pragma solidity 0.8.28;

import {CoreVaultIncomeTest} from "./CoreVaultIncome.t.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";

contract ClosureIncomeDustTest is CoreVaultIncomeTest {
    function test_B02_alphaSizedFundFinalizesWithExcludedIncomeDust() public {
        _deployAtMinimumFees();
        _deposit(bruno, 2e6);
        _deliver(_spokeIncomeReport(0.00001e18, 0.00001e18));
        vm.prank(manager);
        vault.closeFund();
        vm.prank(manager);
        vault.unwindAllAfterDeadline();
        _request(manager);
        ReportCodec.Report memory report = _spokeIncomeReport(0.00001e18, 0);
        SpokeIncomeTypes.CollectionResult[] memory collections = new SpokeIncomeTypes.CollectionResult[](1);
        collections[0].resultId = 1;
        collections[0].round = vault.incomeCollection().round;
        collections[0].amountSent = 25_000;
        collections[0].tokens = new address[](1);
        collections[0].tokens[0] = address(spokeWeth);
        collections[0].sold = new uint256[](1);
        collections[0].sold[0] = 0.00001e18;
        collections[0].obtained = new uint256[](1);
        report.collectionResults = abi.encode(collections);
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].requestId = vault.closureRequestId();
        results[0].attempt = 1;
        results[0].orderId = keccak256(abi.encode(OrderCodec.CLOSE, FUND_ID, results[0].requestId, uint32(1)));
        report.unwindResults = abi.encode(results);
        _deliver(report);
        assertEq(vault.incomeToken(1, address(spokeWeth)).recognized, 0);
        vault.finalizeClosure();
        assertEq(uint256(vault.fundState()), uint256(ICoreVaultLifecycle.FundState.Closed));
        assertEq(vault.closedIdle(), 2e6);
        assertEq(vault.exitClosedFund(bruno), 2e6);
    }
}
