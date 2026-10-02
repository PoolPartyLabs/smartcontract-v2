// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {DeployFactory} from "../../../script/DeployFactory.s.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";

/// @notice The deployment's library linking (script/FactoryDeployment.sol): the Spoke Vault creation code the factory
///         stores and pins by hash is linked to every library step 2 deploys, and a library missing from a link list
///         fails by name (DEC-131: the vault's code is split into linked libraries; DEC-058: their addresses are part
///         of the pinned creation code).
contract FactoryDeploymentLinkingTest is Test, FactoryDeployment {
    function test_DEC131_fullHubFactoryThroughDeployScript() public {
        _assertScriptDeployment(ARBITRUM);
    }

    function test_DEC131_fullSpokeFactoryThroughDeployScript() public {
        _assertScriptDeployment(ROBINHOOD);
    }

    function _assertScriptDeployment(uint256 chainId) internal {
        vm.chainId(chainId);
        IFundFactory.ProtocolWiring memory wiring = _chainWiring(chainId);
        vm.etch(wiring.baseToken, hex"00");
        vm.etch(wiring.acrossSpokePool, hex"00");
        vm.etch(wiring.wormholeCore, hex"00");
        vm.etch(wiring.uniswapV4PoolManager, hex"00");
        vm.etch(wiring.permit2, hex"00");
        vm.etch(wiring.uniswapV3Factory, hex"00");
        if (chainId == ARBITRUM) {
            vm.etch(wiring.aaveV3Pool, hex"00");
            vm.mockCall(ARB_ETH_USD_FEED, abi.encodeWithSignature("decimals()"), abi.encode(uint8(8)));
        }
        vm.mockCall(
            wiring.uniswapV4PositionManager,
            abi.encodeWithSignature("poolManager()"),
            abi.encode(wiring.uniswapV4PoolManager)
        );
        vm.mockCall(
            wiring.uniswapV4StateView, abi.encodeWithSignature("poolManager()"), abi.encode(wiring.uniswapV4PoolManager)
        );
        vm.mockCall(wiring.uniswapV4PositionManager, abi.encodeWithSignature("permit2()"), abi.encode(wiring.permit2));
        vm.mockCall(
            wiring.uniswapV3SwapRouter02, abi.encodeWithSignature("factory()"), abi.encode(wiring.uniswapV3Factory)
        );
        vm.mockCall(wiring.uniswapV3QuoterV2, abi.encodeWithSignature("factory()"), abi.encode(wiring.uniswapV3Factory));
        vm.setEnv("PROTOCOL_RECIPIENT", vm.toString(address(100)));
        vm.setEnv("ADAPTER_GUARDIAN", vm.toString(address(101)));
        vm.setEnv("API_SIGNER", vm.toString(address(102)));
        vm.setEnv("REGISTRY_OWNER", vm.toString(address(102)));
        DeployFactory script = new DeployFactory();
        Deployment memory deployed = script.run();
        Deployment memory predicted = _libraryAddresses(chainId == ARBITRUM);
        assertGt(address(deployed.factory).code.length, 0, "factory deployed through run()");
        assertGt(deployed.factory.transitEscrowImplementation().code.length, 0, "escrow deployed");
        assertEq(deployed.spokeUnwindLib, predicted.spokeUnwindLib, "nested linking is deterministic");
        assertTrue(
            vm.contains(vm.toString(deployed.spokeUnwindLib.code), _bareHex(deployed.spokeCrossChainLib)),
            "unwind -> cross-chain runtime link"
        );
        string memory spokeCode = vm.toString(_spokeVaultCreationCode(deployed));
        assertFalse(vm.contains(spokeCode, "__$"), "no unlinked Spoke Vault placeholder");
        assertEq(
            deployed.factory.creationCodeHash(deployed.factory.ROLE_SPOKE_VAULT()),
            keccak256(_spokeVaultCreationCode(deployed)),
            "factory pins linked Spoke Vault code"
        );
        if (chainId == ARBITRUM) {
            string memory coreCode = vm.toString(_coreVaultCreationCode(deployed));
            assertFalse(vm.contains(coreCode, "__$"), "no unlinked Core Vault placeholder");
            assertEq(
                deployed.factory.creationCodeHash(deployed.factory.ROLE_CORE_VAULT()),
                keccak256(_coreVaultCreationCode(deployed)),
                "factory pins linked Core Vault code"
            );
            assertEq(deployed.coreVaultTransitLogic, predicted.coreVaultTransitLogic);
            assertGt(deployed.coreVaultClosureLogic.code.length, 0);
        }
    }

    function test_DEC131_spokeVaultCodeLinksEveryDeployedLibrary() public {
        Deployment memory d;
        _deployLibraries(false, d);
        string memory code = vm.toString(_spokeVaultCreationCode(d));
        assertTrue(d.spokeCrossChainLib.code.length != 0, "SpokeCrossChainLib deployed");
        assertTrue(vm.contains(code, _bareHex(d.spokeCrossChainLib)), "SpokeCrossChainLib linked");
        assertTrue(d.spokeUnwindLib.code.length != 0, "SpokeUnwindLib deployed");
        assertTrue(vm.contains(code, _bareHex(d.spokeUnwindLib)), "SpokeUnwindLib linked");
        assertTrue(d.spokeCloseLib.code.length != 0, "SpokeCloseLib deployed");
        assertTrue(vm.contains(code, _bareHex(d.spokeCloseLib)), "SpokeCloseLib linked");
        assertTrue(vm.contains(vm.toString(d.spokeCloseLib.code), _bareHex(d.spokeUnwindLib)), "close -> unwind");
        assertTrue(d.spokeIncomeLib.code.length != 0, "SpokeIncomeLib deployed");
        assertTrue(vm.contains(code, _bareHex(d.spokeIncomeLib)), "SpokeIncomeLib linked");
        assertFalse(vm.contains(code, "__$"), "no placeholder left");
        // Library into library: SpokeIncomeLib sends the collections home through SpokeCrossChainLib (WP-10).
        string memory income = vm.toString(d.spokeIncomeLib.code);
        assertTrue(vm.contains(income, _bareHex(d.spokeCrossChainLib)), "SpokeIncomeLib -> SpokeCrossChainLib");
    }

    function test_DEC131_hubAlsoDeploysTheCoreVaultLibraries() public {
        Deployment memory d;
        _deployLibraries(true, d);
        string memory code = vm.toString(_coreVaultCreationCode(d));
        assertTrue(d.coreVaultLogic.code.length != 0, "CoreVaultLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultLogic)), "CoreVaultLogic linked");
        assertTrue(d.coreVaultTransitLogic.code.length != 0, "CoreVaultTransitLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultTransitLogic)), "CoreVaultTransitLogic linked");
        assertTrue(d.coreVaultIncomeLogic.code.length != 0, "CoreVaultIncomeLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultIncomeLogic)), "CoreVaultIncomeLogic linked");
        assertTrue(d.coreVaultPayoutLogic.code.length != 0, "CoreVaultPayoutLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultPayoutLogic)), "CoreVaultPayoutLogic linked");
        assertTrue(d.coreVaultClosureLogic.code.length != 0, "CoreVaultClosureLogic deployed on the hub");
        assertTrue(vm.contains(code, _bareHex(d.coreVaultClosureLogic)), "CoreVaultClosureLogic linked");
        assertTrue(d.coreVaultIncomeCollectionLogic.code.length != 0, "CoreVaultIncomeCollectionLogic deployed");
        assertTrue(
            vm.contains(code, _bareHex(d.coreVaultIncomeCollectionLogic)), "CoreVaultIncomeCollectionLogic linked"
        );
        assertFalse(vm.contains(code, "__$"), "no placeholder left");
        // Library into library: CoreVaultIncomeLogic calls CoreVaultIncomeCollectionLogic (WP-10), CoreVaultLogic calls
        // CoreVaultIncomeLogic (the valuation hook, WP-07 D2), the payout
        // library calls both and the transit library all three (the report hooks), through their own linked
        // addresses.
        string memory income = vm.toString(d.coreVaultIncomeLogic.code);
        assertTrue(
            vm.contains(income, _bareHex(d.coreVaultIncomeCollectionLogic)), "income -> CoreVaultIncomeCollectionLogic"
        );
        string memory logic = vm.toString(d.coreVaultLogic.code);
        assertTrue(vm.contains(logic, _bareHex(d.coreVaultIncomeLogic)), "CoreVaultLogic -> CoreVaultIncomeLogic");
        string memory transit = vm.toString(d.coreVaultTransitLogic.code);
        assertTrue(vm.contains(transit, _bareHex(d.coreVaultLogic)), "transit -> CoreVaultLogic");
        assertTrue(vm.contains(transit, _bareHex(d.coreVaultIncomeLogic)), "transit -> CoreVaultIncomeLogic");
        assertTrue(vm.contains(transit, _bareHex(d.coreVaultPayoutLogic)), "transit -> CoreVaultPayoutLogic");
        assertTrue(vm.contains(transit, _bareHex(d.coreVaultClosureLogic)), "transit -> CoreVaultClosureLogic");
        string memory payout = vm.toString(d.coreVaultPayoutLogic.code);
        assertTrue(vm.contains(payout, _bareHex(d.coreVaultLogic)), "payout -> CoreVaultLogic");
        assertTrue(vm.contains(payout, _bareHex(d.coreVaultIncomeLogic)), "payout -> CoreVaultIncomeLogic");
    }

    /// @notice A library linked before the library it calls is deployed fails by name, never as a call into nothing.
    function test_DEC131_linkingToAnUndeployedLibraryRevertsByName() public {
        vm.expectRevert(abi.encodeWithSelector(UnlinkedLibrary.selector, CORE_VAULT_ARTIFACT));
        this.linkCoreVaultWithoutLibraries();
    }

    function linkCoreVaultWithoutLibraries() external view returns (bytes memory) {
        Deployment memory none;
        return _coreVaultCreationCode(none);
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

    function test_DEC131_nestedSpokeLibraryRequiresItsDependency() public {
        vm.expectRevert(abi.encodeWithSelector(UnlinkedLibrary.selector, "out/SpokeUnwindLib.sol/SpokeUnwindLib.json"));
        this.linkSpokeUnwindWithoutLibraries();
    }

    function linkSpokeUnwindWithoutLibraries() external view returns (bytes memory) {
        Deployment memory none;
        return _linkedToSpokeVaultLibraries("out/SpokeUnwindLib.sol/SpokeUnwindLib.json", none);
    }

    function linkSpokeVaultWithoutLibraries() external view returns (bytes memory) {
        return _linked(SPOKE_VAULT_ARTIFACT, new string[](0), new address[](0));
    }

    /// @dev Lowercase hex of `a` without the 0x prefix, as it appears inside linked bytecode.
    function _bareHex(address a) internal pure returns (string memory) {
        return vm.replace(vm.toLowercase(vm.toString(a)), "0x", "");
    }
}
