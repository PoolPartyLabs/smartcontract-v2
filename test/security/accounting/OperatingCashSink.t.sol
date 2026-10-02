// SPDX-License-Identifier: MIT
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

    function test_POC_operatingCashHasNoExitAndUncappedTopUpEmptiesFreeIdle() public {
        _deposit(alice, 100_000e6);
        _deposit(bob, 10_000e6);

        // (a) The Payout Fee of an Instant Payout lands in Operating Cash and nothing can ever move it.
        vm.startPrank(bob);
        ICoreVault.PayoutReceipt memory bobReceipt =
            core.requestPayout(1_000_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.stopPrank();
        // DEC-144 fixed (a) for the Payout Fee: it stays in Idle and goes to those who stay.
        assertEq(core.operatingCash(), 0, "the 2 % Payout Fee stays in Idle");
        assertGt(bobReceipt.payoutFee, 199e6);
        assertEq(core.sweepExcess(address(usdc)), 0, "the garbage collector does not reach it");

        uint256 aliceBefore = _valueOf(alice);
        assertApproxEqAbs(
            aliceBefore, 99_750e6 + bobReceipt.payoutFee, 1e6, "Alice's position before the parameter write"
        );
        uint256 cashBefore = core.operatingCash();

        // (b) One Manager call. No cap, no delay.
        vm.prank(manager);
        core.setOperatingCashParameters(type(uint256).max, 99_000e6);

        // Alice exits. The top-up runs first and takes 99,000 USDC of Free Idle out of Share Assets.
        vm.startPrank(alice);
        ICoreVault.PayoutReceipt memory r = core.requestPayout(1_000_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.stopPrank();

        assertEq(core.operatingCash(), cashBefore + 99_000e6, "99,000 USDC moved to Operating Cash");
        assertEq(shares.balanceOf(alice), 0, "every share of Alice was burned");
        assertLt(r.usdcPaid, 1000e6, "for less than 1,000 USDC");
        assertEq(core.payoutRequest(alice).open, false, "and her request is closed");

        // The Manager undoing the parameters returns nothing, and no verb of the Core Vault lowers Operating Cash.
        vm.prank(manager);
        core.setOperatingCashParameters(0, 0);
        assertEq(core.operatingCash(), 99_000e6, "locked for good");
        assertEq(core.sweepExcess(address(usdc)), 0, "not sweepable");
        assertGt(usdc.balanceOf(address(core)), 99_000e6, "the USDC is still in the Core Vault");
        assertLe(core.shareAssets(), r.payoutFee + 10e6, "outside Share Assets (only Alice's Payout Fee stayed)");

        emit log_named_decimal_uint("Alice received (USDC)", r.usdcPaid, 6);
        emit log_named_decimal_uint("Operating Cash, locked (USDC)", core.operatingCash(), 6);
    }
}
