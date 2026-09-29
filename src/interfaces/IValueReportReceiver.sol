// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReportCodec} from "../libraries/ReportCodec.sol";

/// @title IValueReportReceiver
/// @notice Hub contract that accepts Wormhole value reports from a fund's Spoke Vaults and keeps the latest one per
///         spoke.
/// @dev DEC-086: Wormhole is the report channel; the emitter must be the fund's Spoke Vault. DEC-093: finalized
///      consistency only; anyone may deliver; strictly increasing sequence per (emitter chain, emitter address),
///      rejecting replays and out-of-order VAAs. DEC-094, DEC-099: a report older than the spoke's max report age at
///      delivery is rejected. One receiver per fund; spoke indices are Mandate spoke indices.
interface IValueReportReceiver {
    /// @notice A report was accepted and stored.
    event ReportAccepted(
        uint256 indexed spokeIndex,
        uint16 indexed emitterChainId,
        bytes32 emitterAddress,
        uint64 wormholeSequence,
        uint64 reportSequence,
        uint64 blockNumber,
        uint64 timestamp
    );

    /// @notice The Core Bridge rejected the VAA.
    error InvalidVaa(string reason);

    /// @notice The VAA emitter is not a Mandate Spoke Vault.
    error UnknownEmitter(uint16 emitterChainId, bytes32 emitterAddress);

    /// @notice The VAA was not published with finalized consistency (DEC-093).
    error NotFinalized(uint8 consistencyLevel);

    /// @notice The VAA sequence is not strictly greater than the last accepted one (DEC-093).
    error SequenceNotIncreasing(uint64 lastAccepted, uint64 received);

    /// @notice The report sequence inside the payload is not strictly greater than the last accepted one.
    error ReportSequenceNotIncreasing(uint64 lastAccepted, uint64 received);

    /// @notice The report is older than the spoke's max report age at delivery (DEC-099).
    error ReportTooOld(uint256 age, uint32 maxReportAge);

    /// @notice The report is for another fund or another chain than its emitter.
    error ReportMismatch();

    /// @notice No report was ever accepted for the spoke.
    error NoReport(uint256 spokeIndex);

    /// @notice The Wormhole Core Bridge on the hub.
    function coreBridge() external view returns (address);

    /// @notice The fund's Core Vault, notified on every accepted report.
    function coreVault() external view returns (address);

    /// @notice Verifies and stores a report, then notifies the Core Vault (`ICoreVault.onReportAccepted`).
    ///         Permissionless (DEC-093).
    /// @return spokeIndex Mandate index of the reporting spoke.
    /// @return reportSequence Sequence inside the payload.
    function deliver(bytes calldata vaa) external returns (uint256 spokeIndex, uint64 reportSequence);

    /// @notice Whether a report was ever accepted for the spoke.
    function hasReport(uint256 spokeIndex) external view returns (bool);

    /// @notice Latest accepted report of a spoke. Reverts with `NoReport` if none.
    /// @return report Decoded report.
    /// @return wormholeSequence VAA sequence of that report.
    /// @return acceptedAt Hub timestamp at which it was accepted.
    function latestReport(uint256 spokeIndex)
        external
        view
        returns (ReportCodec.Report memory report, uint64 wormholeSequence, uint64 acceptedAt);

    /// @notice Last accepted VAA sequence of a spoke (meaningful only when `hasReport`).
    function lastWormholeSequence(uint256 spokeIndex) external view returns (uint64);

    /// @notice Max report age of a spoke, from the Mandate (DEC-094, DEC-099; value OPEN, Q57 / Q66).
    function maxReportAge(uint256 spokeIndex) external view returns (uint32);

    /// @notice Whether the spoke's latest report is younger than its max report age now.
    /// @dev Q57 reading (OPEN): a mint requires fresh reports; an Idle-paid payout does not.
    function isReportFresh(uint256 spokeIndex) external view returns (bool);

    /// @notice Variation band on accepted report values, in bps; 0 means disabled.
    /// @dev OPEN (Q57 (d), erratum 12): the 2% band was proposed and never answered. MVP: slot reserved, disabled.
    function variationBandBps() external view returns (uint16);
}
