pragma solidity 0.8.28;

import {CoreVaultIncomeTest} from "./CoreVaultIncome.t.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

contract DelayedIncomeCollectionTest is CoreVaultIncomeTest {
    function test_delayedOldSaleMustNotPayNewEntrant() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _deposit(caio, 100e6);
        _deliver(_spokeIncomeReport(0.2e18, 0.1e18));
        _fillIncome(HOME, 265e6);
        assertEq(_incomeOf(caio), 0, "entrant must not receive an earlier sale");
        assertApproxEqAbs(_incomeOf(manager), 119.25e6, 1);
        assertApproxEqAbs(_incomeOf(bruno), 119.25e6, 1);
        assertApproxEqAbs(vault.unconvertedIncome(caio, 1, address(spokeWeth)), 0.03e18, 2);
    }

    function test_recoveredCollectionMustEventuallySettle() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _fillIncome(HOME, 265e6);
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        vault.recoverUnlistedArrival(0, HOME);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertEq(vault.incomeCollection().openResults, 0);
        assertApproxEqAbs(vault.settleIncomeWithdrawal(manager), 119.25e6, 1);
        assertEq(usdc.balanceOf(protocol), 13.25e6);
        assertEq(usdc.balanceOf(address(feeVault)), 13.25e6);
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc());
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertEq(_incomeOf(manager), 0);
    }

    function test_recoveredCollectionClosesWithoutAnInFlightListing() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _fillIncome(HOME, 265e6);
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        uint256 idle = vault.idle();
        vault.recoverUnlistedArrival(0, HOME);
        assertEq(vault.idle(), idle);
        ReportCodec.Report memory report = _collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6);
        SpokeIncomeTypes.CollectionResult[] memory results =
            abi.decode(report.collectionResults, (SpokeIncomeTypes.CollectionResult[]));
        results[0].amountToArrive = 265e6;
        report.collectionResults = abi.encode(results);
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](0);
        _deliver(report);
        assertEq(vault.incomeCollection().openResults, 0);
        assertEq(vault.incomeCollection().pendingSpokes, 0);
        assertApproxEqAbs(vault.settleIncomeWithdrawal(manager), 119.25e6, 1);
        assertApproxEqAbs(_incomeOf(bruno), 119.25e6, 1);
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_twoDelayedSalesPreserveDistinctEntryIntervals() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _deposit(caio, 100e6);
        bytes32 second = keccak256("second-sale");
        _deliver(_collectionReport(0.2e18, 2, 1, second, 0.1e18, 300e6, 300e6));
        _fillIncome(second, 300e6);
        _fillIncome(HOME, 265e6);
        assertApproxEqAbs(_incomeOf(caio), 90e6, 2);
        assertApproxEqAbs(_incomeOf(manager), 209.25e6, 2);
        assertApproxEqAbs(_incomeOf(bruno), 209.25e6, 2);
        assertEq(vault.incomeCollection().openResults, 0);
    }
}
