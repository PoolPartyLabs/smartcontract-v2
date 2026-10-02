// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeUnwindOrdersTest} from "./SpokeUnwindOrders.t.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {Transit} from "../../../src/interfaces/FundTypes.sol";

contract SpokeUnwindReviewTest is SpokeUnwindOrdersTest {
    function test_H3_retryRetainsUnresolvedSend() public {
        spokeBridge.setFee(1e6);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 0, true);
        vm.warp(block.timestamp + 3601);
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 2, 0, true);
        assertEq(retry.transitId, first.transitId);
        assertEq(retry.amountToArrive, first.amountToArrive);
        assertEq(retry.leaverCost, first.leaverCost);
    }

    function test_M3_sameOrderIdCannotExecuteAtNewSequence() public {
        _execute(OrderCodec.UNWIND, 1, 0, true);
        OrderCodec.Order memory order;
        order.kind = OrderCodec.UNWIND;
        order.fundId = FUND_ID;
        order.requestId = REQUEST;
        order.attempt = 1;
        order.deadline = uint64(block.timestamp) + 1 hours;
        order.fracNum = 1;
        order.fracDen = 2;
        bytes memory vaa =
            orderCore.craft(23, bytes32(uint256(uint160(address(core)))), 2, 200, OrderCodec.encode(order));
        vm.expectRevert(abi.encodeWithSignature("OrderAlreadyExecuted(bytes32)", OrderCodec.orderId(order)));
        vault.executeOrder(vaa);
        assertEq(vault.reportSequence(), 1);
    }

    function test_H3_twoOutstandingSendsStayInReportOnRetry() public {
        _position();
        spokeSwap.setHaircutBps(200);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 100, true);
        SpokeUnwindTypes.OrderResult memory second = _execute(OrderCodec.UNWIND, 2, 300, true);
        _execute(OrderCodec.UNWIND, 3, 0, true);
        ReportCodec.Report memory report = ReportCodec.decode(orderCore.published(2).payload);
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertEq(results[0].transitId, first.transitId);
        assertEq(results[1].transitId, second.transitId);
        assertEq(results[2].transitId, second.transitId);
    }

    function test_M2_refundResendRetainsSaleCostsWithoutRepeatingBridgeFee() public {
        _position();
        spokeSwap.setHaircutBps(200);
        spokeBridge.setFee(1e6);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 0, true);
        Transit memory transit = vault.hubBoundTransit(first.transitId);
        vm.warp(uint256(transit.fillDeadline) + 1);
        usdg.mint(transit.escrow, transit.amountSent);
        vault.recognizeRefund(first.transitId);
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 2, 0, true);
        assertEq(retry.marketCost, first.marketCost);
        assertEq(retry.leaverCost, first.leaverCost);
        assertEq(retry.amountSent, first.amountSent);
    }

    function test_H3_fullWindowNeverEvictsDistinctUnresolvedSend() public {
        _position();
        spokeSwap.setHaircutBps(200);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 100, true);
        _execute(OrderCodec.UNWIND, 2, 300, true);
        for (uint32 attempt = 3; attempt <= 20; ++attempt) {
            _execute(OrderCodec.UNWIND, attempt, 0, true);
        }
        ReportCodec.Report memory report = ReportCodec.decode(orderCore.published(19).payload);
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertEq(results.length, 16);
        assertEq(results[0].transitId, first.transitId);
    }
}
