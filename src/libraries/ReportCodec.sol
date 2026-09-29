// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ReportCodec
/// @notice Versioned encoding of the value report a Spoke Vault publishes through Wormhole and the hub accepts.
/// @dev DEC-070: the report is built by the Spoke Vault from its own ledger. DEC-086, DEC-093: carried by Wormhole
///      with finalized consistency. The payload is a superset that serves every spoke pricing option still OPEN
///      (Q57 (b)): token quantities, position ranges and liquidity, and monotonic cumulative income counters, so the
///      hub can price with a report value or with its own price source without a payload change.
/// @dev Layout: `abi.encode(uint256 version, Report report)`. A reader checks the first word before decoding.
library ReportCodec {
    /// @notice Current payload version.
    uint256 internal constant VERSION = 1;

    /// @notice A token and an amount in that token's base units.
    struct TokenAmount {
        address token;
        uint256 amount;
    }

    /// @notice A transit reference and the amount it carries.
    struct TransitAmount {
        bytes32 transitId;
        uint256 amount;
    }

    /// @notice One open position of the Spoke Vault, as its adapter reports it (DEC-079). Same fields as
    ///         `IAdapter.PositionValue` plus the adapter address.
    struct PositionReport {
        address adapter;
        bytes32 poolKey;
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token0;
        address token1;
        uint256 principal0;
        uint256 principal1;
        uint256 income0;
        uint256 income1;
    }

    /// @notice The value report payload.
    /// @param fundId Fund identifier; the hub rejects a report for another fund.
    /// @param sequence Spoke Vault report counter, strictly increasing per spoke (DEC-093).
    /// @param spokeChainId EVM chain id of the reporting Spoke Vault.
    /// @param blockNumber Spoke block at which the report was built (DEC-083, DEC-105).
    /// @param timestamp Spoke block timestamp at which the report was built (DEC-094, DEC-099 age rule).
    /// @param unallocated Unallocated Balance per token, principal only (DEC-055, DEC-080: ledger, never balanceOf).
    /// @param positions Every open position with principal and income separated (DEC-079).
    /// @param cumulativeIncome Monotonic income-since-inception counter per income token (Q60, DEC-092).
    /// @param cumulativeReceived Total principal ever credited from hub transfers, in the spoke's base token units.
    /// @param cumulativeSentHome Total ever sent to the hub, in the spoke's base token units (Q66, DEC-105).
    /// @param arrivedTransits Hub-to-spoke transits the spoke credited, with the amount credited (DEC-090). The hub
    ///        confirms only ids it sent; the Spoke Vault chooses the retention window, and a repeated id is a no-op
    ///        on the hub.
    /// @param inFlightToHub Spoke-to-hub transits the spoke sent whose outcome it does not yet know, with the amount
    ///        that will arrive (DEC-085). A list rather than a scalar so the hub can reconcile by transfer id and never
    ///        count an arrival twice (DEC-104).
    struct Report {
        bytes32 fundId;
        uint64 sequence;
        uint256 spokeChainId;
        uint64 blockNumber;
        uint64 timestamp;
        TokenAmount[] unallocated;
        PositionReport[] positions;
        TokenAmount[] cumulativeIncome;
        uint256 cumulativeReceived;
        uint256 cumulativeSentHome;
        TransitAmount[] arrivedTransits;
        TransitAmount[] inFlightToHub;
    }

    /// @notice The payload carries a version this code does not know.
    error UnsupportedReportVersion(uint256 version);

    /// @notice The payload is shorter than one ABI word.
    error ReportPayloadTooShort(uint256 length);

    /// @notice Encodes a report with the current version.
    function encode(Report memory report) internal pure returns (bytes memory) {
        return abi.encode(VERSION, report);
    }

    /// @notice Reads the version word of a payload without decoding the rest.
    function versionOf(bytes memory payload) internal pure returns (uint256) {
        if (payload.length < 32) revert ReportPayloadTooShort(payload.length);
        return abi.decode(payload, (uint256));
    }

    /// @notice Decodes a payload. Reverts on an unknown version or a malformed payload.
    function decode(bytes memory payload) internal pure returns (Report memory report) {
        uint256 version = versionOf(payload);
        if (version != VERSION) revert UnsupportedReportVersion(version);
        (, report) = abi.decode(payload, (uint256, Report));
    }
}
