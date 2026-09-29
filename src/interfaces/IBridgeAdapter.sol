// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdapterGuard} from "./IAdapterGuard.sol";

/// @title IBridgeAdapter
/// @notice Bridge adapter: a pure call builder that translates a vault-fixed transfer request into one bridge
///         protocol call, which the vault executes itself.
/// @dev DEC-087: a bridge is a type of Adapter (fixed in the Mandate, immutable, `deprecated` regime); it reports the
///      amount that will arrive. DEC-088: the Mandate lists bridge adapters in order (primary, fallback) per spoke.
///      DEC-090: the core owns the transit state machine; the adapter only translates.
/// @dev Custody never leaves the vault (DEC-087 "destination locked by the core", ARCHITECTURE §1 "builds the call for
///      the vault"). The vault, per send:
///      1. fixes every field of `SendRequest`: the recipient is the fund's own vault on the destination chain registered
///         in the Mandate (DEC-087), the token pair is the Mandate's route pair, the quote's fee
///         `inputAmount - outputAmount` is within the Mandate's `maxBridgeFeeBps` (QA19);
///      2. calls `buildSend` and requires `call.target` to equal the target it pinned for this adapter at creation
///         (next to the adapter address and, under Q17-4 reading O2, its codehash);
///      3. approves `call.target` for exactly `inputAmount` of `inputToken`, executes `call.data` with a plain CALL
///         (never DELEGATECALL, no ETH value), requires its own `inputToken` balance to fall by exactly `inputAmount`,
///         and resets the approval to zero.
///      The adapter never holds tokens and is never `msg.sender` of the bridge protocol, so it cannot keep funds or
///      spend more than one send's `inputAmount`. Residual trust: the vault cannot decode protocol-specific calldata
///      generically, so that `call.data` encodes the vault-fixed recipient rests on the adapter code the Mandate pins
///      (immutable adapter; codehash per Q17-4, OPEN). Fork tests decode the built call and assert every field.
/// @dev Quarantine and deprecation: `buildSend` does not read the adapter's own flags, because the same adapter type
///      serves both directions and DEC-056 keeps the exit path (spoke to hub) open. The Core Vault refuses a
///      hub-to-spoke send through a paused or deprecated bridge adapter; the Spoke Vault never checks the flags on a
///      send home.
interface IBridgeAdapter is IAdapterGuard {
    /// @notice A transfer request, fully fixed by the calling vault.
    /// @param inputToken Token leaving the origin chain.
    /// @param outputToken Token delivered on the destination chain.
    /// @param inputAmount Amount of `inputToken` sent.
    /// @param outputAmount Amount of `outputToken` that will arrive, from the signed quote (DEC-085).
    /// @param destinationChainId EVM chain id of the destination.
    /// @param recipient Destination vault as a universal address; fixed by the calling vault (DEC-087).
    /// @param quoteTimestamp Quote timestamp.
    /// @param exclusivityDeadline Exclusivity deadline, 0 for none.
    /// @param exclusiveRelayer Exclusive relayer, address(0) for none.
    /// @param message Message the destination vault receives (see TransitMessage); fixed by the calling vault.
    struct SendRequest {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        bytes32 recipient;
        uint32 quoteTimestamp;
        uint32 exclusivityDeadline;
        address exclusiveRelayer;
        bytes message;
    }

    /// @notice The protocol call the vault executes for one send.
    /// @param target Bridge protocol contract to approve and call (Across: the SpokePool); must equal `target()`.
    /// @param data Calldata for `target` (Across: `depositV3` with `msg.sender` = the vault as the payer).
    /// @param transitRef Protocol-level reference the call will produce (Across: `numberOfDeposits()` read at build
    ///        time, as bytes32); valid only when the vault executes the call in the same transaction, right after
    ///        building it.
    /// @param amountToArrive Amount that will arrive on the destination chain (DEC-085, DEC-087).
    /// @param fillDeadline Fill deadline encoded in `data`: `block.timestamp + fillDeadlineSeconds()` (DEC-066).
    struct BridgeCall {
        address target;
        bytes data;
        bytes32 transitRef;
        uint256 amountToArrive;
        uint32 fillDeadline;
    }

    /// @notice Zero input or output amount, or output above input.
    error InvalidAmounts(uint256 inputAmount, uint256 outputAmount);

    /// @notice Recipient or depositor is zero.
    error InvalidParty();

    /// @notice The vault (Core Vault on the hub, Spoke Vault on a spoke) this adapter builds calls for.
    function vault() external view returns (address);

    /// @notice Identifier of the bridge protocol (Across: keccak256("ACROSS_V3")).
    function protocolId() external pure returns (bytes32);

    /// @notice The bridge protocol contract every built call targets (Across: the SpokePool of this chain).
    /// @dev Immutable. The vault reads and pins it at creation and rejects a `BridgeCall` whose target differs.
    function target() external view returns (address);

    /// @notice Seconds between the send and the fill deadline.
    /// @dev DEC-066: 6 h in both directions, an adapter constant; the Across adapter returns 21600, which equals the
    ///      SpokePool `fillDeadlineBuffer` on both chains.
    function fillDeadlineSeconds() external view returns (uint32);

    /// @notice Builds the protocol call for `req`. View: moves no tokens and touches no state.
    /// @dev Reverts with `InvalidAmounts` or `InvalidParty` on a malformed request. Encodes exactly the fields it
    ///      receives; never substitutes a recipient, token or amount.
    /// @param req Request fixed by the calling vault.
    /// @param depositor Depositor of record that receives a refund on expiry (per-send TransitEscrow, DEC-066; the
    ///        depositor must not be able to sign an Across speed-up, so it is a keyless contract without EIP-1271).
    /// @return call The call the vault executes itself.
    function buildSend(SendRequest calldata req, address depositor) external view returns (BridgeCall memory call);
}
