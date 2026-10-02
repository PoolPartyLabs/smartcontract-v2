// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransferKind} from "../interfaces/FundTypes.sol";

/// @title ReportCodec
/// @notice Versioned encoding of the value report a Spoke Vault publishes through Wormhole and the hub accepts.
/// @dev DEC-070: the report is built by the Spoke Vault from its own ledger. DEC-086, DEC-093: carried by Wormhole
///      with finalized consistency. The payload is a superset that serves every spoke pricing option still OPEN
///      (Q57 (b)): token quantities, position ranges and liquidity, and monotonic cumulative income counters, so the
///      hub can price with a report value or with its own price source without a payload change.
/// @dev Layout: `abi.encode(uint256 version, Report report)`. A reader checks the first word before decoding.
/// @dev Versions: 1, the module build; 2, the consolidation of 2026-09-29: `inFlightToHub` entries carry their
///      `TransferKind` (CV-OQ-1, DEC-085, DEC-092), and the spoke's collected income bucket and Operating Cash travel
///      for Gross Assets (DEC-098); 3, the security review of 2026-09-30: the report carries the Spoke Vault's
///      `mandateHash` so the hub accepts reports only from a spoke running its own Mandate (S-6, FF-OQ-1); 4, WP-07 D3:
///      the report carries the results of the Hub's orders the spoke executed, `unwindResults` (DEC-105, DEC-120 item
///      2) and `collectionResults` (DEC-122, DEC-161), opaque here. Nothing was ever deployed with versions 1 to 3.
library ReportCodec {
    /// @notice Current payload version.
    uint256 internal constant VERSION = 4;

    /// @notice Most arrivals a report lists in `arrivedTransits` (OQ-09 stance; Spoke Vault verifier finding).
    /// @dev Shared by the Spoke Vault, which keeps a ring of this size, and the Core Vault, which accepts a report's
    ///      silence about a transit as proof of non-arrival only while the report lists fewer entries than this (a full
    ///      window may have evicted the id).
    uint256 internal constant ARRIVAL_WINDOW = 256;

    /// @notice How long after its fill deadline a Spoke Vault keeps an unrefunded send home in `inFlightToHub`.
    /// @dev Security review S-3 (DEC-063, DEC-085, DEC-104). Shared by the Spoke Vault, which lists a send home until
    ///      its refund is recognized or this long after its fill deadline, and the Core Vault, which lets an arrival no
    ///      accepted report listed be recovered only once no report can list it any more (S-4). Across refunds an
    ///      expired deposit 55 to 90 min after its deadline (DEC-063 measured facts); three days is a wide margin.
    ///      OPEN value (security review parameter, to confirm with the founder).
    uint256 internal constant HUB_BOUND_RETENTION = 3 days;

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

    /// @notice A spoke-to-hub transfer in flight: its id, the amount that will arrive and what it carries.
    /// @dev CV-OQ-1: the kind lets the hub keep Income in flight home out of Share Assets (DEC-092) while Principal in
    ///      flight home stays in (DEC-085, DEC-104), and credit an arrival by the reported kind rather than by the
    ///      unauthenticated Across message (OQ-01). Both kinds count toward the Spoke Cap (DEC-066 B1).
    struct HubBoundAmount {
        bytes32 transitId;
        uint256 amount;
        TransferKind kind;
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
    /// @param mandateHash The reporting Spoke Vault's `mandateHash`; the hub rejects a report whose hash differs from
    ///        the Core Vault's, so a Spoke Vault created from another Mandate at the fund's address is never trusted
    ///        (security review S-6, FF-OQ-1).
    /// @param sequence Spoke Vault report counter, strictly increasing per spoke (DEC-093).
    /// @param spokeChainId EVM chain id of the reporting Spoke Vault.
    /// @param blockNumber Spoke block at which the report was built (DEC-083, DEC-105).
    /// @param timestamp Spoke block timestamp at which the report was built (DEC-094, DEC-099 age rule).
    /// @param unallocated Unallocated Balance per token, principal only (DEC-055, DEC-080: ledger, never balanceOf).
    /// @param positions Every open position with principal and income separated (DEC-079).
    /// @param cumulativeIncome Monotonic income-since-inception counter per income token (Q60, DEC-092); informational
    ///        (ruling 2026-09-29: spoke income is attributed only when it reaches the hub as Income).
    /// @param collectedIncome The spoke's collected income bucket per ledger token, not yet sent home (DEC-092: outside
    ///        Share Assets, inside Gross Assets, DEC-098).
    /// @param operatingCash The spoke's Operating Cash, in base token units (DEC-096: outside Share Assets, inside Gross
    ///        Assets, DEC-098).
    /// @param cumulativeReceived Total principal ever credited from hub transfers, in the spoke's base token units.
    /// @param cumulativeSentHome Total ever sent to the hub, in the spoke's base token units (Q66, DEC-105).
    /// @param arrivedTransits Hub-to-spoke Principal transits the spoke credited, with the total credited per id
    ///        (DEC-090): the last `ARRIVAL_WINDOW` ids whose credited total reached the Spoke Vault's listing minimum,
    ///        oldest first. The hub confirms only ids it sent, only once the listed total reaches the amount it expects
    ///        to arrive (OQ-01, OQ-09), and a repeated id is a no-op on the hub.
    /// @param inFlightToHub Spoke-to-hub transits the spoke sent whose outcome it does not yet know, with the amount
    ///        that will arrive (DEC-085) and the kind (Principal or Income, DEC-092). A list rather than a scalar so the
    ///        hub can reconcile by transfer id and never count an arrival twice (DEC-104).
    /// @param unwindResults What the Spoke Vault's unwind book holds for the Hub (`SpokeUnwindTypes.Book.reportBlob`):
    ///        the results of the unwind and closure orders it executed, which the Hub's settlement waits for (DEC-105,
    ///        DEC-120 items 2-3). Opaque here: the unwind work owns the encoding; empty until it exists.
    /// @param collectionResults What the Spoke Vault's income book holds for the Hub
    ///        (`SpokeIncomeTypes.Book.reportBlob`): the results of the collection orders it executed (DEC-122 item 5,
    ///        DEC-161). Opaque here: the income work owns the encoding; empty until it exists.
    struct Report {
        bytes32 fundId;
        bytes32 mandateHash;
        uint64 sequence;
        uint256 spokeChainId;
        uint64 blockNumber;
        uint64 timestamp;
        TokenAmount[] unallocated;
        PositionReport[] positions;
        TokenAmount[] cumulativeIncome;
        TokenAmount[] collectedIncome;
        uint256 operatingCash;
        uint256 cumulativeReceived;
        uint256 cumulativeSentHome;
        TransitAmount[] arrivedTransits;
        HubBoundAmount[] inFlightToHub;
        bytes unwindResults;
        bytes collectionResults;
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
