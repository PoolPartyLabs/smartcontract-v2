// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {PayoutCalls} from "../../utils/PayoutCalls.sol";

/// @notice The Core Vault's income hooks around mints and burns (WP-07 D2), driven through the shared payout wrappers
///         (`PayoutCalls`, WP-07 D5): the settlement before every balance change, the interval adjustments after it and
///         the full-burn income payment (DEC-014, DEC-045, DEC-047, DEC-161).
contract CoreVaultIncomeHooksTest is CoreVaultFixture {
    function setUp() public override {
        super.setUp();
        _deployAtMinimumFees();
    }

    /// @dev `afterBurn` pays every converted dollar when the burn takes the whole balance.
    function test_DEC045_aFullExitPaysTheAttributedIncome() public {
        _deposit(alice, 1000e6);
        _deposit(bob, 1000e6);
        _hubIncomeCollected(address(usdc), 200.1e6); // 0.10 per share over 2,001 shares (the seed's included)
        uint256 owed = _incomeOf(alice);
        assertApproxEqAbs(owed, _netOfMinimumFee(100e6), 1);

        ICoreVaultPayouts.PayoutReceipt memory r = PayoutCalls.fullExit(vault, alice);

        assertEq(r.sharesBurned, 1000e18, "every share burned");
        assertEq(shares.balanceOf(alice), 0);
        assertEq(usdc.balanceOf(alice), 980e6 + owed, "principal less the 2% Payout Fee, plus the income");
        assertEq(_incomeOf(alice), 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    /// @dev A partial burn leaves the income attributed (`afterBurn` pays only on a full burn), and the settlement the
    ///      burn took keeps what the burned shares earned.
    function test_DEC045_aPartialBurnKeepsTheIncomeAttributed() public {
        _deposit(alice, 1000e6);
        _hubIncomeCollected(address(usdc), 100.1e6); // 0.10 per share over 1,001 shares (the seed's included)
        ICoreVaultPayouts.PayoutReceipt memory r =
            PayoutCalls.request(vault, alice, 500e6, ICoreVaultPayouts.PayoutMode.Instant);

        assertEq(r.sharesBurned, 500e18);
        assertEq(usdc.balanceOf(alice), 490e6, "no income paid");
        assertApproxEqAbs(_incomeOf(alice), _netOfMinimumFee(100e6), 1, "all 1,000 shares' income kept");
    }

    /// @dev A burn in the middle of an interval: the burned shares keep what they earned until the burn, converted
    ///      with the interval (DEC-014, doc 10 section 2).
    function test_DEC014_burnedSharesKeepTheirPartOfTheOpenInterval() public {
        _deposit(alice, 1000e6);
        _earnHubIncome(address(usdc), 100.1e6); // recognized at the burn's valuation
        PayoutCalls.request(vault, alice, 500e6, ICoreVaultPayouts.PayoutMode.Instant);
        _hubIncomeCollected(address(usdc), 25.05e6);
        assertApproxEqAbs(_incomeOf(alice), _netOfMinimumFee(100e6 + 25e6), 2);
    }

    /// @dev DEC-014: the settlement before a mint gives an entrant none of the income recognized before it entered.
    function test_DEC014_anEntrantGetsNoIncomeEarnedBeforeItsMint() public {
        _deposit(alice, 1000e6);
        _earnHubIncome(address(usdc), 100.1e6);
        _deposit(bob, 1000e6);
        _collectHubIncome();
        assertEq(_incomeOf(bob), 0);
        assertApproxEqAbs(_incomeOf(alice), _netOfMinimumFee(100e6), 1);
    }
}
