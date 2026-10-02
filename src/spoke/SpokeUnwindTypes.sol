// SPDX-License-Identifier: MIT
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

    /// @notice DEC-151/156: sales retained across bridge refusal, plus costs restored if the send is refunded.
    struct Pending {
        uint256 sentSpotOut;
        uint256 sentMarketCost;
        uint256 sentLeaverCost;
        uint256 proceeds;
        uint256 spotOut;
        uint256 marketCost;
        uint256 leaverCost;
        bytes32 transitId;
        uint32 attempt;
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

    /// @notice The name of a step in `Book.delivered`: a position by its adapter and key, a non-base Unallocated
    ///         Balance by a zero adapter and the token.
    function stepId(address adapter, bytes32 positionKey) internal pure returns (bytes32) {
        return keccak256(abi.encode(adapter, positionKey));
    }
}
