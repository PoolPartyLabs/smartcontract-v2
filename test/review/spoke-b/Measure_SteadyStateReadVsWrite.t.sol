// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice Lead 1, what breaks first: once a large report is stored (grown in steps, each delivery adding what it can
///         afford), a later delivery rewrites mostly unchanged words (about 2,200 gas each) while a payout reads them
///         cold (about 2,100 each). On main the setup stored a 400-position report (about 4,800 words); since
///         MAX_OPEN_POSITIONS a report holds at most 32, so the setup stores the largest report the caps allow (32
///         positions, 64 Income sends home, 256 listed arrivals) and the test measures one more delivery of it against
///         an Instant claim and a deposit.
contract Measure_SteadyStateReadVsWrite is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        _dustPositions(SpokeVaultTypes.MAX_OPEN_POSITIONS);
        _incomeArrival(64);
        _dustSendsHome(64, TransferKind.Income);
        _dustArrivals(256);
        {
            (bytes memory payload, uint64 seq) = _publishPayload();
            vm.prank(keeper);
            receiver.deliver(_vaa(payload, seq));
        }
    }

    function test_measure_steadyStateDeliveryVersusPayoutRead() public {
        (bytes memory payload, uint64 seq,) = _publishMeasured();
        bytes memory vaa = _vaa(payload, seq);
        uint256 deliverGas = _deliverMeasured(vaa) + _intrinsic(vaa);

        vm.cool(address(receiver));
        vm.cool(address(vault));
        vm.prank(alice);
        uint256 g = gasleft();
        vault.requestPayout(10_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0); // its own claim (DEC-120 item 1)
        uint256 claimGas = g - gasleft();
        uint256 depositGas = _depositMeasured(bob, 10_000e6);

        console2.log("stored payload words          ", payload.length / 32);
        console2.log("steady-state deliver + intrinsic", deliverGas);
        console2.log("Instant claim (reads it cold) ", claimGas);
        console2.log("deposit (reads it cold)       ", depositGas);
        assertLt(deliverGas, 32_000_000, "the largest report the caps allow delivers in one transaction");
        assertLt(claimGas, 32_000_000, "and a payout reads it within one transaction");
    }
}

/// @notice Lead 1, keeper cost once the arrival window is full (it never drains, I-01): every later delivery rewrites
///         the 512 words of the 256 listed ids. Setup lists 256 arrivals and delivers that report.
contract Measure_FullWindowSteadyState is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        _dustArrivals(256);
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
    }

    function test_measure_everyLaterDeliveryWithAFullWindow() public {
        vm.warp(block.timestamp + 384);
        _refreshPrices();
        (bytes memory payload, uint64 seq,) = _publishMeasured();
        bytes memory vaa = _vaa(payload, seq);
        uint256 deliverGas = _deliverMeasured(vaa) + _intrinsic(vaa);
        console2.log("payload words                        ", payload.length / 32);
        console2.log("routine delivery with a full window  ", deliverGas);
    }
}
