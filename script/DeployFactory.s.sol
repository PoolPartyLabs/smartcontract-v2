// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FactoryDeployment} from "./FactoryDeployment.sol";

/// @title DeployFactory
/// @notice Deploys the protocol stack and the Fund Factory on the current chain (Arbitrum One or Robinhood Chain), with
///         the addresses of docs/INTEGRATIONS.md. Run it with the same broadcaster on every chain: the factory lands at
///         the same address everywhere (docs/DEPLOYMENT.md).
/// @dev Environment: `PROTOCOL_RECIPIENT` (fee wallet, DEC-106, LC-132 OPEN), `ADAPTER_GUARDIAN` (ruling 2026-09-29,
///      Q17-2b), `REGISTRY_OWNER` (hub ManagerRegistry owner, LC-142). Fork first:
///      `forge script script/DeployFactory.s.sol --fork-url $ARBITRUM_RPC_URL --sender <operator>`, then the same
///      command with `--rpc-url` and `--broadcast` and the operator's keystore.
contract DeployFactory is Script, FactoryDeployment {
    function run() external returns (Deployment memory d) {
        address recipient = vm.envAddress("PROTOCOL_RECIPIENT");
        address guardian = vm.envAddress("ADAPTER_GUARDIAN");
        address registryOwner = vm.envAddress("REGISTRY_OWNER");

        vm.startBroadcast();
        d = _deployProtocol(recipient, guardian, registryOwner);
        vm.stopBroadcast();

        console.log("chain id", block.chainid);
        console.log("Create3Deployer", d.create3Deployer);
        console.log("SpokeCrossChainLib", d.spokeCrossChainLib);
        console.log("SpokeUnwindLib", d.spokeUnwindLib);
        console.log("CoreVaultLogic", d.coreVaultLogic);
        console.log("CoreVaultTransitLogic", d.coreVaultTransitLogic);
        console.log("CoreVaultIncomeLogic", d.coreVaultIncomeLogic);
        console.log("CoreVaultPayoutLogic", d.coreVaultPayoutLogic);
        console.log("ManagerRegistry", d.managerRegistry);
        console.log("ChainlinkPriceSource", d.priceSource);
        console.log("FundFactory", address(d.factory));
        console.log("TransitEscrow implementation", d.factory.transitEscrowImplementation());
        console.logBytes32(d.factory.creationCodeHash(d.factory.ROLE_CORE_VAULT()));
        console.logBytes32(d.factory.creationCodeHash(d.factory.ROLE_SPOKE_VAULT()));
    }
}
