// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IDimeTypes} from "../interfaces/IDime.sol";

/// The DimeProtocol functions an agent vault uses.
interface IDimeForVault is IDimeTypes {
    function deposit(uint256 amount) external;
    function withdraw(uint256 amount) external;
    function freeBalance(address user) external view returns (uint256);
    function lockedCollateral(address user) external view returns (uint256);
    function positionOf(address user) external view returns (Position memory);
    function closeOwn(bytes32 positionId, PriceProof calldata price) external;
    function claim() external returns (uint256);
    function eip712Domain()
        external
        view
        returns (bytes1, string memory, string memory, uint256, address, bytes32, uint256[] memory);
}

/// @title DimeAgentVault
/// @notice A pooled account that an AI agent (or any bot) trades on DIME. Depositors hold ERC-4626 shares;
///         the vault's capital sits in its DIME free balance, and the vault itself is the trading account.
///
///         The agent never holds the money. It signs intents with its own key and sends them through the
///         normal DIME API; the protocol checks them against this contract via ERC-1271, and this contract
///         only says yes when the intent is inside the vault's policy:
///           - for this vault, BTC house route only (no matched route, so the agent can't trade against itself)
///           - leverage ≤ maxLeverage, margin ≤ maxMarginBps of the vault's value
///         One position at a time (a DIME rule). The worst a bad or compromised agent key can do per trade
///         is lose that one margin.
///
///         Deposits and withdrawals happen only while the vault is flat, at the exact value. Positions older
///         than maxHoldSeconds can be closed by anyone, so the agent can't hold withdrawals hostage, and the
///         owner can always close through the contract even if the DIME API is down.
///
///         Optional performance fee for the agent's operator, charged only on gains above the high-water mark,
///         paid in new shares. Losses earn DIME for this vault (staked automatically); its USDC rewards can be
///         claimed into the vault by anyone and belong to all depositors.
/// @dev Signature format for ERC-1271: abi.encode(uint8 kind, bytes message, bytes agentSig), where
///      kind 0 = OrderIntent, 1 = CloseRequest, message = abi.encode(struct), agentSig = the agent's ECDSA
///      signature over the same EIP-712 digest a normal wallet would sign. Any other hash is refused, so the
///      agent key can't approve anything else (messages, permits) for the vault.
contract DimeAgentVault is ERC4626, IERC1271, ReentrancyGuard, IDimeTypes {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "OrderIntent(address user,bytes32 market,uint8 side,uint128 collateral,uint16 leverage,uint8 routeMask,uint64 matchDeadline,uint128 priceLimit,uint32 configVersion,uint64 expiry,uint256 nonce)"
    );
    bytes32 internal constant CLOSE_TYPEHASH =
        keccak256("CloseRequest(address user,bytes32 positionId,uint64 expiry,uint256 nonce)");
    bytes32 internal constant BTC_MARKET = keccak256("BTC-USD");
    uint8 internal constant ROUTE_HOUSE = 2;
    uint8 internal constant KIND_ORDER = 0;
    uint8 internal constant KIND_CLOSE = 1;
    bytes4 internal constant MAGIC = 0x1626ba7e;
    bytes4 internal constant INVALID = 0xffffffff;
    uint256 internal constant BPS = 1e4;
    uint16 public constant MAX_PERFORMANCE_FEE_BPS = 3000;

    IDimeForVault public immutable protocol;
    bytes32 public immutable protocolDomainSeparator;

    address public owner;
    address public agent;
    address public feeRecipient;

    struct Policy {
        uint16 maxLeverage;
        uint16 maxMarginBps; // of totalAssets, per position
        uint32 maxHoldSeconds; // after this, anyone may close the position
        uint16 performanceFeeBps; // on gains above the high-water mark
        uint128 depositCap; // vault size limit in collateral units; 0 = none
    }

    Policy public policy;
    /// Assets per 1e18 shares at the last fee point.
    uint256 public highWaterMark;

    event AgentChanged(address agent);
    event OwnerChanged(address owner);
    event PolicyChanged(Policy policy);
    event FeeRecipientChanged(address recipient);
    event PerformanceFee(uint256 assets, uint256 shares, uint256 highWaterMark);
    event ForceClosed(bytes32 positionId, address by);

    error NotOwner();
    error PositionOpen();
    error NoPosition();
    error TooEarly();
    error BadPolicy();
    error ZeroAddress();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        IDimeForVault protocol_,
        IERC20 collateral,
        string memory name_,
        string memory symbol_,
        address owner_,
        address agent_,
        address feeRecipient_,
        Policy memory policy_
    ) ERC20(name_, symbol_) ERC4626(collateral) {
        if (address(protocol_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        protocol = protocol_;
        (, string memory n, string memory v, uint256 chainId, address verifying,,) = protocol_.eip712Domain();
        protocolDomainSeparator = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes(n)), keccak256(bytes(v)), chainId, verifying
        ));
        owner = owner_;
        agent = agent_;
        feeRecipient = feeRecipient_ == address(0) ? owner_ : feeRecipient_;
        _setPolicy(policy_);
        collateral.forceApprove(address(protocol_), type(uint256).max);
    }

    /* ================================================================== ERC-1271: the agent's trading permission */

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        address a = agent;
        if (a == address(0)) return INVALID; // paused
        (uint8 kind, bytes memory message, bytes memory agentSig) = abi.decode(signature, (uint8, bytes, bytes));
        if (kind == KIND_ORDER) {
            OrderIntent memory it = abi.decode(message, (OrderIntent));
            if (_digest(keccak256(abi.encode(ORDER_TYPEHASH, it))) != hash) return INVALID;
            if (!_withinPolicy(it)) return INVALID;
        } else if (kind == KIND_CLOSE) {
            CloseRequest memory r = abi.decode(message, (CloseRequest));
            if (_digest(keccak256(abi.encode(CLOSE_TYPEHASH, r))) != hash) return INVALID;
            if (r.user != address(this)) return INVALID;
        } else {
            return INVALID;
        }
        (address signer, ECDSA.RecoverError e,) = ECDSA.tryRecover(hash, agentSig);
        return e == ECDSA.RecoverError.NoError && signer == a ? MAGIC : INVALID;
    }

    /// Would the vault accept this intent right now (ignoring the agent signature)? For agents and UIs.
    function withinPolicy(OrderIntent calldata it) external view returns (bool) { return _withinPolicy(it); }

    /// Largest margin the agent may use right now.
    function maxMargin() public view returns (uint256) { return totalAssets() * policy.maxMarginBps / BPS; }

    function _withinPolicy(OrderIntent memory it) internal view returns (bool) {
        return it.user == address(this) && it.market == BTC_MARKET && it.routeMask == ROUTE_HOUSE
            && it.leverage <= policy.maxLeverage && it.collateral <= maxMargin();
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", protocolDomainSeparator, structHash));
    }

    /* ================================================================== positions */

    function hasPosition() public view returns (bool) { return protocol.positionOf(address(this)).user != address(0); }

    /// Owner or agent: close on-chain directly, without the DIME API. Anyone: once the position is older than maxHoldSeconds.
    function closePosition(PriceProof calldata price) external nonReentrant {
        Position memory p = protocol.positionOf(address(this));
        if (p.user == address(0)) revert NoPosition();
        if (msg.sender != owner && msg.sender != agent) {
            if (block.timestamp * 1000 < uint256(p.openedAtMs) + uint256(policy.maxHoldSeconds) * 1000) revert TooEarly();
            emit ForceClosed(p.id, msg.sender);
        }
        protocol.closeOwn(p.id, price);
    }

    /// Anyone: move the vault's accrued staking rewards (USDC) into its trading balance.
    function claimRewards() external returns (uint256) { return protocol.claim(); }

    /* ================================================================== ERC-4626 accounting */

    /// Idle collateral + DIME free balance + margin in an open position (deposits and withdrawals only run when flat).
    function totalAssets() public view override returns (uint256) {
        return IERC20(asset()).balanceOf(address(this)) + protocol.freeBalance(address(this))
            + protocol.lockedCollateral(address(this));
    }

    function maxDeposit(address) public view override returns (uint256) {
        if (hasPosition()) return 0;
        uint256 cap = policy.depositCap;
        if (cap == 0) return type(uint256).max;
        uint256 t = totalAssets();
        return cap > t ? cap - t : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        uint256 a = maxDeposit(receiver);
        return a == type(uint256).max ? a : _convertToShares(a, Math.Rounding.Floor);
    }

    function maxWithdraw(address o) public view override returns (uint256) {
        return hasPosition() ? 0 : super.maxWithdraw(o);
    }

    function maxRedeem(address o) public view override returns (uint256) {
        return hasPosition() ? 0 : super.maxRedeem(o);
    }

    /// Fee shares owed but not yet minted count as supply, so previews already price them in.
    function _convertToShares(uint256 assets, Math.Rounding rounding) internal view override returns (uint256) {
        return assets.mulDiv(totalSupply() + pendingFeeShares() + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal view override returns (uint256) {
        return shares.mulDiv(totalAssets() + 1, totalSupply() + pendingFeeShares() + 10 ** _decimalsOffset(), rounding);
    }

    /// 6 extra share decimals: guards the first depositor against share-price inflation.
    function _decimalsOffset() internal pure override returns (uint8) { return 6; }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        if (hasPosition()) revert PositionOpen();
        _crystallise();
        super._deposit(caller, receiver, assets, shares);
        protocol.deposit(assets);
        if (highWaterMark == 0) highWaterMark = _pricePerShare();
    }

    function _withdraw(address caller, address receiver, address o, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        if (hasPosition()) revert PositionOpen();
        _crystallise();
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (assets > idle) protocol.withdraw(assets - idle);
        super._withdraw(caller, receiver, o, assets, shares);
    }

    /* ================================================================== performance fee */

    function _pricePerShare() internal view returns (uint256) {
        uint256 s = totalSupply();
        return s == 0 ? 0 : totalAssets().mulDiv(1e18, s);
    }

    /// Shares that would be minted to the fee recipient for gains above the high-water mark.
    function pendingFeeShares() public view returns (uint256) {
        uint256 bps = policy.performanceFeeBps;
        uint256 s = totalSupply();
        uint256 hwm = highWaterMark;
        if (bps == 0 || s == 0 || hwm == 0) return 0;
        uint256 assets = totalAssets();
        uint256 pps = assets.mulDiv(1e18, s);
        if (pps <= hwm) return 0;
        uint256 fee = (pps - hwm).mulDiv(s, 1e18).mulDiv(bps, BPS);
        // Shares worth `fee` after they are added: fee × s / (assets − fee).
        return fee.mulDiv(s, assets - fee);
    }

    /// Anyone (while flat): mint the performance fee and move the high-water mark.
    function crystallise() external nonReentrant {
        if (hasPosition()) revert PositionOpen();
        _crystallise();
    }

    function _crystallise() internal {
        uint256 shares = pendingFeeShares();
        if (shares > 0) {
            _mint(feeRecipient, shares);
            highWaterMark = _pricePerShare();
            emit PerformanceFee(convertToAssets(shares), shares, highWaterMark);
        } else if (totalSupply() == 0) {
            highWaterMark = 0;
        }
    }

    /* ================================================================== admin */

    /// address(0) pauses the agent: no new intents or signed closes validate (owner and maxHold closes still work).
    function setAgent(address a) external onlyOwner {
        agent = a;
        emit AgentChanged(a);
    }

    function setPolicy(Policy calldata p) external onlyOwner {
        if (p.performanceFeeBps != policy.performanceFeeBps) {
            if (hasPosition()) revert PositionOpen();
            _crystallise(); // the old rate applies to gains made under it
        }
        _setPolicy(p);
    }

    function setFeeRecipient(address r) external onlyOwner {
        if (r == address(0)) revert ZeroAddress();
        feeRecipient = r;
        emit FeeRecipientChanged(r);
    }

    function transferOwnership(address o) external onlyOwner {
        if (o == address(0)) revert ZeroAddress();
        owner = o;
        emit OwnerChanged(o);
    }

    function _setPolicy(Policy memory p) internal {
        if (
            p.maxLeverage == 0 || p.maxLeverage > 1000 || p.maxMarginBps == 0 || p.maxMarginBps > BPS
                || p.maxHoldSeconds == 0 || p.performanceFeeBps > MAX_PERFORMANCE_FEE_BPS
        ) revert BadPolicy();
        policy = p;
        emit PolicyChanged(p);
    }
}
