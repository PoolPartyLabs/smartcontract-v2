// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
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
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {MockToken} from "../../mocks/v4/MockToken.sol";
import {MockPermit2} from "../../mocks/v4/MockPermit2.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {V4VaultHarness} from "../../mocks/v4/V4VaultHarness.sol";

contract UniswapV4AdapterTest is Test {
    int24 internal constant LOWER = -600;
    int24 internal constant UPPER = 600;
    uint128 internal constant LIQUIDITY = 1e21;
    uint256 internal constant FUNDS = 1e24;
    /// @dev Fee growth that gives 1e18 of income for LIQUIDITY.
    uint256 internal constant GROWTH = (uint256(1) << 128) / 1000;

    MockToken internal token0;
    MockToken internal token1;
    MockPermit2 internal permit2;
    MockV4 internal v4;
    V4VaultHarness internal vault;
    UniswapV4Adapter internal adapter;
    PoolKey internal key;
    PoolKey internal hookedKey;
    bytes32 internal poolId;
    bytes32 internal hookedId;
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        MockToken a = new MockToken("A", 18);
        MockToken b = new MockToken("B", 6);
        (token0, token1) = address(a) < address(b) ? (a, b) : (b, a);
        permit2 = new MockPermit2();
        v4 = new MockV4(permit2);
        vault = new V4VaultHarness();

        key = PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, 10, IHooks(address(0)));
        hookedKey =
            PoolKey(Currency.wrap(address(token0)), Currency.wrap(address(token1)), 500, 10, IHooks(address(0xC0FFEE)));
        poolId = PoolId.unwrap(key.toId());
        hookedId = PoolId.unwrap(hookedKey.toId());
        v4.initialize(key, TickMath.getSqrtPriceAtTick(0));

        adapter = _deploy(address(vault), _keys(key, hookedKey));
        vault.setAdapter(adapter);

        token0.mint(address(vault), FUNDS);
        token1.mint(address(vault), FUNDS);
        // Reserves that back fees and swap outputs inside the mock protocol.
        token0.mint(address(v4), FUNDS);
        token1.mint(address(v4), FUNDS);
    }

    // ------------------------------------------------------------------ construction and pools

    /// DEC-030, DEC-053: the closed pool list is registered once; the adapter's poolKey is the PoolId.
    function test_DEC030_constructorRegistersPoolsById() public view {
        (address t0, address t1) = adapter.poolTokens(poolId);
        assertEq(t0, address(token0));
        assertEq(t1, address(token1));
        assertEq(adapter.vault(), address(vault));
        assertEq(adapter.guardian(), guardian);
    }

    function test_DEC030_constructorRejectsDuplicatePool() public {
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.DuplicatePool.selector, poolId));
        _deploy(address(vault), _keys(key, key));
    }

    function test_DEC030_constructorRejectsNativeAndMalformedKeys() public {
        PoolKey memory native = key;
        native.currency0 = Currency.wrap(address(0));
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.InvalidPoolKey.selector, PoolId.unwrap(native.toId())));
        _deploy(address(vault), _keys(native, key));

        PoolKey memory noSpacing = key;
        noSpacing.tickSpacing = 0;
        vm.expectRevert(
            abi.encodeWithSelector(UniswapV4Adapter.InvalidPoolKey.selector, PoolId.unwrap(noSpacing.toId()))
        );
        _deploy(address(vault), _keys(noSpacing, key));
    }

    function test_DEC058_constructorRejectsZeroAddresses() public {
        vm.expectRevert(UniswapV4Adapter.ZeroAddress.selector);
        _deploy(address(0), _keys(key, hookedKey));
        vm.expectRevert(AdapterGuard.ZeroGuardian.selector);
        new UniswapV4Adapter(
            address(vault),
            address(0),
            IPoolManager(address(v4)),
            IPositionManager(address(v4)),
            IStateView(address(v4)),
            IAllowanceTransfer(address(permit2)),
            _keys(key, hookedKey)
        );
    }

    /// DEC-079 (OPEN), OQ-12: a hooked pool is unknown to poolTokens, openPosition and swapExactInput.
    function test_DEC079_hookedPoolIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, hookedId));
        adapter.poolTokens(hookedId);

        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, hookedId));
        vault.open(hookedId, address(token0), 1e20, address(token1), 1e20, _openParams(LIQUIDITY));

        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, hookedId));
        vault.swap(hookedId, address(token0), 1e18, 0, _swapParams());
    }

    function test_DEC030_unregisteredPoolIsUnknown() public {
        bytes32 other = keccak256("other");
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, other));
        adapter.poolTokens(other);
    }

    /// DEC-059: Uniswap V4 positions are price-dependent.
    function test_DEC059_isNotExactValue() public view {
        assertFalse(adapter.isExactValue());
    }

    // ------------------------------------------------------------------ access and guard

    /// DEC-053, DEC-058: every mutating verb is vault only.
    function test_DEC058_everyMutatingVerbIsVaultOnly() public {
        bytes32 positionKey = _open();
        vm.startPrank(stranger);
        bytes memory notVault = abi.encodeWithSelector(IAdapter.NotVault.selector, stranger);
        vm.expectRevert(notVault);
        adapter.openPosition(poolId, _openParams(LIQUIDITY));
        vm.expectRevert(notVault);
        adapter.increasePosition(positionKey, _increaseParams(LIQUIDITY));
        vm.expectRevert(notVault);
        adapter.decreasePosition(positionKey, _decreaseParams(1));
        vm.expectRevert(notVault);
        adapter.closePosition(positionKey, _closeParams());
        vm.expectRevert(notVault);
        adapter.collectIncome(positionKey);
        vm.expectRevert(notVault);
        adapter.swapExactInput(poolId, address(token0), 1, 0, _swapParams());
        vm.stopPrank();
    }

    function test_DEC058_unlockCallbackIsPoolManagerOnly() public {
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.NotPoolManager.selector, stranger));
        vm.prank(stranger);
        adapter.unlockCallback("");
    }

    /// DEC-056: quarantine blocks open and increase; decrease, collect, close and (OQ-04) swap keep working.
    function test_DEC056_pauseBlocksEntriesNeverExits() public {
        bytes32 positionKey = _open();
        v4.accrueFees(poolId, GROWTH, GROWTH);
        vm.prank(guardian);
        adapter.setPaused(true);

        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        vault.open(poolId, address(token0), 1e20, address(token1), 1e20, _openParams(LIQUIDITY));
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        vault.increase(positionKey, address(token0), 1e20, address(token1), 1e20, _increaseParams(LIQUIDITY));

        vault.collect(positionKey);
        vault.decrease(positionKey, _decreaseParams(LIQUIDITY / 2));
        vault.swap(poolId, address(token0), 1e18, 0, _swapParams());
        vault.close(positionKey, _closeParams());
        assertEq(adapter.positionKeys().length, 0);
    }

    /// DEC-058: deprecation blocks open, increase and (OQ-04) swap; exits keep working.
    function test_DEC058_deprecationBlocksEntriesAndSwapNeverExits() public {
        bytes32 positionKey = _open();
        vm.prank(guardian);
        adapter.deprecate();

        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        vault.open(poolId, address(token0), 1e20, address(token1), 1e20, _openParams(LIQUIDITY));
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        vault.increase(positionKey, address(token0), 1e20, address(token1), 1e20, _increaseParams(LIQUIDITY));
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        vault.swap(poolId, address(token0), 1e18, 0, _swapParams());

        vault.collect(positionKey);
        vault.decrease(positionKey, _decreaseParams(LIQUIDITY / 2));
        vault.close(positionKey, _closeParams());
    }

    // ------------------------------------------------------------------ open

    /// DEC-079, DEC-080: open pays exactly the owed principal, returns the rest, and leaves no balance or allowance.
    function test_DEC079_openPaysExactPrincipalAndReturnsUnused() public {
        uint256 before0 = token0.balanceOf(address(vault));
        uint256 before1 = token1.balanceOf(address(vault));
        (bytes32 positionKey, uint256 used0, uint256 used1) =
            vault.open(poolId, address(token0), 1e20, address(token1), 1e20, _openParams(LIQUIDITY));

        assertEq(uint256(positionKey), 1);
        assertGt(used0, 0);
        assertGt(used1, 0);
        assertEq(token0.balanceOf(address(vault)), before0 - used0);
        assertEq(token1.balanceOf(address(vault)), before1 - used1);
        _assertAdapterHoldsNothing();

        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);
        assertEq(v.poolKey, poolId);
        assertEq(v.poolId, poolId);
        assertEq(v.tickLower, LOWER);
        assertEq(v.tickUpper, UPPER);
        assertEq(v.liquidity, LIQUIDITY);
        assertEq(v.token0, address(token0));
        assertEq(v.token1, address(token1));
        // Principal is rounded down, the payment up: at most one wei apart.
        assertApproxEqAbs(v.principal0, used0, 1);
        assertApproxEqAbs(v.principal1, used1, 1);
        assertLe(v.principal0, used0);
        assertEq(v.income0, 0);
        assertEq(v.income1, 0);
        assertEq(adapter.positionKeys()[0], positionKey);
    }

    /// DEC-079: liquidity 0 derives liquidity from the desired amounts; the minimums bound the result.
    function test_DEC079_openFromDesiredAmounts() public {
        UniswapV4Adapter.OpenParams memory p = _open_(0);
        p.amount0Max = 5e19;
        p.amount1Max = 1e20;
        (, uint256 used0, uint256 used1) =
            vault.open(poolId, address(token0), 5e19, address(token1), 1e20, abi.encode(p));
        assertApproxEqAbs(used0, 5e19, 1); // token0 binds at tick 0 with a symmetric range
        assertLe(used0, 5e19);
        assertLt(used1, 1e20);
        _assertAdapterHoldsNothing();

        p.amount0Min = 5e19 + 1;
        vm.expectRevert();
        vault.open(poolId, address(token0), 5e19, address(token1), 1e20, abi.encode(p));
    }

    function test_DEC079_openRejectsZeroLiquidity() public {
        UniswapV4Adapter.OpenParams memory p = _open_(0);
        p.amount0Max = 0;
        p.amount1Max = 0;
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.InvalidLiquidity.selector, 0, 0));
        vault.open(poolId, address(token0), 0, address(token1), 0, abi.encode(p));
    }

    function test_DEC079_openRevertsAfterDeadline() public {
        UniswapV4Adapter.OpenParams memory p = _open_(LIQUIDITY);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(MockV4.DeadlinePassed.selector, p.deadline));
        vault.open(poolId, address(token0), 1e20, address(token1), 1e20, abi.encode(p));
    }

    // ------------------------------------------------------------------ income and principal

    /// DEC-079: collect takes only the income, reported apart from principal, and it lands in the vault.
    function test_DEC079_collectTakesOnlyIncome() public {
        bytes32 positionKey = _open();
        v4.accrueFees(poolId, GROWTH, 2 * GROWTH);
        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);
        assertApproxEqAbs(v.income0, 1e18, 1);
        assertApproxEqAbs(v.income1, 2e18, 1);

        uint256 before0 = token0.balanceOf(address(vault));
        uint256 before1 = token1.balanceOf(address(vault));
        IAdapter.Amounts memory a = vault.collect(positionKey);

        assertEq(a.principal0, 0);
        assertEq(a.principal1, 0);
        assertEq(a.income0, v.income0);
        assertEq(a.income1, v.income1);
        assertEq(token0.balanceOf(address(vault)) - before0, a.income0);
        assertEq(token1.balanceOf(address(vault)) - before1, a.income1);
        assertEq(adapter.realizedIncome(address(token0)), a.income0);

        IAdapter.PositionValue memory after_ = adapter.positionValue(positionKey);
        assertEq(after_.income0, 0);
        assertEq(after_.income1, 0);
        assertEq(after_.principal0, v.principal0);
        _assertAdapterHoldsNothing();
    }

    function test_DEC079_collectWithoutIncomeIsANoop() public {
        bytes32 positionKey = _open();
        IAdapter.Amounts memory a = vault.collect(positionKey);
        assertEq(a.income0 + a.income1 + a.principal0 + a.principal1, 0);
    }

    /// DEC-079: an increase realizes the position's income, which is taken to the vault and reported as income.
    function test_DEC079_increaseReportsRealizedIncome() public {
        bytes32 positionKey = _open();
        v4.accrueFees(poolId, GROWTH, GROWTH);
        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);

        uint256 before0 = token0.balanceOf(address(vault));
        (uint256 used0, uint256 used1, uint256 income0, uint256 income1) =
            vault.increase(positionKey, address(token0), 1e20, address(token1), 1e20, _increaseParams(LIQUIDITY));

        assertEq(income0, v.income0);
        assertEq(income1, v.income1);
        assertGt(used0, 0);
        assertGt(used1, 0);
        assertEq(token0.balanceOf(address(vault)), before0 - used0 + income0);
        assertEq(adapter.positionValue(positionKey).liquidity, 2 * LIQUIDITY);
        assertEq(adapter.positionValue(positionKey).income0, 0);
        _assertAdapterHoldsNothing();
    }

    /// DEC-079: decrease realizes income first (DECREASE of 0), then principal; both reach the vault, split.
    function test_DEC079_decreaseSplitsPrincipalAndIncome() public {
        bytes32 positionKey = _open();
        v4.accrueFees(poolId, GROWTH, GROWTH);
        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);

        uint256 before0 = token0.balanceOf(address(vault));
        uint256 before1 = token1.balanceOf(address(vault));
        IAdapter.Amounts memory a = vault.decrease(positionKey, _decreaseParams(LIQUIDITY / 4));

        assertEq(a.income0, v.income0);
        assertEq(a.income1, v.income1);
        assertApproxEqAbs(a.principal0, v.principal0 / 4, 1);
        assertApproxEqAbs(a.principal1, v.principal1 / 4, 1);
        assertEq(token0.balanceOf(address(vault)) - before0, a.principal0 + a.income0);
        assertEq(token1.balanceOf(address(vault)) - before1, a.principal1 + a.income1);
        assertEq(adapter.positionValue(positionKey).liquidity, LIQUIDITY - LIQUIDITY / 4);
        _assertAdapterHoldsNothing();
    }

    function test_DEC079_decreaseRejectsZeroOrWholeLiquidity() public {
        bytes32 positionKey = _open();
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.InvalidLiquidity.selector, 0, LIQUIDITY));
        vault.decrease(positionKey, _decreaseParams(0));
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.InvalidLiquidity.selector, LIQUIDITY, LIQUIDITY));
        vault.decrease(positionKey, _decreaseParams(LIQUIDITY));
    }

    function test_DEC079_decreaseEnforcesPrincipalMinimums() public {
        bytes32 positionKey = _open();
        UniswapV4Adapter.DecreaseParams memory p = UniswapV4Adapter.DecreaseParams({
            liquidity: LIQUIDITY / 2, amount0Min: type(uint128).max, amount1Min: 0, deadline: block.timestamp
        });
        vm.expectRevert();
        vault.decrease(positionKey, abi.encode(p));
    }

    /// DEC-079: close realizes income first, then removes the whole principal and burns the position.
    function test_DEC079_closeSplitsPrincipalAndIncome() public {
        bytes32 positionKey = _open();
        v4.accrueFees(poolId, GROWTH, 3 * GROWTH);
        IAdapter.PositionValue memory v = adapter.positionValue(positionKey);

        uint256 before0 = token0.balanceOf(address(vault));
        uint256 before1 = token1.balanceOf(address(vault));
        IAdapter.Amounts memory a = vault.close(positionKey, _closeParams());

        assertEq(a.principal0, v.principal0);
        assertEq(a.principal1, v.principal1);
        assertEq(a.income0, v.income0);
        assertEq(a.income1, v.income1);
        assertEq(token0.balanceOf(address(vault)) - before0, a.principal0 + a.income0);
        assertEq(token1.balanceOf(address(vault)) - before1, a.principal1 + a.income1);
        assertEq(adapter.positionKeys().length, 0);
        assertEq(adapter.cumulativeIncome(address(token1)), a.income1);
        _assertAdapterHoldsNothing();

        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPosition.selector, positionKey));
        adapter.positionValue(positionKey);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPosition.selector, positionKey));
        vault.collect(positionKey);
    }

    /// DEC-079: the adapter settles and takes exact amounts, so a protocol that realizes a different amount than the
    /// adapter computed makes the whole call revert instead of misreporting principal or income.
    function test_DEC079_protocolMismatchReverts() public {
        bytes32 positionKey = _open();
        v4.accrueFees(poolId, GROWTH, GROWTH);
        v4.setFeeSkew0(1);
        vm.expectRevert(MockV4.CurrencyNotSettled.selector);
        vault.collect(positionKey);
    }

    /// DEC-079: principal is the position's amounts at the current price.
    function test_DEC079_principalTracksPrice() public {
        bytes32 positionKey = _open();
        IAdapter.PositionValue memory mid = adapter.positionValue(positionKey);

        v4.setTick(poolId, -300);
        IAdapter.PositionValue memory low = adapter.positionValue(positionKey);
        assertGt(low.principal0, mid.principal0);
        assertLt(low.principal1, mid.principal1);

        v4.setTick(poolId, LOWER - 10);
        IAdapter.PositionValue memory below = adapter.positionValue(positionKey);
        assertGt(below.principal0, low.principal0);
        assertEq(below.principal1, 0);

        v4.setTick(poolId, UPPER);
        IAdapter.PositionValue memory above = adapter.positionValue(positionKey);
        assertEq(above.principal0, 0);
        assertGt(above.principal1, mid.principal1);
    }

    /// Q60, DEC-092: cumulativeIncome = realized + uncollected, never decreasing across every verb.
    function testFuzz_Q60_cumulativeIncomeIsMonotonic(uint64 g0, uint64 g1, uint8 steps) public {
        bytes32 positionKey = _open();
        bytes32 second = _open();
        uint256 last0;
        uint256 last1;
        steps = uint8(bound(steps, 1, 12));
        for (uint256 i; i < steps; ++i) {
            v4.accrueFees(poolId, uint256(g0) << 64, uint256(g1) << 64);
            (last0, last1) = _assertMonotonic(last0, last1);
            uint256 op = i % 4;
            if (op == 0) {
                vault.collect(positionKey);
            } else if (op == 1) {
                vault.increase(second, address(token0), 1e20, address(token1), 1e20, _increaseParams(LIQUIDITY / 8));
            } else if (op == 2) {
                vault.decrease(positionKey, _decreaseParams(adapter.positionValue(positionKey).liquidity / 3));
            } else {
                vault.collect(second);
            }
            (last0, last1) = _assertMonotonic(last0, last1);
        }
        vault.close(positionKey, _closeParams());
        (last0, last1) = _assertMonotonic(last0, last1);
        vault.close(second, _closeParams());
        (last0, last1) = _assertMonotonic(last0, last1);
        assertEq(last0, adapter.realizedIncome(address(token0)));
        assertEq(last1, adapter.realizedIncome(address(token1)));
        _assertAdapterHoldsNothing();
    }

    function test_Q60_cumulativeIncomeIgnoresForeignToken() public {
        _open();
        v4.accrueFees(poolId, GROWTH, GROWTH);
        assertEq(adapter.cumulativeIncome(stranger), 0);
    }

    // ------------------------------------------------------------------ swap

    /// OQ-04: swap in a registered pool sends the output to the vault.
    function test_OQ04_swapSendsOutputToVault() public {
        v4.setSwap(2e18, 10_000);
        uint256 before1 = token1.balanceOf(address(vault));
        uint256 out = vault.swap(poolId, address(token0), 1e18, 2e18, _swapParams());
        assertEq(out, 2e18);
        assertEq(token1.balanceOf(address(vault)) - before1, 2e18);
        _assertAdapterHoldsNothing();

        uint256 before0 = token0.balanceOf(address(vault));
        out = vault.swap(poolId, address(token1), 1e18, 0, _swapParams());
        assertEq(token0.balanceOf(address(vault)) - before0, out);
    }

    /// IAdapter custody (Uniswap V4 verifier finding): input already sitting in the adapter goes back to the vault.
    function test_DEC080_swapHandsBackAnySurplusInput() public {
        v4.setSwap(2e18, 10_000);
        token0.mint(address(adapter), 3); // dust a stranger left in the adapter
        uint256 before0 = token0.balanceOf(address(vault));
        vault.swap(poolId, address(token0), 1e18, 0, _swapParams());
        assertEq(token0.balanceOf(address(vault)), before0 - 1e18 + 3, "the surplus came back, unreported");
        _assertAdapterHoldsNothing();
    }

    function test_OQ04_swapRevertsBelowMinimumOutput() public {
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientOutput.selector, 1e18, 1e18 + 1));
        vault.swap(poolId, address(token0), 1e18, 1e18 + 1, _swapParams());
    }

    function test_OQ04_swapRevertsOnPartialFill() public {
        v4.setSwap(1e18, 5000);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.PartialSwap.selector, 5e17, 1e18));
        vault.swap(poolId, address(token0), 1e18, 0, _swapParams());
    }

    function test_OQ04_swapRejectsForeignTokenZeroAmountAndExpiredDeadline() public {
        MockToken foreign = new MockToken("F", 18);
        foreign.mint(address(vault), 1e18);
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.TokenNotInPool.selector, address(foreign)));
        vault.swap(poolId, address(foreign), 1e18, 0, _swapParams());

        vm.expectRevert(UniswapV4Adapter.ZeroAmount.selector);
        vault.swap(poolId, address(token0), 0, 0, _swapParams());

        bytes memory expired =
            abi.encode(UniswapV4Adapter.SwapExactInputParams({sqrtPriceLimitX96: 0, deadline: block.timestamp - 1}));
        vm.expectRevert(abi.encodeWithSelector(UniswapV4Adapter.DeadlineExpired.selector, block.timestamp - 1));
        vault.swap(poolId, address(token0), 1e18, 0, expired);
    }

    // ------------------------------------------------------------------ helpers

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

    function _keys(PoolKey memory a, PoolKey memory b) internal pure returns (PoolKey[] memory keys) {
        keys = new PoolKey[](2);
        keys[0] = a;
        keys[1] = b;
    }

    function _open() internal returns (bytes32 positionKey) {
        (positionKey,,) = vault.open(poolId, address(token0), 1e20, address(token1), 1e20, _openParams(LIQUIDITY));
    }

    function _open_(uint128 liquidity) internal view returns (UniswapV4Adapter.OpenParams memory) {
        return UniswapV4Adapter.OpenParams({
            tickLower: LOWER,
            tickUpper: UPPER,
            liquidity: liquidity,
            amount0Max: 1e20,
            amount1Max: 1e20,
            amount0Min: 0,
            amount1Min: 0,
            deadline: block.timestamp
        });
    }

    function _openParams(uint128 liquidity) internal view returns (bytes memory) {
        return abi.encode(_open_(liquidity));
    }

    function _increaseParams(uint128 liquidity) internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.IncreaseParams({
                liquidity: liquidity,
                amount0Max: 1e20,
                amount1Max: 1e20,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _decreaseParams(uint128 liquidity) internal view returns (bytes memory) {
        return abi.encode(
            UniswapV4Adapter.DecreaseParams({
                liquidity: liquidity, amount0Min: 0, amount1Min: 0, deadline: block.timestamp
            })
        );
    }

    function _closeParams() internal view returns (bytes memory) {
        return abi.encode(UniswapV4Adapter.CloseParams({amount0Min: 0, amount1Min: 0, deadline: block.timestamp}));
    }

    function _swapParams() internal view returns (bytes memory) {
        return abi.encode(UniswapV4Adapter.SwapExactInputParams({sqrtPriceLimitX96: 0, deadline: block.timestamp}));
    }

    function _assertMonotonic(uint256 last0, uint256 last1) internal view returns (uint256 now0, uint256 now1) {
        now0 = adapter.cumulativeIncome(address(token0));
        now1 = adapter.cumulativeIncome(address(token1));
        assertGe(now0, last0, "cumulativeIncome token0 decreased");
        assertGe(now1, last1, "cumulativeIncome token1 decreased");
    }

    /// DEC-080 / IAdapter custody: no idle balance and no allowance left between calls.
    function _assertAdapterHoldsNothing() internal view {
        assertEq(token0.balanceOf(address(adapter)), 0);
        assertEq(token1.balanceOf(address(adapter)), 0);
        assertEq(IERC20(address(token0)).allowance(address(adapter), address(permit2)), 0);
        assertEq(IERC20(address(token1)).allowance(address(adapter), address(permit2)), 0);
        (uint160 p0,,) = permit2.allowance(address(adapter), address(token0), address(v4));
        (uint160 p1,,) = permit2.allowance(address(adapter), address(token1), address(v4));
        assertEq(p0, 0);
        assertEq(p1, 0);
    }
}
