// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice [C-01] (spoke-a), ported to main. At `e5c778a` the automatic unwind floored its swap at 95% of the pool's
///         spot, so a claimant who crushed the WETH spot made the hub Spoke Vault close a 1,000,000 USDC position and
///         sell 410 WETH for 820 USDC (Share Assets 1,017,446 -> 18,239). Security review S-2 floors the swap at
///         max(spot, price source) less 5%: the same crushed-spot claim now reverts inside the unwind, the position is
///         kept and the claim is paid from Free Idle only (DEC-068). Real CoreVault + hub SpokeVault +
///         UniswapV4Adapter over MockV4.
/// @dev Residuals, not asserted here: the unwind is still SIZED at spot (`SpokeVault._unwindValue` reads
///      `spotQuote`), and a push inside the 5% floor still sells under the external price; the latter is pinned on
///      main by `test/security/integrations/UnwindFloorResidual.t.sol` (S-2 residual).
contract C01_UnwindAtManipulatedSpot is SpokeAHubFixture {
    function test_REVIEW_C01_crushedSpotUnwindRevertsAndTheClaimIsPaidFromIdleOnly() public {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 20_000e6);
        _managerOpensHubPosition(1_000_000e6);
        _request(mallory, 19_000e6, ICoreVaultPayouts.PayoutMode.Instant);

        uint256 assetsBefore = vault.shareAssets();
        uint256 aliceBefore = _valueOf(alice);
        uint256 freeIdleBefore = vault.freeIdle();
        assertEq(assetsBefore, 1_017_450_999_998);
        assertEq(aliceBefore, 997_499_999_998);
        assertEq(freeIdleBefore, 17_451e6);

        // Same push as the e5c778a PoC: WETH spot at 1/1,250 of the oracle, the mock fills at that spot.
        _crushWethSpot(1250);
        v4.setSwap(adapter.spotQuote(poolId, address(weth), 1e18), 10_000);

        vm.expectEmit(false, false, false, false, address(vault));
        emit ICoreVaultPayouts.UnwindForPayoutFailed(0);
        ICoreVault.PayoutReceipt memory r = _claim(mallory);
        _restoreSpot();

        console2.log("unwind proceeds", r.unwindProceeds);
        console2.log("usdc paid to mallory", r.usdcPaid);
        console2.log("share assets after", vault.shareAssets());

        // The unwind reverted whole: no position closed, no WETH sold, nothing taken from the fund.
        assertEq(r.unwindProceeds, 0, "unwind reverted under the oracle floor");
        assertEq(hubVault.positions().length, 1, "position kept");
        assertEq(r.usdcPaid, 17_058_352_501, "paid from Free Idle only");
        assertTrue(vault.payoutRequest(mallory).open, "partial payout, request stays open");
        // Share Assets fall only by what Mallory was paid gross less her Payout Fee, which stays in Idle (DEC-144);
        // Alice's value is untouched, and the fee even raises it.
        assertEq(vault.shareAssets(), assetsBefore - r.usdcGross + r.payoutFee);
        assertGe(_valueOf(alice), aliceBefore, "the holder who stays loses nothing");
    }
}
