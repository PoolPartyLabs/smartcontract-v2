pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DollarIncomeIndex} from "../../../src/libraries/DollarIncomeIndex.sol";

contract IncomeEntryTimeTest is Test {
    using DollarIncomeIndex for DollarIncomeIndex.State;
    DollarIncomeIndex.State internal index;
    address internal constant TOKEN = address(123);
    address internal constant ANA = address(1);
    address internal constant BRUNO = address(2);
    uint256 internal supply;
    mapping(address => uint256) internal balance;
    mapping(address => uint256) internal paid;
    uint256 internal recognized;

    function setUp() public {
        index.registerToken(TOKEN);
    }

    function deposit(address holder, uint256 shares, uint256 timestamp) internal {
        settle(holder);
        index.wait(holder, shares, timestamp);
        balance[holder] += shares;
        supply += shares;
    }

    function settle(address holder) internal {
        assertTrue(index.settle(holder, balance[holder]));
    }

    function burn(address holder, uint256 shares) internal {
        settle(holder);
        index.onBurn(holder, index.burnWaiting(holder, shares));
        balance[holder] -= shares;
        supply -= shares;
    }

    function report(uint64 timestamp, uint256 income) internal {
        index.activate(timestamp);
        assertTrue(index.recognize(TOKEN, income, supply - index.waitingTotal));
        recognized += income;
    }

    function collect(address holder) internal {
        uint256[] memory sold = new uint256[](1);
        sold[0] = index.token[TOKEN].recognized;
        index.collect(sold, sold);
        settle(holder);
        paid[holder] += index.take(holder, type(uint256).max);
    }

    function check(uint256 ana, uint256 bruno) internal {
        collect(ANA);
        collect(BRUNO);
        assertApproxEqAbs(paid[ANA], ana * 1e6, 2);
        assertApproxEqAbs(paid[BRUNO], bruno * 1e6, 2);
        assertLe(paid[ANA] + paid[BRUNO], recognized);
        assertLe(recognized - paid[ANA] - paid[BRUNO], 4);
    }

    function test_doc08_delayedReports_50_10() public {
        deposit(ANA, 100, 0);
        report(100, 0);
        report(200, 10e6);
        deposit(BRUNO, 100, 450);
        report(300, 10e6);
        report(400, 10e6);
        report(500, 10e6);
        assertEq(index.tokenOwed(BRUNO, balance[BRUNO], TOKEN), 0);
        report(600, 10e6);
        report(700, 10e6);
        check(50, 10);
    }

    function test_doc08_topUpCollectionPartialWithdrawal_55_40() public {
        deposit(ANA, 100, 0);
        deposit(BRUNO, 100, 0);
        report(100, 0);
        report(200, 20e6);
        collect(ANA);
        deposit(ANA, 100, 250);
        report(300, 20e6);
        report(400, 30e6);
        burn(ANA, 50);
        report(500, 25e6);
        check(55, 40);
    }

    function test_doc08_waitingBurn_24_20() public {
        deposit(ANA, 100, 0);
        deposit(BRUNO, 100, 0);
        report(100, 0);
        deposit(ANA, 100, 150);
        burn(ANA, 60);
        report(200, 20e6);
        report(300, 24e6);
        check(24, 20);
    }

    function test_doc08_fullExitDelayedReport_10_30() public {
        deposit(ANA, 100, 0);
        deposit(BRUNO, 100, 0);
        report(100, 0);
        report(200, 20e6);
        burn(ANA, 100);
        collect(ANA);
        report(300, 20e6);
        check(10, 30);
    }

    function testFuzz_conservation(uint64 amount, uint32 first, uint32 second) public {
        uint256 ana = bound(first, 1, 1000);
        uint256 bruno = bound(second, 1, 1000);
        uint256 income = bound(amount, 1, 1e12);
        deposit(ANA, ana, 0);
        report(100, 0);
        deposit(BRUNO, bruno, 150);
        report(200, income);
        assertEq(index.tokenOwed(BRUNO, bruno, TOKEN), 0);
        report(300, income);
        collect(ANA);
        collect(BRUNO);
        assertLe(paid[ANA] + paid[BRUNO], recognized);
        assertLe(recognized - paid[ANA] - paid[BRUNO], 4);
    }

    function test_waitingTopUpsMergeAtNewestTime() public {
        deposit(ANA, 100, 0);
        report(100, 0);
        deposit(BRUNO, 10, 150);
        deposit(BRUNO, 10, 250);
        report(200, 10e6);
        report(300, 10e6);
        assertEq(index.tokenOwed(BRUNO, 20, TOKEN), 0);
        report(400, 12e6);
        check(30, 2);
    }

    function test_activationIsBounded() public {
        for (uint256 timestamp; timestamp < 40; ++timestamp) {
            deposit(address(uint160(timestamp + 1000)), 1, timestamp);
        }
        report(100, 0);
        assertEq(index.activationCursor, 1);
        report(200, 0);
        assertEq(index.activationCursor, 33);
        assertEq(index.waitingTotal, 7);
        report(300, 0);
        assertEq(index.waitingTotal, 0);
    }

    function test_activationGasAt32EntriesAnd16Tokens() public {
        for (uint256 token; token < 15; ++token) {
            index.registerToken(address(uint160(token + 2000)));
        }
        deposit(ANA, 1, 0);
        report(100, 0);
        for (uint256 token; token < index.tokens.length; ++token) {
            assertTrue(index.recognize(index.tokens[token], 1e6, 1));
        }
        for (uint256 timestamp = 101; timestamp <= 132; ++timestamp) {
            deposit(address(uint160(timestamp + 1000)), 1, timestamp);
        }
        report(200, 0);
        uint256 before = gasleft();
        index.activate(300);
        uint256 used = before - gasleft();
        emit log_named_uint("activation gas: 32 entries, 16 tokens", used);
        assertLt(used, 32_000_000);
        assertEq(index.waitingTotal, 0);
    }

    function test_activatedLotRetainsFrozenCollectionAfterBurn() public {
        deposit(ANA, 100, 0);
        report(100, 0);
        deposit(BRUNO, 100, 150);
        report(200, 10e6);
        report(300, 20e6);
        uint256[] memory sold = new uint256[](1);
        sold[0] = 30e6;
        uint64 frozen = index.freeze(sold);
        burn(BRUNO, 100);
        assertEq(index.owedDollars(BRUNO, 0), 0);
        index.finalizeFrozen(frozen, sold);
        assertApproxEqAbs(index.owedDollars(BRUNO, 0), 10e6, 1);
        collect(BRUNO);
        collect(ANA);
        assertApproxEqAbs(paid[BRUNO], 10e6, 1);
        assertApproxEqAbs(paid[ANA], 20e6, 1);
    }

    function test_activationBaselineSurvivesPartialAndDifferentPriceCollections() public {
        deposit(ANA, 100, 0);
        report(100, 0);
        report(200, 10e6);
        deposit(BRUNO, 100, 250);
        report(300, 10e6);
        report(400, 20e6);
        uint256[] memory sold = new uint256[](1);
        uint256[] memory obtained = new uint256[](1);
        sold[0] = 20e6;
        obtained[0] = 40e6;
        index.collect(sold, obtained);
        assertApproxEqAbs(index.owedDollars(BRUNO, 100), 10e6, 1);
        sold[0] = 20e6;
        obtained[0] = 60e6;
        index.collect(sold, obtained);
        assertApproxEqAbs(index.owedDollars(BRUNO, 100), 25e6, 4);
        settle(BRUNO);
        assertApproxEqAbs(index.take(BRUNO, type(uint256).max), 25e6, 4);
        settle(ANA);
        assertApproxEqAbs(index.take(ANA, type(uint256).max), 75e6, 2);
    }

    function test_moreThan64FrozenCollectionsSettleInBoundedCalls() public {
        deposit(ANA, 100, 0);
        report(100, 0);
        deposit(BRUNO, 100, 150);
        report(200, 10e6);
        report(300, 20e6);
        uint256[] memory sold = new uint256[](1);
        for (uint256 collection; collection < 70; ++collection) {
            if (collection == 0) {
                sold[0] = 30e6;
            } else {
                sold[0] = 2e6;
                report(uint64(400 + collection), 2e6);
            }
            index.freeze(sold);
        }
        assertFalse(index.settle(BRUNO, 100));
        bool complete;
        for (uint256 attempt; attempt < 8 && !complete; ++attempt) {
            complete = index.settle(BRUNO, 100);
        }
        assertTrue(complete);
        assertEq(index.holders[BRUNO].waitingShares, 0);
        for (uint64 collection = 1; collection <= 70; ++collection) {
            sold[0] = collection == 1 ? 30e6 : 2e6;
            index.finalizeFrozen(collection, sold);
        }
        assertFalse(index.settle(BRUNO, 100));
        assertTrue(index.settle(BRUNO, 100));
        assertApproxEqAbs(index.take(BRUNO, type(uint256).max), 79e6, 1);
    }

    function testFuzz_conservationWithTopUpBurnAndCollection(uint64 first, uint64 second, uint32 burnAmount) public {
        uint256 early = bound(first, 1, 1e12);
        uint256 later = bound(second, 1, 1e12);
        uint256 burned = bound(burnAmount, 1, 150);
        deposit(ANA, 100, 0);
        deposit(BRUNO, 100, 0);
        report(100, 0);
        report(200, early);
        collect(ANA);
        deposit(ANA, 100, 250);
        burn(ANA, burned);
        report(300, later);
        report(400, later);
        collect(ANA);
        collect(BRUNO);
        assertLe(paid[ANA] + paid[BRUNO], recognized);
        assertLe(recognized - paid[ANA] - paid[BRUNO], 12);
    }

    function test_frozenCaptureCarriesAdjustmentsWithinStepBudget() public {
        deposit(ANA, 100, 0);
        report(100, 0);
        report(200, 100e6);
        deposit(BRUNO, 100, 250);
        report(300, 0);
        report(400, 100e6);
        uint256[] memory sold = new uint256[](1);
        sold[0] = 1;
        for (uint256 collection; collection < 70; ++collection) {
            index.freeze(sold);
        }
        bool complete;
        for (uint256 attempt; attempt < 8 && !complete; ++attempt) {
            complete = index.settle(BRUNO, 100);
        }
        assertTrue(complete);
        assertLt(index.tokenOwed(BRUNO, 100, TOKEN), 50e6);
        assertGt(index.tokenOwed(BRUNO, 100, TOKEN), 49e6);
    }
}
