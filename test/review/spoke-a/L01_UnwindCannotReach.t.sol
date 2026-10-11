// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Mandate, PoolConfig} from "../../../src/mandate/Mandate.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice [L-05] (spoke-a report L-01), FIXED by the proportional unwind (WP-09; DEC-137, D-11): the automatic unwind
///         used to exit positions only, so Unallocated Balance in any token but USDC was never swapped. It now sells the
///         same fraction of every non-base Unallocated Balance as of every position. Real CoreVault + hub SpokeVault +
///         UniswapV4Adapter over MockV4, the Mandate swap adapter stand-in.
contract L01_UnwindCannotReach is SpokeAHubFixture {
    function test_REVIEW_L05_nonUsdcUnallocatedBalanceIsUnwoundAtTheFraction() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 50_000e6);
        // The manager allocates and swaps it into WETH through the swap adapter (DEC-136), leaving it in Unallocated
        // Balance (no position).
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1_000_000e6);
        hubSwap.setPrice(address(usdc), address(weth), 1e18, 2500e6); // USDC -> WETH at the oracle price
        vm.prank(manager);
        hubVault.swap(address(hubSwap), address(usdc), address(weth), 1_000_000e6, 0, "");
        _unwindSwapsAtOracle();

        // Share Assets count the 400 WETH at the oracle price, so Mallory's shares are worth 49,875 USDC; Free Idle
        // is 47,376, so 2,499 shares of the 1,000,000 not covered by Idle are missing: f = 2,499 / 1,000,000 x 1.02.
        uint256 value = _valueOf(mallory);
        assertEq(value, 49_875e6);
        ICoreVault.PayoutReceipt memory r = _request(mallory, value, ICoreVaultPayouts.PayoutMode.Instant);
        console2.log("mallory asked", value);
        console2.log("unwind proceeds", r.unwindProceeds);
        assertEq(r.fracNum * 1_000_000 * 10_000, r.fracDen * 2499 * 10_200, "DEC-137: (S - A/P) / (T - A/P) x 1.02");
        uint256 wethSold = 400e18 - hubVault.unallocatedBalance(address(weth));
        assertEq(wethSold, Math.mulDiv(400e18, r.fracNum, r.fracDen), "the fraction of the Unallocated WETH was sold");
        assertEq(r.unwindProceeds, wethSold * 2500e6 / 1e18);
        assertEq(r.usdcOutstanding, 0, "paid in full");
        assertFalse(vault.payoutRequest(mallory).open);
    }
}

/// @notice [L-05] (adapters report L-03, the "single-asset non-USDC step" part), FIXED: a single-token pool whose token
///         is not USDC (an Aave WETH reserve; here the exact-value mock with `poolTokens = (WETH, 0)`) used to make
///         every unwind that reached the step revert. Since WP-09 the step's WETH is sold through the swap adapter.
contract L05_SingleAssetNonUsdcStep is SpokeAHubFixture {
    bytes32 internal constant EXACT_WETH = keccak256("exact-value WETH");

    function _extraPools() internal override {
        exact.addPool(EXACT_WETH, address(weth), address(0));
    }

    /// @dev Pools: V4 WETH/USDC, exact-value USDC and the single-asset WETH reserve.
    function _mandate(address adapter_, address exact_) internal view override returns (Mandate memory m) {
        m = super._mandate(adapter_, exact_);
        PoolConfig[] memory pools = new PoolConfig[](3);
        (pools[0], pools[1], pools[2]) = (m.pools[0], m.pools[1], PoolConfig(HUB, exact_, EXACT_WETH));
        m.pools = pools;
    }

    /// @dev Fixed on fix/pp-sc-fix-independent-review (plan T14), then by the proportional unwind (WP-09): the
    ///      single-asset WETH step used to revert `UnexpectedToken`, then needed a hinted route. Its WETH is now sold
    ///      through the Mandate swap adapter like any other (DEC-136 item 4), and every step gives the same fraction.
    function test_REVIEW_L05_singleAssetWethStepIsSoldThroughTheSwapAdapter() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 300_000e6);
        _managerOpensHubPosition(100_000e6); // V4: ~100,000 USDC of value
        // 10,000 USDC -> 4 WETH supplied to the single-asset WETH reserve.
        vm.prank(manager);
        vault.allocateToHubSpokeVault(10_000e6);
        hubSwap.setPrice(address(usdc), address(weth), 1e18, 2500e6);
        vm.prank(manager);
        uint256 wethIn = hubVault.swap(address(hubSwap), address(usdc), address(weth), 10_000e6, 0, "");
        vm.prank(manager);
        (bytes32 wethKey,,) = hubVault.openPosition(address(exact), EXACT_WETH, wethIn, 0, "");
        _managerSuppliesExact(1_140_000e6); // exact-value USDC
        _unwindSwapsAtOracle();
        assertEq(hubVault.positions().length, 3);

        // A claim above Free Idle: every step delivers its fraction, the WETH reserve's included, with no route given;
        // the WETH its exit returned is sold (the Unallocated WETH the V4 position left gives the same fraction).
        uint256 wethLeft = hubVault.unallocatedBalance(address(weth));
        ICoreVault.PayoutReceipt memory r = _request(mallory, 290_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertEq(r.excludedPositions, 0);
        assertTrue(hubVault.unwindDelivered(r.requestId, address(exact), wethKey), "the WETH step delivered");
        assertEq(
            hubVault.unallocatedBalance(address(weth)),
            wethLeft - Math.mulDiv(wethLeft, r.fracNum, r.fracDen),
            "nothing of the WETH step's exit stayed unsold"
        );
        assertEq(r.usdcOutstanding, 0, "paid in full");
    }
}
