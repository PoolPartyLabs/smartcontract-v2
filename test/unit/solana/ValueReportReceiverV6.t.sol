pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockReceiverCoreVault} from "../../mocks/receiver/MockReceiverCoreVault.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

contract ValueReportReceiverV6Test is Test {
    MockCoreBridge private bridge;
    MockReceiverCoreVault private vault;
    ValueReportReceiverV6 private receiver;

    function setUp() public {
        vm.warp(1_791_286_864);
        bridge = new MockCoreBridge();
        vault = new MockReceiverCoreVault();
        vm.mockCall(address(vault), abi.encodeWithSignature("mandateHash()"), abi.encode(bytes32(uint256(2))));
        receiver = new ValueReportReceiverV6(
            address(bridge),
            address(vault),
            bytes32(uint256(1)),
            SolanaFixture.spokes(),
            new SolanaSpokeRegistryV6(SolanaFixture.nativeConfig())
        );
        vault.setReceiver(address(receiver));
    }

    function _message(uint8 consistency, ReportCodecV6.Report memory report) private pure returns (bytes memory) {
        CoreBridgeVM memory message;
        message.version = 1;
        message.guardianSetIndex = 7;
        message.timestamp = 1_791_286_864;
        message.emitterChainId = 1;
        message.emitterAddress = SolanaFixture.EMITTER;
        message.sequence = 1_428_661;
        message.consistencyLevel = consistency;
        message.payload = ReportCodecV6.encode(report);
        return abi.encode(message);
    }

    function testAcceptSolanaFinalizedAndProjectWithoutTruncation() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        (uint256 index, uint64 sequence) = receiver.deliver(_message(32, report));
        assertEq(index, 1);
        assertEq(sequence, 1);
        assertEq(receiver.latestNativeReport(), ReportCodecV6.encode(report));
        (ReportCodec.Report memory projected,,) = receiver.latestReport(1);
        assertEq(projected.unallocated[0].token, SolanaMandateAlias());
        assertEq(projected.unallocated[0].amount, 50e6);
        assertEq(vault.calls(), 1);
        assertTrue(receiver.isReportFresh(1));
    }

    function SolanaMandateAlias() private view returns (address) {
        return receiver.nativeRegistry().token(SolanaFixture.USDC);
    }

    function testFuzzRejectEveryOtherSolanaConsistency(uint8 consistency) public {
        vm.assume(consistency != 32);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, consistency));
        receiver.deliver(_message(consistency, SolanaFixture.report(uint64(block.timestamp))));
    }

    function testUnknownEmitterRejectedBeforeFinality() public {
        CoreBridgeVM memory message =
            abi.decode(_message(1, SolanaFixture.report(uint64(block.timestamp))), (CoreBridgeVM));
        message.emitterAddress = bytes32(uint256(123));
        vm.expectRevert(
            abi.encodeWithSelector(IValueReportReceiver.UnknownEmitter.selector, uint16(1), message.emitterAddress)
        );
        receiver.deliver(abi.encode(message));
    }

    function testEvmKeepsV5AndConsistencyOne() public {
        CoreBridgeVM memory message;
        message.emitterChainId = 72;
        message.emitterAddress = bytes32(uint256(700));
        message.sequence = 1;
        message.consistencyLevel = 1;
        ReportCodec.Report memory report;
        report.fundId = bytes32(uint256(1));
        report.mandateHash = bytes32(uint256(2));
        report.spokeChainId = 4663;
        report.sequence = 1;
        report.timestamp = uint64(block.timestamp);
        message.payload = ReportCodec.encode(report);
        receiver.deliver(abi.encode(message));
        message.sequence = 2;
        message.consistencyLevel = 32;
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.NotFinalized.selector, uint8(32)));
        receiver.deliver(abi.encode(message));
    }

    function testReplayAndCallbackFailureAreAtomic() public {
        bytes memory message = _message(32, SolanaFixture.report(uint64(block.timestamp)));
        vault.setRevertOnCallback(true);
        vm.expectRevert("core vault rejects");
        receiver.deliver(message);
        assertFalse(receiver.hasReport(1));
        vault.setRevertOnCallback(false);
        receiver.deliver(message);
        vm.expectRevert(
            abi.encodeWithSelector(
                IValueReportReceiver.SequenceNotIncreasing.selector, uint64(1_428_661), uint64(1_428_661)
            )
        );
        receiver.deliver(message);
    }

    function testRejectStaleFutureWrongMandateAndWrongNativeCommitment() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp - 1601));
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportTooOld.selector, 1601, uint32(1600)));
        receiver.deliver(_message(32, report));
        report.timestamp = uint64(block.timestamp + 1601);
        vm.expectRevert(
            abi.encodeWithSelector(IValueReportReceiver.ReportFromFuture.selector, report.timestamp, block.timestamp)
        );
        receiver.deliver(_message(32, report));
        report.timestamp = uint64(block.timestamp);
        report.mandateHash = bytes32(uint256(99));
        vm.expectRevert(IValueReportReceiver.ReportMismatch.selector);
        receiver.deliver(_message(32, report));
        report.nativeMandateHash = 0;
        vm.expectRevert(ValueReportReceiverV6.InvalidNativeReport.selector);
        receiver.deliver(_message(32, report));
    }

    function testRejectMissingChangedPausedOrHookedStockState() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        report.mintStates[0].newMultiplierBits = 0x4000000000000000;
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK));
        receiver.deliver(_message(32, report));
        report.mintStates[0].newMultiplierBits = 0x3ff0000000000000;
        report.mintStates[0].paused = true;
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK));
        receiver.deliver(_message(32, report));
        report.mintStates = new ReportCodecV6.MintState[](0);
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK));
        receiver.deliver(_message(32, report));
    }

    function testUnknownAndDuplicateMintsRejected() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        report.unallocated[0].mint = bytes32(uint256(123));
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnknownMint.selector, bytes32(uint256(123))));
        receiver.deliver(_message(32, report));
        report.unallocated = new ReportCodecV6.TokenAmount[](2);
        report.unallocated[0] = ReportCodecV6.TokenAmount(SolanaFixture.USDC, 1);
        report.unallocated[1] = report.unallocated[0];
        vm.expectRevert(ValueReportReceiverV6.InvalidNativeReport.selector);
        receiver.deliver(_message(32, report));
    }

    function testInvalidGuardianVerificationRejected() public {
        bridge.setInvalid("invalid signatures");
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.InvalidVaa.selector, "invalid signatures"));
        receiver.deliver(_message(32, SolanaFixture.report(uint64(block.timestamp))));
    }
}
