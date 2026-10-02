// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HubStackFixture} from "./HubStackFixture.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";

/// @title Regression (security review S-1): a claimant who moves the pool price is no longer paid on an LP
///        composition marked at the oracle price
/// @notice Was PoC `test_POC_claimantInflatesShareAssetsByMovingThePoolPrice` (medium, liveness lens): Share Assets
///         marked the pool's CURRENT composition of a Uniswap V4 position at the oracle price, and for an LP
///         `marked(p) - value(P) = L * (sqrt(P) - sqrt(p))^2 / sqrt(p) >= 0`, so pushing the pool to the range edge
///         inside the claim transaction added 1,266 USDC to Share Assets and about 250 USDC to the claimant's payout.
///
/// FIX (S-1, `CoreVaultLogic._oracleComposition`): the Core Vault recomputes the composition from liquidity and range
/// at the oracle price. The adapter's own `positionValue` still reports the spot split (it describes the pool), but
/// Share Assets no longer read it. The test repeats the sandwich and asserts it now FAILS: Share Assets and the payout
/// are those of the honest claim and alice keeps her value.
contract POC_CompositionMarking is HubStackFixture {
    function test_SEC_S1_claimantMovingThePoolPriceIsPaidTheHonestAmount() public {
        _deposit(alice, 200_000e6);
        bytes32 positionKey = _openHubPosition(100_000e6, 50_000e6, 50_000e6);
        _deposit(bob, 50_000e6); // bob enters at the true price
        uint256 trueValue = _markedPositionValue(positionKey);
        uint256 trueAssets = vault.shareAssets();

        // Counterfactual: bob exits at the true price.
        uint256 snapshot = vm.snapshotState();
        _request(bob, 100_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory honest = _claim(bob);
        uint256 aliceAssetsHonest = vault.shareAssets();
        vm.revertToState(snapshot);

        // Attack: push the pool to the lower edge of the fund's range, claim, restore.
        v4.setTick(poolId, TRUE_TICK - HALF_RANGE);
        assertGt(_markedPositionValue(positionKey), trueValue, "the adapter still reports the pushed spot split");
        assertEq(vault.shareAssets(), trueAssets, "S-1: Share Assets do not follow it");

        _request(bob, 100_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory attack = _claim(bob);
        v4.setTick(poolId, TRUE_TICK);

        assertEq(attack.sharesBurned, honest.sharesBurned);
        assertEq(attack.unwindProceeds, 0);
        assertEq(attack.usdcPaid, honest.usdcPaid, "S-1: bob is paid exactly the honest amount");
        assertEq(_markedPositionValue(positionKey), trueValue);
        assertEq(vault.shareAssets(), aliceAssetsHonest, "S-1: alice keeps what she keeps after an honest exit");
    }
}
