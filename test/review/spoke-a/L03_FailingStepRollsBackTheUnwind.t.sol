// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice [L-05] (spoke-a report L-03), ported to main, STILL_PRESENT (register S-27, Acknowledged; IN-6 refuted it
///         as a defect under DEC-068 and DEC-069). One step that cannot be served (an Aave-like reserve without
///         liquidity) reverts the whole `unwindForPayout`, so the exits that already succeeded before it are rolled
///         back and the claim is paid from Idle only.
contract L03_FailingStepRollsBackTheUnwind is SpokeAHubFixture {
    function test_POC_REVIEW_L05_illiquidSecondStepDiscardsTheFirstStepsProceeds() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 300_000e6);
        _managerOpensHubPosition(100_000e6); // V4 first in the unwind order: ~100,000 USDC of value
        _managerSuppliesExact(1_150_000e6); // exact-value second
        _unwindSwapsAtOracle();
        // Free Idle ~46,747; Mallory asks 290,000 Instant: the shortfall (~248,000 with the margin) takes the whole
        // V4 step (~99,000) and ~149,000 more from the exact-value step.
        exact.setRevertOnExit(true); // the exact-value reserve cannot pay right now

        uint256 freeIdle = vault.freeIdle();
        ICoreVault.PayoutReceipt memory r = _request(mallory, 290_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        console2.log("free idle", freeIdle);
        console2.log("unwind proceeds", r.unwindProceeds);
        console2.log("paid gross", r.usdcGross);
        // The V4 step could have produced ~99,000 USDC on its own; all of it was rolled back with the failing step.
        assertEq(r.unwindProceeds, 0);
        assertEq(hubVault.positions().length, 2, "the V4 exit was rolled back");
        assertEq(freeIdle, 46_751e6);
        assertEq(r.usdcGross, 46_750_999_999, "paid from Idle only");
        assertTrue(vault.payoutRequest(mallory).open);
    }
}
