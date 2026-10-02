// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransferKind, Transit} from "../../../src/interfaces/FundTypes.sol";
import {MockOrderCore} from "../../mocks/wormhole/MockOrderCore.sol";

contract SpokeUnwindOrdersTest is SpokeVaultTestBase {
    MockOrderCore internal orderCore;
    bytes32 internal constant REQUEST = keccak256("spoke payout");
    bytes32 internal position;

    function setUp() public {
        _setUpMocks();
        orderCore = new MockOrderCore(WH_SPOKE);
        vm.chainId(SPOKE);
        vault = new SpokeVault(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(orderCore),
            address(escrowImplementation),
            excessRecipient
        );
        spokeUni.setVault(address(vault));
        spokeBridge.setVault(address(vault));
        _disableOperatingCash();
        _arrive(1000e6, keccak256("initial"), TransferKind.Principal);
    }

    function _position() internal {
        vm.startPrank(manager);
        uint256 obtained = vault.swap(address(spokeSwap), address(usdg), address(weth), 400e6, 0, "");
        (position,,) = vault.openPosition(address(spokeUni), SPOKE_POOL, obtained, 400e6, "");
        vm.stopPrank();
    }

    function _execute(uint8 kind, uint32 attempt, uint16 maximum, bool instant)
        internal
        returns (SpokeUnwindTypes.OrderResult memory result)
    {
        OrderCodec.Order memory order;
        order.kind = kind;
        order.fundId = FUND_ID;
        order.requestId = REQUEST;
        order.attempt = attempt;
        order.deadline = uint64(block.timestamp) + 1 hours;
        order.fracNum = 1;
        order.fracDen = 2;
        order.maxLossBps = maximum;
        order.payoutMode = instant ? 0 : 1;
        bytes memory vaa =
            orderCore.craft(23, bytes32(uint256(uint160(address(core)))), attempt, 200, OrderCodec.encode(order));
        vault.executeOrder(vaa);
        ReportCodec.Report memory report =
            ReportCodec.decode(orderCore.published(orderCore.publishedCount() - 1).payload);
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        result = results[results.length - 1];
    }

    function test_DEC137_spokeBaseUsesFractionAndAdapterTerms() public {
        spokeBridge.setFee(1e6);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.UNWIND, 1, 0, true);
        assertEq(result.amountSent, 500e6);
        assertEq(result.amountToArrive, 499e6);
        assertEq(result.leaverCost, 1e6);
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6);
        Transit memory transit = vault.hubBoundTransit(result.transitId);
        assertEq(transit.amountSent, result.amountSent);
        assertEq(transit.amountToArrive, result.amountToArrive);
        assertEq(usdg.allowance(address(vault), address(spokePool)), 0);
    }

    function test_DEC118_instantPaysEverySaleLossAndBridgeFee() public {
        _position();
        spokeSwap.setHaircutBps(200);
        spokeBridge.setFee(1e6);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.UNWIND, 1, 0, true);
        assertEq(result.spotOut, 200e6);
        assertEq(result.marketCost, 4e6);
        assertEq(result.leaverCost, 5e6);
        assertEq(result.amountSent, 496e6);
        assertEq(result.delivered, 1);
    }

    function test_DEC141_standardAbsorbsOnePercentAndBridgeFee() public {
        _position();
        spokeSwap.setHaircutBps(200);
        spokeBridge.setFee(1e6);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.UNWIND, 1, 0, false);
        assertEq(result.marketCost, 4e6);
        assertEq(result.leaverCost, 2e6);
    }

    function test_DEC148_atomicExclusionAndRetryOnlyUndeliveredPosition() public {
        _position();
        spokeSwap.setHaircutBps(200);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 100, true);
        assertEq(first.excluded, 1);
        assertEq(first.amountSent, 100e6);
        assertFalse(vault.unwindDelivered(REQUEST, address(spokeUni), position));
        assertEq(vault.unallocatedBalance(address(weth)), 0);
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 2, 300, true);
        assertEq(retry.amountSent, 396e6);
        assertEq(retry.excluded, 0);
        assertTrue(vault.unwindDelivered(REQUEST, address(spokeUni), position));
        assertEq(vault.unallocatedBalance(address(usdg)), 100e6);
        SpokeUnwindTypes.OrderResult memory again = _execute(OrderCodec.UNWIND, 3, 0, true);
        assertEq(again.transitId, retry.transitId);
        assertEq(again.amountSent, retry.amountSent);
        assertEq(again.delivered, 0);
    }

    function test_DEC156_bridgeRefusalRetainsProceedsAndRetryDoesNotResell() public {
        _position();
        spokeBridge.setFee(10e6);
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 100, true);
        assertEq(first.transitId, bytes32(0));
        assertEq(first.excluded, 1);
        assertTrue(vault.unwindDelivered(REQUEST, address(spokeUni), position));
        uint256 swaps = spokeSwap.calls();
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 2, 300, true);
        assertEq(retry.amountSent, 500e6);
        assertEq(retry.amountToArrive, 490e6);
        assertEq(spokeSwap.calls(), swaps);
    }

    function test_DEC156_unsentProceedsCannotBeSpentByManager() public {
        spokeBridge.setFee(10e6);
        _execute(OrderCodec.UNWIND, 1, 100, true);
        vm.expectRevert(SpokeUnwindTypes.UnwindProceedsReserved.selector);
        vm.prank(manager);
        vault.sendToHub(600e6, TransferKind.Principal, 0);
        vm.expectRevert(SpokeUnwindTypes.UnwindProceedsReserved.selector);
        vm.prank(manager);
        vault.swap(address(spokeSwap), address(usdg), address(weth), 10e6, 0, "");
    }

    function test_DEC151_refundRetrySendsRefundWithoutAnotherFraction() public {
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 0, true);
        Transit memory transit = vault.hubBoundTransit(first.transitId);
        vm.warp(uint256(transit.fillDeadline) + 1);
        usdg.mint(transit.escrow, transit.amountSent);
        vault.recognizeRefund(first.transitId);
        vault.report();
        ReportCodec.Report memory report =
            ReportCodec.decode(orderCore.published(orderCore.publishedCount() - 1).payload);
        SpokeUnwindTypes.OrderResult[] memory records =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertTrue(records[0].refunded);
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 2, 0, true);
        assertEq(retry.amountSent, first.amountSent);
        assertTrue(retry.transitId != first.transitId);
    }

    function test_DEC149_closeEverythingAndBlockManagerEntries() public {
        _position();
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.CLOSE, 1, 1, true);
        assertEq(result.amountSent, 1000e6);
        assertEq(vault.positions().length, 0);
        assertTrue(vault.spokeClosed());
        vm.startPrank(manager);
        vm.expectRevert(SpokeUnwindTypes.SpokeClosed.selector);
        vault.openPosition(address(spokeUni), SPOKE_POOL, 0, 1, "");
        vm.expectRevert(SpokeUnwindTypes.SpokeClosed.selector);
        vault.increasePosition(address(spokeUni), position, 0, 1, "");
        vm.expectRevert(SpokeUnwindTypes.SpokeClosed.selector);
        vault.swap(address(spokeSwap), address(usdg), address(weth), 1, 0, "");
        vm.stopPrank();
        _arrive(100e6, keccak256("late"), TransferKind.Principal);
        vm.prank(stranger);
        vault.sendToHub(100e6, TransferKind.Principal, 0);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
    }

    function test_DEC131_sendStepOnlySelf() public {
        vm.expectRevert(abi.encodeWithSelector(SpokeUnwindTypes.UnwindStepNotSelf.selector, address(this)));
        vault.unwindSend(1);
    }

    function test_DEC148_exitFailureLeavesPositionIntact() public {
        _position();
        spokeUni.setRevertOnExit(true);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.UNWIND, 1, 0, true);
        assertEq(result.excluded, 1);
        assertEq(result.amountSent, 100e6);
        assertEq(vault.positions().length, 1);
        assertFalse(vault.unwindDelivered(REQUEST, address(spokeUni), position));
    }

    function test_DEC151_bridgeCallFailureKeepsSalesAndRetryDoesNotResell() public {
        _position();
        spokeBridge.setBuiltTargetOverride(address(0xBEEF));
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 0, true);
        assertEq(first.excluded, 1);
        assertEq(first.transitId, bytes32(0));
        uint256 calls = spokeSwap.calls();
        spokeBridge.setBuiltTargetOverride(address(0));
        SpokeUnwindTypes.OrderResult memory retry = _execute(OrderCodec.UNWIND, 2, 0, true);
        assertEq(retry.amountSent, 500e6);
        assertEq(spokeSwap.calls(), calls);
    }

    function test_DEC068_reportAutomaticallyRecognizesRefundAndCarriesProof() public {
        SpokeUnwindTypes.OrderResult memory first = _execute(OrderCodec.UNWIND, 1, 0, true);
        Transit memory transit = vault.hubBoundTransit(first.transitId);
        vm.warp(uint256(transit.fillDeadline) + 1);
        usdg.mint(transit.escrow, transit.amountSent);
        vault.report();
        ReportCodec.Report memory report =
            ReportCodec.decode(orderCore.published(orderCore.publishedCount() - 1).payload);
        SpokeUnwindTypes.OrderResult[] memory records =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertTrue(records[0].refunded);
        assertEq(report.inFlightToHub.length, 0);
    }

    function test_DEC149_closeIncludesBaseOperatingCash() public {
        vm.prank(manager);
        vault.setOperatingCashParameters(10e6, 10e6);
        _arrive(100e6, keccak256("cash"), TransferKind.Principal);
        assertEq(vault.operatingCash(), 10e6);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.CLOSE, 1, 0, false);
        assertEq(result.amountSent, 1100e6);
        assertEq(vault.operatingCash(), 0);
    }

    function test_DEC120_reportFeeFailureRollsBackUnwind() public {
        orderCore.setMessageFee(1);
        uint256 beforeBalance = vault.unallocatedBalance(address(usdg));
        OrderCodec.Order memory order;
        order.kind = OrderCodec.UNWIND;
        order.fundId = FUND_ID;
        order.requestId = REQUEST;
        order.attempt = 1;
        order.deadline = uint64(block.timestamp) + 1 hours;
        order.fracNum = 1;
        order.fracDen = 2;
        bytes memory vaa =
            orderCore.craft(23, bytes32(uint256(uint160(address(core)))), 1, 200, OrderCodec.encode(order));
        vm.expectRevert(abi.encodeWithSelector(MockOrderCore.WrongFee.selector, 0, 1));
        vault.executeOrder(vaa);
        assertEq(vault.unallocatedBalance(address(usdg)), beforeBalance);
        assertEq(vault.reportSequence(), 0);
    }

    function test_DEC120_reportWindowBoundedAtSixteen() public {
        for (uint32 attempt = 1; attempt <= 18; ++attempt) {
            _execute(OrderCodec.UNWIND, attempt, 0, true);
        }
        SpokeUnwindTypes.OrderResult[] memory records =
            abi.decode(vault.buildReport().unwindResults, (SpokeUnwindTypes.OrderResult[]));
        assertEq(records.length, 16);
        assertEq(records[0].attempt, 3);
        assertEq(records[15].attempt, 18);
    }
}
