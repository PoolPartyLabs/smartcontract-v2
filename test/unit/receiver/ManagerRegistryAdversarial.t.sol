// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ManagerRegistry} from "../../../src/core/ManagerRegistry.sol";
import {IManagerRegistry} from "../../../src/interfaces/IManagerRegistry.sol";

/// @notice Adversarial verification of ManagerRegistry: fuzzed writer gate, cap invariant and ownership edge cases.
contract ManagerRegistryAdversarialTest is Test {
    address internal constant ADMIN = address(0xAD);
    ManagerRegistry internal registry;

    function setUp() public {
        registry = new ManagerRegistry(ADMIN);
    }

    /// @dev No address other than the owner can write, whatever the manager and bps; the pending owner included.
    function testFuzz_LC142_nonOwnerCannotWrite(address caller, address manager, uint16 bps) public {
        vm.assume(caller != ADMIN);
        vm.prank(ADMIN);
        registry.transferOwnership(caller); // even as pending owner
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        registry.setProtocolSliceBps(manager, bps);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        registry.clearProtocolSliceBps(manager);
        assertFalse(registry.hasEntry(manager));
    }

    /// @dev Whatever sequence of sets and clears the owner performs, the effective slice stays within [min, cap]
    ///      (DEC-112).
    function testFuzz_LC142_effectiveSliceNeverExceedsCap(address manager, uint16[8] memory values, uint8 clearMask)
        public
    {
        vm.assume(manager != address(0));
        uint16 maxBps = registry.MAX_PROTOCOL_SLICE_BPS();
        uint16 minBps = registry.MIN_PROTOCOL_SLICE_BPS();
        uint16 defaultBps = registry.DEFAULT_PROTOCOL_SLICE_BPS();
        for (uint256 i; i < values.length; ++i) {
            if (values[i] > maxBps) {
                vm.expectRevert(
                    abi.encodeWithSelector(IManagerRegistry.ProtocolSliceAboveMax.selector, values[i], maxBps)
                );
                vm.prank(ADMIN);
                registry.setProtocolSliceBps(manager, values[i]);
            } else if (values[i] < minBps) {
                vm.expectRevert(
                    abi.encodeWithSelector(IManagerRegistry.ProtocolSliceBelowMin.selector, values[i], minBps)
                );
                vm.prank(ADMIN);
                registry.setProtocolSliceBps(manager, values[i]);
            } else {
                vm.prank(ADMIN);
                registry.setProtocolSliceBps(manager, values[i]);
                assertEq(registry.protocolSliceBps(manager), values[i]);
            }
            if ((clearMask >> i) & 1 == 1) {
                vm.prank(ADMIN);
                registry.clearProtocolSliceBps(manager);
                assertEq(registry.protocolSliceBps(manager), defaultBps);
            }
            assertLe(registry.protocolSliceBps(manager), maxBps);
            assertGe(registry.protocolSliceBps(manager), minBps);
        }
    }

    /// @dev LC-142 (verifier finding, fixed): the writer cannot be renounced, so one call can never freeze every
    ///      manager's slice; strangers still get the Ownable error.
    function test_LC142_renounceOwnershipIsDisabled() public {
        vm.startPrank(ADMIN);
        registry.setProtocolSliceBps(address(0x3A), 1000);
        vm.expectRevert(IManagerRegistry.RenounceDisabled.selector);
        registry.renounceOwnership();
        vm.stopPrank();
        assertEq(registry.owner(), ADMIN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0x3B)));
        vm.prank(address(0x3B));
        registry.renounceOwnership();
        vm.prank(ADMIN);
        registry.setProtocolSliceBps(address(0x3A), 500);
        assertEq(registry.protocolSliceBps(address(0x3A)), 500);
    }
}
