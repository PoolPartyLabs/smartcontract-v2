// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DollarIncomeIndex
/// @notice Attributed Income per share in two indices (DEC-161 item 1): per income token, a token index of the open
///         interval (since the last collection that sold the token) that advances at recognition; and one cumulative
///         dollar index that advances only when a collection converts an interval's income, at that collection's rate
///         per token.
/// @dev Mechanism: `docs/engenharia/2026-10-01-checklist-pre-mainnet/10-INDICE-EM-DOLAR-NA-HUB.md` section 2 of the
///      spec repository.
///      - DEC-014, DEC-138: income belongs to whoever held shares when it was recognized, and collecting it later does
///        not change the beneficiary. Shares minted in the middle of an interval take nothing of what the interval
///        earned before them (`onMint`); burned shares keep what they earned until the burn (`onBurn`); a sale that
///        leaves part of an interval unsold keeps that part with the same holders (`collect`).
///      - DEC-117 item 2, DEC-152: one token index per income token, no price in the attribution. The caller
///        recognizes the income net of the performance fee (DEC-117 item 3); the fee is not this library's concern.
///      - DEC-124, DEC-161: the conversion to dollars happens at collection; Income Withdrawal pays dollars (`take`).
///      - DEC-161 item 2: the rate of every token converted in every collection is stored. A holder who moved shares
///        during an interval carries a per-token adjustment for it, converted at the rate of the collection that
///        closed that interval, possibly several collections before the holder comes back (doc 10 section 3).
///        DEC-161 item 3: never paid by average.
///      - Holders who did not move shares during an interval are served by the dollar index alone and read no rate.
///      Intervals are counted per token: a collection that does not sell a token (a refused or failed sale) leaves that
///      token's interval open, so its income, index and adjustments wait for the next sale unchanged. `State.interval`
///      counts collections; `IncomeToken.interval` counts the collections that converted the token.
///      Source-agnostic: the caller keeps one `State` per source class (Hub income, spoke income; doc 10 section 6)
///      and tags it with `source` for the events. DEC-145 (active shares for spoke income) is layered on top by the
///      caller (WP-14).
///      Rounding is always against the holder: floor on every credit, ceiling on every debit, the division remainder
///      of the open interval dropped at collection. The holders together are never owed more tokens than were
///      recognized in the open interval, nor more dollars than the collections obtained (`dollarsAttributed`).
///      Usage per balance change of `holder` (mint, every form of burn): `settle(holder, sharesBefore)`, then
///      `onMint(holder, minted)` or `onBurn(holder, burned)`, then the balance change; `settle` again before `take`.
///      Bounds: amounts per recognition up to `MAX_STEP`; overflow is unreachable with share supplies of whole shares
///      and real token amounts (the open index stays near `income per share x 2^128`); at most `MAX_SETTLE_STEPS`
///      stored-rate conversions per `settle`.
library DollarIncomeIndex {
    using SafeCast for uint256;
    using SafeCast for int256;

    /// @notice Index scale: 2^128.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Maximum number of income tokens per source, bounding every per-holder loop.
    uint256 internal constant MAX_TOKENS = 16;

    /// @notice Largest amount one recognition accepts (arithmetic bound, as `IncomeAccumulator.MAX_STEP`).
    uint256 internal constant MAX_STEP = type(uint128).max;

    /// @notice Most token claim captures, payments, merges and carried-rate conversions in one settlement, shared
    ///         across active and activated waiting lots and, in the Core Vault, all income sources (DEC-145, DEC-161).
    uint256 internal constant MAX_SETTLE_STEPS = 64;

    /// @notice DEC-145: maximum FIFO entries activated per accepted report.
    uint256 internal constant MAX_ACTIVATIONS = 32;

    /// @notice Open-interval state of one income token.
    /// @param registered Whether the token is in the closed list.
    /// @param interval Number of the token's open interval: how many collections converted the token so far.
    /// @param openIndex Token units per share in the open interval, in Q128: recognized since the interval opened,
    ///        plus the unsold part carried from a partial sale.
    /// @param remainder Division remainder carried between recognitions of the open interval (numerator units).
    /// @param recognized Token units the holders can claim in the open interval (carried-in units included).
    struct IncomeToken {
        bool registered;
        uint64 interval;
        uint256 openIndex;
        uint256 remainder;
        uint256 recognized;
    }

    /// @notice Running totals of one `settle` (memory only).
    /// @param credit Dollars converted from positive adjustments.
    /// @param debit Dollars converted from negative adjustments.
    /// @param budget Conversion steps left in the call.
    /// @param remaining Whether any adjustment is left.
    /// @param complete Whether every adjustment reached its token's open interval.
    struct Settlement {
        uint256 credit;
        uint256 debit;
        uint256 budget;
        bool remaining;
        bool complete;
    }

    struct Work {
        uint256 budget;
    }

    /// @notice One holder's adjustment on one token.
    /// @param amount Signed token units: minus what shares minted during the interval would have earned before the
    ///        mint, plus what shares burned during it earned.
    /// @param interval Token interval the amount belongs to.
    struct Adjustment {
        int192 amount;
        uint64 interval;
    }

    /// @notice One holder's state.
    /// @param dollars Dollars settled and not yet taken.
    /// @param mark Value of the dollar index at the holder's last settlement.
    /// @param interval Collection count at the holder's last complete settlement (every adjustment then belongs to
    ///        its token's open interval).
    /// @param adjusted Whether any adjustment may be non-zero (skips the per-token reads otherwise).
    /// @param adjustment Per-token adjustment.
    struct Holder {
        uint256 dollars;
        uint256 mark;
        uint64 interval;
        bool adjusted;
        mapping(address token => Adjustment) adjustment;
        uint64 captured;
        uint64 paid;
        mapping(uint64 collection => uint256[]) claims;
        uint256 waitingShares;
        uint256 waitingEntry;
        bool capturePrepared;
        mapping(address token => Adjustment) captureAdjustment;
        uint256 paymentCursor;
        uint256 settlementCredit;
        uint256 settlementDebit;
    }

    struct Entry {
        uint256 timestamp;
        uint256 shares;
        bool activated;
        uint256 mark;
        uint64 captured;
        uint256[] indices;
        uint64[] intervals;
    }

    struct FrozenCollection {
        uint256[] indices;
        uint256[] fractions;
        uint64[] intervals;
        uint256[] sold;
        uint256[] recognized;
        uint256[] rates;
        bool finalized;
    }

    /// @notice Index storage of one source class.
    /// @param source Caller-chosen tag carried by the events (e.g. 1 = Hub income, 2 = spoke income).
    /// @param interval Number of collections so far; collection `n` closes collection interval `n`.
    /// @param dollarIndex Dollar units per share converted by every collection so far, in Q128; never decreases.
    /// @param rate Per closed token interval and token: dollar units per claimed token unit, in Q128.
    /// @param carry Per closed token interval and token: the fraction of every claim kept for the next interval after
    ///        a partial sale, `(recognized - sold) / recognized` in Q128, rounded down; zero after a full sale.
    /// @param dollarsObtained Dollars credited by every collection.
    /// @param dollarsAttributed Dollars attributed to holders, rounded up per token and collection; at most
    ///        `dollarsObtained`. What holders can still take is at most `dollarsAttributed - dollarsTaken`; the gap is
    ///        rounding dust that stays in the vault. `dollarsObtained - dollarsAttributed` is the unattributed total.
    /// @param dollarsTaken Dollars taken by holders.
    struct State {
        uint8 source;
        uint64 interval;
        uint256 dollarIndex;
        address[] tokens;
        mapping(address token => IncomeToken) token;
        mapping(uint256 interval => mapping(address token => uint256)) rate;
        mapping(uint256 interval => mapping(address token => uint256)) carry;
        mapping(address holder => Holder) holders;
        uint256 dollarsObtained;
        uint256 dollarsAttributed;
        uint256 dollarsTaken;
        uint64 frozenCount;
        uint256 deferredIndex;
        mapping(uint64 collection => FrozenCollection) frozen;
        uint256 waitingTotal;
        uint256 entryCount;
        uint256 activationCursor;
        uint64 reportTimestamp;
        mapping(uint256 entry => Entry) entries;
        mapping(address holder => Holder) activating;
        mapping(address holder => bool) activationPrepared;
        mapping(address holder => uint64) activationMerged;
        mapping(address holder => uint256) activationMergeToken;
        mapping(address holder => bool) activationMerging;
    }

    /// @notice DEC-145: merge new shares into the holder's single waiting lot at the latest deposit timestamp.
    function wait(State storage s, address holder, uint256 shares, uint256 timestamp) internal {
        Holder storage account = s.holders[holder];
        uint256 combined = account.waitingShares + shares;
        if (account.waitingShares != 0) s.entries[account.waitingEntry].shares -= account.waitingShares;
        uint256 entryId = s.entryCount;
        if (entryId == 0 || s.entries[entryId].timestamp != timestamp || s.entries[entryId].activated) {
            entryId = ++s.entryCount;
            s.entries[entryId].timestamp = timestamp;
        }
        s.entries[entryId].shares += combined;
        account.waitingEntry = entryId;
        account.waitingShares = combined;
        s.waitingTotal += shares;
    }

    /// @notice DEC-145: activate at most 32 FIFO entries eligible for the interval beginning at the previous report.
    function activate(State storage s, uint64 timestamp) internal {
        uint256 cursor = s.activationCursor;
        uint256 budget = MAX_ACTIVATIONS;
        while (cursor < s.entryCount && budget != 0) {
            Entry storage entry = s.entries[cursor + 1];
            if (entry.timestamp > s.reportTimestamp) break;
            entry.activated = true;
            entry.mark = s.dollarIndex - s.deferredIndex;
            entry.captured = s.frozenCount;
            s.waitingTotal -= entry.shares;
            for (uint256 index; index < s.tokens.length; ++index) {
                IncomeToken storage token = s.token[s.tokens[index]];
                entry.indices.push(token.openIndex);
                entry.intervals.push(token.interval);
                token.remainder = 0;
            }
            ++cursor;
            --budget;
        }
        s.activationCursor = cursor;
        s.reportTimestamp = timestamp;
    }

    /// @notice DEC-145: burn waiting shares first; return the remainder to burn from active shares.
    function burnWaiting(State storage s, address holder, uint256 burned) internal returns (uint256 activeBurn) {
        Holder storage account = s.holders[holder];
        uint256 waitingBurn = Math.min(burned, account.waitingShares);
        if (waitingBurn != 0) {
            account.waitingShares -= waitingBurn;
            s.entries[account.waitingEntry].shares -= waitingBurn;
            s.waitingTotal -= waitingBurn;
        }
        return burned - waitingBurn;
    }

    /// @notice An income token was added to the closed list.
    event IncomeTokenAdded(uint8 indexed source, address indexed token);

    /// @notice `amount` of `token` entered the open interval's index, now `openIndex`.
    event IntervalIncomeRecognized(uint8 indexed source, address indexed token, uint256 amount, uint256 openIndex);

    /// @notice A recognition was skipped (unknown token, amount above `MAX_STEP`, index overflow); never reverted.
    event IntervalIncomeSkipped(uint8 indexed source, address indexed token, uint256 amount);

    /// @notice Token interval `interval` of `token` closed: `sold` units for `obtained` dollars, at `rate` (Q128 dollar
    ///         units per claimed token unit); `carried` unsold units stay with their holders in the next interval.
    event IntervalIncomeConverted(
        uint8 indexed source,
        uint256 indexed interval,
        address indexed token,
        uint256 sold,
        uint256 obtained,
        uint256 rate,
        uint256 carried
    );

    /// @notice The collection did not sell `token`: its interval `interval` stays open with `recognized` units.
    event IntervalIncomeUnsold(
        uint8 indexed source, uint256 indexed interval, address indexed token, uint256 recognized
    );

    /// @notice Collection `interval` closed: the dollar index is now `dollarIndex`; of `obtained` dollars,
    ///         `unattributed` belong to no holder (sold above what holders were recognized, or rounding).
    event IncomeIntervalClosed(
        uint8 indexed source, uint256 indexed interval, uint256 dollarIndex, uint256 obtained, uint256 unattributed
    );

    /// @notice Zero token address.
    error IncomeTokenZero();

    /// @notice The closed list is full.
    error IncomeTokenListFull();

    /// @notice The token is already in the closed list.
    error IncomeTokenAlreadyAdded(address token);

    /// @notice `sold` and `obtained` must have one entry per income token, in list order.
    error CollectionLengthMismatch();

    /// @notice A collection reported dollars obtained for `token` without selling any of it.
    error InconsistentCollection(address token);

    /// @notice `onMint`/`onBurn`/`take` ran without a complete `settle` of the holder in the open interval.
    error HolderNotSettled(address holder);

    /// @notice Adds `token` to the closed list. Call at construction, from the Mandate's tokens.
    function registerToken(State storage s, address token) internal {
        if (token == address(0)) revert IncomeTokenZero();
        IncomeToken storage t = s.token[token];
        if (t.registered) revert IncomeTokenAlreadyAdded(token);
        if (s.tokens.length >= MAX_TOKENS) revert IncomeTokenListFull();
        t.registered = true;
        s.tokens.push(token);
        emit IncomeTokenAdded(s.source, token);
    }

    /// @notice The closed list of income tokens; `collect` takes its arrays in this order.
    function incomeTokens(State storage s) internal view returns (address[] memory) {
        return s.tokens;
    }

    /// @notice Whether `token` is in the closed list.
    function isRegistered(State storage s, address token) internal view returns (bool) {
        return s.token[token].registered;
    }

    /// @notice Adds `amount` of `token` to the open interval's index for `totalShares`. Never reverts.
    /// @dev DEC-138: called at recognition (Hub income at every mint and burn, spoke income per accepted report),
    ///      before the holder's settlement. `openIndex += (amount * 2^128 + remainder) / totalShares`, with the
    ///      remainder carried (the arithmetic of `IncomeAccumulator.distribute`).
    /// @return accepted False when nothing entered the index: no shares (`totalShares == 0`, the caller decides),
    ///         or a skip with `IntervalIncomeSkipped` (unknown token, amount above `MAX_STEP`, index overflow).
    function recognize(State storage s, address token, uint256 amount, uint256 totalShares)
        internal
        returns (bool accepted)
    {
        IncomeToken storage t = s.token[token];
        if (t.registered && amount <= MAX_STEP) {
            if (amount == 0) return true;
            if (totalShares == 0) return false;
            (bool ok, uint256 index, uint256 remainder) = _advance(t.openIndex, t.remainder, amount, totalShares);
            if (ok) {
                t.openIndex = index;
                t.remainder = remainder;
                t.recognized += amount;
                emit IntervalIncomeRecognized(s.source, token, amount, index);
                return true;
            }
        }
        emit IntervalIncomeSkipped(s.source, token, amount);
        return false;
    }

    /// @notice Closes the collection interval: converts the open interval of every token the collection sold, at this
    ///         collection's rate per token.
    /// @dev DEC-161, doc 10 section 2. Per token (arrays in `incomeTokens` order), with `R` the units the holders can
    ///      claim in the token's open interval:
    ///      - `sold == 0` (a refused or failed sale): the token's interval stays open, with its index, its holders'
    ///        adjustments and its `R`; nothing is stored.
    ///      - `sold >= R`: the interval closes at `rate = obtained / sold`, stored for it, `dollarIndex += rate x
    ///        openIndex`, and the next interval opens empty. The dollars for the units above `R` (the fee's units if the
    ///        caller passes the whole sale; income recognized at zero supply) come back in `unattributed`.
    ///      - `0 < sold < R` (a partial sale): every claim on the interval converts the same fraction `sold / R` at the
    ///        sale price (`rate = obtained / R`), and the rest of each claim stays with its holder in the next
    ///        interval (DEC-014: collecting later does not change the beneficiary; DEC-045: a holder who burned every
    ///        share keeps the unsold part of what they earned). The next interval opens with `R - sold` units at
    ///        `openIndex x (R - sold) / R`; the fraction is stored as `carry` and carries the adjustments when their
    ///        holders settle.
    /// @param sold Token units sold for the holders, per token.
    /// @param obtained Dollars credited for them, per token (for a dollar token not sold, `sold == obtained`); zero
    ///        when `sold` is zero, or the collection reverts with `InconsistentCollection`.
    /// @return unattributed Dollars of this collection attributed to no holder (at most `sum(obtained)`).
    function collect(State storage s, uint256[] memory sold, uint256[] memory obtained)
        internal
        returns (uint256 unattributed)
    {
        uint256 length = s.tokens.length;
        if (sold.length != length || obtained.length != length) revert CollectionLengthMismatch();
        uint256 indexIncrement;
        uint256 attributed;
        uint256 obtainedTotal;
        for (uint256 i; i < length; ++i) {
            (uint256 increment, uint256 share) = _convert(s, s.tokens[i], sold[i], obtained[i]);
            indexIncrement += increment;
            attributed += share;
            obtainedTotal += obtained[i];
        }
        uint64 closing = s.interval;
        uint256 dollarIndex = s.dollarIndex + indexIncrement;
        s.dollarIndex = dollarIndex;
        s.interval = closing + 1;
        s.dollarsObtained += obtainedTotal;
        s.dollarsAttributed += attributed;
        unattributed = obtainedTotal - attributed;
        emit IncomeIntervalClosed(s.source, closing, dollarIndex, obtainedTotal, unattributed);
    }

    function freeze(State storage s, uint256[] memory sold) internal returns (uint64 id) {
        id = ++s.frozenCount;
        FrozenCollection storage frozen = s.frozen[id];
        for (uint256 index; index < s.tokens.length; ++index) {
            IncomeToken storage token = s.token[s.tokens[index]];
            uint256 recognized = token.recognized;
            uint256 claimed = sold[index] < recognized ? sold[index] : recognized;
            uint256 fraction = recognized == 0 ? 0 : Math.mulDiv(claimed, Q128, recognized);
            uint256 sealedIndex = Math.mulDiv(token.openIndex, fraction, Q128);
            frozen.indices.push(sealedIndex);
            frozen.fractions.push(fraction);
            frozen.intervals.push(token.interval);
            frozen.sold.push(sold[index]);
            frozen.recognized.push(claimed);
            if (claimed == 0) continue;
            uint256 carried = recognized - claimed;
            s.carry[token.interval][s.tokens[index]] = Math.mulDiv(carried, Q128, recognized);
            token.openIndex = Math.mulDiv(token.openIndex, carried, recognized);
            token.recognized = carried;
            token.remainder = 0;
            ++token.interval;
        }
        ++s.interval;
    }

    function finalizeFrozen(State storage s, uint64 id, uint256[] memory obtained)
        internal
        returns (uint256 attributed)
    {
        FrozenCollection storage frozen = s.frozen[id];
        uint256 increment;
        uint256 total;
        for (uint256 index; index < obtained.length; ++index) {
            uint256 rate = frozen.sold[index] == 0 ? 0 : Math.mulDiv(obtained[index], Q128, frozen.sold[index]);
            frozen.rates.push(rate);
            increment += Math.mulDiv(frozen.indices[index], rate, Q128);
            total += obtained[index];
            attributed += Math.mulDiv(frozen.recognized[index], rate, Q128, Math.Rounding.Ceil);
        }
        frozen.finalized = true;
        s.dollarIndex += increment;
        s.deferredIndex += increment;
        s.dollarsObtained += total;
        s.dollarsAttributed += attributed;
        emit IncomeIntervalClosed(s.source, id, s.dollarIndex, total, total - attributed);
    }

    function _frozenClaim(
        State storage s,
        Holder storage holder,
        FrozenCollection storage frozen,
        uint256 shares,
        uint256 index
    ) private view returns (uint256 claim) {
        claim = Math.mulDiv(shares, frozen.indices[index], Q128);
        address token = s.tokens[index];
        Adjustment storage adjustment = holder.adjustment[token];
        int256 amount = adjustment.amount;
        uint64 closing = frozen.intervals[index];
        if (amount == 0 || adjustment.interval > closing || frozen.fractions[index] == 0) return claim;
        if (adjustment.interval != closing) {
            (, amount,) = _carryForward(s, token, amount, adjustment.interval, closing, type(uint256).max);
        }
        uint256 correction = Math.mulDiv(
            _abs(amount), frozen.fractions[index], Q128, amount < 0 ? Math.Rounding.Ceil : Math.Rounding.Floor
        );
        if (amount >= 0) return claim + correction;
        return claim > correction ? claim - correction : 0;
    }

    function _settleFrozen(State storage s, Holder storage holder, uint256 shares, Work memory work)
        private
        returns (bool complete)
    {
        if (holder.captured < s.frozenCount && !holder.capturePrepared) {
            for (uint256 index; index < s.tokens.length; ++index) {
                address token = s.tokens[index];
                holder.captureAdjustment[token] = holder.adjustment[token];
            }
            holder.capturePrepared = true;
        }
        while (holder.captured < s.frozenCount && work.budget != 0) {
            uint64 id = holder.captured + 1;
            for (uint256 index = holder.claims[id].length; index < s.tokens.length; ++index) {
                if (!_captureToken(s, holder, id, shares, index, work)) return false;
            }
            if (s.tokens.length == 0) --work.budget;
            holder.captured = id;
        }
        complete = holder.captured == s.frozenCount;
        while (holder.paid < holder.captured && work.budget != 0) {
            uint64 id = holder.paid + 1;
            FrozenCollection storage frozen = s.frozen[id];
            if (!frozen.finalized) break;
            for (uint256 index = holder.paymentCursor; index < s.tokens.length; ++index) {
                if (work.budget == 0) return false;
                --work.budget;
                holder.dollars += Math.mulDiv(holder.claims[id][index], frozen.rates[index], Q128);
                holder.claims[id][index] = 0;
                holder.paymentCursor = index + 1;
            }
            delete holder.claims[id];
            if (s.tokens.length == 0) --work.budget;
            holder.paymentCursor = 0;
            holder.paid = id;
        }
        if (holder.paid < holder.captured && s.frozen[holder.paid + 1].finalized) complete = false;
    }

    function _captureToken(
        State storage s,
        Holder storage holder,
        uint64 id,
        uint256 shares,
        uint256 index,
        Work memory work
    ) private returns (bool) {
        address token = s.tokens[index];
        Adjustment storage adjustment = holder.captureAdjustment[token];
        FrozenCollection storage frozen = s.frozen[id];
        uint64 closing = frozen.intervals[index];
        if (adjustment.amount != 0 && adjustment.interval < closing) {
            uint64 from = adjustment.interval;
            (, int256 rest, uint64 reached) = _carryForward(s, token, adjustment.amount, from, closing, work.budget);
            work.budget -= reached - from;
            adjustment.amount = rest.toInt192();
            adjustment.interval = reached;
            if (rest != 0 && reached < closing) return false;
        }
        if (work.budget == 0) return false;
        --work.budget;
        uint256 claim = Math.mulDiv(shares, frozen.indices[index], Q128);
        int256 amount = adjustment.amount;
        if (amount != 0 && adjustment.interval <= closing) {
            uint256 correction = Math.mulDiv(
                _abs(amount), frozen.fractions[index], Q128, amount < 0 ? Math.Rounding.Ceil : Math.Rounding.Floor
            );
            claim = amount >= 0 ? claim + correction : claim > correction ? claim - correction : 0;
        }
        holder.claims[id].push(claim);
        return true;
    }

    /// @notice Brings `holder` to the open interval: converts every adjustment of a closed token interval at the rate
    ///         stored for it, then adds `shares * (dollarIndex - mark)`.
    /// @dev DEC-014, DEC-161. Call before every change to the holder's balance, with the balance BEFORE the change,
    ///      and before `take`. A total below zero can only come from rounding (every holder's exact claim is
    ///      non-negative) and settles at zero.
    ///      After a partial sale the unsold part of an adjustment is carried into the next token interval and
    ///      converted there in turn, until a full sale or the open interval: one step per token interval crossed.
    ///      At most `MAX_SETTLE_STEPS` steps run per call; when they run out, each unfinished adjustment keeps the
    ///      interval it reached and the call returns false. The hooks and `take` revert until a later `settle`
    ///      completes, so the caller must offer a way to call it again; progress is kept between calls.
    /// @return settled Whether every adjustment reached its token's open interval (the hooks and `take` may run).
    function settle(State storage s, address holder, uint256 shares) internal returns (bool settled) {
        Work memory work = Work(MAX_SETTLE_STEPS);
        return settle(s, holder, shares, work);
    }

    /// @notice DEC-145, DEC-161: shared token-operation budget across sources and both holder lots.
    function settle(State storage s, address holder, uint256 shares, Work memory work) internal returns (bool settled) {
        Holder storage h = s.holders[holder];
        uint256 waiting = h.waitingShares;
        if (!s.activationMerging[holder] && !_settleHolder(s, h, shares - waiting, work)) return false;
        if (waiting == 0 || !s.entries[h.waitingEntry].activated) return true;
        Holder storage activation = s.activating[holder];
        if (!s.activationPrepared[holder]) {
            Entry storage entry = s.entries[h.waitingEntry];
            activation.mark = entry.mark;
            activation.captured = entry.captured;
            activation.paid = entry.captured;
            for (uint256 index; index < s.tokens.length; ++index) {
                Adjustment storage adjustment = activation.adjustment[s.tokens[index]];
                adjustment.amount =
                    (-Math.mulDiv(waiting, entry.indices[index], Q128, Math.Rounding.Ceil).toInt256()).toInt192();
                adjustment.interval = entry.intervals[index];
            }
            activation.adjusted = true;
            s.activationPrepared[holder] = true;
        }
        if (!s.activationMerging[holder]) {
            if (!_settleHolder(s, activation, waiting, work)) return false;
            s.activationMerging[holder] = true;
        }
        uint64 merged = s.activationMerged[holder];
        if (merged < activation.paid) merged = activation.paid;
        while (merged < activation.captured) {
            uint64 id = merged + 1;
            for (uint256 index = s.activationMergeToken[holder]; index < s.tokens.length; ++index) {
                if (work.budget == 0) return false;
                --work.budget;
                h.claims[id][index] += activation.claims[id][index];
                activation.claims[id][index] = 0;
                s.activationMergeToken[holder] = index + 1;
            }
            s.activationMergeToken[holder] = 0;
            s.activationMerged[holder] = ++merged;
        }
        s.activationMerged[holder] = merged;
        if (merged < activation.captured) return false;
        h.dollars += activation.dollars;
        for (uint256 index; index < s.tokens.length; ++index) {
            address token = s.tokens[index];
            Adjustment storage adjustment = h.adjustment[token];
            if (activation.adjustment[token].amount != 0) adjustment.interval = activation.adjustment[token].interval;
            adjustment.amount = (int256(adjustment.amount) + activation.adjustment[token].amount).toInt192();
            delete activation.adjustment[token];
        }
        h.adjusted = true;
        h.capturePrepared = false;
        h.waitingShares = 0;
        h.waitingEntry = 0;
        delete s.activating[holder];
        delete s.activationPrepared[holder];
        delete s.activationMerged[holder];
        delete s.activationMergeToken[holder];
        delete s.activationMerging[holder];
        return _settleHolder(s, h, shares, work);
    }

    function _settleHolder(State storage s, Holder storage h, uint256 shares, Work memory work)
        private
        returns (bool settled)
    {
        if (!_settleFrozen(s, h, shares, work)) return false;
        uint256 dollars = h.dollars + _indexed(s, h, shares);
        settled = true;
        if (h.adjusted && h.interval != s.interval) {
            Settlement memory run = Settlement(0, 0, work.budget, false, true);
            address[] storage tokens = s.tokens;
            uint256 length = tokens.length;
            for (uint256 i; i < length; ++i) {
                _settleAdjustment(s, h, tokens[i], run);
            }
            h.adjusted = run.remaining;
            settled = run.complete;
            work.budget = run.budget;
            h.settlementCredit += run.credit;
            h.settlementDebit += run.debit;
        }
        if (settled) {
            dollars += h.settlementCredit;
            dollars = dollars > h.settlementDebit ? dollars - h.settlementDebit : 0;
            h.settlementCredit = 0;
            h.settlementDebit = 0;
            h.interval = s.interval;
        }
        h.mark = s.dollarIndex - s.deferredIndex;
        h.dollars = dollars;
    }

    /// @notice Shares minted to `holder` take nothing of what the open interval earned before them.
    /// @dev DEC-014, doc 10 section 2: `adjustment -= minted * openIndex` per token, rounded up. Requires `settle` in
    ///      the open interval first.
    function onMint(State storage s, address holder, uint256 minted) internal {
        _adjust(s, holder, minted, true);
    }

    /// @notice Shares burned by `holder` keep what they earned in the open interval until the burn.
    /// @dev DEC-014, DEC-045, doc 10 section 2: `adjustment += burned * openIndex` per token, rounded down. Requires
    ///      `settle` in the open interval first.
    function onBurn(State storage s, address holder, uint256 burned) internal {
        _adjust(s, holder, burned, false);
    }

    /// @notice Removes up to `maxDollars` from `holder`'s settled dollars and returns the amount removed.
    /// @dev Takes only settled dollars: requires a complete `settle` in the open interval first (until then the
    ///      settled dollars may still owe a debit). The caller transfers the amount.
    function take(State storage s, address holder, uint256 maxDollars) internal returns (uint256 dollars) {
        Holder storage h = s.holders[holder];
        _requireSettled(s, h, holder);
        uint256 settled = h.dollars;
        dollars = settled < maxDollars ? settled : maxDollars;
        if (dollars == 0) return 0;
        h.dollars = settled - dollars;
        s.dollarsTaken += dollars;
    }

    /// @notice Dollars `holder` is owed now for a balance of `shares` (settled plus pending), without settling.
    /// @dev Walks every carried adjustment to the open interval, with no step bound (a view for off-chain reads).
    function owedDollars(State storage s, address holder, uint256 shares) internal view returns (uint256 dollars) {
        Holder storage h = s.holders[holder];
        dollars = _owedHolder(s, h, shares - h.waitingShares);
        if (h.waitingShares == 0 || !s.entries[h.waitingEntry].activated) return dollars;
        if (s.activationPrepared[holder]) return dollars + _owedHolder(s, s.activating[holder], h.waitingShares);
        return dollars + _entryDollars(s, s.entries[h.waitingEntry], h.waitingShares);
    }

    function _entryDollars(State storage s, Entry storage entry, uint256 shares)
        private
        view
        returns (uint256 dollars)
    {
        dollars = Math.mulDiv(shares, s.dollarIndex - s.deferredIndex - entry.mark, Q128);
        uint256 debit;
        for (uint256 index; index < s.tokens.length; ++index) {
            address token = s.tokens[index];
            int256 amount = -Math.mulDiv(shares, entry.indices[index], Q128, Math.Rounding.Ceil).toInt256();
            (uint256 converted,,) =
                _carryForward(s, token, amount, entry.intervals[index], s.token[token].interval, type(uint256).max);
            debit += converted;
        }
        dollars = dollars > debit ? dollars - debit : 0;
        for (uint64 id = entry.captured + 1; id <= s.frozenCount; ++id) {
            FrozenCollection storage frozen = s.frozen[id];
            if (!frozen.finalized) break;
            for (uint256 index; index < s.tokens.length; ++index) {
                int256 amount = -Math.mulDiv(shares, entry.indices[index], Q128, Math.Rounding.Ceil).toInt256();
                (, amount,) = _carryForward(
                    s, s.tokens[index], amount, entry.intervals[index], frozen.intervals[index], type(uint256).max
                );
                uint256 claim = Math.mulDiv(shares, frozen.indices[index], Q128);
                uint256 correction = Math.mulDiv(_abs(amount), frozen.fractions[index], Q128, Math.Rounding.Ceil);
                claim = claim > correction ? claim - correction : 0;
                dollars += Math.mulDiv(claim, frozen.rates[index], Q128);
            }
        }
    }

    function _owedHolder(State storage s, Holder storage h, uint256 shares) private view returns (uint256 dollars) {
        dollars = h.dollars + h.settlementCredit + _indexed(s, h, shares);
        for (uint64 id = h.paid + 1; id <= s.frozenCount; ++id) {
            FrozenCollection storage frozen = s.frozen[id];
            if (!frozen.finalized) break;
            for (uint256 index; index < s.tokens.length; ++index) {
                uint256 claim = id <= h.captured ? h.claims[id][index] : _frozenClaim(s, h, frozen, shares, index);
                dollars += Math.mulDiv(claim, frozen.rates[index], Q128);
            }
        }
        uint256 debit = h.settlementDebit;
        if (!h.adjusted || h.interval == s.interval) return dollars > debit ? dollars - debit : 0;
        address[] storage tokens = s.tokens;
        uint256 length = tokens.length;
        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            Adjustment storage a = h.adjustment[token];
            int256 amount = a.amount;
            uint64 open = s.token[token].interval;
            if (amount == 0 || a.interval == open) continue;
            (uint256 converted,,) = _carryForward(s, token, amount, a.interval, open, type(uint256).max);
            if (amount > 0) dollars += converted;
            else debit += converted;
        }
        dollars = dollars > debit ? dollars - debit : 0;
    }

    /// @notice Units of `token` `holder` is owed in the open interval (not yet converted) for a balance of `shares`.
    function tokenOwed(State storage s, address holder, uint256 shares, address token) internal view returns (uint256) {
        Holder storage account = s.holders[holder];
        uint256 owed = _tokenOwed(s, account, shares - account.waitingShares, token);
        if (account.waitingShares == 0 || !s.entries[account.waitingEntry].activated) return owed;
        if (s.activationPrepared[holder]) {
            return owed + _tokenOwed(s, s.activating[holder], account.waitingShares, token);
        }
        Entry storage entry = s.entries[account.waitingEntry];
        for (uint256 index; index < s.tokens.length; ++index) {
            if (s.tokens[index] != token) continue;
            int256 amount =
                -Math.mulDiv(account.waitingShares, entry.indices[index], Q128, Math.Rounding.Ceil).toInt256();
            (, amount,) =
                _carryForward(s, token, amount, entry.intervals[index], s.token[token].interval, type(uint256).max);
            uint256 base = Math.mulDiv(account.waitingShares, s.token[token].openIndex, Q128);
            uint256 debit = _abs(amount);
            return owed + (base > debit ? base - debit : 0);
        }
        return owed;
    }

    function _tokenOwed(State storage s, Holder storage holder, uint256 shares, address token)
        private
        view
        returns (uint256)
    {
        IncomeToken storage t = s.token[token];
        uint256 base = Math.mulDiv(shares, t.openIndex, Q128);
        Adjustment storage a = holder.adjustment[token];
        int256 amount = a.amount;
        uint64 open = t.interval;
        // An adjustment of a closed interval is already dollars (pending in `owedDollars`) but for its carried part.
        if (amount != 0 && a.interval != open) {
            (, amount,) = _carryForward(s, token, amount, a.interval, open, type(uint256).max);
        }
        uint256 magnitude = _abs(amount);
        if (amount >= 0) return base + magnitude;
        return base > magnitude ? base - magnitude : 0;
    }

    /// @dev Dollars of the dollar index since `h`'s mark for `shares`.
    function _indexed(State storage s, Holder storage h, uint256 shares) private view returns (uint256) {
        uint256 mark = h.mark;
        uint256 index = s.dollarIndex - s.deferredIndex;
        if (shares == 0 || index == mark) return 0;
        return Math.mulDiv(shares, index - mark, Q128);
    }

    /// @dev Brings `h`'s adjustment on `token` toward the token's open interval within `run.budget` steps (see
    ///      `settle`), adding the dollars converted to `run` and recording whether an adjustment is left and whether it
    ///      is still short of the open interval.
    function _settleAdjustment(State storage s, Holder storage h, address token, Settlement memory run) private {
        Adjustment storage a = h.adjustment[token];
        int256 amount = a.amount;
        if (amount == 0) return;
        uint64 from = a.interval;
        uint64 open = s.token[token].interval;
        if (from != open) {
            (uint256 converted, int256 rest, uint64 reached) = _carryForward(s, token, amount, from, open, run.budget);
            run.budget -= reached - from;
            if (amount > 0) run.credit += converted;
            else run.debit += converted;
            if (rest == 0) {
                delete h.adjustment[token];
                return;
            }
            if (reached != from) {
                a.amount = rest.toInt192();
                a.interval = reached;
            }
            if (reached != open) run.complete = false;
        }
        run.remaining = true;
    }

    /// @dev Converts `amount` of `token`, an adjustment of the closed token interval `from`, at the rate stored for
    ///      `from`, then carries its unsold part into the next interval and converts it there, until a full sale
    ///      (`carry == 0`), the open interval `open`, or `budget` steps. Returns the dollars converted (a credit when
    ///      `amount > 0`, a debit otherwise), the adjustment left and the interval it belongs to. Rounded against the
    ///      holder: a credit and its carry floor; a debit and its carry ceil (the carry at `carry + 1`, as the stored
    ///      fraction is rounded down).
    function _carryForward(State storage s, address token, int256 amount, uint64 from, uint64 open, uint256 budget)
        private
        view
        returns (uint256 dollars, int256 left, uint64 reached)
    {
        bool credit = amount > 0;
        uint256 magnitude = _abs(amount);
        reached = from;
        while (magnitude != 0 && reached != open && budget != 0) {
            uint256 rate = s.rate[reached][token];
            uint256 carry = s.carry[reached][token];
            if (credit) {
                dollars += Math.mulDiv(magnitude, rate, Q128);
                magnitude = carry == 0 ? 0 : Math.mulDiv(magnitude, carry, Q128);
            } else {
                dollars += Math.mulDiv(magnitude, rate, Q128, Math.Rounding.Ceil);
                magnitude = carry == 0 ? 0 : Math.mulDiv(magnitude, carry + 1, Q128, Math.Rounding.Ceil);
            }
            ++reached;
            --budget;
        }
        // casting to 'int256' is safe because the magnitude never grows past the input's
        // forge-lint: disable-next-line(unsafe-typecast)
        left = credit ? int256(magnitude) : -int256(magnitude);
    }

    /// @dev Applies the open-interval adjustment of a mint (`minted`) or a burn of `shares` to `holder`.
    function _adjust(State storage s, address holder, uint256 shares, bool minted) private {
        Holder storage h = s.holders[holder];
        _requireSettled(s, h, holder);
        if (shares == 0) return;
        h.capturePrepared = false;
        address[] storage tokens = s.tokens;
        uint256 length = tokens.length;
        bool written;
        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            IncomeToken storage t = s.token[token];
            uint256 index = t.openIndex;
            if (index == 0) continue;
            Adjustment storage a = h.adjustment[token];
            int256 amount = a.amount;
            if (minted) amount -= Math.mulDiv(shares, index, Q128, Math.Rounding.Ceil).toInt256();
            else amount += Math.mulDiv(shares, index, Q128).toInt256();
            a.amount = amount.toInt192();
            a.interval = t.interval;
            written = true;
        }
        if (written && !h.adjusted) h.adjusted = true;
    }

    /// @dev Reverts unless `h` was completely settled in the open collection interval.
    function _requireSettled(State storage s, Holder storage h, address holder) private view {
        if (h.interval != s.interval || h.mark != s.dollarIndex - s.deferredIndex || h.captured != s.frozenCount) {
            revert HolderNotSettled(holder);
        }
    }

    /// @dev Converts `token`'s open interval for the collection (see `collect`): returns the dollar index increment
    ///      and the dollars attributed to holders (rounded up, an upper bound).
    function _convert(State storage s, address token, uint256 sold, uint256 obtained)
        private
        returns (uint256 indexIncrement, uint256 attributed)
    {
        IncomeToken storage t = s.token[token];
        uint256 recognized = t.recognized;
        uint64 closing = t.interval;
        if (sold == 0) {
            if (obtained != 0) revert InconsistentCollection(token);
            if (recognized != 0) emit IntervalIncomeUnsold(s.source, closing, token, recognized);
            return (0, 0);
        }
        uint256 rate = Math.mulDiv(obtained, Q128, sold > recognized ? sold : recognized);
        uint256 carried;
        if (recognized != 0) {
            uint256 index = t.openIndex;
            indexIncrement = Math.mulDiv(index, rate, Q128);
            // ceil(R * rate) <= obtained * R / max(sold, R) <= obtained: the holders' share, rounded in their disfavor.
            attributed = Math.mulDiv(recognized, rate, Q128, Math.Rounding.Ceil);
            s.rate[closing][token] = rate;
            if (sold < recognized) {
                carried = recognized - sold;
                s.carry[closing][token] = Math.mulDiv(carried, Q128, recognized);
                t.openIndex = Math.mulDiv(index, carried, recognized);
            } else {
                t.openIndex = 0;
            }
            t.recognized = carried;
            t.remainder = 0;
            t.interval = closing + 1;
        }
        emit IntervalIncomeConverted(s.source, closing, token, sold, obtained, rate, carried);
    }

    /// @dev Magnitude of a signed adjustment.
    function _abs(int256 value) private pure returns (uint256) {
        // casting to 'uint256' is safe because the operand is non-negative (negation is checked)
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(value >= 0 ? value : -value);
    }

    /// @dev `index + floor((amount * 2^128 + remainder) / totalShares)` with the new remainder; `ok` false on
    ///      overflow. `amount <= MAX_STEP` keeps the mulDiv below 2^256; the carried remainder is reduced in full.
    function _advance(uint256 index, uint256 remainder, uint256 amount, uint256 totalShares)
        private
        pure
        returns (bool ok, uint256 newIndex, uint256 newRemainder)
    {
        uint256 increment = Math.mulDiv(amount, Q128, totalShares);
        uint256 fresh = mulmod(amount, Q128, totalShares);
        (ok, increment) = Math.tryAdd(increment, remainder / totalShares);
        remainder %= totalShares;
        if (!ok) return (false, index, 0);
        // fresh, remainder < totalShares: compare against the gap so the sum can never overflow.
        if (fresh >= totalShares - remainder) {
            newRemainder = fresh - (totalShares - remainder);
            (ok, increment) = Math.tryAdd(increment, 1);
        } else {
            newRemainder = fresh + remainder;
        }
        if (ok) (ok, newIndex) = Math.tryAdd(index, increment);
    }
}
