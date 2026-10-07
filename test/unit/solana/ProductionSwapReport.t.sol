pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";

/// @notice DEC-079, DEC-080, DEC-192, DEC-198: actual signed-swap producer bytes, not a synthetic encoder.
contract ProductionSwapReportTest is Test {
    function testDecodeNonzeroTradingIncomeAndNvdaWitness() public view {
        bytes memory payload = vm.parseBytes(vm.readLine("solana/tests/swap/fixtures/production-report-v6.hex"));
        ReportCodecV6.Report memory report = ReportCodecV6.decode(payload);
        assertEq(ReportCodecV6.encode(report), payload);
        assertEq(payload.length, 1952);
        assertEq(report.positions.length, 1);
        assertGt(report.positions[0].liquidity, 0);
        assertEq(report.collectedIncome.length, 1);
        assertEq(report.collectedIncome[0].amount, 10);
        assertEq(report.cumulativeIncome[0].amount, 10);
        assertEq(report.mintStates.length, 1);
        assertEq(report.mintStates[0].multiplierBits, 0x3ff003c2ac1bf43f);
        assertEq(report.mintStates[0].newMultiplierBits, 0x3ff006f7d589fea9);
        assertEq(report.mintStates[0].effectiveAt, 1_789_000_200);
    }
}
