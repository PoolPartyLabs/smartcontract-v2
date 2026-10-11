// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";

contract HubClosureExposureTest is SpokeVaultTestBase {
    bytes32 internal position;

    function setUp() public {
        _setUpMocks();
        _deployHub();
        usdc.mint(address(core), 5e6);
        core.allocate(vault, 5e6);
        vm.prank(manager);
        (position,,) = vault.openPosition(address(hubAave), AAVE_USDC, 1e6, 0, "");
    }

    function _rejectExposure(ICoreVaultLifecycle.FundState state) internal {
        core.setFundState(state);
        bytes memory reason = abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, state);
        vm.startPrank(manager);
        vm.expectRevert(reason);
        vault.openPosition(address(hubAave), AAVE_USDC, 1e6, 0, "");
        vm.expectRevert(reason);
        vault.increasePosition(address(hubAave), position, 1e6, 0, "");
        vm.expectRevert(reason);
        vault.swap(address(hubSwap), address(usdc), address(weth), 1e6, 0, "");
        vm.stopPrank();
    }

    function test_B01_closingRejectsNewExposure() public {
        _rejectExposure(ICoreVaultLifecycle.FundState.Closing);
    }

    function test_B01_closedRejectsNewExposure() public {
        _rejectExposure(ICoreVaultLifecycle.FundState.Closed);
    }

    function test_B01_closingAllowsOnlySwapBackToBase() public {
        vm.prank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 1e6, 0, "");
        core.setFundState(ICoreVaultLifecycle.FundState.Closing);
        vm.prank(manager);
        vault.swap(address(hubSwap), address(weth), address(usdc), 0.0005e18, 0, "");
        assertEq(vault.unallocatedBalance(address(weth)), 0);
        core.setFundState(ICoreVaultLifecycle.FundState.Closed);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.FundNotOpen.selector, ICoreVaultLifecycle.FundState.Closed)
        );
        vault.swap(address(hubSwap), address(weth), address(usdc), 1, 0, "");
    }
}
