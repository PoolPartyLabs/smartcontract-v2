// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CORE_VAULT_UNWINDING_SLOT} from "../../../src/core/CoreVaultTypes.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice The unwinding flag after the payout path moved into the linked `CoreVaultPayoutLogic` (WP-07 A2, DEC-131
///         pattern): the library sets it in transient storage (`CORE_VAULT_UNWINDING_SLOT`) around
///         `ISpokeVault.unwindForPayout` only, and `CoreVaultBase.onlyHubSpokeVaultCallback` reads it. The hub Spoke
///         Vault's `returnToIdle` is accepted inside an unwind and refused inside any other guarded entry, before and
///         after an unwind in the same transaction, whether the unwind returned or reverted.
contract CoreVaultUnwindingFlagTest is CoreVaultFixture {
    ICoreVault.PayoutMode internal constant INSTANT = ICoreVaultPayouts.PayoutMode.Instant;

    function _allocateToPosition(uint256 amount) internal {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(amount);
        hubVault.moveToPosition(amount);
    }

    /// @dev A guarded entry (`allocateToHubSpokeVault`) whose hub Spoke Vault calls back `returnToIdle`.
    function _expectCallbackRefused() internal {
        hubVault.setReturnOnReceive(true);
        vm.prank(manager);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.allocateToHubSpokeVault(1e6);
        hubVault.setReturnOnReceive(false);
    }

    function test_DEC131_unwindingSlotIsTheErc7201Slot() public pure {
        bytes32 expected =
            keccak256(abi.encode(uint256(keccak256("pool-party.CoreVault.unwinding")) - 1)) & ~bytes32(uint256(0xff));
        assertEq(CORE_VAULT_UNWINDING_SLOT, expected);
    }

    function test_DEC131_hubCallbackOutsideAnUnwindIsRefused() public {
        _deposit(alice, 1000e6);
        _expectCallbackRefused();
    }

    function test_DEC131_flagIsClearedAfterAnUnwindThatReturned() public {
        _deployAtMinimumFees();
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left
        _request(alice, 800e6, INSTANT);
        _expectCallbackRefused();
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.unwindProceeds, 408e6, "the unwind's returnToIdle callback was accepted");
        _expectCallbackRefused();
    }

    function test_DEC131_flagIsClearedAfterAnUnwindThatReverted() public {
        _deployAtMinimumFees();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _deposit(alice, 1000e6);
        _allocateToPosition(600e6 + SEED_IDLE); // Idle 400 left
        _request(alice, 800e6, INSTANT);
        vm.expectEmit(address(vault));
        emit ICoreVaultPayouts.UnwindForPayoutFailed(408e6);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.unwindProceeds, 0, "DEC-056: the claim went on with Idle");
        _expectCallbackRefused();
    }
}
