// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreBCrossChainFixture} from "./CoreBCrossChainFixture.sol";

/// @notice Review port of core-b H02, consolidated finding H-02 (register S-4, with S-3). On `e5c778a` a genuine
///         spoke-to-hub transfer that was filled stayed in `unmatchedArrivals` for good when no report listing it was
///         accepted before `fillDeadline + maxReportAge` (99,900 USDC, Share Assets -10%). Since S-3 the spoke lists a
///         send home for `HUB_BOUND_RETENTION` (3 days) after its deadline, and since S-4 anyone recovers an arrival no
///         report ever listed once `pendingSince + 6 h + 3 days + 2 x maxReportAge` has passed.
/// @dev Adaptation to main, interface only: the spoke's first report is delivered before the first send (S-14).
contract H02_ReturnTransferStrandedInUnmatched is CoreBCrossChainFixture {
    uint256 internal constant SEND = 100_000e6;
    uint256 internal constant ARRIVES = 99_950e6;
    uint256 internal constant HOME_OUT = 99_900e6; // what the send home delivers in USDC

    bytes32 internal home;
    uint256 internal assetsBefore;
    uint256 internal filledAt;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        _report(); // S-14: the spoke's first report, before the first send
        bytes32 out = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(out, ARRIVES);
        _report(); // confirms the arrival: the spoke holds 99,950 USDG of principal
        assetsBefore = vault.shareAssets();
        assertEq(assetsBefore, 997_450e6);

        // The manager brings the principal home; a relayer fills it on Arbitrum within minutes.
        vm.prank(manager);
        home = spoke.sendToHub(ARRIVES, TransferKind.Principal, 0, _homeQuote(HOME_OUT));
        vm.warp(block.timestamp + 2 minutes);
        filledAt = block.timestamp;
        _fillOnHub(home, HOME_OUT, TransferKind.Principal);
        assertEq(vault.unmatchedArrivals(), HOME_OUT, "held apart until a report lists it (OQ-01)");
    }

    /// @dev The review's outage (no report until `fillDeadline + maxReportAge + 1`) no longer strands anything: the
    ///      spoke still lists the send home and the first report after the outage matches it.
    function test_REVIEW_H02_filledTransferHomeIsMatchedByTheFirstReportAfterTheOutage() public {
        Transit memory t = spoke.hubBoundTransit(home);
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        _refreshPrices();
        _report();
        ReportCodec.Report memory r = _latest();
        assertEq(r.inFlightToHub.length, 1, "still listed");
        assertEq(vault.unmatchedArrivals(), 0, "matched");
        assertEq(vault.shareAssets(), assetsBefore - (ARRIVES - HOME_OUT), "only the bridge fee is gone");
    }

    /// @dev Re-attack: an outage longer than the retention. The spoke stops listing the send home and the arrival stays
    ///      held apart; since the cross-check fix of S-4, `recoverUnlistedArrival` (permissionless) is refused while the
    ///      hub's latest report predates the arrival (it still counts the transfer on the spoke), whatever the delay,
    ///      and opens at once when a report built after the arrival no longer lists it.
    function test_REVIEW_H02_unlistedArrivalIsRecoveredAfterAMultiDayOutage() public {
        Transit memory t = spoke.hubBoundTransit(home);
        vm.warp(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1);
        _refreshPrices();
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.RecoveryNotReady.selector, home, filledAt + uint256(MAX_REPORT_AGE))
        );
        vault.recoverUnlistedArrival(0, home);

        _report();
        assertEq(_latest().inFlightToHub.length, 0, "no longer listed");
        assertEq(vault.unmatchedArrivals(), HOME_OUT);
        vm.prank(bob);
        assertEq(vault.recoverUnlistedArrival(0, home), HOME_OUT);
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.shareAssets(), assetsBefore - (ARRIVES - HOME_OUT), "back in Share Assets");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, home));
        vault.recoverUnlistedArrival(0, home);
    }

    /// @dev Residual (narrowed by the cross-check fix of S-4): after an outage longer than `fillDeadline + 3 days`,
    ///      the first report after the retention no longer lists the transfer, so until someone calls the
    ///      permissionless recovery it is in no value base while mints are open. On main the gap lasted until a delay
    ///      ran out (3,295 s here); now recovery opens with that report, so the gap is only what separates the
    ///      delivery from the recovery call. An entrant who lands in between still gains: the keeper should recover
    ///      right after delivering.
    function test_POC_REVIEW_H02_entrantBetweenTheReportAndTheRecoveryIsPricedLow() public {
        Transit memory t = spoke.hubBoundTransit(home);
        vm.warp(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1);
        _refreshPrices();
        _report();
        uint256 assetsInGap = vault.shareAssets();
        assertEq(assetsInGap, 897_500e6, "the transfer is in no value base");

        uint256 minted = _deposit(bob, 100_000e6); // the report is fresh: the mint goes through
        vault.recoverUnlistedArrival(0, home); // open at once now
        uint256 bobValue = minted * vault.sharePrice() / 1e36;
        console2.log("bob paid 100,000; worth after the recovery", bobValue);
        assertEq(bobValue, 109_742_302_202, "an entrant between the delivery and the recovery gains 9.7%");
    }

    /// @dev Control: one report inside the window matches and credits the same arrival to Idle.
    function test_REVIEW_H02_control_oneReportInsideTheWindowCreditsIt() public {
        _report();
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.shareAssets(), assetsBefore - (ARRIVES - HOME_OUT));
    }
}
