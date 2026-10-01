// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CommonBase} from "forge-std/Base.sol";
import {IFundFactory} from "../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../src/factory/FundFactory.sol";
import {Create3Deployer} from "../src/factory/Create3Deployer.sol";
import {CodeStore} from "../src/factory/CodeStore.sol";
import {ManagerRegistry} from "../src/core/ManagerRegistry.sol";
import {ChainlinkPriceSource} from "../src/report/ChainlinkPriceSource.sol";
import {IImmutableState} from "@uniswap/v4-periphery/src/interfaces/IImmutableState.sol";

/// @title FactoryDeployment
/// @notice The protocol operator's deployment steps for one chain, shared by `script/DeployFactory.s.sol` and the fork
///         tests so the tested path is the deployed path. Addresses are the verified values of docs/INTEGRATIONS.md.
/// @dev Order on every chain (docs/DEPLOYMENT.md):
///      1. `Create3Deployer` through the deterministic deployer (same address everywhere, no constructor arguments);
///      2. the linked libraries through the deterministic deployer (chain-independent addresses, so the linked
///         creation code, hence its hash, is the same on every chain; docs/ARCHITECTURE.md §1.1);
///      3. on the hub, the protocol-level `ManagerRegistry` and `ChainlinkPriceSource`;
///      4. the creation code stores (CodeStore) for the roles this chain serves;
///      5. the `FundFactory` through `Create3Deployer` with `FACTORY_SALT`, at the same address on every chain for the
///         same operator.
abstract contract FactoryDeployment is CommonBase {
    /// @notice Arachnid's deterministic deployment proxy, present on Arbitrum One and Robinhood Chain.
    address internal constant DETERMINISTIC_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    bytes32 internal constant CREATE3_DEPLOYER_SALT = keccak256("pool-party.v2.Create3Deployer");
    bytes32 internal constant LIBRARY_SALT = keccak256("pool-party.v2.library");
    bytes32 internal constant FACTORY_SALT = keccak256("pool-party.v2.FundFactory");

    string internal constant CORE_VAULT_ARTIFACT = "out/CoreVault.sol/CoreVault.json";
    string internal constant CORE_VAULT_LOGIC_ID = "src/core/CoreVaultLogic.sol:CoreVaultLogic";
    string internal constant SPOKE_VAULT_ARTIFACT = "out/SpokeVault.sol/SpokeVault.json";
    string internal constant SPOKE_CROSS_CHAIN_LIB_ID = "src/spoke/SpokeCrossChainLib.sol:SpokeCrossChainLib";

    // Chains (docs/INTEGRATIONS.md).
    uint256 internal constant ARBITRUM = 42_161;
    uint256 internal constant ROBINHOOD = 4663;
    uint16 internal constant WORMHOLE_ROBINHOOD = 72;

    // Arbitrum One (Hub Chain).
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_ACROSS_SPOKE_POOL = 0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A;
    address internal constant ARB_WORMHOLE_CORE = 0xa5f208e072434bC67592E4C49C1B991BA79BCA46;
    address internal constant ARB_V4_POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address internal constant ARB_V4_POSITION_MANAGER = 0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869;
    address internal constant ARB_V4_STATE_VIEW = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address internal constant ARB_AAVE_V3_POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    /// @dev Chainlink ETH / USD on Arbitrum One (verified in test/fork/receiver/ChainlinkPriceSourceFork.t.sol).
    address internal constant ARB_ETH_USD_FEED = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;

    // Robinhood Chain (Spoke Chain).
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_ACROSS_SPOKE_POOL = 0xD29C85F15DF544bA632C9E25829fd29d767d7978;
    address internal constant RH_WORMHOLE_CORE = 0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB;
    address internal constant RH_V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant RH_V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant RH_V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;

    /// @notice Permit2, the PositionManager's `permit2()` on both chains.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @notice Q59 stance: disjoint fund-number ranges per factory. Robinhood never hubs a fund in the MVP.
    uint256 internal constant ARBITRUM_NUMBER_OFFSET = 0;
    uint256 internal constant ROBINHOOD_NUMBER_OFFSET = 1_000_000;

    /// @notice Price bound handed to the ETH / USD feed (OQ-10: a consumer treats an older price as stale on mint).
    uint32 internal constant ETH_USD_MAX_PRICE_AGE = 1 hours;

    /// @notice DEC-106: default flow fee.
    uint16 internal constant FLOW_FEE_BPS = 25;

    error UnsupportedChain(uint256 chainId);
    error DeterministicDeploymentFailed(bytes32 salt);

    /// @notice A protocol address of the wiring holds no code on this chain.
    error WiringHasNoCode(string role, address target);

    /// @notice The Uniswap V4 addresses of the wiring do not belong to one deployment.
    error V4WiringMismatch(string role, address reported, address expected);

    /// @notice What one chain's deployment produced.
    struct Deployment {
        address create3Deployer;
        address coreVaultLogic;
        address spokeCrossChainLib;
        address managerRegistry;
        address priceSource;
        FundFactory factory;
    }

    /// @notice Deploys the whole protocol stack of this chain (Arbitrum One or Robinhood Chain) and its factory.
    /// @param protocolRecipient Fee wallet (DEC-106; LC-132 OPEN).
    /// @param guardian Adapter guardian (ruling 2026-09-29, Q17-2b).
    /// @param registryOwner Owner of the hub `ManagerRegistry` (LC-142, OQ-11).
    function _deployProtocol(address protocolRecipient, address guardian, address registryOwner)
        internal
        returns (Deployment memory d)
    {
        IFundFactory.ProtocolWiring memory w = _chainWiring(block.chainid);
        w.protocolRecipient = protocolRecipient;
        w.guardian = guardian;
        bool hub = block.chainid == ARBITRUM;
        if (hub) {
            d.managerRegistry = address(new ManagerRegistry(registryOwner));
            d.priceSource = _deployPriceSource();
            w.managerRegistry = d.managerRegistry;
            w.priceSource = d.priceSource;
        }
        _checkWiring(w);
        d = _deployFactory(w, hub, d);
    }

    /// @notice Refuses a wiring the factory would accept but no fund could use (independent verification plan F-12,
    ///         FF-10, SF-1, CF-V4-10): every protocol address holds code on this chain, and the PositionManager and
    ///         StateView answer for the PoolManager given, the PositionManager for the Permit2 given. A codeless
    ///         registry reverts every income collection; a PoolManager of another deployment lets positions open while
    ///         every swap reverts. The factory itself checks only for zero addresses (its unit tests wire mocks).
    function _checkWiring(IFundFactory.ProtocolWiring memory w) internal view {
        _requireCode("baseToken", w.baseToken);
        _requireCode("acrossSpokePool", w.acrossSpokePool);
        _requireCode("wormholeCore", w.wormholeCore);
        _requireCode("uniswapV4PoolManager", w.uniswapV4PoolManager);
        _requireCode("uniswapV4PositionManager", w.uniswapV4PositionManager);
        _requireCode("uniswapV4StateView", w.uniswapV4StateView);
        _requireCode("permit2", w.permit2);
        if (w.aaveV3Pool != address(0)) _requireCode("aaveV3Pool", w.aaveV3Pool);
        if (w.managerRegistry != address(0)) _requireCode("managerRegistry", w.managerRegistry);
        if (w.priceSource != address(0)) _requireCode("priceSource", w.priceSource);
        address manager = address(IImmutableState(w.uniswapV4PositionManager).poolManager());
        if (manager != w.uniswapV4PoolManager) {
            revert V4WiringMismatch("positionManager.poolManager", manager, w.uniswapV4PoolManager);
        }
        manager = address(IImmutableState(w.uniswapV4StateView).poolManager());
        if (manager != w.uniswapV4PoolManager) {
            revert V4WiringMismatch("stateView.poolManager", manager, w.uniswapV4PoolManager);
        }
        address permit2 = address(IPositionManagerPermit2(w.uniswapV4PositionManager).permit2());
        if (permit2 != w.permit2) revert V4WiringMismatch("positionManager.permit2", permit2, w.permit2);
    }

    function _requireCode(string memory role, address target) private view {
        if (target.code.length == 0) revert WiringHasNoCode(role, target);
    }

    /// @notice Steps 1, 2, 4 and 5 with the wiring given (the unit tests pass mock protocol addresses).
    function _deployFactory(IFundFactory.ProtocolWiring memory w, bool hub, Deployment memory d)
        internal
        returns (Deployment memory)
    {
        d.create3Deployer = _deterministic(CREATE3_DEPLOYER_SALT, vm.getCode("Create3Deployer.sol:Create3Deployer"));
        d.spokeCrossChainLib = _deterministic(LIBRARY_SALT, vm.getCode("SpokeCrossChainLib.sol:SpokeCrossChainLib"));
        w.spokeCrossChainLib = d.spokeCrossChainLib;
        if (hub) {
            d.coreVaultLogic = _deterministic(LIBRARY_SALT, vm.getCode("CoreVaultLogic.sol:CoreVaultLogic"));
            w.coreVaultLogic = d.coreVaultLogic;
            w.coreVaultCreationCodeHash = keccak256(_coreVaultCreationCode(d.coreVaultLogic));
        }
        IFundFactory.CreationCodeStores memory stores = _writeCodeStores(hub, d.spokeCrossChainLib);
        d.factory = FundFactory(
            Create3Deployer(d.create3Deployer)
                .deploy(
                    FACTORY_SALT, abi.encodePacked(vm.getCode("FundFactory.sol:FundFactory"), abi.encode(w, stores))
                )
        );
        return d;
    }

    /// @notice The verified protocol addresses of `chainId`; recipient, guardian, registry and price source are set by
    ///         the caller.
    function _chainWiring(uint256 chainId) internal pure returns (IFundFactory.ProtocolWiring memory w) {
        w.flowFeeBps = FLOW_FEE_BPS;
        w.permit2 = PERMIT2;
        if (chainId == ARBITRUM) {
            w.numberOffset = ARBITRUM_NUMBER_OFFSET;
            w.baseToken = ARB_USDC;
            w.acrossSpokePool = ARB_ACROSS_SPOKE_POOL;
            w.wormholeCore = ARB_WORMHOLE_CORE;
            w.uniswapV4PoolManager = ARB_V4_POOL_MANAGER;
            w.uniswapV4PositionManager = ARB_V4_POSITION_MANAGER;
            w.uniswapV4StateView = ARB_V4_STATE_VIEW;
            w.aaveV3Pool = ARB_AAVE_V3_POOL;
        } else if (chainId == ROBINHOOD) {
            w.numberOffset = ROBINHOOD_NUMBER_OFFSET;
            w.baseToken = RH_USDG;
            w.acrossSpokePool = RH_ACROSS_SPOKE_POOL;
            w.wormholeCore = RH_WORMHOLE_CORE;
            w.uniswapV4PoolManager = RH_V4_POOL_MANAGER;
            w.uniswapV4PositionManager = RH_V4_POSITION_MANAGER;
            w.uniswapV4StateView = RH_V4_STATE_VIEW;
        } else {
            revert UnsupportedChain(chainId);
        }
    }

    /// @notice Ruling 2026-09-29 (Q57 b): Chainlink ETH / USD for WETH on both chains (report tokens keep their spoke
    ///         addresses), USDC and USDG at 1:1.
    function _deployPriceSource() internal returns (address) {
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](2);
        feeds[0] = ChainlinkPriceSource.FeedConfig(ARB_WETH, 18, ARB_ETH_USD_FEED, ETH_USD_MAX_PRICE_AGE);
        feeds[1] = ChainlinkPriceSource.FeedConfig(RH_WETH, 18, ARB_ETH_USD_FEED, ETH_USD_MAX_PRICE_AGE);
        ChainlinkPriceSource.FixedConfig[] memory fixedTokens = new ChainlinkPriceSource.FixedConfig[](2);
        fixedTokens[0] = ChainlinkPriceSource.FixedConfig(ARB_USDC, 6);
        fixedTokens[1] = ChainlinkPriceSource.FixedConfig(RH_USDG, 6);
        return address(new ChainlinkPriceSource(feeds, fixedTokens));
    }

    /// @notice Stores the creation code of every role this chain serves: the hub also needs Aave V3 and the receiver.
    function _writeCodeStores(bool hub, address spokeCrossChainLib)
        internal
        returns (IFundFactory.CreationCodeStores memory s)
    {
        s.spokeVault = CodeStore.write(_spokeVaultCreationCode(spokeCrossChainLib));
        s.uniswapV4Adapter = CodeStore.write(vm.getCode("UniswapV4Adapter.sol:UniswapV4Adapter"));
        s.acrossBridgeAdapter = CodeStore.write(vm.getCode("AcrossBridgeAdapter.sol:AcrossBridgeAdapter"));
        if (hub) {
            s.aaveV3Adapter = CodeStore.write(vm.getCode("AaveV3Adapter.sol:AaveV3Adapter"));
            s.valueReportReceiver = CodeStore.write(vm.getCode("ValueReportReceiver.sol:ValueReportReceiver"));
        }
    }

    /// @notice The Core Vault creation code linked to `coreVaultLogic` (what `createFund` takes in calldata).
    function _coreVaultCreationCode(address coreVaultLogic) internal view returns (bytes memory) {
        return _linked(CORE_VAULT_ARTIFACT, CORE_VAULT_LOGIC_ID, coreVaultLogic);
    }

    /// @notice The Spoke Vault creation code linked to `spokeCrossChainLib`.
    function _spokeVaultCreationCode(address spokeCrossChainLib) internal view returns (bytes memory) {
        return _linked(SPOKE_VAULT_ARTIFACT, SPOKE_CROSS_CHAIN_LIB_ID, spokeCrossChainLib);
    }

    /// @notice CREATE2 through the deterministic deployer; returns the existing contract when already deployed.
    function _deterministic(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        deployed = vm.computeCreate2Address(salt, keccak256(initCode), DETERMINISTIC_DEPLOYER);
        if (deployed.code.length != 0) return deployed;
        (bool ok,) = DETERMINISTIC_DEPLOYER.call(abi.encodePacked(salt, initCode));
        if (!ok || deployed.code.length == 0) revert DeterministicDeploymentFailed(salt);
    }

    /// @notice Solidity library linking: replaces every `__$<34 hex of keccak256(libraryId)>$__` placeholder in the
    ///         artifact's creation code with the library address.
    function _linked(string memory artifact, string memory libraryId, address library_)
        internal
        view
        returns (bytes memory)
    {
        string memory unlinked = vm.parseJsonString(vm.readFile(artifact), ".bytecode.object");
        bytes32 id = keccak256(bytes(libraryId));
        string memory placeholder = string.concat("__$", _hex(abi.encodePacked(id), 17), "$__");
        return vm.parseBytes(vm.replace(unlinked, placeholder, _hex(abi.encodePacked(library_), 20)));
    }

    /// @dev Lowercase hex of the first `length` bytes, without prefix.
    function _hex(bytes memory data, uint256 length) private pure returns (string memory) {
        bytes memory digits = "0123456789abcdef";
        bytes memory out = new bytes(length * 2);
        for (uint256 i; i < length; ++i) {
            out[2 * i] = digits[uint8(data[i]) >> 4];
            out[2 * i + 1] = digits[uint8(data[i]) & 0x0f];
        }
        return string(out);
    }
}

/// @notice The PositionManager's Permit2 getter (`Permit2Forwarder.permit2`).
interface IPositionManagerPermit2 {
    function permit2() external view returns (address);
}
