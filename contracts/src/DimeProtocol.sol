// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {
    IDimeVault, IDimePositions, IDimeHouse, IDimeRights, IDimeConfig, IPriceVerifier
} from "./interfaces/IDime.sol";
import {DimeMath} from "./lib/DimeMath.sol";
import {DimeRights} from "./lib/DimeRights.sol";

interface IDimeMintable is IERC20 {
    function mint(address to, uint256 amount) external;
    function transfersEnabled() external view returns (bool);
}

/// @title DimeProtocol (v1)
/// @notice Isolated-margin BTC positions against the house reserve or a matched counterparty,
///         plus non-transferable earnings rights on eligible house-trade losses.
/// @dev Single contract exposing all IDime modules. Rounding: amounts owed TO a trader round
///      toward -inf, amounts owed BY a trader and fees round up; dust accrues to the house reserve.
///      Reward-index dust stays in the claims pool. See docs/CONTRACTS.md.
///      Invariant: token.balanceOf(this) == totalFree + totalLocked + reserve + fundedUnclaimed.
contract DimeProtocol is
    IDimeVault, IDimePositions, IDimeHouse, IDimeRights, IDimeConfig, EIP712, AccessControl, ReentrancyGuard
{
    using SafeERC20 for IERC20;

    /* ------------------------------------------------------------------ constants */
    bytes32 public constant RELAYER_ROLE = keccak256("RELAYER_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant BTC_MARKET = keccak256("BTC-USD");
    bytes32 public constant NVDA_MARKET = keccak256("NVDA-USD");
    bytes32 public constant ORDER_TYPEHASH = keccak256(
        "OrderIntent(address user,bytes32 market,uint8 side,uint128 collateral,uint16 leverage,uint8 routeMask,uint64 matchDeadline,uint128 priceLimit,uint32 configVersion,uint64 expiry,uint256 nonce)"
    );
    bytes32 public constant CLOSE_TYPEHASH =
        keccak256("CloseRequest(address user,bytes32 positionId,uint64 expiry,uint256 nonce)");
    bytes32 public constant SESSION_TYPEHASH =
        keccak256("SessionKey(address user,address key,uint64 expiry,uint256 nonce)");
    /// Longest a session key may live; the user renews it after that.
    uint64 public constant MAX_SESSION_SECONDS = 30 days;
    /// Live trading keys per account: paired browsers, phones, bots. Expired keys are pruned when a new one is added.
    uint256 public constant MAX_SESSION_KEYS = 5;
    uint8 internal constant ROUTE_MATCHED = 1;
    uint8 internal constant ROUTE_HOUSE = 2;
    uint256 internal constant BPS = 1e4;
    /// block.timestamp has 1s granularity; price timestamps are ms.
    uint256 internal constant TS_GRANULARITY_MS = 1000;
    uint256 internal constant MAX_FUTURE_MS = 2000;
    /// Issuance phase thresholds: cumulative house-route trader losses, collateral units (6dp).
    uint256 public constant PHASE1_LOSSES = 10_000e6;
    uint256 public constant PHASE2_LOSSES = 50_000e6;
    uint256 public constant PHASE3_LOSSES = 200_000e6;

    /* ------------------------------------------------------------------ errors */
    error BadMarket();
    error BadSide();
    error BadRoute();
    error BadSize();
    error ConfigMismatch();
    error Expired();
    error NonceUsed();
    error BadSignature();
    error ActivePosition();
    error NotAllowlisted();
    error InsufficientFree();
    error FundingCapExceeded();
    error StateForbids();
    error StalePrice();
    error PriceFromFuture();
    error PriceBeforeOpen();
    error PriceLimit();
    error MatchWindow();
    error SelfMatch();
    error IncompatiblePair();
    error CapacityUnavailable();
    error ConcentrationLimit();
    error SlotsFull();
    error UnknownPosition();
    error NotOwner();
    error NotLiquidatable();
    error NotTriggered();
    error EpochNotOver();
    error BadConfig();
    error IssuanceRaised();
    error CoolingDown();
    error ReserveLocked();
    error BelowMinStake();

    /* ------------------------------------------------------------------ storage */
    IERC20 internal immutable _token;
    IDimeMintable internal immutable _dime;

    /// Stakers' share of house earnings can never be set below 5%.
    uint16 public constant MIN_STAKER_SHARE_BPS = 500;
    /// Once DIME can be transferred, unstaked DIME waits this long before it reaches the wallet.
    uint64 public constant UNSTAKE_COOLDOWN = 7 days;
    struct Unstaking { uint128 amount; uint64 readyAt; }
    mapping(address => Unstaking) public unstaking;
    event UnstakeQueued(address indexed user, uint256 amount, uint64 readyAt);
    event UnstakeWithdrawn(address indexed user, uint256 amount);

    /// USDG sent through addStakerRewards, paid to stakers in full at the next fundAndAdvance.
    uint256 public pendingStakerRewards;
    event StakerRewardsAdded(address indexed from, uint256 amount);
    event StakerRewardsPaid(uint64 indexed epoch, uint256 amount, bool toReserve);
    IPriceVerifier public verifier;

    Config internal _cfg;
    ProtocolState internal _state;
    bool public allowlistEnabled;
    mapping(address => bool) public allowlisted;
    /// Per-account funding cap replacing `fundingCapPerWallet` (0 = use the config). For pooled accounts such as agent vaults.
    mapping(address => uint256) public fundingCapOverride;
    /// Trading-only keys per account (paired browsers, terminals, bots). Each can sign opens and closes until its
    /// expiry, never withdraw, stake or change keys.
    struct SessionKey { address key; uint64 expiry; }
    mapping(address => SessionKey[]) internal _sessions;

    mapping(address => uint256) internal _free;
    mapping(address => uint256) internal _deposited;
    uint256 public totalFree;
    uint256 public totalLocked;

    mapping(bytes32 => Position) internal _positions;
    mapping(address => bytes32) internal _active;
    mapping(bytes32 => bytes32[2]) internal _pairs; // pairId => [longId, shortId]
    mapping(address => mapping(uint256 => bool)) internal _nonceUsed;

    uint256 internal _reserve;
    uint256 internal _reservedLiabilities;
    uint256 internal _matchedLocked;
    uint256 internal _matchedBackstop;
    uint256 internal _fundedUnclaimed;
    uint256 internal _unfunded;
    uint256 internal _collectedLosses;
    uint256 internal _netWinningPayouts;
    uint256 internal _matchedFees;
    int256 internal _netDirectional;
    /// Markets new positions may open on. Disabling one stops opens; its positions still settle.
    mapping(bytes32 => bool) public marketEnabled;
    /// Net house-backed trader notional per market (long − short). The concentration limit applies per market.
    mapping(bytes32 => int256) public netDirectionalOf;
    uint256 internal _houseLong;
    uint256 internal _houseShort;
    uint256 internal _matchedNotional;
    uint32 internal _openHouse;
    uint32 internal _openPairs;
    mapping(address => uint256) public unfundedOwed;

    DimeRights.State internal _r;
    uint256 public distributionsClaimed;

    event VerifierChanged(address verifier);
    event FundingCapOverride(address indexed user, uint256 cap);
    event SessionKeySet(address indexed user, address indexed key, uint64 expiry);
    event MarketEnabled(bytes32 indexed market, bool enabled);

    /* ------------------------------------------------------------------ setup */
    constructor(
        IERC20 token_,
        uint8 expectedDecimals,
        IDimeMintable dime_,
        IPriceVerifier verifier_,
        Config memory cfg,
        address admin,
        string memory domainName
    ) EIP712(domainName, "1") {
        if (IERC20Metadata(address(token_)).decimals() != expectedDecimals) revert BadConfig();
        _token = token_;
        _dime = dime_;
        verifier = verifier_;
        _setConfig(cfg);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _r.epoch = 1;
        _r.epochStartedAt = uint64(block.timestamp);
        marketEnabled[BTC_MARKET] = true;
        emit MarketEnabled(BTC_MARKET, true);
        emit VerifierChanged(address(verifier_));
    }

    /* ================================================================== modifiers */
    // Bitmask of permitted ProtocolStates: bit i set ⇒ state i allowed.
    uint8 internal constant S_OPEN = 1 << 0;
    uint8 internal constant S_CLOSE_ONLY = 1 << 1;
    uint8 internal constant S_HOLD = 1 << 2;
    uint8 internal constant S_WIND_DOWN = 1 << 3;
    uint8 internal constant S_INSOLVENT = 1 << 4;
    /// Settlement (closes, liquidations, protection) is allowed in every state except ORACLE_HOLD.
    uint8 internal constant S_SETTLE = S_OPEN | S_CLOSE_ONLY | S_WIND_DOWN | S_INSOLVENT;

    function _requireState(uint8 mask) internal view {
        if ((mask >> uint8(_state)) & 1 == 0) revert StateForbids();
    }

    /* ================================================================== vault */
    function collateralToken() external view returns (address) { return address(_token); }

    function deposit(uint256 amount) external nonReentrant {
        _deposit(msg.sender, msg.sender, amount);
    }

    /// @notice Deposit on behalf of `user`, paid by the caller: lets a bridge or deposit service
    ///         (Relay, Privy deposit addresses) credit a user's DIME balance in the same transaction
    ///         that delivers the funds. The user's allowlist status and funding cap apply, never the payer's.
    function depositFor(address user, uint256 amount) external nonReentrant {
        if (user == address(0)) revert BadSize();
        _deposit(msg.sender, user, amount);
    }

    function _deposit(address payer, address user, uint256 amount) internal {
        _requireState(S_OPEN);
        _requireAllowed(user);
        if (amount == 0) revert BadSize();
        uint256 next = _deposited[user] + amount;
        uint256 cap = fundingCapOverride[user];
        if (next > (cap == 0 ? _cfg.fundingCapPerWallet : cap)) revert FundingCapExceeded();
        _deposited[user] = next;
        _free[user] += amount;
        totalFree += amount;
        _token.safeTransferFrom(payer, address(this), amount);
        emit Deposited(user, amount, next);
    }

    /// @notice Free funds are withdrawable in every protocol state.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0 || _free[msg.sender] < amount) revert InsufficientFree();
        _free[msg.sender] -= amount;
        totalFree -= amount;
        _token.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function freeBalance(address user) external view returns (uint256) { return _free[user]; }
    function lockedCollateral(address user) external view returns (uint256) { return _positions[_active[user]].collateral; }
    function depositedTotal(address user) external view returns (uint256) { return _deposited[user]; }

    /* ================================================================== opening */
    function openHouse(OrderIntent calldata it, bytes calldata sig, PriceProof calldata price)
    external
    onlyRole(RELAYER_ROLE)
    
    returns (bytes32 id)
  {
        _requireState(S_OPEN);
        if (it.routeMask & ROUTE_HOUSE == 0) revert BadRoute();
        // With matched also permitted, house is only a fallback after the user's window.
        if (it.routeMask & ROUTE_MATCHED != 0 && block.timestamp <= it.matchDeadline) revert MatchWindow();
        _consumeIntent(it, sig);
        (uint256 px, uint64 ts) = _price(price, it.market, 0);
        _checkLimit(it, px);

        uint256 reservation = uint256(it.collateral) * _cfg.houseReservationMultiple;
        // 0 = no count limit: capacity is exposure-based (reservation vs reserve × utilisation, below).
        if (_cfg.maxConcurrentHousePositions != 0 && _openHouse >= _cfg.maxConcurrentHousePositions) revert SlotsFull();
        if (reservation > _available()) revert CapacityUnavailable();
        int256 notional = int256(uint256(it.collateral) * it.leverage);
        int256 signed = it.side == 0 ? notional : -notional;
        int256 marketNet = netDirectionalOf[it.market];
        int256 nextNet = marketNet + signed;
        int256 limit = int256(_reserve * _cfg.houseMaxNetNotionalMultiple);
        if (_abs(nextNet) > limit && _abs(nextNet) > _abs(marketNet)) revert ConcentrationLimit();

        _lock(it.user, it.collateral);
        if (it.side == 0) _houseLong += uint256(notional);
        else _houseShort += uint256(notional);
        _reservedLiabilities += reservation;
        _openHouse += 1;
        _netDirectional += signed;
        netDirectionalOf[it.market] = nextNet;
        id = _store(it, Route.HOUSE, px, ts, reservation, 0, bytes32(0));
    }

    function openMatched(
    OrderIntent calldata longIt, bytes calldata longSig,
    OrderIntent calldata shortIt, bytes calldata shortSig,
    PriceProof calldata price
  ) external onlyRole(RELAYER_ROLE) returns (bytes32 longId, bytes32 shortId) {
        _requireState(S_OPEN);
        if (longIt.side != 0 || shortIt.side != 1) revert IncompatiblePair();
        if (longIt.user == shortIt.user) revert SelfMatch();
        if (longIt.market != shortIt.market) revert IncompatiblePair();
        if (longIt.collateral != shortIt.collateral || longIt.leverage != shortIt.leverage) revert IncompatiblePair();
        if (longIt.routeMask & ROUTE_MATCHED == 0 || shortIt.routeMask & ROUTE_MATCHED == 0) revert BadRoute();
        if (block.timestamp > longIt.matchDeadline || block.timestamp > shortIt.matchDeadline) revert MatchWindow();
        if (_openPairs >= _cfg.maxConcurrentMatchedPairs) revert SlotsFull();
        uint256 backstop = _cfg.matchedGapBackstop;
        if (backstop > _available()) revert CapacityUnavailable();

        _consumeIntent(longIt, longSig);
        _consumeIntent(shortIt, shortSig);
        (uint256 px, uint64 ts) = _price(price, longIt.market, 0);
        _checkLimit(longIt, px);
        _checkLimit(shortIt, px);

        _lock(longIt.user, longIt.collateral);
        _lock(shortIt.user, shortIt.collateral);
        _matchedLocked += uint256(longIt.collateral) * 2;
        _matchedNotional += uint256(longIt.collateral) * longIt.leverage;
        _matchedBackstop += backstop;
        _openPairs += 1;

        bytes32 pairId = keccak256(abi.encode(longIt.user, longIt.nonce, shortIt.user, shortIt.nonce));
        uint128 maxWin = uint128(uint256(longIt.collateral) + backstop);
        longId = _store(longIt, Route.MATCHED, px, ts, 0, maxWin, pairId);
        shortId = _store(shortIt, Route.MATCHED, px, ts, 0, maxWin, pairId);
        _pairs[pairId] = [longId, shortId];
    }

    /* ================================================================== closing */
    function close(CloseRequest calldata req, bytes calldata sig, PriceProof calldata price)
    external
    onlyRole(RELAYER_ROLE)
    
  {
        _requireState(S_SETTLE);
        if (block.timestamp > req.expiry) revert Expired();
        if (_nonceUsed[req.user][req.nonce]) revert NonceUsed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(CLOSE_TYPEHASH, req)));
        if (!_authorised(req.user, digest, sig)) revert BadSignature();
        _nonceUsed[req.user][req.nonce] = true;
        Position memory p = _get(req.positionId);
        if (p.user != req.user) revert NotOwner();
        _closePosition(p, price, CloseReason.USER);
    }

    function closeOwn(bytes32 positionId, PriceProof calldata price) external {
        _requireState(S_SETTLE);
        Position memory p = _get(positionId);
        if (p.user != msg.sender) revert NotOwner();
        _closePosition(p, price, CloseReason.USER);
    }

    /// @notice Permissionless. Not available during ORACLE_HOLD.
    function liquidate(bytes32 positionId, PriceProof calldata price) external {
        _requireState(S_SETTLE);
        Position memory p = _get(positionId);
        (uint256 px,) = _price(price, p.market, p.openedAtMs);
        if (!_liquidatable(p, px)) revert NotLiquidatable();
        if (p.route == Route.HOUSE) _settleHouse(p, px, CloseReason.LIQUIDATION);
        else _settlePair(p.pairId, px, CloseReason.LIQUIDATION, bytes32(0));
    }

    /// @notice Permissionless reserve protection: extend the reservation from free capacity,
    ///         otherwise close early at the verified price.
    function protect(bytes32 positionId, PriceProof calldata price) external {
        _requireState(S_SETTLE);
        Position memory p = _get(positionId);
        if (p.route != Route.HOUSE) revert BadRoute();
        (uint256 px,) = _price(price, p.market, p.openedAtMs);
        int256 raw = _rawPnl(p, px);
        if (raw < int256((uint256(p.houseReservation) * _cfg.protectionTriggerBps) / BPS)) revert NotTriggered();
        uint256 ext = uint256(p.collateral) * _cfg.houseReservationMultiple;
        if (ext <= _available()) {
            _positions[positionId].houseReservation = p.houseReservation + uint128(ext);
            _reservedLiabilities += ext;
            emit HouseReservationChanged(positionId, p.houseReservation + ext);
        } else {
            _settleHouse(p, px, CloseReason.RESERVE_PROTECTION);
        }
    }

    /// @notice WIND_DOWN: anyone may settle a bounded batch of positions at a verified price.
    ///         The price is verified per position market, so a batch must hold one market.
    function windDownSettle(bytes32[] calldata ids, PriceProof calldata price) external {
        _requireState(S_WIND_DOWN);
        for (uint256 i; i < ids.length; ++i) {
            Position memory p = _positions[ids[i]];
            if (p.user == address(0)) continue; // already settled (e.g. other leg of a pair)
            (uint256 px,) = _price(price, p.market, p.openedAtMs);
            if (p.route == Route.HOUSE) _settleHouse(p, px, CloseReason.EMERGENCY);
            else _settlePair(p.pairId, px, CloseReason.EMERGENCY, bytes32(0));
        }
    }

    function cancelNonce(uint256 nonce) external {
        _nonceUsed[msg.sender][nonce] = true;
        emit IntentCancelled(msg.sender, nonce);
    }

    /* ================================================================== session keys */
    /// @notice Authorise `key` to sign this account's opens and closes until `expiry` (unix s); setting it again renews.
    /// expiry 0 revokes that key; key address(0) revokes every key. At most MAX_SESSION_KEYS live at once.
    function setSessionKey(address key, uint64 expiry) external {
        _setSession(msg.sender, key, expiry);
    }

    /// @notice Gasless form: anyone (the relayer, a terminal) submits the user's EIP-712 SessionKey signature.
    function setSessionKeyBySig(address user, address key, uint64 expiry, uint256 nonce, bytes calldata sig) external {
        if (_nonceUsed[user][nonce]) revert NonceUsed();
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(SESSION_TYPEHASH, user, key, expiry, nonce)));
        if (!SignatureChecker.isValidSignatureNow(user, digest, sig)) revert BadSignature();
        _nonceUsed[user][nonce] = true;
        _setSession(user, key, expiry);
    }

    /// Every stored key with its expiry (expired ones included until pruned).
    function sessionKeysOf(address user) external view returns (SessionKey[] memory) {
        return _sessions[user];
    }

    function _setSession(address user, address key, uint64 expiry) internal {
        SessionKey[] storage ks = _sessions[user];
        if (key == address(0)) {
            delete _sessions[user];
            emit SessionKeySet(user, address(0), 0);
            return;
        }
        if (expiry != 0 && (expiry <= block.timestamp || expiry > block.timestamp + MAX_SESSION_SECONDS || key == user)) {
            revert BadConfig();
        }
        // Drop this key and any expired ones, then append it if it is being set rather than revoked.
        for (uint256 i = ks.length; i > 0; i--) {
            SessionKey storage k = ks[i - 1];
            if (k.key == key || k.expiry < block.timestamp) {
                ks[i - 1] = ks[ks.length - 1];
                ks.pop();
            }
        }
        if (expiry != 0) {
            if (ks.length >= MAX_SESSION_KEYS) revert BadConfig();
            ks.push(SessionKey(key, expiry));
        }
        emit SessionKeySet(user, key, expiry);
    }

    /// The account's own signature (wallet or ERC-1271 contract), or one of its live session keys'.
    function _authorised(address user, bytes32 digest, bytes calldata sig) internal view returns (bool) {
        if (SignatureChecker.isValidSignatureNow(user, digest, sig)) return true;
        SessionKey[] storage ks = _sessions[user];
        if (ks.length == 0) return false;
        (address signer, ECDSA.RecoverError e,) = ECDSA.tryRecover(digest, sig);
        if (e != ECDSA.RecoverError.NoError) return false;
        for (uint256 i; i < ks.length; i++) {
            if (ks[i].key == signer) return block.timestamp <= ks[i].expiry;
        }
        return false;
    }

    function nonceUsed(address user, uint256 nonce) external view returns (bool) { return _nonceUsed[user][nonce]; }
    function positionOf(address user) external view returns (Position memory) { return _positions[_active[user]]; }
    function getPosition(bytes32 id) external view returns (Position memory) { return _positions[id]; }

    /* ================================================================== house */
    function fundReserve(uint256 amount) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        _reserve += amount;
        _token.safeTransferFrom(msg.sender, address(this), amount);
        emit ReserveFunded(msg.sender, amount);
    }

    /// @notice Admin may remove house capital only above what open risk and the distribution floor need.
    function withdrawExcessReserve(uint256 amount, address to) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_state == ProtocolState.INSOLVENT) revert StateForbids();
        if (amount > _reserve) revert ReserveLocked();
        uint256 after_ = _reserve - amount;
        uint256 used = _reservedLiabilities + _matchedBackstop;
        if ((after_ * _cfg.houseMaxUtilisationBps) / BPS < used) revert ReserveLocked();
        if (_openHouse + _openPairs > 0 && after_ < used + _cfg.distributionReserveFloor) revert ReserveLocked();
        // Stakers' share of this epoch's new earnings stays in the reserve, above the distribution floor
        // that funding keeps back, until the epoch is funded.
        uint256 owed = stakersAccrued();
        if (owed > 0 && after_ < used + _cfg.distributionReserveFloor + owed) revert ReserveLocked();
        _reserve = after_;
        _token.safeTransfer(to, amount);
        emit ReserveWithdrawn(to, amount);
    }

    function houseStats() external view returns (HouseStats memory s) {
        s.reserve = _reserve;
        s.reservedLiabilities = _reservedLiabilities;
        s.availableCapacity = _available();
        s.matchedCollateralLocked = _matchedLocked;
        s.matchedBackstopReserved = _matchedBackstop;
        s.fundedUnclaimed = _fundedUnclaimed;
        s.unfundedLiabilities = _unfunded;
        s.collectedLosses = _collectedLosses;
        s.netWinningPayouts = _netWinningPayouts;
        s.matchedFees = _matchedFees;
        s.netDirectionalNotional = _netDirectional;
        s.houseLongNotional = _houseLong;
        s.houseShortNotional = _houseShort;
        s.matchedNotionalPerSide = _matchedNotional;
        s.openHousePositions = _openHouse;
        s.openMatchedPairs = _openPairs;
    }

    function protocolState() external view returns (ProtocolState) { return _state; }

    /// @notice Guardian can only reduce risk (CLOSE_ONLY / ORACLE_HOLD / WIND_DOWN). Only admin reopens.
    function setProtocolState(ProtocolState s) external {
        if (s == ProtocolState.INSOLVENT) revert StateForbids();
        if (s == ProtocolState.OPEN || _state == ProtocolState.WIND_DOWN || _state == ProtocolState.INSOLVENT) {
            _checkRole(DEFAULT_ADMIN_ROLE);
        } else if (!hasRole(GUARDIAN_ROLE, msg.sender)) {
            _checkRole(DEFAULT_ADMIN_ROLE);
        }
        _state = s;
        emit ProtocolStateChanged(s);
    }

    function setAllowlistEnabled(bool enabled) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowlistEnabled = enabled;
        emit AllowlistEnabled(enabled);
    }

    function setAllowlisted(address[] calldata users, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        for (uint256 i; i < users.length; ++i) {
            allowlisted[users[i]] = allowed;
            emit AllowlistChanged(users[i], allowed);
        }
    }

    function setFundingCapOverride(address user, uint256 cap) external onlyRole(DEFAULT_ADMIN_ROLE) {
        fundingCapOverride[user] = cap;
        emit FundingCapOverride(user, cap);
    }

    /// @notice Guardian can only turn a market off (its positions still settle). Only admin turns one on.
    function setMarketEnabled(bytes32 market, bool enabled) external {
        if (enabled || !hasRole(GUARDIAN_ROLE, msg.sender)) _checkRole(DEFAULT_ADMIN_ROLE);
        marketEnabled[market] = enabled;
        emit MarketEnabled(market, enabled);
    }

    function setVerifier(IPriceVerifier v) external onlyRole(DEFAULT_ADMIN_ROLE) {
        verifier = v;
        emit VerifierChanged(address(v));
    }

    /* ================================================================== config */
    function activeConfig() external view returns (Config memory) { return _cfg; }

    function setConfig(Config calldata cfg) external onlyRole(DEFAULT_ADMIN_ROLE) { _setConfig(cfg); }

    function _setConfig(Config memory cfg) internal {
        if (
            cfg.minCollateral == 0 || cfg.minCollateral > cfg.maxCollateral || cfg.maxLeverage == 0
                || cfg.maxLeverage > 1000 || cfg.winCurveK > 5000 || cfg.shortHoldK > 5000
                || uint256(cfg.liqBufferBps) * cfg.maxLeverage >= BPS || cfg.houseReservationMultiple == 0 || cfg.protectionTriggerBps == 0
                || cfg.protectionTriggerBps > BPS || cfg.houseMaxUtilisationBps > BPS || cfg.epochSeconds < 60
                || cfg.maxPriceAgeMs == 0 || cfg.distributionShareBps > BPS || cfg.distributionShareBps < MIN_STAKER_SHARE_BPS
        ) revert BadConfig();
        // Issuance can only ever be reduced after deployment: the base rate, the decay knee and the
        // per-epoch cap may go down, and the epoch may only get longer (a shorter epoch would let the
        // cap mint more per day). No one, including the admin, can raise DIME issuance.
        if (
            _cfg.version != 0
                && (cfg.dimePerUsdE18 > _cfg.dimePerUsdE18 || cfg.emissionDecayTvl > _cfg.emissionDecayTvl
                    || cfg.maxMintPerEpoch > _cfg.maxMintPerEpoch || cfg.epochSeconds < _cfg.epochSeconds)
        ) revert IssuanceRaised();
        // The reserve kept back before stakers are paid can never rise above its value at deployment,
        // so it can't be raised to block distributions.
        if (_cfg.version != 0 && cfg.distributionReserveFloor > _cfg.distributionReserveFloor) revert BadConfig();
        cfg.version = _cfg.version + 1;
        _cfg = cfg;
        emit ConfigActivated(cfg.version);
    }

    /* ================================================================== rights */
    function epoch() external view returns (uint64) { return _r.epoch; }
    function epochStartedAt() external view returns (uint64) { return _r.epochStartedAt; }
    function totalActive() external view returns (uint256) { return _r.totalActive; }
    function pendingForEpoch(uint64 e) external view returns (uint256) { return _r.pendingFor[e]; }
    function rewardIndex() external view returns (uint256) { return _r.rewardIndex; }
    function houseCumulativeEarnings() external view returns (int256) { return _r.houseEarnings; }
    function earningsHighWater() external view returns (int256) { return _r.earningsHwm; }
    function distributionsFunded() external view returns (uint256) { return _r.funded; }

    function rightsOf(address user) external view returns (RightsAccount memory) { return DimeRights.account(_r, user); }

    /// @notice Permissionless once the epoch has elapsed. Funds the closing epoch, THEN advances,
    ///         so rights activating now never share earlier earnings.
    function fundAndAdvance() external {
        if (block.timestamp < uint256(_r.epochStartedAt) + _cfg.epochSeconds) revert EpochNotOver();
        // Rewards added from outside go to the stakers active in the closing epoch, all of it.
        // With no one staked they fall into the house reserve instead of waiting.
        uint256 extra = pendingStakerRewards;
        if (extra > 0) {
            pendingStakerRewards = 0;
            if (_r.totalActive > 0) {
                _r.rewardIndex += (extra * 1e18) / _r.totalActive; // DimeRights.INDEX_SCALE
                _r.funded += extra;
                _fundedUnclaimed += extra;
            } else {
                _reserve += extra;
            }
            emit StakerRewardsPaid(_r.epoch, extra, _r.totalActive == 0);
        }
        uint256 needed = _reservedLiabilities + _matchedBackstop + _cfg.distributionReserveFloor;
        uint256 surplus = _reserve > needed ? _reserve - needed : 0;
        uint256 funded = DimeRights.fundAndAdvance(_r, surplus, _cfg.distributionShareBps);
        if (funded > 0) {
            _reserve -= funded;
            _fundedUnclaimed += funded;
        }
    }

    /// @notice DIME per $1 of eligible loss (18dp): flat up to `emissionDecayTvl` of house reserve,
    ///         then falling with the cube of the reserve: rate × (decayTvl / reserve)³. With a $1M
    ///         knee that is 1/8 at $2M, 1/125 at $5M and 1/1000 at $10M. Each step rounds down.
    function emissionRate() public view returns (uint256) {
        uint256 r = _reserve;
        uint256 d = _cfg.emissionDecayTvl;
        if (r <= d || r == 0) return _cfg.dimePerUsdE18;
        uint256 rate = _cfg.dimePerUsdE18;
        rate = (rate * d) / r;
        rate = (rate * d) / r;
        return (rate * d) / r;
    }

    function dimeToken() external view returns (address) { return address(_dime); }

    /// @notice Pays USDG to DIME stakers: all of it goes to the stakers active when the current epoch
    ///         is funded (or to the house reserve if nobody is staked). For income from outside trading,
    ///         such as stablecoin reserve rewards or a pool hook's fees. The sender gets nothing back.
    function addStakerRewards(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadSize();
        _token.safeTransferFrom(msg.sender, address(this), amount);
        pendingStakerRewards += amount;
        emit StakerRewardsAdded(msg.sender, amount);
    }

    /// @notice Stakers' share of house earnings above the high-water mark that the next fundAndAdvance would pay.
    function stakersAccrued() public view returns (uint256) {
        if (_r.totalActive == 0) return 0;
        int256 diff = _r.houseEarnings - _r.earningsHwm;
        return diff > 0 ? (uint256(diff) * _cfg.distributionShareBps) / BPS : 0;
    }

    /// @notice Stake DIME (requires approve). Activates next epoch, so stake can't be added just before funding.
    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadSize();
        RightsAccount memory a = DimeRights.account(_r, msg.sender);
        if (a.active + a.pending + amount < _cfg.minStake) revert BelowMinStake();
        IERC20(address(_dime)).safeTransferFrom(msg.sender, address(this), amount);
        DimeRights.stake(_r, msg.sender, amount);
    }

    /// @notice Unstake DIME back to the wallet (pending first, then active). Accrued USDC stays claimable.
    function unstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadSize();
        DimeRights.unstake(_r, msg.sender, amount); // stops earning now
        if (!_dime.transfersEnabled()) {
            // Non-transferable: DIME can't be sold anyway, so it returns at once.
            IERC20(address(_dime)).safeTransfer(msg.sender, amount);
            return;
        }
        Unstaking storage u = unstaking[msg.sender];
        u.amount += uint128(amount);
        u.readyAt = uint64(block.timestamp) + UNSTAKE_COOLDOWN; // a new unstake restarts the clock
        emit UnstakeQueued(msg.sender, u.amount, u.readyAt);
    }

    /// @notice Sends unstaked DIME to the wallet once its cooldown has passed.
    function withdrawUnstaked() external nonReentrant {
        Unstaking memory u = unstaking[msg.sender];
        if (u.amount == 0) revert BadSize();
        if (block.timestamp < u.readyAt) revert CoolingDown();
        delete unstaking[msg.sender];
        IERC20(address(_dime)).safeTransfer(msg.sender, u.amount);
        emit UnstakeWithdrawn(msg.sender, u.amount);
    }

    /// @notice Credits accrued distributions to the caller's free balance (withdrawable).
    function claim() external returns (uint256 amt) {
        amt = DimeRights.claim(_r, msg.sender);
        _fundedUnclaimed -= amt;
        distributionsClaimed += amt;
        _free[msg.sender] += amt;
        totalFree += amt;
    }

    /* ================================================================== internals */
    function _requireAllowed(address user) internal view {
        if (allowlistEnabled && !allowlisted[user]) revert NotAllowlisted();
    }

    function _consumeIntent(OrderIntent calldata it, bytes calldata sig) internal {
        if (!marketEnabled[it.market]) revert BadMarket();
        if (it.side > 1) revert BadSide();
        if (it.configVersion != _cfg.version) revert ConfigMismatch();
        if (block.timestamp > it.expiry) revert Expired();
        if (it.collateral < _cfg.minCollateral || it.collateral > _cfg.maxCollateral) revert BadSize();
        if (it.leverage == 0 || it.leverage > _cfg.maxLeverage) revert BadSize();
        if (_nonceUsed[it.user][it.nonce]) revert NonceUsed();
        // All OrderIntent fields are static, so abi.encode(typehash, struct) == EIP-712 encodeData.
        bytes32 digest = _hashTypedDataV4(keccak256(abi.encode(ORDER_TYPEHASH, it)));
        if (!_authorised(it.user, digest, sig)) revert BadSignature();
        _nonceUsed[it.user][it.nonce] = true;
        if (_active[it.user] != bytes32(0)) revert ActivePosition();
        _requireAllowed(it.user);
    }

    function _price(PriceProof calldata p, bytes32 market, uint64 notBeforeMs) internal view returns (uint256 px, uint64 ts) {
        (px, ts) = verifier.verify(market, p.payload);
        uint256 nowMs = block.timestamp * 1000;
        if (px == 0) revert StalePrice();
        if (ts > nowMs + MAX_FUTURE_MS) revert PriceFromFuture();
        if (nowMs > ts && nowMs - ts > uint256(_cfg.maxPriceAgeMs) + TS_GRANULARITY_MS) revert StalePrice();
        if (ts < notBeforeMs) revert PriceBeforeOpen();
    }

    function _checkLimit(OrderIntent calldata it, uint256 px) internal pure {
        if (it.side == 0 ? px > it.priceLimit : px < it.priceLimit) revert PriceLimit();
    }

    function _lock(address user, uint256 amount) internal {
        if (_free[user] < amount) revert InsufficientFree();
        _free[user] -= amount;
        totalFree -= amount;
        totalLocked += amount;
    }

    function _store(
        OrderIntent calldata it, Route route, uint256 px, uint64 ts, uint256 reservation, uint128 maxWin, bytes32 pairId
    ) internal returns (bytes32 id) {
        id = keccak256(abi.encode(block.chainid, address(this), it.user, it.nonce));
        // Liquidation when the adverse move reaches 10,000 / leverage − buffer bp (6 bp at 1000× with a 4 bp buffer).
        uint256 move = (px * (BPS - uint256(_cfg.liqBufferBps) * it.leverage)) / (BPS * it.leverage); // floor ⇒ closer to entry
        Position storage p = _positions[id];
        p.id = id;
        p.user = it.user;
        p.route = route;
        p.side = Side(it.side);
        p.collateral = it.collateral;
        p.leverage = it.leverage;
        p.curveK = _cfg.winCurveK;
        p.shortHoldK = _cfg.shortHoldK;
        p.shortHoldSeconds = _cfg.shortHoldSeconds;
        p.entryPrice = uint128(px);
        p.liquidationPrice = uint128(it.side == 0 ? px - move : px + move);
        p.houseReservation = uint128(reservation);
        p.maxGrossWin = maxWin;
        p.pairId = pairId;
        p.configVersion = _cfg.version;
        p.openedAtMs = ts;
        p.market = it.market;
        _active[it.user] = id;
        emit PositionOpened(
            id, it.user, it.market, route, Side(it.side), it.collateral, it.leverage, px, p.liquidationPrice, reservation, pairId,
            _cfg.version
        );
    }

    function _get(bytes32 id) internal view returns (Position memory p) {
        p = _positions[id];
        if (p.user == address(0)) revert UnknownPosition();
    }

    function _closePosition(Position memory p, PriceProof calldata price, CloseReason reason) internal {
        (uint256 px,) = _price(price, p.market, p.openedAtMs);
        if (p.route == Route.HOUSE) _settleHouse(p, px, reason);
        else _settlePair(p.pairId, px, reason, p.id);
    }

    function _available() internal view returns (uint256) {
        uint256 ceiling = (_reserve * _cfg.houseMaxUtilisationBps) / BPS;
        uint256 used = _reservedLiabilities + _matchedBackstop;
        return ceiling > used ? ceiling - used : 0;
    }

    function _liquidatable(Position memory p, uint256 px) internal pure returns (bool) {
        return p.side == Side.LONG ? px <= p.liquidationPrice : px >= p.liquidationPrice;
    }

    function _rawPnl(Position memory p, uint256 exit) internal pure returns (int256) {
        return DimeMath.rawPnl(p.side == Side.LONG, p.collateral, p.leverage, p.entryPrice, exit);
    }

    /// Win curve k for this position: the short-hold k if closed within shortHoldSeconds of opening (latency-bot surcharge).
    function _curveK(Position memory p) internal view returns (uint256) {
        if (p.shortHoldSeconds != 0 && block.timestamp * 1000 < uint256(p.openedAtMs) + uint256(p.shortHoldSeconds) * 1000) {
            return p.shortHoldK;
        }
        return p.curveK;
    }

    /// @notice DIME issuance phase, set by cumulative house-route trader losses (collateral units, 6dp):
    ///         below $10k 4× (liquidations 2× more), below $50k 2× (1.5×), below $200k 1.5× (1.25×), then 1×.
    ///         After phase 3 the base rate (dimePerUsdE18) is the weekly lever.
    function issuancePhase() public view returns (uint8 phase, uint256 boostBps, uint256 liqBoostBps) {
        uint256 l = _collectedLosses;
        if (l < PHASE1_LOSSES) return (1, 40_000, 20_000);
        if (l < PHASE2_LOSSES) return (2, 20_000, 15_000);
        if (l < PHASE3_LOSSES) return (3, 15_000, 12_500);
        return (4, BPS, BPS);
    }

    /// Issuance weight, 10,000 = 1×: leverage ÷ 1000 (so 1000× earns the full rate) × phase boost × liquidation boost.
    function _issuanceWeight(uint16 leverage, bool liquidated, int256 net) internal view returns (uint256 w) {
        if (net >= 0) return 0;
        (, uint256 boost, uint256 liqBoost) = issuancePhase();
        w = (uint256(leverage) * BPS) / 1000;
        w = (w * boost) / BPS;
        if (liquidated) w = (w * liqBoost) / BPS;
    }

    function _settleHouse(Position memory p, uint256 exit, CloseReason reason) internal {
        int256 coll = int256(uint256(p.collateral));
        int256 gross = DimeMath.houseGross(
            p.side == Side.LONG, p.collateral, p.leverage, p.entryPrice, exit, p.houseReservation,
            reason == CloseReason.LIQUIDATION
        );
        uint256 fee = DimeMath.winCut(gross, p.entryPrice, exit, _curveK(p));
        int256 net = gross - int256(fee);

        _reservedLiabilities -= p.houseReservation;
        _openHouse -= 1;
        int256 notional = int256(uint256(p.collateral) * p.leverage);
        int256 signed = p.side == Side.LONG ? notional : -notional;
        _netDirectional -= signed;
        netDirectionalOf[p.market] -= signed;
        if (p.side == Side.LONG) _houseLong -= uint256(notional);
        else _houseShort -= uint256(notional);

        uint256 returned;
        if (net < 0) {
            uint256 loss = uint256(-net);
            _reserve += loss;
            _collectedLosses += loss;
            returned = uint256(coll) - loss;
        } else {
            uint256 pay = uint256(net);
            uint256 paid = _payFromReserve(p.user, pay);
            _netWinningPayouts += paid;
            returned = uint256(coll) + paid;
        }
        // The fee is the unpaid part of a win; it is NOT added as extra revenue.
        _r.houseEarnings -= net;
        _release(p, returned);
        uint256 issued = DimeRights.recordHouseResult(
            _r, p.user, net, emissionRate(), _issuanceWeight(p.leverage, reason == CloseReason.LIQUIDATION, net), _cfg.maxMintPerEpoch
        );
        if (issued > 0) _dime.mint(address(this), issued); // held by the protocol as the user's pending stake
        emit PositionSettled(p.id, p.user, Route.HOUSE, exit, gross, fee, net, returned, reason);
    }

    function _settlePair(bytes32 pairId, uint256 exit, CloseReason reason, bytes32 initiator) internal {
        bytes32[2] memory ids = _pairs[pairId];
        Position memory L = _positions[ids[0]];
        Position memory S = _positions[ids[1]];
        bool liq = reason == CloseReason.LIQUIDATION;
        DimeMath.PairResult memory c =
            DimeMath.pair(L.collateral, L.leverage, L.entryPrice, exit, L.maxGrossWin, _curveK(L), liq);
        (Position memory W, Position memory X) = c.longWins ? (L, S) : (S, L);
        uint256 xColl = X.collateral;
        uint256 backstop = W.maxGrossWin > xColl ? W.maxGrossWin - xColl : 0;

        // House: matched fee + rounding/liquidation dust − backstop paid. Matched losses pay the winner, not the house.
        _matchedFees += c.fee;
        _reserve = _reserve + c.fee + (c.loss - c.base) - c.gapPaid;
        _r.houseEarnings += int256(c.fee + (c.loss - c.base)) - int256(c.gapPaid);
        _matchedBackstop -= backstop;
        _matchedLocked -= uint256(L.collateral) + S.collateral;
        _matchedNotional -= uint256(L.collateral) * L.leverage;
        _openPairs -= 1;

        uint256 wReturned = uint256(W.collateral) + c.winnerGross - c.fee;
        uint256 xReturned = xColl - c.loss;
        CloseReason wReason;
        CloseReason xReason;
        if (reason == CloseReason.USER) {
            wReason = W.id == initiator ? CloseReason.USER : CloseReason.COUNTERPARTY;
            xReason = X.id == initiator ? CloseReason.USER : CloseReason.COUNTERPARTY;
        } else if (liq) {
            wReason = CloseReason.COUNTERPARTY_LIQUIDATED;
            xReason = CloseReason.LIQUIDATION;
        } else {
            wReason = reason;
            xReason = reason;
        }
        _release(W, wReturned);
        _release(X, xReturned);
        delete _pairs[pairId];
        int256 wg = int256(c.winnerGross);
        emit PositionSettled(W.id, W.user, Route.MATCHED, exit, wg, c.fee, wg - int256(c.fee), wReturned, wReason);
        emit PositionSettled(X.id, X.user, Route.MATCHED, exit, -int256(c.loss), 0, -int256(c.loss), xReturned, xReason);
    }

    function _release(Position memory p, uint256 returned) internal {
        totalLocked -= p.collateral;
        _free[p.user] += returned;
        totalFree += returned;
        delete _active[p.user];
        delete _positions[p.id];
    }

    function _payFromReserve(address user, uint256 amount) internal returns (uint256 paid) {
        if (amount <= _reserve) {
            _reserve -= amount;
            return amount;
        }
        // Should be unreachable under admission rules; recorded explicitly rather than reverting a settlement.
        paid = _reserve;
        uint256 shortfall = amount - paid;
        _reserve = 0;
        _unfunded += shortfall;
        unfundedOwed[user] += shortfall;
        _state = ProtocolState.INSOLVENT;
        emit ProtocolStateChanged(ProtocolState.INSOLVENT);
    }

    function _abs(int256 x) internal pure returns (int256) { return x < 0 ? -x : x; }
}
