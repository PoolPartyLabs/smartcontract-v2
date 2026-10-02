// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {MockOrderCore} from "../../mocks/wormhole/MockOrderCore.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";

contract CoreVaultSpokeSettlementTest is CoreVaultFixture {
    function test_REGRESSION_fullHistoryReportSettlesCurrentPayout() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _multiReport(request);
        assertEq(vault.payoutRequest(alice).reportedSpokes, 1);
        _fill(3990e6);
        vault.settlePayout(alice);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function test_REGRESSION_retryAcceptsCurrentResultAfterOlderHistory() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        vm.warp(uint256(request.orderDeadline) + 1);
        _deliver(_spokeReport(8000e6, 8000e6));
        vm.prank(alice);
        vault.claimPayout(200);
        request = vault.payoutRequest(alice);
        _multiReport(request);
        assertEq(vault.payoutRequest(alice).reportedSpokes, 1);
        _fill(3990e6);
        vault.settlePayout(alice);
        assertFalse(vault.payoutRequest(alice).open);
    }

    function _multiReport(ICoreVaultPayouts.PayoutRequest memory request) internal {
        SpokeUnwindTypes.OrderResult[] memory results =
            new SpokeUnwindTypes.OrderResult[](SpokeUnwindTypes.REPORTED_RESULTS);
        for (uint256 index; index + 1 < results.length; ++index) {
            results[index].requestId = keccak256(abi.encode("older payout", index));
            results[index].attempt = 1;
        }
        results[results.length - 1] = _result(request, 0, 10e6);
        ReportCodec.Report memory report = _inFlightToHub(_spokeReport(4000e6, 8000e6), HOME, 3990e6);
        report.cumulativeSentHome = 4000e6;
        report.unwindResults = SpokeUnwindTypes.encodeResults(results);
        _deliver(report);
    }

    address internal stranger = address(0xBEEF);
    MockOrderCore internal orderCore;
    bytes32 internal constant HOME = keccak256("unwind home");

    function setUp() public override {
        super.setUp();
        orderCore = new MockOrderCore(23);
        vm.etch(address(hubWormhole), address(orderCore).code);
        orderCore = MockOrderCore(address(hubWormhole));
        _deposit(alice, 10_000e6);
        _ensureSpokeReport();
        bytes32 outbound = _send(8000e6, 8000e6);
        _deliver(_arrived(_spokeReport(8000e6, 8000e6), outbound, 8000e6));
    }

    function _start() internal returns (ICoreVaultPayouts.PayoutRequest memory request) {
        vm.prank(alice);
        ICoreVaultPayouts.PayoutReceipt memory receipt =
            vault.requestPayout(5000e6, ICoreVaultPayouts.PayoutMode.Instant, 100);
        assertEq(receipt.sharesBurned, 0);
        request = vault.payoutRequest(alice);
        assertTrue(request.awaitingSettlement);
    }

    function _result(ICoreVaultPayouts.PayoutRequest memory request, uint256 marketCost, uint256 leaverCost)
        internal
        view
        returns (SpokeUnwindTypes.OrderResult memory result)
    {
        OrderCodec.Order memory order = OrderCodec.decode(orderCore.published(orderCore.publishedCount() - 1).payload);
        result.orderId = OrderCodec.orderId(order);
        result.requestId = request.requestId;
        result.attempt = request.attempt;
        result.transitId = HOME;
        result.amountSent = 4000e6;
        result.amountToArrive = 3990e6;
        result.marketCost = marketCost;
        result.leaverCost = leaverCost;
        result.delivered = 1;
    }

    function _report(SpokeUnwindTypes.OrderResult memory result) internal {
        ReportCodec.Report memory report = _inFlightToHub(_spokeReport(4000e6, 8000e6), HOME, 3990e6);
        report.cumulativeSentHome = 4000e6;
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0] = result;
        report.unwindResults = abi.encode(results);
        _deliver(report);
    }

    function _fill(uint256 amount) internal {
        usdc.mint(address(vault), amount);
        vm.prank(address(pool));
        vault.handleV3AcrossMessage(
            address(usdc), amount, address(this), TransitMessage.encode(FUND_ID, SPOKE, HOME, TransferKind.Principal)
        );
    }

    function test_DEC120_publishesOneBroadcastAndEarmarksIdle() public {
        uint256 idle = vault.idle();
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        assertEq(orderCore.publishedCount(), 1);
        MockOrderCore.Published memory published = orderCore.published(0);
        OrderCodec.Order memory order = OrderCodec.decode(published.payload);
        assertEq(published.emitter, address(vault));
        assertEq(published.consistencyLevel, 200);
        assertEq(order.kind, OrderCodec.UNWIND);
        assertEq(order.requestId, request.requestId);
        assertEq(order.fracNum, request.fracNum);
        assertEq(order.fracDen, request.fracDen);
        assertEq(order.maxLossBps, 100);
        assertEq(request.expectedSpokes, 1);
        assertEq(vault.payoutReserve(), idle);
        assertEq(vault.freeIdle(), 0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 1, 0));
        vault.allocateToHubSpokeVault(1);
    }

    function test_DEC105_settlementWaitsForReportAndFullPrincipalCredit() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotReported.selector, 0));
        vault.settlePayout(alice);
        _report(_result(request, 0, 10e6));
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.settlePayout(alice);
        _fill(3989e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.settlePayout(alice);
        _fill(1e6);
        uint256 beforeAlice = usdc.balanceOf(alice);
        uint256 beforeStranger = usdc.balanceOf(stranger);
        vm.prank(stranger);
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.settlePayout(alice);
        assertGt(receipt.sharesBurned, 0);
        assertEq(receipt.leaverCost, 10e6);
        assertEq(usdc.balanceOf(alice) - beforeAlice, receipt.usdcPaid);
        assertEq(usdc.balanceOf(stranger), beforeStranger);
        assertFalse(vault.payoutRequest(alice).open);
        assertEq(vault.payoutReserve(), 0);
    }

    function test_DEC105_arrivalBeforeReportWaitsThenSettlesAtOnePrice() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _fill(3990e6);
        assertEq(vault.unmatchedArrivals(), 3990e6);
        _report(_result(request, 20e6, 30e6));
        assertEq(vault.unmatchedArrivals(), 0);
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.settlePayout(alice);
        assertEq(receipt.leaverCost, 30e6);
        assertEq(receipt.marketCost, 20e6);
        assertEq(
            receipt.sharePrice, ShareMath.sharePrice(receipt.shareAssets + receipt.leaverCost, receipt.totalShares)
        );
    }

    function test_DEC093_oldAttemptResultIsIgnored() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory result = _result(request, 0, 0);
        result.attempt = request.attempt - 1;
        _report(result);
        assertEq(vault.payoutRequest(alice).reportedSpokes, 0);
    }

    function test_DEC120_malformedResultDoesNotRefuseReport() public {
        _start();
        ReportCodec.Report memory report = _spokeReport(8000e6, 8000e6);
        report.unwindResults = hex"1234";
        _deliver(report);
        assertEq(vault.payoutRequest(alice).reportedSpokes, 0);
    }

    function test_DEC151_cannotClaimAgainBeforeSettlement() public {
        _start();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.PayoutAwaitingSettlement.selector, alice));
        vault.claimPayout(0);
    }

    function test_DEC151_missingReportCanRepublishAfterOrderExpires() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        vm.warp(uint256(request.orderDeadline) + 1);
        _deliver(_spokeReport(8000e6, 8000e6));
        vm.prank(alice);
        vault.claimPayout(200);
        ICoreVaultPayouts.PayoutRequest memory retry = vault.payoutRequest(alice);
        assertEq(retry.attempt, request.attempt + 1);
        assertEq(retry.fracNum, request.fracNum);
        assertEq(retry.fracDen, request.fracDen);
        assertEq(retry.expectedSpokes, 1);
        assertEq(orderCore.publishedCount(), 2);
        assertTrue(retry.awaitingSettlement);
    }

    function test_DEC068_confirmedRefundAllowsPartialPayoutWithoutBurningMissingValue() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory result = _result(request, 0, 0);
        result.refunded = true;
        result.excluded = 1;
        _report(result);
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.settlePayout(alice);
        assertGt(receipt.usdcPaid, 0);
        assertGt(receipt.usdcOutstanding, 0);
        assertTrue(vault.payoutRequest(alice).open);
        vm.prank(alice);
        vault.claimPayout(0);
        assertEq(vault.payoutRequest(alice).attempt, request.attempt + 1);
        assertTrue(vault.payoutRequest(alice).awaitingSettlement);
    }
}
