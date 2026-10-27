// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DimeProtocol} from "../src/DimeProtocol.sol";
import {OperatorPriceVerifier} from "../src/oracle/OperatorPriceVerifier.sol";
import {TestUSDC} from "../src/test-tokens/TestUSDC.sol";
import {DimeToken} from "../src/DimeToken.sol";
import {IDimeMintable} from "../src/DimeProtocol.sol";
import {IDimeTypes, IPriceVerifier} from "../src/interfaces/IDime.sol";
import {DimeAgentVault, IDimeForVault} from "../src/agents/DimeAgentVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract AgentVaultTest is Test, IDimeTypes {
    DimeProtocol dime;
    OperatorPriceVerifier oracle;
    TestUSDC usdc;
    DimeToken dimeToken;
    DimeAgentVault vault;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");
    address curator = makeAddr("curator");
    address feeTo = makeAddr("feeTo");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address stranger = makeAddr("stranger");
    uint256 reporterPk = 0xA11CE;
    uint256 agentPk = 0xA6E7;
    uint256 otherPk = 0xBAD;
    address agent;

    uint256 constant P0 = 100_000e8;
    bytes32 constant MKT = keccak256("BTC-USD");
    uint256 nonceSeq = 1;

    function setUp() public {
        vm.warp(1_760_000_000);
        agent = vm.addr(agentPk);
        usdc = new TestUSDC();
        oracle = new OperatorPriceVerifier(admin, vm.addr(reporterPk));
        dimeToken = new DimeToken(admin);
        dime = new DimeProtocol(IERC20(address(usdc)), 6, IDimeMintable(address(dimeToken)), IPriceVerifier(address(oracle)), _cfg(), admin, "DIME");
        vault = new DimeAgentVault(
            IDimeForVault(address(dime)), IERC20(address(usdc)), "DIME Agent Vault #1", "dAV1", curator, agent, feeTo,
            DimeAgentVault.Policy({maxLeverage: 1000, maxMarginBps: 1000, maxHoldSeconds: 3600, performanceFeeBps: 2000, depositCap: 1_000e6})
        );
        vm.startPrank(admin);
        dimeToken.setProtocol(address(dime));
        dime.grantRole(dime.RELAYER_ROLE(), relayer);
        dime.setFundingCapOverride(address(vault), 1_000e6);
        usdc.mint(admin, 100e6);
        usdc.approve(address(dime), type(uint256).max);
        dime.fundReserve(100e6);
        vm.stopPrank();
        _lpDeposit(lp1, 6e6);
        _lpDeposit(lp2, 4e6);
    }

    function _cfg() internal pure returns (Config memory c) {
        c.fundingCapPerWallet = 10e6;
        c.minCollateral = 0.1e6;
        c.maxCollateral = 2e6;
        c.maxLeverage = 1000;
        c.winCurveK = 300;
        c.liqBufferBps = 4;
        c.houseReservationMultiple = 20;
        c.protectionTriggerBps = 9000;
        c.houseMaxUtilisationBps = 8000;
        c.houseMaxNetNotionalMultiple = 200;
        c.maxConcurrentHousePositions = 10;
        c.maxConcurrentMatchedPairs = 25;
        c.dimePerUsdE18 = 0.1e18;
        c.emissionDecayTvl = 1_000_000e6;
        c.maxMintPerEpoch = 10_000e18;
        c.minStake = 0.004e18;
        c.distributionShareBps = 2000;
        c.distributionReserveFloor = 10e6;
        c.epochSeconds = 3600;
        c.maxPriceAgeMs = 3000;
    }

    /* ------------------------------------------------------------------ helpers */
    function _lpDeposit(address who, uint256 amt) internal returns (uint256 shares) {
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(vault), type(uint256).max);
        shares = vault.deposit(amt, who);
        vm.stopPrank();
    }

    function _px(uint256 price) internal view returns (PriceProof memory) {
        uint64 ts = uint64(vm.getBlockTimestamp() * 1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(reporterPk, oracle.digest(MKT, price, ts));
        return PriceProof(abi.encode(price, ts, abi.encodePacked(r, s, v)));
    }

    function _intent(uint8 side, uint128 coll, uint16 lev, uint8 mask) internal returns (OrderIntent memory) {
        return OrderIntent({
            user: address(vault), market: MKT, side: side, collateral: coll, leverage: lev, routeMask: mask,
            matchDeadline: uint64(vm.getBlockTimestamp() + 5), priceLimit: side == 0 ? uint128(P0 * 2) : uint128(1),
            configVersion: 1, expiry: uint64(vm.getBlockTimestamp() + 30), nonce: nonceSeq++
        });
    }

    function _domain() internal view returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("DIME"), keccak256("1"), block.chainid, address(dime)
        ));
    }

    function _orderDigest(OrderIntent memory it) internal view returns (bytes32) {
        bytes32 sh = keccak256(abi.encode(
            keccak256("OrderIntent(address user,bytes32 market,uint8 side,uint128 collateral,uint16 leverage,uint8 routeMask,uint64 matchDeadline,uint128 priceLimit,uint32 configVersion,uint64 expiry,uint256 nonce)"),
            it
        ));
        return keccak256(abi.encodePacked("\x19\x01", _domain(), sh));
    }

    /// What an agent sends as the intent signature: its own EIP-712 signature, wrapped with the message.
    function _vaultSig(uint256 pk, OrderIntent memory it) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, _orderDigest(it));
        return abi.encode(uint8(0), abi.encode(it), abi.encodePacked(r, s, v));
    }

    function _open(OrderIntent memory it, bytes memory sig) internal returns (bytes32 id) {
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        id = dime.openHouse(it, sig, px);
    }

    function _closeSigned(bytes32 id, uint256 price) internal {
        CloseRequest memory req = CloseRequest({user: address(vault), positionId: id, expiry: uint64(vm.getBlockTimestamp() + 30), nonce: nonceSeq++});
        bytes32 sh = keccak256(abi.encode(keccak256("CloseRequest(address user,bytes32 positionId,uint64 expiry,uint256 nonce)"), req));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, keccak256(abi.encodePacked("\x19\x01", _domain(), sh)));
        bytes memory sig = abi.encode(uint8(1), abi.encode(req), abi.encodePacked(r, s, v));
        PriceProof memory px = _px(price);
        vm.prank(relayer);
        dime.close(req, sig, px);
    }

    /* ------------------------------------------------------------------ tests */
    function test_depositsLandInVaultsDimeBalance() public view {
        assertEq(vault.totalAssets(), 10e6);
        assertEq(dime.freeBalance(address(vault)), 10e6, "capital sits in DIME, not idle");
        assertEq(usdc.balanceOf(address(vault)), 0);
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp1)), 6e6, 1, "fair share");
    }

    function test_fundingCapOverride() public {
        assertEq(dime.fundingCapOverride(address(vault)), 1_000e6);
        vm.prank(stranger);
        vm.expectRevert();
        dime.setFundingCapOverride(stranger, 1e12);
    }

    function test_agentOpensAndClosesThroughRelayer() public {
        OrderIntent memory it = _intent(0, 0.5e6, 200, 2);
        bytes32 id = _open(it, _vaultSig(agentPk, it));
        assertEq(dime.positionOf(address(vault)).id, id);
        assertTrue(vault.hasPosition());
        vm.warp(block.timestamp + 10);
        _closeSigned(id, P0 + 100e8); // +0.1% at 200× = +20% on margin, before fees
        assertFalse(vault.hasPosition());
        assertGt(vault.totalAssets(), 10e6, "vault made money");
    }

    function test_policyRejectsOutsideLimits() public {
        // margin above 10% of the vault
        OrderIntent memory a = _intent(0, 1.1e6, 10, 2);
        bytes memory sa = _vaultSig(agentPk, a);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(a, sa, px);

        // matched route (agent could trade against its own wallet)
        OrderIntent memory b = _intent(0, 0.1e6, 10, 3);
        assertFalse(vault.withinPolicy(b));

        // leverage above policy
        vm.prank(curator);
        vault.setPolicy(DimeAgentVault.Policy({maxLeverage: 100, maxMarginBps: 1000, maxHoldSeconds: 3600, performanceFeeBps: 2000, depositCap: 1_000e6}));
        OrderIntent memory c = _intent(0, 0.1e6, 500, 2);
        bytes memory sc = _vaultSig(agentPk, c);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(c, sc, px);
    }

    function test_onlyTheAgentKeyAndOnlyWrappedIntents() public {
        OrderIntent memory it = _intent(0, 0.1e6, 100, 2);
        bytes memory wrongKey = _vaultSig(otherPk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, wrongKey, px);

        // A raw ECDSA signature from the agent is not enough: the vault must see the intent itself.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(agentPk, _orderDigest(it));
        bytes memory raw = abi.encodePacked(r, s, v);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, raw, px);

        // A wrapped message that doesn't match the signed hash is refused.
        OrderIntent memory other = _intent(1, 0.1e6, 100, 2);
        (v, r, s) = vm.sign(agentPk, _orderDigest(it));
        bytes memory swapped = abi.encode(uint8(0), abi.encode(other), abi.encodePacked(r, s, v));
        assertEq(vault.isValidSignature(_orderDigest(it), swapped), bytes4(0xffffffff));

        // Arbitrary messages can never be approved by the agent key.
        bytes32 h = keccak256("anything");
        (v, r, s) = vm.sign(agentPk, h);
        assertEq(vault.isValidSignature(h, abi.encode(uint8(2), bytes(""), abi.encodePacked(r, s, v))), bytes4(0xffffffff));
    }

    function test_pausedAgentCannotTrade() public {
        vm.prank(curator);
        vault.setAgent(address(0));
        OrderIntent memory it = _intent(0, 0.1e6, 100, 2);
        bytes memory sig = _vaultSig(agentPk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, sig, px);
    }

    function test_noDepositsOrWithdrawalsWhileInPosition() public {
        OrderIntent memory it = _intent(1, 0.5e6, 100, 2);
        _open(it, _vaultSig(agentPk, it));
        assertEq(vault.maxWithdraw(lp1), 0);
        assertEq(vault.maxDeposit(lp1), 0);
        vm.prank(lp1);
        vm.expectRevert();
        vault.redeem(1e6, lp1, lp1);
        usdc.mint(lp2, 1e6);
        vm.startPrank(lp2);
        vm.expectRevert();
        vault.deposit(1e6, lp2);
        vm.stopPrank();
    }

    function test_anyoneClosesAfterMaxHold_ownerAnytime() public {
        OrderIntent memory it = _intent(0, 0.5e6, 100, 2);
        _open(it, _vaultSig(agentPk, it));
        vm.warp(block.timestamp + 60);
        PriceProof memory px = _px(P0);
        vm.prank(stranger);
        vm.expectRevert(DimeAgentVault.TooEarly.selector);
        vault.closePosition(px);

        vm.warp(block.timestamp + 3600);
        px = _px(P0 - 10e8);
        vm.prank(stranger);
        vault.closePosition(px);
        assertFalse(vault.hasPosition());

        it = _intent(0, 0.5e6, 100, 2);
        _open(it, _vaultSig(agentPk, it));
        px = _px(P0);
        vm.prank(curator);
        vault.closePosition(px); // owner: no wait, no DIME API needed
        assertFalse(vault.hasPosition());
    }

    function test_withdrawAfterLossIsProRata() public {
        OrderIntent memory it = _intent(0, 1e6, 100, 2);
        bytes32 id = _open(it, _vaultSig(agentPk, it));
        vm.warp(block.timestamp + 5);
        _closeSigned(id, P0 - 500e8); // -0.5% at 100× = -50% of margin
        uint256 nav = vault.totalAssets();
        assertLt(nav, 10e6);
        uint256 shares = vault.balanceOf(lp1);
        vm.prank(lp1);
        uint256 got = vault.redeem(shares, lp1, lp1);
        assertApproxEqAbs(got, nav * 6 / 10, 2, "60% of the vault");
        assertEq(usdc.balanceOf(lp1), got);
        assertEq(vault.highWaterMark() > 0, true);
        assertEq(vault.balanceOf(feeTo), 0, "no fee on a loss");
    }

    function test_performanceFeeOnlyAboveHighWaterMark() public {
        OrderIntent memory it = _intent(0, 1e6, 100, 2);
        bytes32 id = _open(it, _vaultSig(agentPk, it));
        vm.warp(block.timestamp + 5);
        _closeSigned(id, P0 + 500e8); // win
        uint256 nav = vault.totalAssets();
        uint256 gain = nav - 10e6;
        assertGt(vault.pendingFeeShares(), 0);
        vault.crystallise();
        uint256 feeAssets = vault.convertToAssets(vault.balanceOf(feeTo));
        assertApproxEqAbs(feeAssets, gain * 2000 / 10_000, 2, "20% of the gain");
        assertEq(vault.pendingFeeShares(), 0);
        // LPs keep 80% of the gain
        assertApproxEqAbs(vault.convertToAssets(vault.balanceOf(lp1)), 6e6 + gain * 8000 / 10_000 * 6 / 10, 3);

        // A loss then a recovery back to the mark pays nothing more.
        it = _intent(1, 1e6, 100, 2);
        id = _open(it, _vaultSig(agentPk, it));
        vm.warp(block.timestamp + 5);
        _closeSigned(id, P0 + 200e8); // short loses
        assertEq(vault.pendingFeeShares(), 0);
    }

    function test_depositCap() public {
        assertEq(vault.maxDeposit(lp1), 990e6);
        usdc.mint(lp1, 991e6);
        vm.startPrank(lp1);
        vm.expectRevert();
        vault.deposit(991e6, lp1);
        vm.stopPrank();
    }

    function test_vaultEarnsDimeOnLosses() public {
        OrderIntent memory it = _intent(0, 1e6, 100, 2);
        bytes32 id = _open(it, _vaultSig(agentPk, it));
        vm.warp(block.timestamp + 5);
        _closeSigned(id, P0 - 500e8);
        RightsAccount memory a = dime.rightsOf(address(vault));
        assertGt(a.pending + a.active, 0, "DIME staked for the vault's depositors");
    }
}
