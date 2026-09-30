// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @title PoC: a filled transfer home that no accepted report listed is frozen in the Core Vault for good
/// @notice Severity: HIGH (permanent loss of fund principal, no attacker needed, only a reporting outage).
///
/// Attack / failure sequence (no privileged or malicious actor):
///  1. The Manager sends the spoke's Unallocated Balance home: `SpokeVault.sendToHub(amount, Principal, ...)`. The
///     spoke debits its ledger at once.
///  2. An Across relayer fills on Arbitrum within seconds. `CoreVault.handleV3AcrossMessage` finds no report listing
///     that transit id yet, so `CoreVaultLogic.receiveHubBound` parks the USDC in `unmatchedArrivals` ("held apart
///     until a report lists the transfer", DEC-080, OQ-01). This is the NORMAL order of events: a finalized report
///     takes 15 to 20 minutes (DEC-086), an Across fill takes seconds.
///  3. The report path is down for `fillDeadline + maxReportAge` (6 h 26 min): the keeper (the API, which DEC-002 and
///     DEC-052 say is never an authority and whose failure must only be a denial of service), the Wormhole guardians
///     for the spoke chain, or the spoke's batch posting (a report older than `maxReportAge` at delivery is rejected
///     with `ReportTooOld`, so late VAAs do not help).
///  4. From then on `SpokeCrossChainLib._stillInFlight` is false ("presumed filled", OQ-09), so NO later report ever
///     lists the id in `inFlightToHub`. `CoreVaultLogic._matchReturnLeg` is the only code that releases a pending
///     arrival and it only walks that list, so the USDC stays in `unmatchedArrivals` forever: outside Idle, outside
///     every value base (DEC-104 violated: a recognized unit of value sits in no base), and not sweepable
///     (`CoreVaultBase._ledger` counts `unmatchedArrivals`).
///
/// Impact: the whole transfer (here half of the fund) is lost to the Shareholders. The Share Price drops by that
/// amount permanently, the USDC is physically in an immutable contract with no verb that can move it (DEC-058: no
/// upgrade). Transfers home are most likely exactly when infrastructure is stressed (the Manager repatriates value to
/// serve payouts while mints are closed).
///
/// Fix: never drop a hub-bound transit from the report on a timer. Keep listing it until the hub has acknowledged
/// it (or until its refund is recognized), or list it under a separate, permanent "presumed filled" section the hub
/// can still match, so `_matchReturnLeg` eventually credits the pending arrival. Alternatively give the hub a
/// permissionless `matchPending(spokeIndex, transitId)` that accepts the spoke's `cumulativeSentHome` /
/// a per-id `hubBoundTransit` proof carried by any later report.
contract HubBoundTransferFrozenPoC is AccountingPocFixture {
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant SENT_TO_SPOKE = 50_000e6;
    uint256 internal constant ARRIVES_ON_SPOKE = 49_975e6;
    uint256 internal constant ARRIVES_ON_HUB = 49_950e6;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_POC_hubBoundTransferNeverListedIsFrozenForever() public {
        // Alice funds the fund; the Manager works half of it on Robinhood Chain; the hub confirms the arrival.
        _deposit(alice, DEPOSIT);
        bytes32 outbound = _sendToSpoke(SENT_TO_SPOKE, ARRIVES_ON_SPOKE);
        _fillOnSpoke(outbound, ARRIVES_ON_SPOKE);
        _reportAndDeliver();
        uint256 idleBefore = core.idle();
        uint256 assetsBefore = core.shareAssets();
        assertEq(idleBefore, 49_750e6, "Idle after the send");
        assertEq(assetsBefore, idleBefore + ARRIVES_ON_SPOKE, "Share Assets: Idle plus the spoke's Unallocated Balance");
        uint256 aliceBefore = _valueOf(alice);

        // 1. The Manager brings the spoke's whole Unallocated Balance home.
        bytes32 home = _sendHome(ARRIVES_ON_SPOKE, ARRIVES_ON_HUB, TransferKind.Principal);
        uint256 sentAt = block.timestamp;
        assertEq(spokeVault.unallocatedBalance(address(usdg)), 0, "the spoke debited its ledger");

        // 2. The relayer fills on Arbitrum one minute later: no report lists the id yet, so it is held apart.
        vm.warp(sentAt + 60);
        _fillOnHub(home, ARRIVES_ON_HUB, TransferKind.Principal);
        assertEq(core.unmatchedArrivals(), ARRIVES_ON_HUB, "arrival parked until a report lists it");
        assertEq(core.idle(), idleBefore, "not in Idle");

        // 3. A report that DOES list the transfer is published, but its VAA only becomes deliverable after the outage.
        vm.warp(sentAt + 120);
        bytes memory listingVaa = _publishReport();
        assertEq(spokeVault.inFlightTransitIds().length, 1, "listed while the spoke still counts it in flight");

        vm.warp(sentAt + FILL_DEADLINE + MAX_REPORT_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IValueReportReceiver.ReportTooOld.selector, block.timestamp - (sentAt + 120), MAX_REPORT_AGE
            )
        );
        receiver.deliver(listingVaa);

        // 4. Reporting resumes. The spoke now presumes the transfer filled and never lists it again.
        _reportAndDeliver();
        assertEq(spokeVault.inFlightTransitIds().length, 0, "dropped from the report for good");
        Transit memory t = spokeVault.hubBoundTransit(home);
        assertEq(uint8(t.state), uint8(TransitState.Sent), "nothing on the spoke can list it again");

        // The USDC is in the Core Vault, in no value base, and no verb moves it.
        assertEq(core.unmatchedArrivals(), ARRIVES_ON_HUB, "still held apart");
        assertEq(core.idle(), idleBefore, "never reached Idle");
        assertEq(usdc.balanceOf(address(core)), idleBefore + ARRIVES_ON_HUB, "physically in the Core Vault");
        assertEq(core.shareAssets(), idleBefore, "DEC-104: the transfer is in no base");
        assertEq(core.sweepExcess(address(usdc)), 0, "the garbage collector cannot recover it");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, home));
        spokeVault.recognizeRefund(home);

        // Any number of later reports changes nothing.
        vm.warp(block.timestamp + 1 days);
        _reportAndDeliver();
        _reportAndDeliver();
        assertEq(core.unmatchedArrivals(), ARRIVES_ON_HUB, "frozen forever");
        assertEq(core.shareAssets(), idleBefore, "Share Assets never recover");

        // Alice lost half of her position with no market loss anywhere.
        uint256 aliceAfter = _valueOf(alice);
        assertEq(aliceBefore - aliceAfter, ARRIVES_ON_SPOKE, "the Shareholders bear the whole transfer");
        assertLt(aliceAfter * 2, aliceBefore + 1e6, "about half of the fund is gone");
    }
}
