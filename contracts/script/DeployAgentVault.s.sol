// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DimeAgentVault, IDimeForVault} from "../src/agents/DimeAgentVault.sol";

/// @notice Deploys one DimeAgentVault next to an existing DimeProtocol.
/// Usage (keystore signer, never a raw key on the command line):
///   forge script contracts/script/DeployAgentVault.s.sol --rpc-url $RPC --account dime-deployer --broadcast
/// Env:
///   DIME_PROTOCOL, DIME_COLLATERAL           the protocol and its collateral token
///   VAULT_OWNER, VAULT_AGENT                 curator (multisig) and the agent's signing wallet
///   VAULT_FEE_RECIPIENT                      optional, defaults to the owner
///   VAULT_NAME, VAULT_SYMBOL                 optional
///   VAULT_MAX_LEVERAGE (500), VAULT_MAX_MARGIN_BPS (500 = 5% of the vault per trade),
///   VAULT_MAX_HOLD_SECONDS (3600), VAULT_PERF_FEE_BPS (1000), VAULT_DEPOSIT_CAP (100_000e6)
/// After deploying, the DIME admin must call setFundingCapOverride(vault, cap) (the per-wallet cap counts
/// lifetime deposits, so a pooled vault needs its own), and setAllowlisted([vault], true) if the allowlist is on.
/// The agent wallet must accept the Terms of Use and create an API key (backend/src/agents/example.ts setup).
contract DeployAgentVault is Script {
    function run() external returns (DimeAgentVault vault) {
        DimeAgentVault.Policy memory p = DimeAgentVault.Policy({
            maxLeverage: uint16(vm.envOr("VAULT_MAX_LEVERAGE", uint256(500))),
            maxMarginBps: uint16(vm.envOr("VAULT_MAX_MARGIN_BPS", uint256(500))),
            maxHoldSeconds: uint32(vm.envOr("VAULT_MAX_HOLD_SECONDS", uint256(3600))),
            performanceFeeBps: uint16(vm.envOr("VAULT_PERF_FEE_BPS", uint256(1000))),
            depositCap: uint128(vm.envOr("VAULT_DEPOSIT_CAP", uint256(100_000e6)))
        });
        address owner = vm.envAddress("VAULT_OWNER");
        vm.startBroadcast();
        vault = new DimeAgentVault(
            IDimeForVault(vm.envAddress("DIME_PROTOCOL")),
            IERC20(vm.envAddress("DIME_COLLATERAL")),
            vm.envOr("VAULT_NAME", string("DIME Agent Vault #1")),
            vm.envOr("VAULT_SYMBOL", string("dAV1")),
            owner,
            vm.envAddress("VAULT_AGENT"),
            vm.envOr("VAULT_FEE_RECIPIENT", owner),
            p
        );
        vm.stopBroadcast();
        console2.log("DimeAgentVault", address(vault));
    }
}
