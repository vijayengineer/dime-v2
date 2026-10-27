// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DimeTest} from "./Dime.t.sol";
import {DimeProtocol} from "../src/DimeProtocol.sol";
import {OperatorPriceVerifier} from "../src/oracle/OperatorPriceVerifier.sol";

/// BTC and NVDA side by side: per-market enablement, prices verified for the position's market,
/// and the concentration limit applied per market.
contract MarketsTest is DimeTest {
    bytes32 constant NVDA = keccak256("NVDA-USD");
    uint256 constant N0 = 200e8; // $200.00000000

    function _pxFor(bytes32 market, uint256 price) internal view returns (PriceProof memory) {
        uint64 ts = uint64(vm.getBlockTimestamp() * 1000);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(reporterPk, oracle.digest(market, price, ts));
        return PriceProof(abi.encode(price, ts, abi.encodePacked(r, s, v)));
    }

    function _nvdaIntent(address user, uint8 side, uint8 mask) internal returns (OrderIntent memory it) {
        it = _intent(user, side, mask);
        it.market = NVDA;
        it.priceLimit = side == 0 ? uint128(N0 * 2) : uint128(1);
    }

    function _openNvda(uint256 pk, address user, uint8 side) internal returns (bytes32 id) {
        OrderIntent memory it = _nvdaIntent(user, side, 2);
        bytes memory sig = _sign(pk, it);
        PriceProof memory px = _pxFor(NVDA, N0);
        vm.prank(relayer);
        id = dime.openHouse(it, sig, px);
    }

    function _enableNvda() internal {
        vm.prank(admin);
        dime.setMarketEnabled(NVDA, true);
    }

    function test_btcEnabledAtDeploy_nvdaNot() public {
        assertTrue(dime.marketEnabled(MKT));
        assertFalse(dime.marketEnabled(NVDA));
        OrderIntent memory it = _nvdaIntent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _pxFor(NVDA, N0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadMarket.selector);
        dime.openHouse(it, sig, px);
    }

    function test_onlyAdminEnablesMarkets() public {
        vm.prank(relayer);
        vm.expectRevert();
        dime.setMarketEnabled(NVDA, true);
        vm.prank(guardian);
        vm.expectRevert();
        dime.setMarketEnabled(NVDA, true);
    }

    function test_guardianCanDisableButNotEnable() public {
        _enableNvda();
        vm.prank(guardian);
        dime.setMarketEnabled(NVDA, false);
        assertFalse(dime.marketEnabled(NVDA));
        vm.prank(relayer);
        vm.expectRevert();
        dime.setMarketEnabled(MKT, false);
    }

    function test_nvdaOpensAndSettlesAtNvdaPrice() public {
        _enableNvda();
        bytes32 id = _openNvda(alicePk, alice, 0);
        assertEq(dime.getPosition(id).market, NVDA);
        assertEq(dime.getPosition(id).entryPrice, N0);
        // A BTC-signed price can't settle an NVDA position.
        PriceProof memory btc = _px(N0 + 0.1e8);
        vm.prank(alice);
        vm.expectRevert(OperatorPriceVerifier.BadReporter.selector);
        dime.closeOwn(id, btc);
        uint256 freeBefore = dime.freeBalance(alice);
        PriceProof memory px = _pxFor(NVDA, N0 + 0.1e8); // +5 bp
        vm.prank(alice);
        dime.closeOwn(id, px);
        assertGt(dime.freeBalance(alice), freeBefore + 0.1e6, "won on the NVDA move");
        _invariant();
    }

    function test_nvdaPriceCannotOpenBtc() public {
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(alicePk, it);
        PriceProof memory px = _pxFor(NVDA, P0);
        vm.prank(relayer);
        vm.expectRevert(OperatorPriceVerifier.BadReporter.selector);
        dime.openHouse(it, sig, px);
    }

    function test_disablingStopsOpensButPositionsStillSettle() public {
        _enableNvda();
        bytes32 id = _openNvda(alicePk, alice, 1);
        vm.prank(admin);
        dime.setMarketEnabled(NVDA, false);
        OrderIntent memory it = _nvdaIntent(bob, 0, 2);
        bytes memory sig = _sign(bobPk, it);
        PriceProof memory open = _pxFor(NVDA, N0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadMarket.selector);
        dime.openHouse(it, sig, open);
        PriceProof memory px = _pxFor(NVDA, N0);
        vm.prank(alice);
        dime.closeOwn(id, px);
        assertEq(dime.getPosition(id).user, address(0), "settled");
        _invariant();
    }

    function test_concentrationLimitIsPerMarket() public {
        _enableNvda();
        // Reserve $10 × 200 = $2,000 net per market; each 0.1 × 1000 position is $100 of notional.
        vm.startPrank(admin);
        Config memory c = dime.activeConfig();
        c.houseMaxNetNotionalMultiple = 15; // $150 net per market: one $100 long fits, a second doesn't
        dime.setConfig(c);
        vm.stopPrank();
        OrderIntent memory a = _intent(alice, 0, 2);
        a.configVersion = 2;
        bytes memory as_ = _sign(alicePk, a);
        PriceProof memory bpx = _px(P0);
        vm.prank(relayer);
        dime.openHouse(a, as_, bpx);
        // A long on NVDA isn't blocked by the BTC long.
        OrderIntent memory b = _nvdaIntent(bob, 0, 2);
        b.configVersion = 2;
        bytes memory bs = _sign(bobPk, b);
        PriceProof memory npx = _pxFor(NVDA, N0);
        vm.prank(relayer);
        dime.openHouse(b, bs, npx);
        assertEq(dime.netDirectionalOf(MKT), 100e6);
        assertEq(dime.netDirectionalOf(NVDA), 100e6);
        assertEq(dime.houseStats().netDirectionalNotional, 200e6);
        // A second BTC long would take BTC to $200 net, over the $150 limit.
        OrderIntent memory c2 = _intent(carol, 0, 2);
        c2.configVersion = 2;
        bytes memory cs = _sign(carolPk, c2);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.ConcentrationLimit.selector);
        dime.openHouse(c2, cs, bpx);
    }

    function test_matchedPairMustShareMarket() public {
        _enableNvda();
        OrderIntent memory l = _intent(alice, 0, 1);
        OrderIntent memory s = _nvdaIntent(bob, 1, 1);
        bytes memory ls = _sign(alicePk, l);
        bytes memory ss = _sign(bobPk, s);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.IncompatiblePair.selector);
        dime.openMatched(l, ls, s, ss, px);
    }
}
