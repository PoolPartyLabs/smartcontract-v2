// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaFundV6Plan} from "../../../script/SolanaFundV6Plan.sol";
import {FundFactoryV6} from "../../../src/factory/FundFactoryV6.sol";
import {CoreVaultV6} from "../../../src/core/CoreVaultV6.sol";
import {SOLANA_MAX_STOCK_PRICE_AGE, SOLANA_MAX_SOL_PRICE_AGE} from "../../../src/report/SolanaPriceSourceV6.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {SolanaMandateV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaPolicyV6} from "../../../src/mandate/SolanaPolicyV6.sol";
import {ForkPins} from "../ForkPins.sol";

/// @notice DEC-188/190/195/200/202: actual wallet consent, fork-only creation, never broadcast.
/// @dev Plan shape shared with the deploy-day builder `script/BuildSolanaFundV6Plan.s.sol` (C2).
contract SolanaThreeChainCreationForkTest is Test, SolanaFundV6Plan {
    V6Deployment private hub;
    uint256 private managerKey;
    address private manager;
    uint256 private creationNumber;
    bytes32 private id;
    address private core;
    bytes private nativeBytes;
    bytes private mandateBytes;
    SolanaPolicyV6.Commitment private commitment;

    function testActualManagerCreatesAllThreeChains() public {
        _prepareHub();
        _createHub();
        _createRobinhood();
    }

    function testActualManagerCreatesHubAndExportsNativeAcceptance() public {
        _prepareHub();
        _createHub();
    }

    function _prepareHub() private {
        managerKey = vm.envUint("PRIVATE_KEY");
        manager = vm.addr(managerKey);
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), ForkPins.arbitrum());
        vm.startPrank(manager);
        hub = _deployV6(vm.envAddress("PROTOCOL_RECIPIENT"), vm.envAddress("ADAPTER_GUARDIAN"), vm.envAddress("API_SIGNER"), vm.envAddress("API_SIGNER"),
            SOLANA_MAX_STOCK_PRICE_AGE, SOLANA_MAX_SOL_PRICE_AGE);
        vm.stopPrank();
        creationNumber = hub.factory.nextCreationNumber();
        id = hub.factory.fundIdOf(42161, creationNumber, manager);
        core = hub.factory.addressOf(id, "CoreVault", 42161);
        SolanaMandateV6.Config memory nativeConfig = abi.decode(vm.parseBytes(vm.readFile("cache/sol-t11/native-config.hex")), (SolanaMandateV6.Config));
        Mandate memory mandateConfig = _mandate(hub.factory, id, manager, nativeConfig);
        commitment = _seal(mandateConfig, nativeConfig, core);
        nativeBytes = abi.encode(nativeConfig);
        mandateBytes = abi.encode(mandateConfig);
    }

    function _createHub() private {
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        SolanaMandateV6.Config memory nativeConfig = abi.decode(nativeBytes, (SolanaMandateV6.Config));
        SolanaPolicyV6.Commitment memory commitmentConfig = commitment;
        FundFactoryV6.Binding memory binding;
        binding.nonce = hub.factory.bindingNonce(manager);
        binding.expiry = block.timestamp + 1 hours;
        bytes32 digest = _bootstrapDigest(hub.factory, core, mandateConfig, nativeConfig, commitmentConfig, id, binding.nonce, binding.expiry);
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) = vm.sign(managerKey, digest);
        binding.signature = abi.encodePacked(signatureR, signatureS, recovery);
        IFundFactory.HubParams memory params;
        params.creationNumber = creationNumber;
        params.seedAmount = 50e6;
        params.coreVaultCreationCode = hub.coreCode;
        bytes memory calldata_ = abi.encodeCall(hub.factory.createFundV6Committed, (mandateConfig, params, nativeConfig, commitmentConfig, binding));
        _writeCreationPlan(calldata_, digest);
        deal(ARB_USDC, manager, 50e6);
        vm.startPrank(manager);
        IERC20(ARB_USDC).approve(address(hub.factory), 50e6);
        IFundFactory.FundAddresses memory result = hub.factory.createFundV6Committed(mandateConfig, params, nativeConfig, commitmentConfig, binding);
        vm.stopPrank();
        assertEq(result.coreVault, core);
        assertEq(CoreVaultV6(core).nativeMandateHash(), SolanaMandateV6.hash(nativeConfig));
        assertEq(IERC20(ARB_USDC).balanceOf(core), 49e6);
        vm.writeFile("cache/sol-t11/hub-created", "PASS");
    }

    function _writeCreationPlan(bytes memory calldata_, bytes32 digest) private {
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        _writePlan("cache/sol-t11/creation.json", hub.factory, core, id, digest, calldata_,
            abi.encodeCall(hub.factory.createSpoke, (creationNumber, mandateConfig, _spokeParams(mandateConfig))));
    }

    function _createRobinhood() private {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), ForkPins.robinhood());
        vm.startPrank(manager);
        V6Deployment memory spoke = _deployV6(vm.envAddress("PROTOCOL_RECIPIENT"), vm.envAddress("ADAPTER_GUARDIAN"), vm.envAddress("API_SIGNER"), vm.envAddress("API_SIGNER"),
            SOLANA_MAX_STOCK_PRICE_AGE, SOLANA_MAX_SOL_PRICE_AGE);
        vm.stopPrank();
        assertEq(address(spoke.factory), address(hub.factory));
        Mandate memory mandateConfig = abi.decode(mandateBytes, (Mandate));
        IFundFactory.SpokeParams memory spokeParams = _spokeParams(mandateConfig);
        vm.prank(manager);
        IFundFactory.ChainAddresses memory deployed = spoke.factory.createSpoke(creationNumber, mandateConfig, spokeParams);
        assertEq(deployed.spokeVault, address(uint160(uint256(mandateConfig.spokes[0].spokeVault))));
        vm.writeFile("cache/sol-t11/robinhood-created", "PASS");
    }
}
