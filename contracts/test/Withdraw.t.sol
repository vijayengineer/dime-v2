// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {DimeTest} from "./Dime.t.sol";
import {DimeProtocol} from "../src/DimeProtocol.sol";

/// Gasless signed withdrawals: signed by the wallet or a live session key, submitted by anyone, paid to the user only.
contract WithdrawBySigTest is DimeTest {
    uint256 sessionPk = 0x5E55;
    address session;
    address stranger = makeAddr("stranger");

    function setUp() public override {
        super.setUp();
        session = vm.addr(sessionPk);
    }

    function _req(address user, uint256 amount) internal returns (WithdrawRequest memory) {
        return WithdrawRequest({user: user, amount: amount, expiry: uint64(vm.getBlockTimestamp() + 60), nonce: nonceSeq++});
    }

    function _signW(uint256 pk, WithdrawRequest memory r) internal view returns (bytes memory) {
        bytes32 sh = keccak256(abi.encode(keccak256("WithdrawRequest(address user,uint256 amount,uint64 expiry,uint256 nonce)"), r));
        (uint8 v, bytes32 rr, bytes32 s) = vm.sign(pk, keccak256(abi.encodePacked("\x19\x01", _domain(address(dime), block.chainid), sh)));
        return abi.encodePacked(rr, s, v);
    }

    function test_walletSignedWithdrawalPaysTheUserWhoeverSubmits() public {
        WithdrawRequest memory r = _req(alice, 0.5e6);
        bytes memory sig = _signW(alicePk, r);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(stranger);
        dime.withdrawBySig(r, sig);
        assertEq(usdc.balanceOf(alice), before + 0.5e6);
        assertEq(usdc.balanceOf(stranger), 0);
        assertEq(dime.freeBalance(alice), 1.5e6);
        _invariant();
    }

    function test_sessionKeyWithdrawsToTheOwnerOnly() public {
        vm.prank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 days));
        WithdrawRequest memory r = _req(alice, 1e6);
        bytes memory sig = _signW(sessionPk, r);
        dime.withdrawBySig(r, sig);
        assertEq(usdc.balanceOf(session), 0);
        assertEq(usdc.balanceOf(alice), 1e6);
        _invariant();
    }

    function test_rejectsReplayExpiryWrongSignerAndOverdraw() public {
        WithdrawRequest memory r = _req(alice, 0.1e6);
        bytes memory sig = _signW(alicePk, r);
        dime.withdrawBySig(r, sig);
        vm.expectRevert(DimeProtocol.NonceUsed.selector);
        dime.withdrawBySig(r, sig);

        WithdrawRequest memory e = _req(alice, 0.1e6);
        bytes memory es = _signW(alicePk, e);
        vm.warp(e.expiry + 1);
        vm.expectRevert(DimeProtocol.Expired.selector);
        dime.withdrawBySig(e, es);

        WithdrawRequest memory b = _req(alice, 0.1e6);
        bytes memory bs = _signW(bobPk, b); // bob can't sign for alice
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.withdrawBySig(b, bs);

        WithdrawRequest memory o = _req(alice, 100e6);
        bytes memory os = _signW(alicePk, o);
        vm.expectRevert(DimeProtocol.InsufficientFree.selector);
        dime.withdrawBySig(o, os);
    }

    function test_revokedOrExpiredSessionKeyCannotWithdraw() public {
        vm.prank(alice);
        dime.setSessionKey(session, uint64(block.timestamp + 1 hours));
        vm.prank(alice);
        dime.setSessionKey(session, 0); // revoke
        WithdrawRequest memory r = _req(alice, 0.1e6);
        bytes memory sig = _signW(sessionPk, r);
        vm.expectRevert(DimeProtocol.BadSignature.selector);
        dime.withdrawBySig(r, sig);
    }

    function test_nonceIsSharedWithOrders() public {
        bytes32 id = _openHouse(alicePk, alice, 0, P0); // uses nonce nonceSeq - 1
        assertTrue(id != bytes32(0));
        WithdrawRequest memory r = WithdrawRequest({user: alice, amount: 0.1e6, expiry: uint64(block.timestamp + 60), nonce: nonceSeq - 1});
        bytes memory sig = _signW(alicePk, r);
        vm.expectRevert(DimeProtocol.NonceUsed.selector);
        dime.withdrawBySig(r, sig);
    }

    function test_worksInEveryProtocolState() public {
        vm.prank(admin);
        dime.setProtocolState(ProtocolState.WIND_DOWN);
        WithdrawRequest memory r = _req(alice, 0.2e6);
        bytes memory sig = _signW(alicePk, r);
        dime.withdrawBySig(r, sig);
        assertEq(usdc.balanceOf(alice), 0.2e6);
    }
}
