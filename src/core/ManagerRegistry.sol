// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IManagerRegistry} from "../interfaces/IManagerRegistry.sol";

/// @title ManagerRegistry
/// @notice Per-manager properties valid across all of a manager's funds, outside the Mandate: today, the protocol
///         slice of the manager fee. See IManagerRegistry.
/// @dev DEC-106: default slice 50% of the manager fee, configurable per manager. DEC-110: a separate registry read at
///      every charge; a change applies from the next charge. DEC-052: a manager without an entry gets the default,
///      with no API dependency.
/// @dev OPEN (LC-142, OQ-11): the writer is the registry's `Ownable2Step` owner (the protocol admin) and the cap is
///      `MAX_PROTOCOL_SLICE_BPS` = 5,000 (the LC-57 proposal), so a slice can only be at or below the default.
/// @dev DEC-022: a global registry that never holds funds; deployed without a proxy all the same.
contract ManagerRegistry is IManagerRegistry, Ownable2Step {
    /// @inheritdoc IManagerRegistry
    /// @dev DEC-106: 50% of the manager fee.
    uint16 public constant DEFAULT_PROTOCOL_SLICE_BPS = 5000;

    /// @inheritdoc IManagerRegistry
    /// @dev OPEN (LC-142, LC-57): research proposal 5,000 bps; equal to the default (OQ-11: only at or below it).
    uint16 public constant MAX_PROTOCOL_SLICE_BPS = 5000;

    struct Entry {
        bool exists;
        uint16 bps;
    }

    mapping(address manager => Entry) internal _entries;

    /// @param initialOwner Protocol admin that writes slices (LC-142 OPEN).
    constructor(address initialOwner) Ownable(initialOwner) {}

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-052, DEC-106: the default when the manager has no entry; an explicit 0 is honoured.
    function protocolSliceBps(address manager) public view returns (uint16) {
        Entry memory e = _entries[manager];
        return e.exists ? e.bps : DEFAULT_PROTOCOL_SLICE_BPS;
    }

    /// @inheritdoc IManagerRegistry
    function hasEntry(address manager) external view returns (bool) {
        return _entries[manager].exists;
    }

    /// @inheritdoc IManagerRegistry
    /// @dev DEC-110: applies from the next charge. LC-142 (OPEN): owner only, capped at `MAX_PROTOCOL_SLICE_BPS`.
    function setProtocolSliceBps(address manager, uint16 bps) external onlyOwner {
        if (manager == address(0)) revert ZeroManager();
        if (bps > MAX_PROTOCOL_SLICE_BPS) revert ProtocolSliceAboveMax(bps, MAX_PROTOCOL_SLICE_BPS);
        uint16 previous = protocolSliceBps(manager);
        _entries[manager] = Entry({exists: true, bps: bps});
        emit ProtocolSliceSet(manager, previous, bps, true);
    }

    /// @notice Disabled: the owner can hand the writer role over (two steps) but never drop it.
    /// @dev LC-142 (OPEN, writer = protocol admin) and the report-receiver verifier finding: renouncing would freeze
    ///      every manager's slice for good with one call on a global registry read at every charge (DEC-110).
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
