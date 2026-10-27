// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

/// @title DIME protocol interfaces (v1)
/// @notice Directional Isolated Monad Exposure. See docs/CONTRACTS.md for invariants,
///         rounding, gap policy and open decisions.
/// @dev Units: collateral in token base units (USDC: 6 decimals, checked at deploy).
///      Prices are 8-decimal fixed point. Bps = 1e4. Price timestamps are ms.

interface IDimeTypes {
    enum Side { LONG, SHORT }
    enum Route { MATCHED, HOUSE }
    enum ProtocolState { OPEN, CLOSE_ONLY, ORACLE_HOLD, WIND_DOWN, INSOLVENT }
    enum CloseReason { USER, COUNTERPARTY, LIQUIDATION, COUNTERPARTY_LIQUIDATED, RESERVE_PROTECTION, EMERGENCY }
    enum FundingLimit { NONE, NO_ACTIVE_RIGHTS, NO_NEW_EARNINGS, RESERVE_FLOOR }

    /// EIP-712: OrderIntent(address user,bytes32 market,uint8 side,uint128 collateral,uint16 leverage,
    ///   uint8 routeMask,uint64 matchDeadline,uint128 priceLimit,uint32 configVersion,uint64 expiry,uint256 nonce)
    /// routeMask bit0 = matched permitted, bit1 = house permitted.
    struct OrderIntent {
        address user;
        bytes32 market;
        uint8 side;
        uint128 collateral;
        uint16 leverage;
        uint8 routeMask;
        uint64 matchDeadline;
        uint128 priceLimit;
        uint32 configVersion;
        uint64 expiry;
        uint256 nonce;
    }

    /// EIP-712: CloseRequest(address user,bytes32 positionId,uint64 expiry,uint256 nonce)
    struct CloseRequest {
        address user;
        bytes32 positionId;
        uint64 expiry;
        uint256 nonce;
    }

    /// Opaque payload checked by the configured IPriceVerifier.
    struct PriceProof {
        bytes payload;
    }

    struct Position {
        bytes32 id;
        address user;
        Route route;
        Side side;
        uint128 collateral;
        uint16 leverage;
        uint16 curveK; // win curve k at open, hundredths of a bp: a win of m bp pays m × m / (m + k)
        uint16 shortHoldK; // k for wins closed within shortHoldSeconds of opening
        uint16 shortHoldSeconds;
        uint128 entryPrice;
        uint128 liquidationPrice;
        uint128 houseReservation; // HOUSE only
        uint128 maxGrossWin; // MATCHED: opposing collateral + reserved backstop
        bytes32 pairId; // MATCHED: shared by both legs
        uint32 configVersion;
        uint64 openedAtMs;
        bytes32 market; // e.g. keccak256("BTC-USD"); settlement prices are verified for this market
    }

    struct Config {
        uint32 version; // set by the contract
        uint128 fundingCapPerWallet;
        uint128 minCollateral;
        uint128 maxCollateral;
        uint16 maxLeverage;
        uint16 winCurveK; // hundredths of a bp (300 = k 3 bp); at most k bp of any win is kept
        uint16 liqBufferBps; // liquidation when the adverse move reaches 10,000 / leverage − buffer bp; the whole margin is lost
        uint16 shortHoldK; // k for wins closed within shortHoldSeconds (latency-bot surcharge); hundredths of a bp
        uint16 shortHoldSeconds; // 0 = no surcharge
        uint16 houseReservationMultiple;
        uint16 protectionTriggerBps;
        uint16 houseMaxUtilisationBps;
        uint32 houseMaxNetNotionalMultiple;
        uint16 maxConcurrentHousePositions; // 0 = no count limit (exposure-based capacity only)
        uint16 maxConcurrentMatchedPairs;
        uint128 matchedGapBackstop;
        uint128 dimePerUsdE18; // DIME (18dp) issued per $1 of eligible loss while reserve <= emissionDecayTvl
        uint128 emissionDecayTvl; // above this house reserve, the rate falls as (decayTvl / reserve)^3
        uint128 maxMintPerEpoch; // hard cap on DIME issued per epoch (18dp)
        uint128 minStake; // a manual stake must leave the holder with at least this much staked (18dp)
        uint16 distributionShareBps;
        uint128 distributionReserveFloor;
        uint64 epochSeconds;
        uint32 maxPriceAgeMs;
    }

    struct HouseStats {
        uint256 reserve;
        uint256 reservedLiabilities;
        uint256 availableCapacity;
        uint256 matchedCollateralLocked;
        uint256 matchedBackstopReserved;
        uint256 fundedUnclaimed;
        uint256 unfundedLiabilities;
        uint256 collectedLosses;
        uint256 netWinningPayouts;
        uint256 matchedFees;
        int256 netDirectionalNotional;
        uint256 houseLongNotional; // open house-backed trader longs
        uint256 houseShortNotional; // open house-backed trader shorts
        uint256 matchedNotionalPerSide; // open matched pairs (each side)
        uint32 openHousePositions;
        uint32 openMatchedPairs;
    }

    struct RightsAccount {
        uint256 pending;
        uint64 pendingEpoch;
        uint256 active;
        uint256 claimable;
        uint256 claimed;
        int256 cumulativeNetLoss;
        int256 netLossHighWater;
    }
}

/// Customer collateral. Free funds are never house backing.
interface IDimeVault is IDimeTypes {
    event Deposited(address indexed user, uint256 amount, uint256 depositedTotal);
    event Withdrawn(address indexed user, uint256 amount);

    function collateralToken() external view returns (address);
    function deposit(uint256 amount) external;
    function depositFor(address user, uint256 amount) external;
    function withdraw(uint256 amount) external;
    function freeBalance(address user) external view returns (uint256);
    function lockedCollateral(address user) external view returns (uint256);
    function depositedTotal(address user) external view returns (uint256);
}

interface IDimePositions is IDimeTypes {
    event IntentCancelled(address indexed user, uint256 nonce);
    event PositionOpened(
        bytes32 indexed id, address indexed user, bytes32 indexed market, Route route, Side side, uint256 collateral, uint16 leverage,
        uint256 entryPrice, uint256 liquidationPrice, uint256 houseReservation, bytes32 pairId, uint32 configVersion
    );
    event PositionSettled(
        bytes32 indexed id, address indexed user, Route route, uint256 exitPrice, int256 grossPnl, uint256 fee,
        int256 netPnl, uint256 returned, CloseReason reason
    );
    event HouseReservationChanged(bytes32 indexed id, uint256 newReservation);

    function openHouse(OrderIntent calldata intent, bytes calldata sig, PriceProof calldata price) external returns (bytes32 id);
    function openMatched(
        OrderIntent calldata longIntent, bytes calldata longSig,
        OrderIntent calldata shortIntent, bytes calldata shortSig,
        PriceProof calldata price
    ) external returns (bytes32 longId, bytes32 shortId);
    function close(CloseRequest calldata req, bytes calldata sig, PriceProof calldata price) external;
    function closeOwn(bytes32 positionId, PriceProof calldata price) external;
    function liquidate(bytes32 positionId, PriceProof calldata price) external;
    function protect(bytes32 positionId, PriceProof calldata price) external;
    function windDownSettle(bytes32[] calldata positionIds, PriceProof calldata price) external;

    function cancelNonce(uint256 nonce) external;
    function nonceUsed(address user, uint256 nonce) external view returns (bool);
    function positionOf(address user) external view returns (Position memory);
    function getPosition(bytes32 id) external view returns (Position memory);
}

interface IDimeHouse is IDimeTypes {
    event ReserveFunded(address indexed from, uint256 amount);
    event ReserveWithdrawn(address indexed to, uint256 amount);
    event ProtocolStateChanged(ProtocolState state);
    event AllowlistChanged(address indexed user, bool allowed);
    event AllowlistEnabled(bool enabled);

    function fundReserve(uint256 amount) external;
    function withdrawExcessReserve(uint256 amount, address to) external;
    function houseStats() external view returns (HouseStats memory);
    function protocolState() external view returns (ProtocolState);
    function setProtocolState(ProtocolState state) external;
    function allowlistEnabled() external view returns (bool);
    function allowlisted(address user) external view returns (bool);
}

interface IPriceVerifier {
    /// @return price 8-dec fixed point  @return tsMs source timestamp (ms)
    function verify(bytes32 market, bytes calldata payload) external view returns (uint256 price, uint64 tsMs);
    /// @notice false for operator-controlled references. UIs must label these.
    function isIndependentOracle() external view returns (bool);
    function oracleKind() external view returns (string memory);
}

/// DIME issuance, staking and USDC distributions. DIME is minted only on eligible house losses and
/// auto-staked (active next epoch). Staked DIME earns funded USDC distributions. No principal claim.
interface IDimeRights is IDimeTypes {
    event DimeIssued(address indexed user, uint256 amount, uint64 activationEpoch, int256 cumulativeNetLoss, int256 highWater, uint256 rateE18);
    event Staked(address indexed user, uint256 amount, uint64 activationEpoch);
    event Unstaked(address indexed user, uint256 amount);
    event EpochFunded(uint64 indexed epoch, uint256 eligibleNewEarnings, uint256 target, uint256 funded, uint8 limitedBy);
    event EpochAdvanced(uint64 indexed epoch, uint256 totalActive);
    event Claimed(address indexed user, uint256 amount);

    function epoch() external view returns (uint64);
    function epochStartedAt() external view returns (uint64);
    function totalActive() external view returns (uint256);
    function pendingForEpoch(uint64 epoch) external view returns (uint256);
    function rightsOf(address user) external view returns (RightsAccount memory);
    function fundAndAdvance() external;
    function claim() external returns (uint256);
    function stake(uint256 amount) external;
    function unstake(uint256 amount) external;
    function dimeToken() external view returns (address);
    /// Current DIME issued per $1 of eligible loss (18dp), after TVL decay.
    function emissionRate() external view returns (uint256);
}

interface IDimeConfig is IDimeTypes {
    event ConfigActivated(uint32 version);
    function activeConfig() external view returns (Config memory);
    function setConfig(Config calldata cfg) external;
}
