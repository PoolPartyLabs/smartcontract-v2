// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";

/// @notice Final whole-tree verification of the integration branch, spoke side. Each test pins a finding by asserting
///         what the code does today, so the suite stays green and a later fix must change the assertion deliberately.
contract SpokeVaultFinalVerifyTest is SpokeVaultTestBase {
    bytes32 internal constant ARRIVAL = keccak256("hub transit 1");

    function setUp() public {
        _setUpMocks();
        _deploySpoke();
        _disableOperatingCash();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-066 / QA6 / DEC-063 (final verification, BLOCKING): `SpokeCrossChainLib.recognizeRefund` accepts any non-zero
    // escrow balance as the refund. The escrow address is public (`SentToHub`, and deterministic per transit id) and
    // Across refunds an expired deposit 55 to 90 minutes after the fill deadline (DEC-063), so a stranger who sends
    // one base unit to the escrow in that window and calls `recognizeRefund` moves the transit to RefundRecognized
    // with one unit credited. The real refund that lands afterwards can never be released: `release` is vault-only
    // and the vault's only path to it requires state Sent. The hub side requires `held >= amountSent` for exactly
    // this reason (CV-OQ-6); the spoke side does not.
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC066_BLOCKING_dustDonationBeforeTheAcrossRefundStrandsTheRealRefundOnTheSpoke() public {
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0, _quote(499e6));
        Transit memory t = vault.hubBoundTransit(id);
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6);

        // The deposit expires unfilled; the Across refund has not landed yet.
        vm.warp(uint256(t.fillDeadline) + 1);
        usdg.mint(t.escrow, 1);
        vm.prank(stranger);
        assertEq(vault.recognizeRefund(id), 1, "one base unit is accepted as the refund");
        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.RefundRecognized));
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6 + 1);
        assertEq(vault.inFlightTransitIds().length, 0, "the transit left the in-flight list");

        // The real refund lands in the escrow and is stranded there for good.
        spokePool.refund(t.escrow, address(usdg), 500e6);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnknownTransit.selector, id));
        vault.recognizeRefund(id);
        assertEq(usdg.balanceOf(t.escrow), 500e6, "the fund's 500 USDG sit in an escrow nothing can release");
        assertEq(vault.sweepExcess(address(usdg)), 0, "and they are not in the vault to be swept");
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6 + 1, "the ledger lost the amount sent");
    }
}
