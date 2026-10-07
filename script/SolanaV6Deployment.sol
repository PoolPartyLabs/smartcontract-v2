pragma solidity 0.8.28;

import {FactoryDeployment} from "./FactoryDeployment.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {FundFactoryV6} from "../src/factory/FundFactoryV6.sol";
import {Create3Deployer} from "../src/factory/Create3Deployer.sol";
import {CodeStore} from "../src/factory/CodeStore.sol";
import {ManagerRegistry} from "../src/core/ManagerRegistry.sol";
import {SolanaPriceSourceV6} from "../src/report/SolanaPriceSourceV6.sol";
import {ChainlinkPriceSource} from "../src/report/ChainlinkPriceSource.sol";
import {ValueReportReceiverV6} from "../src/report/ValueReportReceiverV6.sol";
import {SolanaSpokeRegistryV6} from "../src/mandate/SolanaMandateV6.sol";

/// @notice DEC-188/198/199: separate new-Fund factory, unchanged Robinhood venues, native USD feeds.
abstract contract SolanaV6Deployment is FactoryDeployment {
    bytes32 internal constant V6_FACTORY_SALT = keccak256("pool-party.v2.solana-v6.FundFactory");

    struct V6Deployment {
        Deployment common;
        FundFactoryV6 factory;
        address cctpLogic;
        address nativeDeploymentLogic;
        address nativePdaLogic;
        address nativePolicyLogic;
        bytes coreCode;
    }

    error InvalidDeploymentConfiguration();
    error OversizedRuntime(string role, uint256 size);

    function _deployV6(
        address recipient,
        address guardian,
        address registryOwner,
        address apiSigner,
        uint64 sessionOpen,
        uint64 sessionClose,
        uint32 maxAge
    ) internal returns (V6Deployment memory result) {
        if (
            recipient == address(0) || guardian == address(0) || apiSigner == address(0) || registryOwner == address(0)
                || maxAge == 0
        ) revert InvalidDeploymentConfiguration();
        bool hub = block.chainid == ARBITRUM;
        if (!hub && block.chainid != ROBINHOOD) revert InvalidDeploymentConfiguration();
        IFundFactory.ProtocolWiring memory wiring = _chainWiring(block.chainid);
        _checkManifest(wiring, hub);
        wiring.protocolRecipient = recipient;
        wiring.guardian = guardian;
        wiring.apiSigner = apiSigner;
        result.common.create3Deployer =
            _deterministic(CREATE3_DEPLOYER_SALT, vm.getCode("Create3Deployer.sol:Create3Deployer"));
        _deployLibraries(hub, result.common);
        wiring.spokeCrossChainLib = result.common.spokeCrossChainLib;
        if (hub) {
            result.common.managerRegistry = address(new ManagerRegistry(registryOwner));
            result.common.priceSource = address(_nativePriceSource(sessionOpen, sessionClose, maxAge));
            wiring.managerRegistry = result.common.managerRegistry;
            wiring.priceSource = result.common.priceSource;
            wiring.coreVaultLogic = result.common.coreVaultLogic;
            result.cctpLogic = _deterministic(
                LIBRARY_SALT,
                _linkedToCoreVaultLibraries("out/CoreVaultCctpLogic.sol/CoreVaultCctpLogic.json", result.common)
            );
            (string[] memory existingIds, address[] memory existingLibraries) = _coreVaultLinks(result.common);
            string[] memory ids = new string[](7);
            address[] memory libraries = new address[](7);
            for (uint256 index; index < 6; ++index) {
                ids[index] = existingIds[index];
                libraries[index] = existingLibraries[index];
            }
            ids[6] = "src/core/CoreVaultCctpLogic.sol:CoreVaultCctpLogic";
            libraries[6] = result.cctpLogic;
            result.coreCode = _linked("out/CoreVaultV6.sol/CoreVaultV6.json", ids, libraries);
            wiring.coreVaultCreationCodeHash = keccak256(result.coreCode);
            _checkRuntime("CoreVaultV6", "out/CoreVaultV6.sol/CoreVaultV6.json");
            _checkRuntime("ValueReportReceiverV6", "out/ValueReportReceiverV6.sol/ValueReportReceiverV6.json");
        }
        _checkWiring(wiring);
        IFundFactory.CreationCodeStores memory stores = _writeCodeStores(hub, result.common);
        address[] memory registryCode = CodeStore.write(type(SolanaSpokeRegistryV6).creationCode);
        if (hub) {
            stores.valueReportReceiver = CodeStore.write(type(ValueReportReceiverV6).creationCode);
        }
        _checkRuntime("FundFactoryV6", "out/FundFactoryV6.sol/FundFactoryV6.json");
        result.nativeDeploymentLogic =
            _deterministic(LIBRARY_SALT, vm.getCode("SolanaDeploymentV6.sol:SolanaDeploymentV6"));
        result.nativePdaLogic = _deterministic(LIBRARY_SALT, vm.getCode("SolanaPdaV6.sol:SolanaPdaV6"));
        string[] memory policyIds = new string[](1);
        address[] memory policyLibraries = new address[](1);
        policyIds[0] = "src/mandate/SolanaPdaV6.sol:SolanaPdaV6";
        policyLibraries[0] = result.nativePdaLogic;
        result.nativePolicyLogic = _deterministic(
            LIBRARY_SALT, _linked("out/SolanaPolicyV6.sol/SolanaPolicyV6.json", policyIds, policyLibraries)
        );
        string[] memory factoryIds = new string[](2);
        address[] memory factoryLibraries = new address[](2);
        factoryIds[0] = "src/factory/SolanaDeploymentV6.sol:SolanaDeploymentV6";
        factoryLibraries[0] = result.nativeDeploymentLogic;
        factoryIds[1] = "src/mandate/SolanaPolicyV6.sol:SolanaPolicyV6";
        factoryLibraries[1] = result.nativePolicyLogic;
        result.factory = FundFactoryV6(
            Create3Deployer(result.common.create3Deployer)
                .deploy(
                    V6_FACTORY_SALT,
                    abi.encodePacked(
                        _linked("out/FundFactoryV6.sol/FundFactoryV6.json", factoryIds, factoryLibraries),
                        abi.encode(wiring, stores, registryCode)
                    )
                )
        );
    }

    function _checkRuntime(string memory role, string memory artifact) private view {
        string memory object = vm.parseJsonString(vm.readFile(artifact), ".deployedBytecode.object");
        uint256 size = (bytes(object).length - 2) / 2;
        if (size > 23_576) revert OversizedRuntime(role, size);
    }

    function _checkManifest(IFundFactory.ProtocolWiring memory wiring, bool hub) private view {
        string memory manifest = vm.readFile("script/solana-v6-addresses.json");
        string memory side = hub ? ".arbitrum" : ".robinhood";
        if (
            wiring.baseToken != vm.parseJsonAddress(manifest, string.concat(side, hub ? ".usdc" : ".baseToken"))
                || wiring.wormholeCore != vm.parseJsonAddress(manifest, string.concat(side, ".wormhole"))
                || wiring.acrossSpokePool != vm.parseJsonAddress(manifest, string.concat(side, ".across"))
                || wiring.uniswapV4PoolManager != vm.parseJsonAddress(manifest, string.concat(side, ".v4PoolManager"))
                || wiring.uniswapV4PositionManager
                    != vm.parseJsonAddress(manifest, string.concat(side, ".v4PositionManager"))
                || wiring.uniswapV4StateView != vm.parseJsonAddress(manifest, string.concat(side, ".v4StateView"))
                || wiring.uniswapV3Factory != vm.parseJsonAddress(manifest, string.concat(side, ".v3Factory"))
                || wiring.uniswapV3SwapRouter02 != vm.parseJsonAddress(manifest, string.concat(side, ".v3Router"))
                || wiring.uniswapV3QuoterV2 != vm.parseJsonAddress(manifest, string.concat(side, ".v3Quoter"))
                || wiring.permit2 != vm.parseJsonAddress(manifest, ".permit2")
        ) revert InvalidDeploymentConfiguration();
        if (
            hub
                && (ARB_ETH_USD_FEED != vm.parseJsonAddress(manifest, ".arbitrum.ethUsd")
                    || wiring.aaveV3Pool != vm.parseJsonAddress(manifest, ".arbitrum.aaveV3Pool"))
        ) {
            revert InvalidDeploymentConfiguration();
        }
    }

    function _nativePriceSource(uint64 sessionOpen, uint64 sessionClose, uint32 maxAge)
        private
        returns (SolanaPriceSourceV6)
    {
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](2);
        feeds[0] = ChainlinkPriceSource.FeedConfig(ARB_WETH, 18, ARB_ETH_USD_FEED, ETH_USD_MAX_PRICE_AGE);
        feeds[1] = ChainlinkPriceSource.FeedConfig(RH_WETH, 18, ARB_ETH_USD_FEED, ETH_USD_MAX_PRICE_AGE);
        ChainlinkPriceSource.FixedConfig[] memory fixedTokens = new ChainlinkPriceSource.FixedConfig[](2);
        fixedTokens[0] = ChainlinkPriceSource.FixedConfig(ARB_USDC, 6);
        fixedTokens[1] = ChainlinkPriceSource.FixedConfig(RH_USDG, 6);
        SolanaPriceSourceV6 source = new SolanaPriceSourceV6(
            SolanaPriceSourceV6.NativeConfig(
                0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a,
                0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001,
                0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61,
                maxAge,
                maxAge,
                sessionOpen,
                sessionClose
            ),
            feeds,
            fixedTokens
        );
        string memory manifest = vm.readFile("script/solana-v6-addresses.json");
        if (
            source.TSLA_USD() != vm.parseJsonAddress(manifest, ".arbitrum.tslaUsd")
                || source.NVDA_USD() != vm.parseJsonAddress(manifest, ".arbitrum.nvdaUsd")
                || source.SOL_USD() != vm.parseJsonAddress(manifest, ".arbitrum.solUsd")
        ) revert InvalidDeploymentConfiguration();
        return source;
    }
}
