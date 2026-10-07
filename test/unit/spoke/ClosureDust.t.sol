// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SpokeUnwindOrdersTest} from "./SpokeUnwindOrders.t.sol";
import {SpokeIncomeCollectionTest} from "./SpokeIncomeCollection.t.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeCrossChainLib} from "../../../src/spoke/SpokeCrossChainLib.sol";
import {ClosureDust} from "../../../src/libraries/ClosureDust.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";

contract ClosurePrincipalDustTest is SpokeUnwindOrdersTest {
    function test_B02_latePrincipalDustIsExcludedAndArrivalProofPreserved() public {
        _execute(OrderCodec.CLOSE, 1, 0, false);
        bytes32 transitId = keccak256("late dust");
        uint256 received = vault.buildReport().cumulativeReceived;
        usdg.mint(address(spokePool), 20_000);
        vm.expectEmit(true, false, false, true, address(vault));
        emit SpokeCrossChainLib.ClosureDustExcluded(address(usdg), 20_000, TransferKind.Principal);
        spokePool.fill(
            address(vault),
            address(usdg),
            20_000,
            TransitMessage.encode(FUND_ID, HUB, transitId, TransferKind.Principal)
        );
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
        assertEq(vault.buildReport().cumulativeReceived, received + 20_000);
        assertEq(vault.arrivals(transitId), 20_000);
        assertEq(vault.sweepExcess(address(usdg)), 20_000);
        assertEq(usdg.balanceOf(excessRecipient), 20_000);
    }

    function test_B02_latePrincipalAtThresholdRemainsLedgered() public {
        _execute(OrderCodec.CLOSE, 1, 0, false);
        uint256 threshold = ClosureDust.threshold(address(usdg));
        _arrive(threshold, keccak256("threshold"), TransferKind.Principal);
        _arrive(20_000, keccak256("dust on retained principal"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), threshold + 20_000);
        assertEq(vault.sweepExcess(address(usdg)), 0);
    }

    function test_B02_latePrincipalBelowThresholdIsSweepable() public {
        _execute(OrderCodec.CLOSE, 1, 0, false);
        uint256 dust = ClosureDust.threshold(address(usdg)) - 1;
        _arrive(dust, keccak256("maximum dust"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
        assertEq(vault.sweepExcess(address(usdg)), dust);
    }

    function test_B02_openPrincipalAndLateIncomeRemainLedgered() public {
        _arrive(20_000, keccak256("open dust"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6 + 20_000);
        _execute(OrderCodec.CLOSE, 1, 0, false);
        _arrive(20_000, keccak256("late income"), TransferKind.Income);
        assertEq(vault.collectedIncome(address(usdg)), 20_000);
        assertEq(vault.sweepExcess(address(usdg)), 0);
    }

    function test_B02_failedCloseSendRetainsReservedPrincipalAndLateDust() public {
        spokeBridge.setFee(1001e6);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.CLOSE, 1, 0, false);
        assertGt(result.excluded, 0);
        _arrive(20_000, keccak256("dust after refused send"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6 + 20_000);
        assertEq(vault.sweepExcess(address(usdg)), 0);
        spokeBridge.setFee(0);
        result = _execute(OrderCodec.CLOSE, 2, 0, false);
        assertEq(result.amountSent, 1000e6 + 20_000);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
    }

    function test_B02_closeExcludesUnsendablePrincipalForSweep() public {
        vm.prank(manager);
        vault.sendToHub(1000e6, TransferKind.Principal, 0);
        _arrive(20_000, keccak256("alpha-dust"), TransferKind.Principal);
        spokeBridge.setFee(30_000);
        SpokeUnwindTypes.OrderResult memory result = _execute(OrderCodec.CLOSE, 1, 0, false);
        assertEq(result.excluded, 0);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
        assertEq(vault.sweepExcess(address(usdg)), 20_000);
        assertEq(usdg.balanceOf(excessRecipient), 20_000);
    }
}

contract ClosureIncomeDustTest is SpokeIncomeCollectionTest {
    function test_B02_closedIncomeDustConvertsAtZeroAndCanBeSwept() public {
        _earnIncome(spokeUni, positionKey, 0, 20_000);
        spokeBridge.setFee(30_000);
        OrderCodec.Order memory close;
        close.kind = OrderCodec.CLOSE;
        close.fundId = FUND_ID;
        close.requestId = keccak256("close");
        close.attempt = 1;
        close.fracNum = 1;
        close.fracDen = 1;
        close.closingStartedAt = uint64(block.timestamp);
        close.deadline = uint64(block.timestamp) + OrderCodec.ORDER_LIFETIME;
        bytes memory vaa =
            orderCore.craft(23, bytes32(uint256(uint160(address(core)))), 0, 200, OrderCodec.encode(close));
        vm.prank(stranger);
        vault.executeOrder{value: MESSAGE_FEE}(vaa);
        _execute(1, 1, 0);
        SpokeIncomeTypes.CollectionResult memory result = _results()[0];
        assertEq(result.transitId, bytes32(0));
        assertEq(result.amountSent, 20_000);
        assertEq(result.sold[0], 20_000);
        assertEq(result.obtained[0], 0);
        assertEq(vault.collectedIncome(address(usdg)), 0);
        assertEq(vault.sweepExcess(address(usdg)), 20_000);
    }
}
