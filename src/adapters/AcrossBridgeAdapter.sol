// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AdapterGuard} from "./AdapterGuard.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../interfaces/external/IAcrossSpokePool.sol";

/// @title AcrossBridgeAdapter
/// @notice Bridge Adapter for Across V3: builds the `depositV3` call one vault executes itself. Holds no tokens,
///         grants no approvals and is never `msg.sender` of the SpokePool.
/// @dev DEC-087: a bridge is an Adapter (fixed in the Mandate, immutable, `deprecated` regime) and reports the amount
///      that will arrive. DEC-088: one instance per fund per chain, listed in the Mandate in priority order.
///      DEC-090: the adapter only translates; the core owns the transit state machine. DEC-058: no proxy, no setter,
///      no mutable target, no SELFDESTRUCT, so the vault can pin this address and its codehash (Q17-4, OPEN).
/// @dev Custody (IBridgeAdapter): `msg.sender` of `depositV3` is the vault, which pays `inputAmount` of `inputToken`
///      from its own balance after approving the SpokePool for exactly that amount, and checks the exact debit.
///      The `depositor` of record is a keyless per-send TransitEscrow clone (DEC-066, QA6 OPEN): Across refunds an
///      expired deposit to the depositor on the origin chain, and only the depositor can sign a speed-up
///      (`speedUpV3Deposit`, checked with ECDSA or EIP-1271) that changes the output amount, recipient or message.
///      The escrow has no key and no EIP-1271, so nobody can make a deposit deliver less than the signed quote.
/// @dev Across facts the vault must respect (verified on the live SpokePools, 2026-09-29):
///      - `exclusivityDeadline` is the SpokePool's `exclusivityParameter`: 0 means no exclusivity; a value up to
///        31,536,000 is an offset added to the deposit time; a larger value is an absolute timestamp. A non-zero
///        value requires a non-zero `exclusiveRelayer`. The adapter encodes the field as received.
///      - The SpokePool reverts unless `quoteTimestamp <= now` and `now - quoteTimestamp <= depositQuoteTimeBuffer`.
///      - The live SpokePools no longer keep an on-chain deposit route list; the only on-chain gate is
///        `pausedDeposits`. Whether relayers fill a given token pair is an off-chain property of the route; a
///        deposit nobody fills expires and is refunded to the escrow (DEC-066).
contract AcrossBridgeAdapter is AdapterGuard, IBridgeAdapter {
    /// @notice Protocol identifier returned by `protocolId()`.
    bytes32 public constant PROTOCOL_ID = keccak256("ACROSS_V3");

    /// @notice Seconds between the send and the fill deadline.
    /// @dev DEC-066: 6 h in both directions, an adapter constant, equal to the SpokePool `fillDeadlineBuffer`
    ///      (21,600 s on Arbitrum One and Robinhood Chain).
    uint32 public constant FILL_DEADLINE_SECONDS = 21_600;

    /// @inheritdoc IBridgeAdapter
    address public immutable vault;

    /// @notice The Across SpokePool of this chain; the only target of every built call.
    address public immutable spokePool;

    /// @notice The vault address is zero.
    error ZeroVault();

    /// @notice The SpokePool address is zero.
    error ZeroSpokePool();

    /// @notice The SpokePool would reject a fill deadline `FILL_DEADLINE_SECONDS` ahead (DEC-066).
    error FillDeadlineBufferTooShort(uint32 fillDeadlineBuffer);

    /// @param vault_ The vault this adapter builds calls for (Core Vault on the hub, Spoke Vault on a spoke).
    /// @param guardian_ Immutable guardian of the quarantine and deprecation flags (DEC-021, DEC-058; Q17-2b OPEN).
    /// @param spokePool_ The Across SpokePool of this chain.
    /// @dev DEC-066: rejects a SpokePool whose `fillDeadlineBuffer` is below the 6 h constant, since every deposit
    ///      built by this adapter would revert there. Across governance can still lower the buffer later; `buildSend`
    ///      then uses the lower buffer (security review S-23), so sends, the send home included, keep working.
    constructor(address vault_, address guardian_, address spokePool_) AdapterGuard(guardian_) {
        if (vault_ == address(0)) revert ZeroVault();
        if (spokePool_ == address(0)) revert ZeroSpokePool();
        uint32 buffer = IAcrossSpokePool(spokePool_).fillDeadlineBuffer();
        if (buffer < FILL_DEADLINE_SECONDS) revert FillDeadlineBufferTooShort(buffer);
        vault = vault_;
        spokePool = spokePool_;
    }

    /// @inheritdoc IBridgeAdapter
    function protocolId() external pure returns (bytes32) {
        return PROTOCOL_ID;
    }

    /// @inheritdoc IBridgeAdapter
    function target() external view returns (address) {
        return spokePool;
    }

    /// @inheritdoc IBridgeAdapter
    /// @dev DEC-066: 21,600 s, both directions.
    function fillDeadlineSeconds() external pure returns (uint32) {
        return FILL_DEADLINE_SECONDS;
    }

    /// @inheritdoc IBridgeAdapter
    /// @dev DEC-087: encodes exactly the vault-fixed fields; never substitutes a recipient, token or amount. A
    ///      `recipient` that is not a 20-byte EVM address is rejected with `InvalidParty` instead of being
    ///      truncated, because truncation would deliver to a different address than the vault fixed.
    /// @dev DEC-085: `amountToArrive` is the quote's `outputAmount`, the value In-flight Value counts in Share Assets.
    /// @dev DEC-066: `fillDeadline = block.timestamp + 21600`, the same value encoded in the call; security review S-23:
    ///      `block.timestamp + fillDeadlineBuffer` when the SpokePool's buffer was lowered below 21,600 s.
    /// @dev DEC-056, DEC-058: does not read `paused` or `deprecated`; the Core Vault refuses a hub-to-spoke send
    ///      through a paused or deprecated bridge adapter, and a send home is never blocked.
    /// @dev DEC-090: `transitRef` is the Across deposit id the call will be assigned (`numberOfDeposits()` now),
    ///      valid only if the vault executes the call in the same transaction, before any other deposit.
    /// @param depositor Keyless per-send TransitEscrow that receives the refund on expiry (DEC-066).
    function buildSend(SendRequest calldata req, address depositor) external view returns (BridgeCall memory call) {
        if (req.inputAmount == 0 || req.outputAmount == 0 || req.outputAmount > req.inputAmount) {
            revert InvalidAmounts(req.inputAmount, req.outputAmount);
        }
        uint256 recipientWord = uint256(req.recipient);
        if (depositor == address(0) || recipientWord == 0 || recipientWord > type(uint160).max) {
            revert InvalidParty();
        }

        uint32 fillDeadline = uint32(block.timestamp) + _fillWindow();

        call.target = spokePool;
        call.data = abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                depositor,
                // casting to 'uint160' is safe because recipientWord <= type(uint160).max was checked above
                // forge-lint: disable-next-line(unsafe-typecast)
                address(uint160(recipientWord)),
                req.inputToken,
                req.outputToken,
                req.inputAmount,
                req.outputAmount,
                req.destinationChainId,
                req.exclusiveRelayer,
                req.quoteTimestamp,
                fillDeadline,
                req.exclusivityDeadline,
                req.message
            )
        );
        call.transitRef = bytes32(uint256(IAcrossSpokePool(spokePool).numberOfDeposits()));
        call.amountToArrive = req.outputAmount;
        call.fillDeadline = fillDeadline;
    }

    /// @dev Security review S-23 (DEC-056, DEC-066): the constant equals the SpokePool's maximum, and adapters are
    ///      immutable with Across the only Transport Route, so a later governance decrease of `fillDeadlineBuffer`
    ///      would make every send revert, the send home (the exit path) included. The window follows a lower buffer.
    function _fillWindow() private view returns (uint32 window) {
        uint32 buffer = IAcrossSpokePool(spokePool).fillDeadlineBuffer();
        window = buffer < FILL_DEADLINE_SECONDS ? buffer : FILL_DEADLINE_SECONDS;
        if (window == 0) revert FillDeadlineBufferTooShort(buffer);
    }
}
