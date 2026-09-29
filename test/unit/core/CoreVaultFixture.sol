// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
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
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";

/// @notice Shared deployment of a Core Vault against mocks: Arbitrum as hub (42161), Robinhood as the one spoke (4663).
abstract contract CoreVaultFixture is Test {
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
    TransitEscrow internal escrowImpl;
    CoreVault internal vault;
    ShareToken internal shares;

    address internal manager = makeAddr("manager");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal spokeVaultAddress = makeAddr("robinhoodSpokeVault");
    address internal hubAdapter = makeAddr("hubUniswapV4Adapter");
    address internal spokeAdapter = makeAddr("spokeUniswapV4Adapter");
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
        m.usdc = address(usdc);
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, hubAdapter);
        m.adapters[1] = AdapterConfig(SPOKE, spokeAdapter);
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, hubAdapter, HUB_POOL);
        m.pools[1] = PoolConfig(SPOKE, spokeAdapter, SPOKE_POOL);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, hubAdapter, HUB_POOL);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVaultAddress))), address(usdg), SPOKE_CAP, MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(bridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, spokeBridge);
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.standardPayoutTerm = 72 hours;
        m.minFirstDeposit = 100e6;
        m.performanceFeeBps = performanceFeeBps;
        m.managementFeeBps = 0;
        m.maxBridgeFeeBps = 50;
    }

    function _config(uint16 flowFeeBps) internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = address(hubVault);
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(pool);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = flowFeeBps;
        c.incomeTokens = new address[](1);
        c.incomeTokens[0] = address(weth);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    function _deploy(Mandate memory m, CoreVaultConfig memory c) internal returns (CoreVault v) {
        v = new CoreVault(m, c);
        hubVault.setCoreVault(address(v));
        receiver.setCoreVault(address(v));
        bridge.setVault(address(v));
        vault = v;
        shares = ShareToken(v.shareToken());
    }

    /// @dev A vault with no flow fee and no performance fee, for the worked examples that predate DEC-106.
    function _deployFeeless() internal returns (CoreVault) {
        return _deploy(_mandate(0), _config(0));
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

    function _quote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote({
            outputAmount: outputAmount,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: 0,
            exclusiveRelayer: address(0)
        });
    }

    function _send(uint256 amount, uint256 outputAmount) internal returns (bytes32 transitId) {
        vm.prank(manager);
        transitId = vault.sendToSpoke(0, amount, 0, _quote(outputAmount));
    }

    /// @dev A Robinhood report with `unallocatedUsdg` and `cumulativeReceived`, built now, next sequence.
    function _spokeReport(uint256 unallocatedUsdg, uint256 cumulativeReceived)
        internal
        returns (ReportCodec.Report memory r)
    {
        r.fundId = FUND_ID;
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

    function _inFlightToHub(ReportCodec.Report memory r, bytes32 transitId, uint256 amount)
        internal
        pure
        returns (ReportCodec.Report memory)
    {
        r.inFlightToHub = new ReportCodec.TransitAmount[](1);
        r.inFlightToHub[0] = ReportCodec.TransitAmount(transitId, amount);
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
            (uint256 spokeValue,,) = vault.spokeCapUsage(0);
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
