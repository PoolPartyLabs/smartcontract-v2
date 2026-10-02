// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice DEC-146 (the base is half of the manager address's peak share balance) and DEC-147 item 1 (a manager request
///         crossing it reverts, telling the manager to close the fund; nothing closes automatically).
contract CoreVaultManagerBaseTest is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant INSTANT = ICoreVault.PayoutMode.Instant;
    ICoreVault.PayoutMode internal constant STANDARD = ICoreVault.PayoutMode.Standard;

    /// @dev A feeless fund seeded with the manager's `seed` USDC at 1.00, so shares equal USDC as in the register.
    function _fundSeededWith(uint256 seed) internal {
        _deployUnseeded(_mandate(2000), _config(0));
        _seedFundWith(address(vault), address(usdc), seed);
    }

    function _managerRequest(uint256 amount, ICoreVault.PayoutMode mode) internal {
        vm.prank(manager);
        vault.requestPayout(amount, mode);
    }

    /// @dev DEC-146 example: the manager creates the fund with 100,000 and adds 100,000; the peak is 200,000 shares.
    ///      A request of 120,000 would leave 80,000, below 100,000: refused. 90,000 leaves 110,000: accepted.
    function test_DEC146_registerExample() public {
        _fundSeededWith(100_000e6);
        assertEq(vault.managerPeakShares(), 100_000e18);
        _deposit(manager, 100_000e6);
        assertEq(vault.managerPeakShares(), 200_000e18, "DEC-146: the later capital counts in the peak");

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.ManagerMustCloseFund.selector, 200_000e18, 80_000e18)
        );
        vault.requestPayout(120_000e6, INSTANT);

        _managerRequest(90_000e6, INSTANT);
        assertTrue(vault.payoutRequest(manager).open);
    }

    /// @dev The base is reached exactly: a request leaving half the peak passes; one share more is refused.
    function test_DEC146_requestLeavingExactlyHalfThePeakPasses() public {
        _fundSeededWith(200_000e6);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.ManagerMustCloseFund.selector, 200_000e18, 99_999e18)
        );
        vault.requestPayout(100_001e6, STANDARD);
        _managerRequest(100_000e6, STANDARD);
    }

    /// @dev Standard and Instant alike (DEC-147 item 1 names the manager's request, whatever its mode).
    function test_DEC147_standardRequestCrossingTheBaseReverts() public {
        _fundSeededWith(100_000e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerMustCloseFund.selector, 100_000e18, 0));
        vault.requestPayout(1_000_000e6, STANDARD);
    }

    /// @dev An odd peak: half of 3 shares is 1.5, so the balance must stay at 2 whole shares.
    function test_DEC146_halfOfAnOddPeakRoundsUp() public {
        _fundSeededWith(3e6);
        assertEq(vault.managerPeakShares(), 3e18);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerMustCloseFund.selector, 3e18, 1e18));
        vault.requestPayout(2e6, INSTANT);
        _managerRequest(1e6, INSTANT);
    }

    /// @dev D-27: sized at the request's Share Price, the shares the request would burn rounded up. At 1.10 a request
    ///      of 55,000.01 would burn 50,000.009 shares: counted as 50,001, which crosses a base of 50,000 on 100,000.
    function test_DEC146_requestIsSizedAtTheSharePriceRoundingTheBurnUp() public {
        _fundSeededWith(100_000e6);
        hubVault.setPosition(address(usdc), 10_000e6); // Share Assets 110,000 over 100,000 shares: 1.10
        assertEq(vault.sharePrice(), 1.1e24);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.ManagerMustCloseFund.selector, 100_000e18, 49_999e18)
        );
        vault.requestPayout(55_000.01e6, INSTANT);
        _managerRequest(55_000e6, INSTANT); // exactly 50,000 shares
    }

    /// @dev The peak never goes down: after the manager's exit to the base, it stays; a smaller new deposit leaves it.
    function test_DEC146_peakNeverDecreases() public {
        _fundSeededWith(100_000e6);
        _deposit(alice, 50_000e6);
        _managerRequest(50_000e6, STANDARD); // no Payout Fee, so the Share Price stays at 1.00
        vm.warp(block.timestamp + 72 hours);
        vm.prank(manager);
        vault.claimPayout("");
        assertEq(shares.balanceOf(manager), 50_000e18);
        assertEq(vault.managerPeakShares(), 100_000e18, "the peak stays");

        _deposit(manager, 10_000e6);
        assertEq(vault.managerPeakShares(), 100_000e18, "60,000 is below the peak");
        _deposit(manager, 50_000e6);
        assertEq(vault.managerPeakShares(), 110_000e18, "the next high is the new peak");
    }

    /// @dev DEC-046, DEC-146: the base binds the manager address only; other holders exit in full.
    function test_DEC146_otherHoldersAreNotBound() public {
        _fundSeededWith(100_000e6);
        _deposit(alice, 50_000e6);
        assertEq(vault.managerPeakShares(), 100_000e18, "a deposit by someone else leaves the manager's peak");
        _request(alice, 50_000e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 50_000e18);
        assertEq(shares.balanceOf(alice), 0);
    }
}
