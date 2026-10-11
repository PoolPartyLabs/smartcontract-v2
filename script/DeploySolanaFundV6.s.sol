// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {FundFactoryV6} from "../src/factory/FundFactoryV6.sol";

/// @notice DEC-190/191/200: simulate reviewed, Manager-signed creation calldata, never invent a binding.
/// @dev The factory creates Core v6, receiver, registry, CCTP adapter/connector and Hub adapters atomically.
contract DeploySolanaFundV6 is Script {
    error InvalidCreationRequest();
    error CreationFailed(bytes reason);
    /// @notice `arbitrum.approvedFactory` in `script/solana-v6-addresses.json` is still the zero-address placeholder:
    ///         no reviewed v6 factory identity has been pinned, so no Fund creation is simulated or sent.
    error FactoryNotApproved();
    /// @notice `SOLANA_V6_FACTORY` is not the factory pinned in the manifest.
    error FactoryNotPinned(address supplied, address approved);

    function run() external {
        if (block.chainid != 42_161) revert InvalidCreationRequest();
        string memory manifest = vm.readFile("script/solana-v6-addresses.json");
        // CR-35: the placeholder is the zero address (JSON null made parseJsonAddress fail with an opaque error).
        address approvedFactory = vm.parseJsonAddress(manifest, ".arbitrum.approvedFactory");
        if (approvedFactory == address(0)) revert FactoryNotApproved();
        address factory = vm.envAddress("SOLANA_V6_FACTORY");
        if (factory != approvedFactory) revert FactoryNotPinned(factory, approvedFactory);
        bytes memory request = vm.parseBytes(vm.readFile(vm.envString("SOLANA_V6_CREATION_CALLDATA_FILE")));
        if (
            factory.code.length == 0 || request.length < 4
                || bytes4(request) != FundFactoryV6.createFundV6Committed.selector
        ) {
            revert InvalidCreationRequest();
        }
        vm.startBroadcast();
        (bool success, bytes memory result) = factory.call(request);
        vm.stopBroadcast();
        if (!success) revert CreationFailed(result);
        console.log("Fund creation return-data hash");
        console.logBytes32(keccak256(result));
    }
}
