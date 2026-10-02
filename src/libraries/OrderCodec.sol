// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";

/// @title OrderCodec
/// @notice Versioned encoding of the orders the Core Vault publishes through Wormhole for the fund's Spoke Vaults, and
///         the publisher the Hub calls.
/// @dev DEC-111, DEC-120 items 1-2, DEC-139: when a payout needs the spokes, the Core Vault publishes an unwind order
///      on the Hub's Wormhole Core with instant consistency, and any address delivers it to each Spoke Vault, which
///      checks it with `OrderVerifier`. DEC-157: no inactivity switch; an order is the only Hub-to-spoke instruction.
///      The same channel carries the closure order (DEC-121, DEC-147, DEC-149) and the income collection order
///      (DEC-122, DEC-124, DEC-161).
/// @dev DEC-111: an order never names a destination. It only authorises the receiving Spoke Vault to unwind its own
///      positions (or collect its own income) and send the proceeds to the Core Vault through the Mandate's bridge
///      adapter, so a valid order cannot move value out of the fund.
/// @dev Layout: `abi.encode(uint256 version, Order order)`. A reader checks the first word before decoding.
library OrderCodec {
    /// @notice Current payload version.
    uint256 internal constant VERSION = 1;

    /// @notice Unwind order: the Spoke Vault exits `fracNum / fracDen` of every position and sends the proceeds home
    ///         (DEC-120, DEC-137, DEC-139).
    uint8 internal constant UNWIND = 1;

    /// @notice Closure order: the Spoke Vault exits everything and sends it home (DEC-121, DEC-147, DEC-149). The
    ///         fraction is always 1/1, whatever the publisher wrote.
    uint8 internal constant CLOSE = 2;

    /// @notice Income collection order: the Spoke Vault collects its positions' income and sends it home (DEC-122,
    ///         DEC-124, DEC-161). The fraction is not read.
    uint8 internal constant COLLECT = 3;

    /// @notice Wormhole consistency level of an order: instant (DEC-120 item 1, DEC-111). Reports stay finalized
    ///         (DEC-093). A Hub reorg could orphan an executed order; its proceeds land in Idle as Principal.
    uint8 internal constant CONSISTENCY_INSTANT = 200;

    /// @notice Wormhole nonce: a batching tag only; replay protection is the (emitter, sequence) pair (DEC-093).
    uint32 internal constant NONCE = 0;

    /// @notice Highest payout mode value; mirrors `ICoreVault.PayoutMode` (Instant = 0, Standard = 1, DEC-075).
    uint8 internal constant MAX_PAYOUT_MODE = 1;

    /// @notice An order from the Core Vault to every Spoke Vault of the fund.
    /// @param kind `UNWIND`, `CLOSE` or `COLLECT`.
    /// @param fundId Fund identifier; a Spoke Vault refuses another fund's order (DEC-111).
    /// @param requestId What the order serves: the Payout Request (requester and request nonce) for `UNWIND`, the
    ///        closure for `CLOSE`, the collection for `COLLECT`. Chosen by the Hub.
    /// @param attempt Retry counter of the same request (DEC-151); a retry is a new order with a new id.
    /// @param fracNum Numerator of the share of every position to unwind, the 2% margin included (DEC-137, DEC-081).
    /// @param fracDen Denominator of that share; nonzero and at least `fracNum` for `UNWIND`.
    /// @param maxLossBps The requester's optional maximum loss per sale, in bps (DEC-140, DEC-148, DEC-156 item 2).
    ///        Not interpreted here: the executor applies the "0 or >= 10,000 means none" reading (D-23).
    /// @param payoutMode `ICoreVault.PayoutMode` of the request, which decides who bears the Market Costs (DEC-118,
    ///        DEC-141). 0 for orders that serve no payout.
    /// @param data Extension field the order kinds may use; empty unless an order kind defines it.
    struct Order {
        uint8 kind;
        bytes32 fundId;
        bytes32 requestId;
        uint32 attempt;
        uint256 fracNum;
        uint256 fracDen;
        uint16 maxLossBps;
        uint8 payoutMode;
        bytes data;
    }

    /// @notice The payload carries a version this code does not know.
    error UnsupportedOrderVersion(uint256 version);

    /// @notice The payload is shorter than one ABI word.
    error OrderPayloadTooShort(uint256 length);

    /// @notice The order kind is not `UNWIND`, `CLOSE` or `COLLECT`.
    error UnknownOrderKind(uint8 kind);

    /// @notice An unwind order's denominator is zero or its numerator exceeds it.
    error InvalidOrderFraction(uint256 fracNum, uint256 fracDen);

    /// @notice The payout mode is not an `ICoreVault.PayoutMode`.
    error InvalidPayoutMode(uint8 payoutMode);

    /// @notice Identifier of an order: one per (kind, fund, request, attempt). The spoke executes an order id once.
    /// @dev The kind is part of the id so a collection id and a Payout Request id can never name the same order.
    function orderId(Order memory o) internal pure returns (bytes32) {
        return keccak256(abi.encode(o.kind, o.fundId, o.requestId, o.attempt));
    }

    /// @notice Encodes an order with the current version, after `check` (a `CLOSE` is written with 1/1).
    function encode(Order memory o) internal pure returns (bytes memory) {
        check(o);
        return abi.encode(VERSION, o);
    }

    /// @notice Reads the version word of a payload without decoding the rest.
    function versionOf(bytes memory payload) internal pure returns (uint256) {
        if (payload.length < 32) revert OrderPayloadTooShort(payload.length);
        return abi.decode(payload, (uint256));
    }

    /// @notice Decodes a payload and applies `check`. Reverts on an unknown version, an unknown kind, an invalid
    ///         unwind fraction, an unknown payout mode or a malformed payload.
    function decode(bytes memory payload) internal pure returns (Order memory o) {
        uint256 version = versionOf(payload);
        if (version != VERSION) revert UnsupportedOrderVersion(version);
        (, o) = abi.decode(payload, (uint256, Order));
        check(o);
    }

    /// @notice Validates an order in place: a known kind and payout mode; for `UNWIND`, `0 < fracDen` and
    ///         `fracNum <= fracDen` (never more than everything, DEC-137); a `CLOSE` is set to 1/1 (DEC-147).
    /// @dev Shared by `encode` (the Hub never publishes an order the spokes would refuse) and `decode` (the spoke never
    ///      executes one).
    function check(Order memory o) internal pure {
        uint8 kind = o.kind;
        if (kind == UNWIND) {
            if (o.fracDen == 0 || o.fracNum > o.fracDen) revert InvalidOrderFraction(o.fracNum, o.fracDen);
        } else if (kind == CLOSE) {
            o.fracNum = 1;
            o.fracDen = 1;
        } else if (kind != COLLECT) {
            revert UnknownOrderKind(kind);
        }
        if (o.payoutMode > MAX_PAYOUT_MODE) revert InvalidPayoutMode(o.payoutMode);
    }

    /// @notice Publishes an order on the Hub's Wormhole Core with instant consistency (DEC-120 item 1).
    /// @dev Must run in the Core Vault's context (the Core Vault itself or a linked library it delegatecalls): the Core
    ///      records the caller as the emitter, and every Spoke Vault accepts only the Core Vault (DEC-111). Libraries
    ///      cannot be payable, so the entry point passes its `msg.value` as `messageFee`; the Core requires exactly
    ///      `ICoreBridge.messageFee()` (0 on Arbitrum One today) and reverts otherwise.
    /// @param core The Hub's Wormhole Core.
    /// @param o The order; `check`ed before publishing.
    /// @param messageFee Native amount forwarded as the Wormhole message fee.
    /// @return sequence The Wormhole sequence of the order (per emitter, from 0).
    function publish(address core, Order memory o, uint256 messageFee) internal returns (uint64 sequence) {
        sequence = ICoreBridge(core).publishMessage{value: messageFee}(NONCE, encode(o), CONSISTENCY_INSTANT);
    }
}
