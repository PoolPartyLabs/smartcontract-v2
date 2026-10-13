// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

/// @notice Read-only launch wiring expected from T2b's CCTP adapter (DEC-191).
/// @dev Zero deadline denotes a pending claim, never an Across timeout/refund. No Core transit implementation here.
interface ISolanaTransportV6 {
    function target() external view returns (address);
    function fillDeadlineSeconds() external view returns (uint32);
}
