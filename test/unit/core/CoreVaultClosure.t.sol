pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

contract CoreVaultClosureTest is CoreVaultFixture {
    function test_REGRESSION_multipleResultsFinalizeClosureAfterRefundedAttempt() public {
        _ready();
        (ReportCodec.Report memory report,,) = receiver.latestReport(0);
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](3);
        results[0].requestId = keccak256("older payout");
        results[0].attempt = 1;
        results[1] = abi.decode(_result(0), (SpokeUnwindTypes.OrderResult[]))[0];
        results[1].transitId = keccak256("refunded closure send");
        results[1].amountSent = 100e6;
        results[1].amountToArrive = 99e6;
        results[1].refunded = true;
        results[2] = abi.decode(_result(0), (SpokeUnwindTypes.OrderResult[]))[0];
        report.sequence = ++reportSequence;
        report.unwindResults = SpokeUnwindTypes.encodeResults(results);
        receiver.deliver(0, report);
        vault.finalizeClosure();
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Closed));
    }

    function test_REGRESSION_realOrderResultFinalizesClosure() public {
        _ready();
        (ReportCodec.Report memory report,,) = receiver.latestReport(0);
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].requestId = vault.closureRequestId();
        results[0].attempt = 1;
        results[0].orderId = keccak256(abi.encode(OrderCodec.CLOSE, FUND_ID, results[0].requestId, uint32(1)));
        report.unwindResults = abi.encode(results);
        receiver.store(0, report);
        vault.finalizeClosure();
        assertEq(uint8(vault.fundState()), uint8(ICoreVaultLifecycle.FundState.Closed));
    }

    function test_REGRESSION_evictedUncreditedClosureSendStillBlocksFinalization() public {
        _ready();
        (ReportCodec.Report memory report,,) = receiver.latestReport(0);
        SpokeUnwindTypes.OrderResult[] memory results = abi.decode(_result(0), (SpokeUnwindTypes.OrderResult[]));
        results[0].transitId = keccak256("undelivered closure send");
        results[0].amountSent = 100e6;
        results[0].amountToArrive = 99e6;
        report.unwindResults = abi.encode(results);
        report.sequence = ++reportSequence;
        receiver.deliver(0, report);
        _emptyReport(0);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_REGRESSION_manualThreePercentSaleChargesManagerExcess() public {
        _deploy(_mandate(2000), _config(0));
        _deposit(manager, 999e6);
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1000e6);
        _start();
        vm.mockCall(address(hubVault), abi.encodeWithSignature("closureCost()"), abi.encode(uint256(20e6)));
        deal(address(usdc), address(hubVault), 970e6);
        usdc.mint(address(vault), 970e6);
        vm.prank(address(hubVault));
        vault.returnToIdle(970e6);
        hubVault.setPosition(address(usdc), 0);
        vm.mockCall(
            address(hubVault),
            abi.encodeWithSignature("buildReport()"),
            abi.encode(
                ReportCodec.Report({
                    fundId: bytes32(0),
                    mandateHash: bytes32(0),
                    sequence: 0,
                    spokeChainId: 0,
                    blockNumber: 0,
                    timestamp: uint64(block.timestamp),
                    unallocated: new ReportCodec.TokenAmount[](0),
                    positions: new ReportCodec.PositionReport[](0),
                    cumulativeIncome: new ReportCodec.TokenAmount[](0),
                    collectedIncome: new ReportCodec.TokenAmount[](0),
                    operatingCash: 0,
                    cumulativeReceived: 0,
                    cumulativeSentHome: 0,
                    arrivedTransits: new ReportCodec.TransitAmount[](0),
                    inFlightToHub: new ReportCodec.HubBoundAmount[](0),
                    unwindResults: "",
                    collectionResults: ""
                })
            )
        );
        _emptyReport(0);
        vm.prank(manager);
        vault.unwindAllAfterDeadline();
        uint256 before = usdc.balanceOf(manager);
        vault.finalizeClosure();
        assertEq(usdc.balanceOf(manager) - before, 975e6);
        assertEq(vault.exitClosedFund(alice), 995e6);
    }

    function _start() internal {
        vm.prank(manager);
        vault.closeFund();
    }

    function _result(uint256 cost) internal view returns (bytes memory) {
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].requestId = vault.closureRequestId();
        results[0].attempt = 1;
        results[0].orderId = keccak256(abi.encode(OrderCodec.CLOSE, FUND_ID, results[0].requestId, uint32(1)));
        results[0].closureExcessCost = cost;
        return abi.encode(results);
    }

    function _emptyReport(uint256 cost) internal {
        ReportCodec.Report memory report;
        report.fundId = FUND_ID;
        report.mandateHash = vault.mandateHash();
        report.timestamp = uint64(block.timestamp);
        report.sequence = ++reportSequence;
        report.unwindResults = _result(cost);
        receiver.deliver(0, report);
    }

    function _ready() internal {
        _start();
        vm.warp(vault.closingDeadline() + 1);
        vm.prank(bob);
        vault.unwindAllAfterDeadline();
        _emptyReport(0);
    }

    function test_DEC149_deadlineAndManagerWindow() public {
        _start();
        assertEq(vault.closingDeadline(), block.timestamp + 72 hours);
        vm.prank(manager);
        vault.unwindAllAfterDeadline();
        vm.warp(vault.closingDeadline());
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultLifecycle.ClosingDeadlineNotReached.selector, block.timestamp));
        vault.unwindAllAfterDeadline();
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        vault.unwindAllAfterDeadline();
        (, uint256 numerator, uint256 denominator, uint16 maximum, ICoreVaultPayouts.PayoutMode mode) =
            hubVault.lastRequest();
        assertEq(numerator, 1);
        assertEq(denominator, 1);
        assertEq(maximum, 0);
        assertEq(uint8(mode), uint8(ICoreVaultPayouts.PayoutMode.Standard));
    }

    function test_DEC147_finalizeRequiresClosingAndExitRequiresClosed() public {
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.FundNotClosing.selector, ICoreVaultLifecycle.FundState.Open)
        );
        vault.finalizeClosure();
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.FundNotClosed.selector, ICoreVaultLifecycle.FundState.Open)
        );
        vault.exitClosedFund(alice);
    }

    function test_DEC163_emptyReportWithoutCloseProofCannotFinalize() public {
        _start();
        _ensureSpokeReport();
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_DEC163_finalizeRefusesStaleReport() public {
        _ready();
        vm.warp(block.timestamp + MAX_REPORT_AGE + 1);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_DEC149_closeOrdersUseCodecStandardModeAndIncreasingAttempts() public {
        _start();
        vm.startPrank(manager);
        vault.unwindAllAfterDeadline();
        vault.unwindAllAfterDeadline();
        vm.stopPrank();
        OrderCodec.Order memory first = OrderCodec.decode(hubWormhole.published(0).payload);
        OrderCodec.Order memory second = OrderCodec.decode(hubWormhole.published(1).payload);
        assertEq(first.kind, OrderCodec.CLOSE);
        assertEq(first.fracNum, 1);
        assertEq(first.fracDen, 1);
        assertEq(first.payoutMode, 1);
        assertEq(first.requestId, vault.closureRequestId());
        assertEq(first.deadline, block.timestamp + 1 hours);
        assertEq(first.attempt, 1);
        assertEq(second.attempt, 2);
        assertEq(first.requestId, second.requestId);
        assertTrue(OrderCodec.orderId(first) != OrderCodec.orderId(second));
    }

    function test_DEC163_spokeNonemptyConditionsEachBlockFinalization() public {
        _ready();
        (ReportCodec.Report memory report,,) = receiver.latestReport(0);
        report.positions = new ReportCodec.PositionReport[](1);
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        report.positions = new ReportCodec.PositionReport[](0);
        report.unallocated = new ReportCodec.TokenAmount[](1);
        report.unallocated[0] = ReportCodec.TokenAmount(address(spokeWeth), 1);
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        report.unallocated[0].amount = 0;
        report.collectedIncome = new ReportCodec.TokenAmount[](1);
        report.collectedIncome[0] = ReportCodec.TokenAmount(address(usdg), 500_000);
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        report.collectedIncome[0].amount = 0;
        report.operatingCash = 1;
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        report.operatingCash = 0;
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_DEC163_wrongOrIncompleteClosureProofBlocksFinalization() public {
        _ready();
        (ReportCodec.Report memory report,,) = receiver.latestReport(0);
        SpokeUnwindTypes.OrderResult[] memory results = abi.decode(_result(0), (SpokeUnwindTypes.OrderResult[]));
        results[0].excluded = 1;
        report.unwindResults = abi.encode(results);
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        results[0].excluded = 0;
        results[0].requestId = keccak256("wrong closure");
        report.unwindResults = abi.encode(results);
        receiver.store(0, report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_DEC163_outstandingHubToSpokeTransitBlocksFinalization() public {
        _deposit(alice, 1000e6);
        _ensureSpokeReport();
        vm.prank(manager);
        vault.sendToSpoke(0, 100e6, 0, "");
        _ready();
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_DEC167_closedReportAndHubReturnStayUnledgered() public {
        _deposit(alice, 1000e6);
        _ready();
        vault.finalizeClosure();
        uint256 idle = vault.idle();
        (ReportCodec.Report memory report,,) = receiver.latestReport(0);
        report.cumulativeIncome = new ReportCodec.TokenAmount[](1);
        report.cumulativeIncome[0] = ReportCodec.TokenAmount(address(usdg), 999e6);
        receiver.deliver(0, report);
        usdc.mint(address(vault), 123e6);
        vm.prank(address(hubVault));
        vault.returnToIdle(123e6);
        assertEq(vault.idle(), idle);
        assertEq(vault.sweepExcess(address(usdc)), 123e6);
        assertEq(vault.incomeOwed(alice), 0);
        vm.prank(manager);
        vm.expectRevert();
        vault.allocateToHubSpokeVault(1e6);
    }

    function test_DEC096_operatingCashReturnsToFrozenIdle() public {
        _deposit(alice, 5e6);
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(1e6, 10e6);
        _ready();
        vault.finalizeClosure();
        assertEq(vault.operatingCash(), 0);
        assertEq(vault.operatingCashTopUp(), 0);
    }

    function test_DEC167_finalizationEmitsFrozenClosureRecord() public {
        _deploy(_mandate(2000), _config(0));
        _deposit(alice, 1000e6);
        _ready();
        vm.expectEmit(address(vault));
        emit ICoreVaultLifecycle.FundClosed(uint64(block.timestamp), 1000e18, 1000e6, ONE, 0, 1e18, 0);
        vault.finalizeClosure();
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVaultLifecycle.FundNotClosing.selector, ICoreVaultLifecycle.FundState.Closed)
        );
        vault.finalizeClosure();
    }

    function test_DEC141_spokeCumulativeExcessJoinsHubCost() public {
        _deploy(_mandate(2000), _config(0));
        _deposit(manager, 999e6);
        _deposit(alice, 1000e6);
        _ready();
        _emptyReport(20e6);
        uint256 before = usdc.balanceOf(manager);
        vault.finalizeClosure();
        assertEq(usdc.balanceOf(manager) - before, 990e6);
        assertEq(vault.closedIdle(), 1010e6);
    }

    function test_DEC141_excessBeyondManagerPaymentIsAbsorbedWithoutBlockingClosure() public {
        _deposit(alice, 1000e6);
        _ready();
        _emptyReport(900e6);
        uint256 initial = vault.idle();
        uint256 managerBefore = usdc.balanceOf(manager);
        uint256 protocolBefore = usdc.balanceOf(protocol);
        vault.finalizeClosure();
        assertLe(usdc.balanceOf(manager) - managerBefore, 1);
        assertEq(
            vault.closedIdle() + usdc.balanceOf(manager) - managerBefore + usdc.balanceOf(protocol) - protocolBefore,
            initial
        );
        vault.exitClosedFund(alice);
    }

    function test_DEC167_managerOnlyFundClosesWithZeroFrozenSupply() public {
        _ready();
        vault.finalizeClosure();
        assertEq(shares.totalSupply(), 0);
        assertEq(vault.closedSupply(), 0);
        assertEq(vault.exitClosedFund(alice), 0);
        vault.sweepExcess(address(usdc));
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function testFuzz_DEC167_frozenExitsConserveIdle(uint64 first, uint64 second) public {
        uint256 firstAmount = bound(uint256(first), 100e6, 100_000e6);
        uint256 secondAmount = bound(uint256(second), 100e6, 100_000e6);
        _deposit(alice, firstAmount);
        _deposit(bob, secondAmount);
        _ready();
        vault.finalizeClosure();
        uint256 initialIdle = vault.closedIdle();
        uint256 protocolBefore = usdc.balanceOf(protocol);
        uint256 paid = vault.exitClosedFund(alice) + vault.exitClosedFund(bob);
        assertEq(paid + usdc.balanceOf(protocol) - protocolBefore + vault.idle(), initialIdle);
        assertLe(vault.idle(), 1);
        assertEq(shares.totalSupply(), 0);
    }

    function test_DEC163_finalizeRefusesRemainingHubUnallocated() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100e6);
        _start();
        vm.prank(manager);
        vault.unwindAllAfterDeadline();
        _emptyReport(0);
        usdc.mint(address(hubVault), 1e6);
        vm.prank(address(vault));
        hubVault.receiveFromCoreVault(1e6);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
    }

    function test_DEC056_failedHubUnwindCanRetry() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100e6);
        hubVault.moveToPosition(100e6);
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        _ready();
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode(0));
        vault.unwindAllAfterDeadline();
        _emptyReport(0);
        vault.finalizeClosure();
    }

    function test_DEC149_retryUnwindsNewValueInPreviouslyDeliveredPosition() public {
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100e6);
        hubVault.moveToPosition(100e6);
        _ready();
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100e6);
        hubVault.moveToPosition(100e6);
        vault.unwindAllAfterDeadline();
        assertEq(hubVault.positionPrincipal(), 0);
        _emptyReport(0);
        vault.finalizeClosure();
    }

    function test_DEC167_frozenSplitIgnoresLateArrivalsAndReportFailure() public {
        _deposit(alice, 1001e6);
        _deposit(bob, 2003e6);
        _ready();
        uint256 expectedSupply = shares.balanceOf(alice) + shares.balanceOf(bob);
        vault.finalizeClosure();
        assertEq(vault.closedSupply(), expectedSupply);
        uint256 frozenIdle = vault.closedIdle();
        uint256 aliceGross = Math.mulDiv(shares.balanceOf(alice), frozenIdle, expectedSupply);
        uint256 bobGross = Math.mulDiv(shares.balanceOf(bob), frozenIdle, expectedSupply);
        usdc.mint(address(vault), 123e6);
        vm.prank(address(pool));
        vault.handleV3AcrossMessage(address(0), 0, address(0), hex"01");
        assertEq(vault.idle(), frozenIdle);
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.sweepExcess(address(usdc)), 123e6);
        hubVault.setBuildReverts(true);
        uint256 aliceBefore = usdc.balanceOf(alice);
        vm.prank(ana);
        assertEq(vault.exitClosedFund(alice), aliceGross - aliceGross * 25 / 10_000);
        assertEq(usdc.balanceOf(alice) - aliceBefore, aliceGross - aliceGross * 25 / 10_000);
        assertEq(vault.exitClosedFund(bob), bobGross - bobGross * 25 / 10_000);
        assertEq(vault.closedIdle(), frozenIdle);
        assertEq(vault.closedSupply(), expectedSupply);
        assertEq(shares.totalSupply(), 0);
        assertEq(vault.idle(), frozenIdle - aliceGross - bobGross);
        vault.sweepExcess(address(usdc));
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_DEC150_openRequestBecomesFullClosedExitWithoutPayoutFee() public {
        _deposit(alice, 1000e6);
        _request(alice, 100e6, ICoreVaultPayouts.PayoutMode.Standard);
        _ready();
        vault.finalizeClosure();
        uint256 gross = vault.closedIdle();
        assertEq(vault.payoutReserve(), 0);
        assertEq(vault.exitClosedFund(alice), gross - gross * 25 / 10_000);
        assertFalse(vault.payoutRequest(alice).open);
        assertEq(shares.balanceOf(alice), 0);
    }

    function test_DEC114_managementFeeThreeYearsAndStopsAtClosing() public {
        _managementFee(5000);
    }

    function test_DEC114_managementFeeAtFivePercentSlice() public {
        _managementFee(500);
    }

    function _managementFee(uint16 slice) internal {
        Mandate memory mandate = _mandate(2000);
        mandate.managementFeeBps = 100;
        _deploy(mandate, _config(0));
        _deposit(alice, 999_999e6);
        registry.setSlice(slice);
        vm.warp(block.timestamp + 3 * 365 days);
        _start();
        assertEq(vault.managementFeeAccrued(), 30_000e6);
        vm.warp(block.timestamp + 72 hours + 1);
        vault.unwindAllAfterDeadline();
        _emptyReport(0);
        uint256 protocolBefore = usdc.balanceOf(protocol);
        vault.finalizeClosure();
        assertEq(usdc.balanceOf(protocol) - protocolBefore, uint256(30_000e6) * slice / 10_000);
        assertEq(usdc.balanceOf(vault.managerFeeVault()), uint256(30_000e6) * (10_000 - slice) / 10_000);
        assertEq(vault.managementFeeAccrued(), 0);
    }

    function test_DEC141_marketCostAboveOnePercentPaidOnceByManager() public {
        _deploy(_mandate(2000), _config(0));
        _deposit(manager, 999e6);
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1000e6);
        hubVault.moveToPosition(1000e6);
        hubVault.setUnwindLossBps(300);
        _ready();
        uint256 managerBefore = usdc.balanceOf(manager);
        vault.finalizeClosure();
        assertEq(usdc.balanceOf(manager) - managerBefore, 995e6 - 20e6);
        assertEq(vault.closedIdle(), 995e6);
        assertEq(vault.exitClosedFund(alice), 995e6);
        assertEq(usdc.balanceOf(address(vault)), 0);
    }

    function test_DEC141_fundAbsorbsCostsBelowOnePercent() public {
        _deploy(_mandate(2000), _config(0));
        _deposit(manager, 999e6);
        _deposit(alice, 1000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1000e6);
        hubVault.moveToPosition(1000e6);
        hubVault.setUnwindLossBps(50);
        _ready();
        uint256 before = usdc.balanceOf(manager);
        vault.finalizeClosure();
        assertEq(usdc.balanceOf(manager) - before, 997.5e6);
        assertEq(vault.closedIdle(), 997.5e6);
    }

    function test_DEC117_incomeInClosingPaidOnClosedExitAndLateIncomeUnledgered() public {
        _deposit(alice, 1000e6);
        _ready();
        _earnHubIncome(address(usdc), 100e6);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        _collectHubIncome();
        vault.finalizeClosure();
        uint256 income = vault.incomeOwed(alice);
        assertGt(income, 0);
        _earnHubIncome(address(usdc), 777e6);
        vault.requestIncomeWithdrawal(0);
        assertEq(hubVault.collectable(address(usdc)), 777e6);
        assertEq(vault.incomeOwed(alice), income);
        uint256 before = usdc.balanceOf(alice);
        uint256 paid = vault.exitClosedFund(alice);
        assertEq(usdc.balanceOf(alice) - before, paid + income);
        uint256 idle = vault.idle();
        vault.requestIncomeWithdrawal(0);
        assertEq(hubVault.collectable(address(usdc)), 777e6);
        assertEq(vault.idle(), idle);
    }
}
