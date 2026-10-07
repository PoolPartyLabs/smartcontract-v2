// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {Mandate, MandateLib, OperatingCashConfig} from "../../../src/mandate/Mandate.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";

contract OperatingCashMvpTest is CoreVaultFixture {
    function test_B03_mandateRejectsFloorOrTopUp() public {
        Mandate memory mandate = _mandate(2000);
        mandate.operatingCash = new OperatingCashConfig[](1);
        mandate.operatingCash[0] = OperatingCashConfig(HUB, 1, 0);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        new CoreVault(mandate, _config(25));
        mandate.operatingCash[0] = OperatingCashConfig(HUB, 0, 1);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        new CoreVault(mandate, _config(25));
    }

    function test_B03_managerCannotEnableCashEvenWithZeroSetter() public {
        vm.startPrank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(0, 0);
        vm.stopPrank();
        _deposit(alice, 5e6);
        assertEq(vault.operatingCash(), 0);
        assertEq(vault.operatingCashFloor(), 0);
        assertEq(vault.operatingCashTopUp(), 0);
    }
}
