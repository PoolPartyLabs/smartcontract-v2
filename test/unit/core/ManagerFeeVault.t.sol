// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {IManagerFeeVault} from "../../../src/interfaces/IManagerFeeVault.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";

/// @notice The manager's fee vault on its own (ruling 2026-09-29, DEC-107, DEC-109): only the manager withdraws, never
///         to the zero address, and construction refuses zero addresses. Closes the branch gaps the coverage run of
///         2026-10-01 listed (1 of 3 branches hit).
contract ManagerFeeVaultTest is Test {
    address internal fund = makeAddr("coreVault");
    address internal manager = makeAddr("manager");
    CoreMockToken internal usdc;
    ManagerFeeVault internal feeVault;

    function setUp() public {
        usdc = new CoreMockToken("USD Coin", "USDC", 6);
        feeVault = new ManagerFeeVault(fund, manager);
        usdc.mint(address(feeVault), 1000e6);
    }

    function test_DEC107_constructorRefusesZeroAddresses() public {
        vm.expectRevert(IManagerFeeVault.ZeroAddress.selector);
        new ManagerFeeVault(address(0), manager);
        vm.expectRevert(IManagerFeeVault.ZeroAddress.selector);
        new ManagerFeeVault(fund, address(0));
    }

    function test_DEC107_onlyTheManagerWithdraws() public {
        vm.prank(fund);
        vm.expectRevert(abi.encodeWithSelector(IManagerFeeVault.NotManager.selector, fund));
        feeVault.withdraw(address(usdc), fund, 1);
    }

    function test_DEC107_withdrawToZeroAddressReverts() public {
        vm.prank(manager);
        vm.expectRevert(IManagerFeeVault.ZeroAddress.selector);
        feeVault.withdraw(address(usdc), address(0), 1);
    }

    function test_DEC107_managerWithdrawsWhereItChooses() public {
        address treasury = makeAddr("treasury");
        vm.expectEmit(address(feeVault));
        emit IManagerFeeVault.ManagerFeeWithdrawn(address(usdc), treasury, 400e6);
        vm.prank(manager);
        feeVault.withdraw(address(usdc), treasury, 400e6);
        assertEq(usdc.balanceOf(treasury), 400e6);
        assertEq(feeVault.balanceOf(address(usdc)), 600e6);
        assertEq(feeVault.fund(), fund);
        assertEq(feeVault.manager(), manager);
    }
}
