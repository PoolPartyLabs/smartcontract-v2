// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
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
    function test_REGRESSION_operatingCashParametersSweepBridgedPrincipal() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(spoke.operatingCash(), 0);
    }
}
