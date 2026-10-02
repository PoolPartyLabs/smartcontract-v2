// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";

/// @notice The deployment's library linking (script/FactoryDeployment.sol): the Spoke Vault creation code the factory
///         stores and pins by hash is linked to every library step 2 deploys, and a library missing from a link list
///         fails by name (DEC-131: the vault's code is split into linked libraries; DEC-058: their addresses are part
///         of the pinned creation code).
contract FactoryDeploymentLinkingTest is Test, FactoryDeployment {
    function test_DEC131_spokeVaultCodeLinksEveryDeployedLibrary() public {
        Deployment memory d;
        _deployLibraries(false, d);
        string memory code = vm.toString(_spokeVaultCreationCode(d));
        assertTrue(d.spokeCrossChainLib.code.length != 0, "SpokeCrossChainLib deployed");
        assertTrue(vm.contains(code, _bareHex(d.spokeCrossChainLib)), "SpokeCrossChainLib linked");
        assertTrue(d.spokeUnwindLib.code.length != 0, "SpokeUnwindLib deployed");
        assertTrue(vm.contains(code, _bareHex(d.spokeUnwindLib)), "SpokeUnwindLib linked");
        assertFalse(vm.contains(code, "__$"), "no placeholder left");
    }

    function test_DEC131_hubAlsoDeploysTheCoreVaultLibraries() public {
        Deployment memory d;
        _deployLibraries(true, d);
        string memory code = vm.toString(_coreVaultCreationCode(d));
        assertTrue(d.coreVaultLogic.code.length != 0, "CoreVaultLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultLogic)), "CoreVaultLogic linked");
        assertTrue(d.coreVaultTransitLogic.code.length != 0, "CoreVaultTransitLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultTransitLogic)), "CoreVaultTransitLogic linked");
        assertFalse(vm.contains(code, "__$"), "no placeholder left");
        // Library into library: the transit library calls CoreVaultLogic through its own linked address.
        assertTrue(vm.contains(vm.toString(d.coreVaultTransitLogic.code), _bareHex(d.coreVaultLogic)));
    }

    /// @notice `CreateFund` links the Core Vault code to the predicted addresses, so they must be where step 2 deploys.
    function test_DEC131_predictedLibraryAddressesAreTheDeployedOnes() public {
        Deployment memory predicted = _libraryAddresses(true);
        Deployment memory d;
        _deployLibraries(true, d);
        assertEq(abi.encode(predicted), abi.encode(d), "every library at its predicted address");
        assertEq(keccak256(_coreVaultCreationCode(predicted)), keccak256(_coreVaultCreationCode(d)));
    }

    function test_DEC131_aLibraryMissingFromTheLinkListRevertsByName() public {
        vm.expectRevert(abi.encodeWithSelector(UnlinkedLibrary.selector, SPOKE_VAULT_ARTIFACT));
        this.linkSpokeVaultWithoutLibraries();
    }

    function linkSpokeVaultWithoutLibraries() external view returns (bytes memory) {
        return _linked(SPOKE_VAULT_ARTIFACT, new string[](0), new address[](0));
    }

    /// @dev Lowercase hex of `a` without the 0x prefix, as it appears inside linked bytecode.
    function _bareHex(address a) internal pure returns (string memory) {
        return vm.replace(vm.toLowercase(vm.toString(a)), "0x", "");
    }
}
