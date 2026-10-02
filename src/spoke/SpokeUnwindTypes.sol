// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SpokeUnwindTypes
/// @notice The unwind's own types and errors: the claimant's hints to the hub Spoke Vault's automatic unwind
///         (`SpokeVaultUnwind`, `SpokeUnwindLib`).
/// @dev WP-07 D1: moved out of `SpokeVaultTypes` so the unwind work (the proportional unwind and the spoke unwind
///      orders, DEC-120, DEC-137, DEC-139) edits its own types file.
library SpokeUnwindTypes {
    /// @notice The claimant's optional tightening of the swap of one non-USDC token an unwind exit returned, into hub
    ///         USDC. Final verification (DEC-069, DEC-081, DEC-097, QA3 OPEN): a hint can never widen what the vault
    ///         would do on its own.
    /// @param adapter Mandate position adapter on the Hub Chain that runs the swap. When the position's own pool pairs
    ///        `tokenIn` with USDC the vault swaps there and a hint must name that same route; otherwise the hint names
    ///        the route (a Mandate pool of a Mandate adapter holding `tokenIn` and USDC) and is required.
    /// @param poolKey Mandate pool of that adapter.
    /// @param tokenIn Token the exit returned as principal; the whole amount the exit returned is swapped.
    /// @param minAmountOut Minimum USDC output; used only when above the vault's floor (the route's spot quote less
    ///        `SpokeVault.MAX_UNWIND_SLIPPAGE_BPS`).
    /// @param params Adapter-specific swap parameters (Uniswap V4: price limit and deadline, which can only make the
    ///        swap revert); empty for the adapter's defaults.
    struct UnwindSwap {
        address adapter;
        bytes32 poolKey;
        address tokenIn;
        uint256 minAmountOut;
        bytes params;
    }

    /// @notice The claimant's optional hint for one position the automatic unwind visits (registry order): only swap
    ///         tightenings. The vault sizes every exit itself (`IAdapter.unwindExitParams`) and never takes exit
    ///         parameters from the claimant (final verification).
    /// @param swaps Tightenings of the swaps of the non-USDC principal this exit returns, matched by `tokenIn`.
    struct UnwindHint {
        UnwindSwap[] swaps;
    }

    /// @notice An unwind exit returns `token`, the position's own pool does not pair it with USDC and no hint names a
    ///         route for it (final verification: the unwind is never sized or swapped without a price).
    error MissingUnwindSwap(address token);
    error InvalidUnwindSwap(address adapter, bytes32 poolKey, address tokenIn);

    /// @notice Encodes the `unwindHints` argument of `ISpokeVault.unwindForPayout`.
    function encodeHints(UnwindHint[] memory hints) internal pure returns (bytes memory) {
        return abi.encode(hints);
    }
}
