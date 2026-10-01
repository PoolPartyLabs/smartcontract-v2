// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice Lead 1, what breaks first: once a large report is stored (grown in steps, each delivery adding what it can
///         afford), a later delivery rewrites mostly unchanged words (about 2,200 gas each) while a payout reads them
///         cold (about 2,100 each). Setup stores a 400-position report (about 4,800 words) through four deliveries;
///         the test measures one more delivery of the same size against an Instant claim and a deposit.
contract Measure_SteadyStateReadVsWrite is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        for (uint256 step; step < 4; ++step) {
            _dustPositions(100);
            (bytes memory payload, uint64 seq) = _publishPayload();
            vm.prank(keeper);
            receiver.deliver(_vaa(payload, seq));
        }
        vm.prank(alice);
        vault.requestPayout(10_000e6, ICoreVault.PayoutMode.Instant);
    }

    function test_measure_steadyStateDeliveryVersusPayoutRead() public {
        (bytes memory payload, uint64 seq,) = _publishMeasured();
        bytes memory vaa = _vaa(payload, seq);
        uint256 deliverGas = _deliverMeasured(vaa) + _intrinsic(vaa);

        vm.cool(address(receiver));
        vm.cool(address(vault));
        vm.prank(alice);
        uint256 g = gasleft();
        vault.claimPayout("");
        uint256 claimGas = g - gasleft();
        uint256 depositGas = _depositMeasured(bob, 10_000e6);

        console2.log("stored payload words          ", payload.length / 32);
        console2.log("steady-state deliver + intrinsic", deliverGas);
        console2.log("Instant claim (reads it cold) ", claimGas);
        console2.log("deposit (reads it cold)       ", depositGas);
        assertGt(deliverGas, claimGas, "a delivery costs more per word than a payout's read");
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
