// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FundSeed} from "../../utils/FundSeed.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";

import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockAcrossSpokePool as HubAcrossPool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockBridgeAdapter as HubBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {MockAcrossSpokePool as SpokeAcrossPool} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockBridgeAdapter as SpokeBridgeAdapter} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockBridgeNextArrive} from "../../mocks/across/MockBridgeNextArrive.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";

/// @title AccountingPocFixture
/// @notice Shared deployment for the accounting security proofs of concept: one fund made of the REAL production
///         contracts (CoreVault linked to CoreVaultLogic, hub SpokeVault and Robinhood SpokeVault linked to
///         SpokeCrossChainLib, UniswapV4Adapter on the hub, ValueReportReceiver, ShareToken, ManagerFeeVault,
///         TransitEscrow), wired to the repository's existing protocol mocks (Uniswap V4, Across, Wormhole Core,
///         price source, manager registry). Nothing under `src/` is modified and no mock is modified.
/// @dev One EVM state plays both chains: `vm.chainId` is switched only while a vault is constructed (the vaults read
///      `block.chainid` in their constructors only, apart from the hub transit id). A report travels exactly as in
///      production: `SpokeVault.report()` publishes the payload through the Wormhole mock, and the published bytes
///      are delivered to the real `ValueReportReceiver` wrapped in a VAA the Core Bridge mock accepts.
abstract contract AccountingPocFixture is Test, FundSeed {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    uint256 internal constant SPOKE = 4663;
    uint16 internal constant WH_SPOKE = 72;
    /// @dev Ruling 2026-09-29: Robinhood report lifetime, 1,587 s plus one block.
    uint32 internal constant MAX_REPORT_AGE = 1588;
    /// @dev DEC-066: Across fill deadline, both directions.
    uint32 internal constant FILL_DEADLINE = 21_600;
    /// @dev Typical age of a finalized Wormhole VAA from Robinhood Chain (DEC-086: about 925 to 1,190 s).
    uint256 internal constant VAA_FINALITY = 1000;
    uint256 internal constant SPOKE_CAP = 5_000_000e6;
    bytes32 internal constant FUND_ID = keccak256("sec-accounting-fund");
    bytes32 internal constant SPOKE_POOL = keccak256("spoke WETH/USDG");

    /// @dev Hub Uniswap V4 pool: WETH (currency0, 18 decimals) / USDC (currency1, 6 decimals), 0.05 %, spacing 10.
    uint24 internal constant POOL_FEE_PIPS = 500;
    int24 internal constant TICK_SPACING = 10;
    /// @dev 1.0001^-198080 = 2.49994e-9 USDC units per WETH unit, i.e. about 2,499.94 USDC per WETH.
    int24 internal constant TICK_FAIR = -198_080;

    CoreMockToken internal usdc;
    CoreMockToken internal weth;
    CoreMockToken internal usdg;
    CoreMockToken internal spokeWeth;

    MockPriceSource internal prices;
    MockManagerRegistry internal registry;
    HubAcrossPool internal hubAcross;
    HubBridgeAdapter internal hubBridge;
    SpokeAcrossPool internal spokeAcross;
    SpokeBridgeAdapter internal spokeBridge;
    MockPositionAdapter internal spokeUni;
    MockSwapAdapter internal hubSwap;
    MockSwapAdapter internal spokeSwap;
    MockWormholeCore internal spokeWormhole;
    MockCoreBridge internal hubWormhole;
    MockV4 internal v4;
    MockPermit2 internal permit2;
    TransitEscrow internal escrowImpl;

    UniswapV4Adapter internal hubV4;
    ValueReportReceiver internal receiver;
    CoreVault internal core;
    SpokeVault internal hubVault;
    SpokeVault internal spokeVault;
    ShareToken internal shares;

    PoolKey internal hubKey;
    bytes32 internal hubPoolId;
    /// @dev IPriceSource scale: USDC base units per WETH base unit, times 1e18, equal to the pool's fair price.
    uint256 internal wethPrice1e18;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal alice = makeAddr("alice");
    address internal keeper = makeAddr("keeper");

    uint64 internal wormholeSequence;

    // ---------------------------------------------------------------------------------------------------------------
    // Deployment
    // ---------------------------------------------------------------------------------------------------------------

    /// @param performanceFeeBps Mandate performance fee (DEC-107).
    /// @param flowFeeBps Protocol flow fee (DEC-106).
    function _deployFund(uint16 performanceFeeBps, uint16 flowFeeBps) internal {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);

        usdc = new CoreMockToken("USD Coin", "USDC", 6);
        weth = new CoreMockToken("Wrapped Ether", "WETH", 18);
        // Uniswap V4 orders currencies by address; keep WETH as currency0 so the pool price reads USDC per WETH.
        while (address(weth) > address(usdc)) weth = new CoreMockToken("Wrapped Ether", "WETH", 18);
        usdg = new CoreMockToken("Global Dollar", "USDG", 6);
        spokeWeth = new CoreMockToken("Robinhood WETH", "WETH", 18);

        prices = new MockPriceSource();
        registry = new MockManagerRegistry();
        hubAcross = new HubAcrossPool();
        hubBridge = new HubBridgeAdapter(address(hubAcross));
        spokeAcross = new SpokeAcrossPool();
        spokeBridge = new SpokeBridgeAdapter(guardian, address(spokeAcross));
        spokeUni = new MockPositionAdapter(guardian, false);
        spokeUni.addPool(SPOKE_POOL, address(spokeWeth), address(usdg));
        hubSwap = new MockSwapAdapter();
        spokeSwap = new MockSwapAdapter();
        spokeWormhole = new MockWormholeCore();
        hubWormhole = new MockCoreBridge();
        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        escrowImpl = new TransitEscrow();

        hubKey = PoolKey(
            Currency.wrap(address(weth)), Currency.wrap(address(usdc)), POOL_FEE_PIPS, TICK_SPACING, IHooks(address(0))
        );
        hubPoolId = PoolId.unwrap(hubKey.toId());
        uint160 sqrtFair = TickMath.getSqrtPriceAtTick(TICK_FAIR);
        v4.initialize(hubKey, sqrtFair);
        // The oracle agrees with the pool: price1e18 = sqrtPrice^2 / 2^192 * 1e18.
        wethPrice1e18 = Math.mulDiv(Math.mulDiv(sqrtFair, sqrtFair, 1 << 96), 1e18, 1 << 96);
        _refreshPrices();
        // Reserves that back swap outputs and fees inside the Uniswap V4 mock.
        weth.mint(address(v4), 1_000_000e18);
        usdc.mint(address(v4), 1_000_000_000e6);

        // The five fund contracts know each other's addresses before they exist (CREATE3 in production).
        uint256 nonce = vm.getNonce(address(this));
        address adapterAt = vm.computeCreateAddress(address(this), nonce);
        address receiverAt = vm.computeCreateAddress(address(this), nonce + 1);
        address coreAt = vm.computeCreateAddress(address(this), nonce + 2);
        address hubVaultAt = vm.computeCreateAddress(address(this), nonce + 3);
        address spokeVaultAt = vm.computeCreateAddress(address(this), nonce + 4);

        Mandate memory m = _mandate(adapterAt, spokeVaultAt, performanceFeeBps);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = hubKey;

        hubV4 = new UniswapV4Adapter(
            hubVaultAt,
            guardian,
            IPoolManager(address(v4)),
            IPositionManager(address(v4)),
            IStateView(address(v4)),
            IAllowanceTransfer(address(permit2)),
            keys
        );
        receiver = new ValueReportReceiver(address(hubWormhole), coreAt, FUND_ID, m.spokes, 0);
        core = new CoreVault(m, _config(receiverAt, hubVaultAt, flowFeeBps));
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).
        _seedFund(address(core), core.usdc(), core.flowFeeBps());
        hubVault = new SpokeVault(
            m, FUND_ID, HUB, coreAt, address(usdc), address(hubAcross), address(0), address(escrowImpl), excess
        );
        vm.chainId(SPOKE);
        spokeVault = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            coreAt,
            address(usdg),
            address(spokeAcross),
            address(spokeWormhole),
            address(escrowImpl),
            excess
        );
        vm.chainId(HUB);

        require(address(hubV4) == adapterAt && address(receiver) == receiverAt, "fixture: prediction");
        require(address(core) == coreAt && address(hubVault) == hubVaultAt, "fixture: prediction");
        require(address(spokeVault) == spokeVaultAt, "fixture: prediction");

        hubBridge.setVault(address(core));
        spokeBridge.setVault(address(spokeVault));
        spokeUni.setVault(address(spokeVault));
        shares = ShareToken(core.shareToken());
    }

    function _mandate(address hubAdapter, address spokeVaultAt, uint16 performanceFeeBps)
        internal
        view
        returns (Mandate memory m)
    {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, address(usdc));
        m.addToken(HUB, address(weth));
        m.addToken(SPOKE, address(usdg));
        m.addToken(SPOKE, address(spokeWeth));
        m.addSwapAdapter(HUB, address(hubSwap));
        m.addSwapAdapter(SPOKE, address(spokeSwap));
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, hubAdapter);
        m.adapters[1] = AdapterConfig(SPOKE, address(spokeUni));
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, hubAdapter, hubPoolId);
        m.pools[1] = PoolConfig(SPOKE, address(spokeUni), SPOKE_POOL);
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVaultAt))), address(usdg), SPOKE_CAP, MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, address(hubBridge));
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridge));
        // No Operating Cash floor: the proofs isolate the base arithmetic from top-ups (DEC-096).
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = performanceFeeBps;
        m.managementFeeBps = 0;
    }

    function _config(address receiverAt, address hubVaultAt, uint16 flowFeeBps)
        internal
        view
        returns (CoreVaultConfig memory c)
    {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = hubVaultAt;
        c.reportReceiver = receiverAt;
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = address(hubAcross);
        c.wormholeCore = address(hubWormhole);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = flowFeeBps;
        c.factory = address(this);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Re-posts every price with the current time, as the next Chainlink round (WETH) or a fixed 1:1 token
    ///      (USDG, whose production `updatedAt` is always the current block) would: a mint reverts on a stale price.
    function _refreshPrices() internal {
        prices.setPrice(address(weth), wethPrice1e18);
        prices.setPrice(address(spokeWeth), wethPrice1e18);
        prices.setPrice(address(usdg), 1e18);
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 minted, uint256 charged) {
        _refreshPrices();
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(core), amount);
        (minted, charged) = core.deposit(amount, 0);
        vm.stopPrank();
    }

    /// @dev DEC-158, DEC-162: the vaults pass no amount to arrive; the mock bridge adapters fix it. On the hub the
    ///      mock reads this `bridgeData` word as its amount (a stand-in for a quote an adapter verifies itself).
    function _quote(uint256 outputAmount) internal pure returns (bytes memory) {
        return abi.encode(outputAmount);
    }

    /// @dev Manager sends Idle to the Robinhood Spoke Vault through Across.
    function _sendToSpoke(uint256 amount, uint256 outputAmount) internal returns (bytes32 transitId) {
        // Security review S-14: the hub funds a spoke only once it accepted a report from it.
        if (!receiver.hasReport(0)) {
            bytes memory vaa = _publishReport();
            vm.prank(keeper);
            receiver.deliver(vaa);
        }
        vm.prank(manager);
        transitId = core.sendToSpoke(0, amount, 0, _quote(outputAmount));
    }

    /// @dev An Across relayer fills a hub-to-spoke deposit on Robinhood Chain.
    function _fillOnSpoke(bytes32 transitId, uint256 amount) internal {
        usdg.mint(address(spokeAcross), amount);
        spokeAcross.fill(
            address(spokeVault),
            address(usdg),
            amount,
            TransitMessage.encode(FUND_ID, HUB, transitId, TransferKind.Principal)
        );
    }

    /// @dev Manager sends Unallocated Balance (or collected income) home through Across.
    function _sendHome(uint256 amount, uint256 outputAmount, TransferKind kind) internal returns (bytes32 transitId) {
        // The spoke's mock adapter delivers `outputAmount`; the Spoke Vault ignores its vestigial quote argument.
        MockBridgeNextArrive.set(address(spokeBridge), outputAmount);
        BridgeQuote memory none;
        vm.prank(manager);
        transitId = spokeVault.sendToHub(amount, kind, 0, none);
    }

    /// @dev An Across relayer fills a spoke-to-hub deposit on Arbitrum: USDC to the Core Vault with the message.
    function _fillOnHub(bytes32 transitId, uint256 amount, TransferKind kind) internal {
        hubAcross.fill(address(core), address(usdc), amount, TransitMessage.encode(FUND_ID, SPOKE, transitId, kind));
    }

    /// @dev Anyone publishes a value report on the spoke (permissionless, DEC-070) and gets the VAA the guardians
    ///      will sign for it.
    function _publishReport() internal returns (bytes memory vaa) {
        vm.prank(keeper);
        spokeVault.report();
        MockWormholeCore.Published memory p = spokeWormhole.published(spokeWormhole.publishedCount() - 1);
        CoreBridgeVM memory m;
        m.version = 1;
        m.emitterChainId = WH_SPOKE;
        m.emitterAddress = bytes32(uint256(uint160(address(spokeVault))));
        m.sequence = p.sequence;
        m.consistencyLevel = p.consistencyLevel;
        m.payload = p.payload;
        m.signatures = new GuardianSignature[](0);
        return abi.encode(m);
    }

    /// @dev Publishes a report, waits for finality and delivers it to the hub receiver (DEC-093: anyone delivers).
    function _reportAndDeliver() internal {
        bytes memory vaa = _publishReport();
        vm.warp(block.timestamp + VAA_FINALITY);
        vm.prank(keeper);
        receiver.deliver(vaa);
    }

    /// @dev The Manager moves `usdcAmount` of Idle into one hub Uniswap V4 position centred on the fair price: half is
    ///      swapped to WETH at the oracle price through the Mandate swap adapter (a stand-in at a fixed rate, DEC-136),
    ///      then both legs enter the range `TICK_FAIR +- halfWidthTicks`. Returns the position key (the
    ///      PositionManager token id).
    function _openHubPosition(uint256 usdcAmount, int24 halfWidthTicks) internal returns (bytes32 positionKey) {
        return _openHubPositionAt(usdcAmount, TICK_FAIR - halfWidthTicks, TICK_FAIR + halfWidthTicks);
    }

    /// @dev Same, in the range `[tickLower, tickUpper]`.
    function _openHubPositionAt(uint256 usdcAmount, int24 tickLower, int24 tickUpper)
        internal
        returns (bytes32 positionKey)
    {
        uint256 half = usdcAmount / 2;
        // WETH base units per USDC base unit, 1e18-scaled: the inverse of the oracle price.
        hubSwap.setPrice(address(usdc), address(weth), 1e36 / wethPrice1e18, 1e18);
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(usdcAmount);
        uint256 wethOut = hubVault.swap(address(hubSwap), address(usdc), address(weth), half, 0, "");
        UniswapV4Adapter.OpenParams memory p = UniswapV4Adapter.OpenParams({
            tickLower: tickLower,
            tickUpper: tickUpper,
            liquidity: 0,
            amount0Max: uint128(wethOut),
            amount1Max: uint128(usdcAmount - half),
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        (positionKey,,) = hubVault.openPosition(address(hubV4), hubPoolId, wethOut, usdcAmount - half, abi.encode(p));
        vm.stopPrank();
    }

    /// @dev USDC value of `holder`'s shares at the current Share Price (DEC-061: truncated to 6 decimals).
    function _valueOf(address holder) internal view returns (uint256) {
        return ShareMath.usdcFor(shares.balanceOf(holder), core.sharePrice());
    }
}
