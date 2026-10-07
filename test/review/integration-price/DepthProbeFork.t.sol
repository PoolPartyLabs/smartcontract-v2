// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";

/// @notice Review probe (integration-price), not a finding: what it costs to move the Uniswap V4 pools that
///         docs/INTEGRATIONS.md lists, on both chains, at a fork block near the head. For each target price (a fraction
///         of the start price) it measures the token sold to reach it and the cost of the round trip back to the exact
///         start price (LP fees plus rounding), valued at the Chainlink ETH / USD answer the fund's price source reads.
/// @notice Ported to fix/pp-sc-fix-independent-review (review I-08): MEASUREMENT, kept unchanged; no contract change
///         touches pool depth. The numbers fed the S-2 residual (`UnwindAttackFork` section 8, before the proportional
///         unwind of WP-09 removed the 5% floor).
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
///      ARBITRUM_FORK_BLOCK=<head - 300> ROBINHOOD_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/DepthProbeFork.t.sol' -vv
contract DepthProbeFork is Test {
    address constant ARB_PM = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant ARB_SV = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant RH_PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant RH_SV = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612; // Arbitrum One

    /// @dev price1e18 as ChainlinkPriceSource computes it: USDC base units per wei, times 1e18.
    uint256 internal ethUsd;
    address internal trader = makeAddr("depthTrader");

    // Pool under probe.
    PoolKey internal key;
    address internal sv;
    address internal weth;
    address internal usd;
    uint160 internal sqrtP0;
    V4SwapRouter internal router;

    function _oracle() internal {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        (, int256 answer,,,) = IChainlinkAggregatorV3(ETH_USD).latestRoundData();
        ethUsd = Math.mulDiv(uint256(answer), 1e24, 1e26);
    }

    function test_REVIEW_I08_measure_probe_arbitrum_listedPools() public {
        _oracle();
        _probe("ARB V4 WETH/USDC 0.05% (listed)", ARB_PM, ARB_SV, ARB_WETH, ARB_USDC, 500, 10);
        _probe("ARB V4 WETH/USDC 0.3%", ARB_PM, ARB_SV, ARB_WETH, ARB_USDC, 3000, 60);
    }

    function test_REVIEW_I08_measure_probe_robinhood_listedPools() public {
        _oracle();
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"), vm.envUint("ROBINHOOD_FORK_BLOCK"));
        _probe("RH V4 WETH/USDG 0.05% (listed)", RH_PM, RH_SV, RH_WETH, RH_USDG, 500, 10);
        _probe("RH V4 WETH/USDG 0.3% (listed)", RH_PM, RH_SV, RH_WETH, RH_USDG, 3000, 60);
    }

    function _probe(string memory name, address pm, address sv_, address weth_, address usd_, uint24 fee, int24 spacing)
        internal
    {
        key = PoolKey(Currency.wrap(weth_), Currency.wrap(usd_), fee, spacing, IHooks(address(0)));
        sv = sv_;
        weth = weth_;
        usd = usd_;
        router = new V4SwapRouter(IPoolManager(pm));
        deal(weth, trader, 1_000_000e18);
        deal(usd, trader, 5_000_000_000e6);
        vm.startPrank(trader);
        IERC20(weth).approve(address(router), type(uint256).max);
        IERC20(usd).approve(address(router), type(uint256).max);
        vm.stopPrank();

        int24 tick0;
        (sqrtP0, tick0,,) = IStateView(sv).getSlot0(key.toId());
        console2.log("==", name);
        console2.log("  tick0", tick0);
        console2.log("  in-range liquidity", IStateView(sv).getLiquidity(key.toId()));
        console2.log("  spot USD per WETH (6dp)", Math.mulDiv(Math.mulDiv(sqrtP0, sqrtP0, 1 << 96), 1e18, 1 << 96));
        console2.log("  oracle USD per WETH (6dp)", ethUsd);

        uint256 snap = vm.snapshotState();
        // down 1%, 2%, 5%, 10%, 25%, 50%, 90%, 99%, 99.9%; up 1%, 2%, 5%, 10%, 50%
        uint256[14] memory f = [
            uint256(990_000),
            980_000,
            950_000,
            900_000,
            750_000,
            500_000,
            100_000,
            10_000,
            1000,
            1_010_000,
            1_020_000,
            1_050_000,
            1_100_000,
            1_500_000
        ];
        for (uint256 i; i < f.length; ++i) {
            vm.revertToState(snap);
            _step(f[i]);
        }
        vm.revertToState(snap);
    }

    function _step(uint256 fraction) internal {
        uint160 target = uint160(Math.mulDiv(sqrtP0, Math.sqrt(fraction * 1e12), 1e9));
        bool down = fraction < 1e6;
        uint256 w0 = IERC20(weth).balanceOf(trader);
        uint256 u0 = IERC20(usd).balanceOf(trader);
        vm.prank(trader);
        router.swap(key, down, -int256(uint256(type(uint128).max)), target);
        console2.log(string.concat("  price x", vm.toString(fraction), "/1e6"));
        if (down) {
            console2.log("    WETH sold to get there (1e18)", w0 - IERC20(weth).balanceOf(trader));
            console2.log("    USD received (6dp)", IERC20(usd).balanceOf(trader) - u0);
        } else {
            console2.log("    USD sold to get there (6dp)", u0 - IERC20(usd).balanceOf(trader));
            console2.log("    WETH received (1e18)", IERC20(weth).balanceOf(trader) - w0);
        }
        vm.prank(trader);
        router.swap(key, !down, -int256(uint256(type(uint128).max)), sqrtP0);
        (uint160 sqrtBack,,,) = IStateView(sv).getSlot0(key.toId());
        int256 dw = int256(IERC20(weth).balanceOf(trader)) - int256(w0);
        int256 du = int256(IERC20(usd).balanceOf(trader)) - int256(u0);
        console2.log("    round-trip cost at oracle (USD 6dp)", -(dw * int256(ethUsd) / 1e18 + du));
        assertEq(sqrtBack, sqrtP0, "back at the exact start price");
    }
}
