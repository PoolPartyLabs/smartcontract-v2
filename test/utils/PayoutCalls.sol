// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ICoreVault} from "../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../src/interfaces/ICoreVaultPayouts.sol";

/// @title PayoutCalls
/// @notice The payout verbs as a test that only needs a payout to happen calls them: open a Payout Request, claim it,
///         leave with every share. Each call is made as the holder.
/// @dev WP-07 D5: new tests outside the payout work (income, closure, harness checks) go through these wrappers, so the
///      payout work (the proportional unwind and its settlement, DEC-120, DEC-137, DEC-139) changes the payout
///      signatures here, in one place, instead of in every such test.
library PayoutCalls {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice A request for more USDC than any balance is worth: the claim burns at most the balance (DEC-020), so it
    ///         asks for every share.
    uint256 internal constant EVERYTHING = type(uint128).max;

    /// @notice `holder` opens a Payout Request of `usdcAmount` in `mode`, with no maximum loss (DEC-020, DEC-024,
    ///         DEC-140). An Instant request is its own claim (DEC-120 item 1): it pays in the same call and its receipt
    ///         is returned; a Standard one returns an empty receipt.
    function request(ICoreVault core, address holder, uint256 usdcAmount, ICoreVaultPayouts.PayoutMode mode)
        internal
        returns (ICoreVaultPayouts.PayoutReceipt memory)
    {
        VM.prank(holder);
        return core.requestPayout(usdcAmount, mode, 0);
    }

    /// @notice `holder` claims its open Payout Request with no maximum loss: a Standard one after its term, or the next
    ///         attempt of a partial one (DEC-068, DEC-151).
    function claim(ICoreVault core, address holder) internal returns (ICoreVaultPayouts.PayoutReceipt memory) {
        VM.prank(holder);
        return core.claimPayout(0);
    }

    /// @notice `holder` leaves with every share: an Instant request for `EVERYTHING`, paid in the same call. When Free
    ///         Idle (and the hub unwind) covers it the whole balance burns and its Attributed Income is paid in the
    ///         same transaction (DEC-045, DEC-047); otherwise the payout is partial (DEC-068). Not for the manager,
    ///         whose requests stop at the base (DEC-146).
    function fullExit(ICoreVault core, address holder) internal returns (ICoreVaultPayouts.PayoutReceipt memory) {
        return request(core, holder, EVERYTHING, ICoreVaultPayouts.PayoutMode.Instant);
    }
}
