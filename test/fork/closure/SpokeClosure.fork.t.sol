pragma solidity 0.8.28;

import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {VaaBody, VaaLib} from "wormhole-sdk/libraries/VaaLib.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {TransferKind, Transit} from "../../../src/interfaces/FundTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";

contract SpokeClosureForkTest is EndToEndScenario {
    using AdvancedWormholeOverride for ICoreBridge;

    function test_B02_alphaFiveUsdcCloseExcludesLatePrincipalDustWithoutAnotherCloseAndSweeps() public {
        _createForks();
        _phase1CreateFund();
        _deliverFirstSpokeReport();
        _onArbitrum();
        vm.prank(manager);
        bytes32 outbound = core.sendToSpoke(0, 5e6, 0, "");
        Transit memory sent = core.transit(outbound);
        _onRobinhood();
        deal(RH_USDG, address(spokeVault), sent.amountToArrive);
        vm.prank(RH_ACROSS_SPOKE_POOL);
        spokeVault.handleV3AcrossMessage(
            RH_USDG,
            sent.amountToArrive,
            relayer,
            TransitMessage.encode(fundId, ARBITRUM, outbound, TransferKind.Principal)
        );
        _deliverFreshSpokeReport();
        _onRobinhood();
        ICoreBridge(RH_WORMHOLE_CORE).setUpOverride();
        _onArbitrum();
        vm.prank(manager);
        core.closeFund();
        SpokeUnwindTypes.OrderResult memory first = _closeAttempt();
        assertGt(first.amountToArrive, 4e6);
        deal(ARB_USDC, address(core), IERC20(ARB_USDC).balanceOf(address(core)) + first.amountToArrive);
        vm.prank(ARB_ACROSS_SPOKE_POOL);
        core.handleV3AcrossMessage(
            ARB_USDC,
            first.amountToArrive,
            relayer,
            TransitMessage.encode(fundId, ROBINHOOD, first.transitId, TransferKind.Principal)
        );
        _onRobinhood();
        deal(RH_USDG, address(spokeVault), 20_000);
        vm.prank(RH_ACROSS_SPOKE_POOL);
        spokeVault.handleV3AcrossMessage(
            RH_USDG,
            20_000,
            relayer,
            TransitMessage.encode(fundId, ARBITRUM, keccak256("terminal dust"), TransferKind.Principal)
        );
        Transit memory home = spokeVault.hubBoundTransit(first.transitId);
        _advance(uint256(home.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1 - block.timestamp);
        _deliverFreshSpokeReport();
        core.requestIncomeWithdrawal(0);
        core.finalizeClosure();
        assertEq(uint256(core.fundState()), uint256(ICoreVaultLifecycle.FundState.Closed));
        _onRobinhood();
        assertEq(spokeVault.unallocatedBalance(RH_USDG), 0);
        address recipient = spokeVault.excessRecipient();
        uint256 beforeSweep = IERC20(RH_USDG).balanceOf(recipient);
        vm.expectEmit(true, true, false, true, address(spokeVault));
        emit ISpokeVault.ExcessSwept(RH_USDG, recipient, 20_000);
        assertEq(spokeVault.sweepExcess(RH_USDG), 20_000);
        assertEq(IERC20(RH_USDG).balanceOf(recipient) - beforeSweep, 20_000);
        assertEq(spokeVault.sweepExcess(RH_USDG), 0);
    }

    function _closeAttempt() internal returns (SpokeUnwindTypes.OrderResult memory result) {
        _onArbitrum();
        vm.recordLogs();
        vm.prank(manager);
        core.unwindAllAfterDeadline();
        VaaBody[] memory orders = ICoreBridge(ARB_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(orders.length, 1);
        assertEq(OrderCodec.decode(orders[0].payload).kind, OrderCodec.CLOSE);
        _onRobinhood();
        _advance(1 minutes);
        ICoreBridge destination = ICoreBridge(RH_WORMHOLE_CORE);
        vm.recordLogs();
        spokeVault.executeOrder(VaaLib.encode(destination.sign(orders[0])));
        VaaBody[] memory reports = destination.fetchPublishedMessages(vm.getRecordedLogs());
        assertEq(reports.length, 1);
        ReportCodec.Report memory report = ReportCodec.decode(reports[0].payload);
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        result = results[results.length - 1];
        assertEq(result.excluded, 0);
        _onArbitrum();
        _advance(1 minutes);
        receiver.deliver(VaaLib.encode(ICoreBridge(ARB_WORMHOLE_CORE).sign(reports[0])));
    }

    function test_REGRESSION_realCloseExecutorReportArrivalRetryFinalizeAndExit() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _onRobinhood();
        deal(RH_USDG, address(spokeVault), IERC20(RH_USDG).balanceOf(address(spokeVault)) + amountToArrive);
        vm.prank(RH_ACROSS_SPOKE_POOL);
        spokeVault.handleV3AcrossMessage(RH_USDG, amountToArrive, relayer, acrossMessage);
        _openSpokeUniswapPosition();
        ICoreBridge(RH_WORMHOLE_CORE).setUpOverride();
        _onArbitrum();
        vm.prank(manager);
        core.closeFund();
        SpokeUnwindTypes.OrderResult memory first = _closeAttempt();
        assertGt(first.amountToArrive, 0);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        core.finalizeClosure();
        deal(ARB_USDC, address(core), IERC20(ARB_USDC).balanceOf(address(core)) + first.amountToArrive);
        vm.prank(ARB_ACROSS_SPOKE_POOL);
        core.handleV3AcrossMessage(
            ARB_USDC,
            first.amountToArrive,
            relayer,
            TransitMessage.encode(fundId, ROBINHOOD, first.transitId, TransferKind.Principal)
        );
        _onRobinhood();
        Transit memory transit = spokeVault.hubBoundTransit(first.transitId);
        _advance(uint256(transit.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1 - block.timestamp);
        SpokeUnwindTypes.OrderResult memory second = _closeAttempt();
        assertEq(second.attempt, 2);
        assertEq(second.transitId, first.transitId);
        assertEq(second.amountSent, first.amountSent);
        assertEq(second.amountToArrive, first.amountToArrive);
        assertEq(second.closureExcessCost, first.closureExcessCost);
        core.requestIncomeWithdrawal(0);
        core.finalizeClosure();
        assertEq(uint8(core.fundState()), uint8(ICoreVaultLifecycle.FundState.Closed));
        assertEq(IERC20(shareToken).balanceOf(manager), 0);
        uint256 frozenIdle = core.closedIdle();
        uint256 income = core.incomeOwed(ana);
        uint256 before = IERC20(ARB_USDC).balanceOf(ana);
        uint256 paid = core.exitClosedFund(ana);
        assertEq(IERC20(ARB_USDC).balanceOf(ana) - before, paid + income);
        assertEq(paid, frozenIdle - frozenIdle * core.flowFeeBps() / 10_000);
        assertEq(IERC20(shareToken).totalSupply(), 0);
    }
}
