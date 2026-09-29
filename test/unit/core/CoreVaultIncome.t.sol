// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";
import {ICoreVaultExtensions} from "../../../src/core/ICoreVaultExtensions.sol";

contract CoreVaultIncomeTest is CoreVaultFixture {
    bytes32 internal constant HUB_SOURCE = keccak256("HUB_SPOKE_VAULT");

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
    }

    function test_DEC106_workedExampleFeesBookedAtRecognition() public {
        // Collection of 1,000 USDC + 0.5 WETH at 20% performance and a 50% protocol slice.
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        hubVault.setCumulativeIncome(address(weth), 0.5e18);
        vm.expectEmit(address(vault));
        emit ICoreVaultExtensions.IncomeFeesBooked(HUB_SOURCE, address(usdc), 1000e6, 100e6, 100e6, 5000);
        vault.recognizeHubIncome();
        assertEq(vault.protocolOwed(address(usdc)), 100e6);
        assertEq(vault.managerOwed(address(usdc)), 100e6);
        assertEq(vault.protocolOwed(address(weth)), 0.05e18);
        assertEq(vault.managerOwed(address(weth)), 0.05e18);
        assertEq(vault.incomeState(address(usdc)).distributed, 800e6);
        assertEq(vault.incomeState(address(weth)).distributed, 0.4e18);
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), 800e6, 1);
        assertApproxEqAbs(vault.attributedIncome(alice, address(weth)), 0.4e18, 1);
    }

    function test_DEC109_feesPaidInKindFromCollectedBalance() public {
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        hubVault.setCumulativeIncome(address(weth), 0.5e18);
        vault.recognizeHubIncome();
        // Nothing collected yet: nothing is paid.
        vault.payOwedFees(address(usdc));
        assertEq(usdc.balanceOf(manager), 0);
        hubVault.forwardIncome(address(usdc), 1000e6);
        hubVault.forwardIncome(address(weth), 0.5e18);
        vm.expectEmit(address(vault));
        emit ICoreVault.FeesPaid(address(weth), manager, 0.05e18);
        vault.payOwedFees(address(weth));
        vault.payOwedFees(address(usdc));
        assertEq(usdc.balanceOf(manager), 100e6);
        assertEq(weth.balanceOf(protocol), 0.05e18);
        // The protocol already holds the deposit flow fee (25) plus the slice.
        assertEq(usdc.balanceOf(protocol), 25e6 + 100e6);
        assertEq(vault.collectedIncome(address(usdc)), 800e6);
        assertEq(vault.managerOwed(address(usdc)), 0);
    }

    function test_OQ02_collectionDoesNotSplitFeesAgain() public {
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        vault.recognizeHubIncome();
        vm.expectEmit(address(vault));
        emit ICoreVault.CollectedIncomeReceived(address(usdc), 1000e6, 0, 0, 5000);
        hubVault.forwardIncome(address(usdc), 1000e6);
        assertEq(vault.managerOwed(address(usdc)), 100e6);
        assertEq(vault.collectedIncome(address(usdc)), 1000e6);
    }

    function test_LC100_incomeWithdrawalPaysMinOfOwedAndCollected() public {
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        vault.recognizeHubIncome();
        hubVault.forwardIncome(address(usdc), 300e6);
        vm.prank(alice);
        assertEq(vault.withdrawIncome(address(usdc)), 300e6);
        assertEq(vault.collectedIncome(address(usdc)), 0);
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), 500e6, 1);
        // No flow fee and no Payout Fee on an Income Withdrawal (LC-143 reading).
        assertEq(usdc.balanceOf(alice), 300e6);
    }

    function test_DEC073_withdrawIncomeUnknownTokenReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnknownIncomeToken.selector, address(usdg)));
        vault.withdrawIncome(address(usdg));
    }

    function test_Q60_regressedCounterNeverRevertsAndIndexNeverDecreases() public {
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        vault.recognizeHubIncome();
        uint256 index = vault.incomeState(address(usdc)).index;
        hubVault.setCumulativeIncome(address(usdc), 400e6);
        vm.expectEmit(address(vault));
        emit IncomeAccumulator.CounterRegressed(HUB_SOURCE, address(usdc), 1000e6, 400e6);
        vault.recognizeHubIncome();
        assertEq(vault.incomeState(address(usdc)).index, index);
        hubVault.setCumulativeIncome(address(usdc), 1200e6);
        vault.recognizeHubIncome();
        assertEq(vault.incomeState(address(usdc)).distributed, 800e6 + 160e6);
    }

    function test_Q60_anomalousCounterSkipped() public {
        hubVault.setCumulativeIncome(address(usdc), uint256(type(uint128).max) + 1);
        vault.recognizeHubIncome();
        assertEq(vault.incomeState(address(usdc)).distributed, 0);
        assertEq(vault.managerOwed(address(usdc)), 0);
    }

    function test_Q60_unreadableHubSpokeVaultNeverReverts() public {
        hubVault.setBuildReverts(true);
        vm.expectEmit(address(vault));
        emit ICoreVaultExtensions.HubIncomeReadFailed();
        vault.recognizeHubIncome();
    }

    function test_DEC110_protocolSliceReadAtEveryCharge() public {
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        vault.recognizeHubIncome();
        registry.setSlice(2000);
        hubVault.setCumulativeIncome(address(usdc), 2000e6);
        vault.recognizeHubIncome();
        // First charge: 200 fee at 50%; second: 200 fee at 20%.
        assertEq(vault.protocolOwed(address(usdc)), 100e6 + 40e6);
        assertEq(vault.managerOwed(address(usdc)), 100e6 + 160e6);
    }

    function test_DEC052_registryFailureUsesDefaultSlice() public {
        registry.setReverts(true);
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        vault.recognizeHubIncome();
        assertEq(vault.protocolOwed(address(usdc)), 100e6);
    }

    function test_DEC110_decreaseManagerFeeBooksAtOldRateFirst() public {
        hubVault.setCumulativeIncome(address(usdc), 1000e6); // not yet recognized
        vm.expectEmit(address(vault));
        emit ICoreVault.ManagerFeeDecreased(2000, 1000, 0, 0);
        vm.prank(manager);
        vault.decreaseManagerFee(1000, 0);
        assertEq(vault.performanceFeeBps(), 1000);
        assertEq(vault.managerOwed(address(usdc)) + vault.protocolOwed(address(usdc)), 200e6, "old rate");
        hubVault.setCumulativeIncome(address(usdc), 2000e6);
        vault.recognizeHubIncome();
        assertEq(vault.managerOwed(address(usdc)) + vault.protocolOwed(address(usdc)), 300e6, "new rate");
    }

    function test_DEC110_managerFeeNeverIncreases() public {
        vm.startPrank(manager);
        vm.expectRevert(ICoreVault.ManagerFeeNotDecreasing.selector);
        vault.decreaseManagerFee(2500, 0);
        vm.expectRevert(ICoreVault.ManagerFeeNotDecreasing.selector);
        vault.decreaseManagerFee(2000, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotManager.selector, alice));
        vault.decreaseManagerFee(0, 0);
    }

    function test_DEC108_managementFeeMustStayZero() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ManagementFeeNotSupported.selector, 10));
        vault.decreaseManagerFee(1000, 10);
        assertEq(vault.managementFeeBps(), 0);
    }

    function test_Q60_spokeIncomeRecognizedOnReportInUsdc() public {
        ReportCodec.Report memory r = _spokeReport(0, 0);
        r.cumulativeIncome = new ReportCodec.TokenAmount[](2);
        r.cumulativeIncome[0] = ReportCodec.TokenAmount(address(usdg), 100e6);
        r.cumulativeIncome[1] = ReportCodec.TokenAmount(address(spokeWeth), 0.1e18);
        vm.expectEmit(address(vault));
        emit ICoreVaultExtensions.SpokeIncomeRecognized(0, address(spokeWeth), 0.1e18, 250e6);
        _deliver(r);
        // 350 USDC recognized: 70 of fees booked, 280 into the USDC index.
        assertEq(vault.incomeState(address(usdc)).distributed, 280e6);
        assertEq(vault.managerOwed(address(usdc)) + vault.protocolOwed(address(usdc)), 70e6);
        // A later report advances only by the delta; a regressed counter is skipped.
        r = _spokeReport(0, 0);
        r = _spokeIncome(r, address(usdg), 150e6);
        _deliver(r);
        assertEq(vault.incomeState(address(usdc)).distributed, 280e6 + 40e6);
        r = _spokeIncome(_spokeReport(0, 0), address(usdg), 120e6);
        _deliver(r);
        assertEq(vault.incomeState(address(usdc)).distributed, 320e6);
    }

    function test_Q60_unpriceableSpokeIncomeRetriedNextReport() public {
        prices.setReverts(address(spokeWeth), true);
        _deliver(_spokeIncome(_spokeReport(0, 0), address(spokeWeth), 0.1e18));
        assertEq(vault.incomeState(address(usdc)).distributed, 0);
        prices.setReverts(address(spokeWeth), false);
        _deliver(_spokeIncome(_spokeReport(0, 0), address(spokeWeth), 0.1e18));
        assertEq(vault.incomeState(address(usdc)).distributed, 200e6);
    }

    function test_Q60_spokeIncomeArrivalPaysHolders() public {
        _deliver(_spokeIncome(_spokeReport(0, 0), address(usdg), 100e6));
        bytes32 homeId = keccak256("income-home");
        _deliver(_inFlightToHub(_spokeIncome(_spokeReport(0, 0), address(usdg), 100e6), homeId, 100e6));
        pool.fill(
            address(vault), address(usdc), 100e6, TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Income)
        );
        vm.prank(alice);
        assertApproxEqAbs(vault.withdrawIncome(address(usdc)), 80e6, 1);
        vault.payOwedFees(address(usdc));
        assertEq(usdc.balanceOf(manager), 10e6);
    }

    function test_LC32_incomeWithNoSharesIsOwnerless() public {
        _deployFeeless();
        hubVault.setCumulativeIncome(address(usdc), 5e6);
        vault.recognizeHubIncome();
        assertEq(vault.ownerlessIncome(address(usdc)), 5e6);
    }

    function test_DEC080_unbackedCollectedIncomeRefused() public {
        vm.prank(address(hubVault));
        vm.expectRevert(abi.encodeWithSelector(ICoreVaultExtensions.UnbackedCredit.selector, address(usdc), 1e6, 0));
        vault.receiveCollectedIncome(address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotHubSpokeVault.selector, address(this)));
        vault.receiveCollectedIncome(address(usdc), 1e6);
    }

    function testFuzz_Q60_feesPlusIncomeNeverExceedRecognized(uint128 a, uint128 b, uint16 slice) public {
        slice = uint16(bound(slice, 0, 10_000));
        registry.setSlice(slice);
        uint256 first = bound(a, 0, 1e30);
        uint256 second = first + bound(b, 0, 1e30);
        hubVault.setCumulativeIncome(address(usdc), first);
        vault.recognizeHubIncome();
        _deposit(bob, 1000e6);
        hubVault.setCumulativeIncome(address(usdc), second);
        vault.recognizeHubIncome();
        IncomeAccumulator.TokenIncome memory t = vault.incomeState(address(usdc));
        uint256 booked = t.distributed + vault.managerOwed(address(usdc)) + vault.protocolOwed(address(usdc));
        assertEq(booked, second, "every recognized unit is in exactly one place");
        uint256 holders = vault.attributedIncome(alice, address(usdc)) + vault.attributedIncome(bob, address(usdc));
        assertLe(holders, t.distributed);
    }
}
