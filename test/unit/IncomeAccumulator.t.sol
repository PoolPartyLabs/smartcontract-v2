// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IncomeAccumulator} from "../../src/libraries/IncomeAccumulator.sol";

/// @dev Minimal share book around the library: the harness plays the Core Vault, checkpointing before every
///      balance change as the library requires.
contract IncomeAccumulatorHarness {
    using IncomeAccumulator for IncomeAccumulator.State;

    IncomeAccumulator.State internal s;
    mapping(address => uint256) public sharesOf;
    uint256 public totalShares;

    function registerToken(address token) external {
        s.registerToken(token);
    }

    function mint(address holder, uint256 shares) external {
        s.checkpoint(holder, sharesOf[holder]);
        sharesOf[holder] += shares;
        totalShares += shares;
    }

    function burn(address holder, uint256 shares) external {
        s.checkpoint(holder, sharesOf[holder]);
        sharesOf[holder] -= shares;
        totalShares -= shares;
    }

    function recognizeFromSource(bytes32 source, address token, uint256 cumulative) external returns (uint256) {
        return s.recognizeFromSource(source, token, cumulative, totalShares);
    }

    function advanceSource(bytes32 source, address token, uint256 cumulative) external returns (uint256) {
        return s.advanceSource(source, token, cumulative);
    }

    function distribute(address token, uint256 amount) external returns (bool) {
        return s.distribute(token, amount, totalShares);
    }

    function take(address holder, address token, uint256 maxAmount) external returns (uint256) {
        s.checkpoint(holder, sharesOf[holder]);
        return s.takeOwed(holder, token, maxAmount);
    }

    function takeAll(address holder, address token) external returns (uint256) {
        s.checkpoint(holder, sharesOf[holder]);
        return s.takeOwed(holder, token);
    }

    function owed(address holder, address token) external view returns (uint256) {
        return s.owed(holder, token, sharesOf[holder]);
    }

    function tokenIncome(address token) external view returns (IncomeAccumulator.TokenIncome memory) {
        return s.tokenIncome[token];
    }

    function sourceCumulative(bytes32 source, address token) external view returns (uint256) {
        return s.sourceCumulative[source][token];
    }

    function tokens() external view returns (address[] memory) {
        return s.incomeTokens();
    }

    function isRegistered(address token) external view returns (bool) {
        return s.isRegistered(token);
    }

    function isSourceFlagged(bytes32 source) external view returns (bool) {
        return s.isSourceFlagged(source);
    }
}

contract IncomeAccumulatorTest is Test {
    IncomeAccumulatorHarness internal h;
    address internal usdc = makeAddr("usdc");
    address internal weth = makeAddr("weth");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    bytes32 internal constant HUB_SOURCE = keccak256("hub spoke vault");
    bytes32 internal constant SPOKE_SOURCE = keccak256("robinhood");

    uint256 internal constant ONE_SHARE = 1e18;

    function setUp() public {
        h = new IncomeAccumulatorHarness();
        h.registerToken(usdc);
        h.registerToken(weth);
    }

    // ------------------------------------------------------------------ registration

    function test_Q60_closedTokenListRegistration() public {
        assertTrue(h.isRegistered(usdc));
        assertFalse(h.isRegistered(makeAddr("other")));
        assertEq(h.tokens().length, 2);
        vm.expectRevert(abi.encodeWithSelector(IncomeAccumulator.IncomeTokenAlreadyRegistered.selector, usdc));
        h.registerToken(usdc);
        vm.expectRevert(IncomeAccumulator.ZeroIncomeToken.selector);
        h.registerToken(address(0));
    }

    function test_Q60_tokenListIsBounded() public {
        for (uint256 i = 2; i < IncomeAccumulator.MAX_TOKENS; ++i) {
            h.registerToken(address(uint160(1000 + i)));
        }
        vm.expectRevert(IncomeAccumulator.TooManyIncomeTokens.selector);
        h.registerToken(address(uint160(5000)));
    }

    // ------------------------------------------------------------------ attribution

    /// DEC-014: an entrant gets nothing of the income recognized before its entry.
    function test_DEC014_newEntrantGetsNothingOfPriorIncome() public {
        h.mint(alice, 100 * ONE_SHARE);
        h.distribute(usdc, 1000e6);
        h.mint(bob, 100 * ONE_SHARE);
        assertEq(h.owed(bob, usdc), 0);
        assertApproxEqAbs(h.owed(alice, usdc), 1000e6, 1);
        // Income after both entered is split pro rata.
        h.distribute(usdc, 500e6);
        assertApproxEqAbs(h.owed(alice, usdc), 1250e6, 1);
        assertApproxEqAbs(h.owed(bob, usdc), 250e6, 1);
    }

    /// DEC-077: shares keep earning until burned; DEC-045: burning all shares leaves the owed amount intact to pay.
    function test_DEC045_fullBurnKeepsAttributedIncomeOwed() public {
        h.mint(alice, 10 * ONE_SHARE);
        h.mint(bob, 30 * ONE_SHARE);
        h.distribute(weth, 4e18);
        h.burn(alice, 10 * ONE_SHARE);
        assertEq(h.sharesOf(alice), 0);
        assertApproxEqAbs(h.owed(alice, weth), 1e18, 1);
        h.distribute(weth, 3e18);
        assertApproxEqAbs(h.owed(alice, weth), 1e18, 1, "no income after exit");
        assertApproxEqAbs(h.owed(bob, weth), 6e18, 1);
        assertApproxEqAbs(h.takeAll(alice, weth), 1e18, 1);
        assertEq(h.owed(alice, weth), 0);
    }

    /// DEC-092: tokens are tracked separately (per-token index, Q60).
    function test_DEC092_perTokenIndexKeepsTokensApart() public {
        h.mint(alice, ONE_SHARE);
        h.distribute(usdc, 7e6);
        h.distribute(weth, 2e18);
        assertApproxEqAbs(h.owed(alice, usdc), 7e6, 1);
        assertApproxEqAbs(h.owed(alice, weth), 2e18, 1);
    }

    /// LC-100 (OPEN): the Core Vault can cap what is paid now at the collected balance.
    function test_LC100_takeOwedCappedByMaxAmount() public {
        h.mint(alice, ONE_SHARE);
        h.distribute(usdc, 100e6);
        uint256 owedBefore = h.owed(alice, usdc);
        assertEq(h.take(alice, usdc, 40e6), 40e6);
        assertEq(h.owed(alice, usdc), owedBefore - 40e6);
        assertEq(h.tokenIncome(usdc).taken, 40e6);
    }

    // ------------------------------------------------------------------ recognition

    /// Q60: the delta is taken against the highest counter seen; a regressed counter is skipped with an event.
    function test_Q60_regressedCounterIsSkippedWithEventAndNeverReverts() public {
        h.mint(alice, ONE_SHARE);
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 100e6), 100e6);
        vm.expectEmit(true, true, false, true, address(h));
        emit IncomeAccumulator.CounterRegressed(SPOKE_SOURCE, usdc, 100e6, 80e6);
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 80e6), 0);
        assertEq(h.sourceCumulative(SPOKE_SOURCE, usdc), 100e6, "highest counter kept");
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 150e6), 50e6);
        assertApproxEqAbs(h.owed(alice, usdc), 150e6, 1);
    }

    function test_Q60_sourcesAreIndependent() public {
        h.mint(alice, ONE_SHARE);
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, 10e6), 10e6);
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 4e6), 4e6);
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, 10e6), 0);
        assertApproxEqAbs(h.owed(alice, usdc), 14e6, 1);
    }

    function test_Q60_unknownTokenIsSkippedWithEventAndNeverReverts() public {
        address other = makeAddr("other");
        h.mint(alice, ONE_SHARE);
        vm.expectEmit(true, true, false, true, address(h));
        emit IncomeAccumulator.UnknownIncomeToken(HUB_SOURCE, other, 5);
        assertEq(h.recognizeFromSource(HUB_SOURCE, other, 5), 0);
        assertEq(h.sourceCumulative(HUB_SOURCE, other), 0);
        assertFalse(h.distribute(other, 5));
    }

    /// Q60 / LC-32: income recognized with no shares outstanding goes to the ownerless bucket.
    function test_Q60_incomeWithZeroSupplyGoesOwnerless() public {
        vm.expectEmit(true, false, false, true, address(h));
        emit IncomeAccumulator.OwnerlessIncome(usdc, 9e6);
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, 9e6), 9e6);
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertEq(t.ownerless, 9e6);
        assertEq(t.index, 0);
        assertEq(t.distributed, 0);
        h.mint(alice, ONE_SHARE);
        assertEq(h.owed(alice, usdc), 0, "a later entrant does not receive ownerless income (DEC-014)");
    }

    /// DEC-107: the fee can be taken between advancing the counter and distributing.
    function test_DEC107_advanceThenDistributeNetOfFee() public {
        h.mint(alice, ONE_SHARE);
        uint256 delta = h.advanceSource(HUB_SOURCE, usdc, 1000e6);
        assertEq(delta, 1000e6);
        uint256 fee = delta / 5;
        h.distribute(usdc, delta - fee);
        assertApproxEqAbs(h.owed(alice, usdc), 800e6, 1);
    }

    /// Q60: the remainder is carried, so repeated small recognitions lose nothing beyond final rounding.
    function test_Q60_remainderCarriedAcrossRecognitions() public {
        h.mint(alice, 3 * ONE_SHARE);
        for (uint256 i; i < 1000; ++i) {
            h.distribute(usdc, 1);
        }
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertLt(t.remainder, 3 * ONE_SHARE);
        assertEq(t.distributed, 1000);
        // A single holder owns everything; rounding down loses at most one base unit.
        assertGe(h.owed(alice, usdc), 999);
        assertLe(h.owed(alice, usdc), 1000);
    }

    // ------------------------------------------------------------------ fuzz

    /// Q60 fitness function: holders are never owed more than what was distributed; rounding is down.
    function testFuzz_Q60_neverOverDistributes(
        uint256 sharesA,
        uint256 sharesB,
        uint256 amount1,
        uint256 amount2,
        uint256 burnB
    ) public {
        sharesA = bound(sharesA, 1, 1e12) * ONE_SHARE;
        sharesB = bound(sharesB, 1, 1e12) * ONE_SHARE;
        amount1 = bound(amount1, 0, 1e30);
        amount2 = bound(amount2, 0, 1e30);
        h.mint(alice, sharesA);
        h.distribute(weth, amount1);
        h.mint(bob, sharesB);
        h.distribute(weth, amount2);
        burnB = bound(burnB, 0, sharesB / ONE_SHARE) * ONE_SHARE;
        h.burn(bob, burnB);
        h.distribute(weth, amount1 / 3);
        uint256 total = amount1 + amount2 + amount1 / 3;
        uint256 owedSum = h.owed(alice, weth) + h.owed(bob, weth);
        assertLe(owedSum, total);
        // Rounding loses at most one base unit per holder per checkpoint plus one per distribution.
        assertGe(owedSum + 8, total);
    }

    // ------------------------------------------------------------------ adversarial (verification round 1)

    /// DEC-014: whatever income was recognized before entry, over any number of recognitions and tokens, an
    /// entrant is owed nothing, and income after entry is split by shares held.
    function testFuzz_DEC014_entrantOwesNothingOfPriorIncome(
        uint256 priorShares,
        uint256 priorIncome,
        uint256 entrantShares,
        uint8 rounds
    ) public {
        priorShares = bound(priorShares, 1, 1e12) * ONE_SHARE;
        entrantShares = bound(entrantShares, 1, 1e12) * ONE_SHARE;
        h.mint(alice, priorShares);
        for (uint256 i; i < rounds % 8; ++i) {
            h.distribute(usdc, bound(uint256(keccak256(abi.encode(priorIncome, i))), 0, 1e30));
        }
        h.distribute(weth, bound(priorIncome, 0, 1e30));
        h.mint(bob, entrantShares);
        assertEq(h.owed(bob, usdc), 0, "DEC-014: nothing of prior USDC income");
        assertEq(h.owed(bob, weth), 0, "DEC-014: nothing of prior WETH income");
        h.distribute(weth, 1e24);
        uint256 total = priorShares + entrantShares;
        assertApproxEqAbs(h.owed(bob, weth), Math.mulDiv(1e24, entrantShares, total), 2);
    }

    /// Q60: with a single holder, every distributed unit is recoverable up to one base unit of rounding, for
    /// amounts far above any realistic income and for the smallest and largest realistic supplies.
    function testFuzz_Q60_singleHolderRecoversAllIncomeUpToOneUnit(uint256 amount, uint256 wholeShares) public {
        amount = bound(amount, 0, IncomeAccumulator.MAX_STEP); // larger steps are skipped by design (Q60)
        wholeShares = bound(wholeShares, 1, 1e15);
        h.mint(alice, wholeShares * ONE_SHARE);
        h.distribute(weth, amount);
        uint256 owedNow = h.owed(alice, weth);
        assertLe(owedNow, amount);
        assertGe(owedNow + 1, amount);
        assertEq(h.takeAll(alice, weth), owedNow);
        assertEq(h.owed(alice, weth), 0);
    }

    /// Q60: the remainder is carried in numerator units and the struct NatSpec promises it stays below total
    /// shares. After the supply shrinks below a remainder left by a larger supply, a distribution must still
    /// reduce the remainder modulo the new supply; otherwise the index under-advances while `distributed` counts
    /// the amount, and the value reaches later holders instead of current ones (a DEC-014 attribution error).
    function test_Q60_remainderStaysBelowSupplyAfterSupplyShrinks() public {
        h.mint(alice, 1000 * ONE_SHARE);
        h.mint(bob, ONE_SHARE);
        h.distribute(usdc, 1); // remainder = 2^128 mod 1001e18, almost surely far above 1e18
        uint256 carried = h.tokenIncome(usdc).remainder;
        assertLt(carried, 1001 * ONE_SHARE);
        assertGt(carried, ONE_SHARE, "precondition: the carried remainder exceeds the shrunken supply");
        h.burn(alice, 1000 * ONE_SHARE);
        assertEq(h.totalShares(), ONE_SHARE);
        h.distribute(usdc, 1);
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertLt(t.remainder, h.totalShares(), "remainder must be below the current supply");
        // Bob alone holds the supply now: the second unit plus the carried fraction must reach him.
        assertGe(h.owed(bob, usdc), 1);
    }

    /// Q60 fitness function: recognition never reverts because of income. One source reporting an absurd
    /// cumulative counter (a buggy adapter, a corrupted report field) must not be able to revert recognition,
    /// and therefore report admission, for the whole fund.
    function test_Q60_absurdCounterFromOneSourceNeverRevertsRecognition() public {
        h.mint(alice, ONE_SHARE);
        h.recognizeFromSource(SPOKE_SOURCE, usdc, type(uint256).max);
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, 5e6), 5e6, "other sources keep working");
    }

    /// Q60: an advance above MAX_STEP is skipped with an event, flags the source and leaves its counter untouched.
    function test_Q60_anomalousAdvanceIsSkippedFlaggedAndCounterKept() public {
        h.mint(alice, ONE_SHARE);
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 10e6), 10e6);
        uint256 absurd = 10e6 + IncomeAccumulator.MAX_STEP + 1;
        vm.expectEmit(true, true, false, true, address(h));
        emit IncomeAccumulator.CounterAnomalous(SPOKE_SOURCE, usdc, 10e6, absurd);
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, absurd), 0);
        assertEq(h.sourceCumulative(SPOKE_SOURCE, usdc), 10e6, "counter not advanced");
        assertTrue(h.isSourceFlagged(SPOKE_SOURCE));
        assertFalse(h.isSourceFlagged(HUB_SOURCE));
        assertEq(h.tokenIncome(usdc).distributed, 10e6);
        // The source recovers as soon as it reports a sane counter again.
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 12e6), 2e6);
    }

    /// Q60: an advance of exactly MAX_STEP is accepted.
    function test_Q60_advanceAtMaxStepIsAccepted() public {
        h.mint(alice, ONE_SHARE);
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, IncomeAccumulator.MAX_STEP), IncomeAccumulator.MAX_STEP);
        assertEq(h.tokenIncome(usdc).distributed, IncomeAccumulator.MAX_STEP);
    }

    /// Q60: a regressed counter flags the source (signal only; recognition from it keeps working).
    function test_Q60_regressedCounterFlagsSource() public {
        h.mint(alice, ONE_SHARE);
        h.recognizeFromSource(SPOKE_SOURCE, usdc, 5e6);
        assertFalse(h.isSourceFlagged(SPOKE_SOURCE));
        h.recognizeFromSource(SPOKE_SOURCE, usdc, 4e6);
        assertTrue(h.isSourceFlagged(SPOKE_SOURCE));
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, 6e6), 1e6);
    }

    /// Q60 / DEC-107: a direct distribution above MAX_STEP (after the fee split) is skipped, never reverted.
    function test_Q60_distributeAboveMaxStepIsSkipped() public {
        h.mint(alice, ONE_SHARE);
        uint256 amount = IncomeAccumulator.MAX_STEP + 1;
        vm.expectEmit(true, false, false, true, address(h));
        emit IncomeAccumulator.DistributionSkipped(usdc, amount, 0);
        assertFalse(h.distribute(usdc, amount));
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertEq(t.distributed, 0);
        assertEq(t.index, 0);
    }

    /// Q60: an increment that would overflow the index is skipped, never reverted; the index keeps its value.
    function test_Q60_indexOverflowIsSkipped() public {
        h.mint(alice, 1); // a one-unit supply maximises the increment (harness only; shares are whole in the vault)
        assertTrue(h.distribute(usdc, IncomeAccumulator.MAX_STEP));
        uint256 indexBefore = h.tokenIncome(usdc).index;
        assertFalse(h.distribute(usdc, IncomeAccumulator.MAX_STEP));
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertEq(t.index, indexBefore);
        assertEq(t.distributed, IncomeAccumulator.MAX_STEP);
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, 1), 1, "later sane recognitions still never revert");
    }

    /// Q60: the carried remainder is reduced in full against the current supply; nothing is lost across shrinks.
    function testFuzz_Q60_remainderBelowSupplyAndConserved(uint256 bigShares, uint256 a1, uint256 a2) public {
        bigShares = bound(bigShares, 2, 1e12) * ONE_SHARE;
        a1 = bound(a1, 1, 1e30);
        a2 = bound(a2, 1, 1e30);
        h.mint(alice, bigShares);
        h.mint(bob, ONE_SHARE);
        h.distribute(usdc, a1);
        h.burn(alice, bigShares);
        h.distribute(usdc, a2);
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertLt(t.remainder, h.totalShares());
        // Index conservation: sum over distributions of amount * 2^128 equals index * supply + remainder, per step.
        uint256 aliceOwed = h.owed(alice, usdc);
        uint256 bobOwed = h.owed(bob, usdc);
        assertLe(aliceOwed + bobOwed, a1 + a2);
        assertGe(aliceOwed + bobOwed + 2, a1 + a2, "at most one unit of rounding per distribution");
    }

    /// Q60: a regression followed by an over-correction is taken against the highest counter seen, whatever the
    /// supply was at each step, and never over-distributes.
    function testFuzz_Q60_regressThenRecoverNeverOverDistributes(uint256 c1, uint256 c2, uint256 c3, uint256 shares)
        public
    {
        c1 = bound(c1, 1, 1e30);
        c2 = bound(c2, 0, c1);
        c3 = bound(c3, 0, 1e30);
        shares = bound(shares, 1, 1e12) * ONE_SHARE;
        h.mint(alice, shares);
        uint256 d1 = h.recognizeFromSource(SPOKE_SOURCE, usdc, c1);
        uint256 d2 = h.recognizeFromSource(SPOKE_SOURCE, usdc, c2);
        uint256 d3 = h.recognizeFromSource(SPOKE_SOURCE, usdc, c3);
        assertEq(d1, c1);
        assertEq(d2, 0, "a regressed counter distributes nothing");
        assertEq(d3, c3 > c1 ? c3 - c1 : 0);
        uint256 highest = c3 > c1 ? c3 : c1;
        assertEq(h.sourceCumulative(SPOKE_SOURCE, usdc), highest);
        assertLe(h.owed(alice, usdc), highest);
        assertGe(h.owed(alice, usdc) + 2, highest);
    }

    // ------------------------------------------------------------------ adversarial (verification round 2)

    /// Q60: exact arithmetic identity of every accepted distribution, whatever the supply did in between:
    /// `(index_new - index_old) * supply_new + remainder_new == amount * 2^128 + remainder_old`, checked modulo
    /// 2^256 (both sides are the same integer, so the wrapped values must agree). This refutes any off-by-one in
    /// the carry, any lost remainder when the supply shrinks, and any drift when the supply grows.
    /// Verification round 2 note: a zero-amount distribution is an early-return no-op, so the carried remainder is
    /// reduced modulo the new supply only at the next NON-zero distribution; the struct NatSpec "below total
    /// shares" holds as of the last non-zero distribution. The identity holds either way.
    function testFuzz_Q60_distributionIdentityHoldsAcrossSupplyChanges(
        uint256 s1,
        uint256 s2,
        uint256 a1,
        uint256 a2,
        uint256 a3
    ) public {
        s1 = bound(s1, 1, 1e15) * ONE_SHARE;
        s2 = bound(s2, 1, 1e15) * ONE_SHARE;
        a1 = bound(a1, 0, IncomeAccumulator.MAX_STEP);
        a2 = bound(a2, 0, IncomeAccumulator.MAX_STEP);
        a3 = bound(a3, 0, IncomeAccumulator.MAX_STEP);
        h.mint(alice, s1);
        _distributeAndCheckIdentity(a1, s1);
        // Grow: bob enters with a possibly much larger supply.
        h.mint(bob, s2);
        _distributeAndCheckIdentity(a2, s1 + s2);
        // Shrink: alice leaves; the remainder left against (s1 + s2) is reduced against s2.
        h.burn(alice, s1);
        _distributeAndCheckIdentity(a3, s2);
        // One more unit forces the reduction even when a3 was zero.
        _distributeAndCheckIdentity(1, s2);
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(weth);
        assertLt(t.remainder, s2);
        assertEq(t.distributed, a1 + a2 + a3 + 1);
    }

    function _distributeAndCheckIdentity(uint256 amount, uint256 supply) internal {
        IncomeAccumulator.TokenIncome memory before = h.tokenIncome(weth);
        assertTrue(h.distribute(weth, amount), "within MAX_STEP a distribution is always accepted");
        IncomeAccumulator.TokenIncome memory later = h.tokenIncome(weth);
        assertGe(later.index, before.index, "index never decreases");
        if (amount == 0) {
            assertEq(later.index, before.index, "zero amount: no-op");
            assertEq(later.remainder, before.remainder, "zero amount: no-op");
        } else {
            assertLt(later.remainder, supply, "remainder below the supply it was reduced against");
        }
        uint256 lhs;
        uint256 rhs;
        unchecked {
            lhs = (later.index - before.index) * supply + later.remainder;
            rhs = amount * IncomeAccumulator.Q128 + before.remainder;
        }
        assertEq(lhs, rhs, "distribution identity");
    }

    /// Q60, DEC-014: with up to five holders, extreme supplies (1e15 whole shares) and extreme amounts (up to
    /// MAX_STEP), the sum of what every holder is owed plus what was taken never exceeds what was distributed, and
    /// the dust left behind is bounded by one base unit per holder-checkpoint plus one per distribution. Holders
    /// who leave keep exactly what they earned; holders who enter late earn nothing from before.
    function testFuzz_Q60_fiveHoldersConservationAtExtremes(uint256[5] memory wholeShares, uint256[3] memory amounts)
        public
    {
        address[5] memory holders = [alice, bob, makeAddr("carol"), makeAddr("dave"), makeAddr("erin")];
        uint256 total;
        for (uint256 i; i < 5; ++i) {
            wholeShares[i] = bound(wholeShares[i], 1, 1e15);
            h.mint(holders[i], wholeShares[i] * ONE_SHARE);
            total += wholeShares[i] * ONE_SHARE;
        }
        for (uint256 i; i < 3; ++i) {
            amounts[i] = bound(amounts[i], 0, IncomeAccumulator.MAX_STEP);
        }
        assertTrue(h.distribute(weth, amounts[0]));
        // dave leaves entirely and takes everything owed; carol halves her position.
        uint256 daveOwedAtExit = h.owed(holders[3], weth);
        h.burn(holders[3], wholeShares[3] * ONE_SHARE);
        assertEq(h.takeAll(holders[3], weth), daveOwedAtExit);
        h.burn(holders[2], (wholeShares[2] / 2) * ONE_SHARE);
        assertTrue(h.distribute(weth, amounts[1]));
        assertEq(h.owed(holders[3], weth), 0, "a leaver earns nothing after exit");
        // A late entrant with a huge position captures nothing of the past (DEC-014).
        address late = makeAddr("late");
        h.mint(late, 1e15 * ONE_SHARE);
        assertEq(h.owed(late, weth), 0);
        assertTrue(h.distribute(weth, amounts[2]));
        uint256 owedSum = h.owed(late, weth);
        for (uint256 i; i < 5; ++i) {
            owedSum += h.owed(holders[i], weth);
        }
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(weth);
        assertEq(t.distributed, amounts[0] + amounts[1] + amounts[2]);
        assertLe(owedSum + t.taken, t.distributed, "never over-distributes");
        // Dust bound: one unit per (holder, distribution) pair, plus the carried remainder (< 1 unit).
        assertGe(owedSum + t.taken + 6 * 3 + 1, t.distributed, "dust bounded");
    }

    /// Q60, LC-32, DEC-014: zero-supply episodes. Income recognized while nobody holds shares is ownerless and
    /// stays so: it never reaches an earlier holder who left, never reaches a later entrant, and the index does not
    /// move. A `type(uint256).max` distribution is skipped without touching any counter; a `type(uint256).max`
    /// cumulative counter is skipped and the source recovers.
    function testFuzz_Q60_zeroSupplyAndMaxUintNeverLeakOrRevert(uint256 wholeShares, uint256 amount) public {
        wholeShares = bound(wholeShares, 1, 1e15);
        amount = bound(amount, 1, IncomeAccumulator.MAX_STEP);
        h.mint(alice, wholeShares * ONE_SHARE);
        assertTrue(h.distribute(usdc, amount));
        uint256 aliceOwed = h.owed(alice, usdc);
        h.burn(alice, wholeShares * ONE_SHARE);
        assertEq(h.totalShares(), 0);
        uint256 indexBefore = h.tokenIncome(usdc).index;

        // Ownerless episode.
        assertTrue(h.distribute(usdc, amount));
        assertEq(h.recognizeFromSource(SPOKE_SOURCE, usdc, amount), amount);
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(usdc);
        assertEq(t.ownerless, 2 * amount);
        assertEq(t.index, indexBefore, "index does not move with zero supply");
        assertEq(t.distributed, amount, "ownerless income is not distributed");
        assertEq(h.owed(alice, usdc), aliceOwed, "the leaver gets nothing of the ownerless income");

        // Max-uint inputs never revert and never move state.
        assertFalse(h.distribute(usdc, type(uint256).max));
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, type(uint256).max), 0);
        assertTrue(h.isSourceFlagged(HUB_SOURCE));
        assertEq(h.sourceCumulative(HUB_SOURCE, usdc), 0);
        assertEq(h.tokenIncome(usdc).ownerless, 2 * amount);

        // A later entrant gets nothing of the ownerless bucket and only what is distributed after entry.
        h.mint(bob, ONE_SHARE);
        assertEq(h.owed(bob, usdc), 0);
        assertEq(h.recognizeFromSource(HUB_SOURCE, usdc, amount), amount, "flagged source keeps recognizing");
        assertApproxEqAbs(h.owed(bob, usdc), amount, 1);
        assertEq(h.owed(alice, usdc), aliceOwed);
        assertEq(h.takeAll(alice, usdc), aliceOwed, "the leaver's owed amount is intact and payable");
    }

    /// Q60: a checkpoint never reverts, even after the index was driven as high as whole-share supplies allow
    /// (one share, MAX_STEP distributions) and the holder then carries the largest realistic balance.
    function test_Q60_checkpointNeverRevertsAtExtremeIndex() public {
        h.mint(alice, ONE_SHARE);
        for (uint256 i; i < 8; ++i) {
            assertTrue(h.distribute(weth, IncomeAccumulator.MAX_STEP));
        }
        uint256 index = h.tokenIncome(weth).index;
        assertGt(index, 0);
        // alice is owed 8 * MAX_STEP up to rounding; the checkpoint runs the 512-bit mulDiv at this index.
        assertApproxEqAbs(h.owed(alice, weth), 8 * IncomeAccumulator.MAX_STEP, 8);
        h.mint(bob, 1e15 * ONE_SHARE);
        assertEq(h.owed(bob, weth), 0);
        assertTrue(h.distribute(weth, IncomeAccumulator.MAX_STEP));
        // bob holds essentially the whole supply; checkpointing 1e33 shares against the delta must not overflow.
        h.burn(bob, 1e15 * ONE_SHARE);
        assertApproxEqAbs(h.owed(bob, weth), IncomeAccumulator.MAX_STEP, IncomeAccumulator.MAX_STEP / 1e14);
        assertLe(h.owed(alice, weth) + h.owed(bob, weth), 9 * IncomeAccumulator.MAX_STEP);
    }

    /// Q60: `recognizeFromSource` advances the counter and then distributes; if the distribution is skipped
    /// (index overflow, only reachable with a sub-whole-share supply) the delta is consumed but never distributed
    /// and never booked as ownerless. The library returns the delta as if recognized. Documented as a finding
    /// (verification round 2): the caller cannot tell from the return value that the value was dropped.
    function test_Q60_recognizeReturnsDeltaEvenWhenDistributionSkipped() public {
        h.mint(alice, 1); // harness only: drives the index to the overflow edge
        assertTrue(h.distribute(usdc, IncomeAccumulator.MAX_STEP));
        uint256 distributedBefore = h.tokenIncome(usdc).distributed;
        uint256 delta = h.recognizeFromSource(SPOKE_SOURCE, usdc, IncomeAccumulator.MAX_STEP);
        assertEq(delta, IncomeAccumulator.MAX_STEP, "delta reported as recognized");
        assertEq(h.sourceCumulative(SPOKE_SOURCE, usdc), IncomeAccumulator.MAX_STEP, "counter advanced");
        assertEq(h.tokenIncome(usdc).distributed, distributedBefore, "but nothing was distributed");
        assertEq(h.tokenIncome(usdc).ownerless, 0, "and nothing went ownerless");
    }
}

/// @dev Random mints, burns, recognitions and takes over three holders and two tokens.
contract IncomeAccumulatorHandler is Test {
    IncomeAccumulatorHarness public immutable h;
    address public immutable usdc;
    address public immutable weth;
    address[3] internal holders = [address(0xA11CE), address(0xB0B), address(0xCA7)];
    bytes32[2] internal sources = [bytes32("hub"), bytes32("spoke")];
    mapping(bytes32 => mapping(address => uint256)) internal counter;
    uint256 public lastIndexUsdc;
    uint256 public lastIndexWeth;
    bool public indexDecreased;

    constructor(IncomeAccumulatorHarness h_, address usdc_, address weth_) {
        h = h_;
        usdc = usdc_;
        weth = weth_;
    }

    function mint(uint256 holderSeed, uint256 wholeShares) external {
        h.mint(holders[holderSeed % 3], bound(wholeShares, 1, 1e9) * 1e18);
        _track();
    }

    function burn(uint256 holderSeed, uint256 wholeShares) external {
        address holder = holders[holderSeed % 3];
        uint256 max = h.sharesOf(holder) / 1e18;
        if (max == 0) return;
        h.burn(holder, bound(wholeShares, 1, max) * 1e18);
        _track();
    }

    function recognize(uint256 sourceSeed, bool isWeth, uint256 step, bool regress) external {
        bytes32 source = sources[sourceSeed % 2];
        address token = isWeth ? weth : usdc;
        uint256 current = counter[source][token];
        uint256 reported = regress ? current / 2 : current + bound(step, 0, 1e24);
        h.recognizeFromSource(source, token, reported);
        if (reported > current) counter[source][token] = reported;
        _track();
    }

    function take(uint256 holderSeed, bool isWeth, uint256 maxAmount) external {
        h.take(holders[holderSeed % 3], isWeth ? weth : usdc, maxAmount);
        _track();
    }

    function holderAt(uint256 i) external view returns (address) {
        return holders[i];
    }

    function _track() internal {
        uint256 iu = h.tokenIncome(usdc).index;
        uint256 iw = h.tokenIncome(weth).index;
        if (iu < lastIndexUsdc || iw < lastIndexWeth) indexDecreased = true;
        lastIndexUsdc = iu;
        lastIndexWeth = iw;
    }
}

contract IncomeAccumulatorInvariantTest is StdInvariant, Test {
    IncomeAccumulatorHarness internal h;
    IncomeAccumulatorHandler internal handler;
    address internal usdc = makeAddr("usdc");
    address internal weth = makeAddr("weth");

    function setUp() public {
        h = new IncomeAccumulatorHarness();
        h.registerToken(usdc);
        h.registerToken(weth);
        handler = new IncomeAccumulatorHandler(h, usdc, weth);
        targetContract(address(handler));
    }

    /// Q60 fitness function: owed (checkpointed and pending) plus taken never exceeds what was distributed.
    function invariant_Q60_owedPlusTakenNeverExceedsDistributed() public view {
        _check(usdc);
        _check(weth);
    }

    /// Q60 fitness function: the index never decreases.
    function invariant_Q60_indexNeverDecreases() public view {
        assertFalse(handler.indexDecreased());
    }

    function _check(address token) internal view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += h.owed(handler.holderAt(i), token);
        }
        IncomeAccumulator.TokenIncome memory t = h.tokenIncome(token);
        assertLe(sum + t.taken, t.distributed);
    }
}
