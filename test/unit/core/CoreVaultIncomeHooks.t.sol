// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {PayoutCalls} from "../../utils/PayoutCalls.sol";

/// @notice The Core Vault's income hooks around mints and burns (WP-07 D2) keep today's behaviour, driven through the
///         shared payout wrappers (`PayoutCalls`, WP-07 D5): the checkpoint before every balance change and the
///         full-burn income payment after a burn (DEC-014, DEC-045, DEC-047).
contract CoreVaultIncomeHooksTest is CoreVaultFixture {
    function setUp() public override {
        super.setUp();
        _deployFeeless();
    }

    /// @dev `afterBurn` pays all Attributed Income when the burn takes the whole balance.
    function test_DEC045_aFullExitPaysTheAttributedIncome() public {
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        hubVault.forwardIncome(address(usdc), 200.1e6); // 0.10 per share over 2,001 shares (the seed's included)
        uint256 owed = vault.attributedIncome(alice, address(usdc));
        assertApproxEqAbs(owed, 100e6, 1);

        ICoreVaultPayouts.PayoutReceipt memory r = PayoutCalls.fullExit(vault, alice);

        assertEq(r.sharesBurned, 1000e18, "every share burned");
        assertEq(shares.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 980e6 + owed, "principal less the 2% Payout Fee, plus the income");
        assertEq(vault.attributedIncome(alice, address(usdc)), 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    /// @dev A partial burn leaves the income attributed (`afterBurn` pays only on a full burn), and the checkpoint the
    ///      burn took keeps what the burned shares earned.
    function test_DEC045_aPartialBurnKeepsTheIncomeAttributed() public {
        _deposit(alice, 1000e6);
        hubVault.forwardIncome(address(usdc), 100.1e6); // 0.10 per share over 1,001 shares (the seed's included)
        PayoutCalls.request(vault, alice, 500e6, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVaultPayouts.PayoutReceipt memory r = PayoutCalls.claim(vault, alice);

        assertEq(r.sharesBurned, 500e18);
        assertEq(usdc.balanceOf(alice), 490e6, "no income paid");
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), 100e6, 1, "all 1,000 shares' income kept");
    }

    /// @dev DEC-014: the checkpoint before a mint gives an entrant none of the income collected before it entered.
    function test_DEC014_anEntrantGetsNoIncomeCollectedBeforeItsMint() public {
        _deposit(alice, 1000e6);
        hubVault.forwardIncome(address(usdc), 100.1e6);
        _deposit(bob, 1000e6);
        assertEq(vault.attributedIncome(bob, address(usdc)), 0);
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), 100e6, 1);
    }
}
