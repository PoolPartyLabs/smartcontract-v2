// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";

import {AdaptersForkBase} from "./AdaptersForkBase.sol";

/// @notice (adapters review) Measurement on the live Arbitrum WETH/USDC 0.05% V4 pool: the automatic unwind closes a
///         fund position and sells its WETH leg in the same pool with a floor of 95% of the spot quote
///         (`SpokeVault._unwindSwap`, `MAX_UNWIND_SLIPPAGE_BPS = 500`): how much WETH the pool absorbs within that
///         floor (refutes, at these sizes, that the unwind cannot sell into the pool it just left).
/// @notice Ported to fix/pp-sc-fix-independent-review: MEASUREMENT, kept. Since S-2 the floor is
///         `max(spot, price source) - 5%`; with the pool at the oracle the two coincide. The extra column is the
///         liveness side of the OPEN `MAX_UNWIND_SLIPPAGE_BPS` decision: whether the honest sale would clear a 1% floor
///         (the review's recommendation) in the live pool, before the fund's own liquidity leaves it. e5c778a: 20 WETH
///         returned 97.04% of the spot quote, 1 WETH 99.79%.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/adapters/UnwindSwapDepthFork.t.sol' -vv
contract UnwindSwapDepthFork is AdaptersForkBase {
    function _secondFee() internal pure override returns (uint24) {
        return 7777;
    }

    /// (1) WETH sales through the fund's adapter into the live pool (no fund position in it): output against the
    ///     spot quote the unwind floors at.
    function test_REVIEW_L05_measure_depthWithinTheUnwindFloor() public {
        uint256[8] memory sizes = [uint256(1e18), 2e18, 4e18, 6e18, 8e18, 10e18, 15e18, 20e18];
        uint256 largestUnderOnePercent;
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            uint256 spotUsdc = adapter.spotQuote(livePool, WETH, sizes[i]);
            deal(WETH, address(adapter), sizes[i]);
            vm.prank(address(hubVault));
            uint256 out = adapter.swapExactInput(livePool, WETH, sizes[i], 0, "");
            console2.log("WETH sold (milli-WETH)", sizes[i] / 1e15);
            console2.log("  output / spot quote (bps)", out * 10_000 / spotUsdc);
            assertGe(out * 10_000 / spotUsdc, 9500, "the honest sale clears today's 5% floor");
            if (out * 10_000 >= spotUsdc * 9900) largestUnderOnePercent = sizes[i];
            vm.revertToState(snap);
        }
        console2.log("largest size tried that a 1% floor lets through (milli-WETH)", largestUnderOnePercent / 1e15);
    }
}
