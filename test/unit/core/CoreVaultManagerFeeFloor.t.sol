// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {MandateLib} from "../../../src/mandate/Mandate.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice DEC-182, DEC-184 (correcting DEC-115, DEC-125 item 3 and reading D-36): the performance fee is chosen at
///         creation within [1,000, 9,000] bps and never goes below 1,000; the floor is a core constant, not a
///         registry value read at creation.
contract CoreVaultManagerFeeFloorTest is CoreVaultFixture {
    function test_DEC184_constructorRefusesAFeeBelowTheFloor() public {
        vm.expectRevert(abi.encodeWithSelector(MandateLib.BpsBelowMin.selector, 999, 1000));
        new CoreVault(_mandate(999), _config(25));
    }

    function test_DEC184_decreaseStopsAtTheFloor() public {
        _deploy(_mandate(2000), _config(25));
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerFeeBelowMinimum.selector, 999, 1000));
        vault.decreaseManagerFee(999, 0);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ManagerFeeBelowMinimum.selector, 0, 1000));
        vault.decreaseManagerFee(0, 0);
        vault.decreaseManagerFee(1000, 0);
        vm.stopPrank();
        assertEq(vault.performanceFeeBps(), 1000);
    }
}
