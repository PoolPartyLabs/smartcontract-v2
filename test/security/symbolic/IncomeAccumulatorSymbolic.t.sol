// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";

/// @title Symbolic properties of IncomeAccumulator (Halmos `check_` functions)
/// @notice Run with `halmos --match-contract IncomeAccumulatorSymbolicTest`. Each check writes an arbitrary (symbolic)
///         accumulator state straight into storage, so the property holds from every reachable state, not only from
///         the ones a call sequence builds.
contract IncomeAccumulatorSymbolicTest is Test {
    using IncomeAccumulator for IncomeAccumulator.State;

    uint256 internal constant Q128 = 1 << 128;
    /// @dev Storage variables on purpose, never `constant`: with compile-time constant mapping keys solc folds the
    ///      slot hash into a PUSH32, and Halmos does not unify that literal slot with the same slot the library
    ///      computes at run time with KECCAK256 (a write through one form is invisible to a read through the other,
    ///      which yields false counterexamples and vacuous passes; see docs/security/reports/dynamic-analysis.md).
    address internal TOKEN = address(0xA11CE);
    address internal HOLDER = address(0xB0B);
    address internal OTHER = address(0xCA11);
    bytes32 internal SOURCE = keccak256("source");

    IncomeAccumulator.State internal s;

    function setUp() public {
        s.registerToken(TOKEN);
    }

    /// DEC-014: an entrant checkpointed with its balance before the mint (zero) owes nothing of the income recognized
    /// before it entered, whatever the index was and however many shares it then holds.
    function check_DEC014_newHolderOwesNothingOfPriorIncome(uint256 priorIndex, uint256 shares) public {
        s.tokenIncome[TOKEN].index = priorIndex;
        s.checkpoint(HOLDER, 0);
        assert(s.holders[HOLDER].income[TOKEN].owed == 0);
        assert(s.owed(HOLDER, TOKEN, shares) == 0);
    }

    /// Q60: a checkpoint credits exactly `shares * (index - checkpoint) / 2^128` rounded down, moves the checkpoint to
    /// the index, and a second checkpoint at the same index credits nothing (income is never collected twice).
    function check_Q60_checkpointCreditsOnceAndExactly(uint256 shares, uint256 last, uint256 index, uint256 owedBefore)
        public
    {
        vm.assume(last <= index);
        vm.assume(shares <= type(uint128).max);
        vm.assume(owedBefore <= type(uint128).max);
        s.tokenIncome[TOKEN].index = index;
        s.holders[HOLDER].income[TOKEN] = IncomeAccumulator.HolderIncome(last, owedBefore);

        s.checkpoint(HOLDER, shares);
        uint256 owedAfter = s.holders[HOLDER].income[TOKEN].owed;
        assert(s.holders[HOLDER].income[TOKEN].indexCheckpoint == index);
        assert(owedAfter == owedBefore + Math.mulDiv(shares, index - last, Q128));

        s.checkpoint(HOLDER, shares);
        assert(s.holders[HOLDER].income[TOKEN].owed == owedAfter);
    }

    /// Q60: `takeOwed` moves exactly the amount it returns from the holder's owed balance to `taken`, never more than
    /// the holder is owed and never more than the cap (LC-100).
    function check_LC100_takeOwedConserves(uint256 owedBefore, uint256 takenBefore, uint256 maxAmount) public {
        vm.assume(takenBefore <= type(uint128).max && owedBefore <= type(uint128).max);
        s.holders[HOLDER].income[TOKEN].owed = owedBefore;
        s.tokenIncome[TOKEN].taken = takenBefore;
        uint256 amount = s.takeOwed(HOLDER, TOKEN, maxAmount);
        assert(amount <= owedBefore && amount <= maxAmount);
        assert(s.holders[HOLDER].income[TOKEN].owed == owedBefore - amount);
        assert(s.tokenIncome[TOKEN].taken == takenBefore + amount);
    }

    /// Q60: a source's counter never decreases, the delta returned is exactly its advance, and a regressed or anomalous
    /// report returns zero, leaves the counter alone and flags the source.
    function check_Q60_advanceSourceIsMonotonic(uint256 previous, uint256 reported) public {
        s.sourceCumulative[SOURCE][TOKEN] = previous;
        uint256 delta = s.advanceSource(SOURCE, TOKEN, reported);
        uint256 current = s.sourceCumulative[SOURCE][TOKEN];
        assert(current >= previous);
        assert(delta == current - previous);
        assert(delta <= IncomeAccumulator.MAX_STEP);
        if (reported < previous || reported - previous > IncomeAccumulator.MAX_STEP) {
            assert(delta == 0 && current == previous && s.flaggedSources[SOURCE]);
        } else {
            assert(current == reported);
        }
    }

    /// Q60: `distribute` never lowers the index and never reverts on any state; a rejected amount changes nothing, an
    /// accepted amount is booked exactly once (in `distributed`, or in `ownerless` with no shares outstanding).
    function check_Q60_distributeBooksExactlyOnce(
        uint256 index,
        uint256 remainder,
        uint256 distributed,
        uint256 ownerless,
        uint256 amount,
        uint256 totalShares
    ) public {
        vm.assume(distributed <= type(uint192).max && ownerless <= type(uint192).max);
        IncomeAccumulator.TokenIncome storage t = s.tokenIncome[TOKEN];
        t.index = index;
        t.remainder = remainder;
        t.distributed = distributed;
        t.ownerless = ownerless;

        bool accepted = s.distribute(TOKEN, amount, totalShares);

        assert(t.index >= index);
        if (!accepted) {
            assert(t.index == index && t.remainder == remainder);
            assert(t.distributed == distributed && t.ownerless == ownerless);
        } else if (amount == 0) {
            assert(t.index == index && t.distributed == distributed && t.ownerless == ownerless);
        } else if (totalShares == 0) {
            assert(t.index == index && t.distributed == distributed && t.ownerless == ownerless + amount);
        } else {
            assert(amount <= IncomeAccumulator.MAX_STEP);
            assert(t.distributed == distributed + amount && t.ownerless == ownerless);
        }
    }

    /// Q60: after an accepted distribution the carried remainder is below the supply it was divided by.
    function check_Q60_remainderStaysBelowSupply(uint256 remainder, uint256 amount, uint256 totalShares) public {
        vm.assume(totalShares != 0 && totalShares <= type(uint96).max);
        vm.assume(amount != 0 && amount <= type(uint64).max);
        vm.assume(remainder <= type(uint96).max);
        s.tokenIncome[TOKEN].remainder = remainder;
        bool accepted = s.distribute(TOKEN, amount, totalShares);
        assert(accepted);
        assert(s.tokenIncome[TOKEN].remainder < totalShares);
    }

    /// DEC-014, Q60 conservation: two holders that together own the whole supply are never owed more than what was
    /// distributed (owed plus taken never exceeds distributed; nothing was taken here).
    function check_Q60_twoHoldersNeverOwedMoreThanDistributed(uint256 sharesA, uint256 sharesB, uint256 amount) public {
        vm.assume(sharesA <= type(uint64).max && sharesB <= type(uint64).max);
        vm.assume(sharesA + sharesB != 0);
        vm.assume(amount <= type(uint64).max);
        s.checkpoint(HOLDER, 0);
        s.checkpoint(OTHER, 0);
        s.distribute(TOKEN, amount, sharesA + sharesB);
        assert(s.owed(HOLDER, TOKEN, sharesA) + s.owed(OTHER, TOKEN, sharesB) <= amount);
        assert(s.tokenIncome[TOKEN].distributed == amount);
    }
}
