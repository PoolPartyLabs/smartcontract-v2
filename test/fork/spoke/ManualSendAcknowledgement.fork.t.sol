// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {AdvancedWormholeOverride} from "wormhole-sdk/testing/WormholeOverride.sol";
import {VaaBody, VaaLib} from "wormhole-sdk/libraries/VaaLib.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";

contract ManualSendAcknowledgementForkTest is EndToEndScenario {
    using AdvancedWormholeOverride for ICoreBridge;

    function setUp() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();
        _onRobinhood();
        ICoreBridge(RH_WORMHOLE_CORE).setUpOverride();
    }

    function test_manualMoreThanSixteenAcknowledgedSendsKeepWorking() public {
        for (uint256 index; index < 24; ++index) {
            _onRobinhood();
            vm.prank(manager);
            bytes32 home = spokeVault.sendToHub(10e6, TransferKind.Principal, 0);
            Transit memory transit = spokeVault.hubBoundTransit(home);
            assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 1);
            _deliverCurrentReport();
            _fillHome(home, transit);
            uint256 idle = core.idle();
            _ackHome(home);
            assertEq(uint8(spokeVault.hubBoundTransit(home).state), uint8(TransitState.ArrivalConfirmed));
            assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 0);
            assertEq(spokeVault.buildReport().inFlightToHub.length, 0);
            _deliverCurrentReport();
            assertEq(core.idle(), idle);
            _ackHome(home);
            assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 0);
        }
    }

    function test_manualAndUnwindAcknowledgementsPreserveSettlement() public {
        _onRobinhood();
        vm.prank(manager);
        bytes32 manualId = spokeVault.sendToHub(10e6, TransferKind.Principal, 0);
        Transit memory manualTransit = spokeVault.hubBoundTransit(manualId);
        _deliverCurrentReport();
        _refreshEthUsdFeed();
        vm.recordLogs();
        vm.prank(ana);
        core.requestPayout(9000e6, ICoreVaultPayouts.PayoutMode.Instant, 500);
        VaaBody memory order = ICoreBridge(ARB_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs())[0];
        _onRobinhood();
        vm.warp(uint256(order.envelope.timestamp) + 1 minutes);
        spokeVault.executeOrder(VaaLib.encode(ICoreBridge(RH_WORMHOLE_CORE).sign(order)));
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(spokeVault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[]));
        bytes32 unwindId = results[0].transitId;
        Transit memory unwindTransit = spokeVault.hubBoundTransit(unwindId);
        bytes memory blob = spokeVault.buildReport().unwindResults;
        _deliverCurrentReport();
        _fillHome(manualId, manualTransit);
        _ackHome(manualId);
        assertEq(spokeVault.buildReport().unwindResults, blob);
        assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 1);
        _deliverCurrentReport();
        _fillHome(unwindId, unwindTransit);
        _refreshEthUsdFeed();
        ICoreVaultPayouts.PayoutReceipt memory receipt = core.settlePayout(ana);
        assertGt(receipt.sharesBurned, 0);
        assertFalse(core.payoutRequest(ana).open);
        assertEq(core.payoutReserve(), 0);
        _ackHome(unwindId);
        assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 0);
        assertEq(abi.decode(spokeVault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[])).length, 0);
    }

    function test_manualRefundIsAcknowledgedAndCreditedExactlyOnce() public {
        _onRobinhood();
        uint256 unallocated = spokeVault.unallocatedBalance(RH_USDG);
        vm.prank(manager);
        bytes32 home = spokeVault.sendToHub(10e6, TransferKind.Principal, 0);
        Transit memory transit = spokeVault.hubBoundTransit(home);
        vm.warp(uint256(transit.fillDeadline) + 1);
        deal(RH_USDG, transit.escrow, transit.amountSent);
        assertEq(spokeVault.recognizeRefund(home), transit.amountSent);
        assertEq(spokeVault.unallocatedBalance(RH_USDG), unallocated);
        _deliverCurrentReport();
        uint256 idle = core.idle();
        _ackHome(home);
        _ackHome(home);
        assertEq(uint8(spokeVault.hubBoundTransit(home).state), uint8(TransitState.RefundRecognized));
        assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 0);
        assertEq(spokeVault.unallocatedBalance(RH_USDG), unallocated);
        _onArbitrum();
        assertEq(core.idle(), idle);
        _onRobinhood();
        vm.prank(manager);
        spokeVault.sendToHub(10e6, TransferKind.Principal, 0);
    }

    function test_collectionIncomeAcknowledgementPreservesConversionOwnership() public {
        _onArbitrum();
        _refreshEthUsdFeed();
        vm.recordLogs();
        vm.prank(ana);
        core.requestIncomeWithdrawal(500);
        VaaBody memory order = ICoreBridge(ARB_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs())[0];
        assertEq(OrderCodec.decode(order.payload).kind, OrderCodec.COLLECT);
        _onRobinhood();
        vm.warp(uint256(order.envelope.timestamp) + 1 minutes);
        spokeVault.executeOrder(VaaLib.encode(ICoreBridge(RH_WORMHOLE_CORE).sign(order)));
        SpokeIncomeTypes.CollectionResult[] memory results =
            abi.decode(spokeVault.buildReport().collectionResults, (SpokeIncomeTypes.CollectionResult[]));
        bytes32 home = results[0].transitId;
        Transit memory transit = spokeVault.hubBoundTransit(home);
        assertEq(uint8(transit.kind), uint8(TransferKind.Income));
        assertGt(transit.amountSent, 0);
        bytes memory blob = spokeVault.buildReport().collectionResults;
        _deliverCurrentReport();
        _fillHome(home, transit);
        uint256 held = core.incomeCollection().heldDollars;
        uint256 idle = core.idle();
        _ackHome(home);
        assertEq(spokeVault.buildReport().collectionResults, blob);
        assertEq(SpokeVault(address(spokeVault)).inFlightTransitIds().length, 0);
        _deliverCurrentReport();
        assertEq(core.incomeCollection().heldDollars, held);
        assertEq(core.idle(), idle);
        _ackHome(home);
        assertEq(uint8(spokeVault.hubBoundTransit(home).state), uint8(TransitState.ArrivalConfirmed));
    }

    function _deliverCurrentReport() internal {
        vm.recordLogs();
        spokeVault.report();
        VaaBody memory report = ICoreBridge(RH_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs())[0];
        _onArbitrum();
        vm.warp(uint256(report.envelope.timestamp) + 1 minutes);
        receiver.deliver(VaaLib.encode(ICoreBridge(ARB_WORMHOLE_CORE).sign(report)));
    }

    function _fillHome(bytes32 home, Transit memory transit) internal {
        deal(ARB_USDC, address(core), IERC20(ARB_USDC).balanceOf(address(core)) + transit.amountToArrive);
        vm.prank(ARB_ACROSS_SPOKE_POOL);
        core.handleV3AcrossMessage(
            ARB_USDC, transit.amountToArrive, relayer, TransitMessage.encode(fundId, ROBINHOOD, home, transit.kind)
        );
    }

    function _ackHome(bytes32 home) internal {
        _onArbitrum();
        vm.recordLogs();
        core.acknowledgeSpokeTransit(0, home);
        VaaBody memory acknowledgement = ICoreBridge(ARB_WORMHOLE_CORE).fetchPublishedMessages(vm.getRecordedLogs())[0];
        _onRobinhood();
        vm.warp(uint256(acknowledgement.envelope.timestamp) + 1 minutes);
        spokeVault.executeOrder(VaaLib.encode(ICoreBridge(RH_WORMHOLE_CORE).sign(acknowledgement)));
    }
}
