// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @title PoC: Operating Cash is a one-way sink, and its uncapped top-up can move all Free Idle into it
/// @notice Severity: MEDIUM (value permanently locked outside every base; the large variant needs the Manager).
///
/// Two facts of the shipped code, neither of which is a decision:
///  (a) No verb spends or returns Operating Cash. DEC-096 says it is distributed to the Shareholders at fund close and
///      DEC-102 that it pays operations, but the MVP "keeps the bucket and the top-up rule only" (ARCHITECTURE 4.7).
///      The contracts are immutable (DEC-058), so for every fund created on this version the bucket can only grow:
///      each top-up adds `operatingCashTopUp`, and none of it can ever leave. `sweepExcess` does not reach it
///      (`_ledger` counts it). DEC-144 removed the other feed: the Payout Fee of an Instant Payout (DEC-102) now stays
///      in Idle.
///  (b) `setOperatingCashParameters(floor, topUp)` has no cap on `topUp` (DEC-100 only decides "no protocol cap on
///      the floor"). `_topUpOperatingCash` runs at the start of `deposit`, `claimPayout`, `sendToSpoke` and
///      `allocateToHubSpokeVault` and moves `min(topUp, Free Idle)` out of Share Assets whenever cash is below the
///      floor, BEFORE the operation is priced.
///
/// Sequence of the large variant (a hostile, compromised or fat-fingered Manager key; one call):
///  1. `setOperatingCashParameters(type(uint256).max, 99_000e6)`;
///  2. the next Shareholder operation runs the top-up. Here it is Alice's own `claimPayout`: 99,000 USDC of Free Idle
///     leave Share Assets first, then her claim is priced on what is left, ALL her shares are burned for the 750 USDC
///     that remain, and the request closes.
///  3. Setting the parameters back changes nothing: the 99,000 USDC stay in Operating Cash for good.
///
/// Impact: (a) is a permanent leak of every top-up of every fund; (b) lets one parameter write freeze
/// all Free Idle irrecoverably and burn a claimant's shares against the emptied base. The Payout Reserve is spared
/// (the top-up only takes Free Idle).
///
/// Fix: ship the DEC-096 close-out (or a Manager verb that returns Operating Cash to Idle, never anywhere else) before
/// any fund is created on immutable code; cap `operatingCashTopUp` (absolute, or as bps of Share Assets per period) and
/// require `topUp <= floor` multiples that make sense; run the top-up after the operation is priced, or revert a
/// claim whose top-up would exceed a small share of Free Idle.
contract OperatingCashSinkPoC is AccountingPocFixture {
    address internal bob = makeAddr("bob");

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_REGRESSION_operatingCashHasNoExitAndUncappedTopUpEmptiesFreeIdle() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        core.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(core.operatingCash(), 0);
    }
}
