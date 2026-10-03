// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {IManagerRegistry} from "../interfaces/IManagerRegistry.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {DollarIncomeIndex} from "../libraries/DollarIncomeIndex.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {SpokeIncomeTypes} from "../spoke/SpokeIncomeTypes.sol";
import {CoreVaultState, CoreVaultWiring} from "./CoreVaultTypes.sol";
import {CoreVaultIncomeTypes} from "./CoreVaultIncomeTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {TransferKind} from "../interfaces/FundTypes.sol";

/// @title CoreVaultIncomeCollectionLogic
/// @notice Attributed Income of the Core Vault in the Hub dollar index (DEC-161), collection side: recognition from the
///         income counters (DEC-117, DEC-138), the Income Withdrawal request with the Hub collection and the spokes'
///         collection rounds (DEC-122, DEC-124, DEC-172), the spokes' collection results, the conversion at each
///         collection's rate per token (DEC-161) and the fee paid in USDC (DEC-124 item 2, DEC-128 item 4), as an
///         external library that runs in the Core Vault's context (DELEGATECALL into the fund's own linked library,
///         never into an adapter).
/// @dev Split out of `CoreVaultIncomeLogic` by concern so each linked library keeps room under the 24,576-byte limit
///      (DEC-131 pattern, D-43; WP-10 plan: split when it nears 22K). It calls no other linked library (the fee transfer
///      `CoreVaultLogic.payFee` is internal, so it is compiled in); the Core Vault and `CoreVaultIncomeLogic` call it
///      through its linked address, which is part of the Core Vault's creation code and trust surface (immutable: no
///      proxy, no upgrade path, DEC-022, DEC-058). It must never call a public function of the Core Vault's other
///      libraries: they link it, directly or through `CoreVaultIncomeLogic`.
/// @dev Events are emitted with the Core Vault as their address; they and the errors are declared in ICoreVaultIncome
///      and ICoreVault, except the `DollarIncomeIndex` events (checklist doc 15, gap 5).
library CoreVaultIncomeCollectionLogic {
    using DollarIncomeIndex for DollarIncomeIndex.State;

    /// @dev DEC-106: default protocol slice when the registry cannot be read.
    uint16 internal constant DEFAULT_PROTOCOL_SLICE_BPS = 5000;

    /// @dev DEC-112: the protocol slice is between 5% and 50% of the performance fee, never 0; a registry value outside
    ///      is clamped (R112-05).
    uint16 internal constant MIN_PROTOCOL_SLICE_BPS = 500;
    uint16 internal constant MAX_PROTOCOL_SLICE_BPS = 5000;

    uint256 private constant BPS = 10_000;

    // ---------------------------------------------------------------------------------------------------------------
    // Income Withdrawal request (DEC-122, DEC-124, DEC-161, DEC-166, DEC-172, DEC-175)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVaultIncome.requestIncomeWithdrawal for `holder`, after the guard; `messageFee` is the entry's
    ///         `msg.value` (libraries cannot be payable).
    function requestIncomeWithdrawal(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        address holder,
        uint16 maxLossBps,
        uint256 messageFee
    ) public returns (uint64 round) {
        if (s.fundState == ICoreVaultLifecycle.FundState.Closed) {
            if (messageFee != 0) revert ICoreVaultIncome.MessageFeeNotUsed(messageFee);
            round = s.incomeBook.round;
            s.incomeBook.requests[holder] = CoreVaultIncomeTypes.Request(round, true);
            emit ICoreVaultIncome.IncomeWithdrawalRequested(holder, round);
            return round;
        }
        _collectHub(s, w, maxLossBps);
        bool published = _collectSpokes(s, w, maxLossBps, messageFee);
        if (!published && messageFee != 0) revert ICoreVaultIncome.MessageFeeNotUsed(messageFee);
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        round = b.round;
        b.requests[holder] = CoreVaultIncomeTypes.Request(round, true);
        emit ICoreVaultIncome.IncomeWithdrawalRequested(holder, round);
    }

    /// @notice DEC-106, DEC-110, DEC-112: the registry is read at every charge and clamped to [5%, 50%]; a failed read
    ///         never blocks a collection (DEC-107 reading 3): the DEC-106 default of 50% applies.
    function protocolSliceBps(CoreVaultWiring memory w) public view returns (uint16 bps) {
        try IManagerRegistry(w.managerRegistry).protocolSliceBps(w.manager) returns (uint16 value) {
            bps = value < MIN_PROTOCOL_SLICE_BPS
                ? MIN_PROTOCOL_SLICE_BPS
                : value > MAX_PROTOCOL_SLICE_BPS ? MAX_PROTOCOL_SLICE_BPS : value;
        } catch {
            bps = DEFAULT_PROTOCOL_SLICE_BPS;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Entries of CoreVaultIncomeLogic's hooks (WP-07 D2)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Recognizes every counter of `counters` in `source` at the shares outstanding now (DEC-117, DEC-138):
    ///         the Hub's from a valuation's hub report (`CoreVaultIncomeLogic.onValuation`). Never reverts.
    function recognize(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 source,
        ReportCodec.TokenAmount[] memory counters
    ) public {
        _recognizeAll(s, w, source, counters);
    }

    /// @notice A newly accepted report of spoke `spokeIndex` (`CoreVaultIncomeLogic.onReportAccepted`): recognizes the
    ///         spoke's income from its counters, then reads its collection results (DEC-122 item 5, DEC-161).
    /// @dev Doc 10 section 8: the report published with a collection carries the counters after it, so the income it
    ///      sold is recognized before it is converted. A result whose Income transfer was already credited is converted
    ///      here. Runs inside the report delivery: it never reverts on income and stays bounded (at most
    ///      `SpokeIncomeTypes.REPORTED_RESULTS` results of at most 16 tokens). The results come from the fund's own
    ///      Spoke Vault (the report passed the Mandate hash check, S-6).
    function readReport(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        ReportCodec.TokenAmount[] memory counters,
        bytes memory collectionResults
    ) public {
        _recognizeAll(s, w, spokeIndex + 1, counters);
        if (collectionResults.length == 0) return;
        SpokeIncomeTypes.CollectionResult[] memory list =
            abi.decode(collectionResults, (SpokeIncomeTypes.CollectionResult[]));
        for (uint256 i; i < list.length; ++i) {
            _readResult(s, w, spokeIndex, list[i]);
        }
    }

    /// @notice An Income transfer of spoke `spokeIndex` was credited (`CoreVaultIncomeLogic.onIncomeArrival`): the USDC
    ///         is held for the collection result it carries and converts that result when the Hub already read it.
    /// @dev Runs inside a report delivery or an Across fill (`handleV3AcrossMessage`), so it never reverts.
    function creditIncome(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        uint256 amount,
        bytes32 transitId
    ) public {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 credited = b.credited[spokeIndex][transitId] + amount;
        b.credited[spokeIndex][transitId] = credited;
        b.heldDollars += amount;
        uint64 id = b.resultOf[spokeIndex][transitId];
        if (id == 0) return;
        CoreVaultIncomeTypes.SpokeResult storage res = b.results[spokeIndex][id];
        if (!res.closed && res.transitId == transitId && _fullyCredited(s, spokeIndex, transitId)) {
            _closeSpokeResult(s, w, spokeIndex, res, credited);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Recognition (DEC-117, DEC-138; D-40)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Recognizes every counter of `counters` in `source`, at the shares outstanding now.
    function _recognizeAll(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 source,
        ReportCodec.TokenAmount[] memory counters
    ) private {
        if (s.fundState == ICoreVaultLifecycle.FundState.Closed) return;
        CoreVaultIncomeTypes.Source storage src = s.incomeBook.sources[source];
        uint16 feeBps = s.performanceFeeBps;
        uint256 supply = IERC20(w.shareToken).totalSupply();
        for (uint256 i; i < counters.length; ++i) {
            _recognize(src, source, counters[i].token, counters[i].amount, feeBps, supply);
        }
    }

    /// @dev Q60, DEC-117 item 1: the advance of a monotonic counter since the last recognized one is income earned
    ///      since; a counter below the last, or an advance above the index's step bound, is skipped with an event and
    ///      the last counter stays. DEC-107, DEC-117 item 3, D-40: `fee = advance * performanceFeeBps`, rounded down
    ///      (in the holders' favour), is owed in token units; the net enters the open interval's token index. With no
    ///      share outstanding (supply 0 exists only after closure, DEC-121, DEC-127) the net enters no index and its
    ///      dollars, when sold, belong to nobody (DEC-167: the garbage collector's).
    function _recognize(
        CoreVaultIncomeTypes.Source storage src,
        uint256 source,
        address token,
        uint256 cumulative,
        uint16 feeBps,
        uint256 supply
    ) private {
        if (!src.index.isRegistered(token)) return;
        uint256 last = src.counter[token];
        if (cumulative == last) return;
        if (cumulative < last || cumulative - last > DollarIncomeIndex.MAX_STEP) {
            emit ICoreVaultIncome.IncomeCounterSkipped(source, token, last, cumulative);
            return;
        }
        uint256 amount = cumulative - last;
        src.counter[token] = cumulative;
        uint256 fee = amount * feeBps / BPS;
        if (fee != 0) src.feeUnits[token] += fee;
        bool entered = src.index.recognize(token, amount - fee, supply);
        emit ICoreVaultIncome.IncomeRecognized(source, token, cumulative, amount, fee, entered);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Collection rounds (DEC-122, DEC-124, DEC-161, DEC-166, DEC-172, DEC-175)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-172: the Hub positions' income is sold for USDC in the same collection. Recognized first from the hub
    ///      Spoke Vault's counters (DEC-138: what is sold was recognized), then collected, sold and transferred by the
    ///      hub Spoke Vault, then converted at this collection's rates (no bridge: the dollars obtained are the dollars
    ///      credited). A hub read or collection that fails is skipped (DEC-056); the Hub income waits for the next one.
    ///      DEC-080: only the USDC that reached the Core Vault during the call is converted.
    function _collectHub(CoreVaultState storage s, CoreVaultWiring memory w, uint16 maxLossBps) private {
        ISpokeVault hub = ISpokeVault(w.hubSpokeVault);
        try hub.buildReport() returns (ReportCodec.Report memory r) {
            _recognizeAll(s, w, CoreVaultIncomeTypes.HUB_SOURCE, r.cumulativeIncome);
        } catch {
            emit ICoreVaultIncome.HubIncomeCollectionFailed();
            return;
        }
        IERC20 usdc = IERC20(w.usdc);
        uint256 before = usdc.balanceOf(address(this));
        try hub.collectIncomeAll(maxLossBps) returns (
            address[] memory tokens, uint256[] memory sold, uint256[] memory obtained
        ) {
            CoreVaultIncomeTypes.Source storage src = s.incomeBook.sources[CoreVaultIncomeTypes.HUB_SOURCE];
            (uint256[] memory soldAligned, uint256[] memory dollars, uint256 total) =
                _align(src.index.tokens, tokens, sold, obtained);
            uint256 received = usdc.balanceOf(address(this)) - before;
            if (received < total) revert ICoreVault.UnbackedCredit(w.usdc, total, received);
            if (total != 0 || _any(soldAligned)) {
                _convert(s, w, CoreVaultIncomeTypes.HUB_SOURCE, soldAligned, dollars, bytes32(0), total);
            }
        } catch {
            emit ICoreVaultIncome.HubIncomeCollectionFailed();
        }
    }

    /// @dev DEC-122 items 1 and 5, DEC-120 (the channel): one collection order per round, broadcast to the spokes whose
    ///      last accepted report shows income to collect (in a position or in the collected income bucket). A request
    ///      during a round still waiting for a spoke joins it; once the round's order expired (`ORDER_LIFETIME`) the
    ///      next request publishes it again as a new attempt (a new order id, DEC-151 pattern). Returns whether an
    ///      order was published.
    function _collectSpokes(CoreVaultState storage s, CoreVaultWiring memory w, uint16 maxLossBps, uint256 messageFee)
        private
        returns (bool)
    {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        if (b.pendingSpokes != 0) {
            if (block.timestamp <= b.deadline) return false;
            ++b.attempt;
        } else {
            uint256 mask = _spokesWithIncome(s, w);
            if (mask == 0) return false;
            ++b.round;
            b.attempt = 0;
            b.pendingSpokes = mask;
        }
        OrderCodec.Order memory o;
        o.kind = OrderCodec.COLLECT;
        o.fundId = w.fundId;
        o.requestId = bytes32(uint256(b.round));
        o.attempt = b.attempt;
        o.maxLossBps = maxLossBps;
        uint64 sequence = OrderCodec.publish(w.wormholeCore, o, messageFee);
        b.deadline = o.deadline;
        emit ICoreVault.OrderPublished(o.kind, OrderCodec.orderId(o), o.requestId, o.attempt, sequence);
        return true;
    }

    /// @dev Bitmask of the spokes whose last accepted report shows income: a position's uncollected income, or a
    ///      collected income bucket (which also holds a refunded send of an earlier collection, to send again).
    function _spokesWithIncome(CoreVaultState storage s, CoreVaultWiring memory w) private view returns (uint256 mask) {
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        uint256 n = s.mandate.spokes.length;
        for (uint256 i; i < n; ++i) {
            if (!receiver.hasReport(i)) continue;
            (ReportCodec.Report memory r,,) = receiver.latestReport(i);
            if (_showsIncome(r)) mask |= 1 << i;
        }
    }

    function _showsIncome(ReportCodec.Report memory r) private pure returns (bool) {
        for (uint256 j; j < r.collectedIncome.length; ++j) {
            if (r.collectedIncome[j].amount != 0) return true;
        }
        for (uint256 j; j < r.positions.length; ++j) {
            if (r.positions[j].income0 != 0 || r.positions[j].income1 != 0) return true;
        }
        return false;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Spoke results (DEC-122 item 5, DEC-161, DEC-166)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Records a result the first time a report lists it (an empty one, nothing sent, closes at once), follows a
    ///      refunded send's successor, and converts the result when its transfer was already credited.
    function _readResult(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        SpokeIncomeTypes.CollectionResult memory c
    ) private {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        CoreVaultIncomeTypes.SpokeResult storage res = b.results[spokeIndex][c.resultId];
        if (res.closed || c.resultId == 0) return;
        if (!res.seen) {
            if (c.sold.length != c.tokens.length || c.obtained.length != c.tokens.length) return;
            res.seen = true;
            res.round = c.round;
            if (c.transitId == bytes32(0)) {
                _finish(b, spokeIndex, res, false);
                return;
            }
            (res.sold, res.obtained,) = _align(b.sources[spokeIndex + 1].index.tokens, c.tokens, c.sold, c.obtained);
            _freezeResult(b.sources[spokeIndex + 1], res);
            ++b.openResults;
        } else if (c.transitId == bytes32(0)) {
            return;
        }
        if (res.transitId != bytes32(0)) delete b.resultOf[spokeIndex][res.transitId];
        res.transitId = c.transitId;
        b.resultOf[spokeIndex][c.transitId] = c.resultId;
        _authenticateArrival(s, spokeIndex, c);
        _reconcileRecovery(s, spokeIndex, c);
        uint256 credited = b.credited[spokeIndex][c.transitId];
        if (credited != 0 && _fullyCredited(s, spokeIndex, c.transitId)) {
            _closeSpokeResult(s, w, spokeIndex, res, credited);
        }
    }

    function _authenticateArrival(
        CoreVaultState storage s,
        uint256 spokeIndex,
        SpokeIncomeTypes.CollectionResult memory result
    ) private {
        if (result.amountToArrive == 0) return;
        bytes32 key = CoreVaultLogic.hubBoundKey(s.mandate.spokes[spokeIndex].chainId, result.transitId);
        if (s.hubBound[key].listed == 0) {
            s.hubBound[key].listed = result.amountToArrive;
            s.hubBound[key].kind = TransferKind.Income;
        }
        uint256 room =
            s.hubBound[key].listed > s.hubBound[key].credited ? s.hubBound[key].listed - s.hubBound[key].credited : 0;
        uint256 credit = s.hubBound[key].pending < room ? s.hubBound[key].pending : room;
        if (credit == 0) return;
        s.hubBound[key].pending -= credit;
        s.hubBound[key].credited += credit;
        s.unmatchedArrivals -= credit;
        s.incomeBook.credited[spokeIndex][result.transitId] += credit;
        s.incomeBook.heldDollars += credit;
    }

    function _reconcileRecovery(
        CoreVaultState storage s,
        uint256 spokeIndex,
        SpokeIncomeTypes.CollectionResult memory result
    ) private {
        CoreVaultIncomeTypes.Book storage book = s.incomeBook;
        bytes32 transitId = result.transitId;
        uint256 recovered = book.recoveredIncome[spokeIndex][transitId];
        if (recovered == 0) return;
        bytes32 key = CoreVaultLogic.hubBoundKey(s.mandate.spokes[spokeIndex].chainId, transitId);
        if (s.hubBound[key].listed == 0 && result.amountToArrive != 0) {
            s.hubBound[key].listed = result.amountToArrive;
            s.hubBound[key].kind = TransferKind.Income;
        }
        uint256 listed = s.hubBound[key].listed;
        if (listed == 0) return;
        delete book.recoveredIncome[spokeIndex][transitId];
        book.recoveredDollars -= recovered;
        uint256 credited = recovered < listed ? recovered : listed;
        book.credited[spokeIndex][transitId] += credited;
        if (recovered > credited) {
            book.heldDollars -= recovered - credited;
            s.unmatchedArrivals += recovered - credited;
        }
    }

    function _freezeResult(CoreVaultIncomeTypes.Source storage source, CoreVaultIncomeTypes.SpokeResult storage result)
        private
    {
        uint256[] memory holders = result.sold;
        for (uint256 index; index < holders.length; ++index) {
            uint256 sold = holders[index];
            (uint256 holderSold,,) = _splitFee(source, source.index.tokens[index], sold, 0);
            result.totalSold.push(sold);
            result.feeSold.push(sold - holderSold);
            holders[index] = holderSold;
        }
        result.frozen = source.index.freeze(holders);
    }

    function _fullyCredited(CoreVaultState storage s, uint256 spokeIndex, bytes32 transitId)
        private
        view
        returns (bool)
    {
        bytes32 key = CoreVaultLogic.hubBoundKey(s.mandate.spokes[spokeIndex].chainId, transitId);
        return s.hubBound[key].listed != 0 && s.hubBound[key].credited >= s.hubBound[key].listed;
    }

    /// @dev Converts a spoke result with the `dollars` its Income transfer delivered on the Hub. D-41, DEC-166 item 2,
    ///      DEC-175: the bridge fee and the sale costs are the fund's, so each token's rate is the dollars credited times
    ///      its share of what the sale obtained, over the units sold (WP-10 plan item 5); the last token with a sale
    ///      takes the rounding remainder, so the shares add up to `dollars`.
    function _closeSpokeResult(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        CoreVaultIncomeTypes.SpokeResult storage res,
        uint256 dollars
    ) private {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        bytes32 transitId = res.transitId;
        delete b.credited[spokeIndex][transitId];
        b.heldDollars -= dollars;
        uint256[] memory obtained = res.obtained;
        uint256 n = obtained.length;
        uint256 total;
        uint256 last;
        for (uint256 i; i < n; ++i) {
            if (obtained[i] == 0) continue;
            total += obtained[i];
            last = i;
        }
        uint256[] memory shares = new uint256[](n);
        if (total != 0) {
            uint256 assigned;
            for (uint256 i; i < n; ++i) {
                shares[i] = Math.mulDiv(dollars, obtained[i], total);
                assigned += shares[i];
            }
            shares[last] += dollars - assigned;
        }
        _finish(b, spokeIndex, res, true);
        _finalizeResult(s, w, spokeIndex + 1, res, shares, dollars);
    }

    function _finalizeResult(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 source,
        CoreVaultIncomeTypes.SpokeResult storage res,
        uint256[] memory shares,
        uint256 dollars
    ) private {
        uint256 fee;
        for (uint256 index; index < shares.length; ++index) {
            uint256 feeDollars =
                res.totalSold[index] == 0 ? 0 : Math.mulDiv(shares[index], res.feeSold[index], res.totalSold[index]);
            fee += feeDollars;
            shares[index] -= feeDollars;
        }
        uint256 attributed = s.incomeBook.sources[source].index.finalizeFrozen(res.frozen, shares);
        s.incomeBook.heldDollars += attributed;
        (uint256 slice, uint16 sliceBps) = _payFee(s, w, fee);
        emit ICoreVaultIncome.IncomeCollectionClosed(source, res.transitId, dollars, attributed, fee, slice, sliceBps);
    }

    /// @dev Marks a result converted; it no longer holds its spoke's part of the current round.
    function _finish(
        CoreVaultIncomeTypes.Book storage b,
        uint256 spokeIndex,
        CoreVaultIncomeTypes.SpokeResult storage res,
        bool open
    ) private {
        res.closed = true;
        if (open) --b.openResults;
        if (res.round == b.round) b.pendingSpokes &= ~(uint256(1) << spokeIndex);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Conversion (DEC-161; D-40; DEC-128 item 4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Closes `source`'s interval at this collection's rate per token (`DollarIncomeIndex.collect`) and pays the
    ///      fee part in USDC. Per token, the units sold are shared between the holders' claim (`recognized`) and the
    ///      fee's (`feeUnits`) in proportion when the sale was partial, and the dollars follow the units (D-40: the fee is
    ///      one more owner at the same rate); units sold above both claims convert for nobody. The holders' dollars join
    ///      `heldDollars` as the index attributes them (rounded up, never above what was obtained); the fee goes out
    ///      (`_payFee`); the rest (rounding, units nobody claimed) stays out of every ledger, sweepable excess (DEC-080).
    function _convert(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 source,
        uint256[] memory sold,
        uint256[] memory dollars,
        bytes32 ref,
        uint256 total
    ) private {
        CoreVaultIncomeTypes.Source storage src = s.incomeBook.sources[source];
        address[] storage tokens = src.index.tokens;
        uint256 fee;
        uint256 holders;
        for (uint256 i; i < tokens.length; ++i) {
            uint256 feeDollars;
            (sold[i], dollars[i], feeDollars) = _splitFee(src, tokens[i], sold[i], dollars[i]);
            fee += feeDollars;
            holders += dollars[i];
        }
        uint256 attributed;
        if (_any(sold)) attributed = holders - src.index.collect(sold, dollars);
        s.incomeBook.heldDollars += attributed;
        (uint256 slice, uint16 sliceBps) = _payFee(s, w, fee);
        emit ICoreVaultIncome.IncomeCollectionClosed(source, ref, total, attributed, fee, slice, sliceBps);
    }

    /// @dev One token's sale shared between the holders and the fee: returns the holders' units and dollars and the
    ///      fee's dollars, and takes the fee's units off `feeUnits`. A token not sold converts nothing (its dollars, if
    ///      any, belong to nobody).
    function _splitFee(CoreVaultIncomeTypes.Source storage src, address token, uint256 sold, uint256 dollars)
        private
        returns (uint256 holdersSold, uint256 holdersDollars, uint256 feeDollars)
    {
        if (sold == 0) return (0, 0, 0);
        uint256 feeUnits = src.feeUnits[token];
        uint256 claim = src.index.token[token].recognized + feeUnits;
        uint256 feeSold = claim == 0 ? 0 : sold >= claim ? feeUnits : Math.mulDiv(sold, feeUnits, claim);
        if (feeSold == 0) return (sold, dollars, 0);
        src.feeUnits[token] = feeUnits - feeSold;
        feeDollars = Math.mulDiv(dollars, feeSold, sold);
        return (sold - feeSold, dollars - feeDollars, feeDollars);
    }

    /// @dev DEC-124 item 2, DEC-128 item 4: the performance fee is paid in USDC at the collection, the protocol slice to
    ///      the Protocol Recipient and the rest to the fund's ManagerFeeVault; a transfer that fails is owed (S-12).
    function _payFee(CoreVaultState storage s, CoreVaultWiring memory w, uint256 fee)
        private
        returns (uint256 slice, uint16 sliceBps)
    {
        if (fee == 0) return (0, 0);
        sliceBps = protocolSliceBps(w);
        slice = fee * sliceBps / BPS;
        CoreVaultLogic.payFee(s, w.usdc, w.protocolRecipient, slice);
        CoreVaultLogic.payFee(s, w.usdc, w.managerFeeVault, fee - slice);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev `a` and `b` (one entry per `tokens`) laid out in `sourceTokens`' order; a token outside the source is left
    ///      out. Returns the sum of the aligned `b`.
    function _align(address[] storage sourceTokens, address[] memory tokens, uint256[] memory a, uint256[] memory b)
        private
        view
        returns (uint256[] memory outA, uint256[] memory outB, uint256 sumB)
    {
        uint256 n = sourceTokens.length;
        outA = new uint256[](n);
        outB = new uint256[](n);
        for (uint256 i; i < tokens.length; ++i) {
            for (uint256 j; j < n; ++j) {
                if (sourceTokens[j] != tokens[i]) continue;
                outA[j] += a[i];
                outB[j] += b[i];
                sumB += b[i];
                break;
            }
        }
    }

    function _any(uint256[] memory values) private pure returns (bool) {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] != 0) return true;
        }
        return false;
    }
}
