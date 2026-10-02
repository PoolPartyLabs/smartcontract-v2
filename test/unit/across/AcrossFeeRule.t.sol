// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AcrossBridgeAdapter} from "../../../src/adapters/AcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "../../../src/interfaces/IBridgeAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/across/MockAcrossSpokePool.sol";
import {MockAcrossToken} from "../../mocks/across/MockAcrossToken.sol";
import {AcrossHarnessVault} from "../../mocks/across/AcrossHarnessVault.sol";

/// @notice DEC-162 bridge fee rule (founder chat of 2026-10-02; checklist doc 12): the rate of a send comes from the
///         fund's own last 3 sends on the route, steps one band up after an expiry, and never leaves [floor, cap].
///         Nobody who triggers a send can widen the gap between what leaves and what arrives (DEC-158).
/// @dev The Across adapter's own constants (band 50%, initial 0.08%) exercised end to end through a vault harness; the
///      rule alone, with doc 12 §5's tables at other bands, is in BridgeFeeRule.t.sol. Rates are WAD fractions:
///      6e14 = 0.06%. Without signed quotes (R-162-B) the API rows of doc 12 do not apply yet.
contract AcrossFeeRuleTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant AMOUNT = 20_400e6; // doc 11 / doc 12 example
    uint256 internal constant HUB_CHAIN = 42_161;
    uint256 internal constant CAP = 1e16;

    MockAcrossSpokePool internal pool;
    MockAcrossToken internal usdg;
    AcrossHarnessVault internal vault;
    AcrossBridgeAdapter internal adapter;

    address internal guardian = makeAddr("guardian");
    address internal coreVault = makeAddr("coreVault");
    address internal hubUsdc = makeAddr("usdcOnHub");

    function setUp() public {
        vm.warp(1_790_000_000);
        pool = new MockAcrossSpokePool(405_000);
        usdg = new MockAcrossToken("Global Dollar", "USDG");
        vault = new AcrossHarnessVault();
        adapter = new AcrossBridgeAdapter(address(vault), guardian, address(pool), address(0));
        vault.pin(adapter);
        usdg.mint(address(vault), 1_000_000_000e6);
    }

    // ------------------------------------------------------------------ helpers

    function _request(uint256 amount) internal view returns (IBridgeAdapter.SendRequest memory) {
        return IBridgeAdapter.SendRequest({
            inputToken: address(usdg),
            outputToken: hubUsdc,
            inputAmount: amount,
            destinationChainId: HUB_CHAIN,
            recipient: bytes32(uint256(uint160(coreVault))),
            message: TransitMessage.encode(keccak256("fund"), 4663, bytes32(uint256(1)), TransferKind.Principal)
        });
    }

    /// @dev One send of AMOUNT through the vault harness; returns the call and the rate the adapter applied.
    function _send() internal returns (IBridgeAdapter.BridgeCall memory call, uint256 rate) {
        (rate,,) = adapter.feeState(HUB_CHAIN);
        (call,) = vault.send(_request(AMOUNT));
    }

    /// @dev The send expired: Across refunds it after the deadline and the vault reports it (DEC-066, DEC-162).
    function _expire(IBridgeAdapter.BridgeCall memory call) internal {
        vm.warp(uint256(call.fillDeadline) + 82 minutes); // median refund delay measured on Robinhood Chain
        vault.noteExpiry(call.transitRef);
    }

    /// @dev Doc 12 `expirados` on the Across adapter: `transfers` transfers against a market at `market`; expired
    ///      sends until each one lands.
    function _adapterExpiries(uint256 market, uint256 transfers) internal returns (uint256 failures) {
        for (uint256 i; i < transfers; ++i) {
            while (true) {
                (IBridgeAdapter.BridgeCall memory call, uint256 rate) = _send();
                if (rate >= market) {
                    vm.warp(block.timestamp + 60);
                    break;
                }
                ++failures;
                _expire(call);
            }
        }
    }

    // ------------------------------------------------------------------ doc 12 §5, the stuck-fee case

    /// Doc 12 §5 on the Across adapter (band 50%), from its initial 0.08%: the market doubling to 0.16% costs 4
    /// expired sends over six transfers, and a 40% rise (0.112%) costs 2 (the same ratios as BridgeFeeRule.t.sol's
    /// tables, which start at the market).
    function test_DEC162_adapter_marketMovesFromTheInitialRate() public {
        uint256 snapshot = vm.snapshotState();
        assertEq(_adapterExpiries(16e14, 6), 4, "x2");
        vm.revertToState(snapshot);
        assertEq(_adapterExpiries(112e13, 6), 2, "+40%");
    }

    // ------------------------------------------------------------------ the rule's moves

    /// DEC-162: the first sends use the initial rate: 20,400 pays 16.32 + 0.03 (doc 11 §7 row A).
    function test_DEC162_firstSendsUseTheInitialRate() public {
        for (uint256 i; i < 4; ++i) {
            (IBridgeAdapter.BridgeCall memory call, uint256 rate) = _send();
            assertEq(rate, 8e14);
            assertEq(AMOUNT - call.amountToArrive, 16_350_000);
        }
    }

    /// DEC-162: after an expiry the next send uses the expired rate plus one band (0.08% to 0.12%), the expired rate
    /// leaves the reference (the window rewinds, so the retry takes its slot), and the step is consumed by that one
    /// send.
    function test_DEC162_expiryStepsTheNextSendOneBandUp() public {
        (IBridgeAdapter.BridgeCall memory first,) = _send();
        _expire(first);
        (uint64[3] memory rates, uint8 slot, uint64 sends,) = adapter.feeWindow(HUB_CHAIN);
        assertEq(sends, 1);
        assertEq(rates[0], 0, "the expired rate left the window");
        assertEq(slot, 0, "the window rewound");
        (uint256 next, uint256 ref, uint256 expired) = adapter.feeState(HUB_CHAIN);
        assertEq(expired, 8e14);
        assertEq(next, 12e14, "0.08% * 1.5");
        assertEq(ref, 8e14);

        (IBridgeAdapter.BridgeCall memory retry, uint256 rate) = _send();
        assertEq(rate, 12e14);
        assertEq(AMOUNT - retry.amountToArrive, 24_480_000 + 30_000, "20,400 at 0.12% plus 0.03");
        (, ref, expired) = adapter.feeState(HUB_CHAIN);
        assertEq(expired, 0, "the step is consumed by one send");
        assertEq(ref, uint256(12e14 + 8e14 + 8e14) / 3, "the delivered retry joins the reference");
    }

    /// DEC-162 (research prototype semantics): the expiry of a send that is no longer the latest keeps the window as
    /// it is (only the latest send can leave it), and the next send still steps from the expired rate.
    function test_DEC162_expiryOfAnOlderSendKeepsTheWindowAndSteps() public {
        (IBridgeAdapter.BridgeCall memory older,) = _send();
        vm.warp(block.timestamp + 60);
        _send();
        _expire(older);
        (uint64[3] memory rates, uint8 next, uint64 sends,) = adapter.feeWindow(HUB_CHAIN);
        assertEq(sends, 2);
        assertEq(next, 2);
        assertEq(rates[0], 8e14, "the older send stays in the window");
        assertEq(rates[1], 8e14);
        (, uint256 rate) = _send();
        assertEq(rate, 12e14, "stepped from the expired rate");
    }

    /// DEC-162: a send that left the window (three newer sends) can still expire; it only steps the next send.
    function test_DEC162_expiryOfASendOutsideTheWindowOnlySteps() public {
        (IBridgeAdapter.BridgeCall memory oldest,) = _send();
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 60);
            _send();
        }
        _expire(oldest);
        (uint64[3] memory rates,,,) = adapter.feeWindow(HUB_CHAIN);
        assertEq(rates[0], 8e14, "the window is the three newer sends");
        assertEq(rates[1], 8e14);
        assertEq(rates[2], 8e14);
        (uint256 next,,) = adapter.feeState(HUB_CHAIN);
        assertEq(next, 12e14);
    }

    /// DEC-162 (review round 1, M-1): an older send's expiry reported after the route's reference rose past its rate
    /// (a late refund recognition) leaves the next send at the reference, not one band above the stale rate.
    function test_DEC162_lateExpiryOfAnOlderSendKeepsTheReference() public {
        (IBridgeAdapter.BridgeCall memory older,) = _send(); // 0.08%, its outcome still unknown
        for (uint256 i; i < 3; ++i) {
            (IBridgeAdapter.BridgeCall memory failed,) = _send(); // 0.08%, 0.12%, 0.18%: the market moved up
            _expire(failed);
        }
        for (uint256 i; i < 3; ++i) {
            vm.warp(block.timestamp + 60);
            _send(); // 0.27%, then the reference: delivered
        }
        (, uint256 ref,) = adapter.feeState(HUB_CHAIN);
        assertGt(ref, 12e14, "the reference rose past one step above the older send's rate");

        vault.noteExpiry(older.transitRef);
        (uint256 next, uint256 refAfter, uint256 expired) = adapter.feeState(HUB_CHAIN);
        assertEq(expired, 8e14, "the late expiry is pending");
        assertEq(refAfter, ref, "an older send's expiry keeps the window");
        assertEq(next, ref, "a step from 0.08% (0.12%) would undercut the reference: the reference applies");
        (, uint256 rate) = _send();
        assertEq(rate, ref);
    }

    /// DEC-162 (review round 1, L-2): two expiries before the next send step two sends from the highest expired rate;
    /// the third send is back at the reference.
    function test_DEC162_severalExpiriesStepAsManySendsFromTheHighest() public {
        (IBridgeAdapter.BridgeCall memory a,) = _send();
        _expire(a);
        (IBridgeAdapter.BridgeCall memory b, uint256 rateB) = _send(); // 0.12%
        (IBridgeAdapter.BridgeCall memory c, uint256 rateC) = _send(); // the reference again
        assertEq(rateB, 12e14);
        assertLt(rateC, rateB);
        _expire(b);
        _expire(c);
        (uint256 next,, uint256 expired) = adapter.feeState(HUB_CHAIN);
        assertEq(expired, 12e14, "highest expired rate");
        assertEq(next, 18e14, "0.12% * 1.5");
        (,,, uint32 steps) = adapter.feeWindow(HUB_CHAIN);
        assertEq(steps, 2, "one step per noted expiry");

        (, uint256 first) = _send();
        (, uint256 second) = _send();
        assertEq(first, 18e14);
        assertEq(second, 18e14, "the second retry steps too");
        uint256 ref;
        (next, ref, expired) = adapter.feeState(HUB_CHAIN);
        assertEq(expired, 0, "both steps consumed");
        assertEq(next, ref, "the next send is back at the reference");
    }

    /// DEC-162, DEC-066 (review round 1, L-2): a transfer split into three deposits, all expired by a market move to
    /// 0.11%, retries every deposit one band up (0.12%), so one round of about 7.4 h is lost, not two. Before, only one
    /// retry stepped and the others went at the reference that had just failed (0.0933%, 0.0978%).
    function test_DEC162_everyDepositOfASplitTransferRetriesOneBandUp() public {
        uint256 market = 11e14;
        IBridgeAdapter.BridgeCall[3] memory deposits;
        for (uint256 i; i < 3; ++i) {
            (deposits[i],) = _send(); // 0.08%
        }
        for (uint256 i; i < 3; ++i) {
            _expire(deposits[i]);
        }
        for (uint256 i; i < 3; ++i) {
            (, uint256 rate) = _send();
            assertEq(rate, 12e14, "every retry steps");
            assertGe(rate, market, "and is delivered");
        }
        (,,, uint32 steps) = adapter.feeWindow(HUB_CHAIN);
        assertEq(steps, 0);
        (uint256 next, uint256 ref,) = adapter.feeState(HUB_CHAIN);
        assertEq(ref, 12e14, "the window holds the three delivered retries");
        assertEq(next, ref);
    }

    /// DEC-162, founder chat 2: the cap is the adapter's hard ceiling. A route where every send expires climbs one band
    /// per send (0.08, 0.12, 0.18, 0.27, 0.405, 0.6075, 0.91125%) and then stays at 1% (204 on 20,400 plus 0.03).
    function test_DEC162_ratchetStopsAtTheCap() public {
        uint256[8] memory expected = [uint256(8e14), 12e14, 18e14, 27e14, 405e13, 6075e12, 91_125e11, CAP];
        for (uint256 i; i < expected.length; ++i) {
            (IBridgeAdapter.BridgeCall memory call, uint256 rate) = _send();
            assertEq(rate, expected[i]);
            _expire(call);
        }
        for (uint256 i; i < 3; ++i) {
            (IBridgeAdapter.BridgeCall memory call, uint256 rate) = _send();
            assertEq(rate, CAP, "never above the cap");
            assertEq(AMOUNT - call.amountToArrive, 204e6 + 30_000);
            _expire(call);
        }
    }

    /// DEC-162: without a quote the rate never falls; it only rises through expiries (doc 12 §5: "without one the
    /// rate never falls"). A market that fell below the reference keeps paying the reference until signed quotes exist
    /// (R-162-B).
    function test_DEC162_withoutQuotesTheRateNeverFalls() public {
        (IBridgeAdapter.BridgeCall memory call,) = _send();
        _expire(call);
        for (uint256 i; i < 6; ++i) {
            vm.warp(block.timestamp + 60);
            _send();
        }
        (uint256 next, uint256 ref,) = adapter.feeState(HUB_CHAIN);
        assertGe(ref, 8e14);
        assertEq(next, ref);
    }

    /// DEC-162: the reference holds after expiries: expired rates leave it, delivered rates make it.
    function test_DEC162_referenceIsTheMeanOfTheLastThreeDeliveredSends() public {
        (IBridgeAdapter.BridgeCall memory call,) = _send();
        _expire(call);
        _send(); // 0.12% delivered
        _send(); // (0.12 + 0.08 + 0.08) / 3
        _send();
        (uint64[3] memory rates,, uint64 sends,) = adapter.feeWindow(HUB_CHAIN);
        assertEq(sends, 4);
        uint256 mean = (uint256(rates[0]) + rates[1] + rates[2]) / 3;
        (, uint256 ref,) = adapter.feeState(HUB_CHAIN);
        assertEq(ref, mean, "all three slots are delivered sends");
    }

    // ------------------------------------------------------------------ properties

    /// DEC-162: whatever sequence of sends and expiries, every rate is the one published right before the send, sits
    /// in [floor, cap], and the amount to arrive is the amount less `ceil(amount * rate) + 0.03`, always below it.
    function testFuzz_DEC162_everyRateStaysInsideTheBounds(uint256 seed) public {
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 amount = bound(r >> 64, 40_000, 1e13);
            (uint256 published, uint256 ref,) = adapter.feeState(HUB_CHAIN);
            (IBridgeAdapter.BridgeCall memory call,) = vault.send(_request(amount));
            assertGe(published, 3e14, "floor");
            assertLe(published, CAP, "cap");
            assertGe(published, ref, "never below the reference");
            uint256 fee = (amount * published + WAD - 1) / WAD + 30_000;
            assertEq(call.amountToArrive, amount - fee, "amount to arrive");
            assertGt(call.amountToArrive, 0, "something arrives");
            if (r % 3 == 0) _expire(call);
            else vm.warp(block.timestamp + 60);
        }
    }
}
