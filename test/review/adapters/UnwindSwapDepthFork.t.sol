// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {console2} from "forge-std/Test.sol";

import {AdaptersForkBase} from "./AdaptersForkBase.sol";

/// @notice Live V3 sale-depth measurement through the Mandate swap adapter, never the fund's V4 pool (DEC-136/153).
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
            deal(WETH, address(hubSwap), 0);
            deal(WETH, address(hubVault), sizes[i]);
            vm.startPrank(address(hubVault));
            IERC20(WETH).approve(address(hubSwap), sizes[i]);
            (uint24 fee,) = hubSwap.bestDirectFee(WETH, USDC, sizes[i]);
            (uint256 out, uint256 spotUsdc,) = hubSwap.swapDirect(WETH, USDC, sizes[i], fee, 0);
            vm.stopPrank();
            console2.log("WETH sold (milli-WETH)", sizes[i] / 1e15);
            console2.log("  output / spot quote (bps)", out * 10_000 / spotUsdc);
            assertGe(out * 10_000 / spotUsdc, 9500, "the honest sale clears today's 5% floor");
            if (out * 10_000 >= spotUsdc * 9900) largestUnderOnePercent = sizes[i];
            vm.revertToState(snap);
        }
        console2.log("largest size tried that a 1% floor lets through (milli-WETH)", largestUnderOnePercent / 1e15);
    }
}
