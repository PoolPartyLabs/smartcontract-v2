// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice Lead 1 (report bloat), measurement only, ported to main. Gas of `report()` on the spoke, of `deliver()` on
///         the hub and of a deposit's valuation, as a function of what the report lists. Every scenario starts from the
///         same committed state: a 1,000,000 USDC fund with 99,950 USDG on the spoke and one small report already
///         stored by the receiver. Storage is cooled before each measurement. Changes from e5c778a: sends home are
///         capped at `MAX_HUB_BOUND_IN_FLIGHT` = 64 (S-11), so the 100/200/300-send scenarios are measured at 64 and
///         the pruning scenario at 64; positions and arrivals are unchanged (still uncapped). Core Bridge stand-in
///         decodes the VM instead of verifying signatures (the real Arbitrum Core costs about 146,000 gas more).
contract Measure_ReportBloat is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
        _incomeArrival(1000e6); // collected income on the spoke, so Income-kind dust sends are possible
    }

    function _scenario(string memory name, uint256 arrivals, uint256 principalSends, uint256 incomeSends, uint256 pos)
        internal
    {
        _dustArrivals(arrivals);
        _dustSendsHome(principalSends, TransferKind.Principal);
        _dustSendsHome(incomeSends, TransferKind.Income);
        _dustPositions(pos);

        (bytes memory payload, uint64 seq, uint256 reportGas) = _publishMeasured();
        bytes memory vaa = _vaa(payload, seq);
        uint256 intrinsic = _intrinsic(vaa);
        uint256 deliverGas = _deliverMeasured(vaa);
        uint256 depositGas = _depositMeasured(bob, 10_000e6);

        console2.log("==", name);
        console2.log("   payload words              ", payload.length / 32);
        console2.log("   spoke report() gas         ", reportGas);
        console2.log("   hub deliver() execution gas", deliverGas);
        console2.log("   hub deliver() + intrinsic  ", deliverGas + intrinsic);
        console2.log("   hub deposit() gas          ", depositGas);
    }

    function test_measure_00_baseline() public {
        _scenario("baseline (1 token pair, no bloat)", 0, 0, 0, 0);
    }

    function test_measure_01_stranger256Arrivals() public {
        _scenario("stranger: 256 arrivals of 1 USDG", 256, 0, 0, 0);
    }

    function test_measure_02_manager32PrincipalSends() public {
        _scenario("manager: 32 dust sends home (Principal)", 0, 32, 0, 0);
    }

    function test_measure_03_manager64PrincipalSends() public {
        _scenario("manager: 64 dust sends home (Principal, the cap)", 0, 64, 0, 0);
    }

    function test_measure_05_manager64IncomeSends() public {
        _scenario("manager: 64 dust sends home (Income, the cap)", 0, 0, 64, 0);
    }

    /// @dev Since MAX_OPEN_POSITIONS (32) a manager cannot open more; on main 50 and 100 positions cost 9.19M and
    ///      18.06M to deliver.
    function test_measure_06_manager32Positions() public {
        _scenario("manager: 32 dust positions (the cap)", 0, 0, 0, 32);
    }

    function test_measure_07_worstCase() public {
        _scenario("stranger 256 arrivals + manager 64 Income sends + 32 positions", 256, 0, 64, 32);
    }

    function test_measure_08_arrivalsPlus64Sends() public {
        _scenario("stranger 256 arrivals + manager 64 Principal sends", 256, 64, 0, 0);
    }

    /// @dev The spoke side: `report()` prunes expired sends home in the same call. On main a send is listed for
    ///      `fillDeadline + HUB_BOUND_RETENTION` (3 days), not `fillDeadline + maxReportAge`.
    function test_measure_09_spokeReportPruning64ExpiredSends() public {
        _dustSendsHome(64, TransferKind.Principal);
        vm.warp(block.timestamp + 21_600 + ReportCodec.HUB_BOUND_RETENTION + 1);
        _refreshPrices();
        (bytes memory payload,, uint256 reportGas) = _publishMeasured();
        console2.log("== spoke report() pruning 64 expired sends home");
        console2.log("   payload words              ", payload.length / 32);
        console2.log("   spoke report() gas         ", reportGas);
        assertEq(spoke.inFlightTransitIds().length, 0);
    }
}
