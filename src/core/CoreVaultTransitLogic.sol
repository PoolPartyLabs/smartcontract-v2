// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ITransitEscrow} from "../interfaces/ITransitEscrow.sol";
import {Transit, TransitState, TransferKind} from "../interfaces/FundTypes.sol";
import {SpokeConfig, BridgeAdapterConfig} from "../mandate/Mandate.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {CoreVaultState, CoreVaultWiring, SpokeBook, HubBoundTransfer} from "./CoreVaultTypes.sol";
import {SpokeVaultTypes} from "../spoke/SpokeVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {CoreVaultIncomeLogic} from "./CoreVaultIncomeLogic.sol";
import {CoreVaultIncomeTypes} from "./CoreVaultIncomeTypes.sol";
import {CoreVaultPayoutLogic} from "./CoreVaultPayoutLogic.sol";

/// @title CoreVaultTransitLogic
/// @notice Report application, spoke-to-hub arrivals, sends to spokes and the transit outcomes of the Core Vault (the
///         DEC-066 transit state machine), as an external library that runs in the Core Vault's context (DELEGATECALL
///         into the fund's own linked library, never into an adapter).
/// @dev DEC-131 pattern (alternative C) applied to the Core Vault (D-43): moved out of `CoreVaultLogic` unchanged so
///      each linked library keeps room under the 24,576-byte limit. It calls `CoreVaultLogic` (Spoke Cap usage),
///      `CoreVaultIncomeLogic` (the income hooks) and `CoreVaultPayoutLogic` (the payout hook) through their own linked
///      addresses, so its creation code links them and its address is part of the Core Vault's creation code and trust
///      surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058). Report application lives here, not in
///      `CoreVaultLogic`: it confirms transits and credits hub-bound arrivals, and a link back from `CoreVaultLogic`
///      would make the two libraries' CREATE2 addresses depend on each other.
/// @dev The Core Vault applies access control, the reentrancy guard and the Operating Cash top-up before calling in.
///      Events are emitted with the Core Vault as their address; they and the errors are declared in ICoreVault.
library CoreVaultTransitLogic {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------------------------
    // Report application (DEC-066, DEC-080, DEC-090, Q60)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Applies a newly accepted report: confirms arrived transits and credits matched spoke-to-hub arrivals.
    ///         Never reverts because of an unknown or repeated transit id. The report's cumulative income counters are
    ///         informational (ruling 2026-09-29: spoke income is attributed only when it arrives as Income).
    /// @dev WP-07 D2: ends with the income and payout hooks (`onReportAccepted`, no-ops for now), which get the report
    ///      to read their own results from it (`collectionResults`, `unwindResults`, report version 4).
    function applyReport(CoreVaultState storage s, CoreVaultWiring memory w, uint256 spokeIndex) public {
        if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);
        (ReportCodec.Report memory r,,) = IValueReportReceiver(w.reportReceiver).latestReport(spokeIndex);
        if (r.fundId != w.fundId) revert ICoreVault.WrongFund(r.fundId);
        // Security review S-6 (FF-OQ-1, DEC-053, DEC-086, DEC-087): `createSpoke` binds a Spoke Vault's addresses to
        // the fund, not its rules, so the Manager could create it from another Mandate (a 100% bridge fee, a pool it
        // controls). Its reports then carry another hash: rejected, so the spoke never counts in Share Assets and,
        // with S-14, the hub never funds it.
        if (r.mandateHash != w.mandateHash) revert ICoreVault.WrongMandate(r.mandateHash);
        uint256 arrived = _confirmArrivals(s, spokeIndex, r.arrivedTransits, r.sequence);
        _matchReturnLeg(s, w, s.mandate.spokes[spokeIndex].chainId, r.inFlightToHub);
        emit ICoreVault.ReportAccepted(spokeIndex, r.sequence, r.blockNumber, r.timestamp, arrived);
        CoreVaultIncomeLogic.onReportAccepted(s, w, spokeIndex, r);
        CoreVaultPayoutLogic.onReportAccepted(s, w, spokeIndex, r);
    }

    /// @notice DEC-066, DEC-090: Sent or ExpiryAttested becomes ArrivalConfirmed when a report of the destination spoke
    ///         lists the id. The amount leaves In-flight Value because the report now carries it in the spoke's
    ///         balances. A RefundRecognized transit (its escrow held the full amount sent, DEC-063) that a report still
    ///         lists is confirmed too, without touching In-flight Value again: the escrow's amount was then a donation
    ///         already in Idle, and the arrival must not be deducted as unknown value (DEC-080).
    /// @dev OQ-09, OQ-01, DEC-080, DEC-104: an id is confirmed only when the listed amount reaches the transit's
    ///      `amountToArrive`. Across passes no depositor and transit ids are public (`SentToSpoke`), so a listing below
    ///      that amount may be a stranger's donation carrying a real id; confirming on id presence would release the
    ///      transit from In-flight Value and leave a later expiry refund stranded in its escrow. The spoke lists the
    ///      monotonic credited total per id, so a genuine arrival is never under-listed; a stranger who lists an id at
    ///      or above the amount has made the fund whole, and any excess is deducted as unknown-origin value.
    function _confirmArrivals(
        CoreVaultState storage s,
        uint256 spokeIndex,
        ReportCodec.TransitAmount[] memory list,
        uint64 sequence
    ) private returns (uint256 count) {
        SpokeBook storage book = s.spokeBooks[spokeIndex];
        for (uint256 i; i < list.length; ++i) {
            bytes32 id = list[i].transitId;
            Transit storage t = s.transits[id];
            TransitState state = t.state;
            if (state == TransitState.None || state == TransitState.ArrivalConfirmed) continue;
            if (s.transitSpoke[id] != spokeIndex) continue;
            if (list[i].amount < t.amountToArrive) continue;
            if (state == TransitState.Sent) book.inFlightSent -= t.amountSent;
            else _releaseHeldCap(s, book, id, t.amountSent);
            if (state != TransitState.RefundRecognized) book.inFlightToArrive -= t.amountToArrive;
            book.confirmedArrived += t.amountToArrive;
            t.state = TransitState.ArrivalConfirmed;
            ++count;
            emit ICoreVault.TransitArrived(id, spokeIndex, t.amountToArrive, sequence);
        }
    }

    /// @notice OQ-01, DEC-080: records the report's hub-bound transfers (amount and kind, first listing kept) and
    ///         credits whatever already arrived for them, up to the listed amount; anything above is held apart for
    ///         good.
    function _matchReturnLeg(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 originChainId,
        ReportCodec.HubBoundAmount[] memory list
    ) private {
        for (uint256 i; i < list.length; ++i) {
            bytes32 id = list[i].transitId;
            HubBoundTransfer storage h = s.hubBound[CoreVaultLogic.hubBoundKey(originChainId, id)];
            if (h.listed == 0) {
                h.listed = list[i].amount;
                h.kind = list[i].kind;
            }
            uint256 spokeIndex = _spokeIndexOf(s, originChainId);
            uint256 recovered = s.incomeBook.recoveredIncome[spokeIndex][id];
            if (recovered != 0 && h.kind == TransferKind.Principal) {
                delete s.incomeBook.recoveredIncome[spokeIndex][id];
                s.incomeBook.heldDollars -= recovered;
                s.idle += recovered;
            }
            uint256 pending = h.pending;
            if (pending == 0) continue;
            h.pending = 0;
            s.unmatchedArrivals -= pending;
            _creditHubBound(s, w, h, id, originChainId, pending);
        }
    }

    /// @notice ICoreVault.handleV3AcrossMessage after the caller, token, amount and fund checks: holds the amount apart
    ///         until a report lists the transfer, else credits it against what the report listed (DEC-080, OQ-01).
    /// @dev `kind` is the Across message's claim; it is only logged for an unmatched arrival. Once listed, an arrival
    ///      is credited by the kind the report carries (CV-OQ-1), so a stranger's message cannot relabel income as
    ///      principal or the reverse.
    function receiveHubBound(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 originChainId,
        bytes32 transitId,
        TransferKind kind,
        uint256 amount
    ) public {
        HubBoundTransfer storage h = s.hubBound[CoreVaultLogic.hubBoundKey(originChainId, transitId)];
        if (h.listed == 0) {
            // Cross-check of the independent review (S-45, S-64): the recovery clock restarts at an arrival at least as
            // large as what is already held for the id. Dust bridged early under a predictable id is outweighed by the
            // fund's own transfer, which restarts it (S-45); dust after the transfer cannot restart it, so a stranger
            // can hold the recovery off only by bridging at least the held amount again each time (S-64), which the
            // recovery then credits to the fund.
            uint256 pending = h.pending;
            if (amount >= pending) h.pendingSince = uint64(block.timestamp);
            h.pending = pending + amount;
            s.unmatchedArrivals += amount;
            emit ICoreVault.TransitReceived(transitId, originChainId, kind, amount, false);
            return;
        }
        _creditHubBound(s, w, h, transitId, originChainId, amount);
    }

    /// @notice Credits up to the listed amount not yet credited, by the listed kind: Principal to Idle; Income is
    ///         collected income that reached the Core Vault, handed to the income hook `onIncomeArrival` (today: split
    ///         at once, ruling 2026-09-29, `collectIncome`); the rest is held apart for good (DEC-080).
    function _creditHubBound(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        HubBoundTransfer storage h,
        bytes32 transitId,
        uint256 originChainId,
        uint256 amount
    ) private {
        TransferKind kind = h.kind;
        // A recovered unlisted arrival (S-4) may have credited more than a later listing.
        uint256 room = h.listed > h.credited ? h.listed - h.credited : 0;
        uint256 credit = amount < room ? amount : room;
        if (credit != 0) {
            h.credited += credit;
            emit ICoreVault.TransitReceived(transitId, originChainId, kind, credit, true);
            if (kind == TransferKind.Principal) {
                s.idle += credit;
            } else {
                uint256 spokeIndex = _spokeIndexOf(s, originChainId);
                CoreVaultIncomeLogic.onIncomeArrival(s, w, spokeIndex, w.usdc, credit, transitId);
            }
        }
        if (amount > credit) {
            s.unmatchedArrivals += amount - credit;
            emit ICoreVault.ArrivalHeldApart(transitId, originChainId, kind, amount - credit);
        }
    }

    /// @dev The Mandate spoke on `chainId` (spoke chain ids are unique, MandateLib.validate). Only called for a
    ///      transfer an accepted report of that spoke listed, so the spoke exists.
    function _spokeIndexOf(CoreVaultState storage s, uint256 chainId) private view returns (uint256 i) {
        while (s.mandate.spokes[i].chainId != chainId) ++i;
    }

    /// @notice ICoreVault.recoverUnlistedArrival (security review S-4, corrected by the cross-check of the independent
    ///         review).
    /// @dev Condition: the spoke's latest accepted report was built after the last unlisted arrival for the id, with
    ///      one report lifetime of margin for clock skew (the receiver accepts a report up to one lifetime ahead of the
    ///      hub clock, CS-OQ-5). A spoke lists a send home of its own in every report until its refund is recognized or
    ///      `fillDeadline + ReportCodec.HUB_BOUND_RETENTION`, so such a report not listing the id proves the transfer
    ///      is past its retention or never was the spoke's (a stranger's dust), and its principal no longer counts it:
    ///      crediting Idle counts it once. The first version opened on a delay from the FIRST arrival alone, which a
    ///      stranger could start early with dust under a predictable id, and which a report outage made reachable
    ///      while the latest accepted report still showed the principal on the spoke: Idle and that report counted
    ///      the transfer twice and a claimant was overpaid. The recovered amount joins `credited`, so a later listing
    ///      of the same id nets it out; a stranger's dust becomes a donation to Idle.
    /// @dev DEC-080, DEC-092, DEC-161: a recovery reserved while Income is unresolved can be retried once every
    ///      recognized token and fee unit, pending spoke and open result is settled. The bounded source/token check
    ///      uses authenticated report and collection accounting, never the Across message kind. The amount was
    ///      already credited on its first recovery, so releasing the reservation must not credit the transit again.
    function recoverUnlistedArrival(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        bytes32 transitId
    ) public returns (uint256 amount) {
        if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);
        SpokeConfig storage spoke = s.mandate.spokes[spokeIndex];
        uint256 originChainId = spoke.chainId;
        HubBoundTransfer storage h = s.hubBound[CoreVaultLogic.hubBoundKey(originChainId, transitId)];
        amount = s.incomeBook.recoveredIncome[spokeIndex][transitId];
        if (amount != 0 && CoreVaultIncomeLogic.finalCollectionDone(s, w)) {
            delete s.incomeBook.recoveredIncome[spokeIndex][transitId];
            s.incomeBook.heldDollars -= amount;
            s.idle += amount;
            emit ICoreVault.UnlistedArrivalRecovered(transitId, originChainId, amount);
            return amount;
        }
        amount = h.pending;
        if (h.listed != 0 || amount == 0) revert ICoreVault.NothingToRecover(transitId);
        uint256 builtAfter = uint256(h.pendingSince) + uint256(spoke.maxReportAge);
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        if (!receiver.hasReport(spokeIndex)) revert ICoreVault.RecoveryNotReady(transitId, builtAfter);
        (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
        if (r.timestamp <= builtAfter) revert ICoreVault.RecoveryNotReady(transitId, builtAfter);
        h.pending = 0;
        h.credited += amount;
        s.unmatchedArrivals -= amount;
        if (_incomeRecoveryPending(s, spokeIndex, transitId)) {
            s.incomeBook.recoveredIncome[spokeIndex][transitId] += amount;
            s.incomeBook.heldDollars += amount;
        } else {
            s.idle += amount;
        }
        emit ICoreVault.UnlistedArrivalRecovered(transitId, originChainId, amount);
    }

    function _incomeRecoveryPending(CoreVaultState storage s, uint256 spokeIndex, bytes32 transitId)
        private
        view
        returns (bool)
    {
        if (s.incomeBook.resultOf[spokeIndex][transitId] != 0 || s.incomeBook.pendingSpokes != 0) return true;
        CoreVaultIncomeTypes.Source storage source = s.incomeBook.sources[spokeIndex + 1];
        for (uint256 index; index < source.index.tokens.length; ++index) {
            address token = source.index.tokens[index];
            if (source.index.token[token].recognized != 0 || source.feeUnits[token] != 0) return true;
        }
        return false;
    }

    /// @notice DEC-066: non-arrival is proven by a spoke report built after the fill deadline that does not list the
    ///         transit, or by the deadline plus the spoke's report lifetime having passed.
    /// @dev OQ-09 (Spoke Vault and Core Vault verifier findings): the report lists only the last
    ///      `ReportCodec.ARRIVAL_WINDOW` arrivals, so its silence proves non-arrival only while it lists fewer than
    ///      that; a full window may have evicted the id (dust spam), and then only the deadline plus report lifetime
    ///      path applies. OQ-09, OQ-01: a listing below the transit's `amountToArrive` is not an arrival (see
    ///      `_confirmArrivals`), so a report built after the deadline that lists the id only below that amount proves
    ///      non-arrival as well: once the deadline has passed Across can no longer fill the deposit.
    function nonArrivalProvable(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        bytes32 transitId,
        uint32 deadline
    ) public view returns (bool) {
        return _expiryByTime(s, spokeIndex, deadline) || _reportProvesNonArrival(s, w, spokeIndex, transitId, deadline);
    }

    /// @dev The time path: the deadline plus the spoke's report lifetime has passed. It proves nothing about the
    ///      arrival itself (security review S-13).
    function _expiryByTime(CoreVaultState storage s, uint256 spokeIndex, uint32 deadline) private view returns (bool) {
        return block.timestamp > uint256(deadline) + s.mandate.spokes[spokeIndex].maxReportAge;
    }

    /// @dev The report path: the latest accepted report, built after the deadline and listing fewer than
    ///      `ARRIVAL_WINDOW` ids, does not list the transit at or above its `amountToArrive`.
    function _reportProvesNonArrival(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        bytes32 transitId,
        uint32 deadline
    ) private view returns (bool) {
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        if (!receiver.hasReport(spokeIndex)) return false;
        (ReportCodec.Report memory r,,) = receiver.latestReport(spokeIndex);
        if (r.timestamp <= deadline || r.arrivedTransits.length >= ReportCodec.ARRIVAL_WINDOW) return false;
        uint256 expected = s.transits[transitId].amountToArrive;
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            if (r.arrivedTransits[i].transitId == transitId && r.arrivedTransits[i].amount >= expected) return false;
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Send to a spoke (DEC-037, DEC-066, DEC-085, DEC-087, DEC-088, DEC-095, DEC-158, DEC-162)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVault.sendToSpoke after access control, the guard and the Operating Cash top-up.
    /// @dev DEC-087 and IBridgeAdapter custody: the vault fixes recipient, token pair, amount sent and message; the
    ///      bridge adapter fixes the amount to arrive and every other bridge term (DEC-158, DEC-162: the manager passes
    ///      no bridge parameter, and no bridge fee cap lives in the fund, DEC-156); the vault requires the pinned
    ///      target, `0 < amountToArrive <= usdcAmount` and a future deadline, approves exactly the amount, makes a
    ///      plain CALL without value, requires the exact debit and resets the approval.
    function sendToSpoke(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        uint256 usdcAmount,
        uint256 bridgeRank,
        bytes calldata bridgeData
    ) public returns (bytes32 transitId) {
        SpokeConfig memory spoke = s.mandate.spokes[spokeIndex];
        address adapter = _checkSend(s, w, spokeIndex, spoke.chainId, usdcAmount, bridgeRank);
        transitId = keccak256(abi.encode(block.chainid, address(this), ++s.transitNonce));
        (IBridgeAdapter.BridgeCall memory call, address escrow) =
            _buildSend(s, w, spoke, adapter, usdcAmount, transitId, bridgeData);
        _bookSend(s, w, spokeIndex, spoke, adapter, escrow, usdcAmount, transitId, call);
        _executeBridgeCall(IERC20(w.usdc), call, usdcAmount);
    }

    /// @dev DEC-066, QA6: clones the keyless per-send escrow (the depositor of record, so a refund is recognizable),
    ///      has the adapter build the call and checks it: pinned target, `0 < amountToArrive <= usdcAmount` (DEC-085,
    ///      DEC-162) and a future fill deadline.
    function _buildSend(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        SpokeConfig memory spoke,
        address adapter,
        uint256 usdcAmount,
        bytes32 transitId,
        bytes calldata bridgeData
    ) private returns (IBridgeAdapter.BridgeCall memory call, address escrow) {
        escrow = Clones.clone(w.escrowImplementation);
        ITransitEscrow(escrow).initialize(address(this), w.usdc);
        call = IBridgeAdapter(adapter).buildSend(_sendRequest(w, spoke, usdcAmount, transitId), escrow, bridgeData);
        if (
            call.target != s.bridgeTarget[adapter] || call.amountToArrive == 0 || call.amountToArrive > usdcAmount
                || call.fillDeadline <= block.timestamp
        ) revert ICoreVault.BridgeCallMismatch(adapter);
    }

    /// @dev Effects: DEC-066 state Sent; Spoke Cap at the amount sent (C1); Share Assets at the amount to arrive
    ///      (DEC-085).
    function _bookSend(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        SpokeConfig memory spoke,
        address adapter,
        address escrow,
        uint256 usdcAmount,
        bytes32 transitId,
        IBridgeAdapter.BridgeCall memory call
    ) private {
        s.idle -= usdcAmount;
        SpokeBook storage book = s.spokeBooks[spokeIndex];
        book.inFlightSent += usdcAmount;
        book.inFlightToArrive += call.amountToArrive;
        Transit memory t = Transit({
            destinationChainId: spoke.chainId,
            bridgeAdapter: adapter,
            escrow: escrow,
            inputToken: w.usdc,
            outputToken: spoke.spokeToken,
            amountSent: usdcAmount,
            amountToArrive: call.amountToArrive,
            bridgeRef: call.transitRef,
            sentAt: uint64(block.timestamp),
            fillDeadline: call.fillDeadline,
            kind: TransferKind.Principal,
            state: TransitState.Sent
        });
        s.transits[transitId] = t;
        s.transitSpoke[transitId] = spokeIndex;
        emit ICoreVault.SentToSpoke(transitId, spokeIndex, t, w.hubChainId);
    }

    /// @dev Interaction, IBridgeAdapter custody rule 3: approve exactly `amount`, plain CALL without value, exact
    ///      debit, approval reset.
    function _executeBridgeCall(IERC20 token, IBridgeAdapter.BridgeCall memory call, uint256 amount) private {
        uint256 before = token.balanceOf(address(this));
        token.forceApprove(call.target, amount);
        (bool ok, bytes memory ret) = call.target.call(call.data);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(ret, 0x20), mload(ret))
            }
        }
        uint256 debited = before - token.balanceOf(address(this));
        if (debited != amount) revert ICoreVault.BalanceChangeMismatch(amount, debited);
        token.forceApprove(call.target, 0);
    }

    /// @notice Checks of a send; returns the bridge adapter to use.
    function _checkSend(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        uint256 spokeChainId,
        uint256 usdcAmount,
        uint256 bridgeRank
    ) private view returns (address adapter) {
        // Security review S-14 (DEC-066, DEC-104): a spoke is funded only once the hub accepted a report from it. The
        // Spoke Vault is created by a second transaction on another chain; an Across fill to an address without code
        // succeeds, skips the handler and is never refunded, so the amount would stay in In-flight Value for good. An
        // accepted report proves the fund's Spoke Vault exists there (and, with S-6, runs the hub's Mandate).
        if (!IValueReportReceiver(w.reportReceiver).hasReport(spokeIndex)) {
            revert ICoreVault.SpokeNotReporting(spokeIndex);
        }

        // DEC-017, DEC-072: only Free Idle leaves the Core Vault.
        uint256 free = s.idle - s.payoutReserve;
        if (usdcAmount > free) revert ICoreVault.InsufficientFreeIdle(usdcAmount, free);

        // DEC-088: the Mandate's bridge adapter of that rank on the hub side; DEC-021, DEC-056, DEC-058: never a
        // paused or deprecated one for an entry toward a spoke.
        adapter = _hubBridgeAdapter(s, w.hubChainId, spokeChainId, bridgeRank);
        if (IBridgeAdapter(adapter).paused() || IBridgeAdapter(adapter).deprecated()) {
            revert ICoreVault.BridgeAdapterUnavailable(adapter);
        }
        if (adapter.codehash != s.bridgeCodehash[adapter]) revert ICoreVault.BridgeAdapterCodehashMismatch(adapter);

        // DEC-037, DEC-095, DEC-066 B1/C1: spoke value + in flight (both legs) + amount <= Spoke Cap.
        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub, uint256 cap) =
            CoreVaultLogic.spokeCapUsage(s, w, spokeIndex);
        uint256 used = spokeValue + inFlightSent + inFlightToHub;
        if (used + usdcAmount > cap) revert ICoreVault.SpokeCapExceeded(spokeIndex, used, usdcAmount, cap);
    }

    /// @dev DEC-087: what the vault fixes; never an amount to arrive (DEC-158, DEC-162).
    function _sendRequest(CoreVaultWiring memory w, SpokeConfig memory spoke, uint256 usdcAmount, bytes32 transitId)
        private
        pure
        returns (IBridgeAdapter.SendRequest memory)
    {
        return IBridgeAdapter.SendRequest({
            inputToken: w.usdc,
            outputToken: spoke.spokeToken,
            inputAmount: usdcAmount,
            destinationChainId: spoke.chainId,
            recipient: spoke.spokeVault,
            message: TransitMessage.encode(w.fundId, w.hubChainId, transitId, TransferKind.Principal)
        });
    }

    /// @notice DEC-088: the bridge adapter of priority `rank` serving `spokeChainId` from the hub.
    function _hubBridgeAdapter(CoreVaultState storage s, uint256 hubChainId, uint256 spokeChainId, uint256 rank)
        private
        view
        returns (address)
    {
        BridgeAdapterConfig[] storage list = s.mandate.bridgeAdapters;
        uint256 seen;
        for (uint256 i; i < list.length; ++i) {
            if (list[i].spokeChainId == spokeChainId && list[i].chainId == hubChainId) {
                if (seen == rank) return list[i].adapter;
                ++seen;
            }
        }
        revert ICoreVault.BridgeAdapterUnavailable(address(0));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Transit outcomes (DEC-066, DEC-090; QB11 / QB10 OPEN)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVault.attestExpiry: Sent becomes ExpiryAttested after the fill deadline with proof of non-arrival;
    ///         the Spoke Cap is released while Share Assets keep counting the transit until its refund (DEC-066).
    /// @dev DEC-162: a report's proof of non-arrival is the send's outcome for the bridge adapter's fee rule
    ///      (`_noteExpiry`); the time path proves nothing about the arrival (S-13), so on it the adapter learns the
    ///      expiry only when the refund is recognized. Otherwise anyone could attest a filled send of a quiet fund
    ///      (reports are published only when someone operates, DEC-157) and step every next send's fee up. A report
    ///      proves nothing either for a send whose amount to arrive is below the Spoke Vault's listing minimum
    ///      (`SpokeVaultTypes.MIN_LISTED_ARRIVAL`, CS-OQ-6: such an arrival is credited but never listed), so that
    ///      send is also noted only at its refund.
    function attestExpiry(CoreVaultState storage s, CoreVaultWiring memory w, bytes32 transitId) public {
        Transit storage t = _knownTransit(s, transitId);
        if (t.state != TransitState.Sent) revert ICoreVault.InvalidTransitState(transitId, uint8(t.state));
        uint32 deadline = t.fillDeadline;
        if (block.timestamp <= deadline) revert ICoreVault.FillDeadlineNotReached(transitId, deadline);
        uint256 spokeIndex = s.transitSpoke[transitId];
        bool byReport = _reportProvesNonArrival(s, w, spokeIndex, transitId, deadline);
        if (!byReport && !_expiryByTime(s, spokeIndex, deadline)) revert ICoreVault.ExpiryNotProvable(transitId);
        t.state = TransitState.ExpiryAttested;
        // Security review S-13 (DEC-037, DEC-095; DEC-066 A2 read conservatively): only a report proves that the
        // transit did not arrive. On the time path alone it may have been filled and never confirmed (a report outage,
        // or its id evicted from the arrival window), so its Spoke Cap stays held until the arrival is confirmed or
        // the refund is recognized; otherwise the manager could send the cap again on top of the arrived capital.
        if (byReport) s.spokeBooks[spokeIndex].inFlightSent -= t.amountSent;
        else s.spokeCapHeld[transitId] = true;
        emit ICoreVault.TransitExpiryAttested(transitId, spokeIndex, msg.sender);
        if (byReport && _listable(t)) _noteExpiry(t, transitId);
    }

    /// @dev Whether the spoke lists this send's arrival, so that a report's silence proves non-arrival for the fee
    ///      rule: an arrival below `MIN_LISTED_ARRIVAL` is credited but never listed (CS-OQ-6).
    function _listable(Transit storage t) private view returns (bool) {
        return t.amountToArrive >= SpokeVaultTypes.MIN_LISTED_ARRIVAL;
    }

    /// @dev DEC-162: tells the transit's bridge adapter that the send will never arrive, so its fee rule steps the
    ///      route's next send up. DEC-056: an adapter never blocks an outcome; a failure is only reported. A caller
    ///      cannot starve the call to skip the note: EIP-150 leaves the vault 1/64 of the gas, far less than the work
    ///      after the call, so a starved call reverts the whole outcome.
    function _noteExpiry(Transit storage t, bytes32 transitId) private {
        address adapter = t.bridgeAdapter;
        try IBridgeAdapter(adapter).noteExpiry(t.bridgeRef) {}
        catch {
            emit ICoreVault.BridgeExpiryNoteFailed(transitId, adapter);
        }
    }

    /// @dev Releases the Spoke Cap a time-path attestation kept (security review S-13); returns whether it held one.
    function _releaseHeldCap(CoreVaultState storage s, SpokeBook storage book, bytes32 transitId, uint256 amountSent)
        private
        returns (bool held)
    {
        if (!s.spokeCapHeld[transitId]) return false;
        delete s.spokeCapHeld[transitId];
        book.inFlightSent -= amountSent;
        return true;
    }

    /// @notice ICoreVault.recognizeRefund (DEC-066, QA6): pulls an attested-expired transit's refund from its escrow
    ///         back into Idle.
    /// @dev DEC-066, DEC-090: the only path is Sent -> ExpiryAttested -> RefundRecognized, so the non-arrival proof of
    ///      `attestExpiry` always comes first; a transit still Sent (possibly filled, its report not yet delivered) is
    ///      refused. DEC-063 (docs/DECISIONS.md, Across expired-deposit refund): Across refunds the full `inputAmount`
    ///      to the depositor, so an escrow holding less than `amountSent` holds no refund and nothing changes
    ///      (`NoRefund`). DEC-080, DEC-104: exactly `amountSent` enters Idle as the transit leaves In-flight Value;
    ///      anything above it (a donation) reaches the Core Vault unledgered and only `sweepExcess` moves it. A dust
    ///      donation therefore can neither move the state nor Share Assets. DEC-162: after an attestation by time
    ///      alone, or by a report for a send below the listing minimum, the refund is the first proof of non-arrival,
    ///      so the bridge adapter learns the expiry here. That proof is only the escrow balance: whoever pays
    ///      `amountSent` into a filled send's escrow (the payment becomes the fund's) also steps one send's fee, once
    ///      per send and within the cap (review round 1; a known limitation).
    function recognizeRefund(CoreVaultState storage s, CoreVaultWiring memory w, bytes32 transitId)
        public
        returns (uint256 amount)
    {
        Transit storage t = _knownTransit(s, transitId);
        if (t.state != TransitState.ExpiryAttested) revert ICoreVault.InvalidTransitState(transitId, uint8(t.state));
        address escrow = t.escrow;
        IERC20 token = IERC20(w.usdc);
        uint256 held = token.balanceOf(escrow);
        amount = t.amountSent;
        if (held < amount) revert ICoreVault.NoRefund(transitId);
        uint256 spokeIndex = s.transitSpoke[transitId];
        // The Spoke Cap was released at the attested expiry, or is released now if the expiry was attested by time
        // alone (S-13: the refund proves non-arrival); Share Assets release the transit now (QB11/QB10 stance).
        SpokeBook storage book = s.spokeBooks[spokeIndex];
        bool attestedByTime = _releaseHeldCap(s, book, transitId, amount);
        book.inFlightToArrive -= t.amountToArrive;
        t.state = TransitState.RefundRecognized;
        s.idle += amount;
        emit ICoreVault.TransitRefundRecognized(transitId, spokeIndex, amount);
        if (attestedByTime || !_listable(t)) _noteExpiry(t, transitId);
        uint256 before = token.balanceOf(address(this));
        ITransitEscrow(escrow).release(address(this));
        uint256 received = token.balanceOf(address(this)) - before;
        if (received != held) revert ICoreVault.BalanceChangeMismatch(held, received);
    }

    function _knownTransit(CoreVaultState storage s, bytes32 transitId) private view returns (Transit storage t) {
        t = s.transits[transitId];
        if (t.state == TransitState.None) revert ICoreVault.UnknownTransit(transitId);
    }
}
