// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";

/// @notice Review probe (spoke-a), not a finding: how much WETH moves the real Arbitrum V4 WETH/USDC 0.05% pool
///         (docs/INTEGRATIONS.md) down to a given fraction of its price, on a fork pinned near the head. Context for
///         consolidated I-08 (thin listed pools) and register S-32. Re-run on main: no source change applies; e5c778a
///         block 510379789 needed 28.1 WETH to reach 1/1,000 of the price, the depth moves with the live pool.
contract PoolDepthProbe is Test {
    address constant PM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant SV = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;

    function test_REVIEW_I08_measure_probeDepth() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        PoolKey memory key = PoolKey(Currency.wrap(WETH), Currency.wrap(USDC), 500, 10, IHooks(address(0)));
        bytes32 poolId = PoolId.unwrap(key.toId());
        V4SwapRouter router = new V4SwapRouter(IPoolManager(PM));
        address trader = makeAddr("trader");
        deal(WETH, trader, 1_000_000e18);
        deal(USDC, trader, 1_000_000_000e6);
        vm.startPrank(trader);
        IERC20(WETH).approve(address(router), type(uint256).max);
        IERC20(USDC).approve(address(router), type(uint256).max);
        vm.stopPrank();

        (, int24 tick0,,) = IStateView(SV).getSlot0(PoolId.wrap(poolId));
        console2.log("tick0", tick0);
        console2.log("liquidity0", IStateView(SV).getLiquidity(PoolId.wrap(poolId)));
        // Price fractions (WETH is token0: a lower WETH price is a lower tick). ln(f)/ln(1.0001) ticks.
        int24[7] memory drops = [int24(-1054), -2231, -6932, -13_863, -23_027, -46_054, -69_081]; // 0.9, 0.8, 0.5, 0.25, 0.1, 0.01, 0.001
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < drops.length; ++i) {
            vm.revertToState(snap);
            int24 target = tick0 + drops[i];
            uint256 wethBefore = IERC20(WETH).balanceOf(trader);
            uint256 usdcBefore = IERC20(USDC).balanceOf(trader);
            vm.prank(trader);
            router.swap(key, true, -int256(uint256(type(uint128).max)), TickMath.getSqrtPriceAtTick(target));
            uint256 wethIn = wethBefore - IERC20(WETH).balanceOf(trader);
            uint256 usdcOut = IERC20(USDC).balanceOf(trader) - usdcBefore;
            console2.log("drop ticks", drops[i]);
            console2.log("  WETH in (1e18)", wethIn);
            console2.log("  USDC out (1e6)", usdcOut);
            // swap back to tick0 to price the round trip
            vm.prank(trader);
            router.swap(key, false, -int256(uint256(type(uint128).max)), TickMath.getSqrtPriceAtTick(tick0));
            console2.log("  round-trip WETH lost (1e18)", wethBefore - IERC20(WETH).balanceOf(trader));
            console2.log("  round-trip USDC lost (1e6)", int256(usdcBefore) - int256(IERC20(USDC).balanceOf(trader)));
        }
    }
}
