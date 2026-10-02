// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";

/// @notice Adversarial verification, round 1, of the final verification fixes on the Spoke Vault: the vault-sized
///         unwind against a position an adapter keeps open with no principal (DEC-056, DEC-068, DEC-069) and the
///         refund guard against a donation at or above the amount sent (DEC-066, DEC-063, QA6).
contract SpokeVaultFinalVerifyRound1Test is SpokeVaultTestBase {
    bytes32 internal constant ARRIVAL = keccak256("hub transit 1");

    function setUp() public {
        _setUpMocks();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-069 / DEC-056 / DEC-068: a close the reserve could not finish leaves a registered key with no principal
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-069, DEC-056, DEC-068 (final verification): when the automatic unwind closes an Aave-like position whose
    /// reserve cannot pay the income, the adapter keeps the key and the vault keeps it registered. A later unwind
    /// visits that key, values it at zero and skips it: no revert, no exit, nothing returned, and the pending income
    /// is still collectable afterwards.
    function test_DEC069_positionKeptOpenWithOnlyPendingIncomeIsSkippedByTheUnwind() public {
        _deployHub();
        usdc.mint(address(core), 10_000e6);
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        (bytes32 uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 400e6, "");
        (bytes32 aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        vm.stopPrank();
        _earnIncome(hubAave, aaveKey, 7e6, 0);
        hubAave.setKeepKeyOnClose(true); // the reserve cannot pay the income: the adapter keeps the key

        // Everything is needed: the Uniswap position closes, the Aave close pays its principal and keeps the key.
        vm.expectEmit(address(vault));
        emit ISpokeVault.PositionDecreased(address(hubAave), aaveKey, IAdapter.Amounts(500e6, 0, 0, 0));
        assertEq(core.unwind(vault, 1000e6, ""), 1000e6);
        assertEq(core.idleReturned(), 1000e6);
        assertEq(vault.positions().length, 1, "the Aave key stays registered while the adapter lists it");
        assertEq(vault.positions()[0].positionKey, aaveKey);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        assertEq(vault.collectedIncome(address(usdc)), 0, "the income is still pending in the adapter");
        (,,,,, bool uniOpen) = hubUni.position(uniKey);
        assertFalse(uniOpen);

        // A later unwind visits the key, values it at zero and skips it.
        vm.expectEmit(address(vault));
        emit ISpokeVaultUnwind.UnwoundForPayout(1e6, 0);
        assertEq(core.unwind(vault, 1e6, ""), 0);
        assertEq(core.idleReturned(), 1000e6, "nothing more reached Idle");
        assertEq(vault.positions().length, 1);
        (, uint256 principal0,, uint256 uncollected0,, bool aaveOpen) = hubAave.position(aaveKey);
        assertTrue(aaveOpen);
        assertEq(principal0, 0);
        assertEq(uncollected0, 7e6, "the unwind collected nothing");

        // The income is still collectable, and the close that empties the key removes it.
        hubAave.setKeepKeyOnClose(false);
        vm.prank(manager);
        vault.closePosition(address(hubAave), aaveKey, "");
        assertEq(vault.positions().length, 0);
        assertEq(vault.collectedIncome(address(usdc)), 7e6);
        assertGe(usdc.balanceOf(address(vault)), _ledgerTotal(address(usdc)), "DEC-080: the ledger is backed");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-066 / QA6 / DEC-063: a donation of the whole amount sent is indistinguishable from the refund
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-066, QA6, DEC-063 (final verification, residual pinned): the guard cannot tell a refund from a donation of
    /// the same size. A stranger who parks `amountSent` in the escrow moves the transit to RefundRecognized at their
    /// own expense: the fund is whole (exactly `amountSent` credited, the surplus swept, DEC-080). The real Across
    /// refund that lands afterwards has no release path (the transit is never recognizable again and the escrow
    /// answers only the vault), so it stays in the escrow for good. Nobody gains and the fund loses nothing; pinned
    /// so the stance is explicit.
    function test_DEC066_donationOfTheAmountSentIsRecognizedAndTheLaterRealRefundStaysInTheEscrow() public {
        _deploySpoke();
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0, _quote(499e6));
        Transit memory t = vault.hubBoundTransit(id);
        vm.warp(uint256(t.fillDeadline) + 1);

        usdg.mint(t.escrow, 500e6 + 1); // a stranger's deposit, one unit above the amount sent
        vm.prank(stranger);
        assertEq(vault.recognizeRefund(id), 500e6);
        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.RefundRecognized));
        assertEq(vault.inFlightTransitIds().length, 0);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6, "exactly the amount sent is credited");
        assertEq(usdg.balanceOf(t.escrow), 0);
        assertEq(vault.sweepExcess(address(usdg)), 1, "the surplus is excess, never a base");

        // The real refund lands afterwards: nothing can move it.
        spokePool.refund(t.escrow, address(usdg), 500e6);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnknownTransit.selector, id));
        vault.recognizeRefund(id);
        assertEq(usdg.balanceOf(t.escrow), 500e6, "the real refund is stranded in the escrow");
        assertEq(vault.sweepExcess(address(usdg)), 0, "the vault's sweep does not reach the escrow");
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6);
        assertEq(usdg.balanceOf(address(vault)), _ledgerTotal(address(usdg)), "DEC-080: the ledger is backed");
    }
}
