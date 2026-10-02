// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {OrderCodec} from "../../src/libraries/OrderCodec.sol";
import {ICoreVaultPayouts} from "../../src/interfaces/ICoreVaultPayouts.sol";
import {MockOrderCore} from "../mocks/wormhole/MockOrderCore.sol";
import {OrderCodecHarness, OrderPublisherHarness} from "../mocks/wormhole/OrderCodecHarness.sol";

/// @notice OrderCodec: the order layout, its checks on both ends and the instant publisher (DEC-111, DEC-120,
///         DEC-139).
contract OrderCodecTest is Test {
    uint16 internal constant WH_ARBITRUM = 23;
    bytes32 internal constant FUND = keccak256("pool-party/fund/1");

    OrderCodecHarness internal h;
    MockOrderCore internal core;
    OrderPublisherHarness internal coreVault;

    function setUp() public {
        h = new OrderCodecHarness();
        core = new MockOrderCore(WH_ARBITRUM);
        coreVault = new OrderPublisherHarness();
    }

    /// @dev The DEC-137 example fraction: 14.57% of every position, the 2% margin included.
    function _unwind() internal pure returns (OrderCodec.Order memory o) {
        o.kind = OrderCodec.UNWIND;
        o.fundId = FUND;
        o.requestId = keccak256(abi.encode(address(0xA11CE), uint256(1)));
        o.attempt = 1;
        o.deadline = 1_800_000_000;
        o.fracNum = 1457;
        o.fracDen = 10_000;
        o.maxLossBps = 150;
        o.payoutMode = uint8(ICoreVaultPayouts.PayoutMode.Instant);
    }

    function _same(OrderCodec.Order memory a, OrderCodec.Order memory b) internal pure {
        assertEq(keccak256(abi.encode(a)), keccak256(abi.encode(b)));
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Layout and round trip
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC120_roundTripOfAnUnwindOrder() public view {
        OrderCodec.Order memory o = _unwind();
        bytes memory payload = h.encode(o);
        assertEq(payload, abi.encode(uint256(1), o), "layout: abi.encode(VERSION, order)");
        assertEq(h.versionOf(payload), OrderCodec.VERSION);
        OrderCodec.Order memory d = h.decode(payload);
        _same(o, d);
        assertEq(d.fracNum, 1457);
        assertEq(d.deadline, 1_800_000_000, "doc 32 section 4.2: the deadline travels");
        assertEq(d.maxLossBps, 150, "DEC-140: the requester's maximum travels");
        assertEq(d.payoutMode, uint8(ICoreVaultPayouts.PayoutMode.Instant), "DEC-118, DEC-141: the mode travels");
    }

    function test_DEC161_roundTripOfACollectOrder() public view {
        OrderCodec.Order memory o;
        o.kind = OrderCodec.COLLECT;
        o.fundId = FUND;
        o.requestId = bytes32(uint256(7));
        bytes memory payload = h.encode(o);
        assertEq(payload.length, 10 * 32, "ten static words: the version and the nine fields");
        OrderCodec.Order memory d = h.decode(payload);
        _same(o, d);
        assertEq(d.fracDen, 0, "the fraction of a collection is not read");
    }

    function test_DEC147_closeOrderIsAlwaysOneOverOne() public view {
        OrderCodec.Order memory o;
        o.kind = OrderCodec.CLOSE;
        o.fundId = FUND;
        o.fracNum = 3;
        o.fracDen = 7;
        bytes memory payload = h.encode(o);
        OrderCodec.Order memory d = h.decode(payload);
        assertEq(d.fracNum, 1, "encode writes a CLOSE with 1/1");
        assertEq(d.fracDen, 1);

        // A payload written without `encode` (another encoder) is read as 1/1 too.
        o.fracNum = 0;
        o.fracDen = 0;
        d = h.decode(abi.encode(OrderCodec.VERSION, o));
        assertEq(d.fracNum, 1, "decode forces 1/1 on a CLOSE");
        assertEq(d.fracDen, 1);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Order id
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC151_orderIdIsKindFundRequestAndAttempt() public view {
        OrderCodec.Order memory o = _unwind();
        bytes32 id = h.orderId(o);
        assertEq(id, keccak256(abi.encode(o.kind, o.fundId, o.requestId, o.attempt)));

        OrderCodec.Order memory same = _unwind();
        same.fracNum = 1;
        same.deadline = 1;
        same.maxLossBps = 0;
        assertEq(h.orderId(same), id, "the terms of an order do not change its id");

        OrderCodec.Order memory retry = _unwind();
        retry.attempt = 2;
        assertTrue(h.orderId(retry) != id, "DEC-151: a retry is a new order");

        OrderCodec.Order memory other = _unwind();
        other.requestId = keccak256(abi.encode(address(0xB0B), uint256(1)));
        assertTrue(h.orderId(other) != id);

        OrderCodec.Order memory otherFund = _unwind();
        otherFund.fundId = keccak256("pool-party/fund/2");
        assertTrue(h.orderId(otherFund) != id);

        OrderCodec.Order memory collect = _unwind();
        collect.kind = OrderCodec.COLLECT;
        assertTrue(h.orderId(collect) != id, "a collection and a payout never share an id");
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Checks on decode (the spoke never executes) and on encode (the Hub never publishes)
    // -----------------------------------------------------------------------------------------------------------------

    function test_decodeRejectsAnUnknownVersion() public {
        bytes memory payload = abi.encode(uint256(2), _unwind());
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.UnsupportedOrderVersion.selector, 2));
        h.decode(payload);
        // a value report (ReportCodec v3) is never read as an order
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.UnsupportedOrderVersion.selector, 3));
        h.decode(abi.encode(uint256(3), uint256(0)));
    }

    function test_decodeRejectsAPayloadShorterThanOneWord() public {
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.OrderPayloadTooShort.selector, 31));
        h.decode(new bytes(31));
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.OrderPayloadTooShort.selector, 0));
        h.versionOf("");
    }

    function test_decodeRejectsAMalformedPayload() public {
        // the version word alone
        vm.expectRevert();
        h.decode(abi.encode(OrderCodec.VERSION));
        // a kind word above uint8
        bytes memory payload = abi.encode(OrderCodec.VERSION, _unwind());
        assembly {
            mstore(add(payload, 0x40), 0x101) // length, version, then the kind word
        }
        vm.expectRevert();
        h.decode(payload);
    }

    function test_rejectsUnknownKinds() public {
        uint8[3] memory kinds = [uint8(0), 5, 255];
        for (uint256 i; i < kinds.length; ++i) {
            OrderCodec.Order memory o = _unwind();
            o.kind = kinds[i];
            vm.expectRevert(abi.encodeWithSelector(OrderCodec.UnknownOrderKind.selector, kinds[i]));
            h.decode(abi.encode(OrderCodec.VERSION, o));
            vm.expectRevert(abi.encodeWithSelector(OrderCodec.UnknownOrderKind.selector, kinds[i]));
            h.encode(o);
        }
    }

    function test_DEC137_rejectsAnUnwindFractionAboveOneOrWithoutDenominator() public {
        OrderCodec.Order memory o = _unwind();
        o.fracNum = 10_001;
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 10_001, 10_000));
        h.decode(abi.encode(OrderCodec.VERSION, o));
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 10_001, 10_000));
        h.encode(o);

        o.fracNum = 0;
        o.fracDen = 0;
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 0, 0));
        h.decode(abi.encode(OrderCodec.VERSION, o));
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 0, 0));
        h.encode(o);
    }

    function test_DEC137_acceptsTheWholeAndNothing() public view {
        OrderCodec.Order memory o = _unwind();
        o.fracNum = o.fracDen;
        assertEq(h.decode(h.encode(o)).fracNum, 10_000, "an unwind of everything");
        o.fracNum = 0;
        assertEq(h.decode(h.encode(o)).fracNum, 0, "an unwind of nothing is harmless");
    }

    function test_rejectsAnUnknownPayoutMode() public {
        OrderCodec.Order memory o = _unwind();
        o.payoutMode = 2;
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidPayoutMode.selector, 2));
        h.decode(abi.encode(OrderCodec.VERSION, o));
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidPayoutMode.selector, 2));
        h.encode(o);
        o.payoutMode = uint8(ICoreVaultPayouts.PayoutMode.Standard);
        assertEq(h.decode(h.encode(o)).payoutMode, uint8(ICoreVaultPayouts.PayoutMode.Standard));
    }

    /// @dev Every `ICoreVault.PayoutMode` travels and the next value is refused, read from the enum itself, so this
    ///      test follows the enum when a mode is added.
    function test_everyPayoutModeTravelsAndNoOther() public {
        uint8 last = uint8(type(ICoreVaultPayouts.PayoutMode).max);
        assertEq(OrderCodec.MAX_PAYOUT_MODE, last, "the codec's bound is the enum's last value");
        OrderCodec.Order memory o = _unwind();
        for (uint8 mode; mode <= last; ++mode) {
            o.payoutMode = mode;
            assertEq(h.decode(h.encode(o)).payoutMode, mode);
        }
        o.payoutMode = last + 1;
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidPayoutMode.selector, last + 1));
        h.encode(o);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Publisher
    // -----------------------------------------------------------------------------------------------------------------

    function test_DEC120_publishesWithInstantConsistencyAndTheCoreVaultAsEmitter() public {
        OrderCodec.Order memory o = _unwind();
        o.deadline = uint64(block.timestamp) + OrderCodec.ORDER_LIFETIME; // what publish writes
        vm.expectEmit(address(coreVault));
        emit OrderPublisherHarness.OrderPublished(OrderCodec.UNWIND, h.orderId(o), 0);
        uint64 sequence = coreVault.publish(address(core), o);
        assertEq(sequence, 0, "a Wormhole emitter's first sequence is 0");
        MockOrderCore.Published memory p = core.published(0);
        assertEq(p.emitter, address(coreVault), "DEC-111: the Core Vault is the emitter");
        assertEq(p.consistencyLevel, 200, "DEC-120 item 1: instant consistency");
        assertEq(p.nonce, 0);
        assertEq(p.payload, h.encode(o));
        assertEq(p.value, 0);

        assertEq(coreVault.publish(address(core), o), 1, "per-emitter sequence");
    }

    /// @dev Doc 32 §4.2 (confirmed by DEC-120): the order carries a deadline. The publisher writes it from its own
    ///      clock, so a Hub caller can publish neither an order that never expires nor one already expired.
    function test_DEC120_publishWritesTheDeadlineWhateverTheCallerWrote() public {
        vm.warp(1_900_000_000);
        uint64[3] memory written = [uint64(0), 1, type(uint64).max];
        for (uint256 i; i < written.length; ++i) {
            OrderCodec.Order memory o = _unwind();
            o.deadline = written[i];
            uint64 sequence = coreVault.publish(address(core), o);
            OrderCodec.Order memory d = h.decode(core.published(sequence).payload);
            assertEq(d.deadline, 1_900_000_000 + 1 hours, "deadline = publish time + ORDER_LIFETIME");
        }
        assertEq(OrderCodec.ORDER_LIFETIME, 1 hours);
    }

    function test_publishForwardsTheMessageFee() public {
        core.setMessageFee(0.001 ether);
        vm.deal(address(this), 1 ether);
        uint64 sequence = coreVault.publish{value: 0.001 ether}(address(core), _unwind());
        assertEq(core.published(sequence).value, 0.001 ether);
        assertEq(address(core).balance, 0.001 ether);

        vm.expectRevert(abi.encodeWithSelector(MockOrderCore.WrongFee.selector, 0.002 ether, 0.001 ether));
        coreVault.publish{value: 0.002 ether}(address(core), _unwind());
    }

    function test_publishRefusesAnOrderTheSpokesWouldRefuse() public {
        OrderCodec.Order memory o = _unwind();
        o.fracDen = 0;
        vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, 1457, 0));
        coreVault.publish(address(core), o);
        assertEq(core.publishedCount(), 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Fuzz
    // -----------------------------------------------------------------------------------------------------------------

    function testFuzz_roundTripOfAnyValidUnwind(
        bytes32 requestId,
        uint32 attempt,
        uint64 deadline,
        uint256 fracNum,
        uint256 fracDen,
        uint16 maxLossBps,
        bool standard
    ) public view {
        fracDen = bound(fracDen, 1, type(uint256).max);
        fracNum = bound(fracNum, 0, fracDen);
        OrderCodec.Order memory o = OrderCodec.Order({
            kind: OrderCodec.UNWIND,
            fundId: FUND,
            requestId: requestId,
            attempt: attempt,
            deadline: deadline,
            fracNum: fracNum,
            fracDen: fracDen,
            maxLossBps: maxLossBps,
            payoutMode: standard ? 1 : 0
        });
        _same(o, h.decode(h.encode(o)));
    }

    function testFuzz_decodeAcceptsAnUnwindFractionIffAtMostOne(uint256 fracNum, uint256 fracDen) public {
        OrderCodec.Order memory o = _unwind();
        o.fracNum = fracNum;
        o.fracDen = fracDen;
        bytes memory payload = abi.encode(OrderCodec.VERSION, o);
        if (fracDen == 0 || fracNum > fracDen) {
            vm.expectRevert(abi.encodeWithSelector(OrderCodec.InvalidOrderFraction.selector, fracNum, fracDen));
            h.decode(payload);
        } else {
            _same(o, h.decode(payload));
        }
    }
}
