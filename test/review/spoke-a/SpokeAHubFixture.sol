// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
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

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {TransitEscrow} from "../../../src/core/TransitEscrow.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    SpokeConfig,
    BridgeAdapterConfig,
    OperatingCashConfig
} from "../../../src/mandate/Mandate.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockPriceSource} from "../../mocks/core/MockPriceSource.sol";
import {MockManagerRegistry} from "../../mocks/core/MockManagerRegistry.sol";
import {MockReportReceiver} from "../../mocks/core/MockReportReceiver.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockSwapAdapter} from "../../mocks/swap/MockSwapAdapter.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";

/// @notice Review fixture (spoke-a), adapted from the core-a fixture: a hub-only fund built from the REAL contracts on
///         the payout path: CoreVault (+ linked CoreVaultLogic), the hub SpokeVault (+ linked SpokeCrossChainLib) and
///         the real UniswapV4Adapter over MockV4 (PoolManager + PositionManager + StateView). A second Mandate adapter,
///         an exact-value USDC position (MockPositionAdapter, the Aave-like step), follows the V4 pool in the unwind
///         order. Only the price source, the manager registry and the unused report receiver are mocks besides it.
abstract contract SpokeAHubFixture is Test, FundSeed {
    using MandateFixture for Mandate;

    uint256 internal constant HUB = 42_161;
    bytes32 internal constant FUND_ID = keccak256("spoke-a review fund");
    /// @dev Oracle: 2,500 USDC per WETH, as IPriceSource price1e18 (USDC base units per wei, times 1e18).
    uint256 internal constant WETH_PRICE_1E18 = 2.5e9;
    /// @dev Half-width of the manager's range, in ticks (~10.5%).
    int24 internal constant HALF_RANGE = 1000;
    /// @dev Pool key of the exact-value USDC adapter (the Aave-like second unwind step).
    bytes32 internal constant EXACT_USDC = keccak256("exact-value USDC");

    MockToken internal usdc;
    MockToken internal weth;
    MockPermit2 internal permit2;
    MockV4 internal v4;
    MockPriceSource internal prices;
    MockManagerRegistry internal registry;
    MockReportReceiver internal receiver;
    TransitEscrow internal escrowImpl;

    UniswapV4Adapter internal adapter;
    MockPositionAdapter internal exact;
    SpokeVault internal hubVault;
    MockSwapAdapter internal hubSwap;
    MockWormholeCore internal hubWormhole;
    CoreVault internal vault;
    ShareToken internal shares;

    PoolKey internal key;
    bytes32 internal poolId;
    bool internal wethIsToken0;
    int24 internal tick0;
    uint160 internal sqrtP0;
    int24 internal tickLower;
    int24 internal tickUpper;
    bytes32 internal positionKey;

    address internal manager = makeAddr("manager");
    address internal guardian = makeAddr("guardian");
    address internal protocol = makeAddr("protocolRecipient");
    address internal excess = makeAddr("excessRecipient");
    address internal acrossHub = makeAddr("acrossHubSpokePool");
    address internal alice = makeAddr("alice");
    address internal mallory = makeAddr("mallory");

    function setUp() public virtual {
        vm.chainId(HUB);
        vm.warp(1_800_000_000);
        usdc = new MockToken("USDC", 6);
        weth = new MockToken("WETH", 18);
        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        prices = new MockPriceSource();
        prices.setPrice(address(weth), WETH_PRICE_1E18);
        registry = new MockManagerRegistry();
        receiver = new MockReportReceiver();
        escrowImpl = new TransitEscrow();
        exact = new MockPositionAdapter(guardian, true);
        exact.addPool(EXACT_USDC, address(usdc), address(0));
        _extraPools();

        // Pool WETH/USDC, fee 500, spacing 10, no hooks, initialized at the oracle price.
        wethIsToken0 = address(weth) < address(usdc);
        (address c0, address c1) = wethIsToken0 ? (address(weth), address(usdc)) : (address(usdc), address(weth));
        key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), 500, 10, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        uint256 sqrtP = wethIsToken0
            ? Math.sqrt(Math.mulDiv(2500e6, 1 << 192, 1e18))
            : Math.sqrt(Math.mulDiv(1e18, 1 << 192, 2500e6));
        sqrtP0 = uint160(sqrtP);
        v4.initialize(key, sqrtP0);
        (, tick0,,) = v4.getSlot0(PoolId.wrap(poolId));
        tickLower = (tick0 - HALF_RANGE) / 10 * 10;
        tickUpper = (tick0 + HALF_RANGE) / 10 * 10;

        // Circular wiring (adapter -> hub Spoke Vault -> Core Vault -> hub Spoke Vault): predict the three addresses.
        hubSwap = new MockSwapAdapter();
        hubWormhole = new MockWormholeCore();
        uint64 n = vm.getNonce(address(this));
        address adapterAt = vm.computeCreateAddress(address(this), n);
        address hubVaultAt = vm.computeCreateAddress(address(this), n + 1);
        address coreAt = vm.computeCreateAddress(address(this), n + 2);

        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        adapter = new UniswapV4Adapter(
            hubVaultAt,
            guardian,
            IPoolManager(address(v4)),
            IPositionManager(address(v4)),
            IStateView(address(v4)),
            IAllowanceTransfer(address(permit2)),
            keys
        );
        Mandate memory m = _mandate(address(adapter), address(exact));
        hubVault =
            new SpokeVault(m, FUND_ID, HUB, coreAt, address(usdc), acrossHub, address(0), address(escrowImpl), excess);
        vault = new CoreVault(m, _config(address(hubVault)));
        // DEC-127: this contract plays the factory and seeds the fund (FundSeed).
        _seedFund(address(vault), vault.usdc(), vault.flowFeeBps());
        require(address(adapter) == adapterAt && address(hubVault) == hubVaultAt && address(vault) == coreAt, "wiring");
        shares = ShareToken(vault.shareToken());
        exact.setVault(address(hubVault));

        // Reserves the mock protocol pays swap outputs and moved-price principal from.
        weth.mint(address(v4), 100_000e18);
        usdc.mint(address(v4), 100_000_000e6);
    }

    /// @dev Port hook: a variant registers more mock pools before the vaults read `poolTokens` at construction.
    function _extraPools() internal virtual {}

    function _mandate(address adapter_, address exact_) internal view virtual returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.hubWormholeChainId = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
        m.addToken(HUB, address(usdc));
        m.addToken(HUB, address(weth));
        m.addSwapAdapter(HUB, address(hubSwap));
        m.adapters = new AdapterConfig[](2);
        m.adapters[0] = AdapterConfig(HUB, adapter_);
        m.adapters[1] = AdapterConfig(HUB, exact_);
        m.pools = new PoolConfig[](2);
        m.pools[0] = PoolConfig(HUB, adapter_, poolId);
        m.pools[1] = PoolConfig(HUB, exact_, EXACT_USDC);
        // DEC-069: the V4 pool first, the exact-value USDC position second.
        m.spokes = new SpokeConfig[](0);
        m.bridgeAdapters = new BridgeAdapterConfig[](0);
        // DEC-127: no hub Operating Cash here. With a one-share seed, the first deposit's top-up (floor 1, top-up 3)
        // would take all of the seed's Idle before pricing and leave the Share Price at 0; these reviews are about
        // unwinds, not Operating Cash.
        m.operatingCash = new OperatingCashConfig[](0);
        m.payoutFeeBps = 200;
        m.minFirstDeposit = FIXTURE_MIN_FIRST_DEPOSIT;
        m.performanceFeeBps = 2000;
        m.managementFeeBps = 0;
    }

    function _config(address hubVault_) internal view returns (CoreVaultConfig memory c) {
        c.fundId = FUND_ID;
        c.usdc = address(usdc);
        c.hubSpokeVault = hubVault_;
        c.reportReceiver = address(receiver);
        c.managerRegistry = address(registry);
        c.priceSource = address(prices);
        c.acrossSpokePool = acrossHub;
        c.wormholeCore = address(hubWormhole);
        c.protocolRecipient = protocol;
        c.excessRecipient = excess;
        c.escrowImplementation = address(escrowImpl);
        c.flowFeeBps = 25;
        c.factory = address(this);
        c.shareName = "Pool Party Fund 1";
        c.shareSymbol = "PP-1";
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Actions
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal returns (uint256 minted) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(vault), amount);
        (minted,) = vault.deposit(amount, 0);
        vm.stopPrank();
    }

    /// @dev The manager allocates `usdcAmount` to the hub Spoke Vault, swaps half into WETH at the oracle price through
    ///      the Mandate swap adapter (DEC-136: never in the fund's pool) and opens a WETH/USDC position of +-HALF_RANGE
    ///      ticks around the current price with all of it.
    function _managerOpensHubPosition(uint256 usdcAmount) internal {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(usdcAmount);

        uint256 half = usdcAmount / 2;
        // The swap adapter stand-in swaps at a fixed rate: USDC -> WETH at 1 / 2,500.
        hubSwap.setPrice(address(usdc), address(weth), 1e18, 2500e6);
        vm.prank(manager);
        uint256 wethOut = hubVault.swap(address(hubSwap), address(usdc), address(weth), half, 0, "");

        (uint256 a0, uint256 a1) = wethIsToken0 ? (wethOut, usdcAmount - half) : (usdcAmount - half, wethOut);
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidity: 0,
                amount0Max: uint128(a0),
                amount1Max: uint128(a1),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (positionKey,,) = hubVault.openPosition(address(adapter), poolId, a0, a1, params);
    }

    /// @dev The automatic unwind sells through the Mandate swap adapter (DEC-136 item 4): its stand-in sells WETH into
    ///      USDC at the oracle price (2,500). MockV4 keeps that rate too, for the tests that trade in the pool.
    function _unwindSwapsAtOracle() internal {
        hubSwap.setPrice(address(weth), address(usdc), 2500e6, 1e18);
        v4.setSwap(2500e6, 10_000);
    }

    /// @dev The manager allocates `usdcAmount` more and supplies it to the exact-value USDC position.
    function _managerSuppliesExact(uint256 usdcAmount) internal returns (bytes32 exactKey) {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(usdcAmount);
        vm.prank(manager);
        (exactKey,,) = hubVault.openPosition(address(exact), EXACT_USDC, usdcAmount, 0, "");
    }

    /// @dev `who` opens a Payout Request with no maximum loss; an Instant one is its own claim (DEC-120 item 1), so its
    ///      receipt comes back here.
    function _request(address who, uint256 amount, ICoreVault.PayoutMode mode)
        internal
        returns (ICoreVault.PayoutReceipt memory)
    {
        vm.prank(who);
        return vault.requestPayout(amount, mode, 0);
    }

    /// @dev `who` claims its open request (a Standard one after its term, or the next attempt of a partial one).
    function _claim(address who) internal returns (ICoreVault.PayoutReceipt memory) {
        vm.prank(who);
        return vault.claimPayout(0);
    }

    /// @dev The pool state a swap leaves: the WETH spot price is divided by `factor` (the Chainlink price does not
    ///      move). In a real pool a WETH seller gets here; the fork PoC does it with real swaps.
    function _crushWethSpot(uint256 factor) internal {
        // ln(factor) / ln(1.0001) ticks; WETH token0: a lower WETH price is a lower tick.
        int24 delta = int24(int256(_log10001(factor)));
        v4.setTick(poolId, wethIsToken0 ? tick0 - delta : tick0 + delta);
    }

    /// @dev The swap back: the spot returns exactly to where it was (the oracle price).
    function _restoreSpot() internal {
        v4.initialize(key, sqrtP0);
    }

    /// @dev Share value of `who` at the current Share Price (fair spot restored by the caller).
    function _valueOf(address who) internal view returns (uint256) {
        return Math.mulDiv(shares.balanceOf(who), vault.shareAssets(), shares.totalSupply());
    }

    /// @dev floor(ln(x) / ln(1.0001)) for x >= 1, by repeated multiplication in 1e18 fixed point (test helper only).
    function _log10001(uint256 x) internal pure returns (uint256 ticks) {
        uint256 target = x * 1e18;
        uint256 v = 1e18;
        // Coarse steps of 1,000 ticks (1.0001^1000 = 1.105165...), then single ticks.
        while (v * 1_105_165_392_646_106_700 / 1e18 <= target) {
            v = v * 1_105_165_392_646_106_700 / 1e18;
            ticks += 1000;
        }
        while (v * 10_001 / 10_000 <= target) {
            v = v * 10_001 / 10_000;
            ++ticks;
        }
    }
}
