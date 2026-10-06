pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {VaaLib, Vaa} from "wormhole-sdk/libraries/VaaLib.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

contract ReportCodecV6Harness {
    function decode(bytes memory payload) external pure returns (ReportCodecV6.Report memory) {
        return ReportCodecV6.decode(payload);
    }
}

contract ReportCodecV6Test is Test {
    function testGoldenVectorByteForByte() public view {
        bytes memory golden = vm.parseBytes(vm.readLine("test/fixtures/solana-report-v6.hex"));
        ReportCodecV6.Report memory report = SolanaFixture.report(1_791_286_864);
        report.nativeMandateHash = bytes32(uint256(3));
        assertEq(ReportCodecV6.encode(report), golden);
        ReportCodecV6.Report memory decoded = ReportCodecV6.decode(golden);
        assertEq(decoded.unallocated[0].mint, SolanaFixture.USDC);
        assertEq(decoded.mintStates[0].multiplierBits, 0x3ff0000000000000);
        assertEq(decoded.arrivedTransits[0].amount, 49_990_000);
    }

    function testRealSolanaVaaEnvelopeShape() public view {
        bytes memory raw = vm.parseBytes(string.concat("0x", vm.readLine("test/fixtures/solana-finalized.vaa.hex")));
        Vaa memory decoded = VaaLib.decodeVaaStructMem(raw);
        assertEq(raw.length, 1048);
        assertEq(decoded.envelope.emitterChainId, 1);
        assertEq(decoded.envelope.emitterAddress, SolanaFixture.EMITTER);
        assertEq(decoded.envelope.sequence, 1_428_661);
        assertEq(decoded.envelope.consistencyLevel, 32);
        assertEq(decoded.envelope.timestamp, 1_791_286_864);
        assertEq(decoded.header.version, 1);
        assertEq(uint8(raw[4]), 7);
        assertEq(uint8(raw[5]), 13);
    }

    function testPopulatedGoldenPreservesSignedTicksAndIncomeTransit() public view {
        bytes memory golden = vm.parseBytes(vm.readLine("test/fixtures/solana-report-v6-position.hex"));
        ReportCodecV6.Report memory report = SolanaFixture.report(1_791_286_864);
        report.nativeMandateHash = bytes32(uint256(3));
        report.positions = new ReportCodecV6.Position[](1);
        report.positions[0] = ReportCodecV6.Position(
            bytes32(uint256(300)),
            bytes32(uint256(400)),
            0,
            bytes32(type(uint256).max),
            -100,
            100,
            1000,
            SolanaFixture.STOCK,
            SolanaFixture.USDC,
            12,
            34,
            56,
            78
        );
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        report.inFlightToHub[0] = ReportCodec.HubBoundAmount(bytes32(uint256(901)), 48_000_000, TransferKind.Income);
        assertEq(ReportCodecV6.encode(report), golden);
        ReportCodecV6.Report memory decoded = ReportCodecV6.decode(golden);
        assertEq(decoded.positions[0].tickLower, -100);
        assertEq(decoded.positions[0].position, bytes32(type(uint256).max));
        assertEq(uint8(decoded.inFlightToHub[0].kind), 1);
    }

    function testRejectWrongVersionAndTrailingBytes() public {
        ReportCodecV6Harness harness = new ReportCodecV6Harness();
        ReportCodecV6.Report memory report = SolanaFixture.report(1_791_286_864);
        vm.expectRevert(abi.encodeWithSelector(ReportCodec.UnsupportedReportVersion.selector, uint256(5)));
        harness.decode(abi.encode(uint256(5), report));
        vm.expectRevert(ReportCodecV6.NonCanonicalReport.selector);
        harness.decode(bytes.concat(ReportCodecV6.encode(report), hex"00"));
    }

    function testFullPositionKeysAndClosedVenueValidation() public {
        SolanaSpokeRegistryV6 registry = new SolanaSpokeRegistryV6(SolanaFixture.nativeConfig());
        ReportCodecV6.Position memory position;
        position.program = bytes32(uint256(300));
        position.pool = bytes32(uint256(400));
        position.position = bytes32(type(uint256).max);
        position.token0 = SolanaFixture.STOCK;
        position.token1 = SolanaFixture.USDC;
        position.tickLower = -100;
        position.tickUpper = 100;
        position.liquidity = 1000;
        registry.validatePosition(position);
        position.pool = bytes32(uint256(401));
        vm.expectRevert(SolanaSpokeRegistryV6.UnknownVenue.selector);
        registry.validatePosition(position);
        position.program = bytes32(uint256(500));
        position.pool = 0;
        position.reserve = bytes32(uint256(600));
        position.token0 = SolanaFixture.USDC;
        position.token1 = 0;
        position.tickLower = 0;
        position.tickUpper = 0;
        position.liquidity = 0;
        registry.validatePosition(position);
    }
}
