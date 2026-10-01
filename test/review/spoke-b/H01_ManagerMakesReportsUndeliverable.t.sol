// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice [H-04] (spoke-b report H-01), ported to main. PARTIAL. The renewable dust-sends-home brick is FIXED
///         (register S-11: `sendToHub` reverts `HubBoundInFlightLimit` at 64 listed sends), but the persistent
///         dust-positions brick is STILL_PRESENT: the position registry is still unbounded, so the manager can grow a
///         report past what one Arbitrum transaction (32,000,000 gas) can deliver, after which deposits close on
///         staleness while payouts keep pricing the spoke on the frozen report. e5c778a: 145 positions bricked
///         delivery; on main delivery is cheaper per position (S-11 added no hash, but the threshold moved up) so it
///         takes more.
contract H01_ManagerMakesReportsUndeliverable is SpokeBFixture {
    uint256 internal constant ARBITRUM_MAX_TX_GAS = 32_000_000;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq)); // the fund's last accepted report: 99,950 USDG on the spoke
    }

    /// @dev Deliverable within one Arbitrum transaction? Intrinsic cost (base + calldata) is taken out of the budget.
    function _fitsInOneTransaction(bytes memory vaa) internal returns (bool) {
        return _deliverWithGas(vaa, ARBITRUM_MAX_TX_GAS - _intrinsic(vaa));
    }

    /// @notice STILL_PRESENT: 200 positions of one USDG base unit each. Every later report is undeliverable for as
    ///         long as the manager keeps them open; the manager decides when reporting resumes.
    function test_POC_REVIEW_H04_dustPositionsFreezeReportDeliveryForGood() public {
        uint256 reportsBefore = receiver.lastReportSequence(0);

        // 1. The manager opens 200 dust positions (cost: 200 USDG base units, i.e. 0.0002 USDG, plus Robinhood gas).
        //    Positions are still uncapped on main (S-11 bounds sends home only).
        _dustPositions(200);

        // 2. Anyone can still publish on Robinhood...
        (bytes memory payload, uint64 seq, uint256 reportGas) = _publishMeasured();
        bytes memory vaa = _vaa(payload, seq);
        console2.log("payload words             ", payload.length / 32);
        console2.log("report() gas on Robinhood ", reportGas);
        assertLt(reportGas, ARBITRUM_MAX_TX_GAS, "publishing still works");

        // 3. ...but no keeper can deliver it within one transaction on Arbitrum.
        assertFalse(_fitsInOneTransaction(vaa), "delivery needs more than 32M gas");
        uint256 snap = vm.snapshotState();
        uint256 needed = _deliverMeasured(vaa) + _intrinsic(vaa);
        vm.revertToState(snap);
        console2.log("gas a delivery would need ", needed);
        assertGt(needed, ARBITRUM_MAX_TX_GAS);

        // 4. After one report lifetime, deposits close for everyone.
        vm.warp(block.timestamp + MAX_REPORT_AGE + 1);
        _refreshPrices();
        usdc.mint(bob, 10_000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 10_000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        vault.deposit(10_000e6, 0);
        vm.stopPrank();

        // 5. A day later, any fresh report is still undeliverable: nothing expires on its own.
        for (uint256 i; i < 4; ++i) {
            vm.warp(block.timestamp + 6 hours);
            _refreshPrices();
            (payload, seq,) = _publishMeasured();
            assertFalse(_fitsInOneTransaction(_vaa(payload, seq)));
        }
        assertEq(receiver.lastReportSequence(0), reportsBefore, "the hub never accepts another report");

        // 6. Payouts keep working, priced on the frozen report (a day old, 99,950 USDG of spoke principal).
        vm.prank(alice);
        vault.requestPayout(10_000e6, ICoreVault.PayoutMode.Instant);
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory receipt = vault.claimPayout("");
        assertGt(receipt.sharesBurned, 0, "an Idle-paid payout still executes");
        assertEq(receipt.shareAssets, 997_450e6, "priced on the day-old report the hub still holds");
    }

    /// @notice FIXED (S-11): the renewable sends-home brick is gone. The 65th listed send home reverts
    ///         `HubBoundInFlightLimit(64)`, so the manager can never grow a report with dust sends the way e5c778a
    ///         allowed (450 one-unit sends). A real transfer home sits with at most 63 others, well within one
    ///         transaction.
    function test_REVIEW_S11_sendsHomeAreCappedAtSixtyFour() public {
        BridgeQuote memory q = BridgeQuote(1, uint32(block.timestamp), 0, address(0));
        vm.startPrank(manager);
        for (uint256 i; i < SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT; ++i) {
            spoke.sendToHub(1, TransferKind.Principal, 0, q);
        }
        assertEq(spoke.inFlightTransitIds().length, 64, "64 sends home listed");
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.HubBoundInFlightLimit.selector, 64));
        spoke.sendToHub(1, TransferKind.Principal, 0, q);
        vm.stopPrank();

        // A report that lists the whole 64-send window still delivers in one transaction.
        (bytes memory payload, uint64 seq,) = _publishMeasured();
        ReportCodec.Report memory r = ReportCodec.decode(payload);
        assertEq(r.inFlightToHub.length, 64);
        assertTrue(_fitsInOneTransaction(_vaa(payload, seq)), "a full send-home window is deliverable");
    }

    /// @notice Who can push what: a stranger alone (256 arrivals of 1 USDG, the whole listed window) stays far below
    ///         the limit. Unchanged on main.
    function test_POC_REVIEW_H04_strangerArrivalsAloneStayDeliverable() public {
        _dustArrivals(256);
        (bytes memory payload, uint64 seq,) = _publishMeasured();
        assertTrue(_fitsInOneTransaction(_vaa(payload, seq)), "256 listed arrivals alone fit");
    }
}
