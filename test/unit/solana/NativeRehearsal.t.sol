pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {SolanaFixture} from "./SolanaFixture.sol";
import {Create3} from "../../../src/factory/Create3.sol";

contract NativeRehearsalTest is Test {
    function testNativeProducerReportRoundTripsHubDecoder() public view {
        bytes memory payload = vm.parseBytes(vm.readLine("solana/tests/rehearsal/fixtures/report-v6.hex"));
        ReportCodecV6.Report memory report = ReportCodecV6.decode(payload);
        assertEq(ReportCodecV6.encode(report), payload);
        assertEq(payload.length, 2176);
        assertEq(report.spokeChainId, 1);
        assertEq(report.sequence, 1);
        assertEq(report.positions.length, 2);
        assertEq(report.arrivedTransits.length, 1);
        assertEq(report.arrivedTransits[0].amount, 49_999_900);
        assertEq(report.cumulativeReceived, 49_999_900);
        assertEq(report.mintStates.length, 1);
        assertEq(report.mintStates[0].mint, bytes32(hex"07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a"));
        assertEq(report.mintStates[0].multiplierBits, 0x3ff0000000000000);
        assertEq(report.positions[0].pool, bytes32(0));
        assertGt(report.positions[0].principal0, 0);
        assertGt(report.positions[1].liquidity, 0);
    }

    function testConnectorDerivationMatchesRustFixture() public pure {
        address factory = address(0x0303030303030303030303030303030303030303);
        bytes32 salt = keccak256(abi.encode(bytes32(uint256(1)), bytes32("CctpReceiveConnector"), uint256(42161)));
        assertEq(Create3.addressOf(factory, salt), address(bytes20(hex"8c5438e4a5361b9b8d5a0e91a04c80083967ef9d")));
    }
}
