// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IDimeTypes} from "../interfaces/IDime.sol";

/// @title DimeRights — DIME stake ledger: issuance on losses, staking, epochs, USDC distributions
/// @dev External library on protocol storage. "active" = staked DIME earning distributions;
///      "pending" = newly issued or newly staked DIME that activates next epoch (blocks just-in-time staking).
/// @dev Mirrors src/domain/rights.ts. Issuance on new cumulative net house loss above the user's
///      high-water mark; activation next epoch; distributions via a cumulative reward index funded
///      only from new house earnings above the earnings high-water mark. Index dust stays in the pool.
library DimeRights {
    uint256 internal constant BPS = 1e4;
    uint256 internal constant INDEX_SCALE = 1e18;

    event DimeIssued(address indexed user, uint256 amount, uint64 activationEpoch, int256 cumulativeNetLoss, int256 highWater, uint256 rateE18);
    event Staked(address indexed user, uint256 amount, uint64 activationEpoch);
    event Unstaked(address indexed user, uint256 amount);
    event EpochFunded(uint64 indexed epoch, uint256 eligibleNewEarnings, uint256 target, uint256 funded, uint8 limitedBy);
    event EpochAdvanced(uint64 indexed epoch, uint256 totalActive);
    event Claimed(address indexed user, uint256 amount);

    error NothingToClaim();
    error InsufficientStake();

    struct User {
        int256 cumNetLoss;
        int256 hwm;
        uint256 pending;
        uint64 pendingEpoch; // 0 = none
        uint256 active;
        uint256 indexSnapshot;
        uint256 accrued;
        uint256 claimed;
    }

    struct State {
        mapping(address => User) users;
        uint64 epoch;
        uint64 epochStartedAt;
        uint256 totalActive;
        mapping(uint64 => uint256) pendingFor;
        uint256 rewardIndex;
        mapping(uint64 => uint256) indexAtEpochStart;
        int256 houseEarnings;
        int256 earningsHwm;
        uint256 funded;
        uint256 claimed;
        mapping(uint64 => uint256) mintedIn;
    }

    /// @param net trader's net P&L on a HOUSE trade (negative = loss)
    /// @param rateE18 DIME (18dp) per $1 of loss, already TVL-decayed
    /// @return issued DIME to mint into the protocol as the user's pending stake
    /// @param weightBps issuance weight for this trade (leverage weighting × phase boosts), 10,000 = 1×.
    function recordHouseResult(State storage s, address user, int256 net, uint256 rateE18, uint256 weightBps, uint256 maxPerEpoch)
        external
        returns (uint256 issued)
    {
        User storage r = s.users[user];
        _activateIfDue(s, r);
        r.cumNetLoss -= net;
        if (r.cumNetLoss <= r.hwm) return 0;
        uint256 newLoss = uint256(r.cumNetLoss - r.hwm); // USDC base units (6dp)
        r.hwm = r.cumNetLoss;
        issued = (newLoss * rateE18 * weightBps) / 1e10;
        uint256 room = maxPerEpoch > s.mintedIn[s.epoch] ? maxPerEpoch - s.mintedIn[s.epoch] : 0;
        if (issued > room) issued = room; // per-epoch cap (disclosed); the high-water mark still advances
        if (issued == 0) return 0;
        s.mintedIn[s.epoch] += issued;
        _addPending(s, r, issued);
        emit DimeIssued(user, issued, s.epoch + 1, r.cumNetLoss, r.hwm, (rateE18 * weightBps) / 1e4); // effective rate for this trade
    }

    /// Stake DIME already transferred to the protocol. Activates next epoch.
    function stake(State storage s, address user, uint256 amount) external {
        User storage r = s.users[user];
        _activateIfDue(s, r);
        _addPending(s, r, amount);
        emit Staked(user, amount, s.epoch + 1);
    }

    /// Unstake: takes from not-yet-active stake first, then active stake. Caller transfers DIME out.
    function unstake(State storage s, address user, uint256 amount) external {
        User storage r = s.users[user];
        _activateIfDue(s, r);
        _accrue(s, r);
        if (amount > r.pending + r.active) revert InsufficientStake();
        uint256 fromPending = amount < r.pending ? amount : r.pending;
        if (fromPending > 0) {
            r.pending -= fromPending;
            s.pendingFor[r.pendingEpoch] -= fromPending;
            if (r.pending == 0) r.pendingEpoch = 0;
        }
        uint256 fromActive = amount - fromPending;
        if (fromActive > 0) {
            r.active -= fromActive;
            s.totalActive -= fromActive;
        }
        emit Unstaked(user, amount);
    }

    function _addPending(State storage s, User storage r, uint256 amount) private {
        uint64 at = s.epoch + 1;
        r.pending += amount;
        r.pendingEpoch = at;
        s.pendingFor[at] += amount;
    }

    /// Funds the closing epoch from `surplus` (house reserve above obligations and floor), THEN advances.
    /// @return funded amount to move from the house reserve into the claims pool
    function fundAndAdvance(State storage s, uint256 surplus, uint256 shareBps) external returns (uint256 funded) {
        int256 diff = s.houseEarnings - s.earningsHwm;
        uint256 eligible = diff > 0 ? uint256(diff) : 0;
        uint256 target = (eligible * shareBps) / BPS;
        IDimeTypes.FundingLimit lim;
        if (eligible == 0) {
            lim = IDimeTypes.FundingLimit.NO_NEW_EARNINGS;
        } else {
            s.earningsHwm = s.houseEarnings; // consumed even if unfunded; never queued for later rights
            if (s.totalActive == 0) {
                lim = IDimeTypes.FundingLimit.NO_ACTIVE_RIGHTS;
            } else {
                funded = target < surplus ? target : surplus;
                lim = funded < target ? IDimeTypes.FundingLimit.RESERVE_FLOOR : IDimeTypes.FundingLimit.NONE;
                if (funded > 0) {
                    s.rewardIndex += (funded * INDEX_SCALE) / s.totalActive;
                    s.funded += funded;
                }
            }
        }
        emit EpochFunded(s.epoch, eligible, target, funded, uint8(lim));
        s.epoch += 1;
        s.indexAtEpochStart[s.epoch] = s.rewardIndex;
        s.totalActive += s.pendingFor[s.epoch];
        delete s.pendingFor[s.epoch];
        s.epochStartedAt = uint64(block.timestamp);
        emit EpochAdvanced(s.epoch, s.totalActive);
    }

    function claim(State storage s, address user) external returns (uint256 amt) {
        User storage r = s.users[user];
        _activateIfDue(s, r);
        _accrue(s, r);
        amt = r.accrued;
        if (amt == 0) revert NothingToClaim();
        r.accrued = 0;
        r.claimed += amt;
        s.claimed += amt;
        emit Claimed(user, amt);
    }

    function account(State storage s, address user) external view returns (IDimeTypes.RightsAccount memory a) {
        User storage r = s.users[user];
        bool due = r.pendingEpoch != 0 && r.pendingEpoch <= s.epoch;
        a.pending = due ? 0 : r.pending;
        a.pendingEpoch = due ? 0 : r.pendingEpoch;
        a.active = r.active + (due ? r.pending : 0);
        a.claimable = r.accrued + ((s.rewardIndex - r.indexSnapshot) * r.active) / INDEX_SCALE
            + (due ? ((s.rewardIndex - s.indexAtEpochStart[r.pendingEpoch]) * r.pending) / INDEX_SCALE : 0);
        a.claimed = r.claimed;
        a.cumulativeNetLoss = r.cumNetLoss;
        a.netLossHighWater = r.hwm;
    }

    function _accrue(State storage s, User storage r) private {
        if (r.active > 0) r.accrued += ((s.rewardIndex - r.indexSnapshot) * r.active) / INDEX_SCALE;
        r.indexSnapshot = s.rewardIndex;
    }

    function _activateIfDue(State storage s, User storage r) private {
        if (r.pendingEpoch == 0 || r.pendingEpoch > s.epoch) return;
        _accrue(s, r);
        r.accrued += ((s.rewardIndex - s.indexAtEpochStart[r.pendingEpoch]) * r.pending) / INDEX_SCALE;
        r.active += r.pending;
        r.pending = 0;
        r.pendingEpoch = 0;
    }
}
