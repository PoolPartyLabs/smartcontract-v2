// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AdapterGuard} from "./AdapterGuard.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IAcrossSpokePool} from "../interfaces/external/IAcrossSpokePool.sol";
import {BridgeFeeRule} from "../libraries/BridgeFeeRule.sol";

/// @title AcrossBridgeAdapter
/// @notice Bridge Adapter for Across V3: fixes every term of a send, the amount to arrive included, from the fund's own
///         fee history, and builds the `depositV3` call one vault executes itself. Holds no tokens, grants no approvals
///         and is never `msg.sender` of the SpokePool.
/// @dev DEC-087: a bridge is an Adapter (fixed in the Mandate, immutable, `deprecated` regime) and reports the amount
///      that will arrive. DEC-088: one instance per fund per chain, listed in the Mandate in priority order.
///      DEC-090: the vaults own the transit state machine; the adapter only learns expiries. DEC-058: no proxy, no
///      setter, no mutable target, no SELFDESTRUCT, so the vault can pin this address and its codehash (Q17-4, OPEN).
/// @dev DEC-162 (founder chat of 2026-10-02: "the values for the value in and out of the bridge need to be defined in
///      the adapter so we avoid bad actors of trying to use a relayer to steal funds via adding a huge value in <> out
///      difference"): the vault passes the destination, the recipient, the token pair, the amount sent and the message;
///      the adapter fixes the amount to arrive with `BridgeFeeRule` over the fund's last sends on the route and every
///      other Across term: depositor = the vault's per-send escrow, no exclusive relayer, no exclusivity, quote time =
///      now, fill deadline = now + 6 h (DEC-066; S-23). Nobody who triggers a send passes a bridge parameter
///      (DEC-158): a manager or an order executor that pre-fills the deposit as its own relayer earns the rule's fee
///      and nothing more. Until signed API quotes exist (R-162-B, under evaluation), a non-empty `bridgeData` reverts
///      `QuotesNotSupported`.
/// @dev Why the history is the adapter's own (a reading to confirm: checklist doc 12 §3 has the adapter store nothing
///      and read the vault's sends): Across stores no deposit amounts on-chain (a deposit
///      writes only `numberOfDeposits`; fork proof in test/fork/across/AcrossSpokePoolReadability.fork.t.sol), so
///      the only readable history is the fund's own sends. The adapter keeps it, written only by its vault, instead of
///      reading the vault's transits (that would need a nonce getter, Spoke Vault bytes and a vault ABI in every
///      bridge adapter). It is per destination chain: on the hub one instance may serve several spokes.
/// @dev Rule constants (OPEN, checklist doc 12 §6): window of 3 sends, initial rate 0.08%, floor
///      0.03%, cap 1%, step +50% after an expiry, fixed part 0.03 input-token units (the relayer's gas). The cap is
///      the adapter's own bound on the in/out gap (founder chat of 2026-10-02; a reading to confirm against DEC-156's
///      "no protocol cap", which may instead mean a per-fund cap chosen at creation); the Mandate and the vaults keep
///      no bridge fee cap (DEC-156, DEC-162). The vault may still refuse an amount to arrive below a requester's optional
///      maximum (DEC-156 item 2), never price one.
/// @dev Across facts the adapter relies on (verified on the live SpokePools, 2026-09-29 and 2026-10-02):
///      - the SpokePool reverts unless `quoteTimestamp <= now` and `now - quoteTimestamp <= depositQuoteTimeBuffer`;
///        the adapter quotes at `block.timestamp`;
///      - the only on-chain deposit gate is `pausedDeposits`; whether relayers fill is an off-chain property of the
///        route: a deposit nobody fills expires and is refunded to the escrow 57 to 99 min after the deadline
///        (measured 2026-10-02), and the vault then calls `noteExpiry`, which makes the retry step up one band.
contract AcrossBridgeAdapter is AdapterGuard, IBridgeAdapter {
    /// @notice Protocol identifier returned by `protocolId()`.
    bytes32 public constant PROTOCOL_ID = keccak256("ACROSS_V3");

    /// @notice Seconds between the send and the fill deadline.
    /// @dev DEC-066: 6 h in both directions, an adapter constant, equal to the SpokePool `fillDeadlineBuffer`
    ///      (21,600 s on Arbitrum One and Robinhood Chain).
    uint32 public constant FILL_DEADLINE_SECONDS = 21_600;

    /// @notice Rate of each missing entry of the window: 0.08% (OPEN, doc 12 §6; DEC-162 "MVP minimum").
    uint256 public constant INITIAL_RATE = 0.0008e18;

    /// @notice Lowest rate ever used: 0.03% (OPEN, doc 12 §6).
    uint256 public constant FLOOR_RATE = 0.0003e18;

    /// @notice Hard ceiling of every send: 1% (OPEN, doc 12 §6; see the contract notes on DEC-156).
    uint256 public constant CAP_RATE = 0.01e18;

    /// @notice Step after an expiry: the next send pays the expired rate plus 50% (OPEN, doc 12 §6).
    uint256 public constant BAND = 0.5e18;

    /// @notice Fixed part of the fee, in hundredths of one input-token unit: 3 (0.03 units, the relayer's gas; OPEN,
    ///         doc 12 §6).
    uint256 public constant FIXED_FEE_CENTS = 3;

    /// @inheritdoc IBridgeAdapter
    address public immutable vault;

    /// @notice The Across SpokePool of this chain; the only target of every built call.
    address public immutable spokePool;

    /// @notice One send the adapter priced whose outcome is still open.
    /// @param destinationChainId Route of the send.
    /// @param serial The send's 1-based number on the route (zero: unknown, or its expiry was already noted).
    /// @param rate Rate the send was priced at.
    struct PricedSend {
        uint256 destinationChainId;
        uint64 serial;
        uint64 rate;
    }

    /// @dev The fee history per destination chain.
    mapping(uint256 destinationChainId => BridgeFeeRule.Route) private _routes;

    /// @dev Sends priced and not yet reported expired, by Across deposit id.
    mapping(bytes32 transitRef => PricedSend) private _priced;

    /// @notice The vault address is zero.
    error ZeroVault();

    /// @notice The SpokePool address is zero.
    error ZeroSpokePool();

    /// @notice The SpokePool would reject a fill deadline `FILL_DEADLINE_SECONDS` ahead (DEC-066).
    error FillDeadlineBufferTooShort(uint32 fillDeadlineBuffer);

    /// @notice A non-empty `bridgeData`: signed quotes are not supported by this adapter (DEC-158; R-162-B).
    error QuotesNotSupported();

    /// @notice `noteExpiry` for a send this adapter did not price, or whose expiry was already noted.
    error UnknownSend(bytes32 transitRef);

    /// @notice A send was priced by the rule (DEC-162).
    event SendPriced(uint256 indexed destinationChainId, bytes32 indexed transitRef, uint256 rateWad, uint256 fee);

    /// @notice The vault reported a send that will never arrive; the next send on the route steps up (DEC-162).
    event ExpiryNoted(uint256 indexed destinationChainId, bytes32 indexed transitRef, uint256 rateWad);

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
    function quoteSend(address inputToken, uint256 destinationChainId, uint256 inputAmount, bytes calldata bridgeData)
        external
        view
        returns (uint256 amountToArrive, uint256 rateWad)
    {
        if (bridgeData.length != 0) revert QuotesNotSupported();
        rateWad = BridgeFeeRule.nextRate(_routes[destinationChainId], _params());
        amountToArrive = inputAmount - BridgeFeeRule.fee(inputAmount, rateWad, fixedFee(inputToken));
    }

    /// @inheritdoc IBridgeAdapter
    /// @dev DEC-162: the amount to arrive is `inputAmount - (ceil(inputAmount * rate) + fixed part)` with the rate
    ///      `BridgeFeeRule.nextRate` gives for the route; the send is recorded in the route's window. DEC-158: the
    ///      exclusive relayer, the exclusivity, the quote time and the deadline are the adapter's. DEC-087: the
    ///      recipient, tokens, amount sent and message are encoded as received; a `recipient` that is not a 20-byte
    ///      EVM address is rejected with `InvalidParty` instead of being truncated.
    /// @dev DEC-066: `fillDeadline = block.timestamp + 21600`, the same value encoded in the call; security review S-23:
    ///      `block.timestamp + fillDeadlineBuffer` when the SpokePool's buffer was lowered below 21,600 s.
    /// @dev DEC-056, DEC-058: does not read `paused` or `deprecated`; the Core Vault refuses a hub-to-spoke send
    ///      through a paused or deprecated bridge adapter, and a send home is never blocked.
    /// @dev DEC-090: `transitRef` is the Across deposit id the call will be assigned (`numberOfDeposits()` now),
    ///      valid only if the vault executes the call in the same transaction, before any other deposit.
    /// @param depositor Keyless per-send TransitEscrow that receives the refund on expiry (DEC-066).
    function buildSend(SendRequest calldata req, address depositor, bytes calldata bridgeData)
        external
        returns (BridgeCall memory call)
    {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (bridgeData.length != 0) revert QuotesNotSupported();
        uint256 recipientWord = uint256(req.recipient);
        if (depositor == address(0) || recipientWord == 0 || recipientWord > type(uint160).max) {
            revert InvalidParty();
        }

        BridgeFeeRule.Route storage route = _routes[req.destinationChainId];
        uint256 rate = BridgeFeeRule.nextRate(route, _params());
        uint256 fee = BridgeFeeRule.fee(req.inputAmount, rate, fixedFee(req.inputToken));

        call.target = spokePool;
        call.amountToArrive = req.inputAmount - fee;
        call.fillDeadline = uint32(block.timestamp) + _fillWindow();
        call.transitRef = bytes32(uint256(IAcrossSpokePool(spokePool).numberOfDeposits()));
        call.data = _encode(req, depositor, call.amountToArrive, call.fillDeadline);

        uint64 serial = BridgeFeeRule.record(route, rate);
        // casting to 'uint64' is safe because `rate` is at most CAP_RATE (1e16)
        // forge-lint: disable-next-line(unsafe-typecast)
        _priced[call.transitRef] = PricedSend(req.destinationChainId, serial, uint64(rate));
        emit SendPriced(req.destinationChainId, call.transitRef, rate, fee);
    }

    /// @inheritdoc IBridgeAdapter
    /// @dev The route's next send steps up one band above the highest expired rate (never below the route's
    ///      reference), and the send leaves its route's window if it is still the latest (`BridgeFeeRule.noteExpiry`). Reverts `UnknownSend` for a send this
    ///      adapter did not price or already noted; the vaults call it in try/catch (DEC-056).
    function noteExpiry(bytes32 transitRef) external {
        if (msg.sender != vault) revert NotVault(msg.sender);
        PricedSend memory sent = _priced[transitRef];
        if (sent.serial == 0) revert UnknownSend(transitRef);
        delete _priced[transitRef];
        BridgeFeeRule.noteExpiry(_routes[sent.destinationChainId], sent.serial, sent.rate);
        emit ExpiryNoted(sent.destinationChainId, transitRef, sent.rate);
    }

    /// @inheritdoc IBridgeAdapter
    function feeState(uint256 destinationChainId)
        external
        view
        returns (uint256 nextRateWad, uint256 referenceRateWad, uint256 expiredRateWad)
    {
        BridgeFeeRule.Route storage route = _routes[destinationChainId];
        BridgeFeeRule.Params memory p = _params();
        return (BridgeFeeRule.nextRate(route, p), BridgeFeeRule.referenceRate(route, p), route.expiredRate);
    }

    /// @notice The route's window (ring order, zero for an empty slot), the ring slot the next send writes, and how
    ///         many sends the route has recorded.
    function feeWindow(uint256 destinationChainId)
        external
        view
        returns (uint64[3] memory rates, uint8 next, uint64 sends)
    {
        BridgeFeeRule.Route storage route = _routes[destinationChainId];
        return (route.rates, route.next, route.sends);
    }

    /// @notice The fixed part of the fee for `inputToken`: 0.03 units (`3 * 10 ** decimals / 100`).
    function fixedFee(address inputToken) public view returns (uint256) {
        return FIXED_FEE_CENTS * 10 ** IERC20Metadata(inputToken).decimals() / 100;
    }

    function _params() private pure returns (BridgeFeeRule.Params memory) {
        return BridgeFeeRule.Params({initialRate: INITIAL_RATE, floorRate: FLOOR_RATE, capRate: CAP_RATE, band: BAND});
    }

    /// @dev Depositor, recipient, tokens, amounts, no exclusivity, quote time = now, deadline: DEC-158, DEC-162.
    function _encode(SendRequest calldata req, address depositor, uint256 amountToArrive, uint32 fillDeadline)
        private
        view
        returns (bytes memory)
    {
        return abi.encodeCall(
            IAcrossSpokePool.depositV3,
            (
                depositor,
                // casting to 'uint160' is safe because the recipient word was checked to fit 160 bits in `buildSend`
                // forge-lint: disable-next-line(unsafe-typecast)
                address(uint160(uint256(req.recipient))),
                req.inputToken,
                req.outputToken,
                req.inputAmount,
                amountToArrive,
                req.destinationChainId,
                address(0),
                uint32(block.timestamp),
                fillDeadline,
                0,
                req.message
            )
        );
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
