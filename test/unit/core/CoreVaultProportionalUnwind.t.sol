// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

contract CoreVaultProportionalUnwindTest is CoreVaultFixture {
    ICoreVaultPayouts.PayoutMode internal constant INSTANT = ICoreVaultPayouts.PayoutMode.Instant;
    ICoreVaultPayouts.PayoutMode internal constant STANDARD = ICoreVaultPayouts.PayoutMode.Standard;

    function _allocateToPosition(uint256 amount) internal {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(amount);
        hubVault.moveToPosition(amount);
    }

    function test_DEC132_oneOfTenThousandSharesUnwindsPoint0102Percent() public {
        _deployAtMinimumFees();
        _deposit(alice, 9999e6);
        _allocateToPosition(10_000e6);
        ICoreVault.PayoutReceipt memory receipt = _request(alice, 1e6, INSTANT);
        assertEq(receipt.fracNum, 1e18 * 10_200);
        assertEq(receipt.fracDen, 10_000e18 * 10_000);
        assertEq(receipt.unwindProceeds, 1.02e6);
        assertEq(receipt.sharesBurned, 1e18);
    }

    function test_DEC137_registerExampleFortyThousandWithThirtyThousandIdle() public {
        _deployAtMinimumFees();
        _deposit(alice, 99_999e6);
        _allocateToPosition(70_000e6);
        ICoreVault.PayoutReceipt memory receipt = _request(alice, 40_000e6, INSTANT);
        assertEq(receipt.fracNum, 10_000e18 * 10_200);
        assertEq(receipt.fracDen, 70_000e18 * 10_000);
        assertEq(receipt.unwindProceeds, 10_200e6);
        assertEq(receipt.sharesBurned, 40_000e18);
    }

    function test_DEC137_fractionIsCappedAtOne() public {
        _deployAtMinimumFees();
        _deposit(alice, 9999e6);
        _allocateToPosition(10_000e6);
        ICoreVault.PayoutReceipt memory receipt = _request(alice, 9999e6, INSTANT);
        assertEq(receipt.fracNum, receipt.fracDen);
        assertEq(hubVault.positionPrincipal(), 0);
    }

    function test_DEC151_zeroProgressKeepsTheFractionForTheRetry() public {
        _deployAtMinimumFees();
        _deposit(alice, 9999e6);
        _allocateToPosition(10_000e6);
        hubVault.setExcludePosition(true);
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory first = vault.requestPayout(1000e6, INSTANT, 1);
        assertEq(first.sharesBurned, 0);
        assertEq(first.excludedPositions, 1);
        assertEq(first.usdcOutstanding, 1000e6);
        assertTrue(vault.payoutRequest(alice).open);
        hubVault.setExcludePosition(false);
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory retry = vault.claimPayout(10_000);
        assertEq(retry.requestId, first.requestId);
        assertEq(retry.fracNum, first.fracNum);
        assertEq(retry.fracDen, first.fracDen);
        assertEq(retry.sharesBurned, 1000e18);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_DEC118_registerInstantMarketCostExample() public {
        _deployAtMinimumFees();
        _deposit(alice, 99_999e6);
        _allocateToPosition(90_000e6);
        hubVault.setUnwindLossBps(30);
        ICoreVault.PayoutReceipt memory receipt = _request(alice, 30_000e6, INSTANT);
        assertEq(receipt.marketCost, 61.2e6);
        assertEq(receipt.leaverCost, 61.2e6);
        assertEq(receipt.payoutFee, 600e6);
        assertEq(receipt.usdcPaid, 29_338.8e6);
        assertEq(receipt.sharePrice, ONE);
    }

    function test_DEC105_postUnwindPriceCannotIncreaseTheSharesServed() public {
        _deployAtMinimumFees();
        _deposit(alice, 99_999e6);
        _allocateToPosition(100_000e6);
        hubVault.setUnwindLossBps(100);
        _request(alice, 10_000e6, STANDARD);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory receipt = _claim(alice);
        assertLt(receipt.sharePrice, ONE);
        assertEq(receipt.sharesBurned, 10_000e18, "at most S fixed before the unwind");
        assertEq(receipt.leaverCost, 0);
    }
}
