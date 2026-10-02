// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {IManagerRegistry} from "../../../src/interfaces/IManagerRegistry.sol";

/// @notice DEC-112 (protocol slice between 5% and 50%, never 0) and DEC-115 / DEC-125 item 3 (minimum manager fee from
///         0 up to 1,000 bps), written by the API signer key that owns the registry.
contract ManagerRegistryMinTest is Test {
    address internal constant API_SIGNER = address(0xA51);
    address internal constant MANAGER = address(0x3A);

    ManagerRegistry internal registry;

    function setUp() public {
        registry = new ManagerRegistry(API_SIGNER);
    }

    function test_DEC112_sliceBoundsAreFiveToFiftyPercent() public view {
        assertEq(registry.MIN_PROTOCOL_SLICE_BPS(), 500);
        assertEq(registry.MAX_PROTOCOL_SLICE_BPS(), 5000);
        assertEq(registry.DEFAULT_PROTOCOL_SLICE_BPS(), 5000);
    }

    /// @dev DEC-112: 0 and 499 revert; 500 and 5,000 pass.
    function test_DEC112_sliceBelowFivePercentReverts() public {
        vm.startPrank(API_SIGNER);
        vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.ProtocolSliceBelowMin.selector, 0, 500));
        registry.setProtocolSliceBps(MANAGER, 0);
        vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.ProtocolSliceBelowMin.selector, 499, 500));
        registry.setProtocolSliceBps(MANAGER, 499);
        assertFalse(registry.hasEntry(MANAGER), "a refused write leaves no entry");

        registry.setProtocolSliceBps(MANAGER, 500);
        assertEq(registry.protocolSliceBps(MANAGER), 500);
        registry.setProtocolSliceBps(MANAGER, 5000);
        assertEq(registry.protocolSliceBps(MANAGER), 5000);
        vm.stopPrank();
    }

    /// @dev DEC-115, DEC-125 item 3: 0 at deployment, raised up to 1,000 bps with an event; above it reverts.
    function test_DEC125_minManagerFeeStartsAtZeroAndIsCappedAtTenPercent() public {
        assertEq(registry.minManagerFeeBps(), 0);
        assertEq(registry.MAX_MIN_MANAGER_FEE_BPS(), 1000);

        vm.expectEmit(address(registry));
        emit IManagerRegistry.MinManagerFeeSet(0, 1000);
        vm.prank(API_SIGNER);
        registry.setMinManagerFeeBps(1000);
        assertEq(registry.minManagerFeeBps(), 1000);

        vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.MinManagerFeeAboveMax.selector, 1001, 1000));
        vm.prank(API_SIGNER);
        registry.setMinManagerFeeBps(1001);

        vm.expectEmit(address(registry));
        emit IManagerRegistry.MinManagerFeeSet(1000, 0);
        vm.prank(API_SIGNER);
        registry.setMinManagerFeeBps(0);
        assertEq(registry.minManagerFeeBps(), 0);
    }

    /// @dev DEC-112: only the API signer (the owner) writes the minimum.
    function test_DEC112_onlyTheApiSignerSetsTheMinimum() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, MANAGER));
        vm.prank(MANAGER);
        registry.setMinManagerFeeBps(100);
    }

    function testFuzz_DEC125_minimumNeverAboveCap(uint16 bps) public {
        vm.prank(API_SIGNER);
        if (bps > 1000) {
            vm.expectRevert(abi.encodeWithSelector(IManagerRegistry.MinManagerFeeAboveMax.selector, bps, 1000));
            registry.setMinManagerFeeBps(bps);
            assertEq(registry.minManagerFeeBps(), 0);
        } else {
            registry.setMinManagerFeeBps(bps);
            assertEq(registry.minManagerFeeBps(), bps);
        }
    }
}
