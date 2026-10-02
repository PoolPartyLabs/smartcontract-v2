// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Final whole-tree verification of the integration branch, hub side. Each test pins a finding by asserting
///         the behaviour its fix established.
contract CoreVaultFinalVerifyTest is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant INSTANT = ICoreVault.PayoutMode.Instant;
    ICoreVault.PayoutMode internal constant STANDARD = ICoreVault.PayoutMode.Standard;

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-072 / DEC-017 / DEC-024 / DEC-065 (final verification finding, fixed): a Standard request reserved
    // `min(usdcAmount, Free Idle)` with no bound from the holder's own share value, so a holder of one share could lock
    // every unit of Free Idle in the Payout Reserve and never claim (no cancellation, DEC-024; only the requester
    // claims, DEC-065): the manager could not allocate (DEC-017) and every other Instant Payout had to unwind. The most
    // a request can ever pay is the holder's whole balance (DEC-020), so the reserve is now
    // `min(usdcAmount, usdcFor(balance, sharePrice), Free Idle)` at request time (OPEN reading FV-OQ-1).
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC072_oneShareHolderReservesOnlyItsShareValue() public {
        _deposit(alice, 10_000e6); // Idle 9,975 after the 25 bps flow fee
        _deposit(bob, 2e6); // 1 share at 1.00
        assertEq(shares.balanceOf(bob), 1e18);
        uint256 freeBefore = vault.freeIdle();
        assertGt(freeBefore, 9000e6);

        _request(bob, 1_000_000_000e6, STANDARD);
        assertEq(vault.payoutRequest(bob).reserved, 1e6, "the reserve is bob's one share at 1.00");
        assertEq(vault.payoutRequest(bob).usdcRequested, 1_000_000_000e6, "the request keeps the amount asked");
        assertEq(vault.freeIdle(), freeBefore - 1e6);

        // DEC-017: the manager can still allocate the rest of Free Idle.
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1e6);

        // DEC-095: another holder's Instant Payout is paid from Free Idle, no unwind.
        _request(alice, 100e6, INSTANT);
        ICoreVault.PayoutReceipt memory a = _claim(alice);
        assertEq(a.usdcGross, 100e6);
        assertEq(a.unwindProceeds, 0);

        // DEC-020: bob's claim burns his one share, pays what it is worth and closes the request.
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory b = _claim(bob);
        assertEq(b.sharesBurned, 1e18);
        // DEC-144: alice's Payout Fee stayed in Idle and raised the Share Price to 9,878 / 9,876.
        assertEq(b.usdcGross, 1.000202e6);
        assertFalse(b.closedBelowOneShare);
        assertFalse(vault.payoutRequest(bob).open);
        assertEq(vault.payoutReserve(), 0);
    }
}
