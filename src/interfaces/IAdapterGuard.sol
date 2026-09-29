// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAdapterGuard
/// @notice Quarantine (`paused`) and `deprecated` flags shared by position adapters and bridge adapters.
/// @dev DEC-021: manual pause per Adapter. DEC-056: a paused Adapter is in quarantine; it blocks entry and position
///      increases and never blocks pulling value back to the Spoke Vault. DEC-058: `deprecated` is global, immediate
///      and irreversible; a deprecated Adapter is withdraw-only. DEC-087: a bridge is an Adapter under the same
///      regime.
/// @dev OPEN (DEC-021, Q17-2b, LC-26, LC-40): who triggers pause and deprecation and where the flag lives. MVP: both
///      flags live on the adapter (reading L1) and only an immutable `guardian` address set at construction may
///      change them.
interface IAdapterGuard {
    /// @notice Emitted when the guardian sets the quarantine flag.
    event PausedSet(bool paused);

    /// @notice Emitted once, when the guardian deprecates the adapter.
    event AdapterDeprecated();

    /// @notice Caller is not the guardian.
    error NotGuardian(address caller);

    /// @notice An entry or increase verb was called while the adapter is paused (DEC-056).
    error AdapterPaused();

    /// @notice An entry or increase verb was called after deprecation (DEC-058).
    error AdapterIsDeprecated();

    /// @notice Immutable address allowed to pause, unpause and deprecate.
    function guardian() external view returns (address);

    /// @notice Quarantine flag (DEC-021, DEC-056).
    function paused() external view returns (bool);

    /// @notice Deprecation flag (DEC-058). Once true it never becomes false.
    function deprecated() external view returns (bool);

    /// @notice Sets the quarantine flag. Guardian only.
    function setPaused(bool paused_) external;

    /// @notice Deprecates the adapter, irreversibly. Guardian only.
    function deprecate() external;
}
