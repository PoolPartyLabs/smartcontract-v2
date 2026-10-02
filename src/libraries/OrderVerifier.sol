// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderCodec} from "./OrderCodec.sol";

/// @notice The head of the Wormhole Core's `parseAndVerifyVM` result: the first eight fields of `CoreBridgeVM`
///         (`wormhole-sdk/interfaces/ICoreBridge.sol`), in the same order.
/// @dev The Core returns `CoreBridgeVM` (these fields, then `guardianSetIndex`, `signatures`, `hash`). In the ABI
///      encoding a struct's fields sit at fixed head positions from its start and its dynamic fields are reached by
///      offsets, so declaring the leading fields decodes the same values and leaves the guardian signatures array
///      undecoded: about 330 bytes less in the contract that inlines `OrderVerifier` (measured), for no change in
///      what is checked. The Core still verifies every signature.
struct OrderVaaHead {
    uint8 version;
    uint32 timestamp;
    uint32 nonce;
    uint16 emitterChainId;
    bytes32 emitterAddress;
    uint64 sequence;
    uint8 consistencyLevel;
    bytes payload;
}

/// @notice `ICoreBridge.parseAndVerifyVM` read through `OrderVaaHead`.
interface IOrderVaaParser {
    function parseAndVerifyVM(bytes calldata encodedVM)
        external
        view
        returns (OrderVaaHead memory vm, bool valid, string memory reason);
}

/// @title OrderVerifier
/// @notice What a Spoke Vault checks before it executes an order VAA from the Hub, and its replay guard.
/// @dev DEC-111, DEC-120 item 2, DEC-139: any address delivers the order; the Spoke Vault accepts it only if
///      1. the spoke chain's Wormhole Core verifies the guardian quorum (`InvalidOrderVaa`), DEC-086;
///      2. the emitter chain is the Hub's Wormhole chain id, 23 for Arbitrum One (`OrderEmitterChainMismatch`);
///      3. the emitter is the fund's Core Vault (`OrderEmitterMismatch`);
///      4. the sequence is at least the cursor's `minSequence` (`OrderSequenceTooLow`): the DEC-093 rule, strictly
///         greater than the last accepted order, which rejects a replay and an older order delivered after a newer
///         one;
///      5. the payload decodes with the current `OrderCodec` version (`OrderCodec.decode`);
///      6. the payload's fund id is the fund's own (`OrderFundMismatch`);
///      7. the order's deadline has not passed (`OrderExpired`), doc 32 §4.2 confirmed by DEC-120: the Hub writes
///         `deadline = publish time + OrderCodec.ORDER_LIFETIME`, so a spoke created or funded later cannot be made to
///         execute older orders.
/// @dev The consistency level is not checked: the Core Vault is the only accepted emitter and always publishes with
///      `OrderCodec.CONSISTENCY_INSTANT` (DEC-120 item 1).
/// @dev `accept` advances the caller's `Cursor` itself, so the replay guard does not depend on what each caller
///      stores. "Strictly greater than the last accepted" is kept as "at least the last accepted plus one" because a
///      Wormhole emitter's first sequence is 0: a stored "last accepted" of 0 would refuse the Core Vault's first
///      order unless a separate flag said none was accepted yet.
/// @dev Gaps are accepted: an order this spoke never received does not block a later one.
library OrderVerifier {
    /// @notice A Spoke Vault's place in its Core Vault's order stream: the lowest sequence it still accepts.
    /// @dev 0 before any order; `accept` sets it to the accepted order's sequence plus one. Only `accept` writes it.
    struct Cursor {
        uint64 minSequence;
    }

    /// @notice The Wormhole Core refused the VAA (guardian quorum, guardian set or encoding).
    error InvalidOrderVaa(string reason);

    /// @notice The VAA was not emitted on the Hub's Wormhole chain.
    error OrderEmitterChainMismatch(uint16 emitterChainId);

    /// @notice The VAA was not emitted by the fund's Core Vault.
    error OrderEmitterMismatch(bytes32 emitterAddress);

    /// @notice The VAA's sequence is below the lowest still acceptable (a replay or an older order).
    error OrderSequenceTooLow(uint64 minSequence, uint64 sequence);

    /// @notice The order belongs to another fund.
    error OrderFundMismatch(bytes32 fundId);

    /// @notice The order's deadline has passed.
    error OrderExpired(uint64 deadline);

    /// @notice Verifies an order VAA, consumes it (the cursor moves past its sequence) and returns the order and its
    ///         Wormhole sequence. The caller executes the order in the same transaction.
    /// @param cursor The Spoke Vault's order cursor; advanced to `sequence + 1` when the order is accepted.
    /// @param core The spoke chain's Wormhole Core.
    /// @param vaa The signed VAA, as delivered by anyone.
    /// @param hubWormholeChainId The Hub's Wormhole chain id (Arbitrum One: 23).
    /// @param coreVault The fund's Core Vault (the same address on every chain, DEC-054).
    /// @param fundId The fund's id.
    /// @return o The decoded and checked order (`OrderCodec.check`).
    /// @return sequence The VAA's Wormhole sequence.
    function accept(
        Cursor storage cursor,
        address core,
        bytes calldata vaa,
        uint16 hubWormholeChainId,
        address coreVault,
        bytes32 fundId
    ) internal returns (OrderCodec.Order memory o, uint64 sequence) {
        (OrderVaaHead memory vm, bool valid, string memory reason) = IOrderVaaParser(core).parseAndVerifyVM(vaa);
        if (!valid) revert InvalidOrderVaa(reason);
        if (vm.emitterChainId != hubWormholeChainId) revert OrderEmitterChainMismatch(vm.emitterChainId);
        if (vm.emitterAddress != bytes32(uint256(uint160(coreVault)))) revert OrderEmitterMismatch(vm.emitterAddress);
        sequence = vm.sequence;
        uint64 minSequence = cursor.minSequence;
        if (sequence < minSequence) revert OrderSequenceTooLow(minSequence, sequence);
        o = OrderCodec.decode(vm.payload);
        if (o.fundId != fundId) revert OrderFundMismatch(o.fundId);
        if (block.timestamp > o.deadline) revert OrderExpired(o.deadline);
        cursor.minSequence = sequence + 1;
    }
}
