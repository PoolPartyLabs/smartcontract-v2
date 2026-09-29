// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeConfig} from "../../../src/mandate/Mandate.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockReceiverCoreVault} from "../../mocks/receiver/MockReceiverCoreVault.sol";

/// @notice Adversarial verification of ValueReportReceiver: fuzzed rejection surfaces, ordering attacks, callback
///         re-entry across spokes and malformed payloads.
contract ValueReportReceiverAdversarialTest is Test {
    uint16 internal constant WH_ROBINHOOD = 72;
    uint16 internal constant WH_BASE = 30;
    uint256 internal constant ROBINHOOD = 4663;
    uint256 internal constant BASE = 8453;
    uint32 internal constant MAX_AGE = 1588;
    bytes32 internal constant FUND = keccak256("fund-1");
    bytes32 internal constant SPOKE_VAULT = bytes32(uint256(uint160(0x5b0e)));
    bytes32 internal constant BASE_VAULT = bytes32(uint256(uint160(0xba5e)));
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    MockCoreBridge internal bridge;
    MockReceiverCoreVault internal vault;
    ValueReportReceiver internal receiver;

    function setUp() public {
        vm.warp(1_790_700_000);
        bridge = new MockCoreBridge();
        vault = new MockReceiverCoreVault();
        SpokeConfig[] memory s = new SpokeConfig[](2);
        s[0] = SpokeConfig({
            chainId: ROBINHOOD,
            wormholeChainId: WH_ROBINHOOD,
            spokeVault: SPOKE_VAULT,
            spokeToken: USDG,
            spokeCap: 1_000_000e6,
            maxReportAge: MAX_AGE
        });
        s[1] = SpokeConfig({
            chainId: BASE,
            wormholeChainId: WH_BASE,
            spokeVault: BASE_VAULT,
            spokeToken: address(0xB05C),
            spokeCap: 500_000e6,
            maxReportAge: 1200
        });
        receiver = new ValueReportReceiver(address(bridge), address(vault), FUND, s, 0);
        vault.setReceiver(address(receiver));
    }

    function _report(uint64 sequence, uint256 chainId, uint64 timestamp)
        internal
        pure
        returns (ReportCodec.Report memory r)
    {
        r.fundId = FUND;
        r.sequence = sequence;
        r.spokeChainId = chainId;
        r.blockNumber = 1;
        r.timestamp = timestamp;
    }

    function _vaa(uint16 chain, bytes32 emitter, uint64 sequence, uint8 consistency, bytes memory payload)
        internal
        pure
        returns (bytes memory)
    {
        CoreBridgeVM memory m;
        m.version = 1;
        m.emitterChainId = chain;
        m.emitterAddress = emitter;
        m.sequence = sequence;
        m.consistencyLevel = consistency;
        m.payload = payload;
        m.signatures = new GuardianSignature[](0);
        return abi.encode(m);
    }

    function _robinhoodVaa(uint64 sequence, uint8 consistency) internal view returns (bytes memory) {
        return _vaa(
            WH_ROBINHOOD,
            SPOKE_VAULT,
            sequence,
            consistency,
            ReportCodec.encode(_report(sequence, ROBINHOOD, uint64(block.timestamp)))
        );
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-093: consistency level
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Every consistency level except 1 (finalized) is rejected, including 0 and the instant levels 200/201.
    function testFuzz_DEC093_anyConsistencyOtherThanFinalizedIsRejected(uint8 level) public {
        vm.assume(level != 1);
        bytes memory vaa = _robinhoodVaa(0, level);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, level));
        receiver.deliver(vaa);
        assertFalse(receiver.hasReport(0));
        assertEq(vault.calls(), 0);
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-086: emitter pair (chain AND address)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Any (chain, address) pair outside the Mandate is unknown, including a Mandate vault address on any other
    ///      chain and a Mandate chain with any other address.
    function testFuzz_DEC086_emitterPairOutsideMandateIsRejected(uint16 chain, bytes32 emitter) public {
        bool known = (chain == WH_ROBINHOOD && emitter == SPOKE_VAULT) || (chain == WH_BASE && emitter == BASE_VAULT);
        vm.assume(!known);
        bytes memory payload = ReportCodec.encode(_report(0, ROBINHOOD, uint64(block.timestamp)));
        bytes memory vaa = _vaa(chain, emitter, 0, 1, payload);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, chain, emitter));
        receiver.deliver(vaa);
    }

    /// @dev The two Mandate vault addresses swapped across their chains are both unknown emitters.
    function test_DEC086_swappedEmitterPairsAreRejected() public {
        bytes memory payload = ReportCodec.encode(_report(0, ROBINHOOD, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, WH_ROBINHOOD, BASE_VAULT));
        receiver.deliver(_vaa(WH_ROBINHOOD, BASE_VAULT, 0, 1, payload));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, WH_BASE, SPOKE_VAULT));
        receiver.deliver(_vaa(WH_BASE, SPOKE_VAULT, 0, 1, payload));
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-093: ordering attacks
    // ------------------------------------------------------------------------------------------------------------

    /// @dev After n accepted reports, replaying any of them (or any lower sequence) is rejected; only the next
    ///      strictly greater one is accepted.
    function testFuzz_DEC093_replayOfAnyEarlierReportIsRejected(uint8 count, uint8 pick) public {
        count = uint8(bound(count, 1, 12));
        pick = uint8(bound(pick, 0, count - 1));
        bytes[] memory delivered = new bytes[](count);
        for (uint64 i; i < count; ++i) {
            delivered[i] = _robinhoodVaa(i, 1);
            receiver.deliver(delivered[i]);
        }
        vm.expectRevert(
            abi.encodeWithSelector(IValueReportReceiver.SequenceNotIncreasing.selector, uint64(count - 1), uint64(pick))
        );
        receiver.deliver(delivered[pick]);
        assertEq(receiver.lastWormholeSequence(0), count - 1);
        assertEq(vault.calls(), count);

        receiver.deliver(_robinhoodVaa(count, 1));
        assertEq(receiver.lastWormholeSequence(0), count);
    }

    /// @dev A higher VAA sequence cannot smuggle a report whose own counter went backwards (DEC-093 on both
    ///      counters), and the failed delivery leaves the last accepted report untouched.
    function test_DEC093_higherVaaSequenceCannotCarryOlderReportSequence() public {
        receiver.deliver(
            _vaa(WH_ROBINHOOD, SPOKE_VAULT, 5, 1, ReportCodec.encode(_report(9, ROBINHOOD, uint64(block.timestamp))))
        );
        bytes memory vaa =
            _vaa(WH_ROBINHOOD, SPOKE_VAULT, 6, 1, ReportCodec.encode(_report(8, ROBINHOOD, uint64(block.timestamp))));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportSequenceNotIncreasing.selector, 9, 8));
        receiver.deliver(vaa);
        assertEq(receiver.lastWormholeSequence(0), 5);
        (ReportCodec.Report memory stored,,) = receiver.latestReport(0);
        assertEq(stored.sequence, 9);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Callback re-entry across spokes
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The Core Vault callback for spoke 0 cannot deliver a valid report of spoke 1 inside the same call: the
    ///      guard is per contract, not per spoke, and the outer delivery reverts as a whole.
    function test_DEC093_callbackCannotDeliverAnotherSpokeReport() public {
        bytes memory baseVaa =
            _vaa(WH_BASE, BASE_VAULT, 0, 1, ReportCodec.encode(_report(0, BASE, uint64(block.timestamp))));
        vault.setReentry(baseVaa);
        bytes memory vaa = _robinhoodVaa(0, 1);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        receiver.deliver(vaa);
        assertFalse(receiver.hasReport(0));
        assertFalse(receiver.hasReport(1));

        // once the callback stops re-entering, both spokes accept their reports independently
        vault.setReentry("");
        receiver.deliver(vaa);
        receiver.deliver(baseVaa);
        assertTrue(receiver.hasReport(0));
        assertTrue(receiver.hasReport(1));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Malformed payloads
    // ------------------------------------------------------------------------------------------------------------

    /// @dev A guardian-signed VAA whose payload is not a ReportCodec report is never accepted, whatever its shape.
    function test_DEC093_malformedPayloadIsRejected() public {
        bytes[] memory payloads = new bytes[](4);
        payloads[0] = ""; // empty
        payloads[1] = abi.encode(uint256(1)); // version only
        payloads[2] = abi.encodePacked(uint256(1), keccak256("garbage")); // version + one junk word
        payloads[3] = abi.encodePacked(uint256(1), uint256(0x40), type(uint256).max); // offset to a huge array
        for (uint256 i; i < payloads.length; ++i) {
            bytes memory vaa = _vaa(WH_ROBINHOOD, SPOKE_VAULT, 0, 1, payloads[i]);
            vm.expectRevert();
            receiver.deliver(vaa);
            assertFalse(receiver.hasReport(0));
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-099: clock skew boundary (documents verifier finding: unbounded future timestamps)
    // ------------------------------------------------------------------------------------------------------------

    /// @dev A report whose timestamp is far ahead of the hub clock counts as age 0 and stays fresh until the hub
    ///      clock passes timestamp + maxReportAge. The emitter is the Mandate's own Spoke Vault, so this needs a
    ///      misbehaving spoke chain clock; recorded here so the bound is a deliberate choice, not an accident.
    function test_DEC099_reportTimestampFarAheadStaysFreshUntilItAges() public {
        uint64 ahead = uint64(block.timestamp) + 365 days;
        receiver.deliver(_vaa(WH_ROBINHOOD, SPOKE_VAULT, 0, 1, ReportCodec.encode(_report(0, ROBINHOOD, ahead))));
        assertTrue(receiver.isReportFresh(0));
        vm.warp(block.timestamp + 300 days);
        assertTrue(receiver.isReportFresh(0)); // still "fresh": age is clamped to 0 while the clock is behind
        vm.warp(uint256(ahead) + MAX_AGE);
        assertTrue(receiver.isReportFresh(0));
        vm.warp(uint256(ahead) + MAX_AGE + 1);
        assertFalse(receiver.isReportFresh(0));
    }
}
