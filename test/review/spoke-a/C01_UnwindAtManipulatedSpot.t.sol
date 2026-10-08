// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice DEC-148 regression: an unavailable independent swap route excludes the position and pays only from Idle.
/// @dev The atomic step rolls back its exit, preserves the position and leaves the request open for retry (DEC-151).
contract C01_UnwindAtManipulatedSpot is SpokeAHubFixture {
    function test_REVIEW_C01_crushedSpotUnwindRevertsAndTheClaimIsPaidFromIdleOnly() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 20_000e6);
        _managerOpensHubPosition(1_000_000e6);

        uint256 assetsBefore = vault.shareAssets();
        uint256 aliceBefore = _valueOf(alice);
        uint256 freeIdleBefore = vault.freeIdle();
        assertEq(assetsBefore, 1_017_450_999_998);
        assertEq(aliceBefore, 997_499_999_998);
        assertEq(freeIdleBefore, 17_451e6);

        // Same push as the e5c778a PoC: WETH spot at 1/1,250 of the oracle, the mock fills at that spot.
        _crushWethSpot(1250);
        hubSwap.setNoRoute(true);

        vm.expectEmit(false, false, false, false, address(hubVault));
        emit ISpokeVaultUnwind.UnwindStepExcluded(bytes32(0), address(adapter), bytes32(0), "");
        ICoreVault.PayoutReceipt memory r = _request(mallory, 19_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        _restoreSpot();

        console2.log("unwind proceeds", r.unwindProceeds);
        console2.log("usdc paid to mallory", r.usdcPaid);
        console2.log("share assets after", vault.shareAssets());

        // The unwind reverted whole: no position closed, no WETH sold, nothing taken from the fund.
        assertEq(r.unwindProceeds, 0, "unwind reverted under the oracle floor");
        assertEq(hubVault.positions().length, 1, "position kept");
        assertLe(r.usdcPaid + r.flowFee, freeIdleBefore, "paid from Free Idle only");
        assertTrue(vault.payoutRequest(mallory).open, "partial payout, request stays open");
        // Share Assets fall only by what Mallory was paid gross less her Payout Fee, which stays in Idle (DEC-144);
        // Alice's value is untouched, and the fee even raises it.
        assertEq(vault.shareAssets(), assetsBefore - r.usdcGross + r.payoutFee);
        assertGe(_valueOf(alice), aliceBefore, "the holder who stays loses nothing");
    }
}
