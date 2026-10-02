// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {Mandate, PoolConfig} from "../../../src/mandate/Mandate.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice [L-05] (spoke-a report L-01), ported to main, STILL_PRESENT: the automatic unwind only exits positions of
///         the unwind order; Unallocated Balance in any token but USDC is never swapped, so a Mandate whose unwind
///         order covers every pool still does not guarantee an exit. No sweep fix touched this path. Real CoreVault +
///         hub SpokeVault + UniswapV4Adapter over MockV4.
contract L01_UnwindCannotReach is SpokeAHubFixture {
    function test_POC_REVIEW_L05_nonUsdcUnallocatedBalanceIsNeverUnwound() public {
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

        // Share Assets still count the 400 WETH at the oracle price, so Mallory's shares are worth 49,875 USDC ...
        uint256 value = _valueOf(mallory);
        _request(mallory, value, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(mallory);
        console2.log("mallory asked", value);
        console2.log("paid gross", r.usdcGross);
        console2.log("outstanding", r.usdcOutstanding);
        // ... but the unwind returns nothing: there is no position, and it never swaps Unallocated WETH.
        assertEq(value, 49_875e6);
        assertEq(r.unwindProceeds, 0);
        assertEq(r.usdcGross, 47_376e6, "paid from Free Idle only");
        assertEq(r.usdcOutstanding, 2499e6);
        assertTrue(vault.payoutRequest(mallory).open);
        assertEq(hubVault.unallocatedBalance(address(weth)), 400e18);
        // DEC-144: the first claim's Payout Fee stayed in Idle; a retry is paid from that Free Idle alone (plus the
        // sub-share remainder), still unwinding nothing, and the request stays open.
        uint256 free = vault.freeIdle();
        assertGe(free, r.payoutFee);
        vm.prank(mallory);
        ICoreVault.PayoutReceipt memory again = vault.claimPayout("");
        assertEq(again.unwindProceeds, 0);
        assertLe(again.usdcGross, free);
        assertTrue(vault.payoutRequest(mallory).open);
        assertEq(hubVault.unallocatedBalance(address(weth)), 400e18);
    }
}

/// @notice [L-05] (adapters report L-03, the "single-asset non-USDC step" part), STILL_PRESENT on main: a
///         single-token pool whose token is not USDC (an Aave WETH reserve; here the exact-value mock with
///         `poolTokens = (WETH, 0)`) makes `SpokeVault._otherToken` revert `UnexpectedToken` inside `_unwindRoute`,
///         before the claimant's hint is read. Every unwind that reaches the step reverts, with or without a valid
///         WETH/USDC route hint, and the earlier V4 step's exit is rolled back with it.
contract L05_SingleAssetNonUsdcStep is SpokeAHubFixture {
    bytes32 internal constant EXACT_WETH = keccak256("exact-value WETH");

    function _extraPools() internal override {
        exact.addPool(EXACT_WETH, address(weth), address(0));
    }

    /// @dev Pools: V4 WETH/USDC, exact-value USDC and the single-asset WETH reserve. The unwind walks the positions in
    ///      registry order (DEC-137 interim): the test opens V4 first, then the WETH reserve.
    function _mandate(address adapter_, address exact_) internal view override returns (Mandate memory m) {
        m = super._mandate(adapter_, exact_);
        PoolConfig[] memory pools = new PoolConfig[](3);
        (pools[0], pools[1], pools[2]) = (m.pools[0], m.pools[1], PoolConfig(HUB, exact_, EXACT_WETH));
        m.pools = pools;
    }

    /// @dev Fixed on fix/pp-sc-fix-independent-review (plan T14): the single-asset WETH step used to revert
    ///      `UnexpectedToken` with or without a route hint, rolling back the V4 exit before it. It now takes the hinted
    ///      Mandate route; without a hint it is refused by name, and the claim then falls back to Idle as before.
    function test_REVIEW_L05_singleAssetWethStepUnwindsThroughTheHintedRoute() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 300_000e6);
        _managerOpensHubPosition(100_000e6); // V4 first: ~100,000 USDC of value
        // 10,000 USDC -> 4 WETH supplied to the single-asset WETH reserve (second step).
        vm.prank(manager);
        vault.allocateToHubSpokeVault(10_000e6);
        hubSwap.setPrice(address(usdc), address(weth), 1e18, 2500e6);
        vm.prank(manager);
        uint256 wethIn = hubVault.swap(address(hubSwap), address(usdc), address(weth), 10_000e6, 0, "");
        vm.prank(manager);
        hubVault.openPosition(address(exact), EXACT_WETH, wethIn, 0, "");
        _managerSuppliesExact(1_140_000e6); // exact-value USDC third
        _unwindSwapsAtOracle();
        assertEq(hubVault.positions().length, 3);

        // Without a route for WETH the step is refused by name.
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(SpokeUnwindTypes.MissingUnwindSwap.selector, address(weth)));
        hubVault.unwindForPayout(150_000e6, "");

        // With a hint naming the Mandate's WETH/USDC route for the WETH step (second position visited) the unwind
        // walks all three steps and reaches the target.
        SpokeUnwindTypes.UnwindHint[] memory hints = new SpokeUnwindTypes.UnwindHint[](2);
        hints[1].swaps = new SpokeUnwindTypes.UnwindSwap[](1);
        hints[1].swaps[0] = SpokeUnwindTypes.UnwindSwap(address(adapter), poolId, address(weth), 0, "");
        uint256 snap = vm.snapshotState();
        vm.prank(address(vault));
        assertEq(hubVault.unwindForPayout(150_000e6, SpokeUnwindTypes.encodeHints(hints)), 150_000e6);
        vm.revertToState(snap);

        // Through a claim needing ~248,000 of unwind, with the hint: paid in full.
        _request(mallory, 290_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        vm.prank(mallory);
        ICoreVault.PayoutReceipt memory r = vault.claimPayout(SpokeUnwindTypes.encodeHints(hints));
        console2.log("unwind proceeds", r.unwindProceeds);
        assertGt(r.unwindProceeds, 200_000e6, "the unwind ran through the WETH step");
        assertFalse(vault.payoutRequest(mallory).open, "the request closed");
    }
}
