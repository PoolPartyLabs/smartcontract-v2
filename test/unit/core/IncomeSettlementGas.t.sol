// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {DollarIncomeIndex} from "../../../src/libraries/DollarIncomeIndex.sol";

contract IncomeSettlementGasTest is Test {
    using DollarIncomeIndex for DollarIncomeIndex.State;

    DollarIncomeIndex.State internal index;
    address internal constant HOLDER = address(1);
    uint256 internal constant SHARES = 200;

    function settleExternal(uint256 budget) external returns (bool) {
        DollarIncomeIndex.Work memory work = DollarIncomeIndex.Work(budget);
        return index.settle(HOLDER, SHARES, work);
    }

    function _prepare(bool finalized, uint256 amount) internal {
        for (uint256 token; token < 15; ++token) {
            index.registerToken(address(uint160(1000 + token)));
        }
        index.wait(HOLDER, 100, 0);
        index.activate(100);
        assertTrue(index.settle(HOLDER, 100));
        for (uint256 token; token < 15; ++token) {
            assertTrue(index.recognize(index.tokens[token], 17, 100));
        }
        index.wait(HOLDER, 100, 150);
        index.activate(200);
        index.activate(300);
        uint256[] memory sold = new uint256[](15);
        for (uint256 collection; collection < 64; ++collection) {
            for (uint256 token; token < 15; ++token) {
                assertTrue(index.recognize(index.tokens[token], amount + collection, SHARES));
                sold[token] = amount + collection;
            }
            uint64 frozen = index.freeze(sold);
            if (finalized) index.finalizeFrozen(frozen, sold);
        }
    }

    function _boundedSettlement(uint256 budget) internal returns (uint256 calls) {
        bool complete;
        uint256 peak;
        while (!complete) {
            bytes32 beforeProgress = _progress();
            vm.cool(address(this));
            uint256 beforeGas = gasleft();
            (bool success, bytes memory result) =
                address(this).call{gas: 14_000_000}(abi.encodeCall(this.settleExternal, (budget)));
            uint256 used = beforeGas - gasleft();
            assertTrue(success, "gas-capped settlement must succeed");
            assertLt(used, 15_000_000);
            if (used > peak) peak = used;
            complete = abi.decode(result, (bool));
            if (!complete) assertNotEq(_progress(), beforeProgress, "each incomplete call checkpoints work");
            assertLt(++calls, 500);
        }
        emit log_named_uint("settlement calls", calls);
        emit log_named_uint("peak cold settlement gas", peak);
    }

    function _progress() internal view returns (bytes32 progress) {
        DollarIncomeIndex.Holder storage holder = index.holders[HOLDER];
        DollarIncomeIndex.Holder storage activation = index.activating[HOLDER];
        uint256 cursors = uint256(holder.captured) * 15 + holder.claims[holder.captured + 1].length
            + uint256(holder.paid) * 15 + holder.paymentCursor + uint256(activation.captured) * 15
            + activation.claims[activation.captured + 1].length + uint256(activation.paid) * 15
            + activation.paymentCursor + uint256(index.activationMerged[HOLDER]) * 15
            + index.activationMergeToken[HOLDER];
        progress = keccak256(abi.encode(cursors, holder.waitingShares, holder.dollars, activation.dollars));
        for (uint256 token; token < 15; ++token) {
            progress = keccak256(
                abi.encode(progress, holder.adjustment[index.tokens[token]], activation.adjustment[index.tokens[token]])
            );
        }
    }

    function test_maximumTokensCollectionsAndWaitingLotColdGas() public {
        _prepare(true, 200e6);
        assertGt(_boundedSettlement(DollarIncomeIndex.MAX_SETTLE_STEPS), 1);
        assertEq(index.holders[HOLDER].waitingShares, 0);
        assertEq(index.holders[HOLDER].captured, 64);
        uint256 paid = index.take(HOLDER, type(uint256).max);
        assertLe(paid, index.dollarsObtained);
        assertLt(index.dollarsObtained - paid, 4000);
        index.onBurn(HOLDER, SHARES);
    }

    function testFuzz_splitSettlementExactlyMatchesOneCall(uint96 seed, bool finalized) public {
        _prepare(finalized, bound(seed, 200e6, 1e18));
        uint256 snapshot = vm.snapshotState();
        assertTrue(this.settleExternal(type(uint256).max));
        uint256 expected = index.owedDollars(HOLDER, SHARES);
        int192 expectedAdjustment = index.holders[HOLDER].adjustment[index.tokens[0]].amount;
        assertTrue(vm.revertToState(snapshot));
        _boundedSettlement(DollarIncomeIndex.MAX_SETTLE_STEPS);
        assertEq(index.owedDollars(HOLDER, SHARES), expected);
        assertEq(index.holders[HOLDER].adjustment[index.tokens[0]].amount, expectedAdjustment);
        if (!finalized) {
            uint256[] memory obtained = new uint256[](15);
            for (uint64 collection = 1; collection <= 64; ++collection) {
                for (uint256 token; token < 15; ++token) {
                    obtained[token] = index.frozen[collection].sold[token];
                }
                index.finalizeFrozen(collection, obtained);
            }
            _boundedSettlement(DollarIncomeIndex.MAX_SETTLE_STEPS);
        }
        assertLe(index.take(HOLDER, type(uint256).max), index.dollarsObtained);
    }

    function test_newCollectionDuringPendingClaimMergeMatchesEagerSettlement() public {
        _prepare(false, 200e6);
        uint256 snapshot = vm.snapshotState();
        assertTrue(this.settleExternal(type(uint256).max));
        _appendAndFinalize();
        assertTrue(this.settleExternal(type(uint256).max));
        uint256 expected = index.take(HOLDER, type(uint256).max);
        assertTrue(vm.revertToState(snapshot));
        while (!index.activationMerging[HOLDER]) {
            assertFalse(this.settleExternal(DollarIncomeIndex.MAX_SETTLE_STEPS));
        }
        _appendAndFinalize();
        _boundedSettlement(DollarIncomeIndex.MAX_SETTLE_STEPS);
        assertEq(index.take(HOLDER, type(uint256).max), expected);
    }

    function _appendAndFinalize() internal {
        uint256[] memory sold = new uint256[](15);
        for (uint256 token; token < 15; ++token) {
            assertTrue(index.recognize(index.tokens[token], 300e6, SHARES));
            sold[token] = index.token[index.tokens[token]].recognized;
        }
        index.freeze(sold);
        for (uint64 collection = 1; collection <= index.frozenCount; ++collection) {
            for (uint256 token; token < 15; ++token) {
                sold[token] = index.frozen[collection].sold[token] * (collection % 3 + 1);
            }
            index.finalizeFrozen(collection, sold);
        }
    }
}
