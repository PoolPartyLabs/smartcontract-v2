// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IManagerRegistry
/// @notice Per-manager properties valid across all of a manager's funds, outside the Mandate: the protocol slice of the
///         manager fee.
/// @dev DEC-106: the protocol slice is 50% of the manager fee by default, configurable per manager. DEC-110: it lives
///      in a separate per-manager registry read at every charge; a change applies from the next charge. DEC-052: a
///      manager without an entry gets the default, with no API dependency.
/// @dev DEC-112 (closes LC-142): the writer is the Pool Party API signature, operated through the admin portal; the
///      slice stays between 5% and 50%, never 0. DEC-125 item 2 (D-35 reading): one registry per Hub factory version,
///      deployed with it and pinned in its wiring; funds of an older factory keep reading their own. The writer is the
///      registry's `Ownable2Step` owner, which the deployment sets to the API signer key (`REGISTRY_OWNER`).
/// @dev DEC-182, DEC-184 (correcting DEC-115 and DEC-125 item 3, reading D-36): the adjustable minimum manager fee
///      left the registry; the performance fee floor is a fixed 10% in the Mandate
///      (`MandateLib.MIN_PERFORMANCE_FEE_BPS`).
interface IManagerRegistry {
    /// @notice A manager's slice was set or cleared. `hasEntry` false means it returned to the default.
    event ProtocolSliceSet(address indexed manager, uint16 previousBps, uint16 newBps, bool hasEntry);

    /// @notice The slice is above `MAX_PROTOCOL_SLICE_BPS`.
    error ProtocolSliceAboveMax(uint16 bps, uint16 maxBps);

    /// @notice The slice is below `MIN_PROTOCOL_SLICE_BPS` (DEC-112: never 0).
    error ProtocolSliceBelowMin(uint16 bps, uint16 minBps);

    /// @notice Zero manager address.
    error ZeroManager();

    /// @notice The registry's writer cannot be renounced (DEC-112: a registry read at every charge).
    error RenounceDisabled();

    /// @notice Default protocol slice, in bps of the manager fee (DEC-106): 5,000.
    function DEFAULT_PROTOCOL_SLICE_BPS() external view returns (uint16);

    /// @notice Cap on a manager's slice, in bps of the manager fee (DEC-112, DEC-115): 5,000.
    function MAX_PROTOCOL_SLICE_BPS() external view returns (uint16);

    /// @notice Floor of a manager's slice, in bps of the manager fee (DEC-112): 500.
    function MIN_PROTOCOL_SLICE_BPS() external view returns (uint16);

    /// @notice Effective protocol slice for `manager`, in bps of the manager fee; the default when no entry exists.
    function protocolSliceBps(address manager) external view returns (uint16);

    /// @notice Whether `manager` has an explicit entry.
    function hasEntry(address manager) external view returns (bool);

    /// @notice Sets `manager`'s slice, within [`MIN_PROTOCOL_SLICE_BPS`, `MAX_PROTOCOL_SLICE_BPS`]. Writer only.
    function setProtocolSliceBps(address manager, uint16 bps) external;

    /// @notice Removes `manager`'s entry so the default applies again. Writer only.
    function clearProtocolSliceBps(address manager) external;
}
