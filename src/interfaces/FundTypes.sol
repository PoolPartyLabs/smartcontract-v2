// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Fund types shared by the Core Vault, the Spoke Vault and the bridge adapters
/// @notice File-level declarations so every module imports one definition.

/// @notice State of one cross-chain transfer in the core transit state machine.
/// @dev DEC-066: In-flight Value counts toward the Spoke Cap only while the outcome is unknown and is released by
///      confirmed arrival, attested expiry or recognized refund, whichever comes first.
/// @dev DEC-090: the core owns one transit state machine for all bridges; each bridge adapter translates into it.
/// @dev OPEN (QB11, erratum 16): three states versus four. The MVP keeps the four Across outcomes of DEC-066 because
///      a three-state machine can be derived from these four without losing information.
enum TransitState {
    None,
    Sent,
    ArrivalConfirmed,
    ExpiryAttested,
    RefundRecognized
}

/// @notice What a cross-chain transfer carries, so the receiving vault books it in the right base.
/// @dev DEC-092: collected income sits in its own bucket, outside Share Assets; principal enters Idle (hub) or
///      Unallocated Balance (spoke). The kind travels in the bridge message (see TransitMessage).
enum TransferKind {
    Principal,
    Income
}

/// @notice Funding source of an Operating Expense.
/// @dev DEC-041: every Operating Expense declares its source, in this order: that exit's Payout Fee, then Operating
///      Cash, then Share Assets; the final expense event carries this payer field.
enum ExpensePayer {
    PayoutFee,
    OperatingCash,
    ShareAssets
}

/// @notice One cross-chain transfer as the sending vault books it.
/// @dev DEC-085: Share Assets count it at `amountToArrive` (the signed Across `outputAmount`).
/// @dev DEC-066 (C1): the Spoke Cap counts it at `amountSent` while the outcome is unknown.
/// @param destinationChainId EVM chain id of the receiving vault.
/// @param bridgeAdapter Mandate-listed bridge adapter that submitted the transfer (DEC-087, DEC-088).
/// @param escrow Depositor of record that receives an Across refund (per-send TransitEscrow clone, QA6 OPEN).
/// @param inputToken Token that left the sending vault.
/// @param outputToken Token the receiving vault gets.
/// @param amountSent Input amount, in `inputToken` base units.
/// @param amountToArrive Output amount, in `outputToken` base units.
/// @param bridgeRef Protocol-level reference returned by the bridge adapter (Across: the deposit id).
/// @param sentAt Block timestamp of the send.
/// @param fillDeadline Timestamp after which the bridge can no longer deliver (DEC-066: send time + 6 h).
/// @param kind Principal or income.
/// @param state Current transit state.
struct Transit {
    uint256 destinationChainId;
    address bridgeAdapter;
    address escrow;
    address inputToken;
    address outputToken;
    uint256 amountSent;
    uint256 amountToArrive;
    bytes32 bridgeRef;
    uint64 sentAt;
    uint32 fillDeadline;
    TransferKind kind;
    TransitState state;
}

/// @notice The part of a signed bridge quote that the manager supplies on a send.
/// @dev The calling vault, not the manager and not the adapter, fixes the recipient and the token pair (DEC-087).
///      The vault rejects the quote when `inputAmount - outputAmount` exceeds the Mandate's `maxBridgeFeeBps`
///      (QA19 OPEN as to the value).
/// @param outputAmount Amount that will arrive on the destination chain (DEC-085).
/// @param quoteTimestamp Across quote timestamp (must be within the SpokePool `depositQuoteTimeBuffer`).
/// @param exclusivityDeadline Across exclusivity deadline, 0 for none.
/// @param exclusiveRelayer Across exclusive relayer, address(0) for none.
struct BridgeQuote {
    uint256 outputAmount;
    uint32 quoteTimestamp;
    uint32 exclusivityDeadline;
    address exclusiveRelayer;
}
