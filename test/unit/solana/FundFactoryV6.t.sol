pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundFactoryV6} from "../../../src/factory/FundFactoryV6.sol";
import {CoreVaultV6} from "../../../src/core/CoreVaultV6.sol";
import {CoreVaultCctpLogic} from "../../../src/core/CoreVaultCctpLogic.sol";
import {SolanaDeploymentV6} from "../../../src/factory/SolanaDeploymentV6.sol";
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
import {SolanaPolicyV6} from "../../../src/mandate/SolanaPolicyV6.sol";
import {SolanaPdaV6} from "../../../src/mandate/SolanaPdaV6.sol";

/// @notice Local creation evidence, not a CCTP transport test (DEC-188, DEC-190, DEC-196).
contract FundFactoryV6Test is Test, FactoryDeployment {
    FundFactoryV6 private factory;
    MockToken private usdc;
    bytes private coreCode;
    uint256 private constant MANAGER_PRIVATE_KEY = 0x12345;
    address private manager;
    mapping(uint256 => SolanaPolicyV6.Commitment) private commitments;

    function setUp() public {
        vm.chainId(42_161);
        vm.warp(1_791_293_400);
        manager = vm.addr(MANAGER_PRIVATE_KEY);
        Deployment memory deployment;
        _deployLibraries(true, deployment);
        (string[] memory coreIds, address[] memory coreLibraries) = _coreVaultLinks(deployment);
        string[] memory ids = new string[](7);
        address[] memory libraries = new address[](7);
        for (uint256 index; index < 6; ++index) {
            ids[index] = coreIds[index];
            libraries[index] = coreLibraries[index];
        }
        ids[6] = "src/core/CoreVaultCctpLogic.sol:CoreVaultCctpLogic";
        libraries[6] = _deterministic(
            LIBRARY_SALT, _linkedToCoreVaultLibraries("out/CoreVaultCctpLogic.sol/CoreVaultCctpLogic.json", deployment)
        );
        coreCode = _linked("out/CoreVaultV6.sol/CoreVaultV6.json", ids, libraries);
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
        vm.mockCall(
            0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d,
            abi.encodeWithSignature("remoteTokenMessengers(uint32)", uint32(5)),
            abi.encode(bytes32(uint256(1234)))
        );
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
        SolanaMandateV6.Config memory native = _nativeConfig();
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
        mandate_.bridgeAdapters[2] = BridgeAdapterConfig(1, 42_161, factory.addressOf(id, "CctpBridgeAdapter", 42_161));
        mandate_.bridgeAdapters[3] = BridgeAdapterConfig(1, 1, address(1002));
        mandate_.performanceFeeBps = 1000;
        mandate_.managementFeeBps = 500;
        mandate_.minFirstDeposit = 50e6;
    }

    function _nativeConfig() private view returns (SolanaMandateV6.Config memory native) {
        native = SolanaFixture.nativeConfig();
        native.transport.hubUsdc = address(usdc);
    }

    function _params(uint256 number) private view returns (IFundFactory.HubParams memory params) {
        params.creationNumber = number;
        params.seedAmount = 50e6;
        params.coreVaultCreationCode = coreCode;
    }

    function _binding(uint256 number, SolanaMandateV6.Config memory native)
        private
        returns (FundFactoryV6.Binding memory binding)
    {
        binding.nonce = factory.bindingNonce(manager);
        binding.expiry = block.timestamp + 1 hours;
        Mandate memory mandate_ = _mandate(number);
        SolanaPolicyV6.Commitment memory commitment = _seal(number, mandate_, native);
        commitments[number] = commitment;
        bytes32 digest = _bootstrapDigest(number, mandate_, native, commitment, binding);
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) = vm.sign(MANAGER_PRIVATE_KEY, digest);
        binding.signature = abi.encodePacked(signatureR, signatureS, recovery);
    }

    function _bootstrapDigest(uint256 number, Mandate memory mandate_, SolanaMandateV6.Config memory native,
        SolanaPolicyV6.Commitment memory commitment, FundFactoryV6.Binding memory binding)
        private view returns (bytes32)
    {
        bytes32 domain = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256("PoolParty Solana Fund"), keccak256("6"), block.chainid, address(factory)
        ));
        bytes32 id = factory.fundIdOf(42_161, number, manager);
        return keccak256(abi.encodePacked(hex"1901", domain, SolanaPolicyV6.bootstrapHash(
            factory.BOOTSTRAP_TYPEHASH(), block.chainid, factory.addressOf(id, "CoreVault", 42_161),
            keccak256(abi.encode(mandate_)), native, commitment, id, binding.nonce, binding.expiry
        )));
    }

    function _seal(uint256 number, Mandate memory mandate_, SolanaMandateV6.Config memory native)
        private view returns (SolanaPolicyV6.Commitment memory commitment)
    {
        commitment.spokeIndex = 1;
        commitment.policyHash = SolanaPolicyV6.hash(
            SolanaPolicyV6.hubPolicyHash(mandate_, 1), SolanaPolicyV6.nativePolicyHash(native)
        );
        address core = factory.addressOf(factory.fundIdOf(42_161, number, manager), "CoreVault", 42_161);
        commitment.fundPda = SolanaPdaV6.fund(42_161, core, 1, commitment.policyHash, native.program);
        bytes32 vault = SolanaPdaV6.derive(abi.encodePacked("vault", commitment.fundPda), native.program);
        native.spoke = SolanaPdaV6.derive(abi.encodePacked("emitter", commitment.fundPda), native.program);
        bytes32 token = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;
        bytes32 token2022 = 0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc;
        commitment.usdcAta = SolanaPdaV6.ata(vault, native.usdcMint, token);
        commitment.stockAta = SolanaPdaV6.ata(vault, SolanaFixture.STOCK, token2022);
        commitment.nvdaxAta = SolanaPdaV6.ata(vault, 0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a, token2022);
        commitment.wsolAta = SolanaPdaV6.ata(vault, SolanaFixture.SOL, token);
        native.transport.mintRecipient = commitment.usdcAta;
        native.transport.destinationCaller = vault;
        native.transport.remoteVaultAuthority = vault;
        mandate_.spokes[1].spokeVault = native.spoke;
    }

    function _create(Mandate memory mandate_, IFundFactory.HubParams memory params,
        SolanaMandateV6.Config memory native, FundFactoryV6.Binding memory binding)
        private returns (IFundFactory.FundAddresses memory)
    {
        mandate_.spokes[1].spokeVault = native.spoke;
        return factory.createFundV6Committed(mandate_, params, native, commitments[params.creationNumber], binding);
    }

    function testCreateThreeChainFundAndReuseManagerKey() public {
        for (uint256 number = 1; number <= 2; ++number) {
            SolanaMandateV6.Config memory native = _nativeConfig();
            FundFactoryV6.Binding memory binding = _binding(number, native);
            Mandate memory mandate_ = _mandate(number);
            IFundFactory.HubParams memory params = _params(number);
            vm.prank(manager);
            IFundFactory.FundAddresses memory result = _create(mandate_, params, native, binding);
            CoreVaultV6 core = CoreVaultV6(result.coreVault);
            assertEq(core.managerSolanaKey(), native.managerKey);
            assertEq(core.nativeMandateHash(), SolanaMandateV6.hash(native));
            assertEq(core.mandate().spokes.length, 2);
            assertEq(core.idle(), 49_000_000);
            assertEq(core.shareAssets(), 49_000_000);
            assertEq(core.managementFeeBps(), 500);
            assertEq(core.cctpAdapter().maxFeeBps(), 50_000);
            assertEq(core.cctpAdapter().vault(), result.coreVault);
            assertEq(core.cctpConnector().core(), result.coreVault);
            assertEq(core.cctpAdapter().mintRecipient(), native.transport.mintRecipient);
            assertTrue(factory.isFund(result.coreVault));
            assertEq(factory.bindingNonce(manager), number);
            assertTrue(factory.bindingCommitment(result.coreVault) != 0);
        }
        assertLt(address(factory).code.length, 24_576);
    }

    function testRejectChangedKeyExpiryNonceAndContractManager() public {
        SolanaMandateV6.Config memory native = _nativeConfig();
        FundFactoryV6.Binding memory binding = _binding(1, native);
        Mandate memory mandate_ = _mandate(1);
        IFundFactory.HubParams memory params = _params(1);
        native.managerKey = bytes32(uint256(999));
        vm.expectRevert(SolanaPolicyV6.InvalidPolicyCommitment.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        native = _nativeConfig();
        binding = _binding(1, native);
        binding.expiry = block.timestamp - 1;
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        binding = _binding(1, native);
        binding.nonce = 1;
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        vm.etch(manager, hex"00");
        vm.expectRevert(FundFactoryV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
    }

    function testRejectManagementFeeAbove500AndRollbackBinding() public {
        SolanaMandateV6.Config memory native = _nativeConfig();
        Mandate memory mandate_ = _mandate(1);
        mandate_.managementFeeBps = 501;
        FundFactoryV6.Binding memory binding = _binding(1, native);
        IFundFactory.HubParams memory params = _params(1);
        vm.expectRevert();
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
        assertEq(factory.nextCreationNumber(), 1);
    }

    function testSignatureDomainBindsFactoryChainFundAndMandate() public {
        SolanaMandateV6.Config memory native = _nativeConfig();
        FundFactoryV6.Binding memory binding = _binding(1, native);
        Mandate memory mandate_ = _mandate(1);
        mandate_.spokes[1].spokeVault = native.spoke;
        bytes32 digest = _bootstrapDigest(1, mandate_, native, commitments[1], binding);
        assertTrue(digest != _bootstrapDigest(2, mandate_, native, commitments[1], binding));
        native.venues[0].pool = bytes32(uint256(99));
        assertTrue(digest != _bootstrapDigest(1, mandate_, native, commitments[1], binding));
        vm.chainId(4663);
        assertTrue(digest != _bootstrapDigest(1, mandate_, native, commitments[1], binding));
    }

    function testRejectAcrossNativeTransportAtCoreCreation() public {
        SolanaMandateV6.Config memory native = _nativeConfig();
        Mandate memory mandate_ = _mandate(1);
        mandate_.bridgeAdapters[2].adapter = mandate_.bridgeAdapters[0].adapter;
        IFundFactory.HubParams memory params = _params(1);
        FundFactoryV6.Binding memory binding = _binding(1, native);
        vm.expectRevert(SolanaPolicyV6.InvalidPolicyCommitment.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
    }

    function testRouteAndFeeCeilingAreSignedAndFailClosed() public {
        SolanaMandateV6.Config memory native = _nativeConfig();
        FundFactoryV6.Binding memory binding = _binding(1, native);
        Mandate memory mandate_ = _mandate(1);
        IFundFactory.HubParams memory params = _params(1);
        native.transport.destinationCaller = bytes32(uint256(9876));
        vm.expectRevert(SolanaPolicyV6.InvalidPolicyCommitment.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        native = _nativeConfig();
        native.transport.fastFeeCeiling = 50_001;
        binding = _binding(1, native);
        vm.expectRevert(SolanaDeploymentV6.InvalidSolanaBinding.selector);
        vm.prank(manager);
        _create(mandate_, params, native, binding);
        assertEq(factory.bindingNonce(manager), 0);
    }
}
