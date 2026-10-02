pragma solidity 0.8.28;

import {CoreVaultSpokeSettlementTest} from "./CoreVaultSpokeSettlement.t.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";

contract CoreVaultSpokeRoundTwoTest is CoreVaultSpokeSettlementTest {
    function test_H1R2_acknowledgementRequiresFullCredit() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        _report(_result(request, 0, 10e6));
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.acknowledgeSpokeTransit(0, HOME);
        _fill(3989e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.acknowledgeSpokeTransit(0, HOME);
        _fill(1e6);
        vault.acknowledgeSpokeTransit(0, HOME);
        OrderCodec.Order memory order = OrderCodec.decode(orderCore.published(1).payload);
        assertEq(order.kind, 4);
        assertEq(order.requestId, HOME);
        assertEq(order.fracNum, SPOKE);
        assertEq(order.fracDen, 2);
        assertEq(orderCore.published(1).emitter, address(vault));
    }

    function test_H1R2_acknowledgesAcceptedRefundProof() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory result = _result(request, 0, 10e6);
        result.refunded = true;
        _report(result);
        vault.acknowledgeSpokeTransit(0, HOME);
        OrderCodec.Order memory order = OrderCodec.decode(orderCore.published(1).payload);
        assertEq(order.fracDen, 4);
    }

    function test_M2R2_olderRefundNeverChargesItsFee() public {
        ICoreVaultPayouts.PayoutRequest memory request = _start();
        SpokeUnwindTypes.OrderResult memory first = _result(request, 0, 10e6);
        vm.warp(uint256(request.orderDeadline) + 1);
        _deliver(_spokeReport(8000e6, 8000e6));
        vm.prank(alice);
        vault.claimPayout(200);
        request = vault.payoutRequest(alice);
        SpokeUnwindTypes.OrderResult memory second = _result(request, 100e6, 120e6);
        second.transitId = keccak256("second send");
        first.refunded = true;
        ReportCodec.Report memory report = _inFlightToHub(_spokeReport(4000e6, 8000e6), second.transitId, 3990e6);
        report.cumulativeSentHome = 4000e6;
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](2);
        results[0] = first;
        results[1] = second;
        report.unwindResults = abi.encode(results);
        _deliver(report);
        _deliver(report);
        usdc.mint(address(vault), 3990e6);
        vm.prank(address(pool));
        vault.handleV3AcrossMessage(
            address(usdc),
            3990e6,
            address(this),
            TransitMessage.encode(FUND_ID, SPOKE, second.transitId, TransferKind.Principal)
        );
        ICoreVaultPayouts.PayoutReceipt memory receipt = vault.settlePayout(alice);
        assertEq(receipt.marketCost, 100e6);
        assertEq(receipt.leaverCost, 110e6);
    }
}
