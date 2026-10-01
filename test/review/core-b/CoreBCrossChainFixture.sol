// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";

import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockAcrossSpokePool as HubAcrossMock} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockBridgeAdapter as HubBridgeMock} from "../../mocks/core/MockBridgeAdapter.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockBridgeAdapter as SpokeBridgeMock} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockAcrossSpokePool as SpokeAcrossMock} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";

/// @notice Review fixture (core-b): one fund, one Mandate, wired end to end on the cross-chain path with the REAL
///         contracts: CoreVault (+ linked CoreVaultLogic), ValueReportReceiver (over a Core Bridge stand-in that accepts
///         the VAA as `abi.encode(CoreBridgeVM)`), ManagerRegistry, and the Robinhood SpokeVault (+ linked
///         SpokeCrossChainLib) that builds and publishes every report the hub receives. Mocked: the tokens, the price
///         source, both Across SpokePools (a fill is simulated by the pool calling the recipient's handler), the bridge
///         adapters' call building, the spoke position adapter, the Wormhole Core on the spoke (records the payload) and
///         the hub Spoke Vault (never used by these PoCs beyond construction).
abstract contract CoreBCrossChainFixture is Test {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    /// @dev Research value for Robinhood (1,587 s) plus one block, as the tests of the repository use.
    uint32 internal constant MAX_REPORT_AGE = 1588;
    uint256 internal constant SPOKE_CAP = 100_000e6;
    bytes32 internal constant FUND_ID = keccak256("core-b review fund");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    CoreMockToken internal usdc;
    CoreMockToken internal usdg;
    CoreMockToken internal weth;
    CoreMockToken internal spokeWeth;
    MockPriceSource internal prices;
    ManagerRegistry internal registry;

    HubAcrossMock internal hubAcross;
    HubBridgeMock internal hubBridge;
    MockHubSpokeVault internal hubVault;
    MockCoreBridge internal coreBridge;
    ValueReportReceiver internal receiver;
    TransitEscrow internal escrowImpl;
    CoreVault internal vault;
    ShareToken internal shares;

    SpokeAcrossMock internal spokeAcross;
    SpokeBridgeMock internal spokeBridge;
    MockPositionAdapter internal spokeAdapter;
    MockWormholeCore internal wormhole;
    SpokeVault internal spoke;

    address internal manager = makeAddr("manager");
    address internal protocolAdmin = makeAddr("protocolAdmin");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal guardian = makeAddr("guardian");
    address internal hubAdapter = makeAddr("hubUniswapV4Adapter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    uint256 internal dustNonce;

    function setUp() public virtual {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);
        usdc = new CoreMockToken("USD Coin", "USDC", 6);
        usdg = new CoreMockToken("Global Dollar", "USDG", 6);
        weth = new CoreMockToken("Wrapped Ether", "WETH", 18);
        spokeWeth = new CoreMockToken("Robinhood WETH", "WETH", 18);
        prices = new MockPriceSource();
        _refreshPrices();
        registry = new ManagerRegistry(protocolAdmin);

        hubAcross = new HubAcrossMock();
        hubBridge = new HubBridgeMock(address(hubAcross));
        hubVault = new MockHubSpokeVault(address(usdc));
        coreBridge = new MockCoreBridge();
        escrowImpl = new TransitEscrow();

        spokeAcross = new SpokeAcrossMock();
        spokeBridge = new SpokeBridgeMock(guardian, address(spokeAcross));
        spokeAdapter = new MockPositionAdapter(guardian, false);
        spokeAdapter.addPool(SPOKE_POOL, address(spokeWeth), address(usdg));
        wormhole = new MockWormholeCore();

        // Circular wiring: spoke vault (Mandate recipient and report emitter) -> receiver -> Core Vault.
        uint64 n = vm.getNonce(address(this));
        address spokeAt = vm.computeCreateAddress(address(this), n);
        address receiverAt = vm.computeCreateAddress(address(this), n + 1);
        address coreAt = vm.computeCreateAddress(address(this), n + 2);

        Mandate memory m = _mandate(spokeAt);
        vm.chainId(SPOKE);
        spoke = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            coreAt,
            address(usdg),
            address(spokeAcross),
            address(wormhole),
            address(escrowImpl),
            excess
        );
        vm.chainId(HUB);
        receiver = new ValueReportReceiver(address(coreBridge), coreAt, FUND_ID, m.spokes, 0);
        vault = new CoreVault(m, _config(receiverAt));
        require(address(spoke) == spokeAt && address(receiver) == receiverAt && address(vault) == coreAt, "wiring");
        shares = ShareToken(vault.shareToken());

        hubVault.setCoreVault(address(vault));
        hubBridge.setVault(address(vault));
        spokeBridge.setVault(address(spoke));
        spokeAdapter.setVault(address(spoke));
    }

    function _mandate(address spokeVault_) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, hubAdapter);
        m.adapters[1] = AdapterConfig(SPOKE, address(spokeAdapter));
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, hubAdapter, HUB_POOL);
        m.pools[1] = PoolConfig(SPOKE, address(spokeAdapter), SPOKE_POOL);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, hubAdapter, HUB_POOL);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVault_))), address(usdg), SPOKE_CAP, MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(hubBridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridge));
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.standardPayoutTerm = 72 hours;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
        m.maxBridgeFeeBps = 50;
    }

    function _config(address receiver_) internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = address(hubVault);
        c.reportReceiver = receiver_;
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(hubAcross);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = 25;
        c.incomeTokens = new address[](1);
        c.incomeTokens[0] = address(weth);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function _refreshPrices() internal {
        prices.setPrice(address(usdg), 1e18);
        prices.setPrice(address(weth), 2.5e9);
        prices.setPrice(address(spokeWeth), 2.5e9);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 minted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        (minted,) = vault.deposit(amount, 0);
        vm.stopPrank();
    }

    function _quote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote({
            outputAmount: outputAmount,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0)
        });
    }

    /// @dev Manager: hub -> spoke send of `amount` USDC, `output` USDG to arrive.
    function _sendToSpoke(uint256 amount, uint256 output) internal returns (bytes32 transitId) {
        vm.prank(manager);
        transitId = vault.sendToSpoke(0, amount, 0, _quote(output));
    }

    /// @dev A relayer fill of a hub -> spoke transit on Robinhood: USDG to the Spoke Vault, handler called by the pool.
    function _fillOnSpoke(bytes32 transitId, uint256 amount) internal {
        usdg.mint(address(spokeAcross), amount);
        spokeAcross.fill(
            address(spoke),
            address(usdg),
            amount,
            TransitMessage.encode(FUND_ID, HUB, transitId, TransferKind.Principal)
        );
    }

    /// @dev A stranger's (or the manager's) own Across deposit to the Spoke Vault with a fresh id, filled: 1 USDG.
    function _dustArrival() internal {
        _fillOnSpoke(keccak256(abi.encode("dust", ++dustNonce)), 1e6);
    }

    /// @dev A relayer fill of a spoke -> hub transfer on Arbitrum: USDC to the Core Vault, handler called by the pool.
    function _fillOnHub(bytes32 transitId, uint256 amount, TransferKind kind) internal {
        hubAcross.fill(address(vault), address(usdc), amount, TransitMessage.encode(FUND_ID, SPOKE, transitId, kind));
    }

    /// @dev Anyone: `report()` on the spoke (the real Spoke Vault builds and publishes the payload).
    function _publish() internal returns (bytes memory payload, uint64 wormholeSequence) {
        (, wormholeSequence) = spoke.report();
        payload = wormhole.published(wormhole.publishedCount() - 1).payload;
    }

    /// @dev Anyone: delivers a published payload to the real ValueReportReceiver as a VAA of the fund's Spoke Vault.
    function _deliverVaa(bytes memory payload, uint64 wormholeSequence) internal {
        CoreBridgeVM memory vmm;
        vmm.version = 1;
        vmm.timestamp = uint32(block.timestamp);
        vmm.emitterChainId = WH_SPOKE;
        vmm.emitterAddress = bytes32(uint256(uint160(address(spoke))));
        vmm.sequence = wormholeSequence;
        vmm.consistencyLevel = 1;
        vmm.payload = payload;
        vmm.signatures = new GuardianSignature[](0);
        vm.prank(keeper);
        receiver.deliver(abi.encode(vmm));
    }

    /// @dev The keeper publishes a report on the spoke and delivers it on the hub at once.
    function _report() internal {
        (bytes memory payload, uint64 seq) = _publish();
        _deliverVaa(payload, seq);
    }

    function _latest() internal view returns (ReportCodec.Report memory r) {
        (r,,) = receiver.latestReport(0);
    }

    function _capUsed() internal view returns (uint256 used) {
        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub,) = vault.spokeCapUsage(0);
        used = spokeValue + inFlightSent + inFlightToHub;
    }
}
