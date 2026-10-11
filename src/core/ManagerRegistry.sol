// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IManagerRegistry} from "../interfaces/IManagerRegistry.sol";

/// @title ManagerRegistry
/// @notice Per-manager properties valid across all of a manager's funds, outside the Mandate: the protocol slice of the
///         manager fee. See IManagerRegistry.
/// @dev DEC-106: default slice 50% of the manager fee, configurable per manager. DEC-110: a separate registry read at
///      every charge; a change applies from the next charge. DEC-052: a manager without an entry gets the default,
///      with no API dependency.
/// @dev DEC-112: the writer is the API signature (the `Ownable2Step` owner, set to the API signer key at deployment)
///      and a slice stays within [`MIN_PROTOCOL_SLICE_BPS`, `MAX_PROTOCOL_SLICE_BPS`] = [500, 5,000], never 0.
///      DEC-125 item 2 (D-35): deployed with the Hub factory and pinned in its wiring. DEC-184: the registry holds
///      only the slice; the performance fee floor is the Mandate constant `MandateLib.MIN_PERFORMANCE_FEE_BPS`.
/// @dev DEC-022: a registry that never holds funds; deployed without a proxy all the same.
contract ManagerRegistry is IManagerRegistry, Ownable2Step {
    /// @inheritdoc IManagerRegistry
    /// @dev DEC-106: 50% of the manager fee.
    uint16 public constant DEFAULT_PROTOCOL_SLICE_BPS = 5000;

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-112, DEC-115: 50% of the manager fee, equal to the default.
    uint16 public constant MAX_PROTOCOL_SLICE_BPS = 5000;

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-112: 5% of the manager fee, never 0.
    uint16 public constant MIN_PROTOCOL_SLICE_BPS = 500;

    struct Entry {
        bool exists;
        uint16 bps;
    }

    mapping(address manager => Entry) internal _entries;

    /// @param initialOwner The writer: the API signer key (DEC-112; deployment config `REGISTRY_OWNER`).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-052, DEC-106: the default when the manager has no entry.
    function protocolSliceBps(address manager) public view returns (uint16) {
        Entry memory e = _entries[manager];
        return e.exists ? e.bps : DEFAULT_PROTOCOL_SLICE_BPS;
    }

    /// @inheritdoc IManagerRegistry
    function hasEntry(address manager) external view returns (bool) {
        return _entries[manager].exists;
    }

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-110: applies from the next charge. DEC-112: writer only, within [500, 5,000].
    function setProtocolSliceBps(address manager, uint16 bps) external onlyOwner {
        if (manager == address(0)) revert ZeroManager();
        if (bps > MAX_PROTOCOL_SLICE_BPS) revert ProtocolSliceAboveMax(bps, MAX_PROTOCOL_SLICE_BPS);
        if (bps < MIN_PROTOCOL_SLICE_BPS) revert ProtocolSliceBelowMin(bps, MIN_PROTOCOL_SLICE_BPS);
        uint16 previous = protocolSliceBps(manager);
        _entries[manager] = Entry({exists: true, bps: bps});
        emit ProtocolSliceSet(manager, previous, bps, true);
    }

    /// @notice Disabled: the owner can hand the writer role over (two steps) but never drop it.
    /// @dev DEC-112 and the report-receiver verifier finding: renouncing would freeze every manager's slice for good
    ///      with one call on a registry read at every charge (DEC-110).
    function renounceOwnership() public view override onlyOwner {
        revert RenounceDisabled();
    }

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-052: the manager returns to the default.
    function clearProtocolSliceBps(address manager) external onlyOwner {
        if (manager == address(0)) revert ZeroManager();
        uint16 previous = protocolSliceBps(manager);
        delete _entries[manager];
        emit ProtocolSliceSet(manager, previous, DEFAULT_PROTOCOL_SLICE_BPS, false);
    }
}
