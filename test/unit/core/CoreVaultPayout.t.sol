// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

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
        _request(alice, 100e6, STANDARD);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutRequestAlreadyOpen.selector, alice));
        vault.requestPayout(50e6, INSTANT, 0);
    }

    /// @dev DEC-120 item 1, D-51: an Instant request is its own claim; once paid there is nothing left to claim.
    function test_DEC120_instantRequestIsItsOwnClaim() public {
        _deposit(alice, 1000e6);
        uint256 before = usdc.balanceOf(alice);
        ICoreVault.PayoutReceipt memory r = _request(alice, 100e6, INSTANT);
        assertEq(r.sharesBurned, 100e18);
        assertEq(usdc.balanceOf(alice) - before, r.usdcPaid);
        assertEq(r.requestId, _requestId(alice, 1));
        assertFalse(vault.payoutRequest(alice).open, "paid and closed in the request's transaction");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.NoOpenPayoutRequest.selector, alice));
        vault.claimPayout(0);
    }

    /// @dev A Standard request returns an empty receipt and keeps its id and maximum loss (DEC-140); the claim may
    ///      replace the maximum (DEC-148).
    function test_DEC140_requestKeepsItsIdAndMaximumLoss() public {
        _deposit(alice, 1000e6);
        vm.expectEmit(address(vault));
        emit ICoreVaultPayouts.PayoutRequested(
            alice, STANDARD, _requestId(alice, 1), 100e6, 100e6, uint64(block.timestamp + 72 hours), 150
        );
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory r = vault.requestPayout(100e6, STANDARD, 150);
        assertEq(r.sharesBurned, 0);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertEq(req.requestId, _requestId(alice, 1));
        assertEq(req.maxLossBps, 150);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        r = vault.claimPayout(300);
        assertEq(r.requestId, _requestId(alice, 1));
        assertEq(vault.payoutRequest(alice).maxLossBps, 300);
        assertFalse(vault.payoutRequest(alice).open);
        _deposit(bob, 1000e6);
        _request(bob, 100e6, STANDARD);
        assertEq(vault.payoutRequest(bob).requestId, _requestId(bob, 2), "the counter is fund-wide");
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
        vault.requestPayout(1e6, INSTANT, 0);
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
        _allocateToPosition(900e6); // Idle covers only part, so the request stays open after a Partial Payout
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _request(alice, 500e6, INSTANT);
        assertTrue(vault.payoutRequest(alice).open);
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
        vault.claimPayout(0);
    }

    function test_OQ07_standardClaimBeforeTermReverts() public {
        _deposit(alice, 1000e6);
        _request(alice, 100e6, STANDARD);
        uint64 ends = uint64(block.timestamp + 72 hours);
        vm.warp(ends - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutTermNotEnded.selector, ends));
        vault.claimPayout(0);
    }

    function test_DEC077_workedExample1000At11Burns909Pays99990() public {
        _deployAtMinimumFees();
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
        ICoreVault.PayoutReceipt memory r = _request(alice, 5000e6, INSTANT);
        assertEq(hubVault.unwindCalls(), 0, "nothing unwound");
        assertEq(r.unwindProceeds, 0);
        assertEq(r.payoutSettlementPrice, 0);
        assertEq(r.sharesBurned, 5000e18);
    }

    /// @dev DEC-144 (corrects DEC-102 items 2-4): the Payout Fee stays in Idle, never in Operating Cash.
    function test_DEC144_instantWorkedExample30000() public {
        uint256 protocolBefore = usdc.balanceOf(protocol); // the seed's flow fee
        _deposit(alice, 40_000e6);
        ICoreVault.PayoutReceipt memory r = _request(alice, 30_000e6, INSTANT);
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
        hubVault.moveToPosition(free); // into a position whose unwind fails
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        assertEq(vault.freeIdle(), 0);
        // DEC-148/151: no progress keeps the request and its fraction without touching another request's reserve.
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory receipt = vault.requestPayout(500e6, INSTANT, 0);
        assertEq(receipt.sharesBurned, 0);
        assertEq(receipt.usdcOutstanding, 500e6);
        assertTrue(vault.payoutRequest(alice).open);
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

    /// @dev DEC-137, D-11: Idle 400 of an 800 request, so 400 of the 1,001 - 400 shares not covered by Idle are
    ///      missing: every position gives 400 / 601 x 1.02 (the mock's one position of 601 gives 408), computed from
    ///      shares and stored in the request; DEC-105: one Share Price after the unwind.
    function test_DEC137_fractionFromSharesAndOnePriceAfterTheUnwind() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        ICoreVault.PayoutReceipt memory r = _request(alice, 800e6, INSTANT);
        (bytes32 requestId, uint256 fracNum, uint256 fracDen,,) = hubVault.lastRequest();
        assertEq(requestId, r.requestId);
        assertEq(fracNum, 400e18 * 10_200, "(S - A/P) x (10,000 + 200)");
        assertEq(fracDen, 601e18 * 10_000, "(T - A/P) x 10,000");
        assertEq(r.fracNum, fracNum);
        assertEq(r.fracDen, fracDen);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertEq(req.fracNum, fracNum, "DEC-151: the fraction is kept in the request");
        assertEq(req.attempt, 1);
        assertEq(r.unwindProceeds, 408e6);
        assertEq(r.sharesBurned, 800e18);
        assertEq(r.usdcGross, 800e6);
        assertEq(r.sharePrice, ONE, "DEC-105: one price after the unwind");
        assertEq(r.marketCost, 0);
        // payoutSettlementPrice = 408 / 800 shares, same scale as Share Price; recorded only (DEC-084, DEC-105).
        assertEq(r.payoutSettlementPrice, 0.51e24);
        assertEq(vault.idle(), 8e6 + r.payoutFee, "the 8 left plus the 16 Payout Fee (DEC-144)");
    }

    /// @dev D-11: the hub Spoke Vault's Unallocated USDC counts as available and is paid into Idle first; when it and
    ///      Idle cover the request no position is touched (fraction 0, DEC-067).
    function test_D11_hubUnallocatedUsdcPaysBeforeAnyPosition() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(600e6); // Unallocated in the hub Spoke Vault, no position
        hubVault.setPosition(address(usdc), 0);
        ICoreVault.PayoutReceipt memory r = _request(alice, 800e6, INSTANT);
        (, uint256 fracNum,,,) = hubVault.lastRequest();
        assertEq(fracNum, 0, "no position needed");
        assertEq(r.fracNum, 0);
        assertEq(r.unwindProceeds, 600e6, "all of the hub's USDC moved to Idle");
        assertEq(r.usdcOutstanding, 0);
        assertEq(hubVault.unallocatedUsdc(), 0);
    }

    function test_DEC080_unwindCreditsOnlyWhatReturnToIdleCredited() public {
        _deployAtMinimumFees();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.OverReports);
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        ICoreVault.PayoutReceipt memory r = _request(alice, 800e6, INSTANT);
        // The hub Spoke Vault transferred 408 without `returnToIdle` and reported twice that: nothing reaches Idle
        // (DEC-080: no balance-derived credit), the claim is a Partial Payout of the Idle it had (DEC-068) at the price
        // read after the unwind (DEC-105: the 408 left the position and count nowhere) and the 408 stay above the
        // ledger for the garbage collector.
        assertEq(r.unwindProceeds, 0);
        assertEq(r.sharePrice, ShareMath.sharePrice(1001e6 - 408e6, 1001e18));
        assertEq(r.usdcGross, ShareMath.usdcFor(ShareMath.sharesToBurn(400e6, r.sharePrice), r.sharePrice));
        assertLe(r.usdcGross, 400e6);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc() + 408e6);
        assertEq(vault.sweepExcess(address(usdc)), 408e6);
    }

    /// @dev DEC-118: an Instant requester bears the unwind's Market Cost. 408 unwound at 1%: 403.92 reach Idle; the
    ///      burn price adds the 4.08 back (D-17), so it stays 1.00 and the requester pays the 4.08 once, from the gross.
    function test_DEC118_instantRequesterBearsTheUnwindMarketCost() public {
        _deployAtMinimumFees();
        hubVault.setUnwindLossBps(100);
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        _allocateToPosition(1600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        uint256 bobValue = vault.sharePrice() * shares.balanceOf(bob);
        ICoreVault.PayoutReceipt memory r = _request(alice, 800e6, INSTANT);
        assertEq(r.unwindProceeds, 403.92e6);
        assertEq(r.marketCost, 4.08e6);
        assertEq(r.leaverCost, 4.08e6, "Instant: all of it");
        assertEq(r.marketCostAbsorbed, 0);
        assertEq(r.sharePrice, ONE, "D-17: NAV after the unwind plus the requester's cost");
        assertEq(r.sharesBurned, 800e18);
        assertEq(r.usdcPaid, 800e6 - r.payoutFee - 4.08e6);
        assertGe(vault.sharePrice() * shares.balanceOf(bob), bobValue, "the holder who stays bears none of it");
    }

    /// @dev DEC-141: a Standard requester bears only what the sale loses above 1% of its value; the fund the rest.
    ///      408 unwound at 1.5%: 6.12 lost, 4.08 absorbed, 2.04 deducted from the payout.
    function test_DEC141_standardRequesterBearsOnlyTheExcessOverOnePercent() public {
        _deployAtMinimumFees();
        hubVault.setUnwindLossBps(150);
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        _allocateToPosition(1600e6 + SEED_IDLE); // Free Idle 400
        _request(alice, 800e6, STANDARD); // reserves the 400
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.marketCost, 6.12e6, "1.5% of the 408 sold");
        assertEq(r.marketCostAbsorbed, 4.08e6, "1% of the value sold");
        assertEq(r.leaverCost, 2.04e6, "the excess");
        assertEq(r.payoutFee, 0);
        assertEq(r.usdcPaid, r.usdcGross - 2.04e6);
    }

    function test_DEC068_partialPayoutLeavesRemainderOpen() public {
        _deployAtMinimumFees();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left, as before the seed
        vm.expectEmit(address(vault));
        emit ICoreVaultPayouts.UnwindForPayoutFailed(_requestId(alice, 1), _revertReason("unwind failed"));
        ICoreVault.PayoutReceipt memory r = _request(alice, 800e6, INSTANT);
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
        _deployAtMinimumFees();
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
        _deployAtMinimumFees();
        _deposit(alice, 100e6);
        _deposit(bob, 1000e6);
        ICoreVault.PayoutReceipt memory r = _request(alice, 500e6, INSTANT);
        assertEq(r.sharesBurned, 100e18);
        assertEq(r.usdcGross, 100e6);
        assertEq(r.usdcOutstanding, 0);
        assertEq(shares.balanceOf(alice), 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_DEC045_fullBurnPaysAttributedIncomeInSameTransaction() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        _hubIncomeCollected(address(usdc), 200.1e6); // 0.10 per share over 2,001 shares (the seed's included)
        uint256 owed = _incomeOf(alice);
        assertApproxEqAbs(owed, _netOfMinimumFee(100e6), 1);
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeWithdrawn(alice, address(usdc), owed);
        ICoreVault.PayoutReceipt memory r = _request(alice, 1000e6, INSTANT);
        assertEq(r.sharesBurned, 1000e18);
        // 1,000 gross minus 2% Payout Fee plus the income, in the same transaction.
        assertEq(usdc.balanceOf(alice), 980e6 + owed);
        assertEq(_incomeOf(alice), 0);
    }

    /// Independent review (verification plan CF-2; DEC-021, DEC-045): an income transfer the holder cannot receive
    /// (a USDC blocklist entry) used to revert the full-burn claim and with it the exit of the principal. The claim now
    /// completes; the income is owed to the holder (`IncomeTransferOwed`, checklist doc 15 gap 16) and paid by the
    /// permissionless claimOwedFees.
    function test_REVIEW_CF2_incomeTransferThatRefusesTheHolderNeverBlocksTheExit() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        _hubIncomeCollected(address(usdc), 200.1e6); // per share over 2,001 shares (the seed's included)
        uint256 owed = _incomeOf(alice);
        assertApproxEqAbs(owed, _netOfMinimumFee(100e6), 1);

        // USDC refuses the income transfer to alice (a blocklist entry of the issuer).
        vm.mockCallRevert(address(usdc), abi.encodeCall(IERC20.transfer, (alice, owed)), "blocklisted");
        vm.expectEmit(address(vault));
        emit ICoreVaultIncome.IncomeTransferOwed(alice, address(usdc), owed);
        ICoreVault.PayoutReceipt memory r = _request(alice, 1000e6, INSTANT);

        assertEq(r.sharesBurned, 1000e18, "the exit completed");
        assertEq(usdc.balanceOf(alice), 980e6, "principal paid");
        assertEq(vault.owedFees(address(usdc), alice), owed, "the income is owed to the holder");
        assertEq(_incomeOf(alice), 0);

        // Once the transfer goes through again, anyone pays it to the holder.
        vm.clearMockedCalls();
        vm.prank(bob);
        vault.claimOwedFees(address(usdc), alice);
        assertEq(usdc.balanceOf(alice), 980e6 + owed);
        assertEq(vault.owedFees(address(usdc), alice), 0);
    }

    function test_DEC045_partialBurnKeepsIncomeAttributed() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        _hubIncomeCollected(address(usdc), 100.1e6); // 0.10 per share over 1,001 shares (the seed's included)
        _request(alice, 500e6, INSTANT);
        assertEq(usdc.balanceOf(alice), 490e6);
        assertApproxEqAbs(_incomeOf(alice), _netOfMinimumFee(100e6), 1);
    }

    /// @dev DEC-160 (corrects the Q57 reading of S-26/S-28): no share is burned on a stale spoke report, not even by
    ///      a payout Idle covers. A stale price still falls back (D-28): once the report is fresh the claim pays.
    function test_DEC160_idlePaidPayoutRevertsOnAStaleReportButNotOnAnOldPrice() public {
        _deposit(alice, 1000e6);
        _deliver(_spokeReport(10e6, 0));
        prices.setPriceAt(address(usdg), 1e18, block.timestamp - 3 hours);
        vm.warp(block.timestamp + MAX_REPORT_AGE + 10);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        vault.requestPayout(100e6, INSTANT, 0);

        _request(alice, 100e6, STANDARD);
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        vault.claimPayout(0);

        _deliver(_spokeReport(10e6, 0));
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        // The fresh report counts; the price older than its bound still counts (payout liveness on prices, D-28).
        assertEq(r.shareAssets, SEED_IDLE + 997e6 + 10e6);
        assertEq(r.sharesBurned, ShareMath.sharesToBurn(100e6, r.sharePrice));
        assertGt(r.usdcPaid, 0);
    }

    function test_DEC047_burnAndPayAtomic() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        uint256 supplyBefore = shares.totalSupply();
        uint256 balanceBefore = usdc.balanceOf(alice);
        ICoreVault.PayoutReceipt memory r = _request(alice, 300e6, INSTANT);
        assertEq(supplyBefore - shares.totalSupply(), r.sharesBurned);
        assertEq(usdc.balanceOf(alice) - balanceBefore, r.usdcPaid);
    }

    /// @dev DEC-035 spirit, DEC-077 (final verification): a request that could never burn a share is refused.
    function test_DEC035_requestBelowOneSharePriceReverts() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        hubVault.setPosition(address(usdc), 100.1e6); // price 1.1 over 1,001 shares (the seed's included)
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutBelowOneShare.selector, 1e6, 1.1e24));
        vault.requestPayout(1e6, INSTANT, 0);
        _request(alice, 1.1e6, STANDARD); // exactly one share is accepted
        assertEq(vault.payoutRequest(alice).reserved, 1.1e6);
    }

    /// @dev DEC-077 (final verification): an outstanding amount below one share's price at the claim closes the
    ///      request with nothing burned, visibly (`closedBelowOneShare`), and releases its reserve (DEC-072).
    function test_DEC077_outstandingBelowOneShareClosesWithoutBurn() public {
        _deployAtMinimumFees();
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
        uint256 balanceBefore = shares.balanceOf(alice);
        ICoreVault.PayoutReceipt memory r = _request(alice, amount, standard ? STANDARD : INSTANT);
        if (standard) {
            vm.warp(block.timestamp + 72 hours);
            r = _claim(alice);
        }
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
