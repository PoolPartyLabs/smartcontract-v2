// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IManagerRegistry
/// @notice Per-manager properties valid across all of a manager's funds, outside the Mandate: the protocol slice of the
///         manager fee, and the protocol's minimum manager fee checked when a fund is created.
/// @dev DEC-106: the protocol slice is 50% of the manager fee by default, configurable per manager. DEC-110: it lives
///      in a separate per-manager registry read at every charge; a change applies from the next charge. DEC-052: a
///      manager without an entry gets the default, with no API dependency.
/// @dev DEC-112 (closes LC-142): the writer is the Pool Party API signature, operated through the admin portal; the
///      slice stays between 5% and 50%, never 0. DEC-125 item 2 (D-35 reading): one registry per Hub factory version,
///      deployed with it and pinned in its wiring; funds of an older factory keep reading their own. The writer is the
///      registry's `Ownable2Step` owner, which the deployment sets to the API signer key (`REGISTRY_OWNER`).
/// @dev DEC-115, DEC-125 item 3: the minimum manager fee starts at 0 and the writer may raise it to at most 1,000 bps.
///      It binds the performance fee of funds created after the change; live funds are never forced (D-36).
interface IManagerRegistry {
    /// @notice A manager's slice was set or cleared. `hasEntry` false means it returned to the default.
    event ProtocolSliceSet(address indexed manager, uint16 previousBps, uint16 newBps, bool hasEntry);

    /// @notice The minimum manager fee changed (DEC-115, DEC-125 item 3).
    event MinManagerFeeSet(uint16 previousBps, uint16 newBps);

    /// @notice The slice is above `MAX_PROTOCOL_SLICE_BPS`.
    error ProtocolSliceAboveMax(uint16 bps, uint16 maxBps);

    /// @notice The slice is below `MIN_PROTOCOL_SLICE_BPS` (DEC-112: never 0).
    error ProtocolSliceBelowMin(uint16 bps, uint16 minBps);

    /// @notice The minimum manager fee is above `MAX_MIN_MANAGER_FEE_BPS`.
    error MinManagerFeeAboveMax(uint16 bps, uint16 maxBps);

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

    /// @notice Cap on the minimum manager fee, in bps (DEC-115, DEC-125 item 3): 1,000.
    function MAX_MIN_MANAGER_FEE_BPS() external view returns (uint16);

    /// @notice Effective protocol slice for `manager`, in bps of the manager fee; the default when no entry exists.
    function protocolSliceBps(address manager) external view returns (uint16);

    /// @notice Whether `manager` has an explicit entry.
    function hasEntry(address manager) external view returns (bool);

    /// @notice Minimum performance fee of a new fund, in bps; 0 at deployment (DEC-115, DEC-125 item 3).
    function minManagerFeeBps() external view returns (uint16);

    /// @notice Sets `manager`'s slice, within [`MIN_PROTOCOL_SLICE_BPS`, `MAX_PROTOCOL_SLICE_BPS`]. Writer only.
    function setProtocolSliceBps(address manager, uint16 bps) external;

    /// @notice Removes `manager`'s entry so the default applies again. Writer only.
    function clearProtocolSliceBps(address manager) external;

    /// @notice Sets the minimum manager fee, at most `MAX_MIN_MANAGER_FEE_BPS`. Writer only.
    function setMinManagerFeeBps(uint16 bps) external;
}
