// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/// @title DIME token — non-transferable until a publicly scheduled date
/// @notice Minted only by the protocol on eligible house-trade losses (no pre-mint, no team or
///         investor allocation). Until transfers open, DIME can only be staked in the protocol (to
///         earn funded USDC distributions), unstaked back to the holder, or held — it cannot be sent
///         to another wallet, so it cannot be sold or listed.
///         The admin may SCHEDULE transfers to open at a future time with at least MIN_NOTICE of
///         notice (on-chain event), may cancel only before that time, and once open it is permanent.
///         Holding DIME is not a claim on house principal and carries no guaranteed yield.
contract DimeToken is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// Admin role for MINTER_ROLE after wiring: held by no one, so the minter set can never change.
    bytes32 internal constant LOCKED = keccak256("DIME_MINTER_LOCKED");

    /// The protocol (staking venue). Moves to/from it are the only allowed transfers.
    address public protocol;

    /// Minimum public notice before transfers can open.
    uint64 public constant MIN_NOTICE = 14 days;
    /// When transfers open (unix seconds); 0 = not scheduled.
    uint64 public transfersAt;

    error TransfersDisabled();
    error AlreadySet();
    error NoticeTooShort();
    error AlreadyOpen();
    error NotScheduled();

    event ProtocolSet(address protocol);
    event TransfersScheduled(uint64 at);
    event TransfersScheduleCancelled();

    constructor(address admin) ERC20("DIME", "DIME") {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice One-time wiring to the protocol, which becomes the only minter — permanently.
    function setProtocol(address p) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (protocol != address(0)) revert AlreadySet();
        protocol = p;
        _grantRole(MINTER_ROLE, p);
        _setRoleAdmin(MINTER_ROLE, LOCKED); // nobody (incl. admin) can grant or revoke minting again
        emit ProtocolSet(p);
    }

    /// @notice Schedule transfers to open at `at` (≥ now + MIN_NOTICE). Re-scheduling is allowed before opening.
    function scheduleTransfers(uint64 at) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (transfersEnabled()) revert AlreadyOpen();
        if (at < block.timestamp + MIN_NOTICE) revert NoticeTooShort();
        transfersAt = at;
        emit TransfersScheduled(at);
    }

    /// @notice Cancel a pending schedule. Not possible once transfers are open.
    function cancelScheduledTransfers() external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (transfersAt == 0) revert NotScheduled();
        if (transfersEnabled()) revert AlreadyOpen();
        transfersAt = 0;
        emit TransfersScheduleCancelled();
    }

    function transfersEnabled() public view returns (bool) {
        return transfersAt != 0 && block.timestamp >= transfersAt;
    }

    function mint(address to, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        // Before transfers open, only mint (from == 0) and stake/unstake (to/from the protocol) may move DIME.
        if (from != address(0) && from != protocol && to != protocol && !transfersEnabled()) {
            revert TransfersDisabled();
        }
        super._update(from, to, value);
    }
}
