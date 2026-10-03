pragma solidity 0.8.28;

import {SpokeUnwindOrdersTest} from "./SpokeUnwindOrders.t.sol";
import {SpokeIncomeCollectionTest} from "./SpokeIncomeCollection.t.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";

contract ClosurePrincipalDustTest is SpokeUnwindOrdersTest {
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
