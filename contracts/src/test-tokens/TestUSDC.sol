// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title TestUSDC — TESTNET ONLY. Worthless test collateral with a public faucet.
/// @notice Never deploy or reference this on mainnet. The deploy script refuses on chain 143.
contract TestUSDC is ERC20 {
    uint256 public constant FAUCET_AMOUNT = 25e6;

    constructor() ERC20("DIME Test USDC (testnet, no value)", "tUSDC") {}

    function decimals() public pure override returns (uint8) { return 6; }

    function faucet() external { _mint(msg.sender, FAUCET_AMOUNT); }

    function mint(address to, uint256 amount) external { _mint(to, amount); }
}
