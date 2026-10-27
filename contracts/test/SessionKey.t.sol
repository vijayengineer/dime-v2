// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DimeTest} from "./Dime.t.sol";
import {DimeProtocol} from "../src/DimeProtocol.sol";

/// Session keys: trading-only keys per account (up to 5), for paired browsers, terminals, bots and one-tap trading.
contract SessionKeyTest is DimeTest {
    uint256 sessionPk = 0x5E55;
    address session;

    function setUp() public override {
        super.setUp();
        session = vm.addr(sessionPk);
    }

    function _closeReq(address user, bytes32 id) internal returns (CloseRequest memory) {
        return CloseRequest({user: user, positionId: id, expiry: uint64(vm.getBlockTimestamp() + 30), nonce: nonceSeq++});
    }

    function _signClose(uint256 pk, CloseRequest memory r) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(keccak256("CloseRequest(address user,bytes32 positionId,uint64 expiry,uint256 nonce)"), r));
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", _domain(address(dime), block.chainid), sh)));
        return abi.encodePacked(rr, s, v);
    }

    function _signSession(uint256 pk, address user, address key, uint64 expiry, uint256 nonce) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(keccak256("SessionKey(address user,address key,uint64 expiry,uint256 nonce)"), user, key, expiry, nonce));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", _domain(address(dime), block.chainid), sh)));
        return abi.encodePacked(r, s, v);
    }

    function test_sessionKeyOpensAndClosesButCannotWithdraw() public {
        vm.prank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 days));
        DimeProtocol.SessionKey[] memory ks = dime.sessionKeysOf(alice);
        assertEq(ks.length, 1);
        assertEq(ks[0].key, session);
        assertEq(ks[0].expiry, block.timestamp + 1 days);

        bytes32 id = _openHouse(sessionPk, alice, 0, P0); // signed by the session key, not alice
        assertEq(dime.positionOf(alice).id, id);

        CloseRequest memory r = _closeReq(alice, id);
        bytes memory sig = _signClose(sessionPk, r);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        dime.close(r, sig, px);
        assertEq(dime.positionOf(alice).collateral, 0);

        // Withdrawals are msg.sender-only: the session key holds no balance and can't move alice's.
        vm.prank(session);
        vm.expectRevert(DimeProtocol.InsufficientFree.selector);
        dime.withdraw(1);
        _invariant();
    }

    function test_walletSignatureStillWorks() public {
        vm.prank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 days));
        _openHouse(alicePk, alice, 1, P0);
    }

    function test_expiredOrRevokedKeyRejected() public {
        vm.prank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 100));
        vm.warp(block.timestamp + 101);
        OrderIntent memory it = _intent(alice, 0, 2);
        bytes memory sig = _sign(sessionPk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, sig, px);

        vm.startPrank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 days));
        dime.setSessionKey(address(0), 0); // revoke all
        vm.stopPrank();
        assertEq(dime.sessionKeysOf(alice).length, 0);
        it = _intent(alice, 0, 2);
        sig = _sign(sessionPk, it);
        px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, sig, px);
    }

    function test_keyOnlyActsForItsOwnAccount() public {
        vm.prank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 days));
        OrderIntent memory it = _intent(bob, 0, 2); // bob never authorised it
        bytes memory sig = _sign(sessionPk, it);
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, sig, px);
    }

    function test_badSessionParamsRejected() public {
        vm.startPrank(alice);
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setSessionKey(session, uint64(block.timestamp)); // already expired
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setSessionKey(session, uint64(block.timestamp + 31 days)); // too long
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setSessionKey(alice, uint64(block.timestamp + 1 days)); // itself
        vm.stopPrank();
    }

    function test_gaslessRegistrationBySignature() public {
        uint64 exp = uint64(block.timestamp + 7 days);
        bytes memory sig = _signSession(alicePk, alice, session, exp, 777);
        vm.prank(relayer); // anyone may submit
        dime.setSessionKeyBySig(alice, session, exp, 777, sig);
        assertEq(dime.sessionKeysOf(alice)[0].key, session);

        vm.expectRevert(DimeProtocol.NonceUsed.selector);
        dime.setSessionKeyBySig(alice, session, exp, 777, sig); // no replay

        bytes memory forged = _signSession(bobPk, alice, address(0xBEEF), exp, 778);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.setSessionKeyBySig(alice, address(0xBEEF), exp, 778, forged);

        // The session key itself can't extend or replace itself.
        bytes memory self = _signSession(sessionPk, alice, session, exp + 1, 779);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.setSessionKeyBySig(alice, session, exp + 1, 779, self);
    }

    function test_severalKeysEachWorkAndRevokeIndependently() public {
        uint256 desktopPk = 0xDE5C;
        address desktop = vm.addr(desktopPk);
        vm.startPrank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 days)); // e.g. an agent
        dime.setSessionKey(desktop, uint64(block.timestamp + 7 days)); // a paired browser
        dime.setSessionKey(desktop, uint64(block.timestamp + 8 days)); // renewing doesn't add a second entry
        vm.stopPrank();
        assertEq(dime.sessionKeysOf(alice).length, 2);

        bytes32 id = _openHouse(desktopPk, alice, 0, P0);
        CloseRequest memory r = _closeReq(alice, id);
        bytes memory sig = _signClose(sessionPk, r); // the other key closes it
        PriceProof memory px = _px(P0);
        vm.prank(relayer);
        dime.close(r, sig, px);

        vm.prank(alice);
        dime.setSessionKey(desktop, 0); // unpair the browser only
        DimeProtocol.SessionKey[] memory ks = dime.sessionKeysOf(alice);
        assertEq(ks.length, 1);
        assertEq(ks[0].key, session);
        OrderIntent memory it = _intent(alice, 0, 2);
        sig = _sign(desktopPk, it);
        px = _px(P0);
        vm.prank(relayer);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.openHouse(it, sig, px);
        _invariant();
    }

    function test_keyLimitCountsOnlyLiveKeys() public {
        vm.startPrank(alice);
        for (uint256 i = 1; i <= 5; i++) dime.setSessionKey(address(uint160(0x1000 + i)), uint64(block.timestamp + i * 100));
        vm.expectRevert(DimeProtocol.BadConfig.selector);
        dime.setSessionKey(address(0x2000), uint64(block.timestamp + 1 days));
        vm.warp(block.timestamp + 250); // the first two expire and are pruned on the next add
        dime.setSessionKey(address(0x2000), uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(dime.sessionKeysOf(alice).length, 4);
    }
}
