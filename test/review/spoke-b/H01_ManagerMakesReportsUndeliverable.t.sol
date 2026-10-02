// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice [H-04] (spoke-b report H-01), ported to main; the positions half was fixed afterwards on
///         fix/pp-sc-fix-independent-review (MAX_OPEN_POSITIONS). As ported, PARTIAL. The renewable dust-sends-home brick is FIXED
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

    /// @notice FIXED on fix/pp-sc-fix-independent-review (MAX_OPEN_POSITIONS): main let 200 dust positions make
    ///         every report need 35.98M gas to deliver, freezing the hub's view of the spoke. The 33rd position is now
    ///         refused, and the worst report a manager and a stranger can build together (32 dust positions, 64 Income
    ///         sends home, the whole 256-id arrival window) still delivers in one Arbitrum transaction.
    function test_REVIEW_H04_worstCaseReportStaysDeliverable() public {
        _dustPositions(SpokeVaultTypes.MAX_OPEN_POSITIONS);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(SpokeVaultTypes.OpenPositionLimit.selector, SpokeVaultTypes.MAX_OPEN_POSITIONS)
        );
        spoke.openPosition(address(spokeAdapter), SPOKE_POOL, 0, 1, "");
        _incomeArrival(SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT);
        // WP-10: the manager sends only Principal home (income goes through a collection order, DEC-122).
        _dustSendsHome(SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT, TransferKind.Principal);
        _dustArrivals(256);

        (bytes memory payload, uint64 seq, uint256 reportGas) = _publishMeasured();
        bytes memory vaa = _vaa(payload, seq);
        uint256 snap = vm.snapshotState();
        uint256 needed = _deliverMeasured(vaa) + _intrinsic(vaa);
        vm.revertToState(snap);
        console2.log("payload words             ", payload.length / 32);
        console2.log("report() gas on Robinhood ", reportGas);
        console2.log("worst-case delivery gas   ", needed);
        assertLt(needed, ARBITRUM_MAX_TX_GAS, "the worst report fits in one transaction");
        assertTrue(_fitsInOneTransaction(vaa));
    }

    /// @notice FIXED (S-11): the renewable sends-home brick is gone. The 65th listed send home reverts
    ///         `HubBoundInFlightLimit(64)`, so the manager can never grow a report with dust sends the way e5c778a
    ///         allowed (450 one-unit sends). A real transfer home sits with at most 63 others, well within one
    ///         transaction.
    function test_REVIEW_S11_sendsHomeAreCappedAtSixtyFour() public {
        vm.startPrank(manager);
        for (uint256 i; i < SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT; ++i) {
            spoke.sendToHub(1, TransferKind.Principal, 0);
        }
        assertEq(spoke.inFlightTransitIds().length, 64, "64 sends home listed");
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.HubBoundInFlightLimit.selector, 64));
        spoke.sendToHub(1, TransferKind.Principal, 0);
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
