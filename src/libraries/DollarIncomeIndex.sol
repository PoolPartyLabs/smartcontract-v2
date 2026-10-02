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

    /// @notice Most closed-interval conversions one `settle` performs. Each reads one stored rate and one stored carry
    ///         (two cold slots); after full sales a holder needs one per adjusted token (at most `MAX_TOKENS`).
    uint256 internal constant MAX_SETTLE_STEPS = 64;

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

    function _settleFrozen(State storage s, Holder storage holder, uint256 shares) private returns (bool complete) {
        uint256 budget = MAX_SETTLE_STEPS;
        while (holder.captured < s.frozenCount && budget != 0) {
            uint64 id = ++holder.captured;
            FrozenCollection storage frozen = s.frozen[id];
            for (uint256 index; index < s.tokens.length; ++index) {
                holder.claims[id].push(_frozenClaim(s, holder, frozen, shares, index));
            }
            --budget;
        }
        complete = holder.captured == s.frozenCount;
        budget = MAX_SETTLE_STEPS;
        while (holder.paid < holder.captured && budget != 0) {
            uint64 id = holder.paid + 1;
            FrozenCollection storage frozen = s.frozen[id];
            if (!frozen.finalized) break;
            for (uint256 index; index < s.tokens.length; ++index) {
                holder.dollars += Math.mulDiv(holder.claims[id][index], frozen.rates[index], Q128);
            }
            delete holder.claims[id];
            holder.paid = id;
            --budget;
        }
        if (holder.paid < holder.captured && s.frozen[holder.paid + 1].finalized) complete = false;
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
        Holder storage h = s.holders[holder];
        if (!_settleFrozen(s, h, shares)) return false;
        uint256 dollars = h.dollars + _indexed(s, h, shares);
        settled = true;
        if (h.adjusted && h.interval != s.interval) {
            Settlement memory run = Settlement(0, 0, MAX_SETTLE_STEPS, false, true);
            address[] storage tokens = s.tokens;
            uint256 length = tokens.length;
            for (uint256 i; i < length; ++i) {
                _settleAdjustment(s, h, tokens[i], run);
            }
            h.adjusted = run.remaining;
            settled = run.complete;
            dollars += run.credit;
            dollars = dollars > run.debit ? dollars - run.debit : 0;
        }
        if (settled) h.interval = s.interval;
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
        dollars = h.dollars + _indexed(s, h, shares);
        for (uint64 id = h.paid + 1; id <= s.frozenCount; ++id) {
            FrozenCollection storage frozen = s.frozen[id];
            if (!frozen.finalized) break;
            for (uint256 index; index < s.tokens.length; ++index) {
                uint256 claim = id <= h.captured ? h.claims[id][index] : _frozenClaim(s, h, frozen, shares, index);
                dollars += Math.mulDiv(claim, frozen.rates[index], Q128);
            }
        }
        if (!h.adjusted || h.interval == s.interval) return dollars;
        uint256 debit;
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
        IncomeToken storage t = s.token[token];
        uint256 base = Math.mulDiv(shares, t.openIndex, Q128);
        Adjustment storage a = s.holders[holder].adjustment[token];
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
