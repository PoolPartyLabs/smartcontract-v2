// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title DollarIncomeIndex
/// @notice Attributed Income per share in two indices (DEC-161 item 1): per income token, a token index of the open
///         interval (since the last collection) that advances at recognition; and one cumulative dollar index that
///         advances only when a collection converts the interval's income, at that collection's rate per token.
/// @dev Mechanism: `docs/engenharia/2026-10-01-checklist-pre-mainnet/10-INDICE-EM-DOLAR-NA-HUB.md` section 2 of the
///      spec repository.
///      - DEC-014, DEC-138: income belongs to whoever held shares when it was recognized. Shares minted in the middle of
///        an interval take nothing of what the interval earned before them (`onMint`); burned shares keep what they
///        earned until the burn (`onBurn`).
///      - DEC-117 item 2, DEC-152: one token index per income token, no price in the attribution. The caller
///        recognizes the income net of the performance fee (DEC-117 item 3); the fee is not this library's concern.
///      - DEC-124, DEC-161: the conversion to dollars happens at collection; Income Withdrawal pays dollars (`take`).
///      - DEC-161 item 2: the rate of every token converted in every collection is stored. A holder who moved shares
///        during an interval carries a per-token adjustment for it, converted at the rate of the collection that
///        closed that interval, possibly several collections before the holder comes back (doc 10 section 3).
///        DEC-161 item 3: never paid by average.
///      - Holders who did not move shares during an interval are served by the dollar index alone and read no rate.
///      Source-agnostic: the caller keeps one `State` per source class (Hub income, spoke income; doc 10 section 6)
///      and tags it with `source` for the events. DEC-145 (active shares for spoke income) is layered on top by the
///      caller (WP-14).
///      Rounding is always against the holder: floor on every credit, ceiling on every debit, the division remainder
///      of the open interval dropped at collection. The holders together are never owed more tokens than were
///      recognized in the open interval, nor more dollars than the collections obtained (`dollarsAttributed`).
///      Usage per balance change of `holder` (mint, every form of burn): `settle(holder, sharesBefore)`, then
///      `onMint(holder, minted)` or `onBurn(holder, burned)`, then the balance change; `settle` again before `take`.
///      Bounds: amounts per recognition up to `MAX_STEP`; overflow is unreachable with share supplies of whole shares
///      and real token amounts (the open index stays near `income per share x 2^128`).
library DollarIncomeIndex {
    using SafeCast for uint256;

    /// @notice Index scale: 2^128.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Maximum number of income tokens per source, bounding every per-holder loop.
    uint256 internal constant MAX_TOKENS = 16;

    /// @notice Largest amount one recognition accepts (arithmetic bound, as `IncomeAccumulator.MAX_STEP`).
    uint256 internal constant MAX_STEP = type(uint128).max;

    /// @notice Open-interval state of one income token.
    /// @param registered Whether the token is in the closed list.
    /// @param openIndex Token units per share recognized in the open interval, in Q128; reset at collection.
    /// @param remainder Division remainder carried between recognitions of the open interval (numerator units).
    /// @param recognized Token units that entered `openIndex` in the open interval (carried-in units included).
    /// @param unattributed Token units that could not enter the index when carried at zero supply (caller decides).
    struct IncomeToken {
        bool registered;
        uint256 openIndex;
        uint256 remainder;
        uint256 recognized;
        uint256 unattributed;
    }

    /// @notice One holder's state.
    /// @param dollars Dollars settled and not yet taken.
    /// @param mark Value of the dollar index at the holder's last settlement.
    /// @param interval Interval the adjustments belong to (the open one as of the last settlement).
    /// @param adjusted Whether any adjustment may be non-zero (skips the rate reads otherwise).
    /// @param adjustment Per-token signed adjustment, in token units, of the interval `interval`: minus what shares
    ///        minted during it would have earned before the mint, plus what shares burned during it earned.
    struct Holder {
        uint256 dollars;
        uint256 mark;
        uint64 interval;
        bool adjusted;
        mapping(address token => int256) adjustment;
    }

    /// @notice Index storage of one source class.
    /// @param source Caller-chosen tag carried by the events (e.g. 1 = Hub income, 2 = spoke income).
    /// @param interval Number of the open interval; collection `n` closes interval `n`.
    /// @param dollarIndex Dollar units per share converted by every collection so far, in Q128; never decreases.
    /// @param rate Per closed interval and token: dollar units per token unit, in Q128. Written only when the token's
    ///        open index was non-zero at the collection (otherwise no adjustment can exist for it).
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
        mapping(address holder => Holder) holders;
        uint256 dollarsObtained;
        uint256 dollarsAttributed;
        uint256 dollarsTaken;
    }

    /// @notice An income token was added to the closed list.
    event IncomeTokenAdded(uint8 indexed source, address indexed token);

    /// @notice `amount` of `token` entered the open interval's index, now `openIndex`.
    event IntervalIncomeRecognized(uint8 indexed source, address indexed token, uint256 amount, uint256 openIndex);

    /// @notice A recognition was skipped (unknown token, amount above `MAX_STEP`, index overflow); never reverted.
    event IntervalIncomeSkipped(uint8 indexed source, address indexed token, uint256 amount);

    /// @notice Collection `interval` converted `token`: `sold` units for `obtained` dollars, at `rate` (Q128 dollar
    ///         units per recognized token unit); `carried` unsold units entered the next interval.
    event IntervalIncomeConverted(
        uint8 indexed source,
        uint256 indexed interval,
        address indexed token,
        uint256 sold,
        uint256 obtained,
        uint256 rate,
        uint256 carried
    );

    /// @notice Interval `interval` closed: the dollar index is now `dollarIndex`; of `obtained` dollars,
    ///         `unattributed` belong to no holder (sold above what holders were recognized, or rounding).
    event IncomeIntervalClosed(
        uint8 indexed source, uint256 indexed interval, uint256 dollarIndex, uint256 obtained, uint256 unattributed
    );

    /// @notice Unsold units could not be carried into the next interval because no share existed.
    event UnattributedIncome(uint8 indexed source, address indexed token, uint256 amount);

    /// @notice Zero token address.
    error IncomeTokenZero();

    /// @notice The closed list is full.
    error IncomeTokenListFull();

    /// @notice The token is already in the closed list.
    error IncomeTokenAlreadyAdded(address token);

    /// @notice `sold` and `obtained` must have one entry per income token, in list order.
    error CollectionLengthMismatch();

    /// @notice `onMint`/`onBurn` ran without a `settle` of the holder in the open interval.
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

    /// @notice Closes the open interval: converts every token's interval income at this collection's rate and
    ///         opens the next interval.
    /// @dev DEC-161, doc 10 section 2. Per token `k` (arrays in `incomeTokens` order), with `R` the units recognized in
    ///      the interval: `rate = obtained / max(sold, R)`, stored for the interval; `dollarIndex += rate * openIndex`;
    ///      the open index and remainder reset.
    ///      - `sold >= R`: the holders' `R` units convert at `obtained / sold`; the dollars for the units above `R`
    ///        (the fee's units, if the caller passes the whole sale; income recognized at zero supply) come back in
    ///        `unattributed`.
    ///      - `sold < R` (part of the interval's income unsold, e.g. a failed sale): every holder's interval claim
    ///        converts the same fraction `sold / R` at the sale price, and the `R - sold` unsold units are carried
    ///        into the next interval as recognized income over `totalShares` (doc 10 leaves this case open; this is
    ///        the plan's reading). The carry follows the shares held at the collection, so holders who moved shares
    ///        during the closed interval get the unsold part pro rata to their shares at the collection rather than to
    ///        their interval claim; at zero supply the units stay in `IncomeToken.unattributed`.
    /// @param sold Token units sold for the holders, per token.
    /// @param obtained Dollars credited for them, per token (for a dollar token not sold, `sold == obtained`).
    /// @param totalShares Share supply at the collection, for the carry.
    /// @return unattributed Dollars of this collection attributed to no holder (at most `sum(obtained)`).
    function collect(State storage s, uint256[] memory sold, uint256[] memory obtained, uint256 totalShares)
        internal
        returns (uint256 unattributed)
    {
        uint256 length = s.tokens.length;
        if (sold.length != length || obtained.length != length) revert CollectionLengthMismatch();
        uint256[] memory carried = new uint256[](length);
        unattributed = _close(s, sold, obtained, carried);
        for (uint256 i; i < length; ++i) {
            uint256 carry = carried[i];
            if (carry == 0) continue;
            address token = s.tokens[i];
            if (!recognize(s, token, carry, totalShares)) {
                s.token[token].unattributed += carry;
                emit UnattributedIncome(s.source, token, carry);
            }
        }
    }

    /// @notice Brings `holder` to the open interval: converts the adjustments of a closed interval at that interval's
    ///         stored rates, then adds `shares * (dollarIndex - mark)`.
    /// @dev DEC-014, DEC-161. Call before every change to the holder's balance, with the balance BEFORE the change,
    ///      and before `take`. A total below zero can only come from rounding (every holder's exact claim is
    ///      non-negative) and settles at zero.
    function settle(State storage s, address holder, uint256 shares) internal {
        Holder storage h = s.holders[holder];
        (uint256 dollars, bool converted) = _settled(s, h, shares);
        if (converted) {
            address[] storage tokens = s.tokens;
            uint256 length = tokens.length;
            for (uint256 i; i < length; ++i) {
                delete h.adjustment[tokens[i]];
            }
            h.adjusted = false;
        }
        h.interval = s.interval;
        h.mark = s.dollarIndex;
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
    /// @dev Takes only settled dollars: call `settle` first. The caller transfers the amount.
    function take(State storage s, address holder, uint256 maxDollars) internal returns (uint256 dollars) {
        Holder storage h = s.holders[holder];
        uint256 settled = h.dollars;
        dollars = settled < maxDollars ? settled : maxDollars;
        if (dollars == 0) return 0;
        h.dollars = settled - dollars;
        s.dollarsTaken += dollars;
    }

    /// @notice Dollars `holder` is owed now for a balance of `shares` (settled plus pending), without settling.
    function owedDollars(State storage s, address holder, uint256 shares) internal view returns (uint256 dollars) {
        (dollars,) = _settled(s, s.holders[holder], shares);
    }

    /// @notice Units of `token` `holder` is owed in the open interval (not yet converted) for a balance of `shares`.
    function tokenOwed(State storage s, address holder, uint256 shares, address token) internal view returns (uint256) {
        Holder storage h = s.holders[holder];
        uint256 base = Math.mulDiv(shares, s.token[token].openIndex, Q128);
        // Adjustments of a closed interval are already dollars (pending conversion in `owedDollars`).
        if (h.interval != s.interval) return base;
        int256 adjustment = h.adjustment[token];
        uint256 magnitude = _abs(adjustment);
        if (adjustment >= 0) return base + magnitude;
        return base > magnitude ? base - magnitude : 0;
    }

    /// @dev Settled dollars of `h` for `shares`, and whether closed-interval adjustments were converted.
    function _settled(State storage s, Holder storage h, uint256 shares)
        private
        view
        returns (uint256 dollars, bool converted)
    {
        dollars = h.dollars;
        uint256 debit;
        uint64 tag = h.interval;
        converted = h.adjusted && tag != s.interval;
        if (converted) {
            address[] storage tokens = s.tokens;
            uint256 length = tokens.length;
            for (uint256 i; i < length; ++i) {
                address token = tokens[i];
                int256 adjustment = h.adjustment[token];
                if (adjustment == 0) continue;
                uint256 rate = s.rate[tag][token];
                if (adjustment > 0) dollars += Math.mulDiv(_abs(adjustment), rate, Q128);
                else debit += Math.mulDiv(_abs(adjustment), rate, Q128, Math.Rounding.Ceil);
            }
        }
        uint256 mark = h.mark;
        uint256 index = s.dollarIndex;
        if (shares != 0 && index != mark) dollars += Math.mulDiv(shares, index - mark, Q128);
        dollars = dollars > debit ? dollars - debit : 0;
    }

    /// @dev Applies the open-interval adjustment of a mint (`minted`) or a burn of `shares` to `holder`.
    function _adjust(State storage s, address holder, uint256 shares, bool minted) private {
        Holder storage h = s.holders[holder];
        if (h.interval != s.interval || h.mark != s.dollarIndex) revert HolderNotSettled(holder);
        if (shares == 0) return;
        address[] storage tokens = s.tokens;
        uint256 length = tokens.length;
        bool written;
        for (uint256 i; i < length; ++i) {
            address token = tokens[i];
            uint256 index = s.token[token].openIndex;
            if (index == 0) continue;
            if (minted) h.adjustment[token] -= Math.mulDiv(shares, index, Q128, Math.Rounding.Ceil).toInt256();
            else h.adjustment[token] += Math.mulDiv(shares, index, Q128).toInt256();
            written = true;
        }
        if (written && !h.adjusted) h.adjusted = true;
    }

    /// @dev Converts every token of the open interval (writing the unsold units into `carried`) and opens the next
    ///      interval; returns the dollars attributed to no holder. See `collect`.
    function _close(State storage s, uint256[] memory sold, uint256[] memory obtained, uint256[] memory carried)
        private
        returns (uint256 unattributed)
    {
        uint64 closing = s.interval;
        uint256 indexIncrement;
        uint256 attributed;
        uint256 obtainedTotal;
        for (uint256 i; i < carried.length; ++i) {
            uint256 increment;
            uint256 share;
            (increment, share, carried[i]) = _convert(s, closing, s.tokens[i], sold[i], obtained[i]);
            indexIncrement += increment;
            attributed += share;
            obtainedTotal += obtained[i];
        }
        uint256 dollarIndex = s.dollarIndex + indexIncrement;
        s.dollarIndex = dollarIndex;
        s.interval = closing + 1;
        s.dollarsObtained += obtainedTotal;
        s.dollarsAttributed += attributed;
        unattributed = obtainedTotal - attributed;
        emit IncomeIntervalClosed(s.source, closing, dollarIndex, obtainedTotal, unattributed);
    }

    /// @dev Closes `token`'s open interval for collection `closing`: returns the dollar index increment, the dollars
    ///      attributed to holders (rounded up, an upper bound) and the unsold units to carry. See `collect`.
    function _convert(State storage s, uint64 closing, address token, uint256 sold, uint256 obtained)
        private
        returns (uint256 indexIncrement, uint256 attributed, uint256 carried)
    {
        IncomeToken storage t = s.token[token];
        uint256 recognized = t.recognized;
        if (recognized == 0 && sold == 0 && obtained == 0) return (0, 0, 0);
        uint256 denominator = sold > recognized ? sold : recognized;
        uint256 rate = denominator == 0 ? 0 : Math.mulDiv(obtained, Q128, denominator);
        uint256 index = t.openIndex;
        if (index != 0) {
            indexIncrement = Math.mulDiv(index, rate, Q128);
            s.rate[closing][token] = rate;
            t.openIndex = 0;
        }
        if (recognized != 0) {
            // ceil(R * rate) <= obtained * R / max(sold, R) <= obtained: the holders' share, rounded in their disfavor.
            attributed = Math.mulDiv(recognized, rate, Q128, Math.Rounding.Ceil);
            t.recognized = 0;
            t.remainder = 0;
            if (sold < recognized) carried = recognized - sold;
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
