// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVaultIncome} from "../../../src/interfaces/ICoreVaultIncome.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice WP-07 B5, DEC-114 (with DEC-108, DEC-110, DEC-115; reading D-33): the management fee accrues linearly on
///         Share Assets net of what is already owed, at every valuation, as a liability outside Share Assets; a leaver
///         bears it through the Share Price, an entrant pays none of what accrued before it, a decrease books the old
///         rate first, and the accrual stops at `closeFund`. Payment at closure is WP-13.
/// @dev No flow fee and no performance fee, so Share Assets are exactly what was deposited: the seed's 1 USDC plus
///      Alice's 999,999, a fund of 1,000,000 at 1.00.
contract ManagementFeeTest is CoreVaultFixture {
    uint256 internal constant FUND = 1_000_000e6;
    uint256 internal constant YEAR = 365 days;

    function _fund(uint16 managementFeeBps) internal {
        Mandate memory m = _mandate(0);
        m.managementFeeBps = managementFeeBps;
        _deploy(m, _config(0));
        _deposit(alice, FUND - SEED_IDLE);
        assertEq(vault.shareAssets(), FUND);
    }

    /// @dev DEC-114's own example: 1,000,000 at 1% a year, three years, booked once: 30,000.
    function test_DEC114_onePercentOnAMillionForThreeYearsIsThirtyThousand() public {
        _fund(100);
        vm.warp(block.timestamp + 3 * YEAR);
        assertEq(vault.managementFeeAccrued(), 30_000e6, "the view adds the pending accrual");
        assertEq(vault.shareAssets(), FUND - 30_000e6, "outside Share Assets: the Share Price falls");
        assertEq(vault.grossAssets(), FUND, "still held by the fund until it is paid at closure");

        // The next valuation books it (a deposit: Q57 reading, the entrant prices after the accrual).
        usdc.mint(bob, 970e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 970e6);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.ManagementFeeAccrued(30_000e6, 30_000e6);
        vault.deposit(970e6, 0);
        vm.stopPrank();
        assertEq(vault.managementFeeAccrued(), 30_000e6);
        assertEq(vault.shareAssets(), FUND - 30_000e6 + 970e6);
    }

    /// @dev Reading D-33: the base is Share Assets net of the liability, so booked yearly the three years make
    ///      10,000 + 9,900 + 9,801 = 29,701 (the fee never charges itself).
    function test_D33_accrualBaseIsNetOfTheLiability() public {
        _fund(100);
        vm.startPrank(alice);
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + YEAR);
            vault.requestPayout(1e6, ICoreVaultPayouts.PayoutMode.Instant); // a valuation that books the fee
            vault.claimPayout("");
        }
        vm.stopPrank();
        // The three one-share exits paid out ~3 USDC of the base along the way: 29,701 within one unit of rounding.
        assertApproxEqAbs(vault.managementFeeAccrued(), 29_701e6, 1e6);
    }

    /// @dev DEC-114 item 3: a leaver before closure bears its share through the Share Price. After one year at 1%,
    ///      Alice leaves at 0.99 per share: 10,000 stays owed, outside what she is paid.
    function test_DEC114_leaverBearsTheFeeThroughTheSharePrice() public {
        _fund(100);
        vm.warp(block.timestamp + YEAR);
        uint256 aliceShares = shares.balanceOf(alice);
        vm.prank(alice);
        vault.requestPayout(FUND, ICoreVaultPayouts.PayoutMode.Instant);
        vm.prank(alice);
        ICoreVaultPayouts.PayoutReceipt memory r = vault.claimPayout("");

        assertEq(r.shareAssets, FUND - 10_000e6, "priced net of the liability");
        assertEq(r.sharePrice, ShareMath.sharePrice(FUND - 10_000e6, shares.totalSupply() + r.sharesBurned));
        assertEq(r.sharesBurned, aliceShares, "a full exit");
        assertEq(r.usdcGross, ShareMath.usdcFor(aliceShares, r.sharePrice));
        assertApproxEqAbs(r.usdcGross, 989_999.01e6, 1, "999,999 shares at 0.99");
        assertEq(vault.managementFeeAccrued(), 10_000e6);
        assertGe(vault.idle(), 10_000e6, "the liability is still held in Idle for the closure");
    }

    /// @dev Q57 reading, DEC-114: the deposit books the accrual before pricing, so an entrant pays none of the fee owed
    ///      for the time before it entered.
    function test_DEC114_entrantPaysNoneOfWhatAccruedBeforeIt() public {
        _fund(100);
        vm.warp(block.timestamp + YEAR);
        (uint256 minted,) = _deposit(bob, 99_000e6);
        uint256 bobValue = ShareMath.usdcFor(minted, vault.sharePrice());
        assertApproxEqAbs(bobValue, 99_000e6, 1e6, "Bob's shares are worth what he paid");
        assertEq(vault.managementFeeAccrued(), 10_000e6, "the year before Bob is the old holders' alone");
    }

    /// @dev DEC-110 ("settling what accrued first"): a lower management fee books the year at 1%, then applies 0.5%:
    ///      10,000, then 0.5% of 990,000 = 4,950.
    function test_DEC110_decreaseBooksTheOldRateFirst() public {
        _fund(100);
        vm.warp(block.timestamp + YEAR);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.ManagementFeeAccrued(10_000e6, 10_000e6);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.ManagerFeeDecreased(0, 0, 100, 50);
        vm.prank(manager);
        vault.decreaseManagerFee(0, 50);
        assertEq(vault.managementFeeBps(), 50);
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.managementFeeAccrued(), 10_000e6 + 4950e6);
    }

    /// @dev DEC-110: the management fee never rises, and a call that lowers nothing is refused.
    function test_DEC110_managementFeeNeverRises() public {
        _fund(100);
        vm.startPrank(manager);
        vm.expectRevert(ICoreVaultIncome.ManagerFeeNotDecreasing.selector);
        vault.decreaseManagerFee(0, 101);
        vm.expectRevert(ICoreVaultIncome.ManagerFeeNotDecreasing.selector);
        vault.decreaseManagerFee(0, 100);
        vault.decreaseManagerFee(0, 0);
        vm.stopPrank();
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.managementFeeAccrued(), 0, "a fee of 0 accrues nothing");
    }

    /// @dev DEC-114, DEC-147, reading D-33: `closeFund` books the accrual up to the call and the fee stops there.
    function test_DEC114_accrualStopsAtCloseFund() public {
        _fund(100);
        vm.warp(block.timestamp + YEAR);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.ManagementFeeAccrued(10_000e6, 10_000e6);
        vm.prank(manager);
        vault.closeFund();
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Closing));
        vm.warp(block.timestamp + 2 * YEAR);
        assertEq(vault.managementFeeAccrued(), 10_000e6, "nothing after the close");
        assertEq(vault.shareAssets(), FUND - 10_000e6);
    }

    /// @dev DEC-108: the default is 0, and such a fund owes nothing however long it lives.
    function test_DEC108_zeroFeeOwesNothing() public {
        _fund(0);
        vm.warp(block.timestamp + 10 * YEAR);
        assertEq(vault.managementFeeAccrued(), 0);
        assertEq(vault.shareAssets(), FUND);
        _deposit(bob, 1000e6);
        assertEq(vault.managementFeeAccrued(), 0);
    }

    /// @dev The cap (DEC-115): 5% a year, 50,000 on the million after one year.
    function test_DEC115_atTheCapFivePercentAYear() public {
        _fund(500);
        vm.warp(block.timestamp + YEAR);
        assertEq(vault.managementFeeAccrued(), 50_000e6);
        assertEq(vault.sharePrice(), ShareMath.sharePrice(FUND - 50_000e6, shares.totalSupply()));
    }

    /// @dev An accrual never takes more than the fund holds: a fund left without a valuation for a century at 5% owes
    ///      the whole fund, not five times it; Share Assets floor at 0 while Gross Assets still count what is held.
    function test_D33_accrualNeverTakesMoreThanTheFund() public {
        _fund(500);
        vm.warp(block.timestamp + 100 * YEAR);
        assertEq(vault.managementFeeAccrued(), FUND);
        assertEq(vault.shareAssets(), 0);
        assertEq(vault.grossAssets(), FUND);
    }
}
