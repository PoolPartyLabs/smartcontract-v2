// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultIncome} from "../../../src/interfaces/ICoreVaultIncome.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Every fund is seeded at creation (DEC-127, CoreVaultFixture): the manager's one share and its 1 USDC of Idle
///      are part of the numbers below.
contract CoreVaultPayoutTest is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant INSTANT = ICoreVaultPayouts.PayoutMode.Instant;
    ICoreVault.PayoutMode internal constant STANDARD = ICoreVaultPayouts.PayoutMode.Standard;

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
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutRequestAlreadyOpen.selector, alice));
        vault.requestPayout(50e6, STANDARD);
    }

    function test_DEC077_requestLocksAndBurnsNothing() public {
        _deposit(alice, 1000e6);
        uint256 before = shares.balanceOf(alice);
        _request(alice, 500e6, STANDARD);
        assertEq(shares.balanceOf(alice), before);
        assertEq(shares.totalSupply(), SEED_SHARES + before);
    }

    function test_DEC024_requestWithoutSharesReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.NoShares.selector, alice));
        vault.requestPayout(1e6, INSTANT);
    }

    function test_DEC072_standardReservesMinOfAmountAndFreeIdle() public {
        _deposit(alice, 1000e6); // Idle 997 plus the seed's 1 after the flow fee
        _request(alice, 2000e6, STANDARD);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertEq(req.reserved, 997e6, "bounded by alice's share value (FV-OQ-1)");
        assertEq(vault.payoutReserve(), 997e6);
        assertEq(vault.freeIdle(), SEED_IDLE);
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
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 100e6, 97e6 + SEED_IDLE));
        vault.allocateToHubSpokeVault(100e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Claims
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC065_claimWithoutOpenRequestReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.NoOpenPayoutRequest.selector, alice));
        vault.claimPayout("");
    }

    function test_OQ07_standardClaimBeforeTermReverts() public {
        _deposit(alice, 1000e6);
        _request(alice, 100e6, STANDARD);
        uint64 ends = uint64(block.timestamp + 72 hours);
        vm.warp(ends - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutTermNotEnded.selector, ends));
        vault.claimPayout("");
    }

    function test_DEC077_workedExample1000At11Burns909Pays99990() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.setPosition(address(usdc), 100.1e6); // 1,101.10 over 1,001 shares (the seed's included)
        assertEq(vault.sharePrice(), 1.1e24);
        _request(alice, 1000e6, STANDARD);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 909e18);
        assertEq(r.usdcGross, 999.9e6);
        assertEq(r.usdcPaid, 999.9e6);
        assertEq(r.usdcOutstanding, 0);
        assertEq(r.sharePrice, 1.1e24);
        assertEq(r.shareAssets, 1101.1e6);
        assertEq(r.totalShares, SEED_SHARES + 1000e18);
        assertEq(usdc.balanceOf(alice), 999.9e6);
        assertEq(shares.balanceOf(alice), 91e18);
        assertFalse(vault.payoutRequest(alice).open);
        assertEq(vault.payoutReserve(), 0, "leftover reserve released");
        assertEq(vault.idle(), SEED_IDLE + 0.1e6);
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

    /// @dev DEC-144 (corrects DEC-102 items 2-4): the Payout Fee stays in Idle, never in Operating Cash.
    function test_DEC144_instantWorkedExample30000() public {
        uint256 protocolBefore = usdc.balanceOf(protocol); // the seed's flow fee
        _deposit(alice, 40_000e6);
        _request(alice, 30_000e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.usdcGross, 30_000e6);
        assertEq(r.payoutFee, 600e6, "2% Payout Fee");
        assertEq(r.flowFee, 75e6, "25 bps flow fee on the amount paid out (LC-143 reading)");
        assertEq(r.usdcPaid, 29_325e6);
        assertEq(vault.operatingCash(), 0, "the Payout Fee never enters Operating Cash");
        assertEq(vault.idle(), SEED_IDLE + 39_900e6 - 30_000e6 + 600e6, "Idle drops by usdcGross - payoutFee");
        assertEq(usdc.balanceOf(protocol) - protocolBefore, 100e6 + 75e6);
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
        _request(bob, 2000e6, STANDARD); // reserves bob's 997 shares at 1.00 (FV-OQ-1 bound)
        assertEq(vault.payoutReserve(), 997e6);
        uint256 free = vault.freeIdle();
        vm.prank(manager);
        vault.allocateToHubSpokeVault(free); // the rest of Idle leaves, Free Idle is 0
        assertEq(vault.freeIdle(), 0);
        _request(alice, 500e6, INSTANT);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 500e6, 0));
        vault.claimPayout("");
        assertEq(vault.payoutReserve(), 997e6);
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
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        _request(alice, 800e6, INSTANT);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(hubVault.lastUnwindTarget(), 408e6, "400 shortfall + 2%");
        assertEq(r.unwindProceeds, 408e6);
        assertEq(r.sharesBurned, 800e18);
        assertEq(r.usdcGross, 800e6);
        assertEq(r.sharePrice, ONE, "DEC-105: one price after the unwind");
        // payoutSettlementPrice = 408 / 800 shares, same scale as Share Price; recorded only (DEC-084, DEC-105).
        assertEq(r.payoutSettlementPrice, 0.51e24);
        assertEq(vault.idle(), 8e6 + r.payoutFee, "the 8 left plus the 16 Payout Fee (DEC-144)");
    }

    function test_DEC080_unwindCreditsOnlyWhatReturnToIdleCredited() public {
        _deployFeeless();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.OverReports);
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
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
        _allocateToPosition(1600e6 + SEED_IDLE); // Idle 400 left, as before the seed
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
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        _request(alice, 800e6, INSTANT);
        vm.expectEmit(address(vault));
        emit ICoreVaultPayouts.UnwindForPayoutFailed(408e6);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 400e18);
        assertEq(r.usdcGross, 400e6);
        assertEq(r.usdcOutstanding, 400e6);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertTrue(req.open);
        assertEq(req.usdcOutstanding, 400e6);
        // Once the unwind works again, the next claim unwinds the rest and closes the request. DEC-144: the first
        // claim's Payout Fee stayed in Idle and raised the Share Price, so the 400 outstanding burn fewer shares.
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Callback);
        r = _claim(alice);
        assertGt(r.sharePrice, ONE);
        assertEq(r.sharesBurned, ShareMath.sharesToBurn(400e6, r.sharePrice));
        assertEq(r.usdcGross, ShareMath.usdcFor(r.sharesBurned, r.sharePrice));
        assertLe(r.usdcGross, 400e6);
        assertEq(r.usdcOutstanding, 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_DEC068_partialPayoutEmitsPartialEvent() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _request(alice, 800e6, INSTANT);
        vm.recordLogs();
        _claim(alice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool partialSeen;
        bool fullSeen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == ICoreVaultPayouts.PartialPayoutExecuted.selector) partialSeen = true;
            if (logs[i].topics[0] == ICoreVaultPayouts.PayoutExecuted.selector) fullSeen = true;
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
        hubVault.forwardIncome(address(usdc), 200.1e6); // 0.10 per share over 2,001 shares (the seed's included)
        _request(alice, 1000e6, INSTANT);
        uint256 owed = vault.attributedIncome(alice, address(usdc));
        assertApproxEqAbs(owed, 100e6, 1);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeWithdrawn(alice, address(usdc), owed);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 1000e18);
        // 1,000 gross minus 2% Payout Fee plus the income, in the same transaction.
        assertEq(usdc.balanceOf(alice), 980e6 + owed);
        assertEq(vault.attributedIncome(alice, address(usdc)), 0);
    }

    /// Independent review (verification plan CF-2; DEC-021, DEC-045): an income token that refuses the transfer to the
    /// holder (paused, blocklisting it) used to revert the full-burn claim and with it the exit of the principal. The
    /// claim now completes; that token's income is owed to the holder and paid by the permissionless claimOwedFees.
    function test_REVIEW_CF2_incomeTokenThatRefusesTheHolderNeverBlocksTheExit() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        hubVault.forwardIncome(address(usdc), 200.1e6); // per share over 2,001 shares (the seed's included)
        hubVault.forwardIncome(address(weth), 0.50025e18);
        _request(alice, 1000e6, INSTANT);
        uint256 owedUsdc = vault.attributedIncome(alice, address(usdc));
        uint256 owedWeth = vault.attributedIncome(alice, address(weth));
        assertApproxEqAbs(owedWeth, 0.25e18, 1);

        // WETH refuses every transfer to alice (a pause or a blocklist entry of the token's issuer).
        vm.mockCallRevert(address(weth), abi.encodeWithSignature("transfer(address,uint256)", alice), "paused");
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.FeeAccrued(address(weth), alice, owedWeth);
        ICoreVault.PayoutReceipt memory r = _claim(alice);

        assertEq(r.sharesBurned, 1000e18, "the exit completed");
        assertEq(usdc.balanceOf(alice), 980e6 + owedUsdc, "principal and USDC income paid");
        assertEq(weth.balanceOf(alice), 0, "the refused token was not paid");
        assertEq(vault.owedFees(address(weth), alice), owedWeth, "and is owed to the holder");
        assertEq(vault.attributedIncome(alice, address(weth)), 0);

        // Once the token transfers again, anyone pays it to the holder.
        vm.clearMockedCalls();
        vm.prank(bob);
        vault.claimOwedFees(address(weth), alice);
        assertEq(weth.balanceOf(alice), owedWeth);
        assertEq(vault.owedFees(address(weth), alice), 0);
    }

    function test_DEC045_partialBurnKeepsIncomeAttributed() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.forwardIncome(address(usdc), 100.1e6); // 0.10 per share over 1,001 shares (the seed's included)
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
        assertEq(r.shareAssets, SEED_IDLE + 997e6 + 10e6);
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

    /// @dev DEC-035 spirit, DEC-077 (final verification): a request that could never burn a share is refused.
    function test_DEC035_requestBelowOneSharePriceReverts() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.setPosition(address(usdc), 100.1e6); // price 1.1 over 1,001 shares (the seed's included)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutBelowOneShare.selector, 1e6, 1.1e24));
        vault.requestPayout(1e6, INSTANT);
        _request(alice, 1.1e6, STANDARD); // exactly one share is accepted
        assertEq(vault.payoutRequest(alice).reserved, 1.1e6);
    }

    /// @dev DEC-077 (final verification): an outstanding amount below one share's price at the claim closes the
    ///      request with nothing burned, visibly (`closedBelowOneShare`), and releases its reserve (DEC-072).
    function test_DEC077_outstandingBelowOneShareClosesWithoutBurn() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        _request(alice, 1e6, STANDARD); // one share at 1.00
        assertEq(vault.payoutReserve(), 1e6);
        hubVault.setPosition(address(usdc), 100e6); // price 1.1: the request is now below one share's price
        vm.warp(block.timestamp + 72 hours);
        vm.recordLogs();
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 0);
        assertEq(r.usdcPaid, 0);
        assertTrue(r.closedBelowOneShare, "a zero-share close is explicit");
        assertFalse(vault.payoutRequest(alice).open);
        assertEq(vault.payoutReserve(), 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] != ICoreVaultPayouts.PayoutExecuted.selector) continue;
            (ICoreVault.PayoutReceipt memory emitted,) =
                abi.decode(logs[i].data, (ICoreVaultPayouts.PayoutReceipt, ICoreVaultPayouts.NavConsolidation));
            assertTrue(emitted.closedBelowOneShare);
            found = true;
        }
        assertTrue(found, "PayoutExecuted carries the reason");
    }

    function testFuzz_DEC077_payoutNeverExceedsRequest(uint256 amount, uint256 gain, bool standard) public {
        amount = bound(amount, 2e6, 50_000e6); // price stays below 1.5, so every amount buys a share (DEC-035)
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
        assertFalse(r.closedBelowOneShare);
        assertLe(vault.payoutReserve(), vault.idle());
        // Rounding is down: one more share would exceed the request unless all shares were burned.
        if (r.sharesBurned < balanceBefore) assertGe(ShareMath.usdcFor(r.sharesBurned + 1e18, r.sharePrice), amount);
    }
}
