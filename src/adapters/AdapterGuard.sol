// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IAdapterGuard} from "../interfaces/IAdapterGuard.sol";

/// @title AdapterGuard
/// @notice Base implementation of the quarantine and deprecation flags for every adapter.
/// @dev DEC-021, DEC-056, DEC-058: entry and increase verbs call `_requireEntryAllowed()`; decrease, close and collect
///      verbs never read the flags. Keeping the read behind one internal function keeps the L1/L2 location choice
///      (Q17-2b, OPEN) local to this contract.
abstract contract AdapterGuard is IAdapterGuard {
    /// @inheritdoc IAdapterGuard
    address public immutable guardian;

    /// @inheritdoc IAdapterGuard
    bool public paused;

    /// @inheritdoc IAdapterGuard
    bool public deprecated;

    /// @notice Raised when the guardian address is zero at construction.
    error ZeroGuardian();

    constructor(address guardian_) {
        if (guardian_ == address(0)) revert ZeroGuardian();
        guardian = guardian_;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian(msg.sender);
        _;
    }

    /// @inheritdoc IAdapterGuard
    /// @dev DEC-021: manual pause; DEC-056: pause is a quarantine of entries only.
    function setPaused(bool paused_) external onlyGuardian {
        paused = paused_;
        emit PausedSet(paused_);
    }

    /// @inheritdoc IAdapterGuard
    /// @dev DEC-058: global, immediate, irreversible. A second call is a no-op without an event.
    function deprecate() external onlyGuardian {
        if (deprecated) return;
        deprecated = true;
        emit AdapterDeprecated();
    }

    /// @dev DEC-056, DEC-058: reverts when an entry or increase is not allowed. Never call it from an exit verb.
    function _requireEntryAllowed() internal view {
        if (deprecated) revert AdapterIsDeprecated();
        if (paused) revert AdapterPaused();
    }
}
