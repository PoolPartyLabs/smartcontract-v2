// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";

/// @notice DEC-146 (the base is half of the manager address's peak share balance) and DEC-147 item 1 (a manager request
///         crossing it reverts, telling the manager to close the fund; nothing closes automatically). D-27: the claim's
///         burn stops at the base, so the manager never holds less than half of the peak while the fund is Open.
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
        assertEq(
            uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Open), "DEC-147: nothing closes on its own"
        );
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

    // ---------------------------------------------------------------------------------------------------------------
    // D-27: the claim's burn stops at the base (DEC-147 consequence: never below half of the peak while Open)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Moves `amount` of Idle into the hub Spoke Vault's USDC position.
    function _intoHubPosition(uint256 amount) internal {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(amount);
        hubVault.moveToPosition(amount);
    }

    /// @dev Review round 1, PoC 1: a Standard request leaving exactly the base is accepted at 1.00; the hub position
    ///      then loses 40,000 (Share Price 0.80). At the claim 50,000 USDC would burn 62,500 shares and leave 37,500
    ///      against a base of 50,000; the burn stops at 50,000 shares (40,000 USDC) and the request closes.
    function test_D27_aPriceFallBeforeTheClaimStopsTheBurnAtTheBase() public {
        _fundSeededWith(100_000e6);
        _deposit(alice, 100_000e6);
        _intoHubPosition(100_000e6);
        _managerRequest(50_000e6, STANDARD);
        hubVault.setPosition(address(usdc), 60_000e6); // 160,000 over 200,000 shares
        assertEq(vault.sharePrice(), 0.8e24);
        vm.warp(block.timestamp + 72 hours);

        ICoreVault.PayoutReceipt memory r = _claim(manager);
        assertEq(r.sharesBurned, 50_000e18, "62,500 at 0.80, capped at the shares above the base");
        assertEq(r.usdcGross, 40_000e6);
        assertEq(r.usdcPaid, 40_000e6, "Standard, feeless fund");
        assertEq(shares.balanceOf(manager), 50_000e18, "exactly half of the peak");
        assertFalse(vault.payoutRequest(manager).open, "the capped request closes (DEC-024: never left hanging)");
        assertEq(vault.payoutReserve(), 0, "DEC-072: what is left of its reserve is released");
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Open));
        // From the base, even one share (0.80) more is refused (DEC-147 item 1).
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.ManagerMustCloseFund.selector, 100_000e18, 49_999e18)
        );
        vault.requestPayout(0.8e6, INSTANT);
    }

    /// @dev Review round 1, PoC 2: a sole-holder manager requests Instant 50,000 at 1.00 (accepted); the Share Price
    ///      falls to 0.40. Uncapped, the claim burned all 100,000 shares and left an Open fund with no shares, which
    ///      takes no deposit and can never be seeded again. Capped, it burns 50,000 (20,000 USDC, after an unwind of
    ///      the Idle shortfall) and the fund keeps taking deposits.
    function test_D27_aSoleHolderManagerNeverEmptiesAnOpenFund() public {
        _fundSeededWith(100_000e6);
        _intoHubPosition(90_000e6);
        _managerRequest(50_000e6, INSTANT);
        hubVault.setPosition(address(usdc), 30_000e6); // 40,000 over 100,000 shares
        assertEq(vault.sharePrice(), 0.4e24);

        ICoreVault.PayoutReceipt memory r = _claim(manager);
        assertEq(r.sharesBurned, 50_000e18);
        assertEq(r.usdcGross, 20_000e6);
        assertEq(r.payoutFee, 400e6, "DEC-075: 2% Instant Payout Fee, kept in Idle for the holders (DEC-144)");
        assertEq(shares.totalSupply(), 50_000e18, "DEC-147: a live fund always has shares");
        assertFalse(vault.payoutRequest(manager).open);

        (uint256 minted,) = _deposit(alice, 1000e6);
        assertGt(minted, 0, "DEC-121: the fund still takes deposits");
    }

    /// @dev The cap also bounds a Partial Payout's continuation: a Standard request whose unwind fails is paid in part
    ///      from its reserve (25,000 shares at 0.40), stays open, and the next claim stops at the base and closes it.
    function test_D27_aPartialPayoutThenTheCapClosesTheRequest() public {
        _fundSeededWith(100_000e6);
        _intoHubPosition(90_000e6);
        _managerRequest(50_000e6, STANDARD); // reserves the 10,000 of Free Idle
        hubVault.setPosition(address(usdc), 30_000e6); // 0.40
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        vm.warp(block.timestamp + 72 hours);

        ICoreVault.PayoutReceipt memory first = _claim(manager);
        assertEq(first.sharesBurned, 25_000e18, "DEC-068: what the reserve pays");
        assertEq(first.usdcGross, 10_000e6);
        assertTrue(vault.payoutRequest(manager).open);
        assertEq(vault.payoutRequest(manager).usdcOutstanding, 40_000e6);

        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Callback);
        ICoreVault.PayoutReceipt memory second = _claim(manager);
        assertEq(second.sharesBurned, 25_000e18, "100,000 wanted at 0.40, capped at the 25,000 above the base");
        assertEq(second.usdcGross, 10_000e6);
        assertEq(shares.balanceOf(manager), 50_000e18);
        assertFalse(vault.payoutRequest(manager).open, "closed with 30,000 of the request unpaid");
        assertEq(vault.payoutReserve(), 0);
    }

    /// @dev DEC-146, DEC-147, D-27, property: whatever the seed, the other capital, the share of the fund in a hub
    ///      position, the loss on it, the size and mode of the manager's request and whether the unwind fails, the
    ///      manager's balance never ends below `ceil(peak / 2)` and the supply never reaches 0 while the fund is Open.
    function testFuzz_D27_theManagerKeepsHalfThePeakWhateverThePriceDoes(
        uint256 seedAmount,
        uint256 otherAmount,
        uint256 allocatedBps,
        uint256 keptBps,
        uint256 requestBps,
        bool standard,
        bool unwindFails
    ) public {
        _fundSeededWith(bound(seedAmount, 1000e6, 10_000_000e6));
        otherAmount = bound(otherAmount, 0, 10_000_000e6);
        if (otherAmount >= 1e6) _deposit(alice, otherAmount);
        uint256 allocated = vault.idle() * bound(allocatedBps, 0, 10_000) / 10_000;
        if (allocated != 0) _intoHubPosition(allocated);

        // At 1.00 the largest request the base allows is the whole shares above it, in USDC.
        uint256 peak = vault.managerPeakShares();
        uint256 above = (shares.balanceOf(manager) - (peak - peak / 2)) / 1e18 * 1e6;
        uint256 amount = above * bound(requestBps, 1, 10_000) / 10_000;
        if (amount < 1e6) amount = 1e6;
        _managerRequest(amount, standard ? STANDARD : INSTANT);

        hubVault.setPosition(address(usdc), allocated * bound(keptBps, 0, 10_000) / 10_000);
        if (unwindFails) hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        vm.warp(block.timestamp + 72 hours);
        for (uint256 i; i < 3 && vault.payoutRequest(manager).open; ++i) {
            vm.prank(manager);
            try vault.claimPayout("") {}
            catch {
                break;
            }
            hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Callback);
        }

        assertGe(shares.balanceOf(manager), peak - peak / 2, "DEC-147: never below half of the peak while Open");
        assertGt(shares.totalSupply(), 0, "DEC-147: a live fund always has shares");
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
