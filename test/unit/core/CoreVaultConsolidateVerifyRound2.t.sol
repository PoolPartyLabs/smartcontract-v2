// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Adversarial verification, round 2, of the consolidation stage: the fund-level unknown-origin deduction
///         (OQ-09, CS-OQ-6, DEC-080, DEC-104) and the payout fallback following Idle moves (DEC-021, DEC-056, OQ-10).
///         The OQ-09 spoofed-listing test was written failing against the stage and is the regression of the finding.
contract CoreVaultConsolidateVerifyRound2Test is CoreVaultFixture {
    uint256 internal constant SENT = 1000e6;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6); // Idle 9,975 after the 25 bps flow fee
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / OQ-01 / DEC-066 / DEC-080 (verifier finding, round 2): the hub confirms a hub-to-spoke transit when a
    // report lists its id, whatever amount the report lists. Across passes no depositor, so a stranger can bridge the
    // 1e6 listing minimum to the spoke with a real transit id (public in `SentToSpoke`) and have the spoke list it. The
    // hub then moves the transit to ArrivalConfirmed although nothing of it arrived; if the real deposit expires, its
    // refund sits in the escrow for good (`attestExpiry` and `recognizeRefund` both refuse ArrivalConfirmed) and Share
    // Assets lose `amountSent` permanently, for a 1 USDG cost to the attacker. Expected: a listing below the transit's
    // `amountToArrive` does not confirm it.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_strangerListingOfARealTransitIdBelowItsAmountMustNotConfirmIt() public {
        bytes32 id = _send(SENT, SENT); // Idle 8,975; 1,000 in flight to the spoke
        uint256 assets0 = vault.shareAssets();

        // A stranger's 1 USDG arrival carrying the real id: the spoke credits it and lists the id at 1e6.
        _deliver(_arrived(_spokeReport(1e6, 1e6), id, 1e6));

        assertEq(
            uint8(vault.transit(id).state), uint8(TransitState.Sent), "1e6 listed for a 1,000 transit is no arrival"
        );
        assertEq(vault.inFlightValue(), SENT, "the transit is still in flight");
        assertEq(vault.shareAssets(), assets0, "the stranger's 1 USDG is unknown-origin value, never Share Assets");

        // The real deposit expires and Across refunds the escrow: the fund must be able to recover it.
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        pool.refund(0);
        vault.attestExpiry(id);
        assertEq(vault.recognizeRefund(id), SENT, "the refund reaches Idle");
        assertEq(vault.idle(), 9975e6);
        assertEq(vault.shareAssets(), assets0, "DEC-104: the fund lost nothing to the stranger");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / CS-OQ-6 / DEC-096: a stranded transit (never listed) whose arrival topped up the spoke's Operating Cash.
    // The top-up is outside Share Assets on the confirmed path (unallocated 990, Operating Cash 10), and the fund-level
    // deduction must give the same number on the unconfirmed path: In-flight Value 1,000 minus the shortfall 10.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_strandedTransitWhoseArrivalToppedUpOperatingCashIsCountedOnce() public {
        _send(SENT, SENT); // Idle 8,975
        ReportCodec.Report memory r = _spokeReport(990e6, SENT); // 10 went to Operating Cash on arrival
        r.operatingCash = 10e6;
        _deliver(r);

        assertEq(vault.inFlightValue(), SENT, "never confirmed: still in flight");
        (uint256 spokeValue,,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, 0, "the spoke's principal is all of unknown origin");
        assertEq(vault.shareAssets(), 8975e6 + 990e6, "counted once, net of the Operating Cash top-up");
        assertEq(vault.grossAssets(), 8975e6 + 990e6 + 10e6, "DEC-098: Gross Assets add the spoke's Operating Cash");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / CS-OQ-6 / DEC-066: a stranded transit is attestable through the deadline plus report lifetime path, so
    // it does not keep its Spoke Cap for good (the OQ-09 and CS-OQ-6 rows say it does): the cap is released at the
    // attested expiry, In-flight Value keeps the transit and the fund-level deduction keeps it counted once; the
    // escrow holds no refund, so `recognizeRefund` reverts and the transit stays ExpiryAttested.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_strandedTransitReleasesItsSpokeCapAtTheTimePathExpiryAndStaysCountedOnce() public {
        bytes32 id = _send(SENT, SENT);
        _deliver(_spokeReport(SENT, SENT)); // credited by the spoke, never listed
        (, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(inFlightSent, SENT, "holds the Spoke Cap while Sent");

        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
        (, inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(inFlightSent, 0, "the Spoke Cap is released by the time-path attestation");
        assertEq(vault.inFlightValue(), SENT, "QB11: In-flight Value keeps the transit");
        assertEq(vault.shareAssets(), 9975e6, "counted once through the fund-level deduction");

        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);
        assertEq(vault.shareAssets(), 9975e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-021 / DEC-056 / OQ-10 / DEC-105: the second `_priceClaim` after the automatic unwind runs under the fallback
    // too. The unwind proceeds reach Idle through `returnToIdle`, which lowers the last hub value by the same amount,
    // so the fallback prices the claim at Idle plus what the hub still holds, never at Idle plus the stale value.
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC021_hubValueFallbackFollowsThePayoutUnwindSinceTheLastValuation() public {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(SENT);
        hubVault.moveToPosition(SENT); // the hub Spoke Vault holds a 1,000 USDC position
        _deposit(bob, 1000e6); // last successful valuation: lastHubValue = 1,000
        uint256 idle0 = vault.idle();
        assertEq(vault.shareAssets(), idle0 + SENT);

        hubVault.setBuildReverts(true);
        _request(alice, 9975e6, ICoreVault.PayoutMode.Instant); // above Free Idle: the unwind runs
        ICoreVault.PayoutReceipt memory r = _claim(alice);

        assertGt(r.unwindProceeds, 0, "the unwind moved USDC to Idle");
        assertEq(hubVault.positionPrincipal(), SENT - r.unwindProceeds);
        assertEq(r.shareAssets, idle0 + SENT, "priced after the unwind at Idle plus what the hub still holds");
    }
}
