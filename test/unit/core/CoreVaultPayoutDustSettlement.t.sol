// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";

contract CoreVaultPayoutDustSettlementTest is CoreVaultFixture {
    function test_DEC118_roundTwoInstantProbeCompletes() public {
        _retryToCompletion(100_000e6, 10_000e6, 9900, 0, ICoreVaultPayouts.PayoutMode.Instant);
    }

    function test_DEC141_feeBearingStandardCompletes() public {
        _retryToCompletion(100_000e6, 10_000e6, 9900, 100, ICoreVaultPayouts.PayoutMode.Standard);
    }

    function test_DEC118_terminalDustWaitsForCashAndRetainsWholeShareValue() public {
        _deploy(_mandate(1000), _config(0));
        _deposit(alice, 99_999e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100_000e6);
        hubVault.moveToPosition(100_000e6);
        hubVault.setUnwindLossBps(9900);
        _request(alice, 10_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        uint256 remaining = hubVault.positionPrincipal();
        hubVault.setPosition(address(usdc), 0);
        usdc.mint(address(vault), remaining);
        vm.prank(address(hubVault));
        vault.returnToIdle(remaining);
        _claim(alice);
        _claim(alice);
        assertEq(vault.payoutRequest(alice).pendingLeaverCost, 399_743, "round-two probe debt");
        assertEq(shares.balanceOf(alice), 89_696e18, "round-two probe shares");
        assertEq(vault.idle(), 89_902e6, "round-two probe Idle");
        uint256 idle = vault.idle();
        vm.prank(manager);
        vault.allocateToHubSpokeVault(idle);
        hubVault.moveToPosition(idle);
        hubVault.setExcludePosition(true);
        ICoreVaultPayouts.PayoutReceipt memory blocked = _claim(alice);
        assertEq(blocked.sharesBurned, 0, "terminal burn still requires cash");
        assertEq(vault.payoutRequest(alice).pendingLeaverCost, 399_743);
        hubVault.setPosition(address(usdc), 0);
        usdc.mint(address(vault), idle);
        vm.prank(address(hubVault));
        vault.returnToIdle(idle);
        ICoreVaultPayouts.PayoutReceipt memory terminal = _claim(alice);
        assertEq(terminal.sharesBurned, 1e18);
        assertEq(terminal.usdcPaid, 0);
        assertEq(terminal.leaverCost, terminal.usdcGross - terminal.payoutFee);
        assertEq(vault.idle(), idle, "whole-share proceeds stay in the fund");
        assertFalse(vault.payoutRequest(alice).open);
        _request(alice, 1000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_DEC146_terminalSettlementPreservesManagerBase() public {
        _deployUnseeded(_mandate(1000), _config(0));
        _seedFundWith(address(vault), address(usdc), 100_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100_000e6);
        hubVault.moveToPosition(100_000e6);
        hubVault.setUnwindLossBps(9900);
        _request(manager, 10_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        uint256 remaining = hubVault.positionPrincipal();
        hubVault.setPosition(address(usdc), 0);
        usdc.mint(address(vault), remaining);
        vm.prank(address(hubVault));
        vault.returnToIdle(remaining);
        for (uint256 attempt; attempt < 32 && vault.payoutRequest(manager).open; ++attempt) {
            _claim(manager);
            assertGe(shares.balanceOf(manager), 50_000e18);
        }
        assertFalse(vault.payoutRequest(manager).open);
        assertEq(vault.payoutRequest(manager).pendingLeaverCost, 0);
        _request(manager, 1000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertFalse(vault.payoutRequest(manager).open);
        assertGe(shares.balanceOf(manager), 50_000e18);
    }

    function test_DEC151_sizeRangeCompletesInBothModes() public {
        uint256[5] memory sizes = [uint256(1000e6), 10_000e6, 100_000e6, 1_000_000e6, 100_000_000e6];
        for (uint256 index; index < sizes.length; ++index) {
            _retryToCompletion(sizes[index], sizes[index] / 10, 9900, 0, ICoreVaultPayouts.PayoutMode.Instant);
            _retryToCompletion(sizes[index], sizes[index] / 10, 10_000, 100, ICoreVaultPayouts.PayoutMode.Standard);
        }
    }

    function testFuzz_DEC118_everyFundedRetryReachesFinalState(uint256 size, uint16 loss, uint16 fee) public {
        size = bound(size, 1000, 100_000_000) * 1e6;
        _retryToCompletion(
            size,
            size / 10,
            uint16(bound(loss, 0, 10_000)),
            uint16(bound(fee, 0, 100)),
            ICoreVaultPayouts.PayoutMode.Instant
        );
    }

    function testFuzz_DEC141_everyFundedRetryReachesFinalState(uint256 size, uint16 loss, uint16 fee) public {
        size = bound(size, 1000, 100_000_000) * 1e6;
        _retryToCompletion(
            size,
            size / 10,
            uint16(bound(loss, 0, 10_000)),
            uint16(bound(fee, 0, 100)),
            ICoreVaultPayouts.PayoutMode.Standard
        );
    }

    function _retryToCompletion(
        uint256 size,
        uint256 requested,
        uint16 loss,
        uint16 fee,
        ICoreVaultPayouts.PayoutMode mode
    ) private {
        _deploy(_mandate(1000), _config(fee));
        _deposit(alice, size - 1e6);
        uint256 assets = vault.idle();
        vm.prank(manager);
        vault.allocateToHubSpokeVault(assets);
        hubVault.moveToPosition(assets);
        hubVault.setUnwindLossBps(loss);
        ICoreVaultPayouts.PayoutReceipt memory first = _request(alice, requested, mode);
        if (mode == ICoreVaultPayouts.PayoutMode.Standard) {
            vm.warp(block.timestamp + 72 hours);
            first = _claim(alice);
        }
        uint256 assigned = first.marketCost - first.marketCostAbsorbed;
        uint256 charged = first.leaverCost;
        bytes32 requestId = first.requestId;
        uint256 remaining = hubVault.positionPrincipal();
        hubVault.setPosition(address(usdc), 0);
        usdc.mint(address(vault), remaining);
        if (remaining != 0) {
            vm.prank(address(hubVault));
            vault.returnToIdle(remaining);
        }
        for (uint256 attempt; attempt < 32 && vault.payoutRequest(alice).open; ++attempt) {
            uint256 pending = vault.payoutRequest(alice).pendingLeaverCost;
            uint256 idleBefore = vault.idle();
            uint256 balanceBefore = shares.balanceOf(alice);
            ICoreVaultPayouts.PayoutReceipt memory retry = _claim(alice);
            uint256 pendingAfter = vault.payoutRequest(alice).pendingLeaverCost;
            charged += retry.leaverCost;
            assertEq(retry.marketCost, 0, "no repeated sale");
            assertEq(retry.marketCostAbsorbed, 0, "no additional fund loss");
            assertEq(retry.usdcGross, retry.usdcPaid + retry.flowFee + retry.payoutFee + retry.leaverCost);
            assertEq(shares.balanceOf(alice), balanceBefore - retry.sharesBurned);
            assertEq(vault.idle(), idleBefore - retry.usdcPaid - retry.flowFee);
            assertEq(retry.sharePrice, ShareMath.sharePrice(retry.shareAssets + pending, retry.totalShares));
            assertLe(retry.usdcPaid + retry.flowFee, idleBefore, "cash checked including protocol fee");
            if (retry.leaverCost > pending) {
                assertEq(pendingAfter, 0);
                assertEq(retry.sharesBurned, 1e18, "only terminal debt rounds up");
                assertEq(retry.usdcPaid, 0, "rounding surplus stays with remaining holders");
                assertFalse(vault.payoutRequest(alice).open);
                assertLt(retry.leaverCost - pending, retry.usdcGross, "rounding bounded by one share");
            } else {
                assertEq(pendingAfter, pending - retry.leaverCost);
            }
            assertTrue(!vault.payoutRequest(alice).open || pendingAfter < pending || retry.usdcGross != 0);
        }
        assertFalse(vault.payoutRequest(alice).open, "every funded request reaches a final state");
        assertEq(vault.payoutRequest(alice).pendingLeaverCost, 0, "no forgotten requester cost");
        assertEq(vault.payoutRequest(alice).usdcOutstanding, 0);
        assertEq(vault.payoutRequest(alice).reserved, 0);
        assertEq(vault.payoutReserve(), 0);
        assertGe(charged, assigned, "fund never absorbs debt dust");
        assertLt(charged - assigned, ShareMath.usdcFor(1e18, vault.sharePrice()));
        _request(alice, 100e6, mode);
        assertNotEq(vault.payoutRequest(alice).requestId, requestId, "new requests accepted");
        if (vault.payoutRequest(alice).open) {
            vm.warp(block.timestamp + 72 hours);
            _claim(alice);
        }
        assertFalse(vault.payoutRequest(alice).open, "next request also completes");
    }
}
