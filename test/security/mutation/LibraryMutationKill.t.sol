// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

/// @dev The accumulator behind external calls, with raw setters so a test can start from any stored state.
contract AccumulatorMutationHarness {
    using IncomeAccumulator for IncomeAccumulator.State;

    IncomeAccumulator.State internal s;

    function registerToken(address token) external {
        s.registerToken(token);
    }

    function setTokenIncome(address token, uint256 index, uint256 remainder) external {
        s.tokenIncome[token].index = index;
        s.tokenIncome[token].remainder = remainder;
    }

    function setOwed(address holder, address token, uint256 owed_) external {
        s.holders[holder].income[token].owed = owed_;
    }

    function advanceSource(bytes32 source, address token, uint256 cumulative) external returns (uint256) {
        return s.advanceSource(source, token, cumulative);
    }

    function recognizeFromSource(bytes32 source, address token, uint256 cumulative, uint256 totalShares)
        external
        returns (uint256)
    {
        return s.recognizeFromSource(source, token, cumulative, totalShares);
    }

    function distribute(address token, uint256 amount, uint256 totalShares) external returns (bool) {
        return s.distribute(token, amount, totalShares);
    }

    function checkpoint(address holder, uint256 shares) external {
        s.checkpoint(holder, shares);
    }

    function takeOwed(address holder, address token, uint256 maxAmount) external returns (uint256) {
        return s.takeOwed(holder, token, maxAmount);
    }

    function takeAllOwed(address holder, address token) external returns (uint256) {
        return s.takeOwed(holder, token);
    }

    function storedOwed(address holder, address token) external view returns (uint256) {
        return s.holders[holder].income[token].owed;
    }

    function tokenIncome(address token) external view returns (IncomeAccumulator.TokenIncome memory) {
        return s.tokenIncome[token];
    }

    function isSourceFlagged(bytes32 source) external view returns (bool) {
        return s.isSourceFlagged(source);
    }
}

contract ShareMathMutationHarness {
    function isWholeShares(uint256 shares) external pure returns (bool) {
        return ShareMath.isWholeShares(shares);
    }

    function bpsOf(uint256 amount, uint256 bps) external pure returns (uint256) {
        return ShareMath.bpsOf(amount, bps);
    }
}

contract ReportCodecMutationHarness {
    function versionOf(bytes memory payload) external pure returns (uint256) {
        return ReportCodec.versionOf(payload);
    }

    function decode(bytes memory payload) external pure returns (ReportCodec.Report memory) {
        return ReportCodec.decode(payload);
    }
}

/// @title Tests that kill the meaningful mutants the baseline library suites let survive
/// @notice Each test names the mutant it kills (slither-mutate operator and source line at commit e5c778a); the
///         campaign and the full list of survivors are in docs/security/reports/dynamic-analysis.md.
contract LibraryMutationKillTest is Test {
    uint256 internal constant Q128 = 1 << 128;
    address internal constant TOKEN = address(0xA11CE);
    address internal constant HOLDER = address(0xB0B);
    bytes32 internal constant SOURCE = keccak256("hub");

    AccumulatorMutationHarness internal acc;
    ShareMathMutationHarness internal math;
    ReportCodecMutationHarness internal codec;

    function setUp() public {
        acc = new AccumulatorMutationHarness();
        acc.registerToken(TOKEN);
        math = new ShareMathMutationHarness();
        codec = new ReportCodecMutationHarness();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ShareMath
    // ---------------------------------------------------------------------------------------------------------------

    /// Kills RR, CR and four AOR mutants of ShareMath.sol:51 (`isWholeShares` had no test at all).
    function test_DEC091_isWholeSharesAcceptsOnlyMultiplesOf1e18() public view {
        assertTrue(math.isWholeShares(0));
        assertTrue(math.isWholeShares(1e18));
        assertTrue(math.isWholeShares(183e18));
        assertFalse(math.isWholeShares(1));
        assertFalse(math.isWholeShares(1e18 - 1));
        assertFalse(math.isWholeShares(1e18 + 1));
        assertFalse(math.isWholeShares(type(uint256).max));
    }

    function testFuzz_DEC091_isWholeSharesMatchesModulo(uint256 shares) public view {
        assertEq(math.isWholeShares(shares), shares % 1e18 == 0);
    }

    /// Kills ROR ShareMath.sol:95 (`bps > BPS` to `bps >= BPS`): a rate of exactly 100% is valid.
    function test_DEC102_bpsOfAcceptsExactlyOneHundredPercent() public {
        assertEq(math.bpsOf(1234e6, 10_000), 1234e6);
        vm.expectRevert(abi.encodeWithSelector(ShareMath.BpsAboveMax.selector, 10_001));
        math.bpsOf(1234e6, 10_001);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // IncomeAccumulator
    // ---------------------------------------------------------------------------------------------------------------

    /// Kills three ASOR mutants of IncomeAccumulator.sol:247 (`h.owed +=` to `=`, `|=`, `^=`): income a holder is owed
    /// from an earlier checkpoint must survive the next checkpoint (DEC-014; a holder who deposits again, or whose
    /// payout is partial, is checkpointed without taking).
    function test_DEC014_checkpointAccumulatesOwedAcrossCheckpoints() public {
        uint256 shares = 100e18;
        acc.checkpoint(HOLDER, 0);
        acc.distribute(TOKEN, 300e6, shares);
        acc.checkpoint(HOLDER, shares);
        uint256 first = acc.storedOwed(HOLDER, TOKEN);
        uint256 firstIndex = acc.tokenIncome(TOKEN).index;
        // One base unit stays behind as the index remainder (rounding down at both ends).
        assertEq(first, 300e6 - 1);
        acc.distribute(TOKEN, 300e6, shares);
        acc.checkpoint(HOLDER, shares);
        uint256 second = acc.storedOwed(HOLDER, TOKEN);
        assertEq(second, first + Math.mulDiv(shares, acc.tokenIncome(TOKEN).index - firstIndex, Q128));
        assertGe(second, 600e6 - 2, "the first 300 must not be overwritten or xor-ed away");
        assertLe(second, 600e6);
    }

    function testFuzz_DEC014_checkpointAddsExactlyThePendingIncome(
        uint256 owedBefore,
        uint256 shares,
        uint256 last,
        uint256 index
    ) public {
        owedBefore = bound(owedBefore, 0, type(uint128).max);
        shares = bound(shares, 0, type(uint128).max);
        index = bound(index, 0, type(uint256).max);
        last = bound(last, 0, index);
        // Reach checkpoint `last` with no shares, then move the index to `index`.
        acc.setTokenIncome(TOKEN, last, 0);
        acc.checkpoint(HOLDER, 0);
        acc.setOwed(HOLDER, TOKEN, owedBefore);
        acc.setTokenIncome(TOKEN, index, 0);
        acc.checkpoint(HOLDER, shares);
        assertEq(acc.storedOwed(HOLDER, TOKEN), owedBefore + Math.mulDiv(shares, index - last, Q128));
    }

    /// Kills three ASOR mutants of IncomeAccumulator.sol:269 (`taken +=` to `=`, `|=`, `^=`): `taken` is the running
    /// total of everything holders took.
    function test_LC100_takenIsARunningTotal() public {
        acc.setOwed(HOLDER, TOKEN, 1000);
        assertEq(acc.takeOwed(HOLDER, TOKEN, 300), 300);
        assertEq(acc.tokenIncome(TOKEN).taken, 300);
        assertEq(acc.takeOwed(HOLDER, TOKEN, 300), 300);
        assertEq(acc.tokenIncome(TOKEN).taken, 600, "second take adds to the first");
        assertEq(acc.takeOwed(HOLDER, TOKEN, type(uint256).max), 400);
        assertEq(acc.tokenIncome(TOKEN).taken, 1000);
        assertEq(acc.storedOwed(HOLDER, TOKEN), 0);
    }

    /// Kills SBR IncomeAccumulator.sol:274 (uncapped `takeOwed` capped at uint128 max).
    function test_LC100_uncappedTakeTakesEverythingOwed() public {
        uint256 owed = uint256(type(uint128).max) + 12_345;
        acc.setOwed(HOLDER, TOKEN, owed);
        assertEq(acc.takeAllOwed(HOLDER, TOKEN), owed);
        assertEq(acc.storedOwed(HOLDER, TOKEN), 0);
    }

    /// Kills ROR IncomeAccumulator.sol:149 (`<` to `<=`): a source that reports the same counter again has not
    /// regressed and must not be flagged.
    function test_Q60_unchangedCounterIsNotARegression() public {
        assertEq(acc.advanceSource(SOURCE, TOKEN, 500), 500);
        vm.recordLogs();
        assertEq(acc.advanceSource(SOURCE, TOKEN, 500), 0);
        assertFalse(acc.isSourceFlagged(SOURCE), "an unchanged counter flags nothing");
        assertEq(vm.getRecordedLogs().length, 0, "and emits nothing");
    }

    /// Kills MIA and ROR (`< 0`) IncomeAccumulator.sol:155 and MIA IncomeAccumulator.sol:182: a zero delta and a zero
    /// distribution are silent no-ops, so indexers never see an empty recognition or distribution.
    function test_Q60_zeroDeltaAndZeroAmountEmitNothing() public {
        acc.advanceSource(SOURCE, TOKEN, 7);
        vm.recordLogs();
        assertEq(acc.recognizeFromSource(SOURCE, TOKEN, 7, 10e18), 0);
        assertTrue(acc.distribute(TOKEN, 0, 10e18));
        assertTrue(acc.distribute(TOKEN, 0, 0));
        assertEq(vm.getRecordedLogs().length, 0);
        IncomeAccumulator.TokenIncome memory t = acc.tokenIncome(TOKEN);
        assertEq(t.index, 0);
        assertEq(t.distributed, 0);
        assertEq(t.ownerless, 0);
    }

    /// Kills the five CR mutants that drop an event of the accumulator (lines 115, 162, 179, 213, 219).
    function test_Q60_everyAccumulatorEventIsEmitted() public {
        address other = address(0xBEEF);
        vm.expectEmit(address(acc));
        emit IncomeAccumulator.IncomeTokenRegistered(other);
        acc.registerToken(other);

        vm.expectEmit(address(acc));
        emit IncomeAccumulator.IncomeRecognized(SOURCE, TOKEN, 40, 40);
        acc.advanceSource(SOURCE, TOKEN, 40);

        vm.expectEmit(address(acc));
        emit IncomeAccumulator.IncomeDistributed(TOKEN, 40, Math.mulDiv(40, Q128, 8e18));
        assertTrue(acc.distribute(TOKEN, 40, 8e18));

        address unknown = address(0xDEAD);
        vm.expectEmit(address(acc));
        emit IncomeAccumulator.UnknownIncomeToken(bytes32(0), unknown, 5);
        assertFalse(acc.distribute(unknown, 5, 8e18));

        uint256 tooLarge = uint256(type(uint128).max) + 1;
        vm.expectEmit(address(acc));
        emit IncomeAccumulator.DistributionSkipped(TOKEN, tooLarge, acc.tokenIncome(TOKEN).index);
        assertFalse(acc.distribute(TOKEN, tooLarge, 8e18));

        // The second `DistributionSkipped` site: the index cannot take the increment.
        acc.setTokenIncome(TOKEN, type(uint256).max, 0);
        vm.expectEmit(address(acc));
        emit IncomeAccumulator.DistributionSkipped(TOKEN, 1, type(uint256).max);
        assertFalse(acc.distribute(TOKEN, 1, 1));
    }

    /// Kills MIA IncomeAccumulator.sol:211 (`if (ok)` to `if (true)`): when the increment itself overflows, the
    /// distribution must be skipped whole, never accepted with a zero increment. Only reachable from a carried
    /// remainder far above the supply, which the library never produces; the guard is defence in depth.
    /// (MIA :201 is an equivalent mutant: the first addition can only overflow with a supply of one share base unit,
    /// where the carry branch inside the guarded block can never fire.)
    function test_Q60_overflowingIncrementIsSkippedNotTruncated() public {
        // increment = mulDiv(amount, Q128, 1) + remainder / 1 overflows 256 bits.
        uint256 amount = type(uint128).max;
        acc.setTokenIncome(TOKEN, 5, type(uint256).max);
        assertFalse(acc.distribute(TOKEN, amount, 1));
        IncomeAccumulator.TokenIncome memory t = acc.tokenIncome(TOKEN);
        assertEq(t.index, 5, "index untouched");
        assertEq(t.remainder, type(uint256).max, "remainder untouched");
        assertEq(t.distributed, 0, "nothing booked");

        // A remainder far above the supply that still fits: totalShares = 3, amount = 1 gives fresh = Q128 % 3 = 1,
        // carried / 3 = (2^256 - 1) / 3 and carried % 3 = 0, so there is no carry and the result is exact.
        acc.setTokenIncome(TOKEN, 0, type(uint256).max);
        assertTrue(acc.distribute(TOKEN, 1, 3));
        t = acc.tokenIncome(TOKEN);
        assertEq(t.index, Q128 / 3 + type(uint256).max / 3);
        assertEq(t.remainder, 1);
    }

    /// The exact index arithmetic, from any stored remainder: `index += floor((amount * 2^128 + remainder) /
    /// totalShares)` with the new remainder carried, or nothing at all when that does not fit 256 bits.
    function testFuzz_Q60_distributeIsExactOrSkipped(uint256 index, uint256 remainder, uint256 amount, uint256 supply)
        public
    {
        amount = bound(amount, 1, type(uint128).max);
        supply = bound(supply, 1, type(uint256).max);
        acc.setTokenIncome(TOKEN, index, remainder);

        // Reference: quotient and remainder of (amount * 2^128 + remainder) / supply, tracking overflow.
        uint256 quotient = Math.mulDiv(amount, Q128, supply);
        uint256 fresh = mulmod(amount, Q128, supply);
        bool fits;
        (fits, quotient) = Math.tryAdd(quotient, remainder / supply);
        uint256 carried = remainder % supply;
        uint256 expectedRemainder;
        if (fits) {
            if (fresh >= supply - carried) {
                expectedRemainder = fresh - (supply - carried);
                (fits, quotient) = Math.tryAdd(quotient, 1);
            } else {
                expectedRemainder = fresh + carried;
            }
        }
        uint256 expectedIndex;
        if (fits) (fits, expectedIndex) = Math.tryAdd(index, quotient);

        bool accepted = acc.distribute(TOKEN, amount, supply);
        IncomeAccumulator.TokenIncome memory t = acc.tokenIncome(TOKEN);
        assertEq(accepted, fits, "accepted exactly when the arithmetic fits");
        if (fits) {
            assertEq(t.index, expectedIndex);
            assertEq(t.remainder, expectedRemainder);
            assertLt(t.remainder, supply);
            assertEq(t.distributed, amount);
        } else {
            assertEq(t.index, index);
            assertEq(t.remainder, remainder);
            assertEq(t.distributed, 0);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ReportCodec
    // ---------------------------------------------------------------------------------------------------------------

    /// Kills ROR ReportCodec.sol:118 (`< 32` to `<= 32`): a payload of exactly one word has a version.
    function test_Q57_versionOfReadsAOneWordPayload() public {
        assertEq(codec.versionOf(abi.encode(uint256(2))), 2);
        assertEq(codec.versionOf(abi.encode(uint256(77))), 77);
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.ReportPayloadTooShort.selector, 31));
        codec.versionOf(new bytes(31));
    }

    /// Kills SBR ReportCodec.sol:119 (version word decoded as uint128): a version above 2^128 is reported as an
    /// unsupported version, never as a malformed payload.
    function test_Q57_hugeVersionIsReportedAsUnsupportedVersion() public {
        uint256 version = uint256(type(uint128).max) + 2;
        ReportCodec.Report memory r;
        bytes memory payload = abi.encode(version, r);
        assertEq(codec.versionOf(payload), version);
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, version));
        codec.decode(payload);
    }

    /// Kills CR ReportCodec.sol:24 when the library is tested alone (in the full tree the Core Vault and the Spoke
    /// Vault already fail to compile without it): the window is 256 ids, shared by both vaults (OQ-09).
    function test_OQ09_arrivalWindowIs256() public pure {
        assertEq(ReportCodec.ARRIVAL_WINDOW, 256);
        assertEq(ReportCodec.VERSION, 5);
    }

    /// TransferKind values are part of the wire format of both codecs.
    function test_DEC092_transferKindWireValues() public pure {
        assertEq(uint8(TransferKind.Principal), 0);
        assertEq(uint8(TransferKind.Income), 1);
    }
}
