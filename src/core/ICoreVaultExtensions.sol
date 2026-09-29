// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransferKind} from "../interfaces/FundTypes.sol";

/// @title ICoreVaultExtensions
/// @notice Events and errors the Core Vault emits or reverts with beyond the frozen ICoreVault, in one place so the
///         Core Vault's ABI is complete for indexers and callers.
/// @dev CoreVaultLogic is an external linked library that runs by DELEGATECALL in the Core Vault's context, so its
///      events carry the Core Vault's address; declaring them here (inherited by the Core Vault, emitted by qualified
///      name in the library) keeps them in the Core Vault's ABI instead of only in the library's. Candidate additions
///      to ICoreVault (reported in the module report as an interface change).
interface ICoreVaultExtensions {
    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice DEC-041: Operating Cash was below its floor, so the expense that restores it falls through to Share
    ///         Assets (the explicit "insufficient cash" state). `toppedUp` is below the configured top-up when Free Idle
    ///         is short.
    event OperatingCashInsufficient(uint256 balance, uint256 floor, uint256 toppedUp);

    /// @notice An automatic unwind reverted; the claim continues with the Idle available (DEC-056: exits stay open;
    ///         DEC-068: Partial Payout).
    event UnwindForPayoutFailed(uint256 usdcTarget);

    /// @notice A spoke-to-hub arrival or its remainder was held apart because no report listed it or the listed amount
    ///         was already credited (DEC-080, OQ-01).
    event ArrivalHeldApart(bytes32 indexed transitId, uint256 indexed originChainId, TransferKind kind, uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    error ZeroAddress();
    error UsdcMismatch(address configured, address mandateUsdc);
    error NotOnHubChain(uint256 chainId, uint256 hubChainId);
    error FlowFeeAboveCap(uint16 bps);
    error BridgeTargetUnset(address bridgeAdapter);
    error UnbackedCredit(address token, uint256 amount, uint256 unledgered);

    /// @notice The adapter's call does not match what the vault fixed (target, amount to arrive or fill deadline).
    error BridgeCallMismatch(address bridgeAdapter);

    /// @notice A token movement did not match the expected amount (IBridgeAdapter custody rule 3, escrow release).
    error BalanceChangeMismatch(uint256 expected, uint256 actual);

    /// @notice The bridge adapter's runtime code changed since creation (Q17-4 reading O2).
    error BridgeAdapterCodehashMismatch(address bridgeAdapter);
}
