// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title IncomeAccumulator
/// @notice Per-token income index with a per-holder checkpoint, for Attributed Income.
/// @dev DEC-014: income belongs to whoever held shares while it was generated; a new entrant gets nothing generated
///      before entry. DEC-092: uncollected income sits in its own bucket outside Share Assets; the mechanism must not
///      read all positions on every user operation; direction is a global accumulator with a per-holder checkpoint.
///      Mechanism (Q60, RECOMMENDED, not decided): per-token index in Q128, remainder carried to the next
///      recognition, per-source monotonic cumulative counters, recognition that never reverts, income recognized
///      with no shares outstanding kept ownerless with an event. Rounding is down at both ends; dust stays in the
///      bucket.
/// @dev Usage: `checkpoint(holder, sharesBefore)` before every mint and burn of `holder` and before `takeOwed`.
///      Income tokens form a closed list registered by the vault from the Mandate's pools (bounded by `MAX_TOKENS`
///      so a checkpoint stays O(k)).
/// @dev Per-address state lives in one struct (`HolderAccount`) so a future whole-position migration (Q58, E1) can
///      copy it without a checkpoint of both sides.
library IncomeAccumulator {
    /// @notice Index scale: 2^128.
    uint256 internal constant Q128 = 1 << 128;

    /// @notice Maximum number of income tokens, bounding the checkpoint loop.
    uint256 internal constant MAX_TOKENS = 16;

    /// @notice Largest counter advance (and largest distribution) the accumulator accepts in one step: 2^128 - 1.
    /// @dev Q60 fitness function "report admission never reverts because of income". This is an ARITHMETIC bound, not
    ///      an economic cap: below it `amount * 2^128` fits 256 bits for any supply, `distributed`/`ownerless` would
    ///      need 2^128 steps to overflow, and a checkpoint's `shares * (index - checkpoint) / 2^128` stays below the
    ///      amounts distributed. A larger advance can only come from a faulty or malicious source; it is skipped with
    ///      `CounterAnomalous` and the source is flagged. OPEN (Q60, DEC-107 reading (4)): the economic per-source
    ///      advance cap (`delta * price <= cap * sourceValue * dt / year`) is not decided and is not applied here.
    uint256 internal constant MAX_STEP = type(uint128).max;

    /// @notice Global state of one income token.
    /// @param registered Whether the token is in the closed list.
    /// @param index Income per share base unit since fund creation, in Q128; never decreases.
    /// @param remainder Division remainder carried to the next distribution (numerator units, below total shares).
    /// @param ownerless Income recognized while no share existed (retained until decided, LC-32 OPEN).
    /// @param distributed Total income distributed through the index (excludes ownerless).
    /// @param taken Total income taken by holders through `takeOwed`.
    struct TokenIncome {
        bool registered;
        uint256 index;
        uint256 remainder;
        uint256 ownerless;
        uint256 distributed;
        uint256 taken;
    }

    /// @notice One holder's state for one token.
    /// @param indexCheckpoint Value of the token index at the holder's last checkpoint.
    /// @param owed Attributed Income of the holder in that token, not yet withdrawn.
    struct HolderIncome {
        uint256 indexCheckpoint;
        uint256 owed;
    }

    /// @notice All per-address income state, in one block (Q58).
    struct HolderAccount {
        mapping(address token => HolderIncome) income;
    }

    /// @notice Accumulator storage.
    struct State {
        address[] tokens;
        mapping(address token => TokenIncome) tokenIncome;
        mapping(address holder => HolderAccount) holders;
        mapping(bytes32 source => mapping(address token => uint256)) sourceCumulative;
        mapping(bytes32 source => bool) flaggedSources;
    }

    /// @notice A source's cumulative counter advanced by `delta`.
    event IncomeRecognized(bytes32 indexed source, address indexed token, uint256 delta, uint256 cumulative);

    /// @notice Income entered the index.
    event IncomeDistributed(address indexed token, uint256 amount, uint256 index);

    /// @notice A source reported a cumulative counter below the highest seen; skipped, never reverted (Q60).
    event CounterRegressed(bytes32 indexed source, address indexed token, uint256 previous, uint256 reported);

    /// @notice A source's counter advanced by more than `MAX_STEP`; skipped, never reverted, source flagged (Q60).
    event CounterAnomalous(bytes32 indexed source, address indexed token, uint256 previous, uint256 reported);

    /// @notice A distribution could not enter the index without overflow; skipped, never reverted (Q60).
    event DistributionSkipped(address indexed token, uint256 amount, uint256 index);

    /// @notice Income was recognized with no shares outstanding and kept ownerless (Q60, LC-32 OPEN).
    event OwnerlessIncome(address indexed token, uint256 amount);

    /// @notice Income in a token outside the closed list was reported; skipped, never reverted.
    event UnknownIncomeToken(bytes32 indexed source, address indexed token, uint256 amount);

    /// @notice An income token was added to the closed list.
    event IncomeTokenRegistered(address indexed token);

    /// @notice Zero token address.
    error ZeroIncomeToken();

    /// @notice The closed list is full.
    error TooManyIncomeTokens();

    /// @notice The token is already registered.
    error IncomeTokenAlreadyRegistered(address token);

    /// @notice Adds `token` to the closed list. Call at construction, from the Mandate's pool tokens.
    function registerToken(State storage s, address token) internal {
        if (token == address(0)) revert ZeroIncomeToken();
        TokenIncome storage t = s.tokenIncome[token];
        if (t.registered) revert IncomeTokenAlreadyRegistered(token);
        if (s.tokens.length >= MAX_TOKENS) revert TooManyIncomeTokens();
        t.registered = true;
        s.tokens.push(token);
        emit IncomeTokenRegistered(token);
    }

    /// @notice Whether `token` is in the closed list.
    function isRegistered(State storage s, address token) internal view returns (bool) {
        return s.tokenIncome[token].registered;
    }

    /// @notice Whether `source` ever reported a regressed or anomalous counter.
    /// @dev Q60 design: the per-source flag signals only and blocks nothing; what reacts to it is not decided.
    function isSourceFlagged(State storage s, bytes32 source) internal view returns (bool) {
        return s.flaggedSources[source];
    }

    /// @notice The closed list of income tokens.
    function incomeTokens(State storage s) internal view returns (address[] memory) {
        return s.tokens;
    }

    /// @notice Advances `source`'s counter for `token` to `cumulativeReported` and returns the delta. Never reverts.
    /// @dev Q60: the delta is taken against the highest counter ever seen for the source; a regressed counter emits
    ///      `CounterRegressed`, flags the source and returns 0; an advance above `MAX_STEP` emits `CounterAnomalous`,
    ///      flags the source and returns 0 without moving the counter; an unregistered token emits `UnknownIncomeToken` and returns 0 without
    ///      touching the counter. Separated from `distribute` so the caller can take the performance fee and protocol
    ///      slice from the delta first (DEC-107).
    function advanceSource(State storage s, bytes32 source, address token, uint256 cumulativeReported)
        internal
        returns (uint256 delta)
    {
        if (!s.tokenIncome[token].registered) {
            emit UnknownIncomeToken(source, token, cumulativeReported);
            return 0;
        }
        uint256 previous = s.sourceCumulative[source][token];
        if (cumulativeReported < previous) {
            s.flaggedSources[source] = true;
            emit CounterRegressed(source, token, previous, cumulativeReported);
            return 0;
        }
        delta = cumulativeReported - previous;
        if (delta == 0) return 0;
        if (delta > MAX_STEP) {
            s.flaggedSources[source] = true;
            emit CounterAnomalous(source, token, previous, cumulativeReported);
            return 0;
        }
        s.sourceCumulative[source][token] = cumulativeReported;
        emit IncomeRecognized(source, token, delta, cumulativeReported);
    }

    /// @notice Adds `amount` of `token` income to the index for `totalShares`. Never reverts.
    /// @dev Q60: `index += (amount * 2^128 + remainder) / totalShares`, with the new remainder carried. With no shares
    ///      outstanding the amount goes to the ownerless bucket. An unregistered token emits `UnknownIncomeToken` and
    ///      returns false. An amount above `MAX_STEP`, or one whose increment would overflow the index, emits
    ///      `DistributionSkipped` and returns false; the caller keeps the amount out of `distributed`.
    ///      The carried remainder is reduced against the CURRENT supply in full (`/` and `%`), so it stays below
    ///      `totalShares` even after the supply shrank since the previous distribution.
    /// @return accepted Whether the amount entered the accumulator (index or ownerless bucket).
    function distribute(State storage s, address token, uint256 amount, uint256 totalShares)
        internal
        returns (bool accepted)
    {
        TokenIncome storage t = s.tokenIncome[token];
        if (!t.registered) {
            emit UnknownIncomeToken(bytes32(0), token, amount);
            return false;
        }
        if (amount == 0) return true;
        if (amount > MAX_STEP) {
            emit DistributionSkipped(token, amount, t.index);
            return false;
        }
        if (totalShares == 0) {
            t.ownerless += amount;
            emit OwnerlessIncome(token, amount);
            return true;
        }
        // Exact floor((amount * 2^128 + remainder) / totalShares), overflow-free: amount < 2^128 keeps the mulDiv
        // result below 2^256; the carried remainder was left against an older supply, so it is reduced in full.
        uint256 increment = Math.mulDiv(amount, Q128, totalShares);
        uint256 fresh = mulmod(amount, Q128, totalShares);
        uint256 carried = t.remainder;
        bool ok;
        (ok, increment) = Math.tryAdd(increment, carried / totalShares);
        carried %= totalShares;
        uint256 newRemainder;
        if (ok) {
            // fresh, carried < totalShares: compare against the gap so the sum can never overflow.
            if (fresh >= totalShares - carried) {
                newRemainder = fresh - (totalShares - carried);
                (ok, increment) = Math.tryAdd(increment, 1);
            } else {
                newRemainder = fresh + carried;
            }
        }
        uint256 newIndex;
        if (ok) (ok, newIndex) = Math.tryAdd(t.index, increment);
        if (!ok) {
            emit DistributionSkipped(token, amount, t.index);
            return false;
        }
        t.remainder = newRemainder;
        t.index = newIndex;
        t.distributed += amount;
        emit IncomeDistributed(token, amount, t.index);
        return true;
    }

    /// @notice `advanceSource` then `distribute` of the whole delta (no fee). Never reverts.
    function recognizeFromSource(
        State storage s,
        bytes32 source,
        address token,
        uint256 cumulativeReported,
        uint256 totalShares
    ) internal returns (uint256 delta) {
        delta = advanceSource(s, source, token, cumulativeReported);
        if (delta != 0) distribute(s, token, delta, totalShares);
    }

    /// @notice Moves a holder's pending income into `owed` for every token and resets the checkpoints.
    /// @dev DEC-014, Q60: call before every change to the holder's share balance (mint, every form of burn) and before
    ///      `takeOwed`, with the balance BEFORE the change. `owed += shares * (index - checkpoint) / 2^128`, rounded down.
    function checkpoint(State storage s, address holder, uint256 shares) internal {
        HolderAccount storage account = s.holders[holder];
        uint256 length = s.tokens.length;
        for (uint256 i; i < length; ++i) {
            address token = s.tokens[i];
            uint256 index = s.tokenIncome[token].index;
            HolderIncome storage h = account.income[token];
            uint256 last = h.indexCheckpoint;
            if (index == last) continue;
            if (shares != 0) h.owed += Math.mulDiv(shares, index - last, Q128);
            h.indexCheckpoint = index;
        }
    }

    /// @notice Attributed Income of `holder` in `token` including the pending part, for a balance of `shares`.
    function owed(State storage s, address holder, address token, uint256 shares) internal view returns (uint256) {
        HolderIncome storage h = s.holders[holder].income[token];
        return h.owed + Math.mulDiv(shares, s.tokenIncome[token].index - h.indexCheckpoint, Q128);
    }

    /// @notice Removes up to `maxAmount` from `holder`'s owed `token` income and returns the amount removed.
    /// @dev Takes only the checkpointed `owed`; call `checkpoint` first. The caller transfers the amount.
    ///      LC-100 (OPEN): the Core Vault passes `maxAmount` = the collected balance it can pay now.
    function takeOwed(State storage s, address holder, address token, uint256 maxAmount)
        internal
        returns (uint256 amount)
    {
        HolderIncome storage h = s.holders[holder].income[token];
        amount = h.owed < maxAmount ? h.owed : maxAmount;
        if (amount == 0) return 0;
        h.owed -= amount;
        s.tokenIncome[token].taken += amount;
    }

    /// @notice `takeOwed` with no cap.
    function takeOwed(State storage s, address holder, address token) internal returns (uint256) {
        return takeOwed(s, holder, token, type(uint256).max);
    }
}
