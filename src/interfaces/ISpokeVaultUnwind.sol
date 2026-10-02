// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISpokeVaultUnwind
/// @notice The hub Spoke Vault's automatic unwind for a payout (DEC-069, DEC-081, DEC-097). Part of ISpokeVault.
/// @dev Split out of ISpokeVault (WP-07 A4) so the unwind verb and its event sit with `SpokeVaultUnwind` and
///      `SpokeUnwindLib`. ISpokeVault inherits it: the Spoke Vault's selectors and event topics are unchanged.
interface ISpokeVaultUnwind {
    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Hub only: an automatic unwind for a payout ran (DEC-069, DEC-081).
    event UnwoundForPayout(uint256 usdcTarget, uint256 usdcProceeds);

    // ---------------------------------------------------------------------------------------------------------------
    // Hub Chain interplay with the Core Vault
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Automatic unwind of the open positions in registry order until `usdcTarget` USDC is available, then
    ///         returns the USDC proceeds to the Core Vault's Idle. Core Vault only; hub only.
    /// @dev Interim order (DEC-137, DEC-139: the Mandate no longer orders the unwind; the proportional unwind of WP-09
    ///      replaces this walk); DEC-081: `usdcTarget` already includes the 2% margin; DEC-097: the margin's
    ///      Market Costs are the fund's. Feedback question 2 (OPEN): the MVP unwinds hub positions only. Final
    ///      verification (QA3 OPEN): the vault sizes every step itself (the shortfall still needed against the
    ///      position's principal value at the pool's spot price, closing a position only when its whole value is
    ///      needed) and floors every swap's minimum output at the route's spot quote less `MAX_UNWIND_SLIPPAGE_BPS`.
    /// @param unwindHints Optional `abi.encode(SpokeVaultTypes.UnwindHint[])` from the claimant: swap tightenings only
    ///        (a higher minimum output, a price limit or deadline), never an exit size; a hint cannot widen what the
    ///        vault would do on its own.
    /// @return usdcProceeds USDC returned to the Core Vault (may be below target: the payout is then partial,
    ///         DEC-068).
    function unwindForPayout(uint256 usdcTarget, bytes calldata unwindHints) external returns (uint256 usdcProceeds);
}
