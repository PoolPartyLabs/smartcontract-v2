// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice DEC-115, DEC-125 item 3 (D-36): the minimum manager fee in force at creation is the floor of the Core
///         Vault's `decreaseManagerFee`; the fund starts at or above it.
contract CoreVaultManagerFeeFloorTest is CoreVaultFixture {
    function test_DEC125_constructorRefusesAFeeBelowTheMinimum() public {
        CoreVaultConfig memory c = _config(25);
        c.minPerformanceFeeBps = 2001;
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerFeeBelowMinimum.selector, 2000, 2001));
        new CoreVault(_mandate(2000), c);
    }

    function test_DEC125_decreaseStopsAtTheCreationMinimum() public {
        CoreVaultConfig memory c = _config(25);
        c.minPerformanceFeeBps = 1000;
        _deploy(_mandate(2000), c);
        assertEq(vault.minPerformanceFeeBps(), 1000);
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerFeeBelowMinimum.selector, 999, 1000));
        vault.decreaseManagerFee(999, 0);
        vault.decreaseManagerFee(1000, 0);
        vm.stopPrank();
        assertEq(vault.performanceFeeBps(), 1000);
    }
}
