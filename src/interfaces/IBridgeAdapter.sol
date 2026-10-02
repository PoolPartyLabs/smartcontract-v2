// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdapterGuard} from "./IAdapterGuard.sol";

/// @title IBridgeAdapter
/// @notice Bridge adapter: fixes every term of a transfer the vault asks for, the amount to arrive included, and builds
///         the one bridge protocol call the vault executes itself.
/// @dev DEC-087: a bridge is a type of Adapter (fixed in the Mandate, immutable, `deprecated` regime); it reports the
///      amount that will arrive. DEC-088: the Mandate lists bridge adapters in order (primary, fallback) per spoke.
///      DEC-090: the vaults own the transit state machine (Sent, then arrival, expiry or refund); the adapter only
///      learns the expiries, through `noteExpiry`.
/// @dev DEC-162: the adapter fixes how much leaves and how much must arrive, and the bridge fee rule lives in the
///      adapter of each bridge, never in the fund contracts (an adapter for a bridge without a fee rule, like CCTP,
///      leaves nothing of it there). DEC-158: whoever triggers a transfer (the manager, or the executor of an order)
///      passes no amount to arrive, relayer, quote time or deadline. `bridgeData` is reserved for a quote the
///      adapter verifies itself (a signed API quote, R-162-B); an adapter that takes none refuses a non-empty one.
/// @dev Custody never leaves the vault (DEC-087 "destination locked by the core", ARCHITECTURE §1 "builds the call for
///      the vault"). The vault, per send:
///      1. fixes the destination, the recipient (the fund's own vault on the destination chain registered in the
///         Mandate, DEC-087), the token pair (the Mandate's route pair), the amount sent and the message;
///      2. calls `buildSend` and requires `call.target` to equal the target it pinned for this adapter at creation
///         (next to the adapter address and, under Q17-4 reading O2, its codehash), `0 < amountToArrive <= inputAmount`
///         and a fill deadline in the future;
///      3. approves `call.target` for exactly `inputAmount` of `inputToken`, executes `call.data` with a plain CALL
///         (never DELEGATECALL, no ETH value), requires its own `inputToken` balance to fall by exactly `inputAmount`,
///         and resets the approval to zero.
///      The adapter never holds tokens and is never `msg.sender` of the bridge protocol, so it cannot keep funds or
///      spend more than one send's `inputAmount`. Residual trust: the vault cannot decode protocol-specific calldata
///      generically, so that `call.data` encodes the vault-fixed recipient and the reported amount to arrive rests on
///      the adapter code the Mandate pins (immutable adapter; codehash per Q17-4, OPEN). Fork tests decode the built
///      call and assert every field.
/// @dev Quarantine and deprecation: `buildSend` does not read the adapter's own flags, because the same adapter type
///      serves both directions and DEC-056 keeps the exit path (spoke to hub) open. The Core Vault refuses a
///      hub-to-spoke send through a paused or deprecated bridge adapter; the Spoke Vault never checks the flags on a
///      send home. `noteExpiry` never gates anything and the vaults call it in try/catch (DEC-056).
interface IBridgeAdapter is IAdapterGuard {
    /// @notice A transfer request: what the calling vault fixes. Never an amount to arrive (DEC-158, DEC-162).
    /// @param inputToken Token leaving the origin chain.
    /// @param outputToken Token delivered on the destination chain.
    /// @param inputAmount Amount of `inputToken` sent: the operation's amount (DEC-162 registered reading).
    /// @param destinationChainId EVM chain id of the destination.
    /// @param recipient Destination vault as a universal address; fixed by the calling vault (DEC-087).
    /// @param message Message the destination vault receives (see TransitMessage); fixed by the calling vault.
    struct SendRequest {
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 destinationChainId;
        bytes32 recipient;
        bytes message;
    }

    /// @notice The protocol call the vault executes for one send.
    /// @param target Bridge protocol contract to approve and call (Across: the SpokePool); must equal `target()`.
    /// @param data Calldata for `target` (Across: `depositV3` with `msg.sender` = the vault as the payer).
    /// @param transitRef Protocol-level reference the call will produce (Across: `numberOfDeposits()` read at build
    ///        time, as bytes32); valid only when the vault executes the call in the same transaction, right after
    ///        building it. The vault passes it back to `noteExpiry`.
    /// @param amountToArrive Amount that will arrive on the destination chain, fixed by the adapter (DEC-085, DEC-162).
    /// @param fillDeadline Fill deadline encoded in `data`: `block.timestamp + fillDeadlineSeconds()` (DEC-066).
    struct BridgeCall {
        address target;
        bytes data;
        bytes32 transitRef;
        uint256 amountToArrive;
        uint32 fillDeadline;
    }

    /// @notice `buildSend` or `noteExpiry` was called by an address other than `vault()`.
    error NotVault(address caller);

    /// @notice The recipient is zero or is not a 20-byte EVM address (a bytes32 with bits above 160; it is rejected,
    ///         never truncated, so the adapter never delivers to an address the vault did not fix, DEC-087), or the
    ///         depositor is zero.
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

    /// @notice What a send of `inputAmount` of `inputToken` toward `destinationChainId` would deliver if built now.
    /// @dev The same rule `buildSend` applies, without recording anything. Reverts where `buildSend` would (a dust
    ///      amount, an unsupported `bridgeData`).
    /// @return amountToArrive Amount that would arrive.
    /// @return rateWad The variable rate applied, as a WAD fraction of the amount sent (0 for a bridge without one).
    function quoteSend(address inputToken, uint256 destinationChainId, uint256 inputAmount, bytes calldata bridgeData)
        external
        view
        returns (uint256 amountToArrive, uint256 rateWad);

    /// @notice Fixes the amount to arrive and every other term of `req`, records the send for the fee rule and builds
    ///         the protocol call. Vault only.
    /// @dev Moves no tokens. Reverts with `NotVault` for any other caller and with `InvalidParty` on a zero depositor
    ///      or a recipient that is not an EVM address. Encodes exactly the recipient, tokens, amount sent and message it
    ///      receives; never substitutes any of them.
    /// @param req Request fixed by the calling vault.
    /// @param depositor Depositor of record that receives a refund on expiry (per-send TransitEscrow, DEC-066; the
    ///        depositor must not be able to sign an Across speed-up, so it is a keyless contract without EIP-1271).
    /// @param bridgeData Adapter-verified extra input (reserved for a signed API quote, R-162-B; empty for the Across
    ///        adapter).
    /// @return call The call the vault executes itself.
    function buildSend(SendRequest calldata req, address depositor, bytes calldata bridgeData)
        external
        returns (BridgeCall memory call);

    /// @notice The vault learned that the send `transitRef` will never arrive (DEC-066: non-arrival proven by a report,
    ///         or its refund recognized). Vault only.
    /// @dev The fee rule's input from the outcome (DEC-162): the next send on that route steps up. The vaults call it
    ///      once per expired send, in try/catch, so an adapter never blocks an outcome (DEC-056).
    function noteExpiry(bytes32 transitRef) external;

    /// @notice The fee rule's state for the route toward `destinationChainId`, WAD fractions of the amount sent.
    /// @return nextRateWad Rate the next send without `bridgeData` uses.
    /// @return referenceRateWad Mean of the route's recent sends (the rule's reference).
    /// @return expiredRateWad Highest expired rate pending a step up; 0 when none.
    function feeState(uint256 destinationChainId)
        external
        view
        returns (uint256 nextRateWad, uint256 referenceRateWad, uint256 expiredRateWad);
}
