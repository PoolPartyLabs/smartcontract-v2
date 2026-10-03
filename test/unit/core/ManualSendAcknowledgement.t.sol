pragma solidity 0.8.28;

import {CoreVaultSpokeSettlementTest} from "./CoreVaultSpokeSettlement.t.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {TransferKind, TransitState} from "../../../src/interfaces/FundTypes.sol";

contract CoreManualSendAcknowledgementTest is CoreVaultSpokeSettlementTest {
    function test_manualPrincipalAcknowledgementDoesNotDoubleCredit() public {
        _creditedManual(TransferKind.Principal);
    }

    function test_manualIncomeAcknowledgementRequiresFullCreditAndDoesNotDoubleCredit() public {
        _creditedManual(TransferKind.Income);
    }

    function test_manualRefundRequiresExplicitAcceptedProof() public {
        _deliver(_spokeReport(8000e6, 8000e6));
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.acknowledgeSpokeTransit(0, HOME);
        ReportCodec.Report memory report = _spokeReport(8000e6, 8000e6);
        report.refundedTransits = new bytes32[](1);
        report.refundedTransits[0] = HOME;
        _deliver(report);
        uint256 idle = vault.idle();
        vault.acknowledgeSpokeTransit(0, HOME);
        vault.acknowledgeSpokeTransit(0, HOME);
        assertEq(OrderCodec.decode(orderCore.published(0).payload).fracDen, uint256(TransitState.RefundRecognized));
        assertEq(vault.idle(), idle);
    }

    function _creditedManual(TransferKind kind) internal {
        _deliver(_inFlightToHub(_spokeReport(7990e6, 8000e6), HOME, 10e6, kind));
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.acknowledgeSpokeTransit(0, HOME);
        _manualFill(kind, 9e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultPayouts.SpokeUnwindNotCredited.selector, 0, HOME));
        vault.acknowledgeSpokeTransit(0, HOME);
        _manualFill(kind, 1e6);
        uint256 idle = vault.idle();
        uint256 assets = vault.grossAssets();
        uint256 held = usdc.balanceOf(address(vault));
        vault.acknowledgeSpokeTransit(0, HOME);
        vault.acknowledgeSpokeTransit(0, HOME);
        assertEq(OrderCodec.decode(orderCore.published(0).payload).fracDen, uint256(TransitState.ArrivalConfirmed));
        assertEq(vault.idle(), idle);
        assertEq(vault.grossAssets(), assets);
        assertEq(usdc.balanceOf(address(vault)), held);
    }

    function _manualFill(TransferKind kind, uint256 amount) internal {
        usdc.mint(address(vault), amount);
        vm.prank(address(pool));
        vault.handleV3AcrossMessage(
            address(usdc), amount, address(this), TransitMessage.encode(FUND_ID, SPOKE, HOME, kind)
        );
    }
}
