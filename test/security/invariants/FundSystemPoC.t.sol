// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {FundSystemFixture} from "./FundSystemFixture.sol";

/// @title Proofs of concept for the findings of the dynamic analysis
/// @notice Each `test_POC_` passes while the behaviour it shows exists. They run on the whole fund of
///         FundSystemFixture: the real Core Vault, Spoke Vaults and ValueReportReceiver.
contract FundSystemPoCTest is FundSystemFixture {
    address internal ana = makeAddr("ana");
    address internal bruno = makeAddr("bruno");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        _deploySystem();
        // Operating Cash off, so every number below is exact.
        vm.startPrank(manager);
        sys.core.setOperatingCashParameters(0, 0);
        sys.spokeVault.setOperatingCashParameters(0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-01 (security review S-3): an expired send home no longer leaves Share Assets before its refund
    // ---------------------------------------------------------------------------------------------------------------

    /// Was PoC `test_POC_expiredSendHomeLeavesShareAssetsAndAnEntrantTakesTheDifference`: the spoke dropped an
    /// unfilled send home from `inFlightToHub` at `fillDeadline + maxReportAge` (OQ-09 "presumed filled"), so until
    /// its refund was recognized and reported the transfer was in no base, the Share Price was halved and an entrant
    /// took more than 22,000 USDC from the prior holder. Fix (S-3, `SpokeCrossChainLib._stillInFlight` and
    /// `_sweepInFlight`): the send stays listed until its refund is recognized (a report recognizes a landed refund
    /// itself) or `ReportCodec.HUB_BOUND_RETENTION` after its deadline. The same sequence now FAILS for the entrant.
    function test_SEC_S3_expiredSendHomeStaysInShareAssetsAndAnEntrantGainsNothing() public {
        _fundWithSpokeBalance(50_000e6);
        uint256 assetsBefore = sys.core.shareAssets();
        uint256 priceBefore = sys.core.sharePrice();
        uint256 anaShares = sys.shares.balanceOf(ana);
        assertEq(assetsBefore, 99_999e6);

        // The manager sends the spoke's 50,000 USDG home with a quote no relayer fills (no fee for the relayer).
        uint256 depositIndex = sys.spokePool.numberOfDeposits();
        vm.prank(manager);
        bytes32 transitId = sys.spokeVault.sendToHub(50_000e6, TransferKind.Principal, 0, _quote(50_000e6));
        _report();
        assertEq(sys.core.shareAssets(), assetsBefore, "in flight home, still counted (DEC-085)");

        // The fill deadline and one report lifetime pass; Across has not refunded yet.
        Transit memory t = sys.spokeVault.hubBoundTransit(transitId);
        _warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1 - block.timestamp);
        _report();
        assertEq(sys.core.shareAssets(), assetsBefore, "S-3: the unfilled transfer is still counted in flight");
        assertEq(sys.core.sharePrice(), priceBefore, "S-3: the Share Price did not move");

        // An entrant deposits at the fair price.
        (uint256 attackerShares,) = _deposit(attacker, 50_000e6);
        assertLt(attackerShares, anaShares * 51 / 100, "S-3: the entrant gets half the prior supply, not all of it");

        // The refund lands; the next report recognizes it by itself.
        sys.spokePool.refund(depositIndex);
        _report();
        assertEq(uint8(sys.spokeVault.hubBoundTransit(transitId).state), uint8(TransitState.RefundRecognized));

        // The entrant exits at once (Instant Payout from Idle), paying the 2% Payout Fee and the flow fee.
        uint256 worth = ShareMath.usdcFor(attackerShares, sys.core.sharePrice());
        vm.startPrank(attacker);
        sys.core.requestPayout(worth, ICoreVault.PayoutMode.Instant);
        sys.core.claimPayout("");
        vm.stopPrank();
        assertLt(sys.usdc.balanceOf(attacker), 50_000e6, "S-3: the entrant leaves with less than it deposited");

        uint256 anaWorth = ShareMath.usdcFor(anaShares, sys.core.sharePrice());
        assertGe(anaWorth + 1e6, assetsBefore, "S-3: the prior holder lost nothing");
    }

    /// Was PoC `test_POC_payoutDuringTheWindowIsPaidAtTheUnderstatedPrice`: a holder whose payout was priced while the
    /// transfer was in no base was paid about half of what the shares were worth. Now paid their value.
    function test_SEC_S3_payoutAfterTheReportLifetimeIsPaidTheFairValue() public {
        _fundWithSpokeBalance(50_000e6);
        _deposit(bruno, 10_025e6);
        uint256 brunoShares = sys.shares.balanceOf(bruno);
        uint256 fairValue = ShareMath.usdcFor(brunoShares, sys.core.sharePrice());

        vm.prank(manager);
        bytes32 transitId = sys.spokeVault.sendToHub(50_000e6, TransferKind.Principal, 0, _quote(50_000e6));
        Transit memory t = sys.spokeVault.hubBoundTransit(transitId);
        _warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1 - block.timestamp);
        _report();

        vm.startPrank(bruno);
        sys.core.requestPayout(fairValue, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = sys.core.claimPayout("");
        vm.stopPrank();
        assertEq(sys.shares.balanceOf(bruno), 0, "every share burned");
        assertGe(receipt.usdcGross + 1e6, fairValue, "S-3: paid the shares' value");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-02 (security review S-4): a send home that no report lists in time is no longer held apart for good
    // ---------------------------------------------------------------------------------------------------------------

    /// Was PoC `test_POC_sendHomeFilledButNeverListedIsLostToTheFund`: a send home filled within minutes waited in
    /// `unmatchedArrivals` for a listing report, and if none was accepted before the spoke stopped listing it
    /// (`fillDeadline + maxReportAge`) the fund's own USDC stayed there with no verb to credit it. Fix: the spoke lists
    /// it for `ReportCodec.HUB_BOUND_RETENTION` past its deadline (S-3) and, past that, `recoverUnlistedArrival` (S-4)
    /// credits it once no acceptable report can list it. The same outage now costs time, not principal.
    function test_SEC_S4_sendHomeFilledButNeverListedReachesIdle() public {
        _fundWithSpokeBalance(50_000e6);
        uint256 assetsBefore = sys.core.shareAssets();

        uint256 depositIndex = sys.spokePool.numberOfDeposits();
        vm.prank(manager);
        bytes32 transitId = sys.spokeVault.sendToHub(50_000e6, TransferKind.Principal, 0, _quote(49_900e6));

        MockAcrossSpokePool.Deposit memory d = sys.spokePool.deposit(depositIndex);
        sys.hubPool.fill(address(sys.core), address(sys.usdc), d.outputAmount, d.message);
        uint256 filledAt = block.timestamp;
        assertEq(sys.core.unmatchedArrivals(), 49_900e6, "held apart until a report lists it");

        // No report is delivered for fillDeadline + maxReportAge: the next one still lists it and the hub credits it.
        Transit memory t = sys.spokeVault.hubBoundTransit(transitId);
        uint256 snapshot = vm.snapshotState();
        _warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1 - block.timestamp);
        _report();
        assertEq(sys.core.unmatchedArrivals(), 0, "S-4: credited after the old window");
        assertEq(sys.core.shareAssets(), assetsBefore - 100e6, "S-4: only the bridge fee is lost");
        vm.revertToState(snapshot);

        // No report is delivered for the whole retention either: the recovery credits it.
        _warp(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1 - block.timestamp);
        _report();
        assertEq(sys.core.unmatchedArrivals(), 49_900e6, "no report lists it any more");
        _warp(filledAt + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(MAX_REPORT_AGE) - block.timestamp);
        assertEq(sys.core.recoverUnlistedArrival(0, transitId), 49_900e6, "S-4: recovered");
        assertEq(sys.core.unmatchedArrivals(), 0);
        _report();
        assertEq(sys.core.shareAssets(), assetsBefore - 100e6, "S-4: only the bridge fee is lost");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-03: the manager can move all principal into Operating Cash, which nothing ever pays out
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-096 / DEC-100 ("floor configurable by the Manager", "no protocol cap on the floor") with an uncapped top-up
    /// and no verb that spends or returns Operating Cash in the MVP: one parameter change and one 1-unit allocation
    /// move all Free Idle into Operating Cash, outside Share Assets, for good.
    function test_POC_managerMovesAllFreeIdleIntoOperatingCash() public {
        _deposit(ana, 100_250e6);
        uint256 idle = sys.core.idle();
        assertEq(idle, 99_999e6);

        vm.startPrank(manager);
        sys.core.setOperatingCashParameters(type(uint256).max, idle - 1);
        sys.core.allocateToHubSpokeVault(1);
        vm.stopPrank();

        assertEq(sys.core.idle(), 0);
        assertEq(sys.core.operatingCash(), idle - 1, "all Free Idle is Operating Cash now");
        assertEq(sys.core.shareAssets(), 1, "Share Assets: one base unit");
        assertEq(sys.core.sweepExcess(address(sys.usdc)), 0, "not sweepable: it is ledger value");

        // Ana's 99,999 shares, bought for 99,999 USDC, are worth nothing: a payout burns them all and pays zero.
        assertEq(ShareMath.usdcFor(sys.shares.balanceOf(ana), sys.core.sharePrice()), 0);
        vm.startPrank(ana);
        sys.core.requestPayout(99_999e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = sys.core.claimPayout("");
        vm.stopPrank();
        assertEq(receipt.sharesBurned, 99_999e18);
        assertEq(receipt.usdcPaid, 0);
        assertEq(sys.usdc.balanceOf(address(sys.core)), idle - 1, "while the USDC is still in the Core Vault");
    }

    /// The same on a spoke, where the top-up also runs on an arrival: after the manager's parameter change, a
    /// stranger's one-unit Across deposit is enough to move the whole Unallocated Balance into Operating Cash.
    function test_POC_managerMovesAllSpokePrincipalIntoOperatingCash() public {
        _fundWithSpokeBalance(50_000e6);
        vm.prank(manager);
        sys.spokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max);

        sys.spokePool
            .fill(
                address(sys.spokeVault),
                address(sys.usdg),
                1,
                abi.encode(uint256(1), FUND_ID, HUB, keccak256("any id"), TransferKind.Principal)
            );
        assertEq(sys.spokeVault.unallocatedBalance(address(sys.usdg)), 0);
        assertEq(sys.spokeVault.operatingCash(), 50_000e6 + 1);
        _report();
        // Half of the fund left Share Assets for good (and the stranger's unit is deducted as unknown value, DEC-080).
        assertEq(sys.core.shareAssets(), 99_999e6 - 50_000e6 - 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-04 (security review S-18): at zero Share Assets a claim closes its request instead of reverting
    // ---------------------------------------------------------------------------------------------------------------

    /// Was PoC `test_POC_zeroShareAssetsRevertEveryPayoutVerb`: with Share Assets at exactly zero and shares
    /// outstanding, `claimPayout`, `requestPayout` and `deposit` all reverted `ZeroSharePrice`, so an open request could
    /// never be closed. Fix (S-18, `CoreVault._sharesFor`): the claim closes the request with nothing burned or paid
    /// (`closedBelowOneShare`), the holder keeps its shares; a new request or a deposit still reverts, since nothing
    /// can be priced until value returns (documented in docs/security/KNOWN-LIMITATIONS.md).
    function test_SEC_S18_zeroShareAssetsClaimClosesTheRequest() public {
        _deposit(ana, 100_250e6);
        vm.prank(ana);
        sys.core.requestPayout(1000e6, ICoreVault.PayoutMode.Instant);
        _deposit(bruno, 10_025e6);
        uint256 anaShares = sys.shares.balanceOf(ana);

        uint256 idle = sys.core.idle();
        vm.prank(manager);
        sys.core.allocateToHubSpokeVault(idle);
        vm.mockCall(address(sys.hubVault), abi.encodeWithSignature("buildReport()"), abi.encode(_emptyReport()));
        assertEq(sys.core.shareAssets(), 0);

        vm.prank(ana);
        ICoreVault.PayoutReceipt memory r = sys.core.claimPayout("");
        assertTrue(r.closedBelowOneShare, "S-18: closed with nothing burned");
        assertEq(r.sharesBurned, 0);
        assertEq(r.usdcPaid, 0);
        assertFalse(sys.core.payoutRequest(ana).open, "S-18: the request is closed");
        assertEq(sys.shares.balanceOf(ana), anaShares, "S-18: the holder keeps its shares");

        vm.prank(bruno);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        sys.core.requestPayout(1e6, ICoreVault.PayoutMode.Instant);
        sys.usdc.mint(bruno, 1000e6);
        vm.startPrank(bruno);
        sys.usdc.approve(address(sys.core), 1000e6);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        sys.core.deposit(1000e6, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal returns (uint256 shares, uint256 charged) {
        sys.usdc.mint(who, amount);
        vm.startPrank(who);
        sys.usdc.approve(address(sys.core), amount);
        (shares, charged) = sys.core.deposit(amount, 0);
        vm.stopPrank();
    }

    function _quote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote(outputAmount, uint32(block.timestamp), 0, address(0));
    }

    /// @dev Anyone publishes the spoke's report and delivers its VAA to the hub.
    function _report() internal {
        uint256 index = sys.wormhole.publishedCount();
        sys.spokeVault.report();
        MockWormholeCore.Published memory p = sys.wormhole.published(index);
        CoreBridgeVM memory m;
        m.version = 1;
        m.emitterChainId = WH_SPOKE;
        m.emitterAddress = bytes32(uint256(uint160(p.emitter)));
        m.sequence = p.sequence;
        m.consistencyLevel = p.consistencyLevel;
        m.payload = p.payload;
        m.signatures = new GuardianSignature[](0);
        sys.receiver.deliver(abi.encode(m));
    }

    function _emptyReport() internal view returns (ReportCodec.Report memory r) {
        r.timestamp = uint64(block.timestamp);
    }

    function _warp(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        sys.prices.setPrice(address(sys.usdg), 1e18);
    }

    /// @dev 100,000 USDC deposited by Ana, `toSpoke` of it sent to the spoke, filled and confirmed by a report.
    function _fundWithSpokeBalance(uint256 toSpoke) internal {
        _deposit(ana, 100_250e6);
        _report(); // S-14: the spoke's first report, before the hub funds it
        uint256 depositIndex = sys.hubPool.numberOfDeposits();
        vm.prank(manager);
        sys.core.sendToSpoke(0, toSpoke, 0, _quote(toSpoke));
        MockAcrossSpokePool.Deposit memory d = sys.hubPool.deposit(depositIndex);
        sys.spokePool.fill(address(sys.spokeVault), address(sys.usdg), d.outputAmount, d.message);
        _report();
    }
}
