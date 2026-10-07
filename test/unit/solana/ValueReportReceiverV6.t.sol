pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ValueReportReceiverV6} from "../../../src/report/ValueReportReceiverV6.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SpokeConfig} from "../../../src/mandate/Mandate.sol";
import {MockCoreBridge} from "../../mocks/receiver/MockCoreBridge.sol";
import {MockReceiverCoreVault} from "../../mocks/receiver/MockReceiverCoreVault.sol";
import {SolanaFixture} from "./SolanaFixture.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";

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

    function testAcceptNativeCommandGoldenResults() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        report.unwindResults = _fixtureBytes("solana/tests/report/fixtures/command-unwind.hex");
        report.collectionResults = _fixtureBytes("solana/tests/report/fixtures/command-collection.hex");
        receiver.deliver(_message(32, report));
        (ReportCodec.Report memory projected,,) = receiver.latestReport(1);
        SpokeUnwindTypes.OrderResult[] memory unwind = abi.decode(projected.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertEq(unwind[0].orderId, bytes32(uint256(11)));
        assertEq(unwind[0].amountToArrive, 999);
        assertEq(unwind[0].delivered, 2);
        SpokeIncomeTypes.CollectionResult[] memory income = abi.decode(projected.collectionResults, (SpokeIncomeTypes.CollectionResult[]));
        assertEq(income[0].resultId, 7);
        assertEq(income[0].round, 12);
        assertEq(income[0].tokens[0], SolanaMandateAlias());
        assertEq(income[0].sold[0], 1000);
        assertEq(income[0].amountToArrive, 999);
    }

    function _fixtureBytes(string memory path) private view returns (bytes memory) {
        bytes memory text = bytes(vm.readFile(path));
        while (text.length != 0 && uint8(text[text.length - 1]) <= 32) {
            assembly ("memory-safe") { mstore(text, sub(mload(text), 1)) }
        }
        return vm.parseBytes(string.concat("0x", string(text)));
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

    function testRejectDifferentReportAgesAndDuplicateEmitters() public {
        SpokeConfig[] memory configs = SolanaFixture.spokes();
        SolanaSpokeRegistryV6 registry = receiver.nativeRegistry();
        configs[1].maxReportAge = 1601;
        vm.expectRevert(ValueReportReceiverV6.InvalidConfiguration.selector);
        new ValueReportReceiverV6(address(bridge), address(vault), bytes32(uint256(1)), configs, registry);
        configs[1] = configs[0];
        vm.expectRevert(ValueReportReceiverV6.InvalidConfiguration.selector);
        new ValueReportReceiverV6(address(bridge), address(vault), bytes32(uint256(1)), configs, registry);
    }

    function testRejectRepeatedReportSequenceWithNewWormholeSequence() public {
        bytes memory raw = _message(32, SolanaFixture.report(uint64(block.timestamp)));
        receiver.deliver(raw);
        CoreBridgeVM memory message = abi.decode(raw, (CoreBridgeVM));
        ++message.sequence;
        vm.expectRevert(
            abi.encodeWithSelector(IValueReportReceiver.ReportSequenceNotIncreasing.selector, uint64(1), uint64(1))
        );
        receiver.deliver(abi.encode(message));
    }

    function testRejectWrongFundChainAndNonemptyCommandResult() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        report.fundId = 0;
        vm.expectRevert(IValueReportReceiver.ReportMismatch.selector);
        receiver.deliver(_message(32, report));
        report.fundId = bytes32(uint256(1));
        report.spokeChainId = 4663;
        vm.expectRevert(IValueReportReceiver.ReportMismatch.selector);
        receiver.deliver(_message(32, report));
        report.collectionResults = hex"01";
        vm.expectRevert();
        receiver.deliver(_message(32, report));
    }

    function testFreshnessBoundaryAndGuardedReentry() public {
        bytes memory raw = _message(32, SolanaFixture.report(uint64(block.timestamp)));
        vault.setReentry(raw);
        vm.expectRevert(abi.encodeWithSignature("ReentrancyGuardReentrantCall()"));
        receiver.deliver(raw);
        assertFalse(receiver.hasReport(1));
        vault.setReentry("");
        receiver.deliver(raw);
        vm.warp(block.timestamp + 1600);
        assertTrue(receiver.isReportFresh(1));
        vm.warp(block.timestamp + 1);
        assertFalse(receiver.isReportFresh(1));
    }

    function testNativeClosureUnwindAndCollectionPreserveEvmSemantics() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        SpokeUnwindTypes.OrderResult[] memory unwind = new SpokeUnwindTypes.OrderResult[](1);
        unwind[0] = SpokeUnwindTypes.OrderResult(
            bytes32(uint256(10)),
            bytes32(uint256(11)),
            2,
            bytes32(uint256(12)),
            100e6,
            99_950_000,
            101e6,
            1e6,
            500_000,
            3,
            4,
            false,
            5
        );
        report.unwindResults = SpokeUnwindTypes.encodeResults(unwind);
        ReportCodecV6.CollectionResult[] memory collections = new ReportCodecV6.CollectionResult[](1);
        bytes32[] memory mints = new bytes32[](2);
        mints[0] = SolanaFixture.USDC;
        mints[1] = SolanaFixture.STOCK;
        uint256[] memory sold = new uint256[](2);
        sold[0] = 10e6;
        sold[1] = 1e8;
        uint256[] memory obtained = new uint256[](2);
        obtained[0] = 10e6;
        obtained[1] = 380e6;
        collections[0] =
            ReportCodecV6.CollectionResult(1, 2, bytes32(uint256(13)), 390e6, mints, sold, obtained, 389_805_000);
        report.collectionResults = abi.encode(collections);
        receiver.deliver(_message(32, report));
        (ReportCodec.Report memory projected,,) = receiver.latestReport(1);
        assertEq(projected.unwindResults, report.unwindResults);
        SpokeIncomeTypes.CollectionResult[] memory results =
            abi.decode(projected.collectionResults, (SpokeIncomeTypes.CollectionResult[]));
        assertEq(results[0].amountToArrive, collections[0].amountToArrive);
        assertEq(results[0].tokens[0], receiver.nativeRegistry().token(SolanaFixture.USDC));
        assertEq(results[0].tokens[1], receiver.nativeRegistry().token(SolanaFixture.STOCK));
        assertEq(results[0].sold, sold);
        assertEq(results[0].obtained, obtained);
    }

    function testNativeResultsRejectRefundsAndUnknownOrDuplicateMints() public {
        ReportCodecV6.Report memory report = SolanaFixture.report(uint64(block.timestamp));
        SpokeUnwindTypes.OrderResult[] memory unwind = new SpokeUnwindTypes.OrderResult[](1);
        unwind[0].refunded = true;
        report.unwindResults = SpokeUnwindTypes.encodeResults(unwind);
        vm.expectRevert(ReportCodecV6.NonCanonicalReport.selector);
        receiver.deliver(_message(32, report));
        report.unwindResults = "";
        ReportCodecV6.CollectionResult[] memory collections = new ReportCodecV6.CollectionResult[](1);
        collections[0].mints = new bytes32[](2);
        collections[0].mints[0] = SolanaFixture.USDC;
        collections[0].mints[1] = SolanaFixture.USDC;
        collections[0].sold = new uint256[](2);
        collections[0].obtained = new uint256[](2);
        report.collectionResults = abi.encode(collections);
        vm.expectRevert(ReportCodecV6.NonCanonicalReport.selector);
        receiver.deliver(_message(32, report));
        collections[0].mints[1] = bytes32(type(uint256).max);
        report.collectionResults = abi.encode(collections);
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnknownMint.selector, bytes32(type(uint256).max)));
        receiver.deliver(_message(32, report));
    }
}
