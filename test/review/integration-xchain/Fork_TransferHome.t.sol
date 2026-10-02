// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {XChainBase, LiveRelayData, ILiveSpokePool} from "./XChainBase.sol";

/// @notice Review port of integration-xchain `Fork_TransferHome`: consolidated H-02 (report 03 H-02, register S-4 with
///         S-3: a filled transfer home that no accepted report listed in time) and H-01 (report 02 H-02, register S-3:
///         an unfilled transfer home outside every base until its refund is reported), on the factory-created fund:
///         real `depositV3` on Robinhood, real `fillRelay` on Arbitrum (the live pool calls the Core Vault's handler),
///         reports through both real Wormhole Cores, and the Across refund through the live SpokePool's
///         `executeRelayerRefundLeaf`.
/// @dev Adaptation to the fix branch, interface only: the spoke's first report is delivered before the first send
///      (S-14), and a send home carries no exclusivity (S-9).
contract Fork_TransferHome is XChainBase {
    uint256 internal constant ARRIVES = BRIDGE_AMOUNT - BRIDGE_FEE; // 3,998.40 USDG
    uint256 internal constant HOME_FEE = 1.5e6; // within 4 bps of 3,988.40

    bytes4 internal constant EXPIRED_FILL_DEADLINE = bytes4(keccak256("ExpiredFillDeadline()"));

    uint256 internal assetsBefore;

    /// @dev Fund created, Ana deposits 10,000, the spoke's first report, 4,000 go to Robinhood, a relayer fills for
    ///      real, a report confirms.
    function _setUpSpokeHoldsPrincipal() internal returns (uint256 principal) {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _report(); // S-14: the spoke's first report, before the first send
        (bytes32 out, LiveRelayData memory relay) = _sendToSpoke(BRIDGE_AMOUNT, _quote(ARRIVES));
        _fillOnRobinhood(relay, relayer);
        _report();
        assertEq(uint8(core.transit(out).state), uint8(TransitState.ArrivalConfirmed));
        _onRobinhood();
        principal = spokeVault.unallocatedBalance(RH_USDG); // 3,988.40 after the 10 USDG Operating Cash top-up
        _onArbitrum();
        assetsBefore = core.shareAssets();
        assertEq(assetsBefore, MANAGER_SEED_IDLE + 9963.4e6);
    }

    /// @dev The manager sends the whole spoke principal home; a relayer fills it on Arbitrum two minutes later. Returns
    ///      the id, the relay and the hub time of the fill.
    function _sendHomeFilled(uint256 principal)
        internal
        returns (bytes32 home, LiveRelayData memory relay, uint256 filledAt)
    {
        (home, relay) = _sendToHub(principal, TransferKind.Principal, _quote(principal - HOME_FEE));
        _onArbitrum();
        _advance(2 minutes);
        _fillOnArbitrum(relay, relayer); // live pool: USDC to the Core Vault, then handleV3AcrossMessage
        filledAt = block.timestamp;
        assertEq(core.unmatchedArrivals(), principal - HOME_FEE, "held apart until an accepted report lists it");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // H-02 (report 03 H-02; S-4, S-3)
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice FIXED. The review's outage: no report until the spoke used to stop listing the transfer
    ///         (`fillDeadline + maxReportAge`). On e5c778a Share Assets fell from 9,963.40 to 5,975.00 and 3,986.90 stayed
    ///         in `unmatchedArrivals` for good. Since S-3 the spoke still lists it, and the first report matches it.
    function test_REVIEW_H02_filledTransferHomeIsMatchedByTheFirstReportAfterTheOutage() public {
        uint256 principal = _setUpSpokeHoldsPrincipal();
        (bytes32 home,,) = _sendHomeFilled(principal);

        _onRobinhood();
        Transit memory t = spokeVault.hubBoundTransit(home);
        _advance(uint256(t.fillDeadline) + ROBINHOOD_MAX_REPORT_AGE + 1 - block.timestamp);
        _report(); // reporting resumes
        assertEq(_latest().inFlightToHub.length, 1, "S-3: still listed");
        assertEq(core.unmatchedArrivals(), 0, "matched");
        assertApproxEqAbs(core.shareAssets(), assetsBefore - HOME_FEE, 1, "credited to Idle, only the fee is gone");
        assertEq(core.sweepExcess(ARB_USDC), 0);
    }

    /// @notice FIXED with the S-4 recovery. An outage longer than `HUB_BOUND_RETENTION` (3 days): the first report after
    ///         it no longer lists the transfer, and `recoverUnlistedArrival` opens on that report (it refuses while the
    ///         hub's latest report predates the arrival). Between the delivery and the recovery call the transfer is in
    ///         no value base (the core-b residual, pinned there with exact numbers).
    function test_REVIEW_H02_unlistedArrivalIsRecoveredAfterAMultiDayOutage() public {
        uint256 principal = _setUpSpokeHoldsPrincipal();
        (bytes32 home,, uint256 filledAt) = _sendHomeFilled(principal);

        _onRobinhood();
        Transit memory t = spokeVault.hubBoundTransit(home);
        _advance(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1 - block.timestamp);
        _onArbitrum();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreVault.RecoveryNotReady.selector, home, filledAt + uint256(ROBINHOOD_MAX_REPORT_AGE)
            )
        );
        core.recoverUnlistedArrival(0, home);

        _report();
        assertEq(_latest().inFlightToHub.length, 0, "past the retention: no longer listed");
        uint256 assetsInGap = core.shareAssets();
        _log("Share Assets between the delivery and the recovery", assetsInGap);
        assertApproxEqAbs(assetsBefore - assetsInGap, principal, 1, "in no value base until the recovery call");
        vm.prank(stranger);
        assertEq(core.recoverUnlistedArrival(0, home), principal - HOME_FEE);
        assertEq(core.unmatchedArrivals(), 0);
        assertApproxEqAbs(core.shareAssets(), assetsBefore - HOME_FEE, 1, "back in Share Assets, once");
    }

    /// @notice Control: one report delivered inside the window matches and credits the same arrival to Idle.
    function test_REVIEW_H02_control_oneReportInsideTheWindowCreditsIt() public {
        uint256 principal = _setUpSpokeHoldsPrincipal();
        _sendHomeFilled(principal);
        _report();
        assertEq(core.unmatchedArrivals(), 0);
        assertApproxEqAbs(core.shareAssets(), assetsBefore - HOME_FEE, 1, "credited to Idle, only the fee is gone");
    }

    /// @notice FIXED (re-attack of the S-4 recovery rule on the live pool). A stranger pre-seeds the next send-home id
    ///         with a self-made 1-unit `fillRelay` on the live Arbitrum SpokePool: no Robinhood deposit backs it, yet the
    ///         pool pays the Core Vault and runs its handler, and the relay is marked Filled. Days later the manager sends
    ///         the spoke principal home under that id and it is filled. On main (before the cross-check fix) the
    ///         recovery was open at once and a claimant was paid on Share Assets that counted the transfer twice; now
    ///         the real arrival restarts the clock, the recovery is refused around the claim, and the claim is paid on
    ///         the transfer counted once.
    function test_REVIEW_H02_preSeededIdOpensNoEarlyRecoveryAroundAClaim() public {
        uint256 principal = _setUpSpokeHoldsPrincipal();
        uint256 brunoShares = _depositAs(bruno, 10_000e6);
        uint256 brunoRequest = ShareMath.usdcFor(brunoShares, core.sharePrice());
        vm.prank(bruno);
        core.requestPayout(brunoRequest, ICoreVault.PayoutMode.Standard);

        bytes32 predicted = _sendHomeId(1);
        LiveRelayData memory seed = _fabricatedFillOnArbitrum(predicted, 1, TransferKind.Principal, stranger);
        bytes32 seedHash = keccak256(abi.encode(seed, ARBITRUM));
        assertEq(ILiveSpokePool(ARB_ACROSS_SPOKE_POOL).fillStatuses(seedHash), 2, "the live pool filled it");
        assertEq(core.unmatchedArrivals(), 1, "and ran the Core Vault's handler: held apart");

        // The first S-4 version opened the recovery 6 h + 3 days + 2 x maxReportAge after the FIRST arrival.
        _onRobinhood();
        _advance(6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(ROBINHOOD_MAX_REPORT_AGE));
        _report();
        _onRobinhood();
        (bytes32 home, LiveRelayData memory relay) =
            _sendToHub(principal, TransferKind.Principal, _quote(principal - HOME_FEE));
        assertEq(home, predicted, "the id the stranger seeded");
        _onArbitrum();
        _advance(2 minutes);
        _fillOnArbitrum(relay, relayer);
        uint256 filledAt = block.timestamp;
        uint256 fair = core.shareAssets();

        vm.prank(bruno);
        vm.expectRevert(
            abi.encodeWithSelector(
                ICoreVault.RecoveryNotReady.selector, home, filledAt + uint256(ROBINHOOD_MAX_REPORT_AGE)
            )
        );
        core.recoverUnlistedArrival(0, home);
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory r = core.claimPayout("");
        _log("Share Assets the claim used", r.shareAssets);
        assertEq(r.shareAssets, fair, "the transfer counted once, on the spoke's last report");

        _report();
        assertEq(core.unmatchedArrivals(), 1, "the listing credits the transfer; the stranger's unit stays apart");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, home));
        core.recoverUnlistedArrival(0, home);
    }

    /// @notice FIXED (S-64). Found by this port: any unlisted arrival restarted the S-45 recovery clock, so after an
    ///         outage longer than the retention a stranger who bridged 1 unit under the id before each report held the
    ///         recovery off while mints stayed open (an entrant's 10,000 became 12,467.83, Ana fell from 9,963.40 to
    ///         7,468.57; cost 1 unit per report lifetime). Now only an arrival at least as large as what is held restarts
    ///         it, so the dust changes nothing and the first report after the retention opens the recovery.
    function test_REVIEW_H02_strangerDustNoLongerHoldsTheRecoveryOff() public {
        uint256 principal = _setUpSpokeHoldsPrincipal();
        (bytes32 home,,) = _sendHomeFilled(principal);
        _onRobinhood();
        Transit memory t = spokeVault.hubBoundTransit(home);
        _advance(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1 - block.timestamp);

        (bytes memory payload, uint64 whSeq) = _publish();
        _fabricatedFillOnArbitrum(home, 1, TransferKind.Principal, stranger); // the stranger's dust, as before
        _advance(FINALITY);
        _deliver(payload, whSeq);
        assertEq(_latest().inFlightToHub.length, 0, "past the retention: no longer listed");
        vm.prank(keeper);
        assertEq(core.recoverUnlistedArrival(0, home), principal - HOME_FEE + 1, "the transfer and the dust, at once");
        assertApproxEqAbs(core.shareAssets(), assetsBefore - HOME_FEE + 1, 2, "back in Share Assets but for the fee");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // H-01 (report 02 H-02; S-3, S-9)
    // -----------------------------------------------------------------------------------------------------------------

    /// @notice FIXED. On e5c778a the manager named its own relayer exclusive and did not fill; from the first report
    ///         built after `fillDeadline + maxReportAge` until the refund was reported the transfer was in no base, and
    ///         a 10,000 deposit in that window was worth 12,468.77 (+24.7%) while Ana fell from 9,963.40 to 7,469.13. Now
    ///         exclusivity is refused (S-9); the same unfilled send (nobody fills it) stays listed (S-3), the refund
    ///         comes through the live pool's refund leaf at deadline + 55 min, and the next report recognizes it with
    ///         no `recognizeRefund` call: the Share Price never leaves the fee-only level.
    function test_REVIEW_H01_unfilledTransferHomeStaysInShareAssetsUntilItsRefund() public {
        uint256 principal = _setUpSpokeHoldsPrincipal();
        address managerRelayer = makeAddr("managerRelayer");
        _onRobinhood();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.ExclusiveRelayerNotAllowed.selector, managerRelayer));
        spokeVault.sendToHub(
            principal, TransferKind.Principal, 0, _exclusiveQuote(principal - HOME_FEE, managerRelayer)
        );

        (bytes32 home, LiveRelayData memory relay) =
            _sendToHub(principal, TransferKind.Principal, _quote(principal - HOME_FEE));
        _report();
        assertApproxEqAbs(core.shareAssets(), assetsBefore - HOME_FEE, 1, "in flight home: counted");

        // Nobody fills; after the deadline nobody can.
        uint256 deadline = relay.fillDeadline;
        _onArbitrum();
        _advance(deadline + 1 - block.timestamp);
        deal(ARB_USDC, stranger, relay.outputAmount);
        vm.startPrank(stranger);
        IERC20(ARB_USDC).approve(ARB_ACROSS_SPOKE_POOL, relay.outputAmount);
        vm.expectRevert(EXPIRED_FILL_DEADLINE);
        ILiveSpokePool(ARB_ACROSS_SPOKE_POOL).fillRelay(relay, ROBINHOOD, bytes32(uint256(uint160(stranger))));
        vm.stopPrank();

        // The review's window: the first report built after fillDeadline + maxReportAge.
        _onRobinhood();
        _advance(deadline + ROBINHOOD_MAX_REPORT_AGE + 1 - block.timestamp);
        _report();
        assertEq(_latest().inFlightToHub.length, 1, "S-3: still listed");
        uint256 assetsInWindow = core.shareAssets();
        assertApproxEqAbs(assetsInWindow, assetsBefore - HOME_FEE, 1, "still in Share Assets");
        uint256 priceInWindow = core.sharePrice();
        uint256 brunoShares = _depositAs(bruno, 10_000e6);

        // The refund through the live pool's refund leaf; nobody calls recognizeRefund, the next report does (S-3).
        _onRobinhood();
        _advance(deadline + 55 minutes - block.timestamp); // docs/DECISIONS.md: 55 to 90 min after the deadline
        _acrossRefund(RH_ACROSS_SPOKE_POOL, RH_USDG, spokeVault.hubBoundTransit(home).escrow, principal);
        _report();
        _onRobinhood();
        assertEq(uint8(spokeVault.hubBoundTransit(home).state), uint8(TransitState.RefundRecognized), "by report()");
        assertEq(spokeVault.unallocatedBalance(RH_USDG), principal, "the whole amount sent is back");

        _onArbitrum();
        uint256 priceAfter = core.sharePrice();
        uint256 brunoValue = ShareMath.usdcFor(brunoShares, priceAfter);
        uint256 anaValue = ShareMath.usdcFor(IERC20(shareToken).balanceOf(ana), priceAfter);
        _log("Share Assets in the review's window", assetsInWindow);
        _log("price in window (1e24 = 1 USDC)", priceInWindow);
        _log("price after the refund is reported", priceAfter);
        _log("Bruno paid 10,000 in the window; worth now", brunoValue);
        // Ana's value before: her shares' part of Share Assets; the manager's seed shares hold the rest (DEC-127).
        uint256 anaShares = IERC20(shareToken).balanceOf(ana);
        uint256 anaBefore = assetsBefore * anaShares / (MANAGER_SEED_SHARES + anaShares);
        _log("Ana's value before", anaBefore);
        _log("Ana's value now", anaValue);
        assertApproxEqRel(brunoValue, 9975e6, 0.001e18, "the window's depositor gets what he paid for");
        assertApproxEqRel(anaValue, anaBefore, 0.001e18, "the existing holder keeps her value");
    }
}
