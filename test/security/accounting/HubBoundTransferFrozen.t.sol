// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @title Regression (security review S-4): a filled transfer home that no accepted report listed is no longer
///        frozen in `unmatchedArrivals`
/// @notice Was PoC `test_POC_hubBoundTransferNeverListedIsFrozenForever` (HIGH, accounting lens): the spoke stopped
///         listing a send home at `fillDeadline + maxReportAge`, so a report outage of that length after a filled send
///         home froze the USDC in the Core Vault outside every value base, with no verb to move it.
///
/// Fix: the spoke keeps listing for `ReportCodec.HUB_BOUND_RETENTION` past the deadline (S-3), so the first report
/// after such an outage credits the arrival; past the retention, `CoreVault.recoverUnlistedArrival` (S-4) credits it to
/// Idle once no report can list it any more. The test replays the outage and asserts the transfer reaches Idle.
contract HubBoundTransferFrozenPoC is AccountingPocFixture {
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant SENT_TO_SPOKE = 50_000e6;
    uint256 internal constant ARRIVES_ON_SPOKE = 49_975e6;
    uint256 internal constant ARRIVES_ON_HUB = 49_950e6;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_SEC_S4_hubBoundTransferNeverListedInTheOldWindowIsCredited() public {
        _deposit(alice, DEPOSIT);
        bytes32 outbound = _sendToSpoke(SENT_TO_SPOKE, ARRIVES_ON_SPOKE);
        _fillOnSpoke(outbound, ARRIVES_ON_SPOKE);
        _reportAndDeliver();
        uint256 idleBefore = core.idle();
        uint256 aliceBefore = _valueOf(alice);

        bytes32 home = _sendHome(ARRIVES_ON_SPOKE, ARRIVES_ON_HUB, TransferKind.Principal);
        uint256 sentAt = block.timestamp;
        vm.warp(sentAt + 60);
        _fillOnHub(home, ARRIVES_ON_HUB, TransferKind.Principal);
        assertEq(core.unmatchedArrivals(), ARRIVES_ON_HUB, "arrival parked until a report lists it");

        // The listing report is lost to an outage of fillDeadline + maxReportAge.
        vm.warp(sentAt + 120);
        bytes memory listingVaa = _publishReport();
        vm.warp(sentAt + FILL_DEADLINE + MAX_REPORT_AGE + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IValueReportReceiver.ReportTooOld.selector, block.timestamp - (sentAt + 120), MAX_REPORT_AGE
            )
        );
        receiver.deliver(listingVaa);

        // Reporting resumes: the spoke still lists the transfer and the hub credits it.
        _reportAndDeliver();
        assertEq(core.unmatchedArrivals(), 0, "S-4: credited");
        assertEq(core.idle(), idleBefore + ARRIVES_ON_HUB, "S-4: in Idle");
        assertEq(core.sweepExcess(address(usdc)), 0, "nothing left over");
        assertApproxEqAbs(_valueOf(alice) + (ARRIVES_ON_SPOKE - ARRIVES_ON_HUB), aliceBefore, 1e6, "only the fee lost");

        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, home));
        spokeVault.recognizeRefund(home);
        Transit memory t = spokeVault.hubBoundTransit(home);
        assertEq(uint8(t.state), uint8(TransitState.Sent));
    }
}
