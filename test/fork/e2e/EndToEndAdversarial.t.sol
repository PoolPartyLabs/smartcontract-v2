// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
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
        core.requestPayout(ANA_PAYOUT, ICoreVaultPayouts.PayoutMode.Standard);
        uint256 reserve = core.payoutReserve();
        assertEq(reserve, ANA_PAYOUT, "DEC-072: Ana's request reserved in full");
        uint256 idleBefore = core.idle();
        assertEq(core.freeIdle(), idleBefore - reserve, "DEC-072: Free Idle excludes the reserve");

        // Bruno asks 1,000 above Free Idle: without the reserve rule Idle alone would cover 2,000 of it.
        InstantPlan memory plan = _planInstant();
        assertLt(plan.request, idleBefore, "the request is covered by Idle, not by Free Idle");
        vm.prank(bruno);
        core.requestPayout(plan.request, ICoreVaultPayouts.PayoutMode.Instant);

        bytes memory hints = _unwindHints(plan.target);
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout(hints);
        (uint256 target, uint256 proceeds) = _unwound(vm.getRecordedLogs());

        assertEq(target, plan.target, "DEC-095, DEC-081: the shortfall is measured against Free Idle, plus 2%");
        assertGt(proceeds, 0, "DEC-095: the reserve did not pay, the unwind did");
        assertEq(core.payoutReserve(), reserve, "DEC-095: the Payout Reserve survives the Instant claim");
        assertLe(core.payoutReserve(), core.idle(), "DEC-072: Payout Reserve <= Idle");
        // DEC-144: the Payout Fee stays in Idle.
        assertEq(
            core.idle(),
            idleBefore + proceeds - receipt.usdcGross + receipt.payoutFee,
            "DEC-080: Idle moved by the proceeds and the payout only"
        );
        assertEq(receipt.usdcOutstanding, 0, "paid in full");
        assertFalse(core.payoutRequest(bruno).open, "DEC-074: closed");
        assertEq(receipt.payoutFee, ShareMath.bpsOf(receipt.usdcGross, 200), "DEC-075: Payout Fee");

        _advance(72 hours);
        uint256 anaBefore = IERC20(ARB_USDC).balanceOf(ana);
        vm.prank(ana);
        ICoreVault.PayoutReceipt memory anaReceipt = core.claimPayout("");
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
    ///      `StaleSpokeReport`. Q57 reading (docs/OPEN-QUESTIONS.md): an Idle-paid payout still uses the last accepted
    ///      report and never reverts on its age; the spoke's value stays in Share Assets.
    function test_ruling20260929_forkReportLifetimeGatesMintsNotIdlePayouts() public {
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

        // Q57 reading: the stale report still values the spoke for a payout paid from Free Idle.
        uint256 spokePrincipal = _principalValue(r);
        (uint256 spokeValue,,,) = core.spokeCapUsage(0);
        assertEq(spokeValue, spokePrincipal, "the last accepted report still values the spoke");
        assertEq(core.shareAssets(), _sumOfBuckets(), "DEC-104: nothing left the bases with the freshness");
        uint256 request = core.freeIdle() / 2;
        assertGt(request, 0);
        vm.startPrank(ana);
        core.requestPayout(request, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = core.claimPayout("");
        vm.stopPrank();
        assertEq(receipt.unwindProceeds, 0, "DEC-067: Free Idle paid");
        assertEq(receipt.usdcOutstanding, 0, "the stale report never blocks an Idle-paid payout");
        assertGt(receipt.sharesBurned, 0);
        assertApproxEqAbs(
            receipt.shareAssets,
            assetsAtLifetime + ShareMath.usdcFor(shares, receipt.sharePrice),
            1e6,
            "priced with the stale report"
        );
    }

    // -----------------------------------------------------------------------------------------------------------------
    // DEC-014 vs CS-OQ-1 (OPEN): the main scenario collects the hub income before Bruno enters. Here Bruno enters first
    // and the income generated entirely before his entry is collected after it.
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-014 says a new entrant gets nothing of income generated before entry, regardless of when it is
    ///      collected. The CS-OQ-1 stance (docs/OPEN-QUESTIONS.md) attributes at collection to the holders of that
    ///      moment, so on the live stack Bruno captures a pro-rata share of the V4 fees and Aave interest that were
    ///      earned while Ana was the only holder, and can withdraw it at once. Pinned here on the fork as evidence for
    ///      the founder's ruling; the unit pin is `test_DEC014_OPEN_incomeGeneratedBeforeEntryIsSharedWhenCollectedAfterIt`.
    function test_DEC014_OPEN_forkIncomeGeneratedBeforeBrunoIsSharedWhenCollectedAfterHim() public {
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

        (uint256 netUsdc, uint256 netWeth) = _collectHubIncome();
        uint256 brunoUsdc = core.attributedIncome(bruno, ARB_USDC);
        uint256 brunoWeth = core.attributedIncome(bruno, ARB_WETH);
        assertGt(brunoUsdc, 0, "CS-OQ-1 stance: the entrant shares income generated before his entry (DEC-014 tension)");
        assertGt(brunoWeth, 0);
        assertApproxEqAbs(brunoUsdc, Math.mulDiv(netUsdc, brunoShares, supply), 1, "pro rata at collection");
        assertApproxEqAbs(brunoWeth, Math.mulDiv(netWeth, brunoShares, supply), 1);
        assertApproxEqAbs(core.attributedIncome(ana, ARB_USDC), Math.mulDiv(netUsdc, anaShares, supply), 1);
        assertLt(core.attributedIncome(ana, ARB_USDC), netUsdc, "Ana no longer receives all of what she earned");

        uint256 before = IERC20(ARB_USDC).balanceOf(bruno);
        vm.prank(bruno);
        assertEq(core.withdrawIncome(ARB_USDC), brunoUsdc, "DEC-073: and he can withdraw it at once");
        assertEq(IERC20(ARB_USDC).balanceOf(bruno) - before, brunoUsdc);
        emit log_named_decimal_uint("Income generated before Bruno's entry that Bruno captured (USDC)", brunoUsdc, 6);
    }
}
