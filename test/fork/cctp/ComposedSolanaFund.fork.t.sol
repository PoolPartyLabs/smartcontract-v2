pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundFactoryV6} from "../../../src/factory/FundFactoryV6.sol";
import {CoreVaultV6} from "../../../src/core/CoreVaultV6.sol";
import {CctpReceiveConnector} from "../../../src/core/CctpReceiveConnector.sol";
import {SolanaPriceSourceV6} from "../../../src/report/SolanaPriceSourceV6.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {CctpRoute} from "../../../src/interfaces/ICctpCoreVault.sol";
import {CodeStore} from "../../../src/factory/CodeStore.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaDeploymentV6} from "../../../src/factory/SolanaDeploymentV6.sol";
import {Mandate, TokenConfig, BridgeAdapterConfig, AdapterConfig, PoolConfig} from "../../../src/mandate/Mandate.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {CctpTestMessage} from "../../mocks/cctp/CctpHarness.sol";
import {SolanaFixture} from "../../unit/solana/SolanaFixture.sol";
import {ICctpLiveMessenger, ICctpLiveTransmitter} from "./CctpReceive.fork.t.sol";

/// @notice DEC-188/191/192/196/199: real Arbitrum protocols, local guardian/attester overrides, no broadcast.
contract ComposedSolanaFundForkTest is Test, FactoryDeployment {
    using AdvancedWormholeOverride for ICoreBridge;

    address private constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address private constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint256 private constant MANAGER_KEY = 0x2256C011055E;
    uint256 private constant ATTESTER_KEY = 0xC1AC1E;
    FundFactoryV6 private factory;
    CoreVaultV6 private core;
    ValueReportReceiverV6 private receiver;
    ICoreBridge private bridge;
    SolanaMandateV6.Config private native;
    bytes private coreCode;
    address private manager;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), 512_239_244);
        vm.warp(1_791_293_400);
        manager = vm.addr(MANAGER_KEY);
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
        IFundFactory.ProtocolWiring memory wiring = _chainWiring(ARBITRUM);
        wiring.numberOffset = 0;
        wiring.managerRegistry = address(new MockManagerRegistry());
        wiring.priceSource = address(_priceSource());
        wiring.protocolRecipient = makeAddr("protocol");
        wiring.guardian = makeAddr("guardian");
        wiring.coreVaultLogic = deployment.coreVaultLogic;
        wiring.spokeCrossChainLib = deployment.spokeCrossChainLib;
        wiring.coreVaultCreationCodeHash = keccak256(coreCode);
        IFundFactory.CreationCodeStores memory stores = _writeCodeStores(true, deployment);
        stores.valueReportReceiver = CodeStore.write(type(ValueReportReceiverV6).creationCode);
        factory = new FundFactoryV6(wiring, stores, CodeStore.write(type(SolanaSpokeRegistryV6).creationCode));
        bridge = ICoreBridge(wiring.wormholeCore);
        bridge.setUpOverride();
        bridge.setConsistencyLevel(32);
        SolanaMandateV6.Config memory nativeConfig = SolanaFixture.nativeConfig();
        nativeConfig.transport.hubUsdc = ARB_USDC;
        nativeConfig.transport.remoteTokenMessenger = ICctpLiveMessenger(MESSENGER).remoteTokenMessengers(5);
        SolanaDeploymentV6.store(native, nativeConfig);
        deal(ARB_USDC, manager, 100e6);
        vm.prank(manager);
        IERC20(ARB_USDC).approve(address(factory), 100e6);
        core = _create();
        receiver = ValueReportReceiverV6(core.reportReceiver());
        ICctpLiveTransmitter transmitter = ICctpLiveTransmitter(TRANSMITTER);
        vm.startPrank(transmitter.attesterManager());
        transmitter.enableAttester(vm.addr(ATTESTER_KEY));
        transmitter.setSignatureThreshold(1);
        vm.stopPrank();
    }

    function _priceSource() private returns (SolanaPriceSourceV6) {
        ChainlinkPriceSource.FixedConfig[] memory fixedTokens = new ChainlinkPriceSource.FixedConfig[](2);
        fixedTokens[0] = ChainlinkPriceSource.FixedConfig(ARB_USDC, 6);
        fixedTokens[1] = ChainlinkPriceSource.FixedConfig(RH_USDG, 6);
        return new SolanaPriceSourceV6(
            SolanaPriceSourceV6.NativeConfig(
                SolanaFixture.STOCK, SolanaFixture.SOL, SolanaFixture.USDC, 3600, 3600, 1_791_293_400, 1_791_316_800
            ),
            new ChainlinkPriceSource.FeedConfig[](0),
            fixedTokens
        );
    }

    function _mandate() private view returns (Mandate memory mandate_) {
        bytes32 id = factory.fundIdOf(42_161, 1, manager);
        mandate_.manager = manager;
        mandate_.hubChainId = 42_161;
        mandate_.hubWormholeChainId = 23;
        mandate_.usdc = ARB_USDC;
        mandate_.tokens = new TokenConfig[](5);
        mandate_.tokens[0] = TokenConfig(42_161, ARB_USDC);
        mandate_.tokens[1] = TokenConfig(4663, RH_USDG);
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
        mandate_.pools[0] = PoolConfig(42_161, aave, bytes32(uint256(uint160(ARB_USDC))));
        mandate_.pools[1] = PoolConfig(4663, robinhood, bytes32(uint256(42)));
        mandate_.pools[2] = PoolConfig(1, address(1000), bytes32(uint256(400)));
        mandate_.swapAdapters = new AdapterConfig[](3);
        mandate_.swapAdapters[0] = AdapterConfig(42_161, factory.addressOf(id, "UniswapV3SwapAdapter", 42_161));
        mandate_.swapAdapters[1] = AdapterConfig(4663, factory.addressOf(id, "UniswapV3SwapAdapter", 4663));
        mandate_.swapAdapters[2] = AdapterConfig(1, address(1001));
        mandate_.spokes = SolanaFixture.spokes();
        mandate_.spokes[0].spokeToken = RH_USDG;
        mandate_.spokes[0].spokeVault = bytes32(uint256(uint160(factory.addressOf(id, "SpokeVault", 4663))));
        mandate_.bridgeAdapters = new BridgeAdapterConfig[](4);
        mandate_.bridgeAdapters[0] =
            BridgeAdapterConfig(4663, 42_161, factory.addressOf(id, "AcrossBridgeAdapter", 42_161));
        mandate_.bridgeAdapters[1] = BridgeAdapterConfig(4663, 4663, factory.addressOf(id, "AcrossBridgeAdapter", 4663));
        mandate_.bridgeAdapters[2] = BridgeAdapterConfig(1, 42_161, factory.addressOf(id, "CctpBridgeAdapter", 42_161));
        mandate_.bridgeAdapters[3] = BridgeAdapterConfig(1, 1, address(1002));
        mandate_.performanceFeeBps = 1000;
        mandate_.managementFeeBps = 500;
        mandate_.minFirstDeposit = 50e6;
    }

    function _create() private returns (CoreVaultV6) {
        IFundFactory.HubParams memory params;
        params.creationNumber = 1;
        params.seedAmount = 50e6;
        params.coreVaultCreationCode = coreCode;
        FundFactoryV6.Binding memory binding;
        binding.expiry = block.timestamp + 1 hours;
        address predicted = factory.addressOf(factory.fundIdOf(42_161, 1, manager), "CoreVault", 42_161);
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) =
            vm.sign(MANAGER_KEY, factory.bindingDigest(native, predicted, 0, binding.expiry));
        binding.signature = abi.encodePacked(signatureR, signatureS, recovery);
        Mandate memory mandate_ = _mandate();
        SolanaMandateV6.Config memory nativeConfig = native;
        assertEq(manager.code.length, 0);
        CoreVaultConfig memory sizeConfig;
        sizeConfig.shareName = "Pool Party Fund 1";
        sizeConfig.shareSymbol = "PP-1";
        assertLe(coreCode.length + abi.encode(mandate_, sizeConfig, address(1), address(2), address(3)).length, 49_152);
        vm.prank(manager);
        IFundFactory.FundAddresses memory result = factory.createFundV6(mandate_, params, nativeConfig, binding);
        return CoreVaultV6(result.coreVault);
    }

    function _report(uint64 sequence, uint256 unallocated) private view returns (ReportCodecV6.Report memory report) {
        report = SolanaFixture.report(uint64(block.timestamp));
        report.fundId = core.fundId();
        report.mandateHash = core.mandateHash();
        report.nativeMandateHash = core.nativeMandateHash();
        report.sequence = sequence;
        report.unallocated[0].amount = unallocated;
        report.arrivedTransits = new ReportCodec.TransitAmount[](0);
    }

    function testThreeChainFundFastSendFinalizedReportAndReturnNav() public {
        assertEq(core.mandate().spokes.length, 2);
        assertEq(core.managementFeeBps(), 500);
        assertEq(IERC20(ARB_USDC).balanceOf(address(core)), 49e6);
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(_report(1, 0))));
        vm.prank(manager);
        bytes32 sent = core.sendToSolana(10e6, abi.encode(uint256(50_000)));
        assertEq(core.inFlightValue(), 9_995_000);
        assertEq(core.shareAssets(), 48_995_000);
        assertEq(IERC20(ARB_USDC).allowance(address(core), MESSENGER), 0);
        ReportCodecV6.Report memory report = _report(2, 9_999_000);
        report.cumulativeReceived = 9_999_000;
        report.arrivedTransits = new ReportCodec.TransitAmount[](1);
        report.arrivedTransits[0] = ReportCodec.TransitAmount(sent, 9_999_000);
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(report)));
        assertEq(core.inFlightValue(), 0);
        assertEq(core.shareAssets(), 48_999_000);
        bytes32 returning = keccak256("composed-return");
        report = _report(3, 0);
        report.cumulativeReceived = 9_999_000;
        report.cumulativeSentHome = 9_999_000;
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        report.inFlightToHub[0] = ReportCodec.HubBoundAmount(returning, 9_994_000, TransferKind.Principal);
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(report)));
        assertEq(core.shareAssets(), 48_994_000);
        _return(returning);
        assertEq(core.idle(), 48_998_000);
        assertEq(core.shareAssets(), 48_998_000);
        assertEq(IERC20(ARB_USDC).balanceOf(address(core)), 48_998_000);
        assertEq(core.sharePrice(), uint256(48_998_000) * 1e18 / 49);
    }

    function testOffHoursShareMintAndBurnFailClosed() public {
        uint256 supply = IERC20(core.shareToken()).totalSupply();
        vm.warp(1_791_316_800);
        vm.expectRevert(SolanaPriceSourceV6.StockMarketClosed.selector);
        vm.prank(manager);
        core.deposit(2e6, 0);
        vm.expectRevert(SolanaPriceSourceV6.StockMarketClosed.selector);
        vm.prank(manager);
        core.requestPayout(2e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        assertEq(IERC20(core.shareToken()).totalSupply(), supply);
    }

    function testNativeIncomeResultSplitsFeesAndKeepsFeeSurplusPrincipal() public {
        bytes32 transitId = keccak256("native-income-return");
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(_report(1, 0))));
        ReportCodecV6.Report memory report = _report(2, 0);
        report.cumulativeIncome = new ReportCodecV6.TokenAmount[](1);
        report.cumulativeIncome[0] = ReportCodecV6.TokenAmount(native.usdcMint, 10e6);
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        report.inFlightToHub[0] = ReportCodec.HubBoundAmount(transitId, 9_995_000, TransferKind.Income);
        ReportCodecV6.CollectionResult[] memory results = new ReportCodecV6.CollectionResult[](1);
        bytes32[] memory mints = new bytes32[](1);
        mints[0] = native.usdcMint;
        uint256[] memory sold = new uint256[](1);
        sold[0] = 10e6;
        results[0] = ReportCodecV6.CollectionResult(1, 1, transitId, 10e6, mints, sold, sold, 9_995_000);
        report.collectionResults = abi.encode(results);
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(report)));
        uint256 protocolBefore = IERC20(ARB_USDC).balanceOf(core.protocolRecipient());
        _receive(transitId, TransferKind.Income, 10e6, 5000, 1000);
        assertEq(core.idle(), 49_004_000);
        assertEq(core.shareAssets(), 49_004_000);
        assertEq(IERC20(ARB_USDC).balanceOf(core.protocolRecipient()), protocolBefore + 499_750);
        assertEq(IERC20(ARB_USDC).balanceOf(core.managerFeeVault()), 499_750);
        assertEq(core.unmatchedArrivals(), 0);
        assertGt(core.incomeOwed(manager), 0);
        uint256 balanceBefore = IERC20(ARB_USDC).balanceOf(manager);
        vm.prank(manager);
        uint256 withdrawn = core.withdrawIncome();
        assertGt(withdrawn, 0);
        assertEq(IERC20(ARB_USDC).balanceOf(manager), balanceBefore + withdrawn);
        assertEq(core.shareAssets(), 49_004_000);
    }

    function testNativeClosureResultAndReturnUseExistingClosureAccounting() public {
        vm.prank(manager);
        core.closeFund();
        bytes32 transitId = keccak256("native-closure-return");
        ReportCodecV6.Report memory report = _report(1, 0);
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        report.inFlightToHub[0] = ReportCodec.HubBoundAmount(transitId, 999_500, TransferKind.Principal);
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].orderId = keccak256("closure-order");
        results[0].requestId = core.closureRequestId();
        results[0].transitId = transitId;
        results[0].amountSent = 1e6;
        results[0].amountToArrive = 999_500;
        report.unwindResults = SpokeUnwindTypes.encodeResults(results);
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(report)));
        _receive(transitId, TransferKind.Principal, 1e6, 500, 100);
        assertEq(core.idle(), 49_999_900);
        assertEq(core.unmatchedArrivals(), 0);
    }

    function _return(bytes32 transitId) private {
        _receive(transitId, TransferKind.Principal, 9_999_000, 5000, 1000);
    }

    function _receive(bytes32 transitId, TransferKind kind, uint256 amount, uint256 maxFee, uint256 fee) private {
        CctpRoute memory route = CctpRoute(
            core.fundId(),
            1,
            native.transport.mintRecipient,
            native.transport.destinationCaller,
            native.transport.remoteTokenMessenger,
            native.usdcMint,
            native.transport.remoteVaultAuthority
        );
        bytes memory message = CctpTestMessage.encode(
            route,
            address(core),
            address(core.cctpConnector()),
            MESSENGER,
            transitId,
            keccak256("composed-circle-nonce"),
            kind,
            amount,
            maxFee,
            fee
        );
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) = vm.sign(ATTESTER_KEY, keccak256(message));
        core.cctpConnector().receiveCctpAndCredit(message, abi.encodePacked(signatureR, signatureS, recovery));
    }
}
