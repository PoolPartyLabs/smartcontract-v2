// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";

/// @notice Final whole-tree verification of the integration branch, spoke side. Each test pins a finding by asserting
///         the behaviour its fix established.
contract SpokeVaultFinalVerifyTest is SpokeVaultTestBase {
    bytes32 internal constant ARRIVAL = keccak256("hub transit 1");

    function setUp() public {
        _setUpMocks();
        _deploySpoke();
        _disableOperatingCash();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-066 / QA6 / DEC-063 (final verification finding, fixed): `SpokeCrossChainLib.recognizeRefund` accepted any
    // non-zero escrow balance as the refund. The escrow address is public (`SentToHub`, and deterministic per transit
    // id) and Across refunds an expired deposit 55 to 90 minutes after the fill deadline (DEC-063), so a stranger who
    // sent one base unit to the escrow in that window could move the transit to RefundRecognized and strand the real
    // refund. The spoke now applies the hub's guard (CV-OQ-6): the escrow must hold at least `amountSent`; less is no
    // refund and changes nothing, and once the real refund lands everything is released together, exactly
    // `amountSent` is credited and the surplus is sweepable excess (DEC-080, DEC-101).
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC066_dustDonationBeforeTheAcrossRefundIsNoRefundAndTheRealRefundIsRecognized() public {
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        _willArrive(499e6);
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0);
        Transit memory t = vault.hubBoundTransit(id);
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6);

        // The deposit expires unfilled; the Across refund has not landed yet.
        vm.warp(uint256(t.fillDeadline) + 1);
        usdg.mint(t.escrow, 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, id));
        vault.recognizeRefund(id);
        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.Sent), "the dust moved nothing");
        assertEq(vault.inFlightTransitIds().length, 1, "the transit is still in flight");
        assertEq(vault.buildReport().inFlightToHub.length, 1);
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6);

        // One unit short of the amount sent is still no refund.
        usdg.mint(t.escrow, 500e6 - 2);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, id));
        vault.recognizeRefund(id);

        // The real refund lands; the escrow is released whole and exactly the amount sent is credited.
        spokePool.refund(t.escrow, address(usdg), 500e6);
        vm.expectEmit(address(vault));
        emit ISpokeVault.TransitRefundRecognized(id, 500e6);
        vm.prank(stranger);
        assertEq(vault.recognizeRefund(id), 500e6);
        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.RefundRecognized));
        assertEq(vault.inFlightTransitIds().length, 0);
        assertEq(usdg.balanceOf(t.escrow), 0, "nothing is left in the escrow");
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6, "the ledger is whole again");
        assertEq(vault.sweepExcess(address(usdg)), 500e6 - 1, "the donations are swept, never credited");
    }
}
