// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {Vm} from "forge-std/Vm.sol";

contract CoreVaultPayoutTest is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant INSTANT = ICoreVault.PayoutMode.Instant;
    ICoreVault.PayoutMode internal constant STANDARD = ICoreVault.PayoutMode.Standard;

    /// @dev Moves `amount` of Idle into a hub USDC position the hub Spoke Vault can unwind.
    function _allocateToPosition(uint256 amount) internal {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(amount);
        hubVault.moveToPosition(amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Requests
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC024_oneOpenRequestPerAddress() public {
        _deposit(alice, 1000e6);
        _request(alice, 100e6, INSTANT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.PayoutRequestAlreadyOpen.selector, alice));
        vault.requestPayout(50e6, STANDARD);
    }

    function test_DEC077_requestLocksAndBurnsNothing() public {
        _deposit(alice, 1000e6);
        uint256 before = shares.balanceOf(alice);
        _request(alice, 500e6, STANDARD);
        assertEq(shares.balanceOf(alice), before);
        assertEq(shares.totalSupply(), before);
    }

    function test_DEC024_requestWithoutSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoShares.selector, alice));
        vault.requestPayout(1e6, INSTANT);
    }

    function test_DEC072_standardReservesMinOfAmountAndFreeIdle() public {
        _deposit(alice, 1000e6); // Idle 997.5 after the flow fee
        _request(alice, 2000e6, STANDARD);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertEq(req.reserved, 997e6);
        assertEq(vault.payoutReserve(), 997e6);
        assertEq(vault.freeIdle(), 0);
        assertEq(req.termEndsAt, block.timestamp + 72 hours);
        assertLe(vault.payoutReserve(), vault.idle());
    }

    function test_DEC095_instantReservesNothing() public {
        _deposit(alice, 1000e6);
        _request(alice, 500e6, INSTANT);
        assertEq(vault.payoutRequest(alice).reserved, 0);
        assertEq(vault.payoutReserve(), 0);
    }

    function test_DEC072_managerCannotAllocateThePayoutReserve() public {
        _deposit(alice, 1000e6);
        _request(alice, 900e6, STANDARD);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 100e6, 97e6));
        vault.allocateToHubSpokeVault(100e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC065_claimWithoutOpenRequestReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoOpenPayoutRequest.selector, alice));
        vault.claimPayout("");
    }

    function test_OQ07_standardClaimBeforeTermReverts() public {
        _deposit(alice, 1000e6);
        _request(alice, 100e6, STANDARD);
        uint64 ends = uint64(block.timestamp + 72 hours);
        vm.warp(ends - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.PayoutTermNotEnded.selector, ends));
        vault.claimPayout("");
    }

    function test_DEC077_workedExample1000At11Burns909Pays99990() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.setPosition(address(usdc), 100e6);
        assertEq(vault.sharePrice(), 1.1e24);
        _request(alice, 1000e6, STANDARD);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 909e18);
        assertEq(r.usdcGross, 999.9e6);
        assertEq(r.usdcPaid, 999.9e6);
        assertEq(r.usdcOutstanding, 0);
        assertEq(r.sharePrice, 1.1e24);
        assertEq(r.shareAssets, 1100e6);
        assertEq(r.totalShares, 1000e18);
        assertEq(usdc.balanceOf(alice), 999.9e6);
        assertEq(shares.balanceOf(alice), 91e18);
        assertFalse(vault.payoutRequest(alice).open);
        assertEq(vault.payoutReserve(), 0, "leftover reserve released");
        assertEq(vault.idle(), 0.1e6);
    }

    function test_DEC067_idlePaysWholeRequestWithoutUnwind() public {
        _deposit(alice, 10_000e6);
        _allocateToPosition(1000e6);
        _request(alice, 5000e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(hubVault.lastUnwindTarget(), 0, "nothing unwound");
        assertEq(r.unwindProceeds, 0);
        assertEq(r.payoutSettlementPrice, 0);
        assertEq(r.sharesBurned, 5000e18);
    }

    function test_DEC102_instantWorkedExample30000() public {
        _deposit(alice, 40_000e6);
        _request(alice, 30_000e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.usdcGross, 30_000e6);
        assertEq(r.payoutFee, 600e6, "2% Payout Fee");
        assertEq(r.flowFee, 75e6, "25 bps flow fee on the amount paid out (LC-143 reading)");
        assertEq(r.usdcPaid, 29_325e6);
        assertEq(vault.operatingCash(), 600e6, "Payout Fee whole to Operating Cash");
        assertEq(usdc.balanceOf(protocol), 100e6 + 75e6);
        assertEq(usdc.balanceOf(alice), 29_325e6);
    }

    function test_DEC075_standardPaysNoPayoutFee() public {
        _deposit(alice, 10_000e6);
        _request(alice, 1000e6, STANDARD);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.payoutFee, 0);
        assertEq(r.flowFee, 2.5e6);
        assertEq(vault.operatingCash(), 0);
    }

    function test_DEC095_instantNeverTouchesThePayoutReserve() public {
        _deposit(bob, 1000e6);
        _deposit(alice, 1000e6);
        _request(bob, 2000e6, STANDARD); // reserves all 1,995 of Idle
        assertEq(vault.freeIdle(), 0);
        _request(alice, 500e6, INSTANT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 500e6, 0));
        vault.claimPayout("");
        assertEq(vault.payoutReserve(), 1994e6);
    }

    function test_DEC095_standardUsesItsReserveThenFreeIdle() public {
        _deposit(alice, 1000e6);
        _request(alice, 500e6, STANDARD);
        _deposit(bob, 1000e6); // more Free Idle after the reservation
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.usdcGross, 500e6);
        assertEq(vault.payoutReserve(), 0);
    }

    function test_DEC081_unwindsShortfallPlusTwoPercentCallback() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6);
        _request(alice, 800e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(hubVault.lastUnwindTarget(), 408e6, "400 shortfall + 2%");
        assertEq(r.unwindProceeds, 408e6);
        assertEq(r.sharesBurned, 800e18);
        assertEq(r.usdcGross, 800e6);
        assertEq(r.sharePrice, ONE, "DEC-105: one price after the unwind");
        // payoutSettlementPrice = 408 / 800 shares, same scale as Share Price; recorded only (DEC-084, DEC-105).
        assertEq(r.payoutSettlementPrice, 0.51e24);
        assertEq(vault.idle(), 8e6);
    }

    function test_DEC080_unwindCreditsOnlyWhatReturnToIdleCredited() public {
        _deployFeeless();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.OverReports);
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6);
        _request(alice, 800e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        // The hub Spoke Vault transferred 408 without `returnToIdle` and reported twice that: nothing reaches Idle
        // (DEC-080: no balance-derived credit), the claim is a Partial Payout of the Idle it had (DEC-068) and the
        // 408 stay above the ledger for the garbage collector.
        assertEq(r.unwindProceeds, 0);
        assertEq(r.usdcGross, 400e6);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc() + 408e6);
        assertEq(vault.sweepExcess(address(usdc)), 408e6);
    }

    function test_DEC097_fundBearsUnwindMarketCost() public {
        _deployFeeless();
        hubVault.setUnwindLossBps(100);
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        _allocateToPosition(1600e6);
        _request(alice, 800e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        // 408 unwound at 1% loss: 403.92 reach Idle; the price after the unwind carries the loss for everyone.
        assertEq(r.unwindProceeds, 403.92e6);
        assertLt(r.sharePrice, ONE);
        assertEq(r.sharesBurned, ShareMath.sharesToBurn(800e6, r.sharePrice));
        assertLe(r.usdcGross, 800e6, "never more than requested");
    }

    function test_DEC068_partialPayoutLeavesRemainderOpen() public {
        _deployFeeless();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6);
        _request(alice, 800e6, INSTANT);
        vm.expectEmit(address(vault));
        emit ICoreVault.UnwindForPayoutFailed(408e6);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 400e18);
        assertEq(r.usdcGross, 400e6);
        assertEq(r.usdcOutstanding, 400e6);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertTrue(req.open);
        assertEq(req.usdcOutstanding, 400e6);
        // Once the unwind works again, the next claim unwinds the rest and closes the request.
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Callback);
        r = _claim(alice);
        assertEq(r.usdcGross, 400e6);
        assertEq(r.usdcOutstanding, 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_DEC068_partialPayoutEmitsPartialEvent() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6);
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _request(alice, 800e6, INSTANT);
        vm.recordLogs();
        _claim(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool partialSeen;
        bool fullSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICoreVault.PartialPayoutExecuted.selector) partialSeen = true;
            if (logs[i].topics[0] == ICoreVault.PayoutExecuted.selector) fullSeen = true;
        }
        assertTrue(partialSeen);
        assertFalse(fullSeen);
    }

    function test_DEC020_insufficientSharesBurnAllAndClose() public {
        _deployFeeless();
        _deposit(alice, 100e6);
        _deposit(bob, 1000e6);
        _request(alice, 500e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 100e18);
        assertEq(r.usdcGross, 100e6);
        assertEq(r.usdcOutstanding, 0);
        assertEq(shares.balanceOf(alice), 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_DEC045_fullBurnPaysAttributedIncomeInSameTransaction() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        hubVault.forwardIncome(address(usdc), 200e6);
        _request(alice, 1000e6, INSTANT);
        uint256 owed = vault.attributedIncome(alice, address(usdc));
        assertApproxEqAbs(owed, 100e6, 1);
        vm.expectEmit(address(vault));
        emit ICoreVault.IncomeWithdrawn(alice, address(usdc), owed);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 1000e18);
        // 1,000 gross minus 2% Payout Fee plus the income, in the same transaction.
        assertEq(usdc.balanceOf(alice), 980e6 + owed);
        assertEq(vault.attributedIncome(alice, address(usdc)), 0);
    }

    function test_DEC045_partialBurnKeepsIncomeAttributed() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.forwardIncome(address(usdc), 100e6);
        _request(alice, 500e6, INSTANT);
        _claim(alice);
        assertEq(usdc.balanceOf(alice), 490e6);
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), 100e6, 1);
    }

    function test_Q57_idlePaidPayoutIgnoresStaleReportAndPrice() public {
        _deposit(alice, 1000e6);
        _deliver(_spokeReport(10e6, 0));
        prices.setPriceAt(address(usdg), 1e18, block.timestamp - 3 hours);
        vm.warp(block.timestamp + MAX_REPORT_AGE + 10);
        _request(alice, 100e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        // The last report (10 USDG past its lifetime) and the old price still count; nothing reverts on age.
        assertEq(r.shareAssets, 997e6 + 10e6);
        assertEq(r.sharesBurned, ShareMath.sharesToBurn(100e6, r.sharePrice));
        assertGt(r.usdcPaid, 0);
    }

    function test_DEC047_burnAndPayAtomic() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _request(alice, 300e6, INSTANT);
        uint256 supplyBefore = shares.totalSupply();
        uint256 balanceBefore = usdc.balanceOf(alice);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(supplyBefore - shares.totalSupply(), r.sharesBurned);
        assertEq(usdc.balanceOf(alice) - balanceBefore, r.usdcPaid);
    }

    function test_DEC077_outstandingBelowOneShareClosesWithoutBurn() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.setPosition(address(usdc), 100e6); // price 1.1
        _request(alice, 1e6, INSTANT); // below one share's price
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 0);
        assertEq(r.usdcPaid, 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function testFuzz_DEC077_payoutNeverExceedsRequest(uint256 amount, uint256 gain, bool standard) public {
        amount = bound(amount, 1e6, 50_000e6);
        gain = bound(gain, 0, 20_000e6);
        _deposit(alice, 20_000e6);
        _deposit(bob, 20_000e6);
        hubVault.setPosition(address(usdc), gain);
        _request(alice, amount, standard ? STANDARD : INSTANT);
        if (standard) vm.warp(block.timestamp + 72 hours);
        uint256 balanceBefore = shares.balanceOf(alice);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertLe(r.usdcGross, amount);
        assertEq(r.sharesBurned % 1e18, 0);
        assertLe(r.sharesBurned, balanceBefore);
        assertEq(r.usdcPaid + r.payoutFee + r.flowFee, r.usdcGross);
        assertLe(vault.payoutReserve(), vault.idle());
        // Rounding is down: one more share would exceed the request unless all shares were burned.
        if (r.sharesBurned < balanceBefore) assertGe(ShareMath.usdcFor(r.sharesBurned + 1e18, r.sharePrice), amount);
    }
}
