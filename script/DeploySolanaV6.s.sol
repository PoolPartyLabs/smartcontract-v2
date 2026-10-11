// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SolanaV6Deployment} from "./SolanaV6Deployment.sol";

/// @notice DEC-188/198: rehearse the v6 factory on each EVM chain without broadcasting.
/// @dev DEC-191/199: CCTP adapter/connector and receiver are per-Fund, created by createFundV6.
contract DeploySolanaV6 is Script, SolanaV6Deployment {
    function run() external returns (V6Deployment memory result) {
        address recipient = vm.envAddress("PROTOCOL_RECIPIENT");
        address guardian = vm.envAddress("ADAPTER_GUARDIAN");
        address signer = vm.envAddress("API_SIGNER");
        address owner = vm.envAddress("REGISTRY_OWNER");
        uint256 rawMaxAge = vm.envUint("SOLANA_PRICE_MAX_AGE");
        if (rawMaxAge > type(uint32).max) revert InvalidDeploymentConfiguration();
        uint32 maxAge = uint32(rawMaxAge);
        vm.startBroadcast();
        result = _deployV6(recipient, guardian, owner, signer, maxAge);
        vm.stopBroadcast();
        console.log("chain id", block.chainid);
        console.log("FundFactoryV6", address(result.factory));
        console.log("ManagerRegistry", result.common.managerRegistry);
        console.log("SolanaPriceSourceV6", result.common.priceSource);
        console.log("CoreVaultCctpLogic", result.cctpLogic);
        console.logBytes32(keccak256(result.coreCode));
    }
}
