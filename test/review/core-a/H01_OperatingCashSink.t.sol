// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Review port of core-a H01, consolidated finding H-08 (register S-5, Open, founder decision). Hub Operating
///         Cash is outside Share Assets and outside `sweepExcess`, and `setOperatingCashParameters` takes any floor and
///         any top-up. Still true on main: the manager moves all Free Idle into it with one parameter change and one
///         allocation of 1 base unit, or lets the next third-party deposit do it. The sweep's interim release verb was removed
///         on 2026-10-01 (it let a manager and an ally extract the fund, S-63), so the sink is one-way again until the
///         founder rules on a cap (SEC-OQ-2).
contract H01_OperatingCashSink is CoreVaultFixture {
    address internal stranger = makeAddr("stranger");

    function test_REGRESSION_REVIEW_H08_managerMovesAllFreeIdleIntoOperatingCash() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }

    /// @dev The drain also runs from a third party's verb once the parameters are set: the next deposit tops up first
    ///      (the entrant is priced after it), so every existing holder is diluted by the whole Free Idle.
    function test_REGRESSION_REVIEW_H08_nextDepositRunsTheDrainForTheManager() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }
}
