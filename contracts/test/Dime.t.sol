// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DimeProtocol} from "../src/DimeProtocol.sol";
import {DimeRights} from "../src/lib/DimeRights.sol";
import {OperatorPriceVerifier} from "../src/oracle/OperatorPriceVerifier.sol";
import {TestUSDC} from "../src/test-tokens/TestUSDC.sol";
import {DimeToken} from "../src/DimeToken.sol";
import {IDimeMintable} from "../src/DimeProtocol.sol";
import {IDimeTypes, IPriceVerifier} from "../src/interfaces/IDime.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract DimeTest is Test, IDimeTypes {
    DimeProtocol dime;
    OperatorPriceVerifier oracle;
    TestUSDC usdc;
    DimeToken dimeToken;

    address admin = makeAddr("admin");
    address relayer = makeAddr("relayer");
    address guardian = makeAddr("guardian");
    uint256 reporterPk = 0xA11CE;
    uint256 alicePk = 0xA1;
    uint256 bobPk = 0xB0;
    uint256 carolPk = 0xC0;
    address alice;
    address bob;
    address carol;

    uint256 constant P0 = 100_000e8; // $100,000.00000000
    bytes32 constant MKT = keccak256("BTC-USD");
    uint256 nonceSeq = 1;

    function setUp() public virtual {
        vm.warp(1_760_000_000);
        alice = vm.addr(alicePk);
        bob = vm.addr(bobPk);
        carol = vm.addr(carolPk);
        usdc = new TestUSDC();
        oracle = new OperatorPriceVerifier(admin, vm.addr(reporterPk));
        dimeToken = new DimeToken(admin);
        dime = new DimeProtocol(IERC20(address(usdc)), 6, IDimeMintable(address(dimeToken)), IPriceVerifier(address(oracle)), _cfg(), admin, "DIME");
        vm.startPrank(admin);
        dimeToken.setProtocol(address(dime));
        dime.grantRole(dime.RELAYER_ROLE(), relayer);
        dime.grantRole(dime.GUARDIAN_ROLE(), guardian);
        usdc.mint(admin, 10e6);
        usdc.approve(address(dime), type(uint256).max);
        dime.fundReserve(10e6); // founder commissioning reserve
        vm.stopPrank();
        _fund(alice, 2e6);
        _fund(bob, 2e6);
        _fund(carol, 2e6);
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
        c.matchedGapBackstop = 0;
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
    function _fund(address u, uint256 amt) internal {
        usdc.mint(u, amt);
        vm.startPrank(u);
        usdc.approve(address(dime), type(uint256).max);
        dime.deposit(amt);
        vm.stopPrank();
    }

    function _px(uint256 price) internal view returns (PriceProof memory) {
        return _pxAt(price, uint64(vm.getBlockTimestamp() * 1000));
    }

    function _pxAt(uint256 price, uint64 ts) internal view returns (PriceProof memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(reporterPk, oracle.digest(MKT, price, ts));
        return PriceProof(abi.encode(price, ts, abi.encodePacked(r, s, v)));
    }

    function _intent(address user, uint8 side, uint8 mask) internal returns (OrderIntent memory it) {
        it = OrderIntent({
            user: user, market: MKT, side: side, collateral: 0.1e6, leverage: 1000, routeMask: mask,
            matchDeadline: uint64(vm.getBlockTimestamp() + 5), priceLimit: side == 0 ? uint128(P0 * 2) : uint128(1),
            configVersion: 1, expiry: uint64(vm.getBlockTimestamp() + 30), nonce: nonceSeq++
        });
    }

    /// Independent EIP-712 implementation, so the test checks the contract's encoding.
    function _domain(address verifying, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("DIME"), keccak256("1"), chainId, verifying
        ));
    }

    function _sign(uint256 pk, OrderIntent memory it) internal view returns (bytes memory) {
        return _signFor(pk, it, address(dime), block.chainid);
    }

    function _signFor(uint256 pk, OrderIntent memory it, address verifying, uint256 chainId) internal pure returns (bytes memory) {
        bytes32 structHash = keccak256(abi.encode(
            keccak256("OrderIntent(address user,bytes32 market,uint8 side,uint128 collateral,uint16 leverage,uint8 routeMask,uint64 matchDeadline,uint128 priceLimit,uint32 configVersion,uint64 expiry,uint256 nonce)"),
            it.user, it.market, it.side, it.collateral, it.leverage, it.routeMask, it.matchDeadline, it.priceLimit,
            it.configVersion, it.expiry, it.nonce
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", _domain(verifying, chainId), structHash)));
        return abi.encodePacked(r, s, v);
    }

    function _openHouse(uint256 pk, address user, uint8 side, uint256 price) internal returns (bytes32 id) {
        OrderIntent memory it = _intent(user, side, 2);
        bytes memory sig = _sign(pk, it);
        PriceProof memory px = _px(price);
        vm.prank(relayer);
        id = dime.openHouse(it, sig, px);
    }

    function _openPair(uint256 price) internal returns (bytes32 lId, bytes32 sId) {
        OrderIntent memory l = _intent(alice, 0, 1);
        OrderIntent memory s = _intent(bob, 1, 1);
        bytes memory ls = _sign(alicePk, l);
        bytes memory ss = _sign(bobPk, s);
        PriceProof memory px = _px(price);
        vm.prank(relayer);
        (lId, sId) = dime.openMatched(l, ls, s, ss, px);
    }

    function _invariant() internal view {
        HouseStats memory h = dime.houseStats();
        assertEq(usdc.balanceOf(address(dime)), dime.totalFree() + dime.totalLocked() + h.reserve + h.fundedUnclaimed + dime.pendingStakerRewards(), "conservation");
    }

    /* ------------------------------------------------------------------ custody */
    function test_depositCapAndWithdraw() public {
        usdc.mint(alice, 20e6);
        vm.startPrank(alice);
        dime.deposit(8e6); // 2 + 8 = 10 = cap
        vm.expectRevert(DimeProtocol.FundingCapExceeded.selector);
        dime.deposit(1);
        dime.withdraw(10e6);
        assertEq(dime.freeBalance(alice), 0);
        // cap counts external deposits, not current balance
        vm.expectRevert(DimeProtocol.FundingCapExceeded.selector);
        dime.deposit(1);
        vm.stopPrank();
        _invariant();
    }

    function test_depositForCreditsUserAndAppliesTheirCap() public {
        address bridge = makeAddr("bridge");
        usdc.mint(bridge, 20e6);
        vm.startPrank(bridge);
        usdc.approve(address(dime), type(uint256).max);
        dime.depositFor(alice, 8e6); // alice already deposited 2 in setUp: 2 + 8 = cap
        assertEq(dime.freeBalance(alice), 10e6, "credited to the user");
        assertEq(dime.freeBalance(bridge), 0, "never to the payer");
        assertEq(dime.depositedTotal(bridge), 0);
        vm.expectRevert(DimeProtocol.FundingCapExceeded.selector);
        dime.depositFor(alice, 1); // the user's cap, not the payer's
        vm.expectRevert(DimeProtocol.BadSize.selector);
        dime.depositFor(address(0), 1e6);
        vm.stopPrank();
        vm.prank(alice);
        dime.withdraw(10e6); // the user controls the funds
        _invariant();
    }

    function test_depositForRespectsUserAllowlist() public {
        vm.prank(admin);
        dime.setAllowlistEnabled(true);
        address bridge = makeAddr("bridge");
        address dave = makeAddr("dave");
        usdc.mint(bridge, 1e6);
        vm.startPrank(bridge);
        usdc.approve(address(dime), 1e6);
        vm.expectRevert(DimeProtocol.NotAllowlisted.selector);
        dime.depositFor(dave, 1e6);
        vm.stopPrank();
    }

    function test_allowlistEnforced() public {
        vm.prank(admin);
        dime.setAllowlistEnabled(true);
        address dave = makeAddr("dave");
        usdc.mint(dave, 1e6);
        vm.startPrank(dave);
        usdc.approve(address(dime), 1e6);
        vm.expectRevert(DimeProtocol.NotAllowlisted.selector);
        dime.deposit(1e6);
        vm.stopPrank();
        // existing (non-allowlisted) depositor can still withdraw
        vm.prank(alice);
        dime.withdraw(1e6);
        // but cannot open
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.NotAllowlisted.selector);
        dime.openHouse(it, sig, px);
    }

    /* ------------------------------------------------------------------ house */
    function test_openInterestCounters() public {
        bytes32 h = _openHouse(carolPk, carol, 1, P0);
        (bytes32 l,) = _openPair(P0);
        HouseStats memory st = dime.houseStats();
        assertEq(st.houseShortNotional, 100e6);
        assertEq(st.houseLongNotional, 0);
        assertEq(st.matchedNotionalPerSide, 100e6);
        PriceProof memory px = _px(P0);
        vm.prank(carol);
        dime.closeOwn(h, px);
        vm.prank(alice);
        dime.closeOwn(l, px);
        st = dime.houseStats();
        assertEq(st.houseShortNotional + st.houseLongNotional + st.matchedNotionalPerSide, 0);
    }

    function test_houseWin_feeReducesPayoutOnly() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        Position memory p = dime.getPosition(id);
        assertEq(p.liquidationPrice, P0 - 60e8); // 10 bp of margin at 1000× − 4 bp buffer = a 6 bp move
        assertEq(p.curveK, 300);
        uint256 reserveBefore = dime.houseStats().reserve;
        PriceProof memory cp1 = _px(P0 + 100e8);
        vm.prank(alice);
        dime.closeOwn(id, cp1); // +10 bp on $100 notional = +$0.10 gross; pays 10 × 10 / 13 bp
        uint256 net = 0.1e6 - 23_077; // cut = ceil(0.1 × 3 / 13)
        assertEq(dime.freeBalance(alice), 2e6 + net); // collateral back + net
        assertEq(dime.houseStats().reserve, reserveBefore - net); // pays net only; the cut is not added
        assertEq(dime.houseStats().netWinningPayouts, net);
        assertEq(dime.houseStats().reservedLiabilities, 0);
        assertEq(dime.rightsOf(alice).pending, 0);
        _invariant();
    }

    function test_houseLoss_issuesRightsAboveHighWater() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        PriceProof memory cp2 = _px(P0 - 50e8);
        vm.prank(alice);
        dime.closeOwn(id, cp2); // −$0.05
        RightsAccount memory r = dime.rightsOf(alice);
        assertEq(r.pending, 0.02e18); // $0.05 × 0.1 DIME/$ × 4 (phase 1) at 1000×
        assertEq(r.pendingEpoch, 2);
        assertEq(dimeToken.balanceOf(address(dime)), 0.02e18); // minted into the protocol as pending stake
        // win back 0.05 net then lose 0.05 again: no new rights (HWM)
        id = _openHouse(alicePk, alice, 0, P0);
        PriceProof memory cp3 = _px(P0 + 80e8);
        vm.prank(alice);
        dime.closeOwn(id, cp3); // 8 bp: gross 0.08, cut 0.08 × 3/11, net ≈ 0.0582
        id = _openHouse(alicePk, alice, 0, P0);
        PriceProof memory cp4 = _px(P0 - 50e8);
        vm.prank(alice);
        dime.closeOwn(id, cp4);
        assertEq(dime.rightsOf(alice).pending, 0.02e18);
        _invariant();
    }

    function test_houseLiquidation_lossCappedAtCollateralEvenThroughGap() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 5_000e8)); // −5% gap at 1000×
        assertEq(dime.freeBalance(alice), 1.9e6);
        assertEq(dime.houseStats().collectedLosses, 0.1e6);
        _invariant();
    }

    function test_notLiquidatableAboveLiqPrice() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        PriceProof memory px = _px(P0 - 59e8);
        vm.expectRevert(DimeProtocol.NotLiquidatable.selector);
        dime.liquidate(id, px);
    }

    function test_reserveProtection_extendsThenCloses() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        // reservation 2.0; trigger at 1.8 gross ⇒ +1.8% move
        dime.protect(id, _px(P0 + 1_800e8));
        assertEq(dime.getPosition(id).houseReservation, 4e6);
        // exhaust remaining capacity (reserve*0.8 − used) with other positions, then protection closes
        _openHouse(bobPk, bob, 1, P0 + 1_800e8);
        _openHouse(carolPk, carol, 1, P0 + 1_800e8);
        // capacity: 8.0 − (4+2+2)=0
        dime.protect(id, _px(P0 + 3_700e8));
        assertEq(dime.getPosition(id).user, address(0)); // closed
        _invariant();
    }

    function test_capacityUnavailable() public {
        _openHouse(alicePk, alice, 0, P0);
        _openHouse(bobPk, bob, 0, P0);
        _openHouse(carolPk, carol, 0, P0);
        address d = vm.addr(0xD0);
        _fund(d, 1e6);
        _openHouse(0xD0, d, 0, P0); // used 8.0 = ceiling
        address e = vm.addr(0xE0);
        _fund(e, 1e6);
        OrderIntent memory it = _intent(e, 0, 2);
        bytes memory sig = _sign(0xE0, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.CapacityUnavailable.selector);
        dime.openHouse(it, sig, px);
    }

    function test_slotCountZeroMeansExposureOnly() public {
        // A count limit of 1 blocks the second house position even with capacity to spare...
        Config memory c = _cfg();
        c.maxConcurrentHousePositions = 1;
        vm.prank(admin);
        dime.setConfig(c); // version 2
        _openHouseV(alicePk, alice, 2);
        OrderIntent memory it = _intent(bob, 0, 2);
        it.configVersion = 2;
        bytes memory sig = _sign(bobPk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.SlotsFull.selector);
        dime.openHouse(it, sig, px);
        // ...while 0 means only exposure (reservations vs reserve × utilisation) decides.
        c.maxConcurrentHousePositions = 0;
        vm.prank(admin);
        dime.setConfig(c); // version 3
        _openHouseV(bobPk, bob, 3);
        _openHouseV(carolPk, carol, 3);
        assertEq(dime.houseStats().openHousePositions, 3);
        _invariant();
    }

    function _openHouseV(uint256 pk, address user, uint32 version) internal returns (bytes32 id) {
        OrderIntent memory it = _intent(user, 0, 2);
        it.configVersion = version;
        bytes memory sig = _sign(pk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        id = dime.openHouse(it, sig, px);
    }

    function test_houseFallbackOnlyAfterMatchWindow() public {
        OrderIntent memory it = _intent(alice, 0, 3);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.MatchWindow.selector);
        dime.openHouse(it, sig, px);
        vm.warp(vm.getBlockTimestamp() + 6);
        px = _px(P0);
        vm.prank(relayer);
        dime.openHouse(it, sig, px);
    }

    /* ------------------------------------------------------------------ matched */
    function test_matched_counterpartyCloseSettlesBoth() public {
        (bytes32 l, bytes32 s) = _openPair(P0);
        assertEq(dime.houseStats().matchedCollateralLocked, 0.2e6);
        assertEq(dime.houseStats().reservedLiabilities, 0); // matched collateral is not house capital
        uint256 reserveBefore = dime.houseStats().reserve;
        PriceProof memory cp5 = _px(P0 + 50e8);
        vm.prank(bob);
        dime.closeOwn(s, cp5); // short closes at a loss; long wins 0.05 gross
        assertEq(dime.getPosition(l).user, address(0));
        // 5 bp win: cut = 0.05 × 3 / 8 = 0.01875
        assertEq(dime.freeBalance(alice), 1.9e6 + 0.1e6 + 0.05e6 - 0.01875e6);
        assertEq(dime.freeBalance(bob), 1.9e6 + 0.05e6);
        assertEq(dime.houseStats().reserve, reserveBefore + 0.01875e6);
        assertEq(dime.houseStats().matchedFees, 0.01875e6);
        assertEq(dime.rightsOf(bob).pending, 0); // matched losses issue no rights
        _invariant();
    }

    function test_matched_gapCappedAtLoserCollateral() public {
        (bytes32 l,) = _openPair(P0);
        PriceProof memory cp6 = _px(P0 + 1_000e8);
        vm.prank(alice);
        dime.closeOwn(l, cp6); // raw +$1.00, loser only has $0.10
        assertEq(dime.freeBalance(alice), 1.9e6 + 0.1e6 + 0.1e6 - 2913); // 100 bp move: cut = ceil(0.1 × 3 / 103)
        assertEq(dime.freeBalance(bob), 1.9e6);
        _invariant();
    }

    function test_matched_liquidationSettlesBoth() public {
        (bytes32 l,) = _openPair(P0);
        dime.liquidate(l, _px(P0 - 90e8));
        assertEq(dime.freeBalance(alice), 1.9e6);
        assertEq(dime.freeBalance(bob), 1.9e6 + 0.2e6 - 0.025e6);
        _invariant();
    }

    function test_matched_rejectsSelfMatchAndMismatch() public {
        OrderIntent memory l = _intent(alice, 0, 1);
        OrderIntent memory s = _intent(alice, 1, 1);
        bytes memory ls = _sign(alicePk, l);
        bytes memory ss = _sign(alicePk, s);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.SelfMatch.selector);
        dime.openMatched(l, ls, s, ss, px);
        s = _intent(bob, 1, 1);
        s.leverage = 500;
        ss = _sign(bobPk, s);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.IncompatiblePair.selector);
        dime.openMatched(l, ls, s, ss, px);
    }

    function test_matched_afterWindowRejected() public {
        OrderIntent memory l = _intent(alice, 0, 1);
        OrderIntent memory s = _intent(bob, 1, 1);
        bytes memory ls = _sign(alicePk, l);
        bytes memory ss = _sign(bobPk, s);
        vm.warp(vm.getBlockTimestamp() + 6);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.MatchWindow.selector);
        dime.openMatched(l, ls, s, ss, px);
    }

    /* ------------------------------------------------------------------ signatures & replay */
    function test_replayAndCancel() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        bytes32 id = dime.openHouse(it, sig, px);
        vm.prank(alice);
        dime.closeOwn(id, px);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.NonceUsed.selector);
        dime.openHouse(it, sig, px);

        OrderIntent memory it2 = _intent(alice, 0, 2);
        bytes memory sig2 = _sign(alicePk, it2);
        vm.prank(alice);
        dime.cancelNonce(it2.nonce);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.NonceUsed.selector);
        dime.openHouse(it2, sig2, px);
    }

    function test_signatureBinding() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        PriceProof memory px = _px(P0);
        // wrong chain id in domain
        bytes memory bad = _signFor(alicePk, it, address(dime), 1);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, bad, px);
        // other contract
        bad = _signFor(alicePk, it, address(0xBEEF), block.chainid);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, bad, px);
        // signed by someone else
        bad = _sign(bobPk, it);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, bad, px);
        // tampered leverage
        bytes memory good = _sign(alicePk, it);
        it.leverage = 999;
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, good, px);
    }

    function test_configVersionAndExpiry() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        it.configVersion = 2;
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.ConfigMismatch.selector);
        dime.openHouse(it, sig, px);
        it = _intent(alice, 0, 2);
        sig = _sign(alicePk, it);
        vm.warp(vm.getBlockTimestamp() + 31);
        px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.Expired.selector);
        dime.openHouse(it, sig, px);
    }

    function test_onePositionPerWallet_simultaneousOpens() public {
        _openHouse(alicePk, alice, 0, P0);
        OrderIntent memory it = _intent(alice, 1, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.ActivePosition.selector);
        dime.openHouse(it, sig, px);
    }

    function test_onlyRelayerOpens() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.expectRevert();
        dime.openHouse(it, sig, px);
    }

    /* ------------------------------------------------------------------ price checks */
    function test_stalePriceAndFuturePriceRejected() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory stale = _pxAt(P0, uint64(vm.getBlockTimestamp() * 1000 - 5000));
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.StalePrice.selector);
        dime.openHouse(it, sig, stale);
        PriceProof memory future = _pxAt(P0, uint64(vm.getBlockTimestamp() * 1000 + 5000));
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.PriceFromFuture.selector);
        dime.openHouse(it, sig, future);
    }

    function test_unauthorisedReporterRejected() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        uint64 ts = uint64(vm.getBlockTimestamp() * 1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, oracle.digest(MKT, P0, ts));
        PriceProof memory px = PriceProof(abi.encode(P0, ts, abi.encodePacked(r, s, v)));
        vm.prank(relayer);
        vm.expectRevert(OperatorPriceVerifier.BadReporter.selector);
        dime.openHouse(it, sig, px);
        assertFalse(oracle.isIndependentOracle());
    }

    function test_priceLimitEnforced() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        it.priceLimit = uint128(P0 - 1);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.PriceLimit.selector);
        dime.openHouse(it, sig, px);
    }

    /* ------------------------------------------------------------------ states */
    function test_closeOnly_and_oracleHold() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        vm.prank(guardian);
        dime.setProtocolState(ProtocolState.CLOSE_ONLY);
        OrderIntent memory it = _intent(bob, 0, 2);
        bytes memory sig = _sign(bobPk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.StateForbids.selector);
        dime.openHouse(it, sig, px);
        vm.prank(guardian);
        vm.expectRevert(); // guardian cannot reopen
        dime.setProtocolState(ProtocolState.OPEN);
        vm.prank(guardian);
        dime.setProtocolState(ProtocolState.ORACLE_HOLD);
        vm.prank(alice);
        vm.expectRevert(DimeProtocol.StateForbids.selector);
        dime.closeOwn(id, px);
        vm.prank(bob);
        dime.withdraw(1e6); // withdrawals always work
        vm.prank(admin);
        dime.setProtocolState(ProtocolState.OPEN);
        PriceProof memory cp7 = _px(P0);
        vm.prank(alice);
        dime.closeOwn(id, cp7);
        _invariant();
    }

    function test_windDownBatchSettles() public {
        bytes32 h = _openHouse(carolPk, carol, 0, P0);
        (bytes32 l, bytes32 s) = _openPair(P0);
        vm.prank(guardian);
        dime.setProtocolState(ProtocolState.WIND_DOWN);
        bytes32[] memory ids = new bytes32[](3);
        (ids[0], ids[1], ids[2]) = (h, l, s);
        dime.windDownSettle(ids, _px(P0 + 10e8));
        assertEq(dime.houseStats().openHousePositions, 0);
        assertEq(dime.houseStats().openMatchedPairs, 0);
        _invariant();
    }

    /* ------------------------------------------------------------------ rights & distributions */
    function test_rightsLifecycle_fundActivateClaim() public {
        // epoch 1: alice loses 0.10 to the house → 0.10 pending rights for epoch 2
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8));
        vm.expectRevert(DimeProtocol.EpochNotOver.selector);
        dime.fundAndAdvance();
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance(); // no active rights: earnings consumed, nothing funded
        RightsAccount memory r = dime.rightsOf(alice);
        assertEq(r.active, 0.08e18); // 0.01 × 4 (phase 1) × 2 (liquidation boost)
        assertEq(r.claimable, 0);
        assertEq(dime.totalActive(), 0.08e18);

        // epoch 2: bob loses 0.10 to the house; reserve is 10.2, floor 10 → surplus 0.2, target 0.02
        id = _openHouse(bobPk, bob, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8));
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        assertEq(dime.rightsOf(alice).claimable, 0.02e6);
        assertEq(dime.rightsOf(bob).claimable, 0); // bob's rights activate only now
        vm.prank(alice);
        assertEq(dime.claim(), 0.02e6);
        vm.prank(alice);
        vm.expectRevert(DimeRights.NothingToClaim.selector);
        dime.claim(); // duplicate claim prevented
        _invariant();
    }

    function test_houseLossMustBeRecoveredBeforeDistribution() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8)); // house +0.10
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        id = _openHouse(bobPk, bob, 0, P0);
        PriceProof memory cp8 = _px(P0 + 100e8);
        vm.prank(bob);
        dime.closeOwn(id, cp8); // house −0.075
        id = _openHouse(carolPk, carol, 0, P0);
        PriceProof memory cp9 = _px(P0 - 50e8);
        vm.prank(carol);
        dime.closeOwn(id, cp9); // house +0.05 → still below HWM
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        assertEq(dime.distributionsFunded(), 0);
    }

    /* ------------------------------------------------------------------ fuzz */
    function testFuzz_houseSettlementConserves(uint256 move, bool long_) public {
        move = bound(move, 0, 3_000e8);
        bytes32 id = _openHouse(alicePk, alice, long_ ? 0 : 1, P0);
        uint256 exit = move % 2 == 0 ? P0 + move : P0 - move;
        Position memory p = dime.getPosition(id);
        bool liq = long_ ? exit <= p.liquidationPrice : exit >= p.liquidationPrice;
        if (liq) dime.liquidate(id, _px(exit));
        else {
            PriceProof memory cp10 = _px(exit);
            vm.prank(alice);
            dime.closeOwn(id, cp10);
        }
        _invariant();
        assertLe(dime.freeBalance(alice), 2e6 + 2e6); // never more than collateral + reservation
    }

    function testFuzz_pairSettlementConserves(uint256 move) public {
        move = bound(move, 0, 2_000e8);
        (bytes32 l,) = _openPair(P0);
        uint256 exit = move % 2 == 0 ? P0 + move : P0 - move;
        Position memory p = dime.getPosition(l);
        if (exit <= p.liquidationPrice) dime.liquidate(l, _px(exit));
        else {
            PriceProof memory cp11 = _px(exit);
            vm.prank(alice);
            dime.closeOwn(l, cp11);
        }
        _invariant();
        assertLe(dime.freeBalance(alice) + dime.freeBalance(bob), 4e6);
    }

    /* ------------------------------------------------------------------ DIME token & staking */
    function test_emissionDecaysWithHouseReserve() public {
        assertEq(dime.emissionRate(), 0.1e18); // reserve $10 ≤ $1M
        usdc.mint(admin, 3_999_990e6);
        vm.startPrank(admin);
        usdc.approve(address(dime), type(uint256).max);
        dime.fundReserve(3_999_990e6); // reserve $10 + $3,999,990 = $4M
        vm.stopPrank();
        assertEq(dime.emissionRate(), 0.0015625e18); // 0.1 × (1M / 4M)³ = 0.1 / 64
    }

    function test_perEpochMintCap() public {
        Config memory c = _cfg();
        c.maxMintPerEpoch = 0.1e18; // room for 0.1 DIME this epoch
        vm.prank(admin);
        dime.setConfig(c);
        // config version is now 2; intents must use it
        OrderIntent memory it = _intent(alice, 0, 2);
        it.configVersion = 2;
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        bytes32 id = dime.openHouse(it, sig, px);
        dime.liquidate(id, _px(P0 - 90e8)); // $0.10 → 0.01 × 4 phase × 2 liquidation = 0.08 DIME
        it = _intent(bob, 0, 2);
        it.configVersion = 2;
        sig = _sign(bobPk, it);
        px = _px(P0);
        vm.prank(relayer);
        id = dime.openHouse(it, sig, px);
        dime.liquidate(id, _px(P0 - 90e8)); // would be 0.08, only 0.02 left
        assertEq(dime.rightsOf(bob).pending, 0.02e18);
    }

    function test_stakeUnstakeAndNonTransferable() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8)); // 0.08 DIME pending
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        assertEq(dime.rightsOf(alice).active, 0.08e18);
        // unstake half to the wallet
        vm.prank(alice);
        dime.unstake(0.04e18);
        assertEq(dimeToken.balanceOf(alice), 0.04e18);
        assertEq(dime.totalActive(), 0.04e18);
        // non-transferable: wallet → wallet reverts, wallet → protocol (stake) works
        vm.prank(alice);
        vm.expectRevert(DimeToken.TransfersDisabled.selector);
        dimeToken.transfer(bob, 1);
        vm.startPrank(alice);
        dimeToken.approve(address(dime), type(uint256).max);
        dime.stake(0.04e18);
        vm.stopPrank();
        RightsAccount memory r = dime.rightsOf(alice);
        assertEq(r.active, 0.04e18);
        assertEq(r.pending, 0.04e18); // re-stake activates next epoch (no just-in-time staking)
        // cannot unstake more than staked
        vm.prank(alice);
        vm.expectRevert(DimeRights.InsufficientStake.selector);
        dime.unstake(1e18);
    }

    function test_dimeNonTransferableUntilScheduledOpen() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8));
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        vm.prank(alice);
        dime.unstake(0.01e18);
        assertFalse(dimeToken.transfersEnabled());
        vm.prank(alice);
        vm.expectRevert(DimeToken.TransfersDisabled.selector);
        dimeToken.transfer(bob, 1);

        // scheduling needs admin and ≥ 14 days' notice
        uint64 soon = uint64(vm.getBlockTimestamp() + 13 days);
        vm.expectRevert();
        dimeToken.scheduleTransfers(soon);
        vm.prank(admin);
        vm.expectRevert(DimeToken.NoticeTooShort.selector);
        dimeToken.scheduleTransfers(soon);
        uint64 at = uint64(vm.getBlockTimestamp() + 15 days);
        vm.prank(admin);
        dimeToken.scheduleTransfers(at);

        // still locked before the date
        vm.warp(at - 1);
        vm.prank(alice);
        vm.expectRevert(DimeToken.TransfersDisabled.selector);
        dimeToken.transfer(bob, 1);

        // open at the date, permanently (cannot cancel or re-schedule afterwards)
        vm.warp(at);
        assertTrue(dimeToken.transfersEnabled());
        vm.prank(alice);
        dimeToken.transfer(bob, 1);
        assertEq(dimeToken.balanceOf(bob), 1);
        vm.prank(admin);
        vm.expectRevert(DimeToken.AlreadyOpen.selector);
        dimeToken.cancelScheduledTransfers();
    }

    function test_minStake() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8)); // 0.08 DIME auto-staked (0.01 × 4 phase × 2 liquidation; ignores the minimum)
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        vm.startPrank(alice);
        dime.unstake(0.08e18); // fully out
        dimeToken.approve(address(dime), type(uint256).max);
        vm.expectRevert(DimeProtocol.BelowMinStake.selector);
        dime.stake(0.003e18); // below 0.004 minimum
        dime.stake(0.004e18);
        dime.stake(0.001e18); // top-ups fine once above the minimum
        vm.stopPrank();
        assertEq(dime.rightsOf(alice).pending, 0.005e18);
    }

    function test_scheduleCanBeCancelledBeforeOpening() public {
        uint64 at = uint64(vm.getBlockTimestamp() + 15 days);
        vm.prank(admin);
        dimeToken.scheduleTransfers(at);
        vm.prank(admin);
        dimeToken.cancelScheduledTransfers();
        vm.warp(at + 1);
        assertFalse(dimeToken.transfersEnabled());
    }

    function test_onlyProtocolMints() public {
        vm.expectRevert();
        dimeToken.mint(alice, 1e18);
        // admin cannot add a second minter after wiring
        bytes32 minter = dimeToken.MINTER_ROLE();
        vm.prank(admin);
        vm.expectRevert();
        dimeToken.grantRole(minter, admin);
    }

    /* ------------------------------------------------------------------ zero-fee model */
    function test_winCurve_halfOfA3bpWin() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        PriceProof memory cp = _px(P0 + 30e8);
        vm.prank(alice);
        dime.closeOwn(id, cp); // 3 bp = $0.03 gross; pays 3 × 3 / 6 = half
        assertEq(dime.freeBalance(alice), 2e6 + 0.015e6);
        _invariant();
    }

    function test_shortHoldSurcharge_onlyInsideWindow() public {
        Config memory c = _cfg();
        c.shortHoldK = 800;
        c.shortHoldSeconds = 10;
        vm.prank(admin);
        dime.setConfig(c);
        OrderIntent memory it = _intent(alice, 0, 2);
        it.configVersion = 2;
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        bytes32 id = dime.openHouse(it, sig, px);
        vm.warp(vm.getBlockTimestamp() + 5);
        px = _px(P0 + 100e8);
        vm.prank(alice);
        dime.closeOwn(id, px); // 10 bp inside 10 s: k = 8, pays 10 × 10 / 18
        assertEq(dime.freeBalance(alice), 2e6 + 0.1e6 - 44_445); // cut = ceil(0.1 × 8 / 18)

        it = _intent(bob, 0, 2);
        it.configVersion = 2;
        sig = _sign(bobPk, it);
        px = _px(P0);
        vm.prank(relayer);
        id = dime.openHouse(it, sig, px);
        vm.warp(vm.getBlockTimestamp() + 10);
        px = _px(P0 + 100e8);
        vm.prank(bob);
        dime.closeOwn(id, px); // at 10 s the normal k = 3 applies
        assertEq(dime.freeBalance(bob), 2e6 + 0.1e6 - 23_077);
        _invariant();
    }

    function test_liquidation_bufferAt200x_losesWholeMargin() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        it.leverage = 200;
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        bytes32 id = dime.openHouse(it, sig, px);
        assertEq(dime.getPosition(id).liquidationPrice, P0 - 460e8); // 50 bp − 4 bp
        dime.liquidate(id, _px(P0 - 460e8));
        assertEq(dime.freeBalance(alice), 2e6 - 0.1e6); // whole margin lost
        // leverage weighting: 200× earns 0.2 of the rate; phase 1 4×, liquidation 2× → 0.1 × 0.1 × 0.2 × 8
        assertEq(dime.rightsOf(alice).pending, 0.016e18);
        _invariant();
    }

    function test_issuancePhase_startsAtPhase1() public view {
        (uint8 phase, uint256 boost, uint256 liqBoost) = dime.issuancePhase();
        assertEq(phase, 1);
        assertEq(boost, 40_000);
        assertEq(liqBoost, 20_000);
    }

    function test_config_rejectsBufferAtOrAboveMargin() public {
        Config memory c = _cfg();
        c.liqBufferBps = 10; // 10 bp × 1000× = the whole margin
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setConfig(c);
    }

    function test_config_issuanceCanOnlyGoDown() public {
        Config memory base = _cfg();
        Config memory c = base;
        c.dimePerUsdE18 = base.dimePerUsdE18 + 1;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.IssuanceRaised.selector);
        dime.setConfig(c);

        c = _cfg();
        c.emissionDecayTvl = base.emissionDecayTvl + 1;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.IssuanceRaised.selector);
        dime.setConfig(c);

        c = _cfg();
        c.maxMintPerEpoch = base.maxMintPerEpoch + 1;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.IssuanceRaised.selector);
        dime.setConfig(c);

        c = _cfg();
        c.epochSeconds = base.epochSeconds - 1;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.IssuanceRaised.selector);
        dime.setConfig(c);

        // Lowering is allowed, and a lowered value becomes the new ceiling.
        c = _cfg();
        c.dimePerUsdE18 = base.dimePerUsdE18 / 2;
        c.maxMintPerEpoch = base.maxMintPerEpoch / 2;
        c.emissionDecayTvl = base.emissionDecayTvl / 2;
        c.epochSeconds = base.epochSeconds * 2;
        vm.prank(admin);
        dime.setConfig(c);
        assertEq(dime.activeConfig().dimePerUsdE18, base.dimePerUsdE18 / 2);
        c.dimePerUsdE18 = base.dimePerUsdE18;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.IssuanceRaised.selector);
        dime.setConfig(c);
    }

    function test_stakerShareFloor() public {
        Config memory c = _cfg();
        c.distributionShareBps = 499;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setConfig(c);
        c.distributionShareBps = 500;
        vm.prank(admin);
        dime.setConfig(c);
        assertEq(dime.activeConfig().distributionShareBps, 500);
    }

    function test_reserveFloorCannotRise() public {
        Config memory c = _cfg();
        c.distributionReserveFloor = c.distributionReserveFloor + 1;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setConfig(c);
        c.distributionReserveFloor = 5e6;
        vm.prank(admin);
        dime.setConfig(c);
        c.distributionReserveFloor = 10e6; // back up to the deploy value is still not allowed
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setConfig(c);
    }

    function test_withdrawKeepsStakersAccruedShare() public {
        // epoch 1: alice's loss gives her rights, active from epoch 2
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8));
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        // epoch 2: bob loses 0.10 → stakers (20%) are owed 0.02, kept above the 10 floor
        id = _openHouse(bobPk, bob, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8));
        assertEq(dime.stakersAccrued(), 0.02e6);
        uint256 reserve = dime.houseStats().reserve;
        vm.prank(admin);
        vm.expectRevert(DimeProtocol.ReserveLocked.selector);
        dime.withdrawExcessReserve(reserve - 10.02e6 + 1, admin);
        vm.prank(admin);
        dime.withdrawExcessReserve(reserve - 10.02e6, admin);
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        assertEq(dime.rightsOf(alice).claimable, 0.02e6); // paid in full despite the withdrawal
        _invariant();
    }

    function test_unstakeCooldownOnlyAfterTransfersOpen() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8));
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        // non-transferable: instant
        vm.prank(alice);
        dime.unstake(0.02e18);
        assertEq(dimeToken.balanceOf(alice), 0.02e18);
        // open transfers, then unstaking waits 7 days and stops earning at once
        vm.prank(admin);
        dimeToken.scheduleTransfers(uint64(vm.getBlockTimestamp() + 14 days));
        vm.warp(vm.getBlockTimestamp() + 14 days);
        vm.prank(alice);
        dime.unstake(0.02e18);
        assertEq(dimeToken.balanceOf(alice), 0.02e18);
        assertEq(dime.rightsOf(alice).active, 0.04e18);
        vm.prank(alice);
        vm.expectRevert(DimeProtocol.CoolingDown.selector);
        dime.withdrawUnstaked();
        vm.warp(vm.getBlockTimestamp() + 7 days);
        vm.prank(alice);
        dime.withdrawUnstaked();
        assertEq(dimeToken.balanceOf(alice), 0.04e18);
        vm.prank(alice);
        vm.expectRevert(DimeProtocol.BadSize.selector);
        dime.withdrawUnstaked();
    }

    function test_addStakerRewards_paidInFullToStakers() public {
        // nobody staked yet: added rewards fall into the reserve at funding
        usdc.mint(carol, 10e6);
        vm.startPrank(carol);
        usdc.approve(address(dime), type(uint256).max);
        dime.addStakerRewards(1e6);
        vm.stopPrank();
        bytes32 id = _openHouse(alicePk, alice, 0, P0);
        dime.liquidate(id, _px(P0 - 90e8)); // alice gets rights, active next epoch
        uint256 reserveBefore = dime.houseStats().reserve;
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        assertEq(dime.houseStats().reserve, reserveBefore + 1e6);
        assertEq(dime.pendingStakerRewards(), 0);
        _invariant();
        // alice is now staked: 2 USDG added mid-epoch all reach her, with no 30/70 split
        vm.prank(carol);
        dime.addStakerRewards(2e6);
        _invariant();
        vm.warp(vm.getBlockTimestamp() + 3600);
        dime.fundAndAdvance();
        assertApproxEqAbs(dime.rightsOf(alice).claimable, 2e6, 1);
        vm.prank(alice);
        dime.claim();
        _invariant();
    }
}
