// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IPriceVerifier} from "../interfaces/IDime.sol";

/// @title OperatorPriceVerifier — OPERATOR-CONTROLLED reference (testnet / founder-only commissioning)
/// @notice A signature from a REPORTER proves who signed a price, NOT that the price is fair.
///         `isIndependentOracle()` returns false so UIs and manifests must label it.
///         Not acceptable as the oracle for public real-money trading (docs/STATUS.md).
/// @dev payload = abi.encode(uint256 price, uint64 tsMs, bytes signature)
///      signed message = keccak256(abi.encode(TAG, chainid, address(this), market, price, tsMs)), EIP-191 prefixed.
contract OperatorPriceVerifier is IPriceVerifier, AccessControl {
    bytes32 public constant REPORTER_ROLE = keccak256("REPORTER_ROLE");
    bytes32 public constant TAG = keccak256("DIME_OPERATOR_PRICE_V1");

    error BadReporter();

    constructor(address admin, address reporter) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        if (reporter != address(0)) _grantRole(REPORTER_ROLE, reporter);
    }

    function digest(bytes32 market, uint256 price, uint64 tsMs) public view returns (bytes32) {
        return MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(TAG, block.chainid, address(this), market, price, tsMs)));
    }

    function verify(bytes32 market, bytes calldata payload) external view returns (uint256 price, uint64 tsMs) {
        bytes memory sig;
        (price, tsMs, sig) = abi.decode(payload, (uint256, uint64, bytes));
        address signer = ECDSA.recover(digest(market, price, tsMs), sig);
        if (!hasRole(REPORTER_ROLE, signer)) revert BadReporter();
    }

    function isIndependentOracle() external pure returns (bool) { return false; }
    function oracleKind() external pure returns (string memory) { return "OPERATOR_SIGNED_COMMISSIONING"; }
}
