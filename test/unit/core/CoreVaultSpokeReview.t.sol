// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultSpokeSettlementTest} from "./CoreVaultSpokeSettlement.t.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";

contract CoreVaultSpokeReviewTest is CoreVaultSpokeSettlementTest {
    function test_H1_arrivalBeforeReportIsReserved() public {
        uint256 initialIdle = vault.idle();
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _fill(3990e6);
        _report(_result(request, 0, 10e6));
        assertEq(vault.freeIdle(), 0);
        assertEq(vault.payoutReserve(), initialIdle + 3990e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 1, 0));
        vault.allocateToHubSpokeVault(1);
    }

    function test_H1_reportBeforePartialArrivalsReservesExactlyOnce() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        uint256 reserve = vault.payoutReserve();
        _report(_result(request, 0, 10e6));
        _fill(1000e6);
        assertEq(vault.payoutReserve(), reserve + 1000e6);
        _report(_result(request, 0, 10e6));
        assertEq(vault.payoutReserve(), reserve + 1000e6);
        _fill(2990e6);
        assertEq(vault.payoutReserve(), reserve + 3990e6);
        vault.settlePayout(alice);
        assertEq(vault.payoutReserve(), 0);
    }

    function test_H2_expiredClaimRequiresPrincipalCredit() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _report(_result(request, 0, 10e6));
        vm.warp(uint256(request.orderDeadline) + 1);
        _report(_result(request, 0, 10e6));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.claimPayout(0);
    }

    function test_H2_expiredClaimIncludesSpokeCosts() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _fill(3990e6);
        vm.warp(uint256(request.orderDeadline) + 1);
        _report(_result(request, 20e6, 30e6));
        vm.prank(alice);
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.claimPayout(0);
        assertEq(receipt.marketCost, 20e6);
        assertEq(receipt.leaverCost, 30e6);
        assertFalse(vault.payoutRequest(alice).awaitingSettlement);
    }

    function test_H3_replacementCannotHideUncreditedTransit() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _report(_result(request, 0, 10e6));
        SpokeUnwindTypes.OrderResult memory replacement = _result(request, 0, 0);
        replacement.transitId = bytes32(0);
        replacement.amountSent = 0;
        replacement.amountToArrive = 0;
        _report(replacement);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.settlePayout(alice);
    }

    function test_M1_hubBaseCoverageSkipsSpokePublication() public {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1500e6);
        vm.prank(alice);
        ICoreVaultPayouts.PayoutReceipt memory receipt =
            vault.requestPayout(1000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        assertGt(receipt.usdcPaid, 0);
        assertEq(orderCore.publishedCount(), 0);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_M2_bridgeRefusalIncludesSaleCostsAndExclusions() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory result = _result(request, 100e6, 100e6);
        result.transitId = bytes32(0);
        result.amountSent = 0;
        result.amountToArrive = 0;
        result.excluded = 1;
        _report(result);
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.settlePayout(alice);
        assertEq(receipt.marketCost, 100e6);
        assertEq(receipt.leaverCost, 100e6);
        assertEq(receipt.excludedPositions, 1);
    }

    function test_M2_refundIncludesSaleCosts() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory result = _result(request, 100e6, 110e6);
        result.refunded = true;
        result.excluded = 1;
        _report(result);
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.settlePayout(alice);
        assertEq(receipt.marketCost, 100e6);
        assertEq(receipt.leaverCost, 100e6);
        assertEq(receipt.excludedPositions, 1);
    }

    function test_M3_expiredPublicationUsesNewOrderIdWhenIdleCoversRequest() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        vm.warp(uint256(request.orderDeadline) + 1);
        _deliver(_spokeReport(8000e6, 8000e6));
        prices.setMaxPriceAge(1 days);
        _deposit(stranger, 10_000e6);
        vm.prank(alice);
        vault.claimPayout(200);
        assertEq(vault.payoutRequest(alice).attempt, request.attempt + 1);
        assertEq(orderCore.publishedCount(), 2);
        assertNotEq(
            OrderCodec.orderId(OrderCodec.decode(orderCore.published(0).payload)),
            OrderCodec.orderId(OrderCodec.decode(orderCore.published(1).payload))
        );
    }

    function test_M2_partialRefusalCostsAreNotChargedAgainOnResend() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory result = _result(request, 100e6, 100e6);
        result.transitId = bytes32(0);
        result.amountSent = 0;
        result.amountToArrive = 0;
        result.excluded = 1;
        _report(result);
        ICoreVaultPayouts.PayoutReceipt memory first = vault.settlePayout(alice);
        assertEq(first.marketCost, 100e6);
        assertEq(first.leaverCost, 100e6);
        vm.prank(alice);
        vault.claimPayout(0);
        request = vault.payoutRequest(alice);
        _fill(3990e6);
        _report(_result(request, 100e6, 110e6));
        ICoreVaultPayouts.PayoutReceipt memory retry = vault.settlePayout(alice);
        assertEq(retry.marketCost, 0);
        assertEq(retry.leaverCost, 10e6);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_H3_expiredRetryCannotBypassKnownUnresolvedTransit() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _report(_result(request, 0, 10e6));
        vm.warp(uint256(request.orderDeadline) + 1);
        _report(_result(request, 0, 10e6));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.claimPayout(200);
        assertEq(orderCore.publishedCount(), 1);
    }
}
