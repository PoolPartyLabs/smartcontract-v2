// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AdapterGuard} from "../../src/adapters/AdapterGuard.sol";
import {IAdapterGuard} from "../../src/interfaces/IAdapterGuard.sol";

/// @dev Entry verb gated, exit verb never gated, as every adapter must do.
contract GuardedAdapterMock is AdapterGuard {
    uint256 public entries;
    uint256 public exits;

    constructor(address guardian_) AdapterGuard(guardian_) {}

    function enter() external {
        _requireEntryAllowed();
        ++entries;
    }

    function exit() external {
        ++exits;
    }
}

contract AdapterGuardTest is Test {
    GuardedAdapterMock internal adapter;
    address internal guardian = makeAddr("guardian");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        adapter = new GuardedAdapterMock(guardian);
    }

    function test_DEC021_zeroGuardianReverts() public {
        vm.expectRevert(AdapterGuard.ZeroGuardian.selector);
        new GuardedAdapterMock(address(0));
    }

    function test_DEC021_onlyGuardianPauses() public {
        vm.expectRevert(abi.encodeWithSelector(IAdapterGuard.NotGuardian.selector, stranger));
        vm.prank(stranger);
        adapter.setPaused(true);
        vm.expectEmit(false, false, false, true, address(adapter));
        emit IAdapterGuard.PausedSet(true);
        vm.prank(guardian);
        adapter.setPaused(true);
        assertTrue(adapter.paused());
    }

    /// DEC-056: quarantine blocks entry, never exit; it is reversible.
    function test_DEC056_pauseBlocksEntryNeverExit() public {
        vm.prank(guardian);
        adapter.setPaused(true);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.enter();
        adapter.exit();
        assertEq(adapter.exits(), 1);
        vm.prank(guardian);
        adapter.setPaused(false);
        adapter.enter();
        assertEq(adapter.entries(), 1);
    }

    /// DEC-058: deprecation is guardian-only, irreversible, blocks entry and never exit.
    function test_DEC058_deprecationIsIrreversibleAndWithdrawOnly() public {
        vm.expectRevert(abi.encodeWithSelector(IAdapterGuard.NotGuardian.selector, stranger));
        vm.prank(stranger);
        adapter.deprecate();

        vm.expectEmit(false, false, false, false, address(adapter));
        emit IAdapterGuard.AdapterDeprecated();
        vm.prank(guardian);
        adapter.deprecate();
        assertTrue(adapter.deprecated());

        vm.prank(guardian);
        adapter.deprecate(); // no-op
        vm.prank(guardian);
        adapter.setPaused(false);
        assertTrue(adapter.deprecated());

        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        adapter.enter();
        adapter.exit();
        assertEq(adapter.exits(), 1);
    }
}
