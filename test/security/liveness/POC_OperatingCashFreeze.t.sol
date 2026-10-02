// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";

/// @title POC: an unbounded Operating Cash top-up moves Free Idle into a bucket nothing can ever spend or return
/// @notice SEVERITY: medium (irreversible loss of shareholder value from one manager transaction, no cap, no recovery;
///         the manager key may be an autonomous agent, DEC-003).
///
/// ATTACK / FAILURE
///   `CoreVault.setOperatingCashParameters(floor, topUp)` is manager-only and unbounded (DEC-100: "no protocol cap on
///   the floor"; CoreVaultBase.sol:269). `_topUpOperatingCash` (CoreVaultBase.sol:283) runs at the start of every
///   deposit, claim, allocation and send, and moves `min(topUp, Free Idle)` from Idle into `operatingCash` whenever
///   `operatingCash < floor`. On the hub `operatingCash` only ever grows: no verb spends it, returns it to Idle or
///   distributes it (spending is OPEN, doc 30; fund close does not exist in the MVP). It is outside Share Assets, so
///   the move is booked as an expense paid by Share Assets and the Share Price drops at once (DEC-100).
///   A manager (malicious, compromised, or an agent with a decimals bug: 3e12 instead of 3e6) sets a large top-up;
///   the next shareholder operation, anyone's, executes the transfer irreversibly. The manager cannot steal it, but
///   every holder loses that value for good, and a payout after it is priced at the reduced Share Assets.
///
/// IMPACT
///   Bounded only by Free Idle: in one call plus one routine operation the whole Free Idle can be turned into dead
///   money. Here 50,000 of a 99,750 USDC fund vanish from Share Assets; the only holder's full Instant Payout then
///   pays 48,630 USDC for a 100,000 USDC deposit. There is no verb that moves Operating Cash back, so a fat-finger
///   is as final as an attack.
///
/// FIX
///   Bound the parameters in the core (a cap on `topUp` and `floor` as a fraction of Share Assets, e.g. 1%, or an
///   absolute cap in USDC per DEC-096's "about 3 USD"), rate-limit the top-up (at most once per period), and add a
///   manager verb that returns Operating Cash above the floor to Idle (it is the fund's money). Until spending exists,
///   the top-up serves nothing and could be disabled entirely on the hub.
contract POC_OperatingCashFreeze is CoreVaultFixture {
    function test_POC_operatingCashTopUpMovesFreeIdleIntoADeadBucket() public {
        _deposit(alice, 100_000e6);
        uint256 assetsBefore = vault.shareAssets();
        assertEq(assetsBefore, 99_750e6); // 25 bps flow fee left the fund
        assertEq(vault.operatingCash(), 0);

        // The manager (or an agent with a bug) sets a top-up worth half the fund; nothing bounds it.
        vm.prank(manager);
        vault.setOperatingCashParameters(50_000e6, 50_000e6);

        // Any routine operation executes the move: here a stranger's small deposit.
        _deposit(bob, 1000e6);

        // Half of the fund left Share Assets for good.
        assertEq(vault.operatingCash(), 50_000e6);
        uint256 assetsAfter = vault.shareAssets();
        assertApproxEqAbs(assetsAfter, 49_750e6 + 997_500_000, 0.01e6); // what is left plus bob's net deposit
        assertLt(assetsAfter, assetsBefore);

        // Alice's full exit is priced at the reduced Share Assets: her 100,000 USDC deposit pays back under half.
        _request(alice, 200_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.sharesBurned, 99_750e18);
        assertLt(r.usdcGross, 50_000e6);
        assertEq(r.usdcOutstanding, 0);
        emit log_named_uint("alice paid for a 100,000 USDC deposit", r.usdcPaid);

        // No verb returns Operating Cash to Idle: the ABI of the Core Vault has no such function, and the fund's own
        // ledger keeps the amount out of everything sweepable. Resetting the parameters does not move it back either.
        vm.prank(manager);
        vault.setOperatingCashParameters(0, 0);
        assertEq(vault.operatingCash(), 50_000e6); // DEC-144: the Payout Fee stays in Idle, never in this bucket
        assertEq(vault.sweepExcess(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(vault)), vault.idle() + vault.operatingCash());
    }
}
