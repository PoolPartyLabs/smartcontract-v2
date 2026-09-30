// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {FundSystemFixture} from "./FundSystemFixture.sol";
import {FundSystemHandler} from "./FundSystemHandler.sol";

/// @title Invariants of the transit state machine across both vaults
/// @notice DEC-066, DEC-085, DEC-090, DEC-104: no cross-chain transfer is counted twice or lost, whatever the order
///         of fills, refunds, reports, attestations and strangers' arrivals. The handler checks after every action
///         that a transit only moves along the edges of the state machine.
/// @dev The handler runs under the two liveness assumptions documented in FundSystemHandler (a send home is listed by
///      a delivered report at once; an expired send home is refunded and recognized before the next report). Without
///      them value is lost or transiently dropped: see FundSystemPoC.t.sol.
contract TransitStateMachineInvariantTest is FundSystemFixture {
    uint8 internal constant PENDING = 0;
    uint8 internal constant FILLED = 1;
    uint8 internal constant REFUNDED = 2;

    FundSystemHandler internal handler;

    function setUp() public {
        _deploySystem();
        // The two liveness assumptions of FundSystemHandler hold unless an exploratory run drops them:
        // SEC_UNLISTED_SENDS_HOME=true and SEC_LATE_REFUNDS=true reproduce the counterexamples of the report.
        handler = new FundSystemHandler(
            sys, !vm.envOr("SEC_UNLISTED_SENDS_HOME", false), !vm.envOr("SEC_LATE_REFUNDS", false)
        );
        targetContract(address(handler));
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = FundSystemHandler.settle.selector;
        excluded[1] = FundSystemHandler.deliverFreshReport.selector;
        excludeSelector(StdInvariant.FuzzSelector(address(handler), excluded));
    }

    /// DEC-066, DEC-085: the hub's transit books are exactly the sums over its transits by state: the Spoke Cap
    /// counts the amount sent of every transit still Sent (C1) or whose expiry was attested by time alone (S-13) plus the pending return leg of both kinds (B1), and
    /// In-flight Value counts the amount to arrive of every transit Sent or ExpiryAttested plus the pending Principal
    /// return leg. What really happened to each Across deposit is consistent with the state the hub keeps.
    function invariant_DEC066_booksAreTheSumOfTheirTransits() public view {
        (, uint256 inFlightSent, uint256 inFlightToHub, uint256 cap) = sys.core.spokeCapUsage(0);
        assertEq(cap, SPOKE_CAP);
        assertEq(inFlightSent, handler.hubSendsHoldingTheCap(), "DEC-066 C1, S-13: Spoke Cap in flight");
        assertEq(
            sys.core.inFlightValue(),
            handler.hubSendsIn(TransitState.Sent, true) + handler.hubSendsIn(TransitState.ExpiryAttested, true)
                + handler.pendingPrincipalReturnLeg(),
            "DEC-085: In-flight Value"
        );
        assertEq(inFlightToHub, _pendingReturnLegBothKinds(), "DEC-066 B1: return leg in the Spoke Cap");

        uint256 count = handler.hubSendCount();
        for (uint256 i; i < count; ++i) {
            FundSystemHandler.HubSend memory h = handler.hubSend(i);
            Transit memory t = sys.core.transit(h.id);
            assertEq(t.amountSent, h.amountSent);
            assertEq(t.amountToArrive, h.amountToArrive);
            if (t.state == TransitState.RefundRecognized) {
                assertEq(h.outcome, REFUNDED, "DEC-063: refund recognized for a transit Across never refunded");
                assertTrue(h.recognized);
            }
            if (t.state == TransitState.ExpiryAttested) {
                assertGt(block.timestamp, h.deadline, "DEC-066: expiry attested before the deadline");
            }
            if (t.state == TransitState.ArrivalConfirmed && h.outcome != FILLED) {
                // OQ-01, OQ-09: only a stranger who brought at least the whole amount can confirm an unfilled transit.
                assertGe(h.strangerListed, h.amountToArrive, "OQ-09: confirmed without an arrival");
            }
            if (h.recognized) assertEq(h.outcome, REFUNDED);
        }
    }

    /// DEC-085, DEC-104 with a fresh report and nothing else settled: every unit of the fund's principal is in exactly
    /// one base, wherever it is. Share Assets equal the ledgers (Idle, both Spoke Vaults) plus every hub-to-spoke
    /// transit the hub still counts in flight, plus every Principal transfer home whose value is not back in a ledger
    /// (still with Across, or refunded to its escrow and not yet recognized), less the value of unknown origin the
    /// spoke credited (DEC-080). A transfer that is in no base, or in two, breaks the equality.
    function invariant_DEC085_withAFreshReportEveryTransferIsInExactlyOneBase() public {
        handler.deliverFreshReport();
        uint256 total = handler.principalHeld() + handler.hubSendsIn(TransitState.Sent, true)
            + handler.hubSendsIn(TransitState.ExpiryAttested, true) + handler.principalOnTheWayHome();
        uint256 confirmed = handler.hubSendsIn(TransitState.ArrivalConfirmed, true);
        uint256 received = sys.spokeVault.cumulativeReceived();
        uint256 unknown = received > confirmed ? received - confirmed : 0;
        assertEq(
            sys.core.shareAssets(),
            total > unknown ? total - unknown : 0,
            "DEC-104: a transfer is in no base, or in two"
        );
    }

    /// DEC-104 at rest: once every Across deposit is filled or refunded, every refund recognized and a fresh report
    /// delivered, (1) the fund's ledgers hold exactly the principal that went in less what went out (nothing lost in
    /// an escrow, in `unmatchedArrivals` or between two states), and (2) Share Assets equal those ledgers less the
    /// value of unknown origin strangers bridged to the spoke (nothing counted twice).
    function invariant_DEC104_atRestNothingIsCountedTwiceOrLost() public {
        handler.settle();

        assertEq(
            handler.principalHeld() + handler.operatingCashHeld() + handler.strandedRefunds(),
            handler.principalIn() - handler.principalOut(),
            "DEC-104: principal lost or created across transit states"
        );

        uint256 held = handler.principalHeld() + handler.confirmedWithoutFill();
        uint256 unknown = handler.strangerSpokePrincipal();
        assertEq(sys.core.shareAssets(), held > unknown ? held - unknown : 0, "DEC-104: Share Assets at rest");
        assertEq(
            sys.core.unmatchedArrivals(),
            handler.strangerHubArrivals(),
            "OQ-01: only fabricated arrivals are held apart"
        );
        assertEq(handler.pendingPrincipalReturnLeg(), 0, "nothing in flight home at rest");

        uint256 count = handler.hubSendCount();
        for (uint256 i; i < count; ++i) {
            FundSystemHandler.HubSend memory h = handler.hubSend(i);
            TransitState state = sys.core.transit(h.id).state;
            assertTrue(h.outcome != PENDING, "settlement left a deposit pending");
            if (h.outcome == REFUNDED) {
                assertTrue(
                    h.recognized || (state == TransitState.ArrivalConfirmed && h.strangerListed >= h.amountToArrive),
                    "DEC-066: a refunded transit whose refund cannot be recognized"
                );
            } else if (h.amountToArrive >= 1e6) {
                // OQ-09: a filled transit of at least the listing minimum is confirmed by the next report.
                assertEq(uint8(state), uint8(TransitState.ArrivalConfirmed), "DEC-090: filled transit not confirmed");
            }
        }
        count = handler.homeSendCount();
        for (uint256 i; i < count; ++i) {
            FundSystemHandler.HomeSend memory h = handler.homeSend(i);
            assertTrue(h.outcome == FILLED || h.recognized, "DEC-066: a send home neither filled nor refunded");
        }
    }

    /// Scripted walk through both directions, a refund on each side and a stranger, so a change to the handler that
    /// silently stops exercising a path shows up here.
    function test_DEC066_handlerWalksEveryTransitPath() public {
        handler.deposit(0, 100_000e6, false);
        handler.deposit(1, 50_000e6, false);
        handler.allocateToHubVault(20_000e6);
        handler.hubPosition(0, 0, 5000e6, 0);
        handler.hubPosition(5, 0, 1e17, 100e6);
        handler.hubPosition(4, 0, 0, 0);
        handler.forwardIncome(false);
        handler.forwardIncome(true);
        handler.sendToSpoke(40_000e6, 10);
        handler.sendToSpoke(10_000e6, 50);
        handler.fillOnSpoke(0);
        handler.strangerArrivalOnSpoke(3e6, 1, false);
        handler.strangerArrivalOnHub(7e6, false, true);
        handler.publishAndDeliverReport();
        assertEq(uint8(sys.core.transit(handler.hubSend(0).id).state), uint8(TransitState.ArrivalConfirmed));
        handler.spokePosition(0, 0, 10_000e6, 0);
        handler.spokePosition(5, 0, 1e17, 50e6);
        handler.spokePosition(4, 0, 0, 0);
        handler.spokePosition(1, 0, type(uint256).max, 0);
        handler.sendHome(5000e6, false, 20);
        handler.sendHome(1e6, true, 0);
        handler.sendHome(2000e6, false, 0);
        handler.fillOnHub(0);
        handler.fillOnHub(1);
        handler.warp(7 hours);
        handler.refundHubSend(1);
        handler.refundHomeSend(2);
        handler.publishAndDeliverReport();
        handler.attestExpiry(1);
        handler.recognizeRefundOnHub(1);
        assertEq(uint8(sys.core.transit(handler.hubSend(1).id).state), uint8(TransitState.RefundRecognized));
        handler.deposit(3, 1000e6, true);
        handler.requestPayout(0, 30_000e6, false);
        handler.claimPayout(0, false);
        handler.requestPayout(1, 1000e6, true);
        handler.claimPayout(1, true);
        handler.donate(0, 5e6, 0);
        handler.sweepExcess(0);
        handler.withdrawIncome(0, false);

        string[14] memory paths = [
            "deposit",
            "claimPayout",
            "sendToSpoke",
            "fillOnSpoke",
            "refundHubSend",
            "attestExpiry",
            "recognizeRefundOnHub",
            "sendHome",
            "fillOnHub",
            "refundHomeSend",
            "recognizeRefundOnSpoke",
            "forwardIncome",
            "spokeSwapIncome",
            "sweepExcess"
        ];
        for (uint256 i; i < paths.length; ++i) {
            assertGt(handler.done(bytes32(bytes(paths[i]))), 0, paths[i]);
        }
        invariant_DEC066_booksAreTheSumOfTheirTransits();
        invariant_DEC104_atRestNothingIsCountedTwiceOrLost();
    }

    function _pendingReturnLegBothKinds() internal view returns (uint256 total) {
        if (!sys.receiver.hasReport(0)) return 0;
        (ReportCodec.Report memory r,,) = sys.receiver.latestReport(0);
        uint256 count = handler.homeSendCount();
        for (uint256 i; i < r.inFlightToHub.length; ++i) {
            bool filled;
            for (uint256 j; j < count; ++j) {
                FundSystemHandler.HomeSend memory h = handler.homeSend(j);
                if (h.id == r.inFlightToHub[i].transitId) filled = h.outcome == FILLED;
            }
            if (!filled) total += r.inFlightToHub[i].amount;
        }
    }
}
