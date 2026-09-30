// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {FactoryDeployment} from "../../../script/FactoryDeployment.sol";
import {FundMandate} from "../../../script/FundMandate.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";

/// @notice Shared state and helpers of the end-to-end fork scenario: one fund driven across the pinned Arbitrum One (Hub
///         Chain) and Robinhood Chain (Spoke Chain) forks in one test contract (docs/ARCHITECTURE.md §7).
/// @dev Both forks are created with `vm.createFork` and switched with `vm.selectFork`; each keeps its own state. The
///      test contract is persistent, so the scenario's books (addresses, keys, the Across message, the published
///      Wormhole message) live in its storage across switches.
/// @dev One scenario clock: the two pinned blocks are minutes apart, and a spoke report is judged on the hub clock
///      (DEC-099), so every switch warps the selected fork to the latest time either fork has reached.
/// @dev Live prices move between runs, so the scenario asserts relations and bounds, never market numbers.
abstract contract EndToEndBase is Test, FactoryDeployment, FundMandate {
    // -----------------------------------------------------------------------------------------------------------------
    // Scenario parameters
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev docs/INTEGRATIONS.md fork-test pools (hookless, 0.05%, tick spacing 10).
    bytes32 internal constant ARB_WETH_USDC_POOL_ID =
        0xfc7b3ad139daaf1e9c3637ed921c154d1b04286f8a82b805a6c352da57028653;
    bytes32 internal constant RH_WETH_USDG_POOL_ID = 0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593;
    int24 internal constant TICK_SPACING = 10;

    /// @dev Ana's first deposit and the Spoke Cap at 40% of it, in USDC (DEC-037, DEC-095).
    uint256 internal constant ANA_DEPOSIT = 10_000e6;
    uint256 internal constant SPOKE_CAP = ANA_DEPOSIT * 40 / 100;
    /// @dev Ruling 2026-09-29: Robinhood report lifetime 1,587 s plus one block, rounded up.
    uint32 internal constant ROBINHOOD_MAX_REPORT_AGE = 1587 + 1;

    /// @dev The send to Robinhood and its Across quote: USDC 42161 -> USDG 4663 costs relayer and LP fees of a few bps
    ///      at this size; the quote used here charges 1.60 USDC (4 bps), and the Mandate's `maxBridgeFeeBps` is set from
    ///      it (QA19 OPEN as to the value).
    uint256 internal constant BRIDGE_AMOUNT = 4000e6;
    uint256 internal constant BRIDGE_FEE = 1.6e6;
    uint16 internal constant MAX_BRIDGE_FEE_BPS = 4;

    /// @dev Spoke Operating Cash (DEC-096), the defaults of script/CreateFund.s.sol.
    uint256 internal constant SPOKE_OPERATING_CASH_FLOOR = 5e6;
    uint256 internal constant SPOKE_OPERATING_CASH_TOP_UP = 10e6;

    uint256 internal constant MIN_FIRST_DEPOSIT = 100e6;
    uint16 internal constant PERFORMANCE_FEE_BPS = 2000;

    /// @dev Liquidity ranges and fee-generating swings, in ticks around the current price (docs/INTEGRATIONS.md pools).
    int24 internal constant HALF_RANGE = 200;
    int24 internal constant SWING = 40;

    /// @dev Tolerance between the Chainlink price and a pool's price for swap minimums (a bound, not a market number).
    uint256 internal constant SWAP_TOLERANCE_BPS = 300;

    // -----------------------------------------------------------------------------------------------------------------
    // Actors
    // -----------------------------------------------------------------------------------------------------------------

    address internal manager = makeAddr("manager");
    address internal ana = makeAddr("ana");
    address internal bruno = makeAddr("bruno");
    address internal trader = makeAddr("trader");
    address internal relayer = makeAddr("relayer");
    address internal recipient = makeAddr("protocolRecipient");
    address internal guardian = makeAddr("guardian");
    address internal registryOwner = makeAddr("registryOwner");

    // -----------------------------------------------------------------------------------------------------------------
    // Scenario books (persist across fork switches: the test contract is persistent)
    // -----------------------------------------------------------------------------------------------------------------

    uint256 internal arbitrumFork;
    uint256 internal robinhoodFork;
    uint256 internal clock;

    Deployment internal hubDeployment;
    uint256 internal creationNumber;
    bytes32 internal fundId;
    bytes32 internal mandateHash;

    ICoreVault internal core;
    address internal shareToken;
    address internal managerFeeVault;
    IValueReportReceiver internal receiver;
    ISpokeVault internal hubSpoke;
    address internal hubUniswap;
    address internal hubAave;
    address internal hubAcross;
    ISpokeVault internal spokeVault;
    address internal spokeUniswap;
    address internal spokeAcross;

    V4SwapRouter internal arbitrumRouter;
    V4SwapRouter internal robinhoodRouter;
    bytes32 internal hubUniswapPosition;
    bytes32 internal hubAavePosition;
    bytes32 internal spokeUniswapPosition;

    bytes32 internal transitId;
    uint256 internal amountToArrive;
    bytes internal acrossMessage;

    // -----------------------------------------------------------------------------------------------------------------
    // Forks and the scenario clock
    // -----------------------------------------------------------------------------------------------------------------

    function _createForks() internal {
        arbitrumFork = vm.createFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        robinhoodFork = vm.createFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        vm.selectFork(arbitrumFork);
        clock = block.timestamp;
        vm.selectFork(robinhoodFork);
        clock = Math.max(clock, block.timestamp);
    }

    function _onArbitrum() internal {
        vm.selectFork(arbitrumFork);
        _sync();
    }

    function _onRobinhood() internal {
        vm.selectFork(robinhoodFork);
        _sync();
    }

    /// @dev Warps the selected fork to the scenario clock (never back).
    function _sync() private {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < clock) vm.warp(clock);
        clock = block.timestamp;
    }

    /// @dev Moves the selected fork's clock and block forward; the other fork follows at its next selection.
    function _advance(uint256 seconds_) internal {
        clock = block.timestamp + seconds_;
        vm.warp(clock);
        vm.roll(block.number + 1 + seconds_ / 12);
    }

    /// @dev The ETH / USD aggregator keeps its live answer; a warp outruns its heartbeat, so the answer is re-posted
    ///      with the current time, as the next Chainlink round would (OQ-10: a mint reverts on a stale price).
    function _refreshEthUsdFeed() internal {
        (uint80 roundId, int256 answer, uint256 startedAt,,) =
            IChainlinkAggregatorV3(ARB_ETH_USD_FEED).latestRoundData();
        vm.mockCall(
            ARB_ETH_USD_FEED,
            abi.encodeWithSelector(IChainlinkAggregatorV3.latestRoundData.selector),
            abi.encode(roundId, answer, startedAt, block.timestamp, roundId)
        );
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Mandate plan (docs/DEPLOYMENT.md, script/CreateFund.s.sol)
    // -----------------------------------------------------------------------------------------------------------------

    function _plan() internal view returns (FundPlan memory plan) {
        plan.manager = manager;
        plan.hubChainId = ARBITRUM;
        plan.usdc = ARB_USDC;
        plan.hubPool = _hubPoolKey();
        plan.hubAaveAsset = ARB_USDC;
        plan.spokeChainId = ROBINHOOD;
        plan.spokeWormholeChainId = WORMHOLE_ROBINHOOD;
        plan.spokeToken = RH_USDG;
        plan.spokePool = _spokePoolKey();
        plan.spokeCap = SPOKE_CAP;
        plan.maxReportAge = ROBINHOOD_MAX_REPORT_AGE;
        plan.spokeOperatingCashFloor = SPOKE_OPERATING_CASH_FLOOR;
        plan.spokeOperatingCashTopUp = SPOKE_OPERATING_CASH_TOP_UP;
        plan.minFirstDeposit = MIN_FIRST_DEPOSIT;
        plan.performanceFeeBps = PERFORMANCE_FEE_BPS;
        plan.maxBridgeFeeBps = MAX_BRIDGE_FEE_BPS;
    }

    function _chainIds() internal pure returns (uint256[] memory ids) {
        ids = new uint256[](2);
        ids[0] = ARBITRUM;
        ids[1] = ROBINHOOD;
    }

    /// @dev WETH sorts below USDC on Arbitrum and below USDG on Robinhood, so WETH is currency0 in both pools.
    function _hubPoolKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(ARB_WETH), Currency.wrap(ARB_USDC), 500, TICK_SPACING, IHooks(address(0)));
    }

    function _spokePoolKey() internal pure returns (PoolKey memory) {
        return PoolKey(Currency.wrap(RH_WETH), Currency.wrap(RH_USDG), 500, TICK_SPACING, IHooks(address(0)));
    }

    function _aavePoolKey() internal pure returns (bytes32) {
        return bytes32(uint256(uint160(ARB_USDC)));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Uniswap V4 helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Current tick of `poolId`, rounded toward zero to the tick spacing.
    function _center(address stateView, bytes32 poolId) internal view returns (int24) {
        (, int24 tick,,) = IStateView(stateView).getSlot0(PoolId.wrap(poolId));
        return tick - (tick % TICK_SPACING);
    }

    function _openParams(int24 center, uint256 amount0, uint256 amount1) internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: center - HALF_RANGE,
                tickUpper: center + HALF_RANGE,
                liquidity: 0,
                amount0Max: SafeCast.toUint128(amount0),
                amount1Max: SafeCast.toUint128(amount1),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _closeParams() internal view returns (bytes memory) {
        return abi.encode(UniswapV4Adapter.CloseParams({amount0Min: 0, amount1Min: 0, deadline: block.timestamp}));
    }

    function _swapParams() internal view returns (bytes memory) {
        return abi.encode(UniswapV4Adapter.SwapExactInputParams({sqrtPriceLimitX96: 0, deadline: block.timestamp}));
    }

    /// @dev A test router on `PoolManager.unlock` for a third-party trader, funded and approved on the selected fork.
    function _deployRouter(address poolManager, address token0, address token1, uint256 amount0, uint256 amount1)
        internal
        returns (V4SwapRouter router)
    {
        router = new V4SwapRouter(IPoolManager(poolManager));
        deal(token0, trader, amount0);
        deal(token1, trader, amount1);
        vm.startPrank(trader);
        IERC20(token0).approve(address(router), type(uint256).max);
        IERC20(token1).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev The trader swings the price down by `SWING` ticks and back through the fund's range, so the position earns
    ///      fees in both tokens. Every swap is bounded by a price limit, so the path is the same whatever the depth.
    function _generateFees(V4SwapRouter router, PoolKey memory key, address stateView, int24 center) internal {
        _swapToTick(router, key, stateView, center - SWING);
        _swapToTick(router, key, stateView, center + SWING);
        _swapToTick(router, key, stateView, center);
    }

    function _swapToTick(V4SwapRouter router, PoolKey memory key, address stateView, int24 target) internal {
        bytes32 poolId = PoolId.unwrap(key.toId());
        (, int24 tick,,) = IStateView(stateView).getSlot0(PoolId.wrap(poolId));
        if (tick == target) return;
        bool zeroForOne = target < tick;
        vm.prank(trader);
        router.swap(key, zeroForOne, -int256(uint256(type(uint128).max)), TickMath.getSqrtPriceAtTick(target));
        (, tick,,) = IStateView(stateView).getSlot0(PoolId.wrap(poolId));
        assertApproxEqAbs(int256(tick), int256(target), 1, "swap did not reach the target tick");
    }

    /// @dev WETH out of `usdcIn` at the hub price source, less the swap tolerance (a floor for swap minimums).
    function _minWethFor(uint256 usdcIn) internal view returns (uint256) {
        (uint256 price,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(ARB_WETH);
        return Math.mulDiv(usdcIn, 1e18, price) * (10_000 - SWAP_TOLERANCE_BPS) / 10_000;
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Across
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice Non-indexed fields of `FundsDeposited`, in event order.
    struct DepositData {
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
        bytes message;
    }

    /// @dev The single `FundsDeposited` a SpokePool emitted in `logs`, with its indexed fields.
    function _fundsDeposited(Vm.Log[] memory logs, address spokePool)
        internal
        pure
        returns (uint256 destinationChainId, uint256 depositId, bytes32 depositor, DepositData memory d)
    {
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != spokePool || logs[i].topics[0] != IAcrossSpokePool.FundsDeposited.selector) {
                continue;
            }
            ++seen;
            destinationChainId = uint256(logs[i].topics[1]);
            depositId = uint256(logs[i].topics[2]);
            depositor = logs[i].topics[3];
            // The event's data is the tuple encoding; as a struct it needs its offset word first.
            d = abi.decode(bytes.concat(abi.encode(uint256(0x20)), logs[i].data), (DepositData));
        }
        assertEq(seen, 1, "one FundsDeposited");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Value bases (DEC-042, DEC-083, DEC-104)
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev USDC value of `amount` of `token` as the Core Vault computes it: USDC at face value, anything else through
    ///      the fund's price source, rounded down (ruling 2026-09-29: Chainlink for WETH, 1:1 for USDG).
    function _usdcValue(address token, uint256 amount) internal view returns (uint256) {
        if (amount == 0) return 0;
        if (token == ARB_USDC) return amount;
        (uint256 price,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(token);
        return Math.mulDiv(amount, price, 1e18);
    }

    /// @dev Unallocated Balance plus position principal of a report, in USDC; income excluded (DEC-079, DEC-092). A
    ///      range position is valued at the price-source price from its liquidity and ticks, never at the pool's spot
    ///      composition (security review S-1, `CoreVaultLogic._oracleComposition`).
    function _principalValue(ReportCodec.Report memory r) internal view returns (uint256 value) {
        for (uint256 i; i < r.unallocated.length; ++i) {
            value += _usdcValue(r.unallocated[i].token, r.unallocated[i].amount);
        }
        for (uint256 i; i < r.positions.length; ++i) {
            (uint256 amount0, uint256 amount1) = _oracleAmounts(r.positions[i]);
            value += _usdcValue(r.positions[i].token0, amount0) + _usdcValue(r.positions[i].token1, amount1);
        }
    }

    /// @dev The token amounts of a range position at `sqrt(price(token0) / price(token1))`, as the Core Vault computes.
    function _oracleAmounts(ReportCodec.PositionReport memory p) internal view returns (uint256 a0, uint256 a1) {
        if (p.token1 == address(0) || p.tickLower >= p.tickUpper || p.liquidity == 0) {
            return (p.principal0, p.principal1);
        }
        uint256 price0 = _unitPrice(p.token0);
        uint256 price1 = _unitPrice(p.token1);
        uint256 sqrtPrice = Math.sqrt(Math.mulDiv(price0, 1 << 96, price1)) << 48;
        uint160 lower = TickMath.getSqrtPriceAtTick(p.tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(p.tickUpper);
        if (sqrtPrice <= lower) {
            a0 = SqrtPriceMath.getAmount0Delta(lower, upper, p.liquidity, false);
        } else if (sqrtPrice < upper) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint160 sp = uint160(sqrtPrice);
            a0 = SqrtPriceMath.getAmount0Delta(sp, upper, p.liquidity, false);
            a1 = SqrtPriceMath.getAmount1Delta(lower, sp, p.liquidity, false);
        } else {
            a1 = SqrtPriceMath.getAmount1Delta(lower, upper, p.liquidity, false);
        }
    }

    function _unitPrice(address token) internal view returns (uint256 price) {
        if (token == ARB_USDC) return 1e18;
        (price,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(token);
    }

    /// @dev Share Assets rebuilt bucket by bucket (DEC-042, DEC-104): Idle (Payout Reserve included) + the hub Spoke
    ///      Vault's Unallocated Balance and position principal + In-flight Value + the spoke's principal from its last
    ///      accepted report. Operating Cash, collected income and uncollected income are outside it (DEC-092, DEC-096).
    ///      The scenario never credits value of unknown origin on the spoke, so no deduction applies (DEC-080).
    function _sumOfBuckets() internal view returns (uint256 total) {
        total = core.idle() + _principalValue(hubSpoke.buildReport()) + core.inFlightValue();
        if (receiver.hasReport(0)) {
            (ReportCodec.Report memory r,,) = receiver.latestReport(0);
            total += _principalValue(r);
        }
    }
}
