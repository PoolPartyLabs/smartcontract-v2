// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice DEC-147 items 2-3 and DEC-149 (reading: irreversible): `closeFund` is a manager call; Closing takes no
///         deposit, no Payout Request and no claim (D-26); Income Withdrawal stays open in every state (DEC-117 item
///         4).
contract CoreVaultLifecycleTest is CoreVaultFixture {
    ICoreVaultLifecycle.FundState internal constant OPEN = ICoreVaultLifecycle.FundState.Open;
    ICoreVaultLifecycle.FundState internal constant CLOSING = ICoreVaultLifecycle.FundState.Closing;

    function _close() internal {
        vm.prank(manager);
        vault.closeFund();
    }

    function test_DEC147_aFundIsBornOpen() public view {
        assertEq(uint8(vault.fundState()), uint8(OPEN));
        assertEq(vault.closingStartedAt(), 0);
    }

    function test_DEC147_closeFundMovesOpenToClosing() public {
        vm.warp(1_800_001_234);
        vm.expectEmit(address(vault));
        emit ICoreVaultLifecycle.FundClosing(1_800_001_234);
        _close();
        assertEq(uint8(vault.fundState()), uint8(CLOSING));
        assertEq(vault.closingStartedAt(), 1_800_001_234);
    }

    function test_DEC147_onlyTheManagerCloses() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotManager.selector, alice));
        vault.closeFund();
        assertEq(uint8(vault.fundState()), uint8(OPEN));
    }

    /// @dev DEC-149 reading: the closure has no way back; a second call is refused and keeps the first start.
    function test_DEC149_closingIsIrreversible() public {
        _close();
        uint64 started = vault.closingStartedAt();
        vm.warp(block.timestamp + 1 days);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, CLOSING));
        vault.closeFund();
        assertEq(vault.closingStartedAt(), started);
    }

    /// @dev DEC-121, DEC-147 item 3: no deposit while Closing.
    function test_DEC147_closingRefusesDeposits() public {
        _deposit(alice, 1000e6);
        _close();
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, CLOSING));
        vault.deposit(1000e6, 0);
        vm.stopPrank();
    }

    /// @dev DEC-147 item 3: no new Payout Request while Closing, in either mode.
    function test_DEC147_closingRefusesPayoutRequests() public {
        _deposit(alice, 1000e6);
        _close();
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, CLOSING));
        vault.requestPayout(100e6, ICoreVaultPayouts.PayoutMode.Instant);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, CLOSING));
        vault.requestPayout(100e6, ICoreVaultPayouts.PayoutMode.Standard);
        vm.stopPrank();
    }

    /// @dev D-26: a request opened before closure is not claimed while Closing (it is paid as a closed-fund exit,
    ///      DEC-150 item 4); its reserve stays.
    function test_DEC147_closingRefusesClaimsOfRequestsOpenedBefore() public {
        _deposit(alice, 1000e6);
        _request(alice, 500e6, ICoreVaultPayouts.PayoutMode.Standard);
        uint256 reserve = vault.payoutReserve();
        _close();
        vm.warp(block.timestamp + 72 hours);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, CLOSING));
        vault.claimPayout("");
        assertTrue(vault.payoutRequest(alice).open, "the request stays open");
        assertEq(vault.payoutReserve(), reserve, "and so does its reserve");
    }

    /// @dev DEC-117 item 4: Income Withdrawal works in every state of the fund.
    function test_DEC117_incomeWithdrawalWorksWhileClosing() public {
        _deposit(alice, 10_000e6);
        hubVault.forwardIncome(address(usdc), 1000e6);
        _close();
        uint256 owed = vault.attributedIncome(alice, address(usdc));
        assertGt(owed, 0);
        vm.prank(alice);
        assertEq(vault.withdrawIncome(address(usdc)), owed);
    }

    /// @dev DEC-147 item 4: while Closing the manager still moves value with the existing verbs (here Idle to the hub
    ///      Spoke Vault and back).
    function test_DEC147_managerVerbsStillWorkWhileClosing() public {
        _deposit(alice, 1000e6);
        _close();
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100e6);
        hubVault.returnToCore(100e6);
        assertEq(vault.idle(), SEED_IDLE + 997e6);
    }
}
