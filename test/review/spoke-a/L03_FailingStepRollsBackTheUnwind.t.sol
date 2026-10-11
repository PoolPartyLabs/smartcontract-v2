// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice [L-05] (spoke-a report L-03; register S-27), FIXED by DEC-148 in the proportional unwind (WP-09): one step
///         that could not be served (an Aave-like reserve without liquidity) used to revert the whole
///         `unwindForPayout`, rolling back the exits that had succeeded before it, and the claim was paid from Idle
///         only. Each position is now its own atomic step: the failing one is left out (DEC-148), the others deliver,
///         and the request stays open with what delivered remembered for the next attempt (DEC-151).
contract L03_FailingStepRollsBackTheUnwind is SpokeAHubFixture {
    function test_REVIEW_L05_anIlliquidStepLeavesOnlyItselfOut() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 300_000e6);
        _managerOpensHubPosition(100_000e6); // ~100,000 USDC of value
        bytes32 v4Key = positionKey;
        bytes32 exactKey = _managerSuppliesExact(1_150_000e6);
        _unwindSwapsAtOracle();
        exact.setRevertOnExit(true); // the exact-value reserve cannot pay right now

        uint256 freeIdle = vault.freeIdle();
        assertEq(freeIdle, 46_751e6);
        ICoreVault.PayoutReceipt memory r = _request(mallory, 290_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        console2.log("unwind proceeds", r.unwindProceeds);
        console2.log("paid gross", r.usdcGross);
        assertEq(r.excludedPositions, 1, "only the illiquid step is left out");
        assertGt(r.unwindProceeds, 0, "the V4 step's proceeds are kept");
        assertTrue(hubVault.unwindDelivered(r.requestId, address(adapter), v4Key));
        assertFalse(hubVault.unwindDelivered(r.requestId, address(exact), exactKey));
        assertGt(r.usdcGross, freeIdle, "paid beyond Idle");
        assertTrue(vault.payoutRequest(mallory).open, "DEC-068 (b): the rest stays open");

        // DEC-151: once the reserve pays again, the next attempt unwinds only the step that had not delivered.
        exact.setRevertOnExit(false);
        vm.prank(mallory);
        ICoreVault.PayoutReceipt memory again = vault.claimPayout(0);
        assertEq(again.excludedPositions, 0);
        assertEq(again.fracNum, r.fracNum, "the fraction fixed at the first attempt");
        assertTrue(hubVault.unwindDelivered(r.requestId, address(exact), exactKey));
    }
}
