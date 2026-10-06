pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundFactoryV6} from "../../../src/factory/FundFactoryV6.sol";
import {CoreVaultV6} from "../../../src/core/CoreVaultV6.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {CodeStore} from "../../../src/factory/CodeStore.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {
    Mandate,
    SpokeConfig,
    TokenConfig,
    AdapterConfig,
    PoolConfig,
    BridgeAdapterConfig
} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {AnyPriceSource} from "../../mocks/core/AnyPriceSource.sol";
import {V3Stub} from "../../utils/V3Stub.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

/// @notice Local creation evidence, not a CCTP transport test (DEC-188, DEC-190, DEC-196).
contract FundFactoryV6Test is Test, FactoryDeployment {
    FundFactoryV6 private factory;
    MockToken private usdc;
    bytes private coreCode;
    uint256 private constant MANAGER_PRIVATE_KEY = 0x12345;
    address private manager;
    address private nativeTransport;

    function setUp() public {
        vm.chainId(42_161);
        vm.warp(1_791_293_400);
        manager = vm.addr(MANAGER_PRIVATE_KEY);
        nativeTransport = address(new NativeTransportFixture());
        Deployment memory deployment;
        _deployLibraries(true, deployment);
        coreCode = _linkedToCoreVaultLibraries("out/CoreVaultV6.sol/CoreVaultV6.json", deployment);
        usdc = new MockToken("USDC", 6);
        MockAaveV3Pool aave = new MockAaveV3Pool(MockAaveV3Pool.Rounding.HalfUp);
        aave.listReserve(address(usdc));
        IFundFactory.ProtocolWiring memory wiring;
        wiring.baseToken = address(usdc);
        wiring.acrossSpokePool = address(new MockAcrossSpokePool(0));
        wiring.wormholeCore = address(new MockWormholeCore());
        wiring.aaveV3Pool = address(aave);
        wiring.managerRegistry = address(new MockManagerRegistry());
        wiring.priceSource = address(new AnyPriceSource());
        wiring.protocolRecipient = makeAddr("recipient");
        wiring.guardian = makeAddr("guardian");
        wiring.coreVaultLogic = deployment.coreVaultLogic;
        wiring.spokeCrossChainLib = deployment.spokeCrossChainLib;
        wiring.coreVaultCreationCodeHash = keccak256(coreCode);
        wiring.flowFeeBps = 25;
        V3Stub.wire(wiring);
        IFundFactory.CreationCodeStores memory stores = _writeCodeStores(true, deployment);
        stores.valueReportReceiver = CodeStore.write(type(ValueReportReceiverV6).creationCode);
        factory = new FundFactoryV6(wiring, stores, CodeStore.write(type(SolanaSpokeRegistryV6).creationCode));
        usdc.mint(manager, 1000e6);
        vm.prank(manager);
        usdc.approve(address(factory), type(uint256).max);
    }

    function _mandate(uint256 number) private view returns (Mandate memory mandate_) {
        bytes32 id = factory.fundIdOf(42_161, number, manager);
        mandate_.manager = manager;
        mandate_.hubChainId = 42_161;
        mandate_.hubWormholeChainId = 23;
        mandate_.usdc = address(usdc);
        mandate_.tokens = new TokenConfig[](5);
        mandate_.tokens[0] = TokenConfig(42_161, address(usdc));
        mandate_.tokens[1] = TokenConfig(4663, address(800));
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        for (uint256 index; index < 3; ++index) {
            mandate_.tokens[index + 2] = TokenConfig(1, native.assets[index].accountingId);
        }
        address aave = factory.addressOf(id, "AaveV3Adapter", 42_161);
        address robinhood = factory.addressOf(id, "UniswapV4Adapter", 4663);
        mandate_.adapters = new AdapterConfig[](3);
        mandate_.adapters[0] = AdapterConfig(42_161, aave);
        mandate_.adapters[1] = AdapterConfig(4663, robinhood);
        mandate_.adapters[2] = AdapterConfig(1, address(1000));
        mandate_.pools = new PoolConfig[](3);
        mandate_.pools[0] = PoolConfig(42_161, aave, bytes32(uint256(uint160(address(usdc)))));
        mandate_.pools[1] = PoolConfig(4663, robinhood, bytes32(uint256(42)));
        mandate_.pools[2] = PoolConfig(1, address(1000), bytes32(uint256(400)));
        mandate_.swapAdapters = new AdapterConfig[](3);
        mandate_.swapAdapters[0] = AdapterConfig(42_161, factory.addressOf(id, "UniswapV3SwapAdapter", 42_161));
        mandate_.swapAdapters[1] = AdapterConfig(4663, factory.addressOf(id, "UniswapV3SwapAdapter", 4663));
        mandate_.swapAdapters[2] = AdapterConfig(1, address(1001));
        mandate_.spokes = SolanaFixture.spokes();
        mandate_.spokes[0].spokeVault = bytes32(uint256(uint160(factory.addressOf(id, "SpokeVault", 4663))));
        mandate_.bridgeAdapters = new BridgeAdapterConfig[](4);
        address hubBridge = factory.addressOf(id, "AcrossBridgeAdapter", 42_161);
        mandate_.bridgeAdapters[0] = BridgeAdapterConfig(4663, 42_161, hubBridge);
        mandate_.bridgeAdapters[1] = BridgeAdapterConfig(4663, 4663, factory.addressOf(id, "AcrossBridgeAdapter", 4663));
        mandate_.bridgeAdapters[2] = BridgeAdapterConfig(1, 42_161, nativeTransport);
        mandate_.bridgeAdapters[3] = BridgeAdapterConfig(1, 1, address(1002));
        mandate_.performanceFeeBps = 1000;
        mandate_.managementFeeBps = 500;
        mandate_.minFirstDeposit = 50e6;
    }

    function _params(uint256 number) private view returns (IFundFactory.HubParams memory params) {
        params.creationNumber = number;
        params.seedAmount = 50e6;
        params.coreVaultCreationCode = coreCode;
    }

    function _binding(uint256 number, SolanaMandateV6.Config memory native)
        private
        view
        returns (FundFactoryV6.Binding memory binding)
    {
        binding.nonce = factory.bindingNonce(manager);
        binding.expiry = block.timestamp + 1 hours;
        address fund = factory.addressOf(factory.fundIdOf(42_161, number, manager), "CoreVault", 42_161);
        bytes32 digest = factory.bindingDigest(native, fund, binding.nonce, binding.expiry);
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) = vm.sign(MANAGER_PRIVATE_KEY, digest);
        binding.signature = abi.encodePacked(signatureR, signatureS, recovery);
    }

    function testCreateThreeChainFundAndReuseManagerKey() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        for (uint256 number = 1; number <= 2; ++number) {
            FundFactoryV6.Binding memory binding = _binding(number, native);
            Mandate memory mandate_ = _mandate(number);
            IFundFactory.HubParams memory params = _params(number);
            vm.prank(manager);
            IFundFactory.FundAddresses memory result = factory.createFundV6(mandate_, params, native, binding);
            CoreVaultV6 core = CoreVaultV6(result.coreVault);
            assertEq(core.managerSolanaKey(), native.managerKey);
            assertEq(core.nativeMandateHash(), SolanaMandateV6.hash(native));
            assertEq(core.mandate().spokes.length, 2);
            assertEq(core.idle(), 49_000_000);
            assertEq(core.shareAssets(), 49_000_000);
            assertEq(core.managementFeeBps(), 500);
            assertTrue(factory.isFund(result.coreVault));
            assertEq(factory.bindingNonce(manager), number);
            assertTrue(factory.bindingCommitment(result.coreVault) != 0);
        }
        assertLt(address(factory).code.length, 24_576);
    }

    function testRejectChangedKeyExpiryNonceAndContractManager() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        FundFactoryV6.Binding memory binding = _binding(1, native);
        Mandate memory mandate_ = _mandate(1);
        IFundFactory.HubParams memory params = _params(1);
        native.managerKey = bytes32(uint256(999));
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        factory.createFundV6(mandate_, params, native, binding);
        native = SolanaFixture.nativeConfig();
        binding.expiry = block.timestamp - 1;
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        factory.createFundV6(mandate_, params, native, binding);
        binding = _binding(1, native);
        binding.nonce = 1;
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        factory.createFundV6(mandate_, params, native, binding);
        vm.etch(manager, hex"00");
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        factory.createFundV6(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
    }

    function testRejectManagementFeeAbove500AndRollbackBinding() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        Mandate memory mandate_ = _mandate(1);
        mandate_.managementFeeBps = 501;
        FundFactoryV6.Binding memory binding = _binding(1, native);
        IFundFactory.HubParams memory params = _params(1);
        vm.expectRevert();
        vm.prank(manager);
        factory.createFundV6(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
        assertEq(factory.nextCreationNumber(), 1);
    }

    function testSignatureDomainBindsFactoryChainFundAndMandate() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        bytes32 digest = factory.bindingDigest(native, address(123), 0, 999);
        assertTrue(digest != factory.bindingDigest(native, address(124), 0, 999));
        native.venues[0].pool = bytes32(uint256(99));
        assertTrue(digest != factory.bindingDigest(native, address(123), 0, 999));
        native = SolanaFixture.nativeConfig();
        vm.chainId(4663);
        assertTrue(digest != factory.bindingDigest(native, address(123), 0, 999));
    }

    function testRejectAcrossNativeTransportAtCoreCreation() public {
        SolanaMandateV6.Config memory native = SolanaFixture.nativeConfig();
        Mandate memory mandate_ = _mandate(1);
        mandate_.bridgeAdapters[2].adapter = mandate_.bridgeAdapters[0].adapter;
        IFundFactory.HubParams memory params = _params(1);
        FundFactoryV6.Binding memory binding = _binding(1, native);
        vm.expectRevert(CoreVaultV6.InvalidNativeRegistry.selector);
        vm.prank(manager);
        factory.createFundV6(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
    }
}

/// @notice No bridge execution; only the immutable CCTP target/deadline wiring of DEC-191.
contract NativeTransportFixture {
    function target() external pure returns (address) {
        return 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    }

    function fillDeadlineSeconds() external pure returns (uint32) {
        return 0;
    }
}
