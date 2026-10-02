// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreAHubFixture} from "../core-a/CoreAHubFixture.sol";

/// @notice Review port of core-b L01, consolidated finding L-07 (register S-15). FIXED by DEC-138 and the Hub dollar
///         index (DEC-161, WP-10). As found (Alice 799.99, Mallory 800.01 of 1,600 net; Mallory +300.64 USDC after a
///         Standard exit): the manager's `collectIncome` only moved fees into the hub Spoke Vault's bucket and the index
///         moved when ANYONE called `forwardIncomeToCoreVault`, so an entrant deposited, then forwarded, in one
///         transaction, and shared income the manager collected before the entry. Now the entrant's mint recognizes the
///         hub income first (the hub Spoke Vault's monotonic counters, read in the mint's valuation), for Alice and the
///         seed, and a collection the entrant triggers afterwards only converts it for them.
/// @dev Uses the review fixture of the earlier reviewer (real CoreVault, real hub SpokeVault, real UniswapV4Adapter over
///      MockV4). Fees are accrued in the pool with MockV4.accrueFees and collected by the manager through the real path.
contract L01_IncomeTimingCapture is CoreAHubFixture {
    uint256 internal constant Q128 = 1 << 128;

    function test_REVIEW_L07_FIXED_entrantNoLongerSharesIncomeEarnedBeforeTheEntry() public {
        _deposit(alice, 100_000e6);
        _managerOpensHubPosition(50_000e6);

        // 2,000 USDC of fees accrue on the hub position (2% of the fund: e.g. a month at 24% APR on half of it).
        IAdapter.PositionValue memory pv = adapter.positionValue(positionKey);
        uint256 growth = Math.mulDiv(2000e6, Q128, pv.liquidity, Math.Rounding.Ceil);
        if (wethIsToken0) v4.accrueFees(poolId, 0, growth);
        else v4.accrueFees(poolId, growth, 0);

        // The manager collects: the fees are now "collected" income, in the hub Spoke Vault's bucket.
        vm.prank(manager);
        hubVault.collectIncome(address(adapter), positionKey);
        uint256 bucket = hubVault.collectedIncome(address(usdc));
        assertApproxEqAbs(bucket, 2000e6, 1);

        // Mallory enters after that collection, then has the income collected herself (permissionless).
        uint256 minted = _deposit(mallory, 100_000e6);
        vm.prank(mallory);
        vault.requestIncomeWithdrawal(0);
        uint256 aliceIncome = vault.incomeOwed(alice);
        vm.prank(mallory);
        uint256 malloryIncome = vault.withdrawIncome();
        console2.log("income collected by the manager before Mallory's entry", bucket);
        console2.log("  Alice (held while it was earned) ", aliceIncome);
        console2.log("  Mallory (entered after)          ", malloryIncome);
        assertEq(malloryIncome, 0, "DEC-138: the entrant takes nothing of income earned before she entered");
        assertApproxEqAbs(
            aliceIncome,
            bucket * 8 / 10 * shares.balanceOf(alice) / (shares.balanceOf(alice) + 1e18),
            1,
            "Alice keeps her share of the net, excluding the seed"
        );

        // Mallory leaves with a Standard Payout (no Payout Fee; flow fee on the way out): a loss now.
        uint256 value = ShareMath.usdcFor(minted, vault.sharePrice());
        vm.prank(mallory);
        vault.requestPayout(2 * value, ICoreVaultPayouts.PayoutMode.Standard, 0);
        vm.warp(block.timestamp + 72 hours);
        uint256 before = usdc.balanceOf(mallory);
        vm.prank(mallory);
        vault.claimPayout(0);
        uint256 principalBack = usdc.balanceOf(mallory) - before;
        assertLt(principalBack + malloryIncome, 100_000e6, "the round trip only costs the entrant");
        assertEq(shares.balanceOf(mallory), 0);
    }
}
