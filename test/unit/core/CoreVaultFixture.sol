// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {
    Mandate,
    MandateLib,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {MockAcrossSpokePool as AcrossPoolStandIn} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";

/// @notice Shared deployment of a Core Vault against mocks: Arbitrum as hub (42161), Robinhood as the one spoke (4663).
/// @dev The test contract plays the factory (`CoreVaultConfig.factory`): `_deploy` seeds every fund at creation, as
///      `FundFactory.createFund` does (DEC-127), with the smallest seed that buys one whole share at 1.00 after the
///      flow fee, so the manager holds `SEED_SHARES` and Idle starts at `SEED_IDLE` (the Mandate minimum is 1 USDC
///      here).
abstract contract CoreVaultFixture is Test, FundSeed {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    uint32 internal constant MAX_REPORT_AGE = 1587;
    uint256 internal constant SPOKE_CAP = 100_000e6;
    bytes32 internal constant FUND_ID = keccak256("pool-party-fund-1");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");
    /// @dev 1.00 USDC per whole share in ShareMath scale.
    uint256 internal constant ONE = 1e24;

    CoreMockToken internal usdc;
    CoreMockToken internal weth;
    CoreMockToken internal usdg;
    CoreMockToken internal spokeWeth;
    MockPriceSource internal prices;
    MockManagerRegistry internal registry;
    MockAcrossSpokePool internal pool;
    MockBridgeAdapter internal bridge;
    MockHubSpokeVault internal hubVault;
    MockReportReceiver internal receiver;
    MockWormholeCore internal hubWormhole;
    TransitEscrow internal escrowImpl;
    CoreVault internal vault;
    ShareToken internal shares;

    address internal manager = makeAddr("manager");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal spokeVaultAddress = makeAddr("robinhoodSpokeVault");
    address internal hubAdapter = makeAddr("hubUniswapV4Adapter");
    address internal spokeAdapter = makeAddr("spokeUniswapV4Adapter");
    /// @dev Code-only swap adapters (DEC-136): a derived test may build a real Spoke Vault from this Mandate, which
    ///      pins them.
    address internal hubSwapAdapter;
    address internal spokeSwapAdapter;
    address internal spokeBridge = makeAddr("spokeAcrossAdapter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal ana = makeAddr("ana");
    address internal bruno = makeAddr("bruno");

    uint64 internal reportSequence;

    function setUp() public virtual {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);
        usdc = new CoreMockToken("USD Coin", "USDC", 6);
        weth = new CoreMockToken("Wrapped Ether", "WETH", 18);
        usdg = new CoreMockToken("Global Dollar", "USDG", 6);
        spokeWeth = new CoreMockToken("Robinhood WETH", "WETH", 18);
        hubSwapAdapter = address(new MockSwapAdapter());
        spokeSwapAdapter = address(new MockSwapAdapter());
        hubWormhole = new MockWormholeCore();
        prices = new MockPriceSource();
        prices.setPrice(address(weth), 2.5e9); // 2,500 USDC per WETH
        prices.setPrice(address(spokeWeth), 2.5e9);
        prices.setPrice(address(usdg), 1e18); // 1:1 (QB9 working assumption)
        registry = new MockManagerRegistry();
        pool = new MockAcrossSpokePool();
        bridge = new MockBridgeAdapter(address(pool));
        hubVault = new MockHubSpokeVault(address(usdc));
        receiver = new MockReportReceiver();
        receiver.setMaxReportAge(0, MAX_REPORT_AGE);
        escrowImpl = new TransitEscrow();
        vault = _deploy(_mandate(2000), _config(25));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    function _mandate(uint16 performanceFeeBps) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.usdc = address(usdc);
        m.addToken(HUB, address(usdc));
        m.addToken(HUB, address(weth));
        m.addToken(SPOKE, address(usdg));
        m.addToken(SPOKE, address(spokeWeth));
        m.addSwapAdapter(HUB, hubSwapAdapter);
        m.addSwapAdapter(SPOKE, spokeSwapAdapter);
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, hubAdapter);
        m.adapters[1] = AdapterConfig(SPOKE, spokeAdapter);
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, hubAdapter, HUB_POOL);
        m.pools[1] = PoolConfig(SPOKE, spokeAdapter, SPOKE_POOL);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVaultAddress))), address(usdg), SPOKE_CAP, MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(bridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, spokeBridge);
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = performanceFeeBps;
        m.managementFeeBps = 0;
    }

    function _config(uint16 flowFeeBps) internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = address(hubVault);
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(pool);
        c.wormholeCore = address(hubWormhole);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = flowFeeBps;
        c.factory = address(this);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    function _deploy(Mandate memory m, CoreVaultConfig memory c) internal returns (CoreVault v) {
        v = _deployUnseeded(m, c);
        _seedFund(address(v), address(usdc), c.flowFeeBps);
    }

    /// @dev A fund as the factory leaves it before the seed call (DEC-127): no shares yet.
    function _deployUnseeded(Mandate memory m, CoreVaultConfig memory c) internal returns (CoreVault v) {
        v = new CoreVault(m, c);
        hubVault.setCoreVault(address(v));
        receiver.setCoreVault(address(v));
        bridge.setVault(address(v));
        vault = v;
        shares = ShareToken(v.shareToken());
    }

    /// @dev The fixture's Core Vault with the real AcrossBridgeAdapter as its hub bridge adapter, over the offline
    ///      SpokePool stand-in (DEC-162: the adapter fixes the amount to arrive), with Alice's deposit and the spoke's
    ///      first report (S-14).
    function _deployWithAcross(uint256 aliceDeposit)
        internal
        returns (AcrossBridgeAdapter across, AcrossPoolStandIn acrossPool)
    {
        acrossPool = new AcrossPoolStandIn(1);
        address predictedVault = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        across = new AcrossBridgeAdapter(predictedVault, makeAddr("guardian"), address(acrossPool), address(0));
        Mandate memory m = _mandate(2000);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(across));
        _deploy(m, _config(25));
        assertEq(address(vault), predictedVault, "the adapter's vault");
        _deposit(alice, aliceDeposit);
        _ensureSpokeReport();
    }

    /// @dev A vault with no flow fee and the lowest performance fee a fund may have (DEC-184: 10%), for the worked
    ///      examples that predate DEC-106. The performance fee is charged on collected income only (ruling 2026-09-29),
    ///      so it leaves deposits, Share Prices and payouts as they were.
    function _deployAtMinimumFees() internal returns (CoreVault) {
        return _deploy(_mandate(MandateLib.MIN_PERFORMANCE_FEE_BPS), _config(0));
    }

    /// @dev What enters the shareholders' index out of `income` collected by a `_deployAtMinimumFees` vault: the income less
    ///      its 10% performance fee (DEC-107, DEC-184; `CoreVaultIncomeLogic.collectIncome` rounds the fee down).
    function _netOfMinimumFee(uint256 income) internal pure returns (uint256) {
        return income - income * MandateLib.MIN_PERFORMANCE_FEE_BPS / 10_000;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal returns (uint256 minted, uint256 charged) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        (minted, charged) = vault.deposit(amount, 0);
        vm.stopPrank();
    }

    function _request(address who, uint256 amount, ICoreVault.PayoutMode mode) internal {
        vm.prank(who);
        vault.requestPayout(amount, mode);
    }

    function _claim(address who) internal returns (ICoreVault.PayoutReceipt memory) {
        vm.prank(who);
        return vault.claimPayout("");
    }

    /// @dev `bridgeData` the mock bridge adapter reads as its amount to arrive (a stand-in for a quote an adapter
    ///      verifies itself). DEC-158, DEC-162: the Core Vault never reads it; the adapter fixes the amount.
    function _quote(uint256 outputAmount) internal pure returns (bytes memory) {
        return abi.encode(outputAmount);
    }

    function _send(uint256 amount, uint256 outputAmount) internal returns (bytes32 transitId) {
        _ensureSpokeReport();
        vm.prank(manager);
        transitId = vault.sendToSpoke(0, amount, 0, _quote(outputAmount));
    }

    /// @dev Security review S-14: the hub funds a spoke only once it accepted a report from it; the spoke's first
    ///      (empty) report, as a keeper relays it after `createSpoke`.
    function _ensureSpokeReport() internal {
        if (!receiver.hasReport(0)) _deliver(_spokeReport(0, 0));
    }

    /// @dev A Robinhood report with `unallocatedUsdg` and `cumulativeReceived`, built now, next sequence.
    function _spokeReport(uint256 unallocatedUsdg, uint256 cumulativeReceived)
        internal
        returns (ReportCodec.Report memory r)
    {
        r.fundId = FUND_ID;
        r.mandateHash = vault.mandateHash(); // S-6: a report of the spoke running the hub's Mandate
        r.sequence = ++reportSequence;
        r.spokeChainId = SPOKE;
        r.blockNumber = uint64(block.number);
        r.timestamp = uint64(block.timestamp);
        r.unallocated = new ReportCodec.TokenAmount[](1);
        r.unallocated[0] = ReportCodec.TokenAmount(address(usdg), unallocatedUsdg);
        r.cumulativeReceived = cumulativeReceived;
    }

    function _deliver(ReportCodec.Report memory r) internal {
        receiver.deliver(0, r);
    }

    function _arrived(ReportCodec.Report memory r, bytes32 transitId, uint256 amount)
        internal
        pure
        returns (ReportCodec.Report memory)
    {
        r.arrivedTransits = new ReportCodec.TransitAmount[](1);
        r.arrivedTransits[0] = ReportCodec.TransitAmount(transitId, amount);
        return r;
    }

    /// @dev A Principal transfer home in flight.
    function _inFlightToHub(ReportCodec.Report memory r, bytes32 transitId, uint256 amount)
        internal
        pure
        returns (ReportCodec.Report memory)
    {
        return _inFlightToHub(r, transitId, amount, TransferKind.Principal);
    }

    function _inFlightToHub(ReportCodec.Report memory r, bytes32 transitId, uint256 amount, TransferKind kind)
        internal
        pure
        returns (ReportCodec.Report memory)
    {
        r.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        r.inFlightToHub[0] = ReportCodec.HubBoundAmount(transitId, amount, kind);
        return r;
    }

    function _spokeIncome(ReportCodec.Report memory r, address token, uint256 cumulative)
        internal
        pure
        returns (ReportCodec.Report memory)
    {
        r.cumulativeIncome = new ReportCodec.TokenAmount[](1);
        r.cumulativeIncome[0] = ReportCodec.TokenAmount(token, cumulative);
        return r;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Measures
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-104: Share Assets rebuilt from its buckets, independently of the library.
    function _bucketSum() internal view returns (uint256 sum) {
        sum = vault.idle() + hubVault.unallocatedUsdc();
        (address token, uint256 principal) = (hubVault.positionToken(), hubVault.positionPrincipal());
        if (token == address(usdc)) sum += principal;
        else if (principal != 0) sum += principal * _price(token) / 1e18;
        sum += vault.inFlightValue();
        if (receiver.hasReport(0)) {
            (uint256 spokeValue,,,) = vault.spokeCapUsage(0);
            sum += spokeValue;
        }
    }

    function _price(address token) internal view returns (uint256 p) {
        (p,) = prices.priceInUsdc(token);
    }

    /// @dev USDC the vault holds that its ledger does not account for.
    function _ledgerUsdc() internal view returns (uint256) {
        return vault.idle() + vault.operatingCash() + vault.collectedIncome(address(usdc)) + vault.unmatchedArrivals();
    }
}
