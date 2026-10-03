pragma solidity 0.8.28;

import {SpokeUnwindRoundTwoTest} from "./SpokeUnwindRoundTwo.t.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISpokeVaultIncome} from "../../../src/interfaces/ISpokeVaultIncome.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";

contract ManualSendAcknowledgementTest is SpokeUnwindRoundTwoTest {
    function test_manualPrincipalMoreThanSixteenAcknowledgedSends() public {
        for (uint64 index; index < 24; ++index) {
            bytes32 transitId = _manual(10e6, TransferKind.Principal);
            assertEq(vault.inFlightTransitIds().length, 1);
            _acknowledge(transitId, index * 2 + 1, uint8(TransitState.ArrivalConfirmed));
            _assertRetired(transitId, TransitState.ArrivalConfirmed);
            _acknowledge(transitId, index * 2 + 2, uint8(TransitState.ArrivalConfirmed));
            assertEq(vault.unallocatedBalance(address(usdg)), 1000e6 - (index + 1) * 10e6);
            vm.warp(block.timestamp + 1 minutes);
        }
    }

    function test_collectionIncomeMoreThanSharedCapacityAcknowledgedSends() public {
        _position();
        for (uint64 index; index < 65; ++index) {
            _earnIncome(spokeUni, position, 0, 10e6);
            OrderCodec.Order memory order;
            order.kind = OrderCodec.COLLECT;
            order.fundId = FUND_ID;
            order.requestId = bytes32(uint256(index + 1));
            order.deadline = uint64(block.timestamp) + 1 hours;
            vault.executeOrder(
                orderCore.craft(
                    23, bytes32(uint256(uint160(address(core)))), index * 2 + 1, 200, OrderCodec.encode(order)
                )
            );
            SpokeIncomeTypes.CollectionResult[] memory results =
                abi.decode(vault.buildReport().collectionResults, (SpokeIncomeTypes.CollectionResult[]));
            bytes32 transitId = results[results.length - 1].transitId;
            assertEq(uint8(vault.hubBoundTransit(transitId).kind), uint8(TransferKind.Income));
            assertEq(vault.inFlightTransitIds().length, 1);
            bytes memory blob = vault.buildReport().collectionResults;
            _acknowledge(transitId, index * 2 + 2, uint8(TransitState.ArrivalConfirmed));
            _assertRetired(transitId, TransitState.ArrivalConfirmed);
            assertEq(vault.buildReport().collectionResults, blob);
            assertEq(vault.collectedIncome(address(usdg)), 0);
            vm.warp(block.timestamp + 1 minutes);
        }
    }

    function test_manualAndUnwindShareCapacityWithoutChangingResults() public {
        bytes32 manualId = _manual(10e6, TransferKind.Principal);
        _distinctSend(1, OrderCodec.UNWIND);
        bytes32 unwindId = _records()[0].transitId;
        bytes memory results = vault.buildReport().unwindResults;
        _acknowledge(manualId, 2, uint8(TransitState.ArrivalConfirmed));
        assertEq(vault.buildReport().unwindResults, results);
        assertEq(vault.inFlightTransitIds().length, 1);
        assertEq(vault.inFlightTransitIds()[0], unwindId);
        _acknowledge(unwindId, 3, uint8(TransitState.ArrivalConfirmed));
        assertEq(_records().length, 0);
        _assertRetired(unwindId, TransitState.ArrivalConfirmed);
        _distinctSend(4, OrderCodec.CLOSE);
        _acknowledge(_records()[0].transitId, 5, uint8(TransitState.ArrivalConfirmed));
        assertTrue(vault.spokeClosed());
        assertEq(_records().length, 0);
        assertEq(vault.inFlightTransitIds().length, 0);
    }

    function test_manualRefundAcknowledgementCreditsExactlyOnce() public {
        bytes32 transitId = _manual(10e6, TransferKind.Principal);
        Transit memory transit = vault.hubBoundTransit(transitId);
        vm.warp(uint256(transit.fillDeadline) + 1);
        usdg.mint(transit.escrow, transit.amountSent);
        assertEq(vault.recognizeRefund(transitId), 10e6);
        assertEq(vault.buildReport().refundedTransits[0], transitId);
        _acknowledge(transitId, 1, uint8(TransitState.RefundRecognized));
        _acknowledge(transitId, 2, uint8(TransitState.RefundRecognized));
        _assertRetired(transitId, TransitState.RefundRecognized);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnknownTransit.selector, transitId));
        vault.recognizeRefund(transitId);
        _manual(10e6, TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 990e6);
    }

    function test_manualIncomeEntryRemainsCollectionOnly() public {
        vm.prank(manager);
        vm.expectRevert(ISpokeVaultIncome.IncomeSentOnlyByCollection.selector);
        vault.sendToHub(10e6, TransferKind.Income, 0);
    }

    function test_manualRefundHistoryIsBoundedAndKeepsLatestProofs() public {
        bytes32 first;
        bytes32 last;
        for (uint256 index; index <= SpokeVaultTypes.ARRIVAL_WINDOW; ++index) {
            last = _manual(1e6, TransferKind.Principal);
            if (index == 0) first = last;
            Transit memory transit = vault.hubBoundTransit(last);
            vm.warp(uint256(transit.fillDeadline) + 1);
            usdg.mint(transit.escrow, transit.amountSent);
            vault.recognizeRefund(last);
        }
        bytes32[] memory refunds = vault.buildReport().refundedTransits;
        assertEq(refunds.length, SpokeVaultTypes.ARRIVAL_WINDOW);
        assertNotEq(refunds[0], first);
        assertEq(refunds[refunds.length - 1], last);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6);
    }

    function test_unknownAndPrematureRefundAcknowledgementsRevert() public {
        bytes memory vaa = _invalidAck(keccak256("unknown"), uint8(TransitState.ArrivalConfirmed));
        vm.expectRevert(SpokeUnwindTypes.InvalidTransitOutcome.selector);
        vault.executeOrder(vaa);
        bytes32 transitId = _manual(10e6, TransferKind.Principal);
        vaa = _invalidAck(transitId, uint8(TransitState.RefundRecognized));
        vm.expectRevert(SpokeUnwindTypes.InvalidTransitOutcome.selector);
        vault.executeOrder(vaa);
        assertEq(uint8(vault.hubBoundTransit(transitId).state), uint8(TransitState.Sent));
        assertEq(vault.inFlightTransitIds().length, 1);
    }

    function test_fullManualCapacityThenAcknowledgementReleasesSlotImmediately() public {
        bytes32 first;
        uint256 limit = SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT;
        for (uint256 index; index < limit; ++index) {
            bytes32 transitId = _manual(10e6, TransferKind.Principal);
            if (index == 0) first = transitId;
        }
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.HubBoundInFlightLimit.selector, limit));
        vault.sendToHub(10e6, TransferKind.Principal, 0);
        _acknowledge(first, 1, uint8(TransitState.ArrivalConfirmed));
        assertEq(vault.inFlightTransitIds().length, limit - 1);
        _manual(10e6, TransferKind.Principal);
        assertEq(vault.inFlightTransitIds().length, limit);
    }

    function _manual(uint256 amount, TransferKind kind) internal returns (bytes32 transitId) {
        vm.prank(manager);
        transitId = vault.sendToHub(amount, kind, 0);
    }

    function _invalidAck(bytes32 transitId, uint8 outcome) internal view returns (bytes memory) {
        OrderCodec.Order memory order;
        order.kind = OrderCodec.ACKNOWLEDGE;
        order.fundId = FUND_ID;
        order.requestId = transitId;
        order.fracNum = SPOKE;
        order.fracDen = outcome;
        order.deadline = uint64(block.timestamp) + 1 hours;
        return orderCore.craft(23, bytes32(uint256(uint160(address(core)))), 1, 200, OrderCodec.encode(order));
    }

    function _assertRetired(bytes32 transitId, TransitState state) internal view {
        assertEq(uint8(vault.hubBoundTransit(transitId).state), uint8(state));
        assertEq(vault.inFlightTransitIds().length, 0);
        assertEq(vault.buildReport().inFlightToHub.length, 0);
    }
}
