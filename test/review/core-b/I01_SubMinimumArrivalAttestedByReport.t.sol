// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {CoreBCrossChainFixture} from "./CoreBCrossChainFixture.sol";

/// @notice Review port of core-b I01, consolidated finding I-01 (CS-OQ-6 row; related register entry S-13). The
///         `docs/OPEN-QUESTIONS.md` CS-OQ-6 row still says a hub-to-spoke send below the 1 USDG listing minimum "is
///         attested only through the deadline plus report lifetime path". On main it is still attestable through the
///         REPORT path as soon as a report built after the deadline lands (the spoke never lists it, and an unlisted
///         id in a non-full window proves non-arrival), and since the report path is the one S-13 trusts, the Spoke Cap
///         is released at once for a transit that did arrive. Bounded: one send moves less than 1 USDG outside the cap.
/// @dev Adaptation to main, interface only: the spoke's first report is delivered before the first send (S-14).
contract I01_SubMinimumArrivalAttestedByReport is CoreBCrossChainFixture {
    function test_POC_REVIEW_I01_subMinimumArrivalAttestedRightAfterTheDeadline() public {
        _deposit(alice, 10_000e6);
        _report(); // S-14
        bytes32 id = _sendToSpoke(0.9e6, 0.8996e6);
        _fillOnSpoke(id, 0.8996e6); // it arrives, below MIN_LISTED_ARRIVAL: credited, never listed
        assertEq(_capUsed(), 0.9e6);
        vm.warp(uint256(vault.transit(id).fillDeadline) + 1);
        _refreshPrices();
        _report(); // built after the deadline, window not full, id absent
        vault.attestExpiry(id); // report path: well before fillDeadline + maxReportAge
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
        assertLt(block.timestamp, uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE);
        assertFalse(vault.spokeCapHeld(id), "report path: the cap is released");
        assertEq(_capUsed(), 0, "the arrived 0.8996 USDG is in no term of the cap");
        assertEq(spoke.unallocatedBalance(address(usdg)), 0.8996e6);
    }
}
