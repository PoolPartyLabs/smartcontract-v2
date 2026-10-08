// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

/// @title SpokeUnwindTypes
/// @notice The unwind's own state, types and errors: its book in the Spoke Vault's state and the atomic step of the
///         automatic unwind (`SpokeVaultUnwind`, `SpokeUnwindLib`).
/// @dev WP-07 D1: the unwind work (the proportional unwind and the spoke unwind orders, DEC-120, DEC-137, DEC-139)
///      adds fields only to `Book` and edits only this types file, never `SpokeVaultTypes`.
library SpokeUnwindTypes {
    struct ManualSale {
        address adapter;
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint16 maxLossBps;
        bytes route;
    }
    /// @notice DEC-120: bounded post-unwind history carried by report v4.
    uint256 internal constant REPORTED_RESULTS = 16;
    uint256 internal constant ENCODED_RESULT_SIZE = 13 * 32;

    function encodeResults(OrderResult[] memory results) internal pure returns (bytes memory blob) {
        blob = abi.encode(results);
        assert(blob.length == 64 + results.length * ENCODED_RESULT_SIZE);
    }

    function validResults(bytes memory blob) internal pure returns (bool) {
        if (blob.length < 64) return false;
        uint256 offset;
        uint256 count;
        uint256 stride = ENCODED_RESULT_SIZE;
        assembly ("memory-safe") {
            offset := mload(add(blob, 32))
            count := mload(add(blob, 64))
        }
        if (offset != 32 || count > REPORTED_RESULTS || blob.length != 64 + count * stride) return false;
        for (uint256 index; index < count; ++index) {
            uint256 attempt;
            uint256 refunded;
            assembly ("memory-safe") {
                let entry := add(add(blob, 96), mul(index, stride))
                attempt := mload(add(entry, 64))
                refunded := mload(add(entry, 352))
            }
            if (attempt > type(uint32).max || refunded > 1) return false;
        }
        return true;
    }

    /// @notice DEC-105/139: Principal send and Market Costs for one attempt, in spoke base-token units.
    struct OrderResult {
        bytes32 orderId;
        bytes32 requestId;
        uint32 attempt;
        bytes32 transitId;
        uint256 amountSent;
        uint256 amountToArrive;
        uint256 spotOut;
        uint256 marketCost;
        uint256 leaverCost;
        uint256 delivered;
        uint256 excluded;
        bool refunded;
        uint256 closureExcessCost;
    }

    /// @notice DEC-151/156: unsent proceeds and cumulative sale costs retained across refusals and refunds.
    struct Pending {
        uint256 proceeds;
        uint256 spotOut;
        uint256 marketCost;
        uint256 leaverCost;
        bytes32 transitId;
        uint256 bridgeCost;
    }

    /// @notice The unwind's state inside `SpokeVaultTypes.State`.
    /// @param reportBlob What the next reports carry as `ReportCodec.Report.unwindResults`: the results of the unwind
    ///        orders this vault executed (DEC-120 item 2, DEC-105: the Hub settles on the post-unwind report), opaque
    ///        to the report builder. Empty until the unwind orders exist; their work owns its encoding and how long an
    ///        entry stays in it.
    /// @param delivered Per Payout Request, the positions and Unallocated Balance tokens that already delivered their
    ///        share (DEC-151), by `stepId`: the registry is swap-and-pop, so a position is named by its adapter and
    ///        key, never by its slot.
    struct Book {
        bytes reportBlob;
        mapping(bytes32 requestId => mapping(bytes32 stepId => bool)) delivered;
        mapping(bytes32 requestId => Pending) pending;
        bool closed;
        uint256 reservedBase;
        uint256 closureExcessCost;
        uint64 closureStartedAt;
        uint64[] saleTimes;
        uint256[] saleCosts;
        mapping(bytes32 orderId => bool) executed;
        mapping(bytes32 requestId => bytes32[]) transits;
        mapping(bytes32 transitId => bool) refundRecovered;
        mapping(bytes32 transitId => bytes32) transitRequest;
        mapping(bytes32 transitId => bool) feeRefunded;
        mapping(bytes32 transitId => bool) retired;
    }

    /// @notice One atomic step of an automatic unwind (`ISpokeVaultUnwind.unwindStep`).
    /// @param adapter The position's adapter; zero for the sale of a share of a non-base Unallocated Balance.
    /// @param positionKey The position's key; with `adapter` zero, the token in the low 160 bits.
    /// @param fracNum Numerator of the share to unwind (DEC-137).
    /// @param fracDen Denominator of that share.
    /// @param maxLossBps The requester's maximum loss per sale; 0 or >= 10,000 for none (DEC-140, D-23).
    /// @param instant Whether the request is an Instant Payout, whose requester bears each sale's whole Market Cost
    ///        (DEC-118); otherwise the fund absorbs up to 1% of each sale's value (DEC-141).
    struct Step {
        address adapter;
        bytes32 positionKey;
        uint256 fracNum;
        uint256 fracDen;
        uint16 maxLossBps;
        bool instant;
    }

    /// @notice What one step's sales did (`ISpokeVaultUnwind.UnwindResult` sums them).
    struct StepResult {
        uint256 spotOut;
        uint256 marketCost;
        uint256 leaverCost;
    }

    /// @notice `unwindStep` was called by an address other than the vault itself.
    error UnwindStepNotSelf(address caller);
    error SpokeClosed();
    error UnwindProceedsReserved();
    error OrderAlreadyExecuted(bytes32 orderId);
    error OrderResultCapacity();
    error InvalidTransitOutcome();

    /// @notice The name of a step in `Book.delivered`: a position by its adapter and key, a non-base Unallocated
    ///         Balance by a zero adapter and the token.
    function stepId(address adapter, bytes32 positionKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapter, positionKey));
    }
}
