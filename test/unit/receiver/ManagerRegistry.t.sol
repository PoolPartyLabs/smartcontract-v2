// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {IManagerRegistry} from "../../../src/interfaces/IManagerRegistry.sol";

contract ManagerRegistryTest is Test {
    address internal constant ADMIN = address(0xAD);
    address internal constant NEW_ADMIN = address(0xAD2);
    address internal constant MANAGER = address(0x3A);

    ManagerRegistry internal registry;

    function setUp() public {
        registry = new ManagerRegistry(ADMIN);
    }

    function test_DEC106_defaultSliceIsFiftyPercentWithoutEntry() public view {
        assertEq(registry.DEFAULT_PROTOCOL_SLICE_BPS(), 5000);
        assertEq(registry.MAX_PROTOCOL_SLICE_BPS(), 5000);
        assertEq(registry.protocolSliceBps(MANAGER), 5000);
        assertFalse(registry.hasEntry(MANAGER));
    }

    function test_DEC110_ownerSetsSliceAndEmits() public {
        vm.expectEmit(address(registry));
        emit IManagerRegistry.ProtocolSliceSet(MANAGER, 5000, 2000, true);
        vm.prank(ADMIN);
        registry.setProtocolSliceBps(MANAGER, 2000);
        assertEq(registry.protocolSliceBps(MANAGER), 2000);
        assertTrue(registry.hasEntry(MANAGER));

        vm.expectEmit(address(registry));
        emit IManagerRegistry.ProtocolSliceSet(MANAGER, 2000, 3000, true);
        vm.prank(ADMIN);
        registry.setProtocolSliceBps(MANAGER, 3000);
    }

    function test_DEC052_clearReturnsToDefault() public {
        vm.startPrank(ADMIN);
        registry.setProtocolSliceBps(MANAGER, 1000);
        vm.expectEmit(address(registry));
        emit IManagerRegistry.ProtocolSliceSet(MANAGER, 1000, 5000, false);
        registry.clearProtocolSliceBps(MANAGER);
        vm.stopPrank();
        assertEq(registry.protocolSliceBps(MANAGER), 5000);
        assertFalse(registry.hasEntry(MANAGER));
    }

    function test_LC142_sliceAboveCapReverts() public {
        vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.ProtocolSliceAboveMax.selector, 5001, 5000));
        vm.prank(ADMIN);
        registry.setProtocolSliceBps(MANAGER, 5001);
    }

    function test_LC142_zeroManagerReverts() public {
        vm.startPrank(ADMIN);
        vm.expectRevert(IManagerRegistry.ZeroManager.selector);
        registry.setProtocolSliceBps(address(0), 100);
        vm.expectRevert(IManagerRegistry.ZeroManager.selector);
        registry.clearProtocolSliceBps(address(0));
        vm.stopPrank();
    }

    function test_LC142_onlyOwnerWrites() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MANAGER));
        vm.prank(MANAGER);
        registry.setProtocolSliceBps(MANAGER, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MANAGER));
        vm.prank(MANAGER);
        registry.clearProtocolSliceBps(MANAGER);
    }

    function test_LC142_ownable2StepHandover() public {
        vm.prank(ADMIN);
        registry.transferOwnership(NEW_ADMIN);
        assertEq(registry.owner(), ADMIN); // not yet: the new owner must accept
        assertEq(registry.pendingOwner(), NEW_ADMIN);

        // the pending owner cannot write before accepting
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_ADMIN));
        vm.prank(NEW_ADMIN);
        registry.setProtocolSliceBps(MANAGER, 600);

        // a stranger cannot accept
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MANAGER));
        vm.prank(MANAGER);
        registry.acceptOwnership();

        vm.prank(NEW_ADMIN);
        registry.acceptOwnership();
        assertEq(registry.owner(), NEW_ADMIN);
        assertEq(registry.pendingOwner(), address(0));

        vm.prank(NEW_ADMIN);
        registry.setProtocolSliceBps(MANAGER, 600);
        assertEq(registry.protocolSliceBps(MANAGER), 600);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ADMIN));
        vm.prank(ADMIN);
        registry.setProtocolSliceBps(MANAGER, 700);
    }

    function test_LC142_constructorRejectsZeroOwner() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new ManagerRegistry(address(0));
    }

    function testFuzz_DEC110_sliceWithinCapIsStored(address manager, uint16 bps) public {
        vm.assume(manager != address(0));
        vm.prank(ADMIN);
        if (bps > 5000) {
            vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.ProtocolSliceAboveMax.selector, bps, 5000));
            registry.setProtocolSliceBps(manager, bps);
            assertEq(registry.protocolSliceBps(manager), 5000);
        } else if (bps < 500) {
            // DEC-112: never below 5%.
            vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.ProtocolSliceBelowMin.selector, bps, 500));
            registry.setProtocolSliceBps(manager, bps);
            assertEq(registry.protocolSliceBps(manager), 5000);
        } else {
            registry.setProtocolSliceBps(manager, bps);
            assertEq(registry.protocolSliceBps(manager), bps);
        }
    }
}
