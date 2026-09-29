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

contract ValueReportReceiverTest is Test {
    uint16 internal constant WH_ROBINHOOD = 72;
    uint16 internal constant WH_BASE = 30;
    uint256 internal constant ROBINHOOD = 4663;
    uint256 internal constant BASE = 8453;
    uint32 internal constant MAX_AGE = 1588; // Robinhood research value 1,587 s plus one block (Q66 OPEN)
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
        receiver = new ValueReportReceiver(address(bridge), address(vault), FUND, _spokes(), 0);
        vault.setReceiver(address(receiver));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------------------------------------------

    function _spokes() internal pure returns (SpokeConfig[] memory s) {
        s = new SpokeConfig[](2);
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
    }

    function _report(uint64 sequence, uint64 timestamp) internal pure returns (ReportCodec.Report memory r) {
        r.fundId = FUND;
        r.sequence = sequence;
        r.spokeChainId = ROBINHOOD;
        r.blockNumber = 75_000_000;
        r.timestamp = timestamp;
        r.unallocated = new ReportCodec.TokenAmount[](1);
        r.unallocated[0] = ReportCodec.TokenAmount(USDG, 1000e6 + uint256(sequence));
        r.cumulativeReceived = 10_000e6;
    }

    function _vaa(uint16 chain, bytes32 emitter, uint64 wormholeSequence, uint8 consistency, bytes memory payload)
        internal
        pure
        returns (bytes memory)
    {
        CoreBridgeVM memory m;
        m.version = 1;
        m.emitterChainId = chain;
        m.emitterAddress = emitter;
        m.sequence = wormholeSequence;
        m.consistencyLevel = consistency;
        m.payload = payload;
        m.signatures = new GuardianSignature[](0);
        return abi.encode(m);
    }

    function _vaa(uint64 wormholeSequence, ReportCodec.Report memory r) internal pure returns (bytes memory) {
        return _vaa(WH_ROBINHOOD, SPOKE_VAULT, wormholeSequence, 1, ReportCodec.encode(r));
    }

    function _deliverFresh(uint64 wormholeSequence, uint64 reportSequence) internal {
        receiver.deliver(_vaa(wormholeSequence, _report(reportSequence, uint64(block.timestamp) - 900)));
    }

    // ------------------------------------------------------------------------------------------------------------
    // Acceptance
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC093_firstReportAcceptsSequenceZeroAndNotifiesCoreVault() public {
        ReportCodec.Report memory r = _report(0, uint64(block.timestamp) - 900);
        vm.expectEmit(address(receiver));
        emit IValueReportReceiver.ReportAccepted(0, WH_ROBINHOOD, SPOKE_VAULT, 0, 0, r.blockNumber, r.timestamp);
        vm.prank(address(0xCAFE)); // DEC-093: anyone may deliver
        (uint256 spokeIndex, uint64 reportSequence) = receiver.deliver(_vaa(0, r));

        assertEq(spokeIndex, 0);
        assertEq(reportSequence, 0);
        assertTrue(receiver.hasReport(0));
        assertFalse(receiver.hasReport(1));
        assertEq(vault.calls(), 1);
        assertEq(vault.lastSpokeIndex(), 0);

        (ReportCodec.Report memory stored, uint64 wormholeSequence, uint64 acceptedAt) = receiver.latestReport(0);
        assertEq(keccak256(abi.encode(stored)), keccak256(abi.encode(r)));
        assertEq(wormholeSequence, 0);
        assertEq(acceptedAt, block.timestamp);
    }

    function test_DEC093_coreVaultReadsStoredReportInsideCallback() public {
        _deliverFresh(4, 9);
        assertEq(vault.sequenceSeenInCallback(), 9);
        assertEq(receiver.lastWormholeSequence(0), 4);
        assertEq(receiver.lastReportSequence(0), 9);
    }

    function test_DEC093_laterReportReplacesLatest() public {
        _deliverFresh(1, 1);
        vm.warp(block.timestamp + 400);
        _deliverFresh(5, 2);
        (ReportCodec.Report memory stored, uint64 wormholeSequence,) = receiver.latestReport(0);
        assertEq(stored.sequence, 2);
        assertEq(stored.unallocated[0].amount, 1000e6 + 2);
        assertEq(wormholeSequence, 5);
        assertEq(vault.calls(), 2);
    }

    function test_DEC093_sequencesAreTrackedPerSpoke() public {
        _deliverFresh(7, 7);
        ReportCodec.Report memory r = _report(1, uint64(block.timestamp) - 10);
        r.spokeChainId = BASE;
        (uint256 spokeIndex,) = receiver.deliver(_vaa(WH_BASE, BASE_VAULT, 1, 1, ReportCodec.encode(r)));
        assertEq(spokeIndex, 1);
        assertEq(receiver.lastWormholeSequence(0), 7);
        assertEq(receiver.lastWormholeSequence(1), 1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Rejections
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC086_rejectsVaaTheCoreBridgeRejects() public {
        bridge.setInvalid("signature invalid");
        bytes memory vaa = _vaa(0, _report(0, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.InvalidVaa.selector, "signature invalid"));
        receiver.deliver(vaa);
    }

    function test_DEC093_rejectsNonFinalizedConsistency() public {
        bytes memory payload = ReportCodec.encode(_report(0, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, uint8(200)));
        receiver.deliver(_vaa(WH_ROBINHOOD, SPOKE_VAULT, 0, 200, payload));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, uint8(201)));
        receiver.deliver(_vaa(WH_ROBINHOOD, SPOKE_VAULT, 0, 201, payload));
    }

    function test_DEC086_rejectsUnknownEmitterAddress() public {
        bytes32 stranger = bytes32(uint256(uint160(0xBAD)));
        bytes memory payload = ReportCodec.encode(_report(0, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, WH_ROBINHOOD, stranger));
        receiver.deliver(_vaa(WH_ROBINHOOD, stranger, 0, 1, payload));
    }

    function test_DEC086_rejectsSpokeVaultAddressFromAnotherChain() public {
        bytes memory payload = ReportCodec.encode(_report(0, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, WH_BASE, SPOKE_VAULT));
        receiver.deliver(_vaa(WH_BASE, SPOKE_VAULT, 0, 1, payload));
    }

    function test_DEC093_rejectsReplay() public {
        bytes memory vaa = _vaa(3, _report(3, uint64(block.timestamp) - 5));
        receiver.deliver(vaa);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.SequenceNotIncreasing.selector, 3, 3));
        receiver.deliver(vaa);
    }

    function test_DEC093_rejectsOutOfOrderVaaSequence() public {
        _deliverFresh(10, 10);
        bytes memory older = _vaa(9, _report(11, uint64(block.timestamp) - 5));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.SequenceNotIncreasing.selector, 10, 9));
        receiver.deliver(older);
    }

    function test_DEC093_rejectsReportSequenceNotIncreasing() public {
        _deliverFresh(10, 10);
        bytes memory vaa = _vaa(11, _report(10, uint64(block.timestamp) - 5));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportSequenceNotIncreasing.selector, 10, 10));
        receiver.deliver(vaa);
    }

    function test_DEC070_rejectsAnotherFundsReport() public {
        ReportCodec.Report memory r = _report(0, uint64(block.timestamp));
        r.fundId = keccak256("fund-2");
        bytes memory vaa = _vaa(0, r);
        vm.expectRevert(IValueReportReceiver.ReportMismatch.selector);
        receiver.deliver(vaa);
    }

    function test_DEC086_rejectsReportForAnotherChainThanItsEmitter() public {
        ReportCodec.Report memory r = _report(0, uint64(block.timestamp));
        r.spokeChainId = BASE;
        bytes memory vaa = _vaa(0, r);
        vm.expectRevert(IValueReportReceiver.ReportMismatch.selector);
        receiver.deliver(vaa);
    }

    function test_DEC093_rejectsUnknownPayloadVersion() public {
        bytes memory payload = abi.encode(uint256(2), _report(0, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, 2));
        receiver.deliver(_vaa(WH_ROBINHOOD, SPOKE_VAULT, 0, 1, payload));
    }

    function test_DEC099_rejectsReportOlderThanMaxAge() public {
        bytes memory vaa = _vaa(0, _report(0, uint64(block.timestamp) - MAX_AGE - 1));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportTooOld.selector, MAX_AGE + 1, MAX_AGE));
        receiver.deliver(vaa);
    }

    function test_DEC099_acceptsReportAtExactlyMaxAge() public {
        receiver.deliver(_vaa(0, _report(0, uint64(block.timestamp) - MAX_AGE)));
        assertTrue(receiver.isReportFresh(0));
    }

    function test_DEC099_reportTimestampAheadOfHubClockCountsAsAgeZero() public {
        receiver.deliver(_vaa(0, _report(0, uint64(block.timestamp) + 2)));
        assertTrue(receiver.isReportFresh(0));
    }

    function test_DEC093_failedDeliveryLeavesStateUntouched() public {
        _deliverFresh(1, 1);
        vault.setRevertOnCallback(true);
        bytes memory vaa = _vaa(2, _report(2, uint64(block.timestamp)));
        vm.expectRevert("core vault rejects");
        receiver.deliver(vaa);
        assertEq(receiver.lastWormholeSequence(0), 1);
        assertEq(receiver.lastReportSequence(0), 1);
    }

    function test_DEC093_coreVaultCannotReenterDeliver() public {
        vault.setReentry(_vaa(2, _report(2, uint64(block.timestamp))));
        bytes memory vaa = _vaa(1, _report(1, uint64(block.timestamp)));
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        receiver.deliver(vaa);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC099_isReportFreshFollowsMaxAge() public {
        assertFalse(receiver.isReportFresh(0)); // no report yet
        receiver.deliver(_vaa(0, _report(0, uint64(block.timestamp) - 1000)));
        assertTrue(receiver.isReportFresh(0));
        vm.warp(block.timestamp + MAX_AGE - 1000);
        assertTrue(receiver.isReportFresh(0));
        vm.warp(block.timestamp + 1);
        assertFalse(receiver.isReportFresh(0));
    }

    function test_DEC099_maxReportAgeComesFromTheMandate() public view {
        assertEq(receiver.maxReportAge(0), MAX_AGE);
        assertEq(receiver.maxReportAge(1), 1200);
        assertEq(receiver.spokeCount(), 2);
        assertEq(receiver.spokeIndexOf(WH_BASE, BASE_VAULT), 1);
        ValueReportReceiver.Spoke memory s = receiver.spoke(0);
        assertEq(s.chainId, ROBINHOOD);
        assertEq(s.spokeVault, SPOKE_VAULT);
        assertEq(receiver.coreBridge(), address(bridge));
        assertEq(receiver.coreVault(), address(vault));
        assertEq(receiver.fundId(), FUND);
    }

    function test_DEC099_unknownSpokeIndexReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ValueReportReceiver.UnknownSpoke.selector, 2));
        receiver.maxReportAge(2);
        vm.expectRevert(abi.encodeWithSelector(ValueReportReceiver.UnknownSpoke.selector, 2));
        receiver.isReportFresh(2);
    }

    function test_DEC093_latestReportRevertsWithoutReport() public {
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NoReport.selector, 0));
        receiver.latestReport(0);
    }

    function test_Q57d_variationBandIsStoredButNotEnforced() public {
        ValueReportReceiver banded = new ValueReportReceiver(address(bridge), address(vault), FUND, _spokes(), 200);
        vault.setReceiver(address(banded));
        assertEq(banded.variationBandBps(), 200);
        assertEq(receiver.variationBandBps(), 0);
        ReportCodec.Report memory r = _report(0, uint64(block.timestamp));
        banded.deliver(_vaa(0, r));
        r.sequence = 1;
        r.unallocated[0].amount = 10 * r.unallocated[0].amount; // +900%, far beyond a 2% band
        banded.deliver(_vaa(1, r));
        (ReportCodec.Report memory stored,,) = banded.latestReport(0);
        assertEq(stored.unallocated[0].amount, r.unallocated[0].amount);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC086_constructorRejectsZeroAddressesAndFund() public {
        SpokeConfig[] memory s = _spokes();
        vm.expectRevert(ValueReportReceiver.ZeroAddress.selector);
        new ValueReportReceiver(address(0), address(vault), FUND, s, 0);
        vm.expectRevert(ValueReportReceiver.ZeroAddress.selector);
        new ValueReportReceiver(address(bridge), address(0), FUND, s, 0);
        vm.expectRevert(ValueReportReceiver.ZeroFundId.selector);
        new ValueReportReceiver(address(bridge), address(vault), bytes32(0), s, 0);
    }

    function test_DEC099_constructorRejectsZeroMaxReportAge() public {
        SpokeConfig[] memory s = _spokes();
        s[1].maxReportAge = 0;
        vm.expectRevert(abi.encodeWithSelector(ValueReportReceiver.InvalidSpoke.selector, 1));
        new ValueReportReceiver(address(bridge), address(vault), FUND, s, 0);
    }

    function test_DEC086_constructorRejectsIncompleteSpoke() public {
        SpokeConfig[] memory s = _spokes();
        s[0].spokeVault = bytes32(0);
        vm.expectRevert(abi.encodeWithSelector(ValueReportReceiver.InvalidSpoke.selector, 0));
        new ValueReportReceiver(address(bridge), address(vault), FUND, s, 0);
    }

    function test_DEC093_constructorRejectsDuplicateEmitter() public {
        SpokeConfig[] memory s = _spokes();
        s[1].wormholeChainId = WH_ROBINHOOD;
        s[1].spokeVault = SPOKE_VAULT;
        vm.expectRevert(
            abi.encodeWithSelector(ValueReportReceiver.DuplicateEmitter.selector, WH_ROBINHOOD, SPOKE_VAULT)
        );
        new ValueReportReceiver(address(bridge), address(vault), FUND, s, 0);
    }

    function test_Q57d_constructorRejectsBandAboveOneHundredPercent() public {
        vm.expectRevert(abi.encodeWithSelector(ValueReportReceiver.VariationBandAboveMax.selector, 10_001));
        new ValueReportReceiver(address(bridge), address(vault), FUND, _spokes(), 10_001);
    }

    function test_OQ08_hubOnlyFundReceiverRejectsEveryEmitter() public {
        ValueReportReceiver hubOnly =
            new ValueReportReceiver(address(bridge), address(vault), FUND, new SpokeConfig[](0), 0);
        assertEq(hubOnly.spokeCount(), 0);
        bytes memory vaa = _vaa(0, _report(0, uint64(block.timestamp)));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, WH_ROBINHOOD, SPOKE_VAULT));
        hubOnly.deliver(vaa);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------------------------------------------------

    function testFuzz_DEC093_acceptsOnlyStrictlyIncreasingSequences(uint64 first, uint64 second) public {
        first = uint64(bound(first, 0, type(uint64).max - 1));
        _deliverFresh(first, first);
        bytes memory vaa = _vaa(second, _report(second, uint64(block.timestamp) - 1));
        if (second <= first) {
            vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.SequenceNotIncreasing.selector, first, second));
            receiver.deliver(vaa);
            assertEq(receiver.lastWormholeSequence(0), first);
        } else {
            receiver.deliver(vaa);
            assertEq(receiver.lastWormholeSequence(0), second);
        }
    }

    function testFuzz_DEC099_ageBoundAtDelivery(uint32 age) public {
        age = uint32(bound(age, 0, 1_000_000_000));
        uint64 timestamp = uint64(block.timestamp) - age;
        bytes memory vaa = _vaa(0, _report(0, timestamp));
        if (age > MAX_AGE) {
            vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportTooOld.selector, age, MAX_AGE));
            receiver.deliver(vaa);
        } else {
            receiver.deliver(vaa);
            assertTrue(receiver.hasReport(0));
        }
    }
}
