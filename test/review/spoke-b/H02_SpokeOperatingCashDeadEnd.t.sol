// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice [H-08] (spoke-b report H-02), ported to main. The spoke Operating Cash sink seen end to end through the hub.
///         STILL_PRESENT (register S-5, Open, founder decision): `setOperatingCashParameters` is unbounded and any
///         arrival, a stranger's 1 USDG fill included, runs the top-up, so one parameter change moves the whole spoke
///         Unallocated Balance out of Share Assets and the freed Spoke Cap lets it repeat. FIXED part (S-5 interim):
///         `releaseOperatingCash` returned it above the floor; that verb was removed (S-63), so the sink is one-way.
contract H02_SpokeOperatingCashDeadEnd is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        _reportNow();
    }

    function _reportNow() internal {
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
    }

    function test_REGRESSION_REVIEW_H08_oneParameterChangeSinksTheSpokeAndTheCapLetsItRepeat() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(spoke.operatingCash(), 0);
    }

    /// @dev The sweep's interim release verb was removed on 2026-10-01 (S-63): a spoke sink followed by a release let
    ///      the manager free the Spoke Cap, send more, and bring the sunk principal back above the cap (11,995 USDC of
    ///      spoke value on a 4,000 cap, review port of integration-xchain). The sink is one-way again (SEC-OQ-2).
    function test_REVIEW_S63_noVerbReturnsTheSunkCash() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(spoke.operatingCash(), 0);
    }
}
