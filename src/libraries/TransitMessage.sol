// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {TransferKind} from "../interfaces/FundTypes.sol";

/// @title TransitMessage
/// @notice Versioned encoding of the message a vault attaches to a bridge transfer, read back by the receiving
///         vault's `handleV3AcrossMessage`.
/// @dev DEC-087: the sending vault, never the adapter, fixes the message content.
/// @dev Security note: Across passes no depositor to `handleV3AcrossMessage`, so anyone can make a deposit whose
///      message decodes correctly. A decoded message is a claim, not a proof: the receiving side must match
///      `transitId` against transits it knows (hub) or report it for the hub to match (spoke). See ICoreVault and
///      ISpokeVault.
library TransitMessage {
    /// @notice Current message version.
    uint256 internal constant VERSION = 1;

    /// @notice Raised when a message carries a version this code does not know.
    error UnsupportedTransitMessageVersion(uint256 version);

    /// @notice Encodes a transit message.
    /// @param fundId Fund identifier of the sending vault.
    /// @param originChainId EVM chain id of the sending vault.
    /// @param transitId Vault-assigned transit id (unique per sending vault).
    /// @param kind Principal or income (DEC-092).
    function encode(bytes32 fundId, uint256 originChainId, bytes32 transitId, TransferKind kind)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(VERSION, fundId, originChainId, transitId, kind);
    }

    /// @notice Decodes a transit message. Reverts on an unknown version or a malformed payload.
    function decode(bytes memory message)
        internal
        pure
        returns (bytes32 fundId, uint256 originChainId, bytes32 transitId, TransferKind kind)
    {
        uint256 version = abi.decode(message, (uint256));
        if (version != VERSION) revert UnsupportedTransitMessageVersion(version);
        (, fundId, originChainId, transitId, kind) =
            abi.decode(message, (uint256, bytes32, uint256, bytes32, TransferKind));
    }
}
