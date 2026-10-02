// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {EndToEndScenario} from "./EndToEnd.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {VaaBody, VaaLib} from "wormhole-sdk/libraries/VaaLib.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {console2} from "forge-std/console2.sol";

contract SpokeUnwindOrderForkTest is EndToEndScenario {
    using AdvancedWormholeOverride for ICoreBridge;

    function test_DEC139_publishExecuteReportCreditAndSettleAtOneSharePrice() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();
        _refreshEthUsdFeed();
        uint256 balanceBefore = IERC20(ARB_USDC).balanceOf(ana);
        vm.recordLogs();
        vm.prank(ana);
        ICoreVaultPayouts.PayoutReceipt memory initial =
            core.requestPayout(9000e6, ICoreVaultPayouts.PayoutMode.Instant, 500);
        assertEq(initial.sharesBurned, 0);
        ICoreVaultPayouts.PayoutRequest memory request = core.payoutRequest(ana);
        assertTrue(request.awaitingSettlement);
        VaaBody[] memory orders = ICoreBridge(ARB_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(orders.length, 1);
        assertEq(OrderCodec.decode(orders[0].payload).kind, OrderCodec.UNWIND);
        _onRobinhood();
        vm.warp(uint256(orders[0].envelope.timestamp) + 1 minutes);
        ICoreBridge destinationCore = ICoreBridge(RH_WORMHOLE_CORE);
        destinationCore.setUpOverride();
        bytes memory vaa = VaaLib.encode(destinationCore.sign(orders[0]));
        uint256 liquidityBefore = IAdapter(spokeUniswap).positionValue(spokeUniswapPosition).liquidity;
        vm.recordLogs();
        uint256 beforeGas = gasleft();
        spokeVault.executeOrder(vaa);
        console2.log("executeOrder gas", beforeGas - gasleft());
        VaaBody[] memory reports = destinationCore.fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(reports.length, 1);
        ReportCodec.Report memory report = ReportCodec.decode(reports[0].payload);
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertEq(results.length, 1);
        SpokeUnwindTypes.OrderResult memory result = results[0];
        assertGt(result.amountSent, 0);
        assertLt(result.amountToArrive, result.amountSent);
        assertEq(result.excluded, 0);
        assertLt(IAdapter(spokeUniswap).positionValue(spokeUniswapPosition).liquidity, liquidityBefore);
        _onArbitrum();
        vm.warp(uint256(reports[0].envelope.timestamp) + 1 minutes);
        receiver.deliver(VaaLib.encode(ICoreBridge(ARB_WORMHOLE_CORE).sign(reports[0])));
        deal(ARB_USDC, address(core), IERC20(ARB_USDC).balanceOf(address(core)) + result.amountToArrive);
        vm.prank(ARB_ACROSS_SPOKE_POOL);
        core.handleV3AcrossMessage(
            ARB_USDC,
            result.amountToArrive,
            relayer,
            TransitMessage.encode(fundId, 4663, result.transitId, TransferKind.Principal)
        );
        _refreshEthUsdFeed();
        beforeGas = gasleft();
        ICoreVaultPayouts.PayoutReceipt memory receipt = core.settlePayout(ana);
        console2.log("settlePayout gas", beforeGas - gasleft());
        assertGt(receipt.sharesBurned, 0);
        assertEq(IERC20(ARB_USDC).balanceOf(ana) - balanceBefore, receipt.usdcPaid);
        assertEq(receipt.leaverCost, result.leaverCost + receipt.marketCost - result.marketCost);
        assertFalse(core.payoutRequest(ana).open);
        assertEq(core.payoutReserve(), 0);
    }
}
