// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice Consolidated report section 9, "Execution price" row (spoke-a report M-01; register S-8, Open, founder
///         decision), ported to main, STILL_PRESENT as decided: the manager's swap takes an optional maximum loss
///         without a protocol cap (DEC-142), and nothing compares execution with the price source. Since DEC-136 the
///         swap runs through the Mandate swap adapter, never in a fund pool; a swap adapter that fills at 1/100 of the
///         oracle price (a moved venue, the stand-in's haircut) takes the swapped value with no revert when the
///         manager sends no maximum; the exit verbs take minimums of zero as well. Real hub SpokeVault, adapter and
///         CoreVault over MockV4.
contract M01_ManagerSwapExtraction is SpokeAHubFixture {
    function test_POC_REVIEW_SEC9_managerSwapAtAnyPriceIsAccepted() public {
        _deposit(alice, 1_000_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(500_000e6);
        uint256 assetsBefore = vault.shareAssets();

        // The venue has been moved so that 1 USDC buys 1/100 of what the oracle says (2,500 USDC per WETH). The
        // manager passes no maximum loss (DEC-142: optional).
        hubSwap.setPrice(address(usdc), address(weth), 1e18, 2500e6);
        hubSwap.setHaircutBps(9900);
        vm.prank(manager);
        uint256 wethOut = hubVault.swap(address(hubSwap), address(usdc), address(weth), 500_000e6, 0, "");
        uint256 assetsAfter = vault.shareAssets();
        console2.log("WETH received for 500,000 USDC", wethOut);
        console2.log("share assets before", assetsBefore);
        console2.log("share assets after", assetsAfter);
        assertEq(assetsBefore, 997_501e6);
        assertEq(wethOut, 2e18, "2 WETH (5,000 USDC at the oracle) for 500,000 USDC");
        assertEq(assetsAfter, 502_501e6);
        assertEq(assetsBefore - assetsAfter, 495_000e6, "495,000 USDC left the fund through one manager swap");
    }

    function test_POC_REVIEW_SEC9_exitVerbsAcceptMinimumsOfZero() public {
        _deposit(alice, 1_000_000e6);
        _managerOpensHubPosition(500_000e6);
        // A close at a moved spot with amount0Min = amount1Min = 0 is accepted as well.
        _crushWethSpot(100);
        bytes memory params =
            abi.encode(UniswapV4Adapter.CloseParams({amount0Min: 0, amount1Min: 0, deadline: block.timestamp}));
        vm.prank(manager);
        hubVault.closePosition(address(adapter), positionKey, params);
        assertEq(hubVault.positions().length, 0);
    }
}
