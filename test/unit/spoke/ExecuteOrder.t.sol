// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {OrderVerifier} from "../../../src/libraries/OrderVerifier.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockOrderCore} from "../../mocks/wormhole/MockOrderCore.sol";
import {SpokeVaultOrderHarness} from "../../mocks/spoke/SpokeVaultOrderHarness.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";

/// @notice `SpokeVault.executeOrder` (WP-07 D4): the Core Vault's orders reach a Spoke Vault as Wormhole VAAs that
///         anyone delivers (DEC-111, DEC-120 item 2, DEC-139); the vault checks them (`OrderVerifier`, run by the
///         linked `SpokeUnwindLib`), runs the executor of the order's kind and publishes its report in the same
///         transaction with `msg.value` as the Wormhole fee. No inactivity switch (DEC-157).
/// @dev The spoke's Wormhole Core is `MockOrderCore`: it verifies the hand-crafted VAAs (the guardian quorum is the
///      Core's job) and records the report the vault publishes. `SpokeVaultOrderHarness` stands in the executors
///      to isolate the checks, dispatch and report; production executor rules are in SpokeUnwindOrdersTest.
contract ExecuteOrderTest is SpokeVaultTestBase {
    /// @dev The Hub's Wormhole chain id in the fixture Mandate (Arbitrum One).
    uint16 internal constant WH_HUB = MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID;
    uint8 internal constant FINALIZED = 1;
    uint256 internal constant MESSAGE_FEE = 0.0001 ether;

    MockOrderCore internal orderCore;
    SpokeVaultOrderHarness internal harness;
    address internal deliverer = makeAddr("deliverer");

    function setUp() public {
        _setUpMocks();
        orderCore = new MockOrderCore(WH_SPOKE);
        orderCore.setMessageFee(MESSAGE_FEE);
        vm.deal(deliverer, 1 ether);
        vm.chainId(SPOKE);
        harness = new SpokeVaultOrderHarness(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(orderCore),
            address(escrowImplementation),
            excessRecipient
        );
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev A live order of `kind` (the deadline `OrderCodec.publish` would write now).
    function _order(uint8 kind, uint32 attempt) internal view returns (OrderCodec.Order memory o) {
        o.kind = kind;
        o.fundId = FUND_ID;
        o.requestId = keccak256(abi.encode(stranger, uint256(1)));
        o.attempt = attempt;
        o.deadline = uint64(block.timestamp) + OrderCodec.ORDER_LIFETIME;
        if (kind == OrderCodec.UNWIND) {
            o.fracNum = 1457;
            o.fracDen = 10_000;
            o.payoutMode = uint8(ICoreVaultPayouts.PayoutMode.Standard);
        }
    }

    function _emitter(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    /// @dev The VAA the guardians would sign for `payload` published by the Core Vault on the Hub at `sequence`.
    function _vaaOf(bytes memory payload, uint64 sequence) internal view returns (bytes memory) {
        return orderCore.craft(WH_HUB, _emitter(address(core)), sequence, OrderCodec.CONSISTENCY_INSTANT, payload);
    }

    function _vaa(OrderCodec.Order memory o, uint64 sequence) internal view returns (bytes memory) {
        return _vaaOf(OrderCodec.encode(o), sequence);
    }

    function _deliver(SpokeVault v, bytes memory vaa) internal returns (uint64 reportSequence) {
        vm.prank(deliverer);
        reportSequence = v.executeOrder{value: MESSAGE_FEE}(vaa);
    }

    function _expectRefused(bytes memory vaa, bytes memory reason) internal {
        vm.expectRevert(reason);
        _deliver(harness, vaa);
        _assertNothingHappened();
    }

    /// @dev A refused order executes nothing, publishes nothing and leaves the cursor where it was.
    function _assertNothingHappened() internal view {
        assertEq(harness.orderCursor(), 0, "the cursor did not move");
        assertEq(harness.executed().length, 0, "no executor ran");
        assertEq(harness.reportSequence(), 0, "no report");
        assertEq(orderCore.publishedCount(), 0, "nothing published");
    }

    /// @dev The report the vault published as the `index`-th message of the spoke's Core, decoded.
    function _publishedReport(uint256 index) internal view returns (ReportCodec.Report memory) {
        MockOrderCore.Published memory p = orderCore.published(index);
        assertEq(p.emitter, address(harness), "published by the Spoke Vault");
        assertEq(p.consistencyLevel, FINALIZED, "DEC-093: reports stay finalized");
        assertEq(p.value, MESSAGE_FEE, "msg.value paid the Wormhole fee");
        return ReportCodec.decode(p.payload);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Accepted: executed, then reported in the same transaction
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC120_anyoneDeliversAnOrderAndTheReportFollowsInTheSameTransaction() public {
        OrderCodec.Order memory o = _order(OrderCodec.UNWIND, 1);
        bytes32 orderId = OrderCodec.orderId(o);

        vm.expectEmit(address(harness));
        emit ISpokeVault.OrderExecuted(OrderCodec.UNWIND, orderId, 0);
        vm.expectEmit(address(harness));
        emit ISpokeVault.ReportPublished(1, 0, uint64(block.number));
        uint64 reportSequence = _deliver(harness, _vaa(o, 0));

        assertEq(reportSequence, 1, "the post-order report is the vault's next report");
        assertEq(harness.reportSequence(), 1);
        assertEq(harness.orderCursor(), 1, "DEC-093: the cursor moved past the order");
        uint8[] memory kinds = harness.executed();
        assertEq(kinds.length, 1);
        assertEq(kinds[0], OrderCodec.UNWIND);

        assertEq(orderCore.publishedCount(), 1, "one message: the report");
        ReportCodec.Report memory r = _publishedReport(0);
        assertEq(r.sequence, 1);
        assertEq(r.fundId, FUND_ID);
        assertEq(r.timestamp, block.timestamp, "built after the order, in the same block");
        assertEq(r.unwindResults, abi.encode(orderId, o.fracNum, o.fracDen), "D3: the unwind book travels");
        assertEq(r.collectionResults.length, 0);
    }

    function test_DEC120_eachKindRunsItsOwnExecutor() public {
        OrderCodec.Order memory unwind = _order(OrderCodec.UNWIND, 1);
        OrderCodec.Order memory close = _order(OrderCodec.CLOSE, 1);
        OrderCodec.Order memory collect = _order(OrderCodec.COLLECT, 1);

        _deliver(harness, _vaa(unwind, 0));
        _deliver(harness, _vaa(close, 1));
        vm.expectEmit(address(harness));
        emit ISpokeVault.OrderExecuted(OrderCodec.COLLECT, OrderCodec.orderId(collect), 2);
        assertEq(_deliver(harness, _vaa(collect, 2)), 3);

        uint8[] memory kinds = harness.executed();
        assertEq(kinds.length, 3);
        assertEq(kinds[0], OrderCodec.UNWIND);
        assertEq(kinds[1], OrderCodec.CLOSE);
        assertEq(kinds[2], OrderCodec.COLLECT);
        assertEq(harness.orderCursor(), 3);

        // DEC-147: a closure is everything, whatever the publisher wrote (OrderCodec.check).
        ReportCodec.Report memory afterClose = _publishedReport(1);
        assertEq(afterClose.unwindResults, abi.encode(OrderCodec.orderId(close), uint256(1), uint256(1)));
        ReportCodec.Report memory afterCollect = _publishedReport(2);
        assertEq(afterCollect.collectionResults, abi.encode(OrderCodec.orderId(collect)), "D3: the income book");
        assertEq(
            afterCollect.unwindResults, afterClose.unwindResults, "the unwind book is kept until its work clears it"
        );
    }

    /// @dev DEC-093: gaps are accepted (an order this spoke never received does not block a later one).
    function test_DEC093_aGapIsAcceptedAndTheCursorMovesPastTheOrder() public {
        _deliver(harness, _vaa(_order(OrderCodec.UNWIND, 1), 5));
        assertEq(harness.orderCursor(), 6);
    }

    /// @dev The cursor moves before the executor runs, and the entry is `nonReentrant`: an executor that re-delivers
    ///      the order it runs (or any other) is refused, and the outer order still completes.
    function test_DEC093_aReenteredDeliveryIsRefused() public {
        bytes memory vaa = _vaa(_order(OrderCodec.UNWIND, 1), 0);
        harness.setReentry(vaa);
        _deliver(harness, vaa);
        bytes memory reentrancyRefused = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(harness.reentryRevert(), reentrancyRefused);
        assertEq(harness.executed().length, 1, "executed once");
        assertEq(harness.reportSequence(), 1);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Refused: every verification failure, nothing executed or published
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC086_refusesAVaaTheCoreRefuses() public {
        bytes memory vaa = _vaa(_order(OrderCodec.UNWIND, 1), 0);
        orderCore.setInvalid("VM signature invalid");
        _expectRefused(vaa, abi.encodeWithSelector(OrderVerifier.InvalidOrderVaa.selector, "VM signature invalid"));
    }

    function test_DEC120_refusesAnotherEmitterChain() public {
        bytes memory payload = OrderCodec.encode(_order(OrderCodec.UNWIND, 1));
        uint16[3] memory chains = [WH_SPOKE, 2, 0];
        for (uint256 i; i < chains.length; ++i) {
            // The Core Vault's address on another chain (CREATE3: the same everywhere, DEC-054).
            bytes memory vaa = orderCore.craft(chains[i], _emitter(address(core)), 0, 200, payload);
            _expectRefused(vaa, abi.encodeWithSelector(OrderVerifier.OrderEmitterChainMismatch.selector, chains[i]));
        }
    }

    function test_DEC111_refusesAnotherEmitter() public {
        bytes memory payload = OrderCodec.encode(_order(OrderCodec.UNWIND, 1));
        bytes32[3] memory emitters = [
            _emitter(stranger),
            _emitter(address(harness)), // the Spoke Vault itself
            _emitter(address(core)) | bytes32(uint256(1) << 200) // the Core Vault with dirty high bytes
        ];
        for (uint256 i; i < emitters.length; ++i) {
            bytes memory vaa = orderCore.craft(WH_HUB, emitters[i], 0, 200, payload);
            _expectRefused(vaa, abi.encodeWithSelector(OrderVerifier.OrderEmitterMismatch.selector, emitters[i]));
        }
    }

    function test_DEC093_refusesAReplay() public {
        bytes memory vaa = _vaa(_order(OrderCodec.UNWIND, 1), 0);
        _deliver(harness, vaa);
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderSequenceTooLow.selector, 1, 0));
        _deliver(harness, vaa);
        assertEq(harness.executed().length, 1, "executed once");
        assertEq(harness.reportSequence(), 1, "reported once");
    }

    /// @dev The register's rule (DEC-093, D-13): an older order delivered after a newer one is refused; the request's
    ///      retry republishes it (DEC-151).
    function test_DEC093_refusesAnOlderOrderAfterANewerOne() public {
        bytes memory older = _vaa(_order(OrderCodec.UNWIND, 1), 1);
        _deliver(harness, _vaa(_order(OrderCodec.UNWIND, 2), 2));
        vm.expectRevert(abi.encodeWithSelector(OrderVerifier.OrderSequenceTooLow.selector, 3, 1));
        _deliver(harness, older);
    }

    function test_DEC111_refusesAnotherFundsOrder() public {
        OrderCodec.Order memory o = _order(OrderCodec.UNWIND, 1);
        o.fundId = keccak256("fund-2");
        _expectRefused(_vaa(o, 0), abi.encodeWithSelector(OrderVerifier.OrderFundMismatch.selector, o.fundId));
    }

    /// @dev Doc 32 §4.2, DEC-120: the spoke accepts the order up to its deadline and refuses it from the next second.
    function test_DEC120_refusesAnExpiredOrder() public {
        OrderCodec.Order memory o = _order(OrderCodec.UNWIND, 1);
        bytes memory vaa = _vaa(o, 0);
        vm.warp(o.deadline + 1);
        _expectRefused(vaa, abi.encodeWithSelector(OrderVerifier.OrderExpired.selector, o.deadline));
        vm.warp(o.deadline);
        _deliver(harness, vaa);
        assertEq(harness.orderCursor(), 1, "accepted at its deadline");
    }

    function test_DEC120_refusesAPayloadOfAnotherVersion() public {
        OrderCodec.Order memory o = _order(OrderCodec.UNWIND, 1);
        _expectRefused(
            _vaaOf(abi.encode(OrderCodec.VERSION + 1, o), 0),
            abi.encodeWithSelector(OrderCodec.UnsupportedOrderVersion.selector, OrderCodec.VERSION + 1)
        );
        _expectRefused(
            _vaaOf(new bytes(31), 0), abi.encodeWithSelector(OrderCodec.OrderPayloadTooShort.selector, uint256(31))
        );
    }

    function test_DEC120_refusesAnUnknownKind() public {
        uint8[2] memory kinds = [0, 4];
        for (uint256 i; i < kinds.length; ++i) {
            OrderCodec.Order memory o = _order(OrderCodec.COLLECT, 1);
            o.kind = kinds[i];
            _expectRefused(
                _vaaOf(abi.encode(OrderCodec.VERSION, o), 0),
                abi.encodeWithSelector(OrderCodec.UnknownOrderKind.selector, kinds[i])
            );
        }
    }

    /// @dev DEC-137: an unwind never takes more than everything, and its denominator is never zero.
    function test_DEC137_refusesAnInvalidUnwindFraction() public {
        OrderCodec.Order memory o = _order(OrderCodec.UNWIND, 1);
        (o.fracNum, o.fracDen) = (1, 0);
        _expectRefused(
            _vaaOf(abi.encode(OrderCodec.VERSION, o), 0),
            abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 1, 0)
        );
        (o.fracNum, o.fracDen) = (10_001, 10_000);
        _expectRefused(
            _vaaOf(abi.encode(OrderCodec.VERSION, o), 0),
            abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 10_001, 10_000)
        );
    }

    function test_DEC118_refusesAnUnknownPayoutMode() public {
        OrderCodec.Order memory o = _order(OrderCodec.UNWIND, 1);
        o.payoutMode = OrderCodec.MAX_PAYOUT_MODE + 1;
        _expectRefused(
            _vaaOf(abi.encode(OrderCodec.VERSION, o), 0),
            abi.encodeWithSelector(OrderCodec.InvalidPayoutMode.selector, o.payoutMode)
        );
    }

    /// @dev DEC-120 item 2: the report is published in the order's transaction, so a delivery that does not pay the
    ///      Wormhole fee fails whole: the executor's work is undone and the order can be delivered again.
    function test_DEC120_aDeliveryThatDoesNotPayTheFeeIsRefusedWhole() public {
        bytes memory vaa = _vaa(_order(OrderCodec.UNWIND, 1), 0);
        vm.prank(deliverer);
        vm.expectRevert(abi.encodeWithSelector(MockOrderCore.WrongFee.selector, 0, MESSAGE_FEE));
        harness.executeOrder(vaa);
        _assertNothingHappened();
        _deliver(harness, vaa);
        assertEq(harness.orderCursor(), 1, "delivered again with the fee");
    }

    /// @dev The Hub Spoke Vault takes no orders: the Core Vault unwinds it directly on the same chain (DEC-054).
    function test_DEC139_theHubSpokeVaultTakesNoOrder() public {
        SpokeVault hubVault = _deployHub();
        bytes memory vaa = _vaa(_order(OrderCodec.UNWIND, 1), 0);
        vm.deal(address(this), MESSAGE_FEE);
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        hubVault.executeOrder{value: MESSAGE_FEE}(vaa);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Production executors
    // -----------------------------------------------------------------------------------------------------------------

    /// @dev DEC-120/149: the production UNWIND and CLOSE executors publish their post-order reports.
    function test_WP12_productionExecutorsPublishUnwindAndCloseReports() public {
        vm.chainId(SPOKE);
        SpokeVault v = new SpokeVault(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(orderCore),
            address(escrowImplementation),
            excessRecipient
        );
        uint8[2] memory kinds = [OrderCodec.UNWIND, OrderCodec.CLOSE];
        for (uint256 i; i < kinds.length; ++i) {
            bytes memory vaa = _vaa(_order(kinds[i], 1), uint64(i));
            _deliver(v, vaa);
        }
        assertEq(v.reportSequence(), 2);
        assertEq(orderCore.publishedCount(), 2);
        assertTrue(v.spokeClosed());
    }
}
