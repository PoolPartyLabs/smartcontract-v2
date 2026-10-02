// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Adversarial verification, round 1, of the final verification fixes on the Core Vault: the Standard reserve
///         bound under a Share Price away from 1.00, a price that falls before the claim, and a hub valuation that
///         fails at request time (DEC-017, DEC-020, DEC-024, DEC-072, DEC-077, FV-OQ-1, OQ-10).
contract CoreVaultFinalVerifyRound1Test is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant STANDARD = ICoreVaultPayouts.PayoutMode.Standard;

    // ---------------------------------------------------------------------------------------------------------------
    // FV-OQ-1 / DEC-017 / DEC-020 / DEC-072: the bound is the share value at the request's price
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-072, DEC-017, DEC-020 (final verification, FV-OQ-1): at a Share Price above 1.00 the reserve is the
    /// holder's shares at that price, never the amount asked, and every unit of Free Idle above it stays
    /// allocatable. When the price falls before the claim, the claim burns the whole balance at the lower price and
    /// the part of the reserve above what it paid is released (DEC-072: `payoutReserve <= idle` throughout).
    function test_DEC072_reserveIsTheShareValueAtTheRequestPriceAndItsExcessIsReleasedWhenThePriceFalls() public {
        _deployFeeless();
        _deposit(alice, 1000e6); // 1,000 shares at 1.00
        _deposit(bob, 100e6); // 100 shares
        // Share Assets 1,211.10 over 1,101 shares (the manager's seed share included): 1.10
        hubVault.setPosition(address(usdc), 110.1e6);
        assertEq(vault.sharePrice(), 1.1e24);

        _request(bob, 1_000_000e6, STANDARD);
        assertEq(vault.payoutRequest(bob).reserved, 110e6, "100 shares at 1.10, not the amount asked");
        assertEq(vault.payoutReserve(), 110e6);
        assertEq(vault.freeIdle(), 991e6);
        // DEC-017: the manager keeps every unit of Free Idle above the bound.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 991e6 + 1, 991e6));
        vault.allocateToHubSpokeVault(991e6 + 1);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(991e6);
        assertEq(vault.freeIdle(), 0);
        assertLe(vault.payoutReserve(), vault.idle());

        // The hub position loses its value before the claim: the price is back at 1.00, the claim pays the 100
        // shares at 1.00 from the reserve and the 10 reserved above that are released.
        hubVault.setPosition(address(usdc), 0);
        assertEq(vault.sharePrice(), 1e24);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(bob);
        assertEq(r.sharePrice, 1e24);
        assertEq(r.sharesBurned, 100e18, "DEC-020: an insufficient balance burns everything");
        assertEq(r.usdcGross, 100e6);
        assertEq(r.unwindProceeds, 0, "the reserve paid, no unwind");
        assertFalse(r.closedBelowOneShare);
        assertFalse(vault.payoutRequest(bob).open);
        assertEq(vault.payoutReserve(), 0, "the 10 reserved above the claim's value are released");
        assertEq(vault.idle(), 10e6);
        assertEq(shares.balanceOf(bob), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-10 / DEC-021 / DEC-056: a request is priced like a claim, with the last known value on a failing read
    // ---------------------------------------------------------------------------------------------------------------

    /// OQ-10, DEC-021, DEC-056 (final verification): a request is priced like a claim, so a hub Spoke Vault whose
    /// report read fails does not block it: the bound uses the last known hub value with `HubValuationFallback`, a
    /// gain the failing read cannot see is not reserved against, and the request never reverts.
    function test_OQ10_requestUnderAHubValuationFailureIsBoundedByTheLastKnownValue() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        // Price 1.10 over 1,001 shares (the seed's included), seen by the next successful valuation.
        hubVault.setPosition(address(usdc), 100.1e6);
        _deposit(bob, 110e6); // 100 shares at 1.10; the last known hub value is now 100.10
        hubVault.setPosition(address(usdc), 300e6); // a gain the failing read will not see
        hubVault.setBuildReverts(true);

        vm.expectEmit(address(vault));
        emit ICoreVault.HubValuationFallback(100.1e6);
        _request(bob, 1_000_000e6, STANDARD);
        uint256 price = ShareMath.sharePrice(SEED_IDLE + 1110e6 + 100.1e6, SEED_SHARES + 1100e18);
        assertEq(price, 1.1e24);
        assertEq(vault.payoutRequest(bob).reserved, ShareMath.usdcFor(100e18, price), "priced with the last value");
        assertEq(vault.payoutRequest(bob).reserved, 110e6);
        assertEq(vault.payoutRequest(bob).usdcRequested, 1_000_000e6);
    }
}
