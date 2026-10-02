pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {CheckAlphaDeployment} from "../../../script/CheckAlphaDeployment.s.sol";

contract AlphaCheckHarness is CheckAlphaDeployment {
    function checkGetter(address target, address expected) external view {
        _addressGetter(target, "owner()", expected);
    }

    function checkLink(address target, address libraryAddress) external view {
        _link(target, libraryAddress);
    }

    function plan() external view returns (FundPlan memory) {
        return _plan(address(1));
    }
}

contract AlphaDeploymentCheckTest is Test {
    AlphaCheckHarness internal checker;

    function setUp() public {
        checker = new AlphaCheckHarness();
    }

    function test_DEC134_readOnlyGetterPasses() public view {
        checker.checkGetter(address(this), address(123));
    }

    function test_DEC134_wrongGetterFails() public {
        vm.expectRevert(abi.encodeWithSelector(CheckAlphaDeployment.CheckFailed.selector, "owner()", address(this)));
        checker.checkGetter(address(this), address(124));
    }

    function test_DEC134_missingCodeFails() public {
        vm.expectRevert();
        checker.checkGetter(address(123), address(123));
    }

    function test_DEC131_missingRuntimeLinkFails() public {
        vm.expectRevert(
            abi.encodeWithSelector(CheckAlphaDeployment.CheckFailed.selector, "runtime library link", address(this))
        );
        checker.checkLink(address(this), address(checker));
    }

    function test_DEC053_poolParametersAreConfigurable() public {
        vm.setEnv("HUB_POOL_FEE", "3000");
        vm.setEnv("HUB_POOL_TICK_SPACING", "60");
        vm.setEnv("HUB_AAVE_ASSET", "0x0000000000000000000000000000000000000000");
        assertEq(checker.plan().hubPool.fee, 3000);
        assertEq(checker.plan().hubPool.tickSpacing, 60);
        assertEq(checker.plan().hubAaveAsset, address(0));
        vm.setEnv("HUB_POOL_FEE", "500");
        vm.setEnv("HUB_POOL_TICK_SPACING", "10");
        vm.setEnv("HUB_AAVE_ASSET", "0xaf88d065e77c8cC2239327C5EDb3A432268e5831");
        vm.setEnv("HUB_POOL_FEE", "16777216");
        vm.expectRevert("pool fee overflow");
        checker.plan();
        vm.setEnv("HUB_POOL_FEE", "500");
        vm.setEnv("SPOKE_POOL_TICK_SPACING", "-1");
        vm.expectRevert("invalid tick spacing");
        checker.plan();
        vm.setEnv("SPOKE_POOL_TICK_SPACING", "10");
    }

    function owner() external pure returns (address) {
        return address(123);
    }
}
