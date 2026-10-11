// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SpokeIncomeCollectionTest} from "./SpokeIncomeCollection.t.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";

contract AgedIncomeRefundTest is SpokeIncomeCollectionTest {
    function test_evictedSaleCanBeRepublishedWithoutExecutingAnotherCollection() public {
        _earnIncome(spokeUni, positionKey, 0.1e18, 0);
        _execute(1, 0, 0);
        SpokeIncomeTypes.CollectionResult memory original = _results()[0];
        for (uint64 round = 2; round <= 10; ++round) {
            _execute(round, round - 1, 0);
        }
        uint64[] memory ids = new uint64[](1);
        ids[0] = original.resultId;
        vm.prank(stranger);
        vault.refreshIncomeResults(ids);
        assertEq(_results()[0].transitId, original.transitId);
        assertEq(_results()[0].sold[0], original.sold[0]);
    }

    function test_refundBeyondReportWindowMustKeepOriginalSale() public {
        _earnIncome(spokeUni, positionKey, 0.1e18, 0);
        _execute(1, 0, 0);
        SpokeIncomeTypes.CollectionResult memory original = _results()[0];
        for (uint64 round = 2; round <= 9; ++round) {
            _execute(round, round - 1, 0);
        }
        vm.warp(uint256(vault.hubBoundTransit(original.transitId).fillDeadline) + 1);
        spokePool.refund(vault.hubBoundTransit(original.transitId).escrow, address(usdg), original.amountSent);
        vault.recognizeRefund(original.transitId);
        _execute(10, 9, 0);
        SpokeIncomeTypes.CollectionResult[] memory results = _results();
        bool found;
        for (uint256 index; index < results.length; ++index) {
            if (results[index].resultId != original.resultId) continue;
            found = true;
            assertEq(results[index].amountSent, original.amountSent);
            assertEq(results[index].tokens[0], address(weth));
            assertEq(results[index].sold[0], original.sold[0]);
            assertTrue(results[index].transitId != original.transitId);
        }
        assertTrue(found, "original result must be reportable after resend");
        assertEq(vault.cumulativeIncome(address(usdg)), 0);
    }
}
