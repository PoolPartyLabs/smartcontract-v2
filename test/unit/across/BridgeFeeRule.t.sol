// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {BridgeFeeRule} from "../../../src/libraries/BridgeFeeRule.sol";
import {BridgeFeeRuleHarness} from "../../mocks/across/BridgeFeeRuleHarness.sol";

/// @notice DEC-162 bridge fee rule on its own (founder direction of 2026-10-02, checklist doc 12): the mean of the
///         route's last 3 sends, a hard cap, and one step up after an expiry so value is never held back by a fee too
///         low for relayers.
/// @dev Doc 12 §5's tables are replayed at bands 25 / 50 / 100% with the reference starting at the market (0.06%) and
///      a floor of 1 wei, as in doc 12's Python model and the research prototype (branch
///      test/pp-sc-test-bridge-fee-research), which this rule reproduces exactly. Rates are WAD fractions.
contract BridgeFeeRuleTest is Test {
    uint256 internal constant MARKET = 6e14; // 0.06%, measured 2026-10-02 (bridge fee research)
    uint256 internal constant CAP = 1e16;

    /// @dev Doc 12 `expirados`: 6 transfers against a market at `market`; expired sends until each one lands.
    function _ruleExpiries(uint256 band, uint256 market) internal returns (uint256 failures) {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(MARKET, 1, CAP, band);
        for (uint256 i; i < 6; ++i) {
            while (true) {
                (uint64 serial, uint256 rate) = h.send();
                if (rate >= market) break;
                ++failures;
                h.noteExpiry(serial, rate);
            }
        }
    }

    // ------------------------------------------------------------------ doc 12 §5, the stuck-fee case

    /// Doc 12 §5: the market doubles (0.12%). Without the API, each expiry steps the next send one band up: 7 / 4 / 3
    /// expired sends (band 25 / 50 / 100%) over six transfers, about 7.4 h each.
    function test_DEC162_doc12_marketDoubles_expiriesUntilDelivered() public {
        assertEq(_ruleExpiries(0.25e18, 12e14), 7, "band 25%");
        assertEq(_ruleExpiries(0.5e18, 12e14), 4, "band 50%");
        assertEq(_ruleExpiries(1e18, 12e14), 3, "band 100%");
    }

    /// Doc 12 §5: the market rises 40% (0.084%): 4 / 2 / 2 expired sends without the API.
    function test_DEC162_doc12_marketRises40Percent_expiriesUntilDelivered() public {
        assertEq(_ruleExpiries(0.25e18, 84e13), 4, "band 25%");
        assertEq(_ruleExpiries(0.5e18, 84e13), 2, "band 50%");
        assertEq(_ruleExpiries(1e18, 84e13), 2, "band 100%");
    }

    // ------------------------------------------------------------------ the window

    /// DEC-162: the reference is the mean of the last 3 sends, each missing one counted at the initial rate.
    function test_DEC162_referenceIsTheMeanPaddedWithTheInitialRate() public {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, 0.5e18);
        assertEq(h.referenceRate(), 8e14, "empty window: the initial rate");
        (uint64 serial, uint256 rate) = h.send();
        h.noteExpiry(serial, rate); // 0.08% expired: the next send is 0.12%
        h.send();
        assertEq(h.referenceRate(), (12e14 + 8e14 + 8e14) / uint256(3), "one send, two initial entries");
    }

    /// DEC-162: only the route's latest send leaves the window when it expires (the window rewinds and the retry takes
    /// its slot); an older send's expiry keeps the window as it is. Either way the next send steps up.
    function test_DEC162_onlyTheLatestSendLeavesTheWindow() public {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, 0.5e18);
        (uint64 first,) = h.send();
        (uint64 second,) = h.send();
        h.noteExpiry(first, 8e14);
        (uint64[3] memory rates, uint64 sends,) = h.window();
        assertEq(rates[0], 8e14, "an older send stays");
        assertEq(rates[1], 8e14);
        assertEq(sends, 2);
        assertEq(h.nextRate(), 12e14, "but the next send steps up");

        h.noteExpiry(second, 8e14);
        (rates,,) = h.window();
        assertEq(rates[1], 0, "the latest send left the window");
        (uint64 retry, uint256 rate) = h.send();
        assertEq(retry, 3, "serials are never reused");
        assertEq(rate, 12e14);
        (rates,,) = h.window();
        assertEq(rates[1], 12e14, "the retry took the expired send's slot");
    }

    /// DEC-162 (review round 1, M-1): an older send's expiry noted late, after the reference rose past its rate, never
    /// prices the next send below the reference. Send A goes out at 0.08% and the market moves to 0.20%; the route
    /// expires and steps until it has delivered four times (reference 0.2511%), and only then is A's expiry noted (on
    /// the hub a time-path expiry waits for the permissionless `recognizeRefund`). A step from A's rate alone (0.12%)
    /// would cost two more expiries of about 7.4 h each (0.12%, 0.18%); the reference delivers at once.
    function test_DEC162_lateExpiryOfAnOlderSendNeverPricesBelowTheReference() public {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, 0.5e18);
        uint256 market = 20e14;
        (uint64 a, uint256 rateA) = h.send();
        for (uint256 delivered; delivered < 4;) {
            (uint64 serial, uint256 rate) = h.send();
            if (rate >= market) ++delivered;
            else h.noteExpiry(serial, rate);
        }
        uint256 ref = h.referenceRate();
        assertEq(ref, 2_511_111_111_111_110, "the route delivers above the market");

        h.noteExpiry(a, rateA);
        assertEq(h.nextRate(), ref, "the stale step (0.12%) does not undercut the reference");
        (, uint256 next) = h.send();
        assertGe(next, market, "delivered without another expiry");
    }

    /// DEC-162, DEC-066 (review round 1, L-2): each noted expiry owes one send the step, as doc 12's model keeps the
    /// step until a delivery. Three deposits of a split transfer expire at 0.08% against a 0.11% market, in any order of
    /// notes: the three retries all go at 0.12%.
    function test_DEC162_eachNotedExpiryStepsOneSend() public {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, 0.5e18);
        (uint64 s1, uint256 r1) = h.send();
        (uint64 s2, uint256 r2) = h.send();
        (uint64 s3, uint256 r3) = h.send();
        h.noteExpiry(s3, r3); // the latest first: it leaves the window
        h.noteExpiry(s1, r1);
        h.noteExpiry(s2, r2);
        assertEq(h.steps(), 3);
        for (uint256 i; i < 3; ++i) {
            (, uint256 rate) = h.send();
            assertEq(rate, 12e14, "every retry steps");
        }
        assertEq(h.steps(), 0, "every step consumed");
        (,, uint64 expired) = h.window();
        assertEq(expired, 0, "the last step clears the expired rate");
        assertEq(h.nextRate(), h.referenceRate());
    }

    // ------------------------------------------------------------------ the fee

    /// DEC-162: the fee is `ceil(amount * rate) + fixed`; a fee that reaches the amount is refused.
    function test_DEC162_feeRoundsUpAndMustStayBelowTheAmount() public {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, 0.5e18);
        assertEq(h.fee(20_400e6, 8e14, 30_000), 16_320_000 + 30_000, "doc 11, section 7, row A");
        assertEq(h.fee(1001, 8e14, 0), 1, "0.8008 rounds up to 1");
        vm.expectRevert(abi.encodeWithSelector(BridgeFeeRule.FeeNotBelowAmount.selector, 30_024, 30_000));
        h.fee(30_000, 8e14, 30_000);
    }

    // ------------------------------------------------------------------ properties

    /// DEC-162 rule property: for any band, a route where every send expires climbs to the cap and never exceeds it,
    /// and an expiry never lowers the next rate.
    function testFuzz_DEC162_stepNeverFallsBelowTheExpiredRateNorAboveTheCap(uint256 band, uint8 expiries) public {
        band = bound(band, 1e16, 2e18);
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, band);
        uint256 last;
        for (uint256 i; i < bound(expiries, 1, 40); ++i) {
            (uint64 serial, uint256 rate) = h.send();
            assertLe(rate, CAP);
            assertGe(rate, last, "an expiry never lowers the next rate");
            h.noteExpiry(serial, rate);
            last = rate;
        }
    }

    /// DEC-162 rule property: whatever sequence of sends and expiries (older sends' included, in any order), the next
    /// rate stays within [floor, cap] and never below the reference.
    function testFuzz_DEC162_nextRateStaysWithinFloorAndCap(uint256 seed) public {
        BridgeFeeRuleHarness h = new BridgeFeeRuleHarness(8e14, 3e14, CAP, 0.5e18);
        uint64[] memory serials = new uint64[](24);
        uint256[] memory rates = new uint256[](24);
        for (uint256 i; i < 24; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 next = h.nextRate();
            assertGe(next, 3e14, "floor");
            assertLe(next, CAP, "cap");
            assertGe(next, h.referenceRate(), "never below the reference");
            (serials[i], rates[i]) = h.send();
            assertEq(rates[i], next, "the send uses the published rate");
            if (r % 3 == 0) {
                uint256 j = (r >> 8) % (i + 1); // any send so far, the latest or an older one
                h.noteExpiry(serials[j], rates[j]);
            }
        }
    }
}
