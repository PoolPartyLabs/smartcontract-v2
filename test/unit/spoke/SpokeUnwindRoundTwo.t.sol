pragma solidity 0.8.28;

import {SpokeUnwindOrdersTest} from "./SpokeUnwindOrders.t.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";

contract SpokeUnwindRoundTwoTest is SpokeUnwindOrdersTest {
    function test_M2R2_olderRefundUpdatesNewerCumulativeCosts() public {
        _position();
        spokeSwap.setHaircutBps(200);
        spokeBridge.setFee(1e6);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 100, true);
        SpokeUnwindTypes.OrderResult memory second = _execute(OrderCodec.UNWIND, 2, 300, true);
        assertEq(second.leaverCost, 6e6);
        Transit memory transit = vault.hubBoundTransit(first.transitId);
        vm.warp(uint256(transit.fillDeadline) + 1);
        usdg.mint(transit.escrow, transit.amountSent);
        vault.recognizeRefund(first.transitId);
        vault.report();
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(vault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertTrue(results[0].refunded);
        assertEq(results[1].leaverCost, 5e6);
        vault.report();
        results = abi.decode(vault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertEq(results[1].leaverCost, 5e6);
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 3, 0, true);
        assertEq(retry.leaverCost, 6e6);
        assertEq(retry.marketCost, 4e6);
    }

    function test_H1R2_authenticatedExpiryFreesSlotAndLateRefundRemainsRecoverable() public {
        _distinctSend(1, OrderCodec.UNWIND);
        bytes32 transitId = _records()[0].transitId;
        Transit memory transit = vault.hubBoundTransit(transitId);
        vm.warp(uint256(transit.fillDeadline) + 1);
        _acknowledge(transitId, 2, 3);
        assertEq(_records().length, 0);
        usdg.mint(transit.escrow, transit.amountSent);
        assertEq(vault.recognizeRefund(transitId), transit.amountSent);
        _distinctSend(3, OrderCodec.UNWIND);
        assertEq(_records().length, 1);
    }

    function test_H1R2_untrustedEmitterCannotRetireTransit() public {
        _distinctSend(1, OrderCodec.UNWIND);
        OrderCodec.Order memory order;
        order.kind = 4;
        order.fundId = FUND_ID;
        order.requestId = _records()[0].transitId;
        order.deadline = uint64(block.timestamp) + 1 hours;
        order.fracNum = SPOKE;
        order.fracDen = 2;
        bytes memory vaa = orderCore.craft(23, bytes32(uint256(uint160(stranger))), 2, 200, OrderCodec.encode(order));
        vm.expectRevert();
        vault.executeOrder(vaa);
        assertEq(_records().length, 1);
    }

    function test_H1R2_seventeenthSendAfterHubAcknowledgedRefunds() public {
        for (uint32 sequence = 1; sequence <= 17; ++sequence) {
            _arrive(1000e6, keccak256(abi.encode("deposit", sequence)), TransferKind.Principal);
            OrderCodec.Order memory order;
            order.kind = OrderCodec.UNWIND;
            order.fundId = FUND_ID;
            order.requestId = keccak256(abi.encode("request", sequence));
            order.attempt = 1;
            order.deadline = uint64(block.timestamp) + 1 hours;
            order.fracNum = 1;
            order.fracDen = 2;
            vault.executeOrder(
                orderCore.craft(
                    23, bytes32(uint256(uint160(address(core)))), sequence * 2, 200, OrderCodec.encode(order)
                )
            );
            if (sequence < 17) {
                SpokeUnwindTypes.OrderResult[] memory results =
                    abi.decode(vault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[]));
                bytes32 transitId = results[results.length - 1].transitId;
                Transit memory transit = vault.hubBoundTransit(transitId);
                vm.warp(uint256(transit.fillDeadline) + 1);
                usdg.mint(transit.escrow, transit.amountSent);
                vault.recognizeRefund(transitId);
                vault.report();
                _acknowledge(transitId, sequence * 2 + 1, 4);
                assertEq(_records().length, 0);
            }
        }
    }

    function test_H1R2_sixteenUnresolvedThenArrivalRetiresAndCloseWorks() public {
        for (uint32 sequence = 1; sequence <= 16; ++sequence) {
            _distinctSend(sequence, OrderCodec.UNWIND);
        }
        SpokeUnwindTypes.OrderResult[] memory records = _records();
        assertEq(records.length, 16);
        bytes32 oldest = records[0].transitId;
        _distinctSend(17, OrderCodec.UNWIND);
        assertEq(_records().length, 16);
        _acknowledge(oldest, 18, 2);
        assertEq(_records().length, 15);
        _distinctSend(19, OrderCodec.UNWIND);
        assertEq(_records().length, 16);
        _acknowledge(_records()[0].transitId, 20, 2);
        _distinctSend(21, OrderCodec.CLOSE);
        assertEq(_records().length, 16);
        assertTrue(vault.spokeClosed());
    }

    function test_H1R2_moreThanSixteenArrivalsAndCloseKeepWorking() public {
        for (uint32 sequence = 1; sequence <= 20; ++sequence) {
            _distinctSend(sequence * 2, sequence == 20 ? OrderCodec.CLOSE : OrderCodec.UNWIND);
            SpokeUnwindTypes.OrderResult[] memory records = _records();
            assertEq(records.length, 1);
            OrderCodec.Order memory order;
            order.kind = 4;
            order.fundId = FUND_ID;
            order.requestId = records[0].transitId;
            order.deadline = uint64(block.timestamp) + 1 hours;
            order.fracNum = SPOKE;
            order.fracDen = 2;
            vault.executeOrder(
                orderCore.craft(
                    23, bytes32(uint256(uint160(address(core)))), sequence * 2 + 1, 200, OrderCodec.encode(order)
                )
            );
            assertEq(_records().length, 0);
        }
        assertTrue(vault.spokeClosed());
    }

    function _distinctSend(uint32 sequence, uint8 kind) internal {
        _arrive(1000e6, keccak256(abi.encode("fresh deposit", sequence)), TransferKind.Principal);
        OrderCodec.Order memory order;
        order.kind = kind;
        order.fundId = FUND_ID;
        order.requestId = keccak256(abi.encode("distinct request", sequence));
        order.attempt = 1;
        order.deadline = uint64(block.timestamp) + 1 hours;
        order.fracNum = 1;
        order.fracDen = 2;
        bytes memory vaa =
            orderCore.craft(23, bytes32(uint256(uint160(address(core)))), sequence, 200, OrderCodec.encode(order));
        if (sequence == 17) vm.expectRevert(SpokeUnwindTypes.OrderResultCapacity.selector);
        vault.executeOrder(vaa);
    }

    function _records() internal view returns (SpokeUnwindTypes.OrderResult[] memory) {
        return abi.decode(vault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[]));
    }

    function _acknowledge(bytes32 transitId, uint64 sequence, uint8 outcome) internal {
        OrderCodec.Order memory order;
        order.kind = 4;
        order.fundId = FUND_ID;
        order.requestId = transitId;
        order.deadline = uint64(block.timestamp) + 1 hours;
        order.fracNum = SPOKE;
        order.fracDen = outcome;
        vault.executeOrder(
            orderCore.craft(23, bytes32(uint256(uint160(address(core)))), sequence, 200, abi.encode(uint256(1), order))
        );
    }
}
