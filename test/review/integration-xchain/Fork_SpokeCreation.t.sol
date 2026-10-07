// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState} from "../../../src/interfaces/FundTypes.sol";
import {XChainBase, LiveRelayData} from "./XChainBase.sol";

/// @notice Review port of integration-xchain `Fork_SpokeCreation`: consolidated H-05 (report 07 H-01, register S-14: a
///         send made before `createSpoke`, filled by the live Robinhood SpokePool to an address without code) and H-06
///         (report 07 H-02, register S-6 with S-9 and S-14: a spoke created from a Mandate that differs from the hub's),
///         on the real FundFactory, both forks. On `e5c778a` the first left 3,998.40 USDG counted in Share Assets for
///         good while the Protocol Recipient swept them (Ana exited with 8,797.07 against at most 5,975.00 of real
///         assets); the second let a 10,000 bps spoke send 3,988.40 home for an output of 1 unit, repaid to the
///         manager's relayer through the live refund leaf.
/// @dev Adaptation to the fix branch, interface only: report v3 (`mandateHash`), no exclusivity, the bridge-fee cap.
contract Fork_SpokeCreation is XChainBase {
    uint256 internal constant ARRIVES = BRIDGE_AMOUNT - BRIDGE_FEE; // 3,996.77 USDG (DEC-162: 0.08% plus 0.03)

    /// @notice FIXED (S-14). Before `createSpoke` the hub has no accepted report from the spoke, so `sendToSpoke`
    ///         reverts `SpokeNotReporting` and nothing leaves Idle; no report can exist, since the Wormhole emitter is the
    ///         predicted Spoke Vault, which has no code. Once the spoke exists and its first report is delivered (1,000 s
    ///         after publication, through both real Cores), the same send is filled by the live pool and confirmed.
    function test_REVIEW_H05_sendBeforeCreateSpokeIsRefused() public {
        _createForks();
        _createHub(_plan());
        _phase2AnaDeposits(); // Idle 9,975
        _onRobinhood();
        assertEq(predictedSpokeVault.code.length, 0, "createSpoke has not run");
        _onArbitrum();
        assertFalse(receiver.hasReport(0));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, "");
        assertEq(core.idle(), MANAGER_SEED_IDLE + 9975e6, "nothing left Idle");
        assertEq(core.inFlightValue(), 0);

        _advance(5 minutes);
        assertEq(_createSpokeFrom(_plan()), mandateHash, "the hub's own Mandate");
        _report(); // the keeper's first report of the new spoke
        assertTrue(receiver.hasReport(0));
        (bytes32 id, LiveRelayData memory relay) = _sendToSpoke(BRIDGE_AMOUNT);
        assertEq(relay.recipient, bytes32(uint256(uint160(predictedSpokeVault))), "the Mandate's predicted vault");
        _fillOnRobinhood(relay, relayer);
        assertEq(spokeVault.cumulativeReceived(), ARRIVES, "the handler ran: credited");
        _report();
        assertEq(uint8(core.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertEq(core.shareAssets(), MANAGER_SEED_IDLE + 9975e6 - BRIDGE_FEE - SPOKE_OPERATING_CASH_TOP_UP);
    }

    /// @notice FIXED (S-9, S-6, S-14). The review's divergent Mandate (`maxBridgeFeeBps` 10,000) cannot be written
    ///         any more (DEC-156: Mandate v2 has no bridge fee bound; the Across adapter prices every send). A spoke
    ///         Mandate that diverges from the hub's (here a Spoke Cap without limit) creates a spoke at the address the
    ///         hub names, but its reports carry its own `mandateHash` and the Core Vault rejects them (`WrongMandate`,
    ///         the whole delivery reverts), so the hub never accepts a report from it and never funds it.
    function test_REVIEW_H06_divergentSpokeMandateIsRejectedAndNeverFunded() public {
        _createForks();
        _createHub(_plan()); // what investors read on the hub
        _phase2AnaDeposits();

        FundPlan memory other = _plan();
        other.spokeCap = type(uint256).max;
        bytes32 spokeHash = _createSpokeFrom(other);
        assertTrue(spokeHash != mandateHash, "rules the hub never showed");
        assertEq(spokeVault.mandateHash(), spokeHash);

        (bytes memory payload, uint64 whSeq) = _publish();
        _onArbitrum();
        _advance(FINALITY);
        bytes memory vaa = _vaa(payload, whSeq);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.WrongMandate.selector, spokeHash));
        receiver.deliver(vaa);
        assertFalse(receiver.hasReport(0), "the hub accepts no report of the divergent spoke");

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        core.sendToSpoke(0, BRIDGE_AMOUNT, 0, "");
        assertEq(core.shareAssets(), MANAGER_SEED_IDLE + 9975e6, "the capital never leaves the hub");
    }
}
