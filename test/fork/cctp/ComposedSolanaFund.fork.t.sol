// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundFactoryV6} from "../../../src/factory/FundFactoryV6.sol";
import {CoreVaultV6} from "../../../src/core/CoreVaultV6.sol";
import {CctpReceiveConnector} from "../../../src/core/CctpReceiveConnector.sol";
import {
    SolanaPriceSourceV6,
    SOLANA_MAX_STOCK_PRICE_AGE,
    SOLANA_MAX_SOL_PRICE_AGE
} from "../../../src/report/SolanaPriceSourceV6.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {CctpRoute} from "../../../src/interfaces/ICctpCoreVault.sol";
import {CodeStore} from "../../../src/factory/CodeStore.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaDeploymentV6} from "../../../src/factory/SolanaDeploymentV6.sol";
import {SolanaPolicyV6} from "../../../src/mandate/SolanaPolicyV6.sol";
import {SolanaPdaV6} from "../../../src/mandate/SolanaPdaV6.sol";
import {Mandate, TokenConfig, BridgeAdapterConfig, AdapterConfig, PoolConfig} from "../../../src/mandate/Mandate.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {CctpTestMessage} from "../../mocks/cctp/CctpHarness.sol";
import {SolanaFixture} from "../../unit/solana/SolanaFixture.sol";
import {ICctpLiveMessenger, ICctpLiveTransmitter} from "./CctpReceive.fork.t.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {ForkPins} from "../ForkPins.sol";

/// @notice DEC-188/191/192/196/199: real Arbitrum protocols, local guardian/attester overrides, no broadcast.
contract ComposedSolanaFundForkTest is Test, FactoryDeployment {
    using AdvancedWormholeOverride for ICoreBridge;

    address private constant MESSENGER = 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d;
    address private constant TRANSMITTER = 0x81D40F21F12A8F0E3252Bccb954D722d4c464B64;
    uint256 private constant MANAGER_KEY = 0x2256C011055E;
    uint256 private constant ATTESTER_KEY = 0xC1AC1E;
    address private constant TSLA_USD = 0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3;
    address private constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    /// @dev CR-12: the deploy values (stock: 24 h heartbeat + 1 h; SOL: tight).
    uint32 private constant STOCK_MAX_AGE = SOLANA_MAX_STOCK_PRICE_AGE;
    uint32 private constant SOL_MAX_AGE = SOLANA_MAX_SOL_PRICE_AGE;
    FundFactoryV6 private factory;
    CoreVaultV6 private core;
    ValueReportReceiverV6 private receiver;
    ICoreBridge private bridge;
    SolanaMandateV6.Config private native;
    bytes private coreCode;
    address private manager;
    mapping(address feed => bytes roundData) private _feeds;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), ForkPins.cctpArbitrum());
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
                SolanaFixture.STOCK, SolanaFixture.SOL, SolanaFixture.USDC, STOCK_MAX_AGE, SOL_MAX_AGE
            ),
            new ChainlinkPriceSource.FeedConfig[](0),
            fixedTokens
        );
    }

    /// @dev `everyVenue` lists each native venue as a Mandate pool (the creation builder's shape); otherwise only the
    ///      first, as the original composed fixture does.
    function _mandate(uint256 number, SolanaMandateV6.Config memory config, bool everyVenue)
        private
        view
        returns (Mandate memory mandate_)
    {
        bytes32 id = factory.fundIdOf(42_161, number, manager);
        mandate_.manager = manager;
        mandate_.hubChainId = 42_161;
        mandate_.hubWormholeChainId = 23;
        mandate_.usdc = ARB_USDC;
        mandate_.tokens = new TokenConfig[](2 + config.assets.length);
        mandate_.tokens[0] = TokenConfig(42_161, ARB_USDC);
        mandate_.tokens[1] = TokenConfig(4663, RH_USDG);
        for (uint256 index; index < config.assets.length; ++index) {
            mandate_.tokens[index + 2] = TokenConfig(1, config.assets[index].accountingId);
        }
        address aave = factory.addressOf(id, "AaveV3Adapter", 42_161);
        address robinhood = factory.addressOf(id, "UniswapV4Adapter", 4663);
        mandate_.adapters = new AdapterConfig[](3);
        mandate_.adapters[0] = AdapterConfig(42_161, aave);
        mandate_.adapters[1] = AdapterConfig(4663, robinhood);
        mandate_.adapters[2] = AdapterConfig(1, address(1000));
        mandate_.pools = new PoolConfig[](everyVenue ? 2 + config.venues.length : 3);
        mandate_.pools[0] = PoolConfig(42_161, aave, bytes32(uint256(uint160(ARB_USDC))));
        mandate_.pools[1] = PoolConfig(4663, robinhood, bytes32(uint256(42)));
        if (!everyVenue) mandate_.pools[2] = PoolConfig(1, address(1000), bytes32(uint256(400)));
        for (uint256 index; everyVenue && index < config.venues.length; ++index) {
            SolanaMandateV6.Venue memory venue = config.venues[index];
            mandate_.pools[index + 2] = PoolConfig(1, address(1000), venue.pool == 0 ? venue.reserve : venue.pool);
        }
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
        SolanaMandateV6.Config memory nativeConfig = native;
        Mandate memory mandate_ = _mandate(1, nativeConfig, false);
        SolanaPolicyV6.Commitment memory commitment = _seal(mandate_, nativeConfig, predicted);
        binding.signature = _bootstrapSignature(mandate_, nativeConfig, commitment, predicted, binding.expiry, 1, 0);
        SolanaDeploymentV6.store(native, nativeConfig);
        assertEq(manager.code.length, 0);
        CoreVaultConfig memory sizeConfig;
        sizeConfig.shareName = "Pool Party Fund 1";
        sizeConfig.shareSymbol = "PP-1";
        assertLe(coreCode.length + abi.encode(mandate_, sizeConfig, address(1), address(2), address(3)).length, 49_152);
        vm.prank(manager);
        IFundFactory.FundAddresses memory result =
            factory.createFundV6Committed(mandate_, params, nativeConfig, commitment, binding);
        return CoreVaultV6(result.coreVault);
    }

    function _seal(Mandate memory mandate_, SolanaMandateV6.Config memory config, address predicted)
        private
        view
        returns (SolanaPolicyV6.Commitment memory commitment)
    {
        commitment.spokeIndex = 1;
        commitment.policyHash =
            SolanaPolicyV6.hash(SolanaPolicyV6.hubPolicyHash(mandate_, 1), SolanaPolicyV6.nativePolicyHash(config));
        commitment.fundPda = SolanaPdaV6.fund(42_161, predicted, 1, commitment.policyHash, config.program);
        bytes32 vault = SolanaPdaV6.derive(abi.encodePacked("vault", commitment.fundPda), config.program);
        config.spoke = SolanaPdaV6.derive(abi.encodePacked("emitter", commitment.fundPda), config.program);
        bytes32 token = 0x06ddf6e1d765a193d9cbe146ceeb79ac1cb485ed5f5b37913a8cf5857eff00a9;
        bytes32 token2022 = 0x06ddf6e1ee758fde18425dbce46ccddab61afc4d83b90d27febdf928d8a18bfc;
        commitment.usdcAta = SolanaPdaV6.ata(vault, config.usdcMint, token);
        commitment.stockAta = SolanaPdaV6.ata(vault, SolanaFixture.STOCK, token2022);
        commitment.nvdaxAta =
            SolanaPdaV6.ata(vault, 0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a, token2022);
        commitment.wsolAta = SolanaPdaV6.ata(vault, SolanaFixture.SOL, token);
        config.transport.mintRecipient = commitment.usdcAta;
        config.transport.destinationCaller = vault;
        config.transport.remoteVaultAuthority = vault;
        mandate_.spokes[1].spokeVault = config.spoke;
    }

    function _bootstrapSignature(
        Mandate memory mandate_,
        SolanaMandateV6.Config memory config,
        SolanaPolicyV6.Commitment memory commitment,
        address predicted,
        uint256 expiry,
        uint256 number,
        uint256 nonce
    ) private returns (bytes memory) {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("PoolParty Solana Fund"),
                keccak256("6"),
                block.chainid,
                address(factory)
            )
        );
        bytes32 structHash = SolanaPolicyV6.bootstrapHash(
            factory.BOOTSTRAP_TYPEHASH(),
            block.chainid,
            predicted,
            keccak256(abi.encode(mandate_)),
            config,
            commitment,
            factory.fundIdOf(42_161, number, manager),
            nonce,
            expiry
        );
        (uint8 recovery, bytes32 signatureR, bytes32 signatureS) =
            vm.sign(MANAGER_KEY, keccak256(abi.encodePacked(hex"1901", domain, structHash)));
        return abi.encodePacked(signatureR, signatureS, recovery);
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

    /// @dev R9.1: no market-hours gate. On a Saturday, with live feeds, a stock-admitting Fund mints and burns; once the
    ///      stock feed is older than its max age both fail closed (`UnsafeStockState`) and the supply stays put.
    function testWeekendShareMintAndBurnUseStalenessOnly() public {
        vm.warp(_nextSaturday());
        _feedAt(TSLA_USD, block.timestamp);
        _feedAt(SOL_USD, block.timestamp);
        IERC20 shares = IERC20(core.shareToken());
        uint256 supply = shares.totalSupply();
        vm.startPrank(manager);
        IERC20(ARB_USDC).approve(address(core), 2e6);
        core.deposit(2e6, 0);
        vm.stopPrank();
        uint256 minted = shares.totalSupply();
        assertGt(minted, supply);
        vm.prank(manager);
        core.requestPayout(1e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        uint256 burned = shares.totalSupply();
        assertLt(burned, minted);
        _feedAt(TSLA_USD, block.timestamp - STOCK_MAX_AGE - 1);
        bytes memory stale =
            abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK);
        vm.expectRevert(stale);
        vm.prank(manager);
        core.deposit(1e6, 0);
        vm.expectRevert(stale);
        vm.prank(manager);
        core.requestPayout(1e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        assertEq(shares.totalSupply(), burned);
    }

    /// @dev CR-36: which payout mode is live on a stale Solana report. DEC-160 lets no share burn on a stale report,
    ///      in either mode, so the Instant request (a burn) is refused `StaleSpokeReport`. The Standard request books its
    ///      reserve and term without burning, priced on last-known values (payout liveness, D-28); its claim after the
    ///      term again needs a fresh report, then pays. Feeds are kept live to isolate the report gate.
    function testStandardRequestIsTheOnlyPayoutStepLiveOnAStaleSolanaReport() public {
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(_report(1, 0))));
        vm.warp(block.timestamp + 1601);
        _feedAt(TSLA_USD, block.timestamp);
        _feedAt(SOL_USD, block.timestamp);
        assertFalse(receiver.isReportFresh(1));
        IERC20 shares = IERC20(core.shareToken());
        uint256 supply = shares.totalSupply();
        bytes memory stale = abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, uint256(1));
        vm.expectRevert(stale);
        vm.prank(manager);
        core.requestPayout(2e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.prank(manager);
        core.requestPayout(2e6, ICoreVaultPayouts.PayoutMode.Standard, 0);
        ICoreVaultPayouts.PayoutRequest memory request = core.payoutRequest(manager);
        assertTrue(request.open);
        assertEq(request.reserved, 2e6);
        assertEq(shares.totalSupply(), supply);
        vm.warp(request.termEndsAt);
        _feedAt(TSLA_USD, block.timestamp);
        _feedAt(SOL_USD, block.timestamp);
        vm.expectRevert(stale);
        vm.prank(manager);
        core.claimPayout(0);
        receiver.deliver(bridge.craftVaa(1, native.spoke, ReportCodecV6.encode(_report(2, 0))));
        uint256 balance = IERC20(ARB_USDC).balanceOf(manager);
        vm.prank(manager);
        ICoreVaultPayouts.PayoutReceipt memory receipt = core.claimPayout(0);
        assertGt(receipt.sharesBurned, 0);
        assertEq(shares.totalSupply(), supply - receipt.sharesBurned);
        assertEq(IERC20(ARB_USDC).balanceOf(manager), balance + receipt.usdcPaid);
        assertGt(receipt.usdcPaid, 0);
    }

    /// @dev CR-36, R9.1 on the v6 gate: a stale stock feed blocks every mint/burn (`UnsafeStockState`), but the
    ///      Standard request, which burns nothing, still books.
    function testStandardRequestStaysLiveOnAStaleStockFeed() public {
        _feedAt(TSLA_USD, block.timestamp - STOCK_MAX_AGE - 1);
        _feedAt(SOL_USD, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK));
        vm.prank(manager);
        core.requestPayout(2e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.prank(manager);
        core.requestPayout(2e6, ICoreVaultPayouts.PayoutMode.Standard, 0);
        assertEq(core.payoutRequest(manager).reserved, 2e6);
    }

    /// @dev Next Saturday 02:00 UTC strictly after the fork time (1970-01-01 was a Thursday).
    function _nextSaturday() private view returns (uint256 saturday) {
        uint256 day = block.timestamp / 1 days;
        saturday = (day + (6 + 7 - (day + 4) % 7) % 7) * 1 days + 2 hours;
        if (saturday <= block.timestamp) saturday += 7 days;
    }

    /// @dev Keeps the live answer and round of `feed`, only moving its `updatedAt`.
    function _feedAt(address feed, uint256 updatedAt) private {
        vm.clearMockedCalls();
        (uint80 round, int256 answer,,, uint80 answered) = IChainlinkAggregatorV3(feed).latestRoundData();
        _feeds[feed] = abi.encode(round, answer, updatedAt, updatedAt, answered);
        _mockFeeds();
    }

    /// @dev CR-18 fitness function. Fund creation is one Arbitrum transaction and Nitro caps a transaction at 32M gas;
    ///      it must stay at or below 30M at the largest mandate the Hub admits: 3 native assets and 4 native venues
    ///      (`SolanaSpokeRegistryV6.MAX_ASSETS/MAX_VENUES`), every venue listed as a Mandate pool, on the demo's
    ///      Hub/Robinhood shape. Counted: 21,000 intrinsic + EIP-2028 calldata (CoreVaultV6's creation code travels in
    ///      calldata) + execution from cold state. Not counted, and what the last 2M are for: Arbitrum's L1 data
    ///      component (300,034 gas units measured 2026-10-09).
    function testFundCreationFitsThirtyMillionGasAtLargestMandate() public {
        SolanaMandateV6.Config memory config = _largestNativeConfig();
        _assertLargestAdmissible(config);
        uint256 number = factory.nextCreationNumber();
        address predicted = factory.addressOf(factory.fundIdOf(42_161, number, manager), "CoreVault", 42_161);
        Mandate memory mandate_ = _mandate(number, config, true);
        SolanaPolicyV6.Commitment memory commitment = _seal(mandate_, config, predicted);
        FundFactoryV6.Binding memory binding;
        binding.nonce = factory.bindingNonce(manager);
        binding.expiry = block.timestamp + 1 hours;
        binding.signature =
            _bootstrapSignature(mandate_, config, commitment, predicted, binding.expiry, number, binding.nonce);
        IFundFactory.HubParams memory params;
        params.creationNumber = number;
        params.seedAmount = 50e6;
        params.coreVaultCreationCode = coreCode;
        bytes memory data =
            abi.encodeCall(factory.createFundV6Committed, (mandate_, params, config, commitment, binding));
        // A real transaction starts cold (the factory account itself is warm there: <= 2,600 gas conservative).
        vm.cool(address(factory));
        vm.cool(MESSENGER);
        vm.cool(ARB_USDC);
        vm.prank(manager);
        (bool created, bytes memory result) = address(factory).call(data);
        uint256 execution = vm.lastCallGas().gasTotalUsed;
        assertTrue(created, "largest admissible mandate must be creatable");
        assertEq(abi.decode(result, (IFundFactory.FundAddresses)).coreVault, predicted);
        uint256 calldataGas = _calldataGas(data);
        uint256 total = 21_000 + calldataGas + execution;
        emit log_named_uint("creation calldata bytes", data.length);
        emit log_named_uint("creation calldata gas", calldataGas);
        emit log_named_uint("creation execution gas", execution);
        emit log_named_uint("creation transaction gas", total);
        assertLe(total, 30_000_000, "CR-18: Fund creation must stay <= 30M gas (Arbitrum per-tx cap 32M)");
    }

    /// @dev 3 assets and 4 venues, the Hub's bounds: USDC/TSLAx and USDC/SOL Raydium pools, two Kamino reserves.
    function _largestNativeConfig() private view returns (SolanaMandateV6.Config memory config) {
        config = SolanaFixture.nativeConfig();
        config.transport.hubUsdc = ARB_USDC;
        config.transport.remoteTokenMessenger = ICctpLiveMessenger(MESSENGER).remoteTokenMessengers(5);
        assertEq(config.assets.length, 3);
        config.venues = new SolanaMandateV6.Venue[](4);
        for (uint256 index; index < config.venues.length; ++index) {
            config.venues[index] = index % 2 == 0
                ? SolanaMandateV6.Venue(
                    bytes32(uint256(300)),
                    bytes32(uint256(400 + index)),
                    0,
                    index % 4 == 0 ? SolanaFixture.STOCK : SolanaFixture.SOL,
                    SolanaFixture.USDC
                )
                : SolanaMandateV6.Venue(bytes32(uint256(500)), 0, bytes32(uint256(600 + index)), SolanaFixture.USDC, 0);
        }
    }

    /// @dev The fitness input is the bound itself: one more asset or venue is refused before any capital moves.
    function _assertLargestAdmissible(SolanaMandateV6.Config memory config) private {
        SolanaSpokeRegistryV6 registry = new SolanaSpokeRegistryV6(config);
        assertEq(config.assets.length, registry.MAX_ASSETS());
        assertEq(config.venues.length, registry.MAX_VENUES());
        SolanaMandateV6.Config memory wider = _largestNativeConfig();
        SolanaMandateV6.Venue[] memory venues = new SolanaMandateV6.Venue[](5);
        for (uint256 index; index < 4; ++index) {
            venues[index] = wider.venues[index];
        }
        venues[4] = SolanaMandateV6.Venue(bytes32(uint256(500)), 0, bytes32(uint256(700)), SolanaFixture.USDC, 0);
        wider.venues = venues;
        vm.expectRevert(SolanaSpokeRegistryV6.InvalidNativeConfig.selector);
        new SolanaSpokeRegistryV6(wider);
        wider = _largestNativeConfig();
        SolanaMandateV6.Asset[] memory assets = new SolanaMandateV6.Asset[](4);
        for (uint256 index; index < 3; ++index) {
            assets[index] = wider.assets[index];
        }
        bytes32 nvda = 0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a;
        assets[3] = SolanaMandateV6.Asset(nvda, SolanaMandateV6.accountingId(nvda), true);
        wider.assets = assets;
        vm.expectRevert(SolanaSpokeRegistryV6.InvalidNativeConfig.selector);
        new SolanaSpokeRegistryV6(wider);
    }

    /// @dev EIP-2028 calldata cost: 4 gas per zero byte, 16 per non-zero byte.
    function _calldataGas(bytes memory data) private pure returns (uint256 gas) {
        for (uint256 index; index < data.length; ++index) {
            gas += data[index] == 0 ? 4 : 16;
        }
    }

    function _mockFeeds() private {
        address[2] memory feeds = [TSLA_USD, SOL_USD];
        for (uint256 index; index < feeds.length; ++index) {
            if (_feeds[feeds[index]].length == 0) continue;
            vm.mockCall(feeds[index], abi.encodeCall(IChainlinkAggregatorV3.latestRoundData, ()), _feeds[feeds[index]]);
        }
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
