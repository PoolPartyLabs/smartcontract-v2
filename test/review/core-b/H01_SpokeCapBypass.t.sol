// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreBCrossChainFixture} from "./CoreBCrossChainFixture.sol";

/// @notice Review port of core-b H01, consolidated finding H-03 (register S-13). On `e5c778a` an expiry attested on
///         time alone (`fillDeadline + maxReportAge`, no report) released the transit's `inFlightSent` although it had
///         arrived, so the arrived value was in no term of the cap and the manager sent the cap again and again (the
///         spoke held 3x its cap while the check read 0). Since S-13 only a report's proof releases the cap; a
///         time-path attestation sets `spokeCapHeld` until the arrival is confirmed or the refund recognized.
/// @dev Adaptation to main, interface only: the spoke's first report is delivered before the first send (S-14, the
///      keeper's runbook step after `createSpoke`). Every report is the one the real Robinhood Spoke Vault publishes,
///      delivered through the real ValueReportReceiver.
contract H01_SpokeCapBypass is CoreBCrossChainFixture {
    uint256 internal constant SEND = 100_000e6; // the whole Spoke Cap
    uint256 internal constant ARRIVES = 99_950e6; // 5 bps route fee, inside the 50 bps Mandate maximum

    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        _report(); // S-14: the spoke's first report, before the first send
    }

    /// @dev Variant B (reports flowing, the genuine id evicted by 256 one-USDG arrivals): the time-path attestation
    ///      now keeps the cap, and the second full-cap send is refused.
    function test_REVIEW_H03_evictedArrivalKeepsItsCapAfterATimeAttestation() public {
        bytes32 id = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(id, ARRIVES);
        for (uint256 i; i < ReportCodec.ARRIVAL_WINDOW; ++i) {
            _dustArrival();
        }
        _report();
        ReportCodec.Report memory r = _latest();
        assertEq(r.arrivedTransits.length, ReportCodec.ARRIVAL_WINDOW, "full window");
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            assertTrue(r.arrivedTransits[i].transitId != id, "the genuine id was evicted before any report");
        }

        Transit memory t = vault.transit(id);
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        _refreshPrices();
        _report();
        vm.prank(bob);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
        assertTrue(vault.spokeCapHeld(id), "time path: the cap stays held");

        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub,) = vault.spokeCapUsage(0);
        console2.log("spoke holds (USDG)      ", spoke.unallocatedBalance(address(usdg)));
        console2.log("cap check: spokeValue   ", spokeValue);
        console2.log("cap check: inFlightSent ", inFlightSent);
        assertEq(spoke.unallocatedBalance(address(usdg)), ARRIVES + 256e6);
        assertEq(spokeValue, 0, "the arrival and the dust are unknown-origin value");
        assertEq(inFlightSent, SEND, "the held transit fills the cap");
        assertEq(inFlightToHub, 0);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, SEND, SEND, SPOKE_CAP));
        vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, SEND, 1, SPOKE_CAP));
        vault.sendToSpoke(0, 1, 0, _quote(1));
    }

    /// @dev Variant A (reports withheld after the first one): the time-path attestation keeps the cap, deposits stop
    ///      once the last report is past its lifetime, and the late report confirms the arrival and turns the held cap
    ///      into spoke value: the cap is never free while the spoke holds the capital.
    function test_REVIEW_H03_withheldReportsKeepTheCapOfArrivedTransits() public {
        bytes32 id = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(id, ARRIVES); // it arrives; nobody delivers a report
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        _refreshPrices();
        vault.attestExpiry(id); // time path
        assertTrue(vault.spokeCapHeld(id));
        assertEq(_capUsed(), SEND, "cap still used by the arrived transit");

        // The fund now has an accepted report past its lifetime: mints stop (on e5c778a they went on).
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        vault.deposit(1000e6, 0);
        vm.stopPrank();

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, SEND, SEND, SPOKE_CAP));
        vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));

        // The report finally arrives: it confirms the arrival, releases the held cap and counts the spoke value.
        _report();
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertFalse(vault.spokeCapHeld(id));
        (uint256 spokeValue, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, ARRIVES);
        assertEq(inFlightSent, 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, ARRIVES, SEND, SPOKE_CAP));
        vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));
    }

    /// @dev Re-attack: the only other release of a held cap is `recognizeRefund`, which needs the escrow to hold the
    ///      whole `amountSent`. A filled transit has no Across refund, so the manager must pay it in: the cap comes back
    ///      only against 100,000 USDC of its own, which lands in Idle, while the arrived USDG stays uncounted.
    function test_REVIEW_H03_releasingAHeldCapCostsTheWholeAmountSent() public {
        bytes32 id = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(id, ARRIVES);
        for (uint256 i; i < ReportCodec.ARRIVAL_WINDOW; ++i) {
            _dustArrival();
        }
        Transit memory t = vault.transit(id);
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        _refreshPrices();
        _report();
        vault.attestExpiry(id);
        uint256 assetsBefore = vault.shareAssets();
        uint256 idleBefore = vault.idle();

        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);

        usdc.mint(t.escrow, SEND - 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);

        usdc.mint(t.escrow, 1); // the manager's own 100,000 USDC
        vault.recognizeRefund(id);
        assertEq(_capUsed(), 0, "cap free again");
        assertEq(vault.idle(), idleBefore + SEND, "only because Idle received the full amount sent");
        assertEq(vault.shareAssets(), assetsBefore + SEND - ARRIVES, "no holder value created or lost");
    }
}
