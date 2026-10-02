// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice Suspicions checked and refuted (spoke cross-chain side). Each test asserts the CORRECT behaviour.
contract Refute_SpokeCrossChainChecks is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
    }

    /// @notice `buildReport()` (the hub's reader, assembly return) and the payload `report()` publishes agree field
    ///         for field in the same block, with every list non-empty and pruning pending. Ported to main: a send home
    ///         is now listed for `fillDeadline + HUB_BOUND_RETENTION` (3 days, S-3), and `sendToHub` eagerly sweeps,
    ///         so `a` is expired only after a warp with no send or report in between.
    function test_refute_buildReportAndReportDisagree() public {
        vm.startPrank(manager);
        spoke.openPosition(address(spokeAdapter), SPOKE_POOL, 0, 5000e6, "");
        _willArrive(999e6);
        bytes32 a = spoke.sendToHub(1000e6, TransferKind.Principal, 0);
        _willArrive(1998e6);
        vm.warp(block.timestamp + 1 days); // `a` still within retention
        spoke.sendToHub(2000e6, TransferKind.Principal, 0);
        vm.stopPrank();
        _dustArrivals(3);
        // Past `a`'s retention but within `b`'s, with no send or report since, so the eager sweep has not run: `a` is
        // still stored and only `report()`/`buildReport()` filter it out.
        Transit memory ta = spoke.hubBoundTransit(a);
        vm.warp(uint256(ta.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1);
        assertEq(spoke.inFlightTransitIds().length, 2, "the expired send is still stored until the next report/send");

        bytes memory viewed = abi.encode(spoke.buildReport());
        (bytes memory payload,) = _publishPayload();
        ReportCodec.Report memory published = ReportCodec.decode(payload);
        assertEq(keccak256(abi.encode(published)), keccak256(viewed), "identical report");
        assertEq(published.inFlightToHub.length, 1);
        assertTrue(published.inFlightToHub[0].transitId != a);
        assertEq(published.arrivedTransits.length, 4);
        assertEq(published.positions.length, 1);
    }

    /// @notice A genuine hub-to-spoke fill never reverts on the spoke: not with the Operating Cash top-up running, not
    ///         with a full window, not on an id a stranger already credited, not with an Income-kind duplicate.
    function test_refute_genuineFillCanRevertOnTheSpoke() public {
        vm.prank(manager);
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max); // top-up on every operation
        _dustArrivals(256);
        bytes32 t = keccak256("a hub transit id"); // the spoke cannot tell a relayer's genuine fill from any other
        // A stranger credits the real id first, with both kinds.
        usdg.mint(address(spokeAcross), 2e6);
        spokeAcross.fill(
            address(spoke), address(usdg), 1e6, TransitMessage.encode(FUND_ID, HUB, t, TransferKind.Principal)
        );
        spokeAcross.fill(
            address(spoke), address(usdg), 1e6, TransitMessage.encode(FUND_ID, HUB, t, TransferKind.Income)
        );
        _fillOnSpoke(t, 9995e6); // the relayer's genuine fill
        assertEq(spoke.arrivals(t), 9996e6, "credited on top of the stranger's Principal credit");
    }

    /// @notice The ring lists the last 256 listed ids oldest first across wrap-around, each id at most once.
    function test_refute_ringIndexingWrapsWrong() public {
        _dustArrivals(300); // dust ids 1..300
        (bytes memory payload,) = _publishPayload();
        ReportCodec.Report memory r = ReportCodec.decode(payload);
        assertEq(r.arrivedTransits.length, 256);
        // The genuine setUp arrival and dust ids 1..44 were evicted; dust 45..300 remain, oldest first.
        for (uint256 i; i < 256; ++i) {
            assertEq(r.arrivedTransits[i].transitId, keccak256(abi.encode("dust", i + 45)));
            assertEq(r.arrivedTransits[i].amount, 1e6);
        }
    }

    /// @notice A refund is credited once, to the bucket the send debited, and still works after the spoke stopped
    ///         listing the send; a second call, a call before the deadline, and (new on main, S-3) a call before the
    ///         refund has landed in the escrow all revert.
    function test_refute_refundDoubleCreditOrLostAfterPruning() public {
        _willArrive(39_980e6);
        vm.prank(manager);
        bytes32 id = spoke.sendToHub(40_000e6, TransferKind.Principal, 0);
        Transit memory t = spoke.hubBoundTransit(id);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.FillDeadlineNotReached.selector, id, t.fillDeadline));
        spoke.recognizeRefund(id);

        // On main a send is listed for `fillDeadline + HUB_BOUND_RETENTION` (3 days, S-3); report() prunes it only past
        // that, and only when no refund has landed to recognize instead.
        vm.warp(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1);
        _publishPayload();
        assertEq(spoke.inFlightTransitIds().length, 0, "pruned from the list past the retention");

        // Past the deadline but before the refund lands, `recognizeRefund` reverts `NoRefund` (S-3 landed-refund check).
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, id));
        spoke.recognizeRefund(id);

        // Across refunds the escrow (dealt here as the refund leaf would pay it).
        usdg.mint(t.escrow, 40_000e6);
        uint256 before = spoke.unallocatedBalance(address(usdg));
        spoke.recognizeRefund(id);
        assertEq(spoke.unallocatedBalance(address(usdg)) - before, 40_000e6);
        assertEq(uint8(spoke.hubBoundTransit(id).state), uint8(TransitState.RefundRecognized));
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnknownTransit.selector, id));
        spoke.recognizeRefund(id);
    }
}
