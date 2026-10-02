// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../../utils/FundSeed.sol";
import {CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";

import {CoreVault} from "../../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../../src/report/ValueReportReceiver.sol";
import {AcrossBridgeAdapter} from "../../../../src/adapters/AcrossBridgeAdapter.sol";
import {ICoreVault} from "../../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind} from "../../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../../src/libraries/TransitMessage.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../../src/mandate/Mandate.sol";

import {CoreMockToken} from "../../../mocks/core/CoreMockTokens.sol";
import {MockPriceSource} from "../../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../../mocks/core/MockManagerRegistry.sol";
import {MockHubSpokeVault} from "../../../mocks/core/MockHubSpokeVault.sol";
import {MockCoreBridge} from "../../../mocks/receiver/MockCoreBridge.sol";
import {MockWormholeCore} from "../../../mocks/spoke/MockWormholeCore.sol";
import {MockPositionAdapter} from "../../../mocks/spoke/MockPositionAdapter.sol";
import {SecAcrossSpokePool} from "./SecAcrossSpokePool.sol";

/// @notice One fund across both chains in one EVM, for the cross-chain security proofs of concept.
/// @dev Real contracts: `CoreVault` (linked `CoreVaultLogic`), `ValueReportReceiver`, the Robinhood `SpokeVault` (linked
///      `SpokeCrossChainLib`), `AcrossBridgeAdapter` on both sides and `TransitEscrow`. Stand-ins, all from `test/mocks`
///      except the SpokePool: the Across SpokePools (`SecAcrossSpokePool`), the Wormhole Core on each chain (the spoke
///      one records published payloads, the hub one takes `abi.encode(CoreBridgeVM)` as a verified VAA), the hub Spoke
///      Vault, the price source and the manager registry. `block.chainid` is switched to the chain each call runs on;
///      both chains share one clock, as in `test/fork/e2e`.
abstract contract CrossChainFixture is Test, FundSeed {
    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    /// @dev Ruling 2026-09-29: the research value for Robinhood, 1,587 s plus one block.
    uint32 internal constant MAX_REPORT_AGE = 1588;
    uint32 internal constant FILL_DEADLINE = 21_600;
    bytes32 internal constant FUND_ID = keccak256("sec-crosschain-fund");
    bytes32 internal constant HUB_POOL = keccak256("hub WETH/USDC");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    CoreMockToken internal usdc;
    CoreMockToken internal usdg;
    CoreMockToken internal weth;
    CoreMockToken internal spokeWeth;
    MockPriceSource internal prices;
    MockManagerRegistry internal registry;
    MockHubSpokeVault internal hubVault;
    MockCoreBridge internal hubWormhole;
    MockWormholeCore internal spokeWormhole;
    SecAcrossSpokePool internal hubPool;
    SecAcrossSpokePool internal spokePool;
    TransitEscrow internal escrowImpl;

    AcrossBridgeAdapter internal hubBridge;
    AcrossBridgeAdapter internal spokeBridge;
    ValueReportReceiver internal receiver;
    CoreVault internal core;
    SpokeVault internal spoke;
    ShareToken internal shares;

    address internal spokeAdapter;
    bytes32 internal spokePoolKey;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal hubAdapter = makeAddr("hubUniswapV4Adapter");
    address internal relayer = makeAddr("relayer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    function setUp() public virtual {
        vm.warp(1_800_000_000);
        vm.chainId(HUB);
        usdc = new CoreMockToken("USD Coin", "USDC", 6);
        usdg = new CoreMockToken("Global Dollar", "USDG", 6);
        weth = new CoreMockToken("Wrapped Ether", "WETH", 18);
        spokeWeth = new CoreMockToken("Robinhood WETH", "WETH", 18);
        prices = new MockPriceSource();
        registry = new MockManagerRegistry();
        hubVault = new MockHubSpokeVault(address(usdc));
        hubWormhole = new MockCoreBridge();
        spokeWormhole = new MockWormholeCore();
        hubPool = new SecAcrossSpokePool();
        spokePool = new SecAcrossSpokePool();
        escrowImpl = new TransitEscrow();
        _refreshPrices();
        _beforeFundDeployment();

        // The fund's addresses are mutually dependent (the Mandate names the Spoke Vault and the bridge adapters, the
        // adapters name their vault), so they are predicted from this contract's nonce, as the factory predicts them
        // with CREATE3.
        uint256 nonce = vm.getNonce(address(this));
        address predictedSpokeAdapter = vm.computeCreateAddress(address(this), nonce);
        address predictedHubBridge = vm.computeCreateAddress(address(this), nonce + 1);
        address predictedSpokeBridge = vm.computeCreateAddress(address(this), nonce + 2);
        address predictedReceiver = vm.computeCreateAddress(address(this), nonce + 3);
        address predictedCore = vm.computeCreateAddress(address(this), nonce + 4);
        address predictedSpoke = vm.computeCreateAddress(address(this), nonce + 5);

        (spokeAdapter, spokePoolKey) = _deploySpokePositionAdapter(predictedSpoke);
        require(spokeAdapter == predictedSpokeAdapter, "fixture: spoke adapter address");

        hubBridge = new AcrossBridgeAdapter(predictedCore, guardian, address(hubPool));
        spokeBridge = new AcrossBridgeAdapter(predictedSpoke, guardian, address(spokePool));
        require(address(hubBridge) == predictedHubBridge && address(spokeBridge) == predictedSpokeBridge, "fixture");

        Mandate memory m = _mandate(predictedSpoke);
        receiver = new ValueReportReceiver(address(hubWormhole), predictedCore, FUND_ID, m.spokes, 0);
        require(address(receiver) == predictedReceiver, "fixture: receiver address");

        core = new CoreVault(m, _coreConfig());

        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).

        _seedFund(address(core), core.usdc(), core.flowFeeBps());
        require(address(core) == predictedCore, "fixture: core vault address");
        hubVault.setCoreVault(address(core));
        shares = ShareToken(core.shareToken());

        vm.chainId(SPOKE);
        spoke = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(spokeWormhole),
            address(escrowImpl),
            excess
        );
        require(address(spoke) == predictedSpoke, "fixture: spoke vault address");
        vm.chainId(HUB);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment hooks
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Anything a derived fixture must deploy before the fund's own contracts.
    function _beforeFundDeployment() internal virtual {}

    /// @dev Deploys the spoke's position adapter with exactly one CREATE from this contract and returns it with its
    ///      Mandate pool key. Default: the repository's position adapter mock with one WETH/USDG pool.
    function _deploySpokePositionAdapter(address predictedSpokeVault)
        internal
        virtual
        returns (address adapter, bytes32 poolKey)
    {
        MockPositionAdapter a = new MockPositionAdapter(guardian, false);
        a.addPool(SPOKE_POOL, address(spokeWeth), address(usdg));
        a.setVault(predictedSpokeVault);
        return (address(a), SPOKE_POOL);
    }

    function _spokeCap() internal pure virtual returns (uint256) {
        return 100_000e6;
    }

    function _mandate(address spokeVault_) internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, hubAdapter);
        m.adapters[1] = AdapterConfig(SPOKE, spokeAdapter);
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, hubAdapter, HUB_POOL);
        m.pools[1] = PoolConfig(SPOKE, spokeAdapter, spokePoolKey);
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(HUB, hubAdapter, HUB_POOL);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVault_))), address(usdg), _spokeCap(), MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(hubBridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridge));
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
    }

    function _coreConfig() internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = address(hubVault);
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(hubPool);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = 25;
        c.factory = address(this);
        c.incomeTokens = new address[](1);
        c.incomeTokens[0] = address(weth);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Hub actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Re-posts every price with the current time, as the next oracle round would (a mint reverts on a stale one).
    function _refreshPrices() internal {
        prices.setPrice(address(usdg), 1e18); // 1:1 (ruling 2026-09-29)
        prices.setPrice(address(weth), 2.5e9); // 2,500 USDC per WETH
        prices.setPrice(address(spokeWeth), 2.5e9);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 minted, uint256 charged) {
        vm.chainId(HUB);
        _refreshPrices();
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(core), amount);
        (minted, charged) = core.deposit(amount, 0);
        vm.stopPrank();
    }

    /// @dev DEC-162: the Across adapter's fee on a route with no expiry noted: `ceil(amount * 0.08%) + 0.03`.
    function _ruleFee(uint256 amount) internal pure returns (uint256) {
        return (amount * 8e14 + 1e18 - 1) / 1e18 + 30_000;
    }

    /// @dev Manager send to the spoke; returns the transit id and the Across deposit id on the hub SpokePool. DEC-158,
    ///      DEC-162: the manager passes no bridge parameter; the Across adapter fixes the amount to arrive.
    function _sendToSpoke(uint256 amount) internal returns (bytes32 transitId, uint256 depositId) {
        // Security review S-14: the hub funds a spoke only once it accepted a report from it.
        if (!receiver.hasReport(0)) _reportAndDeliver(0);
        vm.chainId(HUB);
        depositId = hubPool.numberOfDeposits();
        vm.prank(manager);
        transitId = core.sendToSpoke(0, amount, 0, "");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Spoke actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Manager send home; returns the transit id and the Across deposit id on the spoke pool. The quote argument
    ///      is vestigial (ignored since DEC-158 / DEC-162); the Across adapter fixes the amount to arrive.
    function _sendToHub(uint256 amount, TransferKind kind) internal returns (bytes32 transitId, uint256 depositId) {
        vm.chainId(SPOKE);
        depositId = spokePool.numberOfDeposits();
        BridgeQuote memory none;
        vm.prank(manager);
        transitId = spoke.sendToHub(amount, kind, 0, none);
        vm.chainId(HUB);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Across relays
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A relayer fills hub deposit `depositId` on the spoke.
    function _fillOnSpoke(uint256 depositId) internal {
        SecAcrossSpokePool.Deposit memory d = hubPool.deposit(depositId);
        vm.chainId(SPOKE);
        vm.prank(relayer);
        spokePool.fillRelay(d);
        vm.chainId(HUB);
    }

    /// @dev A relayer fills spoke deposit `depositId` on the hub.
    function _fillOnHub(uint256 depositId) internal {
        SecAcrossSpokePool.Deposit memory d = spokePool.deposit(depositId);
        vm.chainId(HUB);
        vm.prank(relayer);
        hubPool.fillRelay(d);
    }

    /// @dev A stranger reaches the spoke vault's `handleV3AcrossMessage` with a message of their choosing by filling a
    ///      relay nobody deposited (the destination SpokePool cannot tell), paying `amount` of USDG themselves.
    function _strangerFillOnSpoke(address who, bytes32 transitId, uint256 amount, TransferKind kind) internal {
        SecAcrossSpokePool.Deposit memory d;
        d.recipient = address(spoke);
        d.outputToken = address(usdg);
        d.outputAmount = amount;
        d.fillDeadline = uint32(block.timestamp);
        d.message = TransitMessage.encode(FUND_ID, HUB, transitId, kind);
        vm.chainId(SPOKE);
        vm.prank(who);
        spokePool.fillRelay(d);
        vm.chainId(HUB);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Wormhole
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Anyone publishes a report on the spoke; returns its index in the spoke Core's published list.
    function _publishReport() internal returns (uint256 index) {
        vm.chainId(SPOKE);
        spoke.report();
        index = spokeWormhole.publishedCount() - 1;
        vm.chainId(HUB);
    }

    /// @dev The VAA the guardians would sign for the published message `index`.
    function _vaa(uint256 index) internal view returns (bytes memory) {
        MockWormholeCore.Published memory p = spokeWormhole.published(index);
        CoreBridgeVM memory m;
        m.version = 1;
        m.timestamp = uint32(block.timestamp);
        m.nonce = p.nonce;
        m.emitterChainId = WH_SPOKE;
        m.emitterAddress = bytes32(uint256(uint160(p.emitter)));
        m.sequence = p.sequence;
        m.consistencyLevel = p.consistencyLevel;
        m.payload = p.payload;
        return abi.encode(m);
    }

    /// @dev Anyone delivers the VAA of published message `index` to the hub receiver.
    function _deliver(uint256 index) internal {
        vm.chainId(HUB);
        receiver.deliver(_vaa(index));
    }

    /// @dev Publishes a report now and delivers it after `finalityLag` seconds (finalized consistency, DEC-093).
    function _reportAndDeliver(uint256 finalityLag) internal {
        uint256 index = _publishReport();
        if (finalityLag != 0) skip(finalityLag);
        _deliver(index);
    }
}
