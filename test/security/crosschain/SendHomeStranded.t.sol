// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Regression (security review S-4): a transfer home is no longer lost when no report listing it is accepted
///        in time
/// @notice Was PoC `test_POC_sendHomeStrandedWithoutListingReport` (high, cross-chain lens): the spoke listed a send
///         home only until `fillDeadline + maxReportAge` and the hub credits an arrival only against a listing, so a
///         report outage of about 6.5 hours after a filled send home left the USDC in `unmatchedArrivals` for good
///         (40% of the fund here).
///
/// Fix: the spoke now lists a send home for `ReportCodec.HUB_BOUND_RETENTION` past its deadline (S-3), so an outage of
/// that length only delays the credit; and past that window `CoreVault.recoverUnlistedArrival` (S-4) credits the
/// held-apart arrival to Idle once no report can list it any more. Both tests assert the loss no longer happens.
contract SendHomeStrandedPoC is CrossChainFixture {
    function test_SEC_S4_outageOfTheOldWindowNoLongerStrandsTheSendHome() public {
        _deposit(alice, 100_000e6);
        uint256 aliceShares = shares.balanceOf(alice);
        (bytes32 outbound, uint256 outboundDeposit) = _sendToSpoke(50_000e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        assertEq(uint8(core.transit(outbound).state), uint8(TransitState.ArrivalConfirmed));
        uint256 idleBefore = core.idle();

        (, uint256 homeDeposit) = _sendToHub(40_000e6, TransferKind.Principal);
        uint256 homeArrives = 40_000e6 - _ruleFee(40_000e6); // DEC-162: the Across adapter's amount
        skip(120);
        _fillOnHub(homeDeposit);
        assertEq(core.unmatchedArrivals(), homeArrives, "held apart until a report lists it");

        // The report that lists it is lost to the outage, which lasts until fillDeadline + maxReportAge has passed.
        uint256 listingReport = _publishReport();
        skip(FILL_DEADLINE + MAX_REPORT_AGE + 1);
        bytes memory lateVaa = _vaa(listingReport);
        vm.expectPartialRevert(IValueReportReceiver.ReportTooOld.selector);
        receiver.deliver(lateVaa);

        // Reports flow again: the spoke still lists the send home, so the hub credits it.
        _reportAndDeliver(900);
        assertEq(core.unmatchedArrivals(), 0, "S-4: credited on the first report after the outage");
        assertEq(core.idle(), idleBefore + homeArrives, "S-4: in Idle");
        // The manager's seed share (DEC-127) bears 1/99,751 of the two bridge fees (DEC-162).
        uint256 fees = _ruleFee(50_000e6) + _ruleFee(40_000e6);
        assertApproxEqAbs(
            aliceShares * core.sharePrice() / 1e36,
            100_000e6 - 250e6 - fees + fees / 99_751,
            1,
            "S-4: only the two bridge fees lost"
        );
    }

    function test_SEC_S4_outageBeyondTheRetentionIsRecoveredAfterTheDelay() public {
        _deposit(alice, 100_000e6);
        uint256 aliceShares = shares.balanceOf(alice);
        (, uint256 outboundDeposit) = _sendToSpoke(50_000e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        uint256 idleBefore = core.idle();

        (bytes32 homeTransit, uint256 homeDeposit) = _sendToHub(40_000e6, TransferKind.Principal);
        uint256 homeArrives = 40_000e6 - _ruleFee(40_000e6); // DEC-162: the Across adapter's amount
        skip(120);
        _fillOnHub(homeDeposit);
        uint256 filledAt = block.timestamp;

        // Cross-check of the independent review: while the hub's latest report predates the arrival it still counts
        // the 40,000 on the spoke, so recovering now would count them twice; recovery is refused, at any delay.
        skip(FILL_DEADLINE + 3 days + MAX_REPORT_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSignature(
                "RecoveryNotReady(bytes32,uint256)", homeTransit, filledAt + uint256(MAX_REPORT_AGE)
            )
        );
        core.recoverUnlistedArrival(0, homeTransit);

        // Reports flow again once the spoke has stopped listing the send home: built after the arrival, it no longer
        // lists it nor counts it on the spoke, so recovery opens at once.
        _reportAndDeliver(900);
        assertEq(core.unmatchedArrivals(), homeArrives, "no report lists it any more");
        vm.prank(attacker);
        assertEq(core.recoverUnlistedArrival(0, homeTransit), homeArrives, "S-4: anyone recovers it");
        assertEq(core.unmatchedArrivals(), 0);
        assertEq(core.idle(), idleBefore + homeArrives, "S-4: in Idle");
        _reportAndDeliver(900);
        // The manager's seed share (DEC-127) bears 1/99,751 of the two bridge fees (DEC-162).
        uint256 fees = _ruleFee(50_000e6) + _ruleFee(40_000e6);
        assertApproxEqAbs(
            aliceShares * core.sharePrice() / 1e36,
            100_000e6 - 250e6 - fees + fees / 99_751,
            1,
            "S-4: only the two bridge fees lost"
        );

        vm.expectRevert(abi.encodeWithSignature("NothingToRecover(bytes32)", homeTransit));
        core.recoverUnlistedArrival(0, homeTransit);
    }
}
