// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISpokeVaultIncome
/// @notice The Spoke Vault's collected income verbs: the swap of collected income into the base token and the forward
///         of collected income to the Core Vault (DEC-092; CV-OQ-2, ruling 2026-09-29). Part of ISpokeVault.
/// @dev Split out of ISpokeVault (WP-07 A4) so these verbs and their events sit with `SpokeVaultIncome`. ISpokeVault
///      inherits it: the Spoke Vault's selectors and event topics are unchanged.
interface ISpokeVaultIncome {
    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Collected income was swapped into the base token inside the collected income bucket (CV-OQ-2).
    event IncomeSwapped(
        address indexed adapter,
        bytes32 indexed poolKey,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 amountOut
    );

    /// @notice Hub only: collected income was handed to the Core Vault's Attributed Income bucket.
    event IncomeForwardedToCoreVault(address indexed token, uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Collected income (DEC-092)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Swaps collected income of `tokenIn` into the base token through a Mandate pool, inside the collected
    ///         income bucket. Manager only; Spoke Chains only.
    /// @dev CV-OQ-2 / Q60 (spoke income tokens) and ruling 2026-09-29: spoke income can only be attributed once it
    ///      reaches the Core Vault, and it can only get there as USDC through the Transport Route (DEC-031, DEC-055),
    ///      so income collected in another token (WETH fees) is first swapped into the spoke's base token and then
    ///      sent with `sendToHub(..., Income, ...)`. Debits and credits the collected income bucket only, never
    ///      Unallocated Balance (DEC-092); the output must be the base token. The Market Costs of the swap are borne by
    ///      the income (LC-45 / LC-141 OPEN). The fee is split on the hub when the USDC arrives (DEC-107), so this swap
    ///      happens before any fee is taken; DEC-109's "no swap by the contract" applies to the fee payment, which
    ///      stays in kind on the hub. `minAmountOut` bounds slippage; the adapter's own rules apply (OQ-04: blocked
    ///      when deprecated, never when paused).
    function swapCollectedIncome(
        address adapter,
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata params
    ) external returns (uint256 amountOut);

    /// @notice Hands the collected income bucket of `token` to the Core Vault (`ICoreVault.receiveCollectedIncome`).
    ///         Permissionless; hub only; the destination is fixed.
    function forwardIncomeToCoreVault(address token) external returns (uint256 amount);
}
