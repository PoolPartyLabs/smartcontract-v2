// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {EndToEndScenario} from "./EndToEnd.t.sol";

/// @notice Adversarial branches of the end-to-end fork scenario (verification round 1 of the e2e stage): each test
///         replays a prefix of the ten phases against the live protocols and then takes the path the main scenario
///         does not walk.
contract EndToEndAdversarialForkTest is EndToEndScenario {
    // -----------------------------------------------------------------------------------------------------------------
    // DEC-095: the main scenario claims Bruno's Instant Payout with an empty Payout Reserve, so it never shows that the
    // reserve is out of reach. Here Ana's Standard request holds 3,000 of Idle while Bruno's Instant claim unwinds.
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-095: an Instant Payout never touches the Payout Reserve; the shortfall is measured against Free Idle.
    ///      DEC-081: the unwind target is that shortfall plus 2%. DEC-072: `payoutReserve <= idle` throughout.
    ///      DEC-060, DEC-067: Ana's Standard claim after the term is then paid from her reserve without an unwind.
    function test_DEC095_forkInstantPayoutUnwindsAgainstFreeIdleAndLeavesTheReserve() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();
        _phase7IncomeAndBrunoDeposit();

        _onArbitrum();
        vm.prank(ana);
        core.requestPayout(ANA_PAYOUT, ICoreVaultPayouts.PayoutMode.Standard, 0);
        uint256 reserve = core.payoutReserve();
        assertEq(reserve, ANA_PAYOUT, "DEC-072: Ana's request reserved in full");
        uint256 idleBefore = core.idle();
        assertEq(core.freeIdle(), idleBefore - reserve, "DEC-072: Free Idle excludes the reserve");

        // DEC-160: a fresh spoke report before the burn.
        _deliverFreshSpokeReport();
        // Bruno asks 1,000 above Free Idle: without the reserve rule Idle alone would cover 2,000 of it.
        InstantPlan memory plan = _planInstant();
        assertLt(plan.request, idleBefore, "the request is covered by Idle, not by Free Idle");
        // DEC-120 item 1: the Instant request is its own claim.
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory receipt =
            core.requestPayout(plan.request, ICoreVaultPayouts.PayoutMode.Instant, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, uint256 fracNum, uint256 fracDen, ISpokeVaultUnwind.UnwindResult memory u) = _unwound(logs);
        uint256 spokeProceeds;
        (receipt, spokeProceeds,,) = _settleSpokeUnwind(bruno, logs);

        assertEq(fracNum, plan.fracNum, "DEC-095, DEC-137: the fraction is measured against Free Idle, plus 2%");
        assertEq(fracDen, plan.fracDen);
        assertGt(u.proceeds, 0, "DEC-095: the reserve did not pay, the unwind did");
        assertEq(core.payoutReserve(), reserve, "DEC-095: the Payout Reserve survives the Instant claim");
        assertLe(core.payoutReserve(), core.idle(), "DEC-072: Payout Reserve <= Idle");
        // DEC-144, DEC-118: the Payout Fee and the requester's Market Cost stay in Idle.
        assertEq(
            core.idle(),
            idleBefore + u.proceeds + spokeProceeds - receipt.usdcGross + receipt.payoutFee + receipt.leaverCost,
            "DEC-080: Idle moved by the proceeds and the payout only"
        );
        assertLe(
            receipt.usdcPaid + receipt.flowFee,
            idleBefore - reserve + u.proceeds + spokeProceeds,
            "DEC-095: never from the reserve"
        );
        assertEq(receipt.payoutFee, ShareMath.bpsOf(receipt.usdcGross, 200), "DEC-075: Payout Fee");

        _advance(72 hours);
        _deliverFreshSpokeReport();
        uint256 anaBefore = IERC20(ARB_USDC).balanceOf(ana);
        vm.prank(ana);
        ICoreVault.PayoutReceipt memory anaReceipt = core.claimPayout(0);
        assertEq(anaReceipt.unwindProceeds, 0, "DEC-067: the reserve paid, nothing unwound");
        assertEq(anaReceipt.usdcOutstanding, 0, "DEC-060: paid in full after the term");
        assertLe(anaReceipt.usdcGross, ANA_PAYOUT, "DEC-077: never above the request");
        assertEq(IERC20(ARB_USDC).balanceOf(ana) - anaBefore, anaReceipt.usdcPaid);
        assertEq(core.payoutReserve(), 0, "DEC-072: reserve released");
        assertEq(core.shareAssets(), _sumOfBuckets(), "DEC-104: Share Assets is the sum of its buckets");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Ruling 2026-09-29 (report lifetime 1,587 s plus one block): the main scenario delivers and mints at age 0. Here
    // the delivered report is used at exactly its lifetime and one second past it.
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev Ruling 2026-09-29, DEC-099: a mint is allowed at exactly `maxReportAge` and refused one second later with
    ///      `StaleSpokeReport`. DEC-160 (corrects the Q57 reading): a burn is refused the same way, even one Idle
    ///      pays, until a fresh report arrives; the stale report keeps valuing the spoke in the meantime.
    function test_DEC160_forkReportLifetimeGatesMintsAndBurns() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();

        _onArbitrum();
        (ReportCodec.Report memory r,,) = receiver.latestReport(0);
        uint256 age = block.timestamp - r.timestamp;
        assertLt(age, ROBINHOOD_MAX_REPORT_AGE);
        _advance(ROBINHOOD_MAX_REPORT_AGE - age);
        assertEq(block.timestamp - r.timestamp, 1588, "ruling 2026-09-29: 1,587 s plus one block");
        assertTrue(receiver.isReportFresh(0), "fresh at exactly its lifetime");

        _refreshEthUsdFeed();
        uint256 assetsAtLifetime = core.shareAssets();
        deal(ARB_USDC, bruno, BRUNO_DEPOSIT);
        vm.startPrank(bruno);
        IERC20(ARB_USDC).approve(address(core), BRUNO_DEPOSIT);
        (uint256 shares,) = core.deposit(BRUNO_DEPOSIT / 2, 0);
        assertGt(shares, 0, "DEC-071: a mint at exactly the lifetime");

        _advance(1);
        _refreshEthUsdFeed();
        assertFalse(receiver.isReportFresh(0), "one second past the lifetime");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        core.deposit(BRUNO_DEPOSIT / 2, 0);
        vm.stopPrank();

        // The stale report still values the spoke; DEC-160: no burn on it, not even one Free Idle pays.
        uint256 spokePrincipal = _principalValue(r);
        (uint256 spokeValue,,,) = core.spokeCapUsage(0);
        assertEq(spokeValue, spokePrincipal, "the last accepted report still values the spoke");
        assertEq(core.shareAssets(), _sumOfBuckets(), "DEC-104: nothing left the bases with the freshness");
        uint256 request = core.freeIdle() / 2;
        assertGt(request, 0);
        vm.prank(ana);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        core.requestPayout(request, ICoreVaultPayouts.PayoutMode.Instant, 0);

        // Once a fresh report is delivered the same Idle-paid payout goes through.
        _deliverFreshSpokeReport();
        vm.prank(ana);
        ICoreVault.PayoutReceipt memory receipt = core.requestPayout(request, ICoreVaultPayouts.PayoutMode.Instant, 0);
        assertEq(receipt.unwindProceeds, 0, "DEC-067: Free Idle paid");
        assertEq(receipt.usdcOutstanding, 0);
        assertGt(receipt.sharesBurned, 0);
        assertGt(assetsAtLifetime, 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // DEC-014, DEC-138 (closes CS-OQ-1 and security review S-15): the main scenario collects the hub income after Bruno
    // enters. Here the income is generated entirely before his entry and collected after it.
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-014: a new entrant gets nothing of income generated before entry, regardless of when it is collected.
    ///      DEC-138 makes it so: Bruno's mint recognizes the hub income first (the hub Spoke Vault's counters, read in
    ///      the valuation), for Ana and the manager's seed only. Pinned on the live stack (the V4 fees and Aave interest
    ///      earned while Ana was the only holder); the unit pin is
    ///      `test_DEC138_incomeGeneratedBeforeEntryIsNotSharedWhenCollectedAfterIt`.
    function test_DEC138_forkIncomeGeneratedBeforeBrunoIsNotHisWhenCollectedAfterHim() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();

        _onArbitrum();
        IAdapter.PositionValue memory v4 = IAdapter(hubUniswap).positionValue(hubUniswapPosition);
        IAdapter.PositionValue memory aave = IAdapter(hubAave).positionValue(hubAavePosition);
        assertGt(v4.income1 + aave.income0, 0, "income generated while Ana was the only holder");

        _brunoDeposits();
        uint256 anaShares = IERC20(shareToken).balanceOf(ana);
        uint256 brunoShares = IERC20(shareToken).balanceOf(bruno);
        uint256 supply = IERC20(shareToken).totalSupply();
        assertEq(MANAGER_SEED_SHARES + anaShares + brunoShares, supply, "the manager's seed shares too (DEC-127)");

        uint256 heldBefore = core.incomeCollection().heldDollars;
        vm.prank(bruno);
        core.requestIncomeWithdrawal(0); // collected after Bruno's entry
        uint256 converted = core.incomeCollection().heldDollars - heldBefore;
        assertGt(converted, 0);
        assertEq(core.incomeOwed(bruno), 0, "DEC-014: nothing generated before his entry is Bruno's");
        assertApproxEqAbs(
            core.incomeOwed(ana), Math.mulDiv(converted, anaShares, anaShares + MANAGER_SEED_SHARES), 2, "all Ana's"
        );
        vm.prank(bruno);
        assertEq(core.withdrawIncome(), 0, "and he has nothing to withdraw");
        emit log_named_decimal_uint(
            "Income generated before Bruno's entry, all Ana's and the seed's (USDC)", converted, 6
        );
    }
}
