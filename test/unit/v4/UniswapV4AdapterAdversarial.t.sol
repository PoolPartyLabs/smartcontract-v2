// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SafeCast as V4SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {ReenteringToken} from "../../mocks/v4/ReenteringToken.sol";
import {V4VaultHarness} from "../../mocks/v4/V4VaultHarness.sol";

/// @notice Adversarial verification of the Uniswap V4 adapter: rounding extremes, reentrancy through a token hook,
///         fee-growth wraparound and the whole tick range.
contract UniswapV4AdapterAdversarialTest is Test {
    int24 internal constant SPACING = 10;
    int24 internal constant MAX_ALIGNED = 887_270;
    uint256 internal constant FUNDS = 1e30;
    uint256 internal constant RESERVE = 1e60;
    uint256 internal constant GROWTH = (uint256(1) << 128) / 1000;

    MockToken internal token0;
    MockToken internal token1;
    MockPermit2 internal permit2;
    MockV4 internal v4;
    V4VaultHarness internal vault;
    UniswapV4Adapter internal adapter;
    PoolKey internal key;
    bytes32 internal poolId;
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        MockToken a = new MockToken("A", 18);
        MockToken b = new MockToken("B", 6);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        vault = new V4VaultHarness();
        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, SPACING, IHooks(address(0)));
        poolId = PoolId.unwrap(key.toId());
        v4.initialize(key, TickMath.getSqrtPriceAtTick(0));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        adapter = _deploy(address(vault), keys);
        vault.setAdapter(adapter);
        token0.mint(address(vault), FUNDS);
        token1.mint(address(vault), FUNDS);
        // The mock protocol pays principal at any price and any fee growth: reserves far above every amount.
        token0.mint(address(v4), RESERVE);
        token1.mint(address(v4), RESERVE);
    }

    // ------------------------------------------------------------------ derived liquidity rounding

    /// DEC-079: `liquidity == 0` derives the liquidity from `amount0Max`/`amount1Max`; the amounts the position then
    /// takes (rounded up by the pool) must never exceed those same maximums, or the entry verb reverts for a
    /// legitimate request.
    function testFuzz_DEC079_derivedLiquidityNeverExceedsMaximums(
        uint128 amount0,
        uint128 amount1,
        int24 lowerSeed,
        int24 widthSeed,
        int24 tickSeed
    ) public {
        amount0 = uint128(bound(amount0, 1, 1e27));
        amount1 = uint128(bound(amount1, 1, 1e27));
        (int24 lower, int24 upper, int24 tick) = _range(lowerSeed, widthSeed, tickSeed);
        v4.setTick(poolId, tick);
        UniswapV4Adapter.OpenParams memory p = UniswapV4Adapter.OpenParams({
            tickLower: lower,
            tickUpper: upper,
            liquidity: 0,
            amount0Max: amount0,
            amount1Max: amount1,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        // Only inputs that yield some liquidity are interesting.
        try vault.open(poolId, address(token0), amount0, address(token1), amount1, abi.encode(p)) returns (
            bytes32, uint256 used0, uint256 used1
        ) {
            assertLe(used0, amount0, "used0 above amount0Max");
            assertLe(used1, amount1, "used1 above amount1Max");
            _assertAdapterHoldsNothing();
        } catch (bytes memory reason) {
            // Zero derived liquidity, or the protocol's own liquidity ceilings (`LiquidityAmounts.toUint128`, the
            // int128 `liquidityDelta` of `Pool.modifyLiquidity`; the mock raises OpenZeppelin's downcast error where
            // v4 raises its own), are the only legitimate reasons; a `MaximumAmountExceeded` from the position
            // manager would be the rounding defect.
            bytes4 selector = bytes4(reason);
            assertTrue(
                selector == UniswapV4Adapter.InvalidLiquidity.selector
                    || selector == V4SafeCast.SafeCastOverflow.selector
                    || selector == SafeCast.SafeCastOverflowedIntDowncast.selector,
                "derived-liquidity open reverted for a reason other than zero liquidity or a liquidity ceiling"
            );
        }
    }

    // ------------------------------------------------------------------ reentrancy through a token hook

    /// DEC-058, checks-effects-interactions: a token that calls back into the vault while the adapter is paying it
    /// cannot re-enter any adapter verb; the whole call reverts with the ReentrancyGuard error.
    function test_DEC058_tokenHookCannotReenterAdapter() public {
        ReenteringToken rnt = new ReenteringToken();
        MockToken other = new MockToken("O", 18);
        (address t0, address t1) =
            address(rnt) < address(other) ? (address(rnt), address(other)) : (address(other), address(rnt));
        PoolKey memory rKey = PoolKey(Currency.wrap(t0), Currency.wrap(t1), 500, SPACING, IHooks(address(0)));
        bytes32 rId = PoolId.unwrap(rKey.toId());
        v4.initialize(rKey, TickMath.getSqrtPriceAtTick(0));
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = rKey;
        V4VaultHarness rVault = new V4VaultHarness();
        UniswapV4Adapter rAdapter = _deploy(address(rVault), keys);
        rVault.setAdapter(rAdapter);
        rnt.mint(address(rVault), FUNDS);
        other.mint(address(rVault), FUNDS);
        rnt.mint(address(v4), FUNDS);
        other.mint(address(v4), FUNDS);

        bytes memory openParams = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: -600,
                tickUpper: 600,
                liquidity: 1e21,
                amount0Max: 1e24,
                amount1Max: 1e24,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        (bytes32 positionKey,,) = rVault.open(rId, t0, 1e24, t1, 1e24, openParams);
        v4.accrueFees(rId, GROWTH, GROWTH);

        bytes memory closeParams =
            abi.encode(UniswapV4Adapter.CloseParams({amount0Min: 0, amount1Min: 0, deadline: block.timestamp}));

        // 1. Re-enter `closePosition` while `collectIncome` pays the vault.
        rnt.arm(address(rVault), abi.encodeCall(V4VaultHarness.close, (positionKey, closeParams)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rVault.collect(positionKey);

        // 2. Re-enter `collectIncome` while `decreasePosition` pays the vault.
        rnt.arm(address(rVault), abi.encodeCall(V4VaultHarness.collect, (positionKey)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rVault.decrease(
            positionKey,
            abi.encode(
                UniswapV4Adapter.DecreaseParams({
                    liquidity: 1e20, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
                })
            )
        );

        // 3. Re-enter `openPosition` while `openPosition` hands the unused remainder back to the vault.
        rnt.arm(address(rVault), abi.encodeCall(V4VaultHarness.open, (rId, t0, 0, t1, 0, openParams)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        rVault.open(rId, t0, 1e24, t1, 1e24, openParams);

        // Nothing changed: the position is intact and every attempt was rolled back.
        rnt.disarm();
        IAdapter.PositionValue memory v = rAdapter.positionValue(positionKey);
        assertEq(v.liquidity, 1e21);
        assertApproxEqAbs(v.income0, 1e18, 1);
        assertEq(rAdapter.realizedIncome(t0), 0);
        assertEq(rAdapter.realizedIncome(t1), 0);
        assertEq(IERC20(t0).balanceOf(address(rAdapter)), 0);
        assertEq(IERC20(t1).balanceOf(address(rAdapter)), 0);
    }

    // ------------------------------------------------------------------ fee growth wraparound

    /// DEC-079, Q60: the PoolManager's fee growth is an unchecked Q128 counter that wraps; the adapter's income
    /// (`inside - last` unchecked) must survive a wrap between two reads and still match what the protocol pays.
    function test_DEC079_feeGrowthWrapAroundIsHandled() public {
        // Fee growth just below 2^256 before the position exists, so the next growth wraps the counter.
        v4.accrueFees(poolId, type(uint256).max - GROWTH / 2, type(uint256).max - GROWTH / 2);
        bytes32 positionKey = _open(-600, 600, 1e21);
        assertEq(adapter.positionValue(positionKey).income0, 0);

        v4.accrueFees(poolId, GROWTH, GROWTH);
        (uint256 g0,,,) = v4.pools(poolId);
        (,, uint256 wrapped0,) = v4.pools(poolId);
        assertLt(wrapped0, GROWTH, "counter did not wrap");
        g0; // silence

        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);
        assertApproxEqAbs(v.income0, 1e18, 1, "income after wrap");
        assertApproxEqAbs(v.income1, 1e18, 1, "income after wrap");
        uint256 cumulative0 = adapter.cumulativeIncome(address(token0));

        uint256 before0 = token0.balanceOf(address(vault));
        IAdapter.Amounts memory a = vault.collect(positionKey);
        assertEq(a.income0, v.income0);
        assertEq(token0.balanceOf(address(vault)) - before0, a.income0);
        assertEq(adapter.cumulativeIncome(address(token0)), cumulative0);
        assertEq(adapter.positionValue(positionKey).income0, 0);
    }

    // ------------------------------------------------------------------ whole tick range

    /// DEC-079: at any current tick (below, inside or above the range, including the extremes of the tick space) and
    /// any fee growth, `closePosition` returns exactly what `positionValue` reported, split between principal and
    /// income, every wei lands in the vault, the adapter keeps nothing and cumulativeIncome is unchanged by the
    /// realization.
    function testFuzz_DEC079_closeMatchesPositionValueAcrossTickSpace(
        uint128 liquidity,
        int24 lowerSeed,
        int24 widthSeed,
        int24 openTickSeed,
        int24 closeTickSeed,
        uint96 growth0,
        uint96 growth1
    ) public {
        liquidity = uint128(bound(liquidity, 1, 1e24));
        (int24 lower, int24 upper, int24 openTick) = _range(lowerSeed, widthSeed, openTickSeed);
        int24 closeTick = int24(bound(closeTickSeed, -MAX_ALIGNED, MAX_ALIGNED));
        v4.setTick(poolId, openTick);

        UniswapV4Adapter.OpenParams memory p = UniswapV4Adapter.OpenParams({
            tickLower: lower,
            tickUpper: upper,
            liquidity: liquidity,
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
        bytes32 positionKey;
        uint256 used0;
        uint256 used1;
        try vault.open(poolId, address(token0), FUNDS / 2, address(token1), FUNDS / 2, abi.encode(p)) returns (
            bytes32 k, uint256 u0, uint256 u1
        ) {
            (positionKey, used0, used1) = (k, u0, u1);
        } catch {
            // Amounts beyond the mock's reserves or the pool's own limits: not the property under test.
            return;
        }
        IAdapter.PositionValue memory atOpen = adapter.positionValue(positionKey);
        assertLe(atOpen.principal0, used0, "principal rounded down must not exceed what was paid");
        assertLe(atOpen.principal1, used1, "principal rounded down must not exceed what was paid");
        assertLe(used0 - atOpen.principal0, 1, "open pays at most one wei above principal");
        assertLe(used1 - atOpen.principal1, 1, "open pays at most one wei above principal");

        v4.accrueFees(poolId, uint256(growth0) << 32, uint256(growth1) << 32);
        v4.setTick(poolId, closeTick);

        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);
        uint256 cumulative0 = adapter.cumulativeIncome(address(token0));
        uint256 cumulative1 = adapter.cumulativeIncome(address(token1));
        uint256 before0 = token0.balanceOf(address(vault));
        uint256 before1 = token1.balanceOf(address(vault));

        IAdapter.Amounts memory a = vault.close(
            positionKey,
            abi.encode(UniswapV4Adapter.CloseParams({amount0Min: 0, amount1Min: 0, deadline: block.timestamp}))
        );
        assertEq(a.principal0, v.principal0, "principal0");
        assertEq(a.principal1, v.principal1, "principal1");
        assertEq(a.income0, v.income0, "income0");
        assertEq(a.income1, v.income1, "income1");
        assertEq(token0.balanceOf(address(vault)) - before0, a.principal0 + a.income0, "vault delta0");
        assertEq(token1.balanceOf(address(vault)) - before1, a.principal1 + a.income1, "vault delta1");
        assertEq(adapter.cumulativeIncome(address(token0)), cumulative0, "cumulativeIncome0 changed by close");
        assertEq(adapter.cumulativeIncome(address(token1)), cumulative1, "cumulativeIncome1 changed by close");
        assertEq(adapter.positionKeys().length, 0);
        _assertAdapterHoldsNothing();
    }

    // ------------------------------------------------------------------ ordering

    /// DEC-079, Q60: realizing income in two steps (collect, then decrease) or in one (decrease alone) must yield the
    /// same principal and the same total income; nothing is double counted or lost by the order of verbs.
    function testFuzz_Q60_collectThenDecreaseEqualsDecreaseAlone(uint96 growth0, uint96 growth1, uint8 fraction)
        public
    {
        fraction = uint8(bound(fraction, 1, 99));
        uint256 g0 = uint256(growth0) << 32;
        uint256 g1 = uint256(growth1) << 32;
        uint256 snapshot = vm.snapshotState();

        // Path A: decrease alone.
        bytes32 a = _open(-600, 600, 1e21);
        v4.accrueFees(poolId, g0, g1);
        uint128 part = uint128(uint256(1e21) * fraction / 100);
        IAdapter.Amounts memory alone = vault.decrease(a, _decreaseParams(part));
        uint256 realizedAlone0 = adapter.realizedIncome(address(token0));
        uint256 realizedAlone1 = adapter.realizedIncome(address(token1));
        IAdapter.PositionValue memory restAlone = adapter.positionValue(a);

        vm.revertToState(snapshot);

        // Path B: collect, then decrease.
        bytes32 b = _open(-600, 600, 1e21);
        v4.accrueFees(poolId, g0, g1);
        IAdapter.Amounts memory collected = vault.collect(b);
        IAdapter.Amounts memory after_ = vault.decrease(b, _decreaseParams(part));

        assertEq(after_.income0 + after_.income1, 0, "no income left after a collect in the same block");
        assertEq(after_.principal0, alone.principal0, "principal0 depends on the order");
        assertEq(after_.principal1, alone.principal1, "principal1 depends on the order");
        assertEq(collected.income0, alone.income0, "income0 depends on the order");
        assertEq(collected.income1, alone.income1, "income1 depends on the order");
        assertEq(adapter.realizedIncome(address(token0)), realizedAlone0);
        assertEq(adapter.realizedIncome(address(token1)), realizedAlone1);
        IAdapter.PositionValue memory restB = adapter.positionValue(b);
        assertEq(restB.principal0, restAlone.principal0);
        assertEq(restB.principal1, restAlone.principal1);
        assertEq(restB.liquidity, restAlone.liquidity);
    }

    // ------------------------------------------------------------------ helpers

    function _range(int24 lowerSeed, int24 widthSeed, int24 tickSeed)
        internal
        pure
        returns (int24 lower, int24 upper, int24 tick)
    {
        lower = int24(bound(lowerSeed, -MAX_ALIGNED, MAX_ALIGNED - SPACING));
        lower = lower - (lower % SPACING);
        int24 maxWidth = MAX_ALIGNED - lower;
        int24 width = int24(bound(widthSeed, SPACING, maxWidth));
        width = width - (width % SPACING);
        upper = lower + width;
        tick = int24(bound(tickSeed, -MAX_ALIGNED, MAX_ALIGNED));
    }

    function _deploy(address vault_, PoolKey[] memory keys) internal returns (UniswapV4Adapter) {
        return new UniswapV4Adapter(
            vault_,
            guardian,
            IPoolManager(address(v4)),
            IPositionManager(address(v4)),
            IStateView(address(v4)),
            IAllowanceTransfer(address(permit2)),
            keys
        );
    }

    function _open(int24 lower, int24 upper, uint128 liquidity) internal returns (bytes32 positionKey) {
        bytes memory p = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: lower,
                tickUpper: upper,
                liquidity: liquidity,
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        (positionKey,,) = vault.open(poolId, address(token0), 1e27, address(token1), 1e27, p);
    }

    function _decreaseParams(uint128 liquidity) internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.DecreaseParams({
                liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
    }

    function _assertAdapterHoldsNothing() internal view {
        assertEq(token0.balanceOf(address(adapter)), 0, "adapter token0 balance");
        assertEq(token1.balanceOf(address(adapter)), 0, "adapter token1 balance");
        assertEq(IERC20(address(token0)).allowance(address(adapter), address(permit2)), 0);
        assertEq(IERC20(address(token1)).allowance(address(adapter), address(permit2)), 0);
        (uint160 p0,,) = permit2.allowance(address(adapter), address(token0), address(v4));
        (uint160 p1,,) = permit2.allowance(address(adapter), address(token1), address(v4));
        assertEq(p0, 0);
        assertEq(p1, 0);
    }
}
