// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract CoreVaultPayoutLossAccountingTest is CoreVaultFixture {
    function test_DEC118_instantHighLossNeverMovesRequesterCostToFund() public {
        _checkLoss(100_000e6, 10_000e6, 9900, ICoreVaultPayouts.PayoutMode.Instant);
    }

    function test_DEC141_standardHighLossNeverExceedsFundCap() public {
        _checkLoss(100_000e6, 10_000e6, 9900, ICoreVaultPayouts.PayoutMode.Standard);
    }

    function test_DEC118_totalLossWithFlowFeeKeepsCostForRetry() public {
        _checkLoss(100_000e6, 10_000e6, 10_000, ICoreVaultPayouts.PayoutMode.Instant);
    }

    function test_DEC141_totalLossWithFlowFeeKeepsCostForRetry() public {
        _checkLoss(100_000e6, 10_000e6, 10_000, ICoreVaultPayouts.PayoutMode.Standard);
    }

    function testFuzz_DEC118_netCashBurnAndRetry(uint256 size, uint256 requested, uint16 loss) public {
        _checkLoss(
            bound(size, 1000e6, 1_000_000e6),
            requested,
            uint16(bound(loss, 0, 10_000)),
            ICoreVaultPayouts.PayoutMode.Instant
        );
    }

    function testFuzz_DEC141_netCashBurnAndRetry(uint256 size, uint256 requested, uint16 loss) public {
        _checkLoss(
            bound(size, 1000e6, 1_000_000e6),
            requested,
            uint16(bound(loss, 0, 10_000)),
            ICoreVaultPayouts.PayoutMode.Standard
        );
    }

    function _checkLoss(uint256 size, uint256 requested, uint16 loss, ICoreVaultPayouts.PayoutMode mode) private {
        size = size / 1e6 * 1e6;
        requested = bound(requested, 100e6, size - 1e6);
        uint16 flowFeeBps = uint16(requested % 101);
        _deploy(_mandate(1000), _config(flowFeeBps));
        _deposit(alice, size - 1e6);
        size = vault.idle();
        vm.prank(manager);
        vault.allocateToHubSpokeVault(size);
        hubVault.moveToPosition(size);
        hubVault.setUnwindLossBps(loss);
        uint256 balanceBefore = shares.balanceOf(alice);
        ICoreVaultPayouts.PayoutReceipt memory first = _request(alice, requested, mode);
        if (mode == ICoreVaultPayouts.PayoutMode.Standard) {
            vm.warp(block.timestamp + 72 hours);
            first = _claim(alice);
        }
        uint256 sold = size - hubVault.positionPrincipal();
        uint256 fundCost = mode == ICoreVaultPayouts.PayoutMode.Instant ? 0 : Math.min(first.marketCost, sold / 100);
        uint256 assigned = first.marketCost - fundCost;
        assertEq(first.marketCostAbsorbed, fundCost, "fund never absorbs requester debt");
        assertEq(first.usdcGross, ShareMath.usdcFor(first.sharesBurned, first.sharePrice));
        assertEq(first.usdcGross, first.usdcPaid + first.payoutFee + first.flowFee + first.leaverCost);
        assertLe(first.sharesBurned, ShareMath.sharesToBurn(requested, ONE), "pre-unwind served cap");
        assertEq(shares.balanceOf(alice), balanceBefore - first.sharesBurned);
        uint256 pending = assigned - first.leaverCost;
        assertEq(vault.payoutRequest(alice).pendingLeaverCost, pending, "every unsettled cost persists");
        assertEq(
            vault.shareAssets() + pending,
            first.shareAssets + assigned - first.usdcGross + first.payoutFee,
            "requester cost is never socialized at settlement"
        );
        if (
            first.usdcOutstanding != 0 && first.sharesBurned < ShareMath.sharesToBurn(requested, ONE)
                && first.sharesBurned < balanceBefore
        ) {
            uint256 nextGross = ShareMath.usdcFor(first.sharesBurned + 1e18, first.sharePrice);
            uint256 nextFee = mode == ICoreVaultPayouts.PayoutMode.Instant ? nextGross * 200 / 10_000 : 0;
            assertGt(
                Math.max(
                    nextGross - nextFee - Math.min(assigned, nextGross - nextFee), nextGross * flowFeeBps / 10_000
                ),
                first.unwindProceeds
            );
        }
        if (pending != 0) assertTrue(vault.payoutRequest(alice).open, "unsettled cost keeps request open");
        if (vault.payoutRequest(alice).open && shares.balanceOf(alice) != 0) {
            uint256 principalBefore = hubVault.positionPrincipal();
            hubVault.setPosition(address(usdc), 0);
            usdc.mint(address(vault), principalBefore);
            if (principalBefore != 0) {
                vm.prank(address(hubVault));
                vault.returnToIdle(principalBefore);
            }
            ICoreVaultPayouts.PayoutReceipt memory retry = _claim(alice);
            assertEq(retry.marketCost, 0, "delivered position never sells twice");
            assertEq(retry.marketCostAbsorbed, 0);
            assertLe(retry.leaverCost, pending, "retry never charges twice");
            if (pending > 2e6 && shares.balanceOf(alice) != 0 && principalBefore > pending * flowFeeBps / 10_000 + 1e6)
            {
                assertGt(retry.leaverCost, 0, "debt-only retry progresses");
            }
            assertEq(
                retry.sharePrice,
                ShareMath.sharePrice(retry.shareAssets + pending, retry.totalShares),
                "pending cost added back exactly once"
            );
            assertEq(vault.payoutRequest(alice).pendingLeaverCost, pending - retry.leaverCost);
            assertEq(
                vault.shareAssets() + pending - retry.leaverCost,
                retry.shareAssets + pending - retry.usdcGross + retry.payoutFee,
                "retry preserves the fund's net-value accounting"
            );
            assertEq(retry.usdcGross, retry.usdcPaid + retry.payoutFee + retry.flowFee + retry.leaverCost);
        }
    }
}
