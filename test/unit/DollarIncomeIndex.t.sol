// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {DollarIncomeIndex} from "../../src/libraries/DollarIncomeIndex.sol";
import {DollarIncomeIndexHarness} from "../mocks/income/DollarIncomeIndexHarness.sol";

/// @dev Unit tests of the DEC-161 dollar income index. Amounts use real decimals: USDC 6, WETH 18, shares 18. The
///      numbered cases are those of doc 10 section 4 (`10-INDICE-EM-DOLAR-NA-HUB.md` in the spec repository).
contract DollarIncomeIndexTest is Test {
    DollarIncomeIndexHarness internal h;
    address internal usdc = makeAddr("usdc");
    address internal weth = makeAddr("weth");
    address internal ana = makeAddr("ana");
    address internal bruno = makeAddr("bruno");
    address internal caio = makeAddr("caio");

    uint8 internal constant SOURCE = 1;
    uint256 internal constant SHARE = 1e18;
    uint256 internal constant WETH = 1e18;
    uint256 internal constant USD = 1e6;
    /// @dev Storage slot of `State.rate` in the harness (`forge inspect DollarIncomeIndexHarness storageLayout`).
    uint256 internal constant RATE_SLOT = 4;

    function setUp() public {
        h = new DollarIncomeIndexHarness(SOURCE);
        h.registerToken(usdc);
        h.registerToken(weth);
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Collection selling `soldWeth` for `obtainedWeth` dollars; USDC income (if any) passes 1:1.
    function _collect(uint256 soldUsdc, uint256 soldWeth, uint256 obtainedWeth) internal returns (uint256) {
        uint256[] memory sold = new uint256[](2);
        uint256[] memory obtained = new uint256[](2);
        sold[0] = soldUsdc;
        obtained[0] = soldUsdc;
        sold[1] = soldWeth;
        obtained[1] = obtainedWeth;
        return h.collect(sold, obtained);
    }

    function _collectWeth(uint256 soldWeth, uint256 obtainedWeth) internal returns (uint256) {
        return _collect(0, soldWeth, obtainedWeth);
    }

    function _rateSlot(uint256 closedInterval, address token) internal pure returns (bytes32) {
        return keccak256(abi.encode(token, keccak256(abi.encode(closedInterval, RATE_SLOT))));
    }

    function _contains(bytes32[] memory slots, bytes32 slot) internal pure returns (bool) {
        for (uint256 i; i < slots.length; ++i) {
            if (slots[i] == slot) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ registration

    function test_DEC152_closedTokenListRegistration() public {
        assertTrue(h.isRegistered(usdc));
        assertTrue(h.isRegistered(weth));
        assertFalse(h.isRegistered(makeAddr("other")));
        assertEq(h.tokens().length, 2);
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.IncomeTokenAlreadyAdded.selector, usdc));
        h.registerToken(usdc);
        vm.expectRevert(DollarIncomeIndex.IncomeTokenZero.selector);
        h.registerToken(address(0));
    }

    function test_DEC152_tokenListIsBounded() public {
        for (uint256 i = 2; i < DollarIncomeIndex.MAX_TOKENS; ++i) {
            h.registerToken(address(uint160(1000 + i)));
        }
        vm.expectRevert(DollarIncomeIndex.IncomeTokenListFull.selector);
        h.registerToken(address(uint160(5000)));
    }

    function test_DEC161_registrationEmitsWithSource() public {
        DollarIncomeIndexHarness other = new DollarIncomeIndexHarness(2);
        address token = makeAddr("usdg");
        vm.expectEmit(true, true, false, true, address(other));
        emit DollarIncomeIndex.IncomeTokenAdded(2, token);
        other.registerToken(token);
    }

    // ------------------------------------------------------------------ doc 10 section 4 cases

    /// Doc 10 section 4, case 1 (DEC-161 journey): two collections at different prices. Ana and Bruno hold 100
    /// shares each; 0.10 WETH sold at 2,660 gives 266: the dollar index rises 1.33 per share, Ana takes 133 and Bruno's
    /// 133 stay on the Hub in his name. Then 0.04 WETH sold at 2,800 gives 112: the index rises 0.56 to 1.89, Bruno
    /// takes 189 and Ana has 56. DEC-161 item 3: paying by average would give Bruno 190.56 (doc 10 section 5).
    function test_DEC161_twoCollectionsAtDifferentPrices() public {
        h.mint(ana, 100 * SHARE);
        h.mint(bruno, 100 * SHARE);

        assertTrue(h.recognize(weth, (10 * WETH) / 100));
        assertApproxEqAbs(h.tokenOwed(ana, weth), (5 * WETH) / 100, 1);
        assertApproxEqAbs(h.tokenOwed(bruno, weth), (5 * WETH) / 100, 1);
        assertEq(_collectWeth((10 * WETH) / 100, 266 * USD), 0, "everything attributed");
        assertEq(h.interval(), 1);
        assertApproxEqAbs(Math.mulDiv(SHARE, h.dollarIndex(), DollarIncomeIndex.Q128), 133 * USD / 100, 1);
        assertEq(h.tokenOwed(ana, weth), 0, "the open interval restarts from zero");

        assertApproxEqAbs(h.take(ana, type(uint256).max), 133 * USD, 1);
        assertApproxEqAbs(h.owedDollars(bruno), 133 * USD, 1);

        assertTrue(h.recognize(weth, (4 * WETH) / 100));
        _collectWeth((4 * WETH) / 100, 112 * USD);
        assertApproxEqAbs(Math.mulDiv(SHARE, h.dollarIndex(), DollarIncomeIndex.Q128), 189 * USD / 100, 1);

        uint256 brunoTook = h.take(bruno, type(uint256).max);
        assertApproxEqAbs(brunoTook, 189 * USD, 2);
        assertLt(brunoTook, 190_560_000, "not paid by average (DEC-161 item 3)");
        assertApproxEqAbs(h.owedDollars(ana), 56 * USD, 1);

        (uint256 obtained, uint256 attributed, uint256 taken) = h.totals();
        assertEq(obtained, 378 * USD);
        assertLe(attributed, obtained);
        assertLe(h.owedDollars(ana) + taken, attributed);
    }

    /// Doc 10 section 4, case 2: an entrant in the middle of the interval. Ana and Bruno hold 100 shares; the fund
    /// earns 0.02 WETH; Caio enters with 100; the fund earns 0.03 WETH more; 0.05 WETH sold at 2,800 gives 140.
    /// Ana and Bruno get 56 each; Caio gets 56 minus his adjustment of 0.01 WETH at 2,800 = 28; the sum is 140.
    function test_DEC014_entrantMidIntervalTakesNothingBeforeEntry() public {
        h.mint(ana, 100 * SHARE);
        h.mint(bruno, 100 * SHARE);
        h.recognize(weth, (2 * WETH) / 100);
        h.mint(caio, 100 * SHARE);
        assertEq(h.tokenOwed(caio, weth), 0, "DEC-014: nothing of the income before the entry");
        assertEq(h.adjustment(caio, weth), -int256(WETH / 100), "adjustment = -minted x open index");
        (,,, bool adjusted) = h.holderState(caio);
        assertTrue(adjusted);
        h.recognize(weth, (3 * WETH) / 100);

        assertApproxEqAbs(h.tokenOwed(ana, weth), (2 * WETH) / 100, 2);
        assertApproxEqAbs(h.tokenOwed(bruno, weth), (2 * WETH) / 100, 2);
        assertApproxEqAbs(h.tokenOwed(caio, weth), WETH / 100, 2);

        _collectWeth((5 * WETH) / 100, 140 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 56 * USD, 1);
        assertApproxEqAbs(h.owedDollars(bruno), 56 * USD, 1);
        assertApproxEqAbs(h.owedDollars(caio), 28 * USD, 2);
        assertLe(h.owedDollars(ana) + h.owedDollars(bruno) + h.owedDollars(caio), 140 * USD);
        assertEq(h.rateAt(0, weth), Math.mulDiv(140 * USD, DollarIncomeIndex.Q128, (5 * WETH) / 100));
    }

    /// Doc 10 section 4, case 2 continued (DEC-161 item 2): Caio comes back only after two more collections, at 3,000
    /// and 2,500. His 0.01 WETH adjustment must convert at the 2,800 of the collection that closed his interval:
    /// 28 + 30 + 25 = 83. Ana, who never moved shares, gets 56 + 30 + 25 = 111.
    function test_DEC161_adjustmentConvertsAtTheStoredRateAfterLaterCollections() public {
        test_DEC014_entrantMidIntervalTakesNothingBeforeEntry();
        h.recognize(weth, (3 * WETH) / 100);
        _collectWeth((3 * WETH) / 100, 90 * USD);
        h.recognize(weth, (3 * WETH) / 100);
        _collectWeth((3 * WETH) / 100, 75 * USD);
        assertEq(h.interval(), 3);

        assertApproxEqAbs(h.owedDollars(caio), 83 * USD, 3);
        assertApproxEqAbs(h.owedDollars(ana), 111 * USD, 3);
        assertApproxEqAbs(h.owedDollars(bruno), 111 * USD, 3);
        assertLe(h.owedDollars(ana) + h.owedDollars(bruno) + h.owedDollars(caio), 305 * USD);

        h.settle(caio);
        (uint256 dollars, uint256 mark, uint64 tag, bool adjusted) = h.holderState(caio);
        assertApproxEqAbs(dollars, 83 * USD, 3);
        assertEq(mark, h.dollarIndex());
        assertEq(tag, 3);
        assertFalse(adjusted, "adjustments cleared once converted");
        assertEq(h.adjustment(caio, weth), 0);
    }

    /// DEC-152 journey: a position earns 1,000 USDC and 0.5 WETH; Ana holds 10% of the shares. She is attributed 100
    /// USDC and 0.05 WETH; the collection sells the WETH at 2,660: the 0.05 become 133 and Ana receives 233.
    function test_DEC152_perTokenAttributionConvertedAtCollection() public {
        h.mint(ana, 10 * SHARE);
        h.mint(bruno, 90 * SHARE);
        h.recognize(usdc, 1000 * USD);
        h.recognize(weth, WETH / 2);
        assertApproxEqAbs(h.tokenOwed(ana, usdc), 100 * USD, 1);
        assertApproxEqAbs(h.tokenOwed(ana, weth), (5 * WETH) / 100, 1);
        _collect(1000 * USD, WETH / 2, 1330 * USD);
        assertEq(h.rateAt(0, usdc), DollarIncomeIndex.Q128, "a dollar token converts 1:1");
        assertApproxEqAbs(h.take(ana, type(uint256).max), 233 * USD, 2);
        assertApproxEqAbs(h.owedDollars(bruno), 2097 * USD, 2);
    }

    // ------------------------------------------------------------------ holders who move shares

    /// DEC-014, DEC-045: burned shares keep what they earned in the open interval until the burn, converted at the
    /// collection that closes it; income recognized after the burn reaches only the remaining shares.
    function test_DEC045_burnerKeepsIntervalIncomeUntilTheBurn() public {
        h.mint(ana, 100 * SHARE);
        h.mint(bruno, 100 * SHARE);
        h.recognize(weth, (10 * WETH) / 100);
        h.burn(ana, 100 * SHARE);
        assertEq(h.sharesOf(ana), 0);
        assertApproxEqAbs(h.tokenOwed(ana, weth), (5 * WETH) / 100, 1);
        h.recognize(weth, (10 * WETH) / 100);
        assertApproxEqAbs(h.tokenOwed(ana, weth), (5 * WETH) / 100, 1, "nothing after the burn");
        assertApproxEqAbs(h.tokenOwed(bruno, weth), (15 * WETH) / 100, 2);
        _collectWeth((20 * WETH) / 100, 532 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 133 * USD, 2);
        assertApproxEqAbs(h.owedDollars(bruno), 399 * USD, 2);
        h.recognize(weth, WETH);
        _collectWeth(WETH, 2660 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 133 * USD, 2, "a leaver earns nothing after the exit");
        assertApproxEqAbs(h.take(ana, type(uint256).max), 133 * USD, 2);
        assertEq(h.owedDollars(ana), 0);
    }

    /// DEC-014: a holder who adds shares mid-interval earns on the old shares for the whole interval and on the new
    /// ones only from the mint; a partial burn later in the same interval keeps the burned shares' part until then.
    function test_DEC014_increaseThenPartialBurnInOneInterval() public {
        h.mint(ana, 100 * SHARE);
        h.mint(bruno, 100 * SHARE);
        h.recognize(weth, (2 * WETH) / 100); // 0.0001 per share
        h.mint(ana, 100 * SHARE); // ana 200, supply 300
        h.recognize(weth, (3 * WETH) / 100); // 0.0001 per share
        h.burn(ana, 50 * SHARE); // ana 150, supply 250
        h.recognize(weth, (5 * WETH) / 1000); // 0.00002 per share
        // ana: 100 x 0.0001 + 200 x 0.0001 + 150 x 0.00002 = 0.033; bruno: 0.01 + 0.01 + 0.002 = 0.022
        assertApproxEqAbs(h.tokenOwed(ana, weth), (33 * WETH) / 1000, 3);
        assertApproxEqAbs(h.tokenOwed(bruno, weth), (22 * WETH) / 1000, 3);
        // The burn's credit cancels the mint's debit at these indices, up to the rounding against the holder.
        assertLe(h.adjustment(ana, weth), 0);
        assertGe(h.adjustment(ana, weth), -1);
        _collectWeth((55 * WETH) / 1000, 154 * USD); // 2,800
        assertApproxEqAbs(h.owedDollars(ana), 92_400_000, 3);
        assertApproxEqAbs(h.owedDollars(bruno), 61_600_000, 3);
    }

    /// Doc 10 sections 1 and 3: the rate record is read only for holders who moved shares during the interval. A
    /// holder who held through is settled by the dollar index alone and reads no stored rate.
    function test_DEC161_rateIsReadOnlyByHoldersWhoMovedShares() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, (2 * WETH) / 100);
        h.mint(caio, 100 * SHARE);
        h.recognize(weth, (2 * WETH) / 100);
        _collectWeth((4 * WETH) / 100, 112 * USD);
        bytes32 slot = _rateSlot(0, weth);
        assertEq(uint256(vm.load(address(h), slot)), h.rateAt(0, weth), "slot computation matches the layout");

        vm.record();
        h.settle(ana);
        (bytes32[] memory reads,) = vm.accesses(address(h));
        assertFalse(_contains(reads, slot), "a holder who did not move shares reads no rate");

        vm.record();
        h.settle(caio);
        (reads,) = vm.accesses(address(h));
        assertTrue(_contains(reads, slot), "the entrant's adjustment reads the stored rate");
    }

    // ------------------------------------------------------------------ collection edge cases

    /// DEC-014 (collecting later does not change the beneficiary): when a collection sells less than the interval
    /// recognized, every claim converts the same fraction at the sale price and each holder keeps the rest of their
    /// own claim in the next interval. The entrant, whose claim on the interval was zero, gets nothing of it.
    function test_DEC014_partialSaleKeepsEachHoldersUnsoldClaim() public {
        h.mint(ana, 100 * SHARE);
        h.mint(bruno, 100 * SHARE);
        h.recognize(weth, (10 * WETH) / 100);
        h.mint(caio, 100 * SHARE); // adjustment -0.05 WETH
        // Sells 0.06 of the 0.10 WETH at 2,800 for 168: each claim converts 60% at 2,800 (1,680 per claimed WETH).
        assertLe(_collectWeth((6 * WETH) / 100, 168 * USD), 1);
        assertApproxEqAbs(h.owedDollars(ana), 84 * USD, 1);
        assertApproxEqAbs(h.owedDollars(bruno), 84 * USD, 1);
        assertLe(h.owedDollars(caio), 1, "the entrant's claim on the interval was zero");
        assertEq(h.rateAt(0, weth), Math.mulDiv(168 * USD, DollarIncomeIndex.Q128, (10 * WETH) / 100));
        assertEq(h.carryAt(0, weth), Math.mulDiv(4, DollarIncomeIndex.Q128, 10));
        // 40% of each claim stays with its holder: 0.02 WETH for Ana and for Bruno, nothing for Caio.
        DollarIncomeIndex.IncomeToken memory t = h.incomeToken(weth);
        assertEq(t.interval, 1);
        assertEq(t.recognized, (4 * WETH) / 100);
        assertApproxEqAbs(h.tokenOwed(ana, weth), (2 * WETH) / 100, 1);
        assertApproxEqAbs(h.tokenOwed(bruno, weth), (2 * WETH) / 100, 1);
        assertLe(h.tokenOwed(caio, weth), 1, "nothing of the unsold part for the entrant");
        uint256 tokenSum = h.tokenOwed(ana, weth) + h.tokenOwed(bruno, weth) + h.tokenOwed(caio, weth);
        assertLe(tokenSum, (4 * WETH) / 100);
        assertApproxEqAbs(tokenSum, (4 * WETH) / 100, 3);
        // The carried units sell at the next collection at 3,000: 60 more for Ana and for Bruno, nothing for Caio.
        _collectWeth((4 * WETH) / 100, 120 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 144 * USD, 2);
        assertApproxEqAbs(h.owedDollars(bruno), 144 * USD, 2);
        assertLe(h.owedDollars(caio), 2);
        h.settle(caio);
        (,,, bool adjusted) = h.holderState(caio);
        assertFalse(adjusted, "the carried adjustment converted at the full sale");
    }

    /// Review M-1 regression (DEC-014, DEC-138, S-15): an entrant after the recognition takes nothing of the
    /// interval's income when a collection leaves it unsold. Ana holds 100 shares; the fund earns 1 WETH; Mallory mints
    /// 900; a collection does not sell the WETH; Mallory burns her 900; the next collection sells the WETH at 2,800.
    /// Ana gets the 2,800 and Mallory nothing (re-spreading the unsold units over the shares gave Mallory 2,520).
    function test_DEC014_entrantTakesNothingOfIncomeLeftUnsold() public {
        address mallory = makeAddr("mallory");
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH);
        h.mint(mallory, 900 * SHARE);
        assertEq(h.tokenOwed(mallory, weth), 0);
        _collectWeth(0, 0);
        assertEq(h.tokenOwed(mallory, weth), 0, "the unsold interval stays open with the entrant's adjustment");
        h.burn(mallory, 900 * SHARE);
        _collectWeth(WETH, 2800 * USD);
        assertLe(h.owedDollars(mallory), 1);
        assertApproxEqAbs(h.owedDollars(ana), 2800 * USD, 1);
    }

    /// The same entrant through a partial sale: half the WETH sells at 2,800 before Mallory leaves. Her adjustment
    /// carries its unsold half into the next interval, where it cancels her shares' part of the carried index.
    function test_DEC014_entrantTakesNothingThroughAPartialSale() public {
        address mallory = makeAddr("mallory");
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH);
        h.mint(mallory, 900 * SHARE);
        _collectWeth(WETH / 2, 1400 * USD);
        assertLe(h.owedDollars(mallory), 1);
        assertLe(h.tokenOwed(mallory, weth), 1);
        assertApproxEqAbs(h.tokenOwed(ana, weth), WETH / 2, 1);
        h.burn(mallory, 900 * SHARE);
        _collectWeth(WETH / 2, 1400 * USD);
        assertLe(h.owedDollars(mallory), 2);
        assertApproxEqAbs(h.owedDollars(ana), 2800 * USD, 2);
    }

    /// Review M-1 regression (DEC-045): a holder who burns every share keeps what they earned in the interval when a
    /// collection leaves it unsold. Ana and Bruno hold 100 shares each; the fund earns 0.10 WETH; Ana leaves; a
    /// collection does not sell; the next one sells at 2,800: 140 each (re-spreading gave Ana 0 and Bruno 280).
    function test_DEC045_fullExitKeepsIncomeLeftUnsold() public {
        h.mint(ana, 100 * SHARE);
        h.mint(bruno, 100 * SHARE);
        h.recognize(weth, (10 * WETH) / 100);
        h.burn(ana, 100 * SHARE);
        _collectWeth(0, 0);
        assertApproxEqAbs(h.tokenOwed(ana, weth), (5 * WETH) / 100, 1);
        _collectWeth((10 * WETH) / 100, 280 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 140 * USD, 1);
        assertApproxEqAbs(h.owedDollars(bruno), 140 * USD, 1);
    }

    /// DEC-045 at zero supply, through a partial sale: Ana burns every share, so no share is left when a collection
    /// sells 0.04 of the 0.10 WETH at 2,800. She gets 112 and keeps 0.06 WETH, which sell at the next collection.
    function test_DEC045_fullExitAtZeroSupplyKeepsTheUnsoldRest() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, (10 * WETH) / 100);
        h.burn(ana, 100 * SHARE);
        assertEq(h.totalShares(), 0);
        _collectWeth((4 * WETH) / 100, 112 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 112 * USD, 1);
        assertApproxEqAbs(h.tokenOwed(ana, weth), (6 * WETH) / 100, 1);
        assertEq(h.incomeToken(weth).recognized, (6 * WETH) / 100);
        _collectWeth((6 * WETH) / 100, 168 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 280 * USD, 2);
        assertApproxEqAbs(h.take(ana, type(uint256).max), 280 * USD, 2);
    }

    /// A token the collection does not sell (`sold == 0`, a refused or failed sale) keeps its interval open: no rate
    /// is stored, its index and recognized units stay, and the next sale converts the whole interval.
    function test_DEC161_unsoldTokenStaysInItsOpenInterval() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        h.recognize(usdc, 50 * USD);
        uint256 index = h.incomeToken(weth).openIndex;
        vm.expectEmit(true, true, true, true, address(h));
        emit DollarIncomeIndex.IntervalIncomeUnsold(SOURCE, 0, weth, WETH / 10);
        assertEq(_collect(50 * USD, 0, 0), 0);
        assertEq(h.interval(), 1, "the collection interval closes");
        DollarIncomeIndex.IncomeToken memory t = h.incomeToken(weth);
        assertEq(t.interval, 0, "the WETH interval stays open");
        assertEq(t.openIndex, index);
        assertEq(t.recognized, WETH / 10);
        assertEq(h.incomeToken(usdc).interval, 1);
        assertEq(h.rateAt(0, weth), 0);
        assertApproxEqAbs(h.owedDollars(ana), 50 * USD, 1);
        assertApproxEqAbs(h.tokenOwed(ana, weth), WETH / 10, 1);
        _collectWeth(WETH / 10, 266 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 316 * USD, 2);
    }

    /// Refused or failed sales add no conversion step: after 100 collections that did not sell the WETH, an entrant's
    /// settlement reads no stored rate, and the sale converts the whole interval at its own rate.
    function test_DEC161_unsoldCollectionsAddNoConversionStep() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        h.mint(caio, 100 * SHARE);
        _collect(0, 0, 0);
        vm.record();
        h.settle(caio);
        (bytes32[] memory afterOne,) = vm.accesses(address(h));
        for (uint256 i; i < 99; ++i) {
            _collect(0, 0, 0);
        }
        vm.record();
        h.settle(caio);
        (bytes32[] memory reads,) = vm.accesses(address(h));
        assertFalse(_contains(reads, _rateSlot(0, weth)), "no conversion while the WETH interval is open");
        assertEq(reads.length, afterOne.length, "the settlement does not walk the collections");
        assertEq(h.adjustmentInterval(caio, weth), 0);
        assertEq(h.adjustment(caio, weth), -int256(WETH / 10));
        _collectWeth(WETH / 10, 266 * USD);
        assertApproxEqAbs(h.owedDollars(ana), 266 * USD, 1);
        assertLe(h.owedDollars(caio), 1);
    }

    /// Bound: an adjustment carried across more partial sales than `MAX_SETTLE_STEPS` converts over several `settle`
    /// calls. Until the last one, the hooks and `take` refuse the holder; progress is kept, and the result equals the
    /// unbounded view.
    function test_DEC161_settleStopsAtTheStepBoundAndResumes() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH);
        h.burn(ana, 50 * SHARE); // +0.5 WETH adjustment on WETH interval 0
        uint256 sales = DollarIncomeIndex.MAX_SETTLE_STEPS + 6;
        for (uint256 i; i < sales; ++i) {
            // Each collection sells a tenth of the open interval at 2,000 per WETH.
            uint256 part = h.incomeToken(weth).recognized / 10;
            _collectWeth(part, Math.mulDiv(part, 2000 * USD, WETH));
        }
        uint256 owed = h.owedDollars(ana);
        assertGt(owed, 0);

        assertFalse(h.settleRaw(ana, 50 * SHARE), "the bound stops the first call");
        assertEq(h.adjustmentInterval(ana, weth), DollarIncomeIndex.MAX_SETTLE_STEPS, "progress is kept");
        (, uint256 mark, uint64 settledAt,) = h.holderState(ana);
        assertEq(mark, h.dollarIndex());
        assertEq(settledAt, 0, "not settled in the open interval");
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.HolderNotSettled.selector, ana));
        h.onBurnRaw(ana, SHARE);
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.HolderNotSettled.selector, ana));
        h.takeRaw(ana, 1);
        assertEq(h.owedDollars(ana), owed, "the view is unchanged by the partial settlement");

        assertTrue(h.settleRaw(ana, 50 * SHARE), "the second call completes");
        (uint256 dollars,, uint64 settledNow, bool adjusted) = h.holderState(ana);
        assertEq(settledNow, h.interval());
        assertEq(dollars, owed, "the same dollars as the unbounded view");
        assertTrue(adjusted, "the unsold rest stays as an adjustment of the open interval");
        assertEq(h.adjustmentInterval(ana, weth), sales);
        assertEq(h.takeRaw(ana, type(uint256).max), owed);
    }

    /// A sale above what holders were recognized (the fee's units, income recognized at zero supply) converts the
    /// holders' units at the sale rate and returns the dollars of the rest as unattributed.
    function test_DEC161_saleAboveRecognizedReturnsUnattributedDollars() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        uint256 unattributed = _collectWeth((15 * WETH) / 100, 399 * USD);
        assertApproxEqAbs(unattributed, 133 * USD, 1);
        assertApproxEqAbs(h.owedDollars(ana), 266 * USD, 1);
        (uint256 obtained, uint256 attributed,) = h.totals();
        assertEq(obtained, 399 * USD);
        assertEq(obtained - attributed, unattributed);
        assertEq(h.incomeToken(weth).recognized, 0, "nothing carried");
    }

    /// Income sold with nothing recognized is wholly unattributed and moves no index.
    function test_DEC161_saleWithNothingRecognizedIsUnattributed() public {
        h.mint(ana, 100 * SHARE);
        assertEq(_collectWeth(WETH, 2660 * USD), 2660 * USD);
        assertEq(h.dollarIndex(), 0);
        assertEq(h.rateAt(0, weth), 0, "no rate stored without an open index");
        assertEq(h.owedDollars(ana), 0);
    }

    /// An empty collection still closes the interval (one collection, one interval) and changes no balance.
    function test_DEC161_emptyCollectionClosesTheInterval() public {
        h.mint(ana, 100 * SHARE);
        vm.expectEmit(true, true, false, true, address(h));
        emit DollarIncomeIndex.IncomeIntervalClosed(SOURCE, 0, 0, 0, 0);
        assertEq(_collect(0, 0, 0), 0);
        assertEq(h.interval(), 1);
        assertEq(h.owedDollars(ana), 0);
    }

    function test_DEC161_collectRejectsMisalignedArrays() public {
        uint256[] memory one = new uint256[](1);
        uint256[] memory two = new uint256[](2);
        vm.expectRevert(DollarIncomeIndex.CollectionLengthMismatch.selector);
        h.collect(one, two);
        vm.expectRevert(DollarIncomeIndex.CollectionLengthMismatch.selector);
        h.collect(two, one);
    }

    /// Review L-1: dollars obtained for a token that was not sold are an inconsistent input (a dollar token passes
    /// `sold == obtained`). Accepting it would book dollars no sale produced; the collection reverts instead.
    function test_DEC161_collectRejectsDollarsWithoutASale() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(usdc, 100 * USD);
        uint256[] memory sold = new uint256[](2);
        uint256[] memory obtained = new uint256[](2);
        obtained[0] = 100 * USD;
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.InconsistentCollection.selector, usdc));
        h.collect(sold, obtained);
        // Also with nothing recognized.
        obtained[0] = 0;
        obtained[1] = 1;
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.InconsistentCollection.selector, weth));
        h.collect(sold, obtained);
    }

    function test_DEC161_collectEmitsPerTokenConversion() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        uint256 rate = Math.mulDiv(266 * USD, DollarIncomeIndex.Q128, WETH / 10);
        vm.expectEmit(true, true, true, true, address(h));
        emit DollarIncomeIndex.IntervalIncomeConverted(SOURCE, 0, weth, WETH / 10, 266 * USD, rate, 0);
        _collectWeth(WETH / 10, 266 * USD);
    }

    // ------------------------------------------------------------------ recognition

    function test_DEC138_recognitionEmitsAndAdvancesTheOpenIndex() public {
        h.mint(ana, 100 * SHARE);
        uint256 index = Math.mulDiv(WETH / 10, DollarIncomeIndex.Q128, 100 * SHARE);
        vm.expectEmit(true, true, false, true, address(h));
        emit DollarIncomeIndex.IntervalIncomeRecognized(SOURCE, weth, WETH / 10, index);
        assertTrue(h.recognize(weth, WETH / 10));
        DollarIncomeIndex.IncomeToken memory t = h.incomeToken(weth);
        assertEq(t.openIndex, index);
        assertEq(t.recognized, WETH / 10);
    }

    /// At zero supply nothing enters the index; the library returns false and lets the caller decide.
    function test_DEC138_recognitionAtZeroSupplyReturnsFalse() public {
        assertFalse(h.recognize(weth, WETH));
        assertEq(h.incomeToken(weth).recognized, 0);
        assertTrue(h.recognize(weth, 0), "a zero amount is a no-op");
    }

    /// Recognition never reverts (DEC-117 item 1: never blocks a mint or a burn): unknown tokens, amounts above
    /// MAX_STEP and index overflows are skipped with an event.
    function test_DEC117_recognitionSkipsWithEventAndNeverReverts() public {
        h.mint(ana, 1); // harness only: a one-unit supply drives the index to the overflow edge
        address other = makeAddr("other");
        vm.expectEmit(true, true, false, true, address(h));
        emit DollarIncomeIndex.IntervalIncomeSkipped(SOURCE, other, 5);
        assertFalse(h.recognize(other, 5));

        uint256 tooBig = DollarIncomeIndex.MAX_STEP + 1;
        vm.expectEmit(true, true, false, true, address(h));
        emit DollarIncomeIndex.IntervalIncomeSkipped(SOURCE, weth, tooBig);
        assertFalse(h.recognize(weth, tooBig));

        assertTrue(h.recognize(weth, DollarIncomeIndex.MAX_STEP));
        DollarIncomeIndex.IncomeToken memory before = h.incomeToken(weth);
        vm.expectEmit(true, true, false, true, address(h));
        emit DollarIncomeIndex.IntervalIncomeSkipped(SOURCE, weth, DollarIncomeIndex.MAX_STEP);
        assertFalse(h.recognize(weth, DollarIncomeIndex.MAX_STEP));
        DollarIncomeIndex.IncomeToken memory later = h.incomeToken(weth);
        assertEq(later.openIndex, before.openIndex);
        assertEq(later.recognized, before.recognized);
    }

    /// The remainder of the division is carried within the interval: many small recognitions lose nothing beyond
    /// the final rounding.
    function test_DEC138_remainderCarriedWithinTheInterval() public {
        h.mint(ana, 3 * SHARE);
        for (uint256 i; i < 500; ++i) {
            h.recognize(usdc, 1);
        }
        assertLt(h.incomeToken(usdc).remainder, 3 * SHARE);
        assertGe(h.tokenOwed(ana, usdc), 499);
        assertLe(h.tokenOwed(ana, usdc), 500);
    }

    // ------------------------------------------------------------------ settlement and take

    /// The hooks refuse to adjust a holder that was not settled in the open interval: an adjustment applied against
    /// a stale mark would mix two intervals.
    function test_DEC161_hooksRequireASettledHolder() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        _collectWeth(WETH / 10, 266 * USD);
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.HolderNotSettled.selector, bruno));
        h.onMintRaw(bruno, SHARE);
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.HolderNotSettled.selector, ana));
        h.onBurnRaw(ana, SHARE);

        h.settleRaw(bruno, 0);
        _collectWeth(0, 0); // a collection between the settlement and the hook
        vm.expectRevert(abi.encodeWithSelector(DollarIncomeIndex.HolderNotSettled.selector, bruno));
        h.onMintRaw(bruno, SHARE);
    }

    function test_DEC124_takeIsCappedAndCounted() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        _collectWeth(WETH / 10, 266 * USD);
        uint256 owed = h.owedDollars(ana);
        assertEq(h.take(ana, 40 * USD), 40 * USD);
        assertEq(h.owedDollars(ana), owed - 40 * USD);
        (,, uint256 taken) = h.totals();
        assertEq(taken, 40 * USD);
        assertEq(h.take(bruno, type(uint256).max), 0, "nothing owed, nothing taken");
    }

    /// A settled holder's view and state agree; settling twice changes nothing.
    function test_DEC161_settleIsIdempotent() public {
        h.mint(ana, 100 * SHARE);
        h.recognize(weth, WETH / 10);
        h.mint(bruno, 50 * SHARE);
        h.recognize(weth, WETH / 10);
        _collectWeth((2 * WETH) / 10, 532 * USD);
        uint256 viewed = h.owedDollars(bruno);
        h.settle(bruno);
        (uint256 dollars,,,) = h.holderState(bruno);
        assertEq(dollars, viewed);
        h.settle(bruno);
        (uint256 again,,,) = h.holderState(bruno);
        assertEq(again, dollars);
    }

    // ------------------------------------------------------------------ fuzz

    /// DEC-161 conservation: with an entrant and a burner moving shares in the middle of two intervals sold at
    /// different prices, the holders together are never owed more than the sales obtained, and each holder is within
    /// rounding of the per-holder computation.
    function testFuzz_DEC161_entrantAndBurnerAcrossCollections(
        uint256 sharesA,
        uint256 sharesB,
        uint256 sharesC,
        uint256 income1,
        uint256 income2,
        uint256 price1,
        uint256 price2
    ) public {
        FuzzCase memory c;
        c.sharesA = bound(sharesA, 1, 1e9) * SHARE;
        c.sharesB = bound(sharesB, 1, 1e9) * SHARE;
        c.sharesC = bound(sharesC, 1, 1e9) * SHARE;
        c.income1 = bound(income1, 1, 1e24);
        c.income2 = bound(income2, 1, 1e24);
        price1 = bound(price1, 1, 10_000); // USD per WETH
        price2 = bound(price2, 1, 10_000);

        h.mint(ana, c.sharesA);
        h.mint(bruno, c.sharesB);
        h.recognize(weth, c.income1);
        h.mint(caio, c.sharesC); // entrant
        h.burn(bruno, c.sharesB); // burner
        h.recognize(weth, c.income2);
        c.obtained1 = Math.mulDiv(c.income1 + c.income2, price1, 1e12);
        _collectWeth(c.income1 + c.income2, c.obtained1);
        h.recognize(weth, c.income2);
        c.obtained2 = Math.mulDiv(c.income2, price2, 1e12);
        _collectWeth(c.income2, c.obtained2);

        // Per-holder expected dollars, computed holder by holder.
        uint256 s1 = c.sharesA + c.sharesB;
        uint256 s2 = c.sharesA + c.sharesC;
        uint256 tolerance = 6 + Math.ceilDiv(price1 + price2, 1e12) * 4;
        uint256 anaTokens1 = Math.mulDiv(c.income1, c.sharesA, s1) + Math.mulDiv(c.income2, c.sharesA, s2);
        assertApproxEqAbs(
            h.owedDollars(ana), _expected(c, anaTokens1, Math.mulDiv(c.income2, c.sharesA, s2)), tolerance
        );
        assertApproxEqAbs(h.owedDollars(bruno), _expected(c, Math.mulDiv(c.income1, c.sharesB, s1), 0), tolerance);
        uint256 caioTokens = Math.mulDiv(c.income2, c.sharesC, s2);
        assertApproxEqAbs(h.owedDollars(caio), _expected(c, caioTokens, caioTokens), tolerance);
        uint256 owedSum = h.owedDollars(ana) + h.owedDollars(bruno) + h.owedDollars(caio);
        (uint256 obtained, uint256 attributed,) = h.totals();
        assertLe(owedSum, attributed, "never more than attributed");
        assertLe(attributed, obtained, "never more than obtained");
    }

    struct FuzzCase {
        uint256 sharesA;
        uint256 sharesB;
        uint256 sharesC;
        uint256 income1;
        uint256 income2;
        uint256 obtained1;
        uint256 obtained2;
    }

    /// @dev Dollars of a holder whose claims were `tokens1` in the first interval and `tokens2` in the second.
    function _expected(FuzzCase memory c, uint256 tokens1, uint256 tokens2) internal pure returns (uint256) {
        return Math.mulDiv(tokens1, c.obtained1, c.income1 + c.income2) + Math.mulDiv(tokens2, c.obtained2, c.income2);
    }

    /// Bounds: at the largest realistic open index (one whole share outstanding, MAX_STEP of income) a mint of the
    /// largest realistic supply, the collection and the settlements never revert.
    function test_DEC161_extremeIndexNeverRevertsTheHooks() public {
        h.mint(ana, SHARE);
        assertTrue(h.recognize(weth, DollarIncomeIndex.MAX_STEP));
        h.mint(bruno, 1e15 * SHARE);
        h.burn(bruno, 1e14 * SHARE);
        assertTrue(h.recognize(weth, DollarIncomeIndex.MAX_STEP));
        _collectWeth(2 * DollarIncomeIndex.MAX_STEP, 1e30);
        h.settle(ana);
        h.settle(bruno);
        (uint256 obtained, uint256 attributed,) = h.totals();
        assertLe(h.owedDollars(ana) + h.owedDollars(bruno), attributed);
        assertLe(attributed, obtained);
    }
}
