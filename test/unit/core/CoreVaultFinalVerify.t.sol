// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Final whole-tree verification of the integration branch, hub side. Each test pins a finding by asserting
///         what the code does today, so the suite stays green and a later fix must change the assertion deliberately.
contract CoreVaultFinalVerifyTest is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant INSTANT = ICoreVault.PayoutMode.Instant;
    ICoreVault.PayoutMode internal constant STANDARD = ICoreVault.PayoutMode.Standard;

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-072 / DEC-017 / DEC-024 / DEC-065 (final verification, MAJOR): a Standard request reserves
    // `min(usdcAmount, Free Idle)` with no bound from the holder's own share value. A holder of one share can lock
    // every unit of Free Idle in the Payout Reserve, never claim (no cancellation, DEC-024; only the requester
    // claims, DEC-065), and keep it locked for good: the manager cannot allocate (DEC-017) and every other Instant
    // Payout must unwind (DEC-081, margin and Market Costs on the fund, DEC-097). No decision states a cap and
    // docs/OPEN-QUESTIONS.md does not list the gap. The most a request can ever pay is the holder's whole balance at
    // the claim's Share Price (DEC-020), so that is the natural bound.
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC072_MAJOR_oneShareHolderReservesAllFreeIdleWithAStandardRequestItNeverClaims() public {
        _deposit(alice, 10_000e6); // Idle 9,975 after the 25 bps flow fee
        _deposit(bob, 2e6); // 1 share at 1.00
        assertEq(shares.balanceOf(bob), 1e18);
        uint256 freeBefore = vault.freeIdle();
        assertGt(freeBefore, 9000e6);

        _request(bob, 1_000_000_000e6, STANDARD);
        assertEq(vault.payoutRequest(bob).reserved, freeBefore, "the whole Free Idle is reserved for one share");
        assertEq(vault.freeIdle(), 0);

        // DEC-017: the manager can no longer allocate anything.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 1e6, 0));
        vault.allocateToHubSpokeVault(1e6);

        // DEC-095: another holder's Instant Payout finds no Free Idle, so it must unwind or fail.
        _request(alice, 100e6, INSTANT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 100e6, 0));
        vault.claimPayout("");

        // Nothing releases the reserve but bob's own claim, which pays one share and frees the rest.
        vm.warp(block.timestamp + 72 hours);
        _claim(bob);
        assertEq(vault.payoutReserve(), 0);
        assertEq(vault.freeIdle(), freeBefore - 1e6);
    }
}
