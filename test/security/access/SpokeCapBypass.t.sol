// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @title Regression (security review S-13): a time-based expiry of a filled transit no longer releases the Spoke Cap
/// @notice Was PoC `test_POC_attestedExpiryOfAFilledTransitLetsTheManagerSendTheCapTwice` (medium, access lens):
///         `attestExpiry`'s deadline-plus-lifetime path needs no evidence and released `inFlightSent`, so after a
///         6.5 h report outage the manager attested its own filled transit and sent the whole cap again (200,000 USDC
///         of principal on a spoke capped at 100,000).
/// @notice FIX (S-13, `CoreVaultLogic.attestExpiry`): only a report's proof of non-arrival releases the Spoke Cap at
///         the attestation; on the time path alone the cap stays held (`spokeCapHeld`) until the arrival is confirmed
///         or the refund recognized. The test asserts the second send now FAILS and the cap is released exactly once,
///         when the late report confirms the arrival.
/// @dev Real Core Vault and CoreVaultLogic on the repository's unit fixture. SPOKE_CAP is 100,000 USDC.
contract SpokeCapBypassPoC is CoreVaultFixture {
    function test_SEC_S13_timeBasedExpiryOfAFilledTransitNoLongerReleasesTheSpokeCap() public {
        _deposit(alice, 300_000e6);
        uint256 assetsBefore = vault.shareAssets();

        bytes32 first = _send(SPOKE_CAP, SPOKE_CAP);

        // No report is accepted on the hub for 6 h 27 min; anyone attests the expiry by time.
        vm.warp(block.timestamp + 6 hours + MAX_REPORT_AGE + 1);
        vault.attestExpiry(first);
        assertEq(uint8(vault.transit(first).state), uint8(TransitState.ExpiryAttested));
        assertTrue(vault.spokeCapHeld(first), "S-13: the time path keeps the cap");
        (uint256 spokeValue, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue + inFlightSent, SPOKE_CAP, "S-13: the cap still reads full");
        assertEq(vault.shareAssets(), assetsBefore);

        // The manager cannot send the cap again.
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, SPOKE_CAP, SPOKE_CAP, SPOKE_CAP)
        );
        vault.sendToSpoke(0, SPOKE_CAP, 0, _quote(SPOKE_CAP));

        // The spoke's late report lists the arrival: confirmed, the cap is now spoke value, released once.
        ReportCodec.Report memory r = _spokeReport(SPOKE_CAP, SPOKE_CAP);
        r.arrivedTransits = new ReportCodec.TransitAmount[](1);
        r.arrivedTransits[0] = ReportCodec.TransitAmount(first, SPOKE_CAP);
        _deliver(r);
        assertEq(uint8(vault.transit(first).state), uint8(TransitState.ArrivalConfirmed));
        assertFalse(vault.spokeCapHeld(first));
        uint256 cap;
        (spokeValue, inFlightSent,, cap) = vault.spokeCapUsage(0);
        assertEq(spokeValue, SPOKE_CAP);
        assertEq(inFlightSent, 0);
        assertLe(spokeValue + inFlightSent, cap, "S-13: the Spoke Cap holds");
        assertEq(vault.shareAssets(), assetsBefore);
    }

    /// @dev S-13: a refund proves non-arrival, so recognizing it releases a cap the time path kept.
    function test_SEC_S13_refundReleasesACapTheTimePathKept() public {
        _deposit(alice, 300_000e6);
        bytes32 id = _send(SPOKE_CAP, SPOKE_CAP);
        vm.warp(block.timestamp + 6 hours + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        usdc.mint(vault.transit(id).escrow, SPOKE_CAP);
        vault.recognizeRefund(id);
        (, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(inFlightSent, 0, "S-13: released by the refund");
        assertFalse(vault.spokeCapHeld(id));
    }
}
