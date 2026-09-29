// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IManagerRegistry
/// @notice Per-manager properties valid across all of a manager's funds, outside the Mandate. Today: the protocol
///         slice of the manager fee.
/// @dev DEC-106: the protocol slice is 50% of the manager fee by default, configurable per manager. DEC-110: it lives
///      in a separate per-manager registry read at every charge; a change applies from the next charge. DEC-052: a
///      manager without an entry gets the default, with no API dependency.
/// @dev OPEN (LC-142): which on-chain role writes it (MVP: the registry's Ownable2Step owner, the protocol admin),
///      whether it may exceed 50%, and its cap (MVP: `MAX_PROTOCOL_SLICE_BPS` = 5,000, the value proposed in LC-57).
interface IManagerRegistry {
    /// @notice A manager's slice was set or cleared. `hasEntry` false means it returned to the default.
    event ProtocolSliceSet(address indexed manager, uint16 previousBps, uint16 newBps, bool hasEntry);

    /// @notice The slice is above `MAX_PROTOCOL_SLICE_BPS`.
    error ProtocolSliceAboveMax(uint16 bps, uint16 maxBps);

    /// @notice Zero manager address.
    error ZeroManager();

    /// @notice The registry's writer cannot be renounced (LC-142: a global registry read at every charge).
    error RenounceDisabled();

    /// @notice Default protocol slice, in bps of the manager fee (DEC-106): 5,000.
    function DEFAULT_PROTOCOL_SLICE_BPS() external view returns (uint16);

    /// @notice Cap on a manager's slice, in bps of the manager fee. OPEN (LC-142, LC-57): proposed 5,000.
    function MAX_PROTOCOL_SLICE_BPS() external view returns (uint16);

    /// @notice Effective protocol slice for `manager`, in bps of the manager fee; the default when no entry exists.
    function protocolSliceBps(address manager) external view returns (uint16);

    /// @notice Whether `manager` has an explicit entry (an explicit 0 is a valid entry).
    function hasEntry(address manager) external view returns (bool);

    /// @notice Sets `manager`'s slice. Protocol admin only (OPEN, LC-142).
    function setProtocolSliceBps(address manager, uint16 bps) external;

    /// @notice Removes `manager`'s entry so the default applies again. Protocol admin only.
    function clearProtocolSliceBps(address manager) external;
}
