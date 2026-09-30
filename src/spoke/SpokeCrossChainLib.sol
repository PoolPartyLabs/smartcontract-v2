// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ITransitEscrow} from "../interfaces/ITransitEscrow.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../interfaces/FundTypes.sol";
import {MandateLib} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";

/// @title SpokeCrossChainLib
/// @notice The Spoke Chain half of the Spoke Vault: sends home, refund recognition, the hub-bound in-flight list and
///         the value report. Deployed once per chain and linked into `SpokeVault`; it runs in the vault's context
///         (library call) over the vault's own `SpokeVaultTypes.State`, holds no state and is immutable (DEC-058).
/// @dev Split out of the vault only to keep the vault's runtime bytecode under EIP-170. Events and errors are the
///      vault's (ISpokeVault and SpokeVaultTypes), emitted from the vault's address.
library SpokeCrossChainLib {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------------------------
    // Send home (DEC-056, DEC-066, DEC-085, DEC-087, DEC-088, QA6, QA19)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Debits the ledger, clones the per-send escrow, executes the bridge call and books the transit.
    /// @dev The vault checks role and caller and tops up Operating Cash before calling. DEC-087: the vault fixes
    ///      recipient (the Core Vault), token pair (base token to hub USDC) and message. QA19: the quote's fee
    ///      `amount - outputAmount` is at most `maxBridgeFeeBps` of `amount`. DEC-056: the bridge adapter's pause and
    ///      deprecation are never read on a send home. Custody per IBridgeAdapter: pinned target, exact approval,
    ///      plain CALL without value, exact debit, approval reset.
    function sendToHub(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        uint256 amount,
        TransferKind kind,
        uint256 bridgeRank,
        BridgeQuote calldata quote
    ) external returns (bytes32 transitId) {
        _checkQuote(c.maxBridgeFeeBps, amount, quote.outputAmount);
        // Security review S-9: no Across exclusivity (an exclusive relayer that never fills forces an expiry; one that
        // fills keeps the whole fee bound on every send).
        if (quote.exclusiveRelayer != address(0) || quote.exclusivityDeadline != 0) {
            revert SpokeVaultTypes.ExclusiveRelayerNotAllowed(quote.exclusiveRelayer);
        }
        // Security review S-11: the list a report walks is bounded; landed refunds and expired entries leave it first.
        _sweepInFlight(s, c.baseToken);
        if (s.inFlightIds.length >= SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT) {
            revert SpokeVaultTypes.HubBoundInFlightLimit(SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT);
        }
        address bridge = _bridgeAdapterAt(s, bridgeRank);
        _debit(s, c.baseToken, amount, kind);

        transitId = keccak256(abi.encode(c.fundId, c.chainId, ++s.transitNonce));
        address escrow = Clones.cloneDeterministic(c.transitEscrowImplementation, transitId);
        ITransitEscrow(escrow).initialize(address(this), c.baseToken);

        IBridgeAdapter.BridgeCall memory call = _buildCall(s, c, bridge, escrow, amount, kind, transitId, quote);
        Transit memory t = _book(s, c, transitId, bridge, escrow, amount, kind, call);
        _executeBridgeCall(c.baseToken, call.target, call.data, amount);
        emit ISpokeVault.SentToHub(transitId, t, c.hubChainId, c.chainId);
    }

    /// @notice Pulls an expired send's refund from its escrow back into the bucket the send debited.
    /// @dev DEC-066, QA6: only after the fill deadline. DEC-063 (docs/DECISIONS.md, Across expired-deposit refund):
    ///      Across refunds the full `inputAmount` to the depositor, so an escrow holding less than `amountSent` holds
    ///      no refund yet: nothing changes (`NoRefund`), the transit stays Sent and in flight, and whatever the escrow
    ///      holds waits there until the real refund lands and everything is released together (final verification,
    ///      the same guard as `CoreVaultLogic.recognizeRefund` on the hub, CV-OQ-6). The escrow balance is only a
    ///      sufficiency check, never a value base (DEC-080): exactly `amountSent` is credited, and anything above it
    ///      (a donation) reaches the vault unledgered and only `sweepExcess` moves it (DEC-101). Checks-effects-
    ///      interactions: the transit is marked refunded, leaves the in-flight list and is credited before the escrow
    ///      is released (Spoke Vault verifier finding); the vault's balance delta must equal what the escrow held.
    function recognizeRefund(SpokeVaultTypes.State storage s, address baseToken, bytes32 transitId)
        external
        returns (uint256 amount)
    {
        Transit storage t = s.hubBoundTransits[transitId];
        if (t.state != TransitState.Sent) revert ISpokeVault.UnknownTransit(transitId);
        if (block.timestamp <= t.fillDeadline) revert ISpokeVault.FillDeadlineNotReached(transitId, t.fillDeadline);
        if (!_refundLanded(t, baseToken)) revert ISpokeVault.NoRefund(transitId);
        amount = _recognize(s, t, baseToken, transitId);
    }

    /// @dev Whether an expired send's escrow holds its full Across refund (DEC-063: the whole `amountSent`).
    function _refundLanded(Transit storage t, address baseToken) private view returns (bool) {
        return IERC20(baseToken).balanceOf(t.escrow) >= t.amountSent;
    }

    /// @dev Effects then the escrow release of a refund whose escrow holds at least `amountSent`.
    function _recognize(SpokeVaultTypes.State storage s, Transit storage t, address baseToken, bytes32 transitId)
        private
        returns (uint256 amount)
    {
        address escrow = t.escrow;
        IERC20 token = IERC20(baseToken);
        uint256 held = token.balanceOf(escrow);
        amount = t.amountSent;
        t.state = TransitState.RefundRecognized;
        _removeInFlight(s, transitId);
        if (t.kind == TransferKind.Principal) s.unallocated[baseToken] += amount;
        else s.collectedIncome[baseToken] += amount;
        emit ISpokeVault.TransitRefundRecognized(transitId, amount);
        uint256 before = token.balanceOf(address(this));
        ITransitEscrow(escrow).release(address(this));
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != held) revert SpokeVaultTypes.RefundReleaseMismatch(held, received);
    }

    /// @dev Security review S-3: walks the hub-bound list once. An expired send whose refund has landed is recognized
    ///      (the same effects as `recognizeRefund`, so a report never drops a refunded transfer from every value
    ///      base while nobody has called it); a send past `fillDeadline + ReportCodec.HUB_BOUND_RETENTION` leaves the
    ///      list. Iterates from the end, so the swap-and-pop removal never skips an entry.
    function _sweepInFlight(SpokeVaultTypes.State storage s, address baseToken) private {
        for (uint256 i = s.inFlightIds.length; i > 0; --i) {
            bytes32 id = s.inFlightIds[i - 1];
            Transit storage t = s.hubBoundTransits[id];
            if (block.timestamp > t.fillDeadline && _refundLanded(t, baseToken)) _recognize(s, t, baseToken, id);
            else if (!_stillInFlight(t)) _removeInFlight(s, id);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report (DEC-070, DEC-079, DEC-085, DEC-090, DEC-093, Q60, OQ-09)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Recognizes landed refunds, drops hub-bound transits past their retention, advances the report sequence
    ///         and returns the payload.
    /// @dev DEC-093: the sequence strictly increases, by one per report. Security review S-3: see `_sweepInFlight`.
    function nextReport(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory c)
        external
        returns (uint64 sequence, bytes memory payload)
    {
        _sweepInFlight(s, c.baseToken);
        sequence = ++s.reportSequence;
        payload = ReportCodec.encode(_build(s, c, sequence));
    }

    /// @notice The payload a report with `sequence` would carry now: `ReportCodec.encode(report)`.
    function encodedReport(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory c, uint64 sequence)
        external
        view
        returns (bytes memory)
    {
        return ReportCodec.encode(_build(s, c, sequence));
    }

    /// @notice Sum of every Mandate adapter's own monotonic income counter on this chain (Q60).
    function cumulativeIncome(SpokeVaultTypes.State storage s, address token) public view returns (uint256 total) {
        for (uint256 i; i < s.adapters.length; ++i) {
            address adapter = s.adapters[i];
            _checkCodehash(s, adapter);
            total += IAdapter(adapter).cumulativeIncome(token);
        }
    }

    function _build(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory c, uint64 sequence)
        private
        view
        returns (ReportCodec.Report memory r)
    {
        r.fundId = c.fundId;
        r.sequence = sequence;
        r.spokeChainId = c.chainId;
        r.blockNumber = uint64(block.number);
        r.timestamp = uint64(block.timestamp);

        // DEC-055, DEC-080: Unallocated Balance from the ledger, never balanceOf; every ledger token is listed. The
        // collected income bucket and Operating Cash travel for the hub's Gross Assets (DEC-092, DEC-096, DEC-098).
        uint256 n = s.tokens.length;
        r.unallocated = new ReportCodec.TokenAmount[](n);
        r.cumulativeIncome = new ReportCodec.TokenAmount[](n);
        r.collectedIncome = new ReportCodec.TokenAmount[](n);
        for (uint256 i; i < n; ++i) {
            address token = s.tokens[i];
            r.unallocated[i] = ReportCodec.TokenAmount(token, s.unallocated[token]);
            r.cumulativeIncome[i] = ReportCodec.TokenAmount(token, cumulativeIncome(s, token));
            r.collectedIncome[i] = ReportCodec.TokenAmount(token, s.collectedIncome[token]);
        }
        r.operatingCash = s.operatingCash;

        // DEC-079: principal and income separated, as each adapter reads its protocol.
        n = s.positions.length;
        r.positions = new ReportCodec.PositionReport[](n);
        for (uint256 i; i < n; ++i) {
            ISpokeVault.PositionRef memory ref = s.positions[i];
            _checkCodehash(s, ref.adapter);
            r.positions[i] = _positionReport(ref.adapter, IAdapter(ref.adapter).positionValue(ref.positionKey));
        }

        r.cumulativeReceived = s.cumulativeReceived;
        r.cumulativeSentHome = s.cumulativeSentHome;

        // OQ-09 stance: the last ARRIVAL_WINDOW listed arrival ids (credited total at least MIN_LISTED_ARRIVAL), oldest
        // first, with the amount credited.
        uint256 count = s.arrivalCount;
        n = Math.min(count, SpokeVaultTypes.ARRIVAL_WINDOW);
        r.arrivedTransits = new ReportCodec.TransitAmount[](n);
        for (uint256 i; i < n; ++i) {
            bytes32 id = s.recentArrivals[(count - n + i) % SpokeVaultTypes.ARRIVAL_WINDOW];
            r.arrivedTransits[i] = ReportCodec.TransitAmount(id, s.arrivals[id]);
        }

        // DEC-085: every hub-bound transit still in flight, at the amount that will arrive, with its kind (CV-OQ-1,
        // DEC-092: the hub keeps Income in flight out of Share Assets).
        n = s.inFlightIds.length;
        ReportCodec.HubBoundAmount[] memory inFlight = new ReportCodec.HubBoundAmount[](n);
        uint256 found;
        for (uint256 i; i < n; ++i) {
            bytes32 id = s.inFlightIds[i];
            Transit storage t = s.hubBoundTransits[id];
            if (_stillInFlight(t)) {
                inFlight[found++] = ReportCodec.HubBoundAmount(id, t.amountToArrive, t.kind);
            }
        }
        assembly ("memory-safe") {
            mstore(inFlight, found)
        }
        r.inFlightToHub = inFlight;
    }

    /// @dev `ReportCodec.PositionReport` is `IAdapter.PositionValue` prefixed by the adapter address, word for word, so
    ///      the value is copied behind the adapter word with one MCOPY (Cancun).
    function _positionReport(address adapter, IAdapter.PositionValue memory v)
        private
        pure
        returns (ReportCodec.PositionReport memory pr)
    {
        assembly ("memory-safe") {
            pr := mload(0x40)
            mstore(pr, adapter)
            mcopy(add(pr, 0x20), v, 0x160)
            mstore(0x40, add(pr, 0x180))
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Private helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev QA19: the fee `amount - outputAmount` is at most `maxBridgeFeeBps` of `amount` (rounded down, so the check
    ///      is never looser than the Mandate); DEC-085: a zero or above-input output is not a quote.
    function _checkQuote(uint16 maxBridgeFeeBps, uint256 amount, uint256 outputAmount) private pure {
        if (amount == 0) revert ISpokeVault.ZeroAmount();
        if (outputAmount == 0 || outputAmount > amount) {
            revert SpokeVaultTypes.InvalidQuoteAmount(amount, outputAmount);
        }
        uint256 fee = amount - outputAmount;
        uint256 maxFee = amount * maxBridgeFeeBps / MandateLib.BPS;
        if (fee > maxFee) revert ISpokeVault.BridgeFeeAboveMax(fee, maxFee);
    }

    /// @dev DEC-092: principal leaves Unallocated Balance, income leaves the collected income bucket.
    function _debit(SpokeVaultTypes.State storage s, address baseToken, uint256 amount, TransferKind kind) private {
        if (kind == TransferKind.Principal) {
            uint256 available = s.unallocated[baseToken];
            if (amount > available) revert ISpokeVault.InsufficientUnallocatedBalance(baseToken, available, amount);
            s.unallocated[baseToken] = available - amount;
        } else {
            uint256 available = s.collectedIncome[baseToken];
            if (amount > available) revert ISpokeVault.InsufficientCollectedIncome(baseToken, available, amount);
            s.collectedIncome[baseToken] = available - amount;
        }
    }

    /// @dev DEC-087: every field of the request is fixed here; the adapter only translates it. The built call must
    ///      target the pinned bridge contract and carry the quoted output (DEC-085).
    function _buildCall(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        address bridge,
        address escrow,
        uint256 amount,
        TransferKind kind,
        bytes32 transitId,
        BridgeQuote calldata quote
    ) private view returns (IBridgeAdapter.BridgeCall memory call) {
        IBridgeAdapter.SendRequest memory req;
        req.inputToken = c.baseToken;
        req.outputToken = c.hubChainUsdc;
        req.inputAmount = amount;
        req.outputAmount = quote.outputAmount;
        req.destinationChainId = c.hubChainId;
        req.recipient = bytes32(uint256(uint160(c.coreVault)));
        req.quoteTimestamp = quote.quoteTimestamp;
        req.exclusivityDeadline = quote.exclusivityDeadline;
        req.exclusiveRelayer = quote.exclusiveRelayer;
        req.message = TransitMessage.encode(c.fundId, c.chainId, transitId, kind);
        call = IBridgeAdapter(bridge).buildSend(req, escrow);
        address pinned = s.bridgeTarget[bridge];
        if (call.target != pinned) revert SpokeVaultTypes.BridgeTargetMismatch(bridge, pinned, call.target);
        if (call.amountToArrive != quote.outputAmount) {
            revert SpokeVaultTypes.BridgeAmountMismatch(quote.outputAmount, call.amountToArrive);
        }
    }

    /// @dev Books the transit as `Sent`, lists it in flight and grows `cumulativeSentHome` before the external call.
    function _book(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        bytes32 transitId,
        address bridge,
        address escrow,
        uint256 amount,
        TransferKind kind,
        IBridgeAdapter.BridgeCall memory call
    ) private returns (Transit memory t) {
        t.destinationChainId = c.hubChainId;
        t.bridgeAdapter = bridge;
        t.escrow = escrow;
        t.inputToken = c.baseToken;
        t.outputToken = c.hubChainUsdc;
        t.amountSent = amount;
        t.amountToArrive = call.amountToArrive;
        t.bridgeRef = call.transitRef;
        t.sentAt = uint64(block.timestamp);
        t.fillDeadline = call.fillDeadline;
        t.kind = kind;
        t.state = TransitState.Sent;
        s.hubBoundTransits[transitId] = t;
        s.inFlightIds.push(transitId);
        s.inFlightSlot[transitId] = s.inFlightIds.length;
        s.cumulativeSentHome += amount;
    }

    /// @dev A hub-bound transit is listed until its refund is recognized or until `fillDeadline +
    ///      ReportCodec.HUB_BOUND_RETENTION` has passed, after which it is presumed filled.
    /// @dev Security review S-3 (DEC-085, DEC-104; OQ-09 stance revised): the spoke cannot tell a filled send from an
    ///      unfilled one, and the hub nets out what it credited (`CoreVaultLogic._returnLeg`: listed minus credited), so
    ///      listing a filled send longer counts nothing twice. Dropping it at `fillDeadline + maxReportAge` (about
    ///      26 min) left an unfilled send in no value base until its Across refund (55 to 90 min after the deadline,
    ///      DEC-063) was recognized and reported: entrants minted at the understated Share Price and the Spoke Cap
    ///      forgot the return leg. The retention covers the refund latency with a wide margin; `_sweepInFlight`
    ///      recognizes a landed refund at the next report or send.
    function _stillInFlight(Transit storage t) private view returns (bool) {
        return
            t.state == TransitState.Sent && block.timestamp <= uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION;
    }

    function _removeInFlight(SpokeVaultTypes.State storage s, bytes32 transitId) private {
        uint256 slot = s.inFlightSlot[transitId];
        if (slot == 0) return;
        uint256 last = s.inFlightIds.length;
        if (slot != last) {
            bytes32 moved = s.inFlightIds[last - 1];
            s.inFlightIds[slot - 1] = moved;
            s.inFlightSlot[moved] = slot;
        }
        s.inFlightIds.pop();
        delete s.inFlightSlot[transitId];
    }

    /// @dev DEC-088: the spoke-side bridge adapter of priority `bridgeRank`; Q17-4: its codehash still matches.
    function _bridgeAdapterAt(SpokeVaultTypes.State storage s, uint256 bridgeRank)
        private
        view
        returns (address bridge)
    {
        if (bridgeRank >= s.bridgeAdapters.length) {
            revert SpokeVaultTypes.UnknownBridgeRank(bridgeRank);
        }
        bridge = s.bridgeAdapters[bridgeRank];
        _checkCodehash(s, bridge);
    }

    function _checkCodehash(SpokeVaultTypes.State storage s, address adapter) private view {
        bytes32 expected = s.codehash[adapter];
        bytes32 actual = adapter.codehash;
        if (actual != expected) revert ISpokeVault.AdapterCodehashMismatch(adapter, expected, actual);
    }

    /// @dev IBridgeAdapter custody step 3: approve exactly `amount`, plain CALL without value, exact debit, reset.
    function _executeBridgeCall(address baseToken, address target, bytes memory data, uint256 amount) private {
        IERC20 token = IERC20(baseToken);
        uint256 balanceBefore = token.balanceOf(address(this));
        token.forceApprove(target, amount);
        (bool ok, bytes memory returned) = target.call(data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 32), mload(returned))
            }
        }
        uint256 balanceAfter = token.balanceOf(address(this));
        uint256 debited = balanceBefore > balanceAfter ? balanceBefore - balanceAfter : 0;
        if (debited != amount) revert SpokeVaultTypes.BridgeDebitMismatch(amount, debited);
        token.forceApprove(target, 0);
    }
}
