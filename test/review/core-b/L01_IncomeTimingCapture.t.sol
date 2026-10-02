// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreAHubFixture} from "../core-a/CoreAHubFixture.sol";

/// @notice Review port of core-b L01, consolidated finding L-07 (register S-15, Open, founder decision). Still present
///         on main with the review's exact numbers (Alice 799.99, Mallory 800.01 of 1,600 net; Mallory +300.64 USDC
///         after a Standard exit); no fix landed, so this stays a pin.
///         Original note: CS-OQ-1 says income "collected before the entry is not shared" and that "frequent collection
///         narrows the window". On the hub, the manager's `collectIncome` only moves fees into the hub Spoke Vault's
///         bucket; the index moves when ANYONE calls `forwardIncomeToCoreVault` (SpokeVault.sol:496, no access control).
///         An entrant deposits, then forwards, in one transaction, and shares income the manager collected before the
///         entry. Numbers below with the default fees (flow fee 25 bps each way, performance fee 20%, Standard exit).
/// @dev Uses the review fixture of the earlier reviewer (real CoreVault, real hub SpokeVault, real UniswapV4Adapter over
///      MockV4). Fees are accrued in the pool with MockV4.accrueFees and collected by the manager through the real path.
contract L01_IncomeTimingCapture is CoreAHubFixture {
    uint256 internal constant Q128 = 1 << 128;

    function test_POC_REVIEW_L07_entrantSharesIncomeTheManagerCollectedBeforeTheEntry() public {
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

        // Mallory enters after that collection, then forwards the bucket herself (permissionless).
        uint256 minted = _deposit(mallory, 100_000e6);
        vm.prank(mallory);
        hubVault.forwardIncomeToCoreVault(address(usdc));
        uint256 aliceIncome = vault.attributedIncome(alice, address(usdc));
        vm.prank(mallory);
        uint256 malloryIncome = vault.withdrawIncome(address(usdc));
        console2.log("income collected by the manager before Mallory's entry", bucket);
        console2.log("  net to holders after the 20% fee", bucket * 8 / 10);
        console2.log("  Alice (held while it was earned) ", aliceIncome);
        console2.log("  Mallory (entered after)          ", malloryIncome);
        assertEq(aliceIncome, 799_995_989);
        assertEq(malloryIncome, 799_995_989, "the entrant takes half of income earned before she entered");

        // Mallory leaves with a Standard Payout (no Payout Fee; flow fee on the way out), after the 72 h term. She asks
        // for more than her balance is worth so the burn is capped at the whole balance (DEC-020; QA23 rounding aside).
        uint256 value = ShareMath.usdcFor(minted, vault.sharePrice());
        vm.prank(mallory);
        vault.requestPayout(2 * value, ICoreVault.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours);
        uint256 before = usdc.balanceOf(mallory);
        vm.prank(mallory);
        vault.claimPayout("");
        uint256 principalBack = usdc.balanceOf(mallory) - before;
        int256 pnl = int256(principalBack + malloryIncome) - int256(100_000e6);
        console2.log("Mallory: paid 100,000, got back principal", principalBack);
        console2.log("Mallory: profit (USDC base units)");
        console2.logInt(pnl);
        assertEq(principalBack, 99_500_625_000);
        assertEq(pnl, 300_620_989, "profitable at 2% of fund value waiting in the bucket");
        assertEq(shares.balanceOf(mallory), 0);
    }
}
