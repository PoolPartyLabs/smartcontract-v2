// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice [I-03] (spoke-b report I-01), ported to main, STILL_PRESENT (register S-30, Acknowledged as an OQ-09
///         liveness cost). The arrival "window" is the last 256 listings of the fund's whole life, not of a period:
///         once 256 arrivals of at least 1 USDG were ever listed (the fund's own sends included), every later report
///         lists 256 ids, so `nonArrivalProvable`'s report path is off for good and every expiry waits for the time
///         path. docs/OPEN-QUESTIONS.md OQ-09 and ARCHITECTURE §4.2 describe the condition as if a window could drain.
contract I01_ArrivalWindowNeverDrains is SpokeBFixture {
    function _reportNow() internal {
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
    }

    function test_POC_REVIEW_I03_afterTheFunds256thListedArrivalTheReportPathIsOffForGood() public {
        _deposit(alice, 1_000_000e6);
        _dustArrivals(256); // any 256 listed arrivals over the fund's life (here: 1 USDG each)
        _reportNow();

        // Thirty days later, nothing new arrived, yet every report still lists 256 ids.
        vm.warp(block.timestamp + 30 days);
        _refreshPrices();
        bytes32 t = _sendToSpoke(1000e6, 999e6); // never filled
        uint32 deadline = vault.transit(t).fillDeadline;
        vm.warp(uint256(deadline) + 1);
        _refreshPrices();
        _reportNow(); // built after the deadline, does not list t
        assertEq(_latest().arrivedTransits.length, ReportCodec.ARRIVAL_WINDOW, "the window never drains");

        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, t));
        vault.attestExpiry(t);

        vm.warp(uint256(deadline) + MAX_REPORT_AGE + 1); // only the time path remains
        vault.attestExpiry(t);
        assertEq(uint8(vault.transit(t).state), uint8(TransitState.ExpiryAttested));
    }
}
