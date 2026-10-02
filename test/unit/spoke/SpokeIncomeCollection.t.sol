// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {SpokeIncomeTypes} from "../../../src/spoke/SpokeIncomeTypes.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockOrderCore} from "../../mocks/wormhole/MockOrderCore.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";

contract SpokeIncomeCollectionTest is SpokeVaultTestBase {
    MockOrderCore internal orderCore;
    bytes32 internal positionKey;
    uint256 internal constant MESSAGE_FEE = 0.0001 ether;

    function setUp() public {
        _setUpMocks();
        orderCore = new MockOrderCore(WH_SPOKE);
        orderCore.setMessageFee(MESSAGE_FEE);
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
        _arrive(1000e6, keccak256("arrival"), TransferKind.Principal);
        vm.prank(manager);
        (positionKey,,) = vault.openPosition(address(spokeUni), SPOKE_POOL, 0, 500e6, "");
        vm.deal(stranger, 1 ether);
    }

    function _execute(uint64 round, uint64 sequence, uint16 maxLossBps) internal {
        bytes memory vaa = _vaa(round, sequence, maxLossBps);
        vm.prank(stranger);
        vault.executeOrder{value: MESSAGE_FEE}(vaa);
    }

    function _vaa(uint64 round, uint64 sequence, uint16 maxLossBps) internal view returns (bytes memory) {
        OrderCodec.Order memory order;
        order.kind = OrderCodec.COLLECT;
        order.fundId = FUND_ID;
        order.requestId = bytes32(uint256(round));
        order.deadline = uint64(block.timestamp) + OrderCodec.ORDER_LIFETIME;
        order.maxLossBps = maxLossBps;
        return orderCore.craft(
            MandateFixture.ARBITRUM_WORMHOLE_CHAIN_ID,
            bytes32(uint256(uint160(address(core)))),
            sequence,
            OrderCodec.CONSISTENCY_INSTANT,
            OrderCodec.encode(order)
        );
    }

    function _results() internal view returns (SpokeIncomeTypes.CollectionResult[] memory) {
        return abi.decode(vault.buildReport().collectionResults, (SpokeIncomeTypes.CollectionResult[]));
    }

    function test_DEC122_collectOrderCollectsSellsBridgesAndReportsInOneTransaction() public {
        _earnIncome(spokeUni, positionKey, 0.1e18, 10e6);
        spokeSwap.setHaircutBps(100);
        spokeBridge.setFee(1e6);
        _execute(1, 0, 200);
        SpokeIncomeTypes.CollectionResult memory result = _results()[0];
        assertEq(result.round, 1);
        assertEq(result.tokens[0], address(usdg));
        assertEq(result.sold[0], 10e6);
        assertEq(result.obtained[0], 10e6);
        assertEq(result.tokens[1], address(weth));
        assertEq(result.sold[1], 0.1e18);
        assertEq(result.obtained[1], 198e6);
        assertEq(result.amountSent, 208e6);
        assertEq(vault.hubBoundTransit(result.transitId).amountToArrive, 207e6);
        assertEq(uint8(vault.hubBoundTransit(result.transitId).kind), uint8(TransferKind.Income));
        assertEq(vault.collectedIncome(address(usdg)), 0);
        assertEq(vault.collectedIncome(address(weth)), 0);
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6);
        assertEq(vault.operatingCash(), 0);
        assertEq(spokeSwap.lastMaxLossBps(), 200);
        assertEq(spokeSwap.lastRoute().length, 0);
        assertEq(IERC20(address(weth)).allowance(address(vault), address(spokeSwap)), 0);
        ReportCodec.Report memory report = ReportCodec.decode(orderCore.published(0).payload);
        assertEq(report.sequence, 1);
        assertEq(report.cumulativeIncome[1].amount, 0.1e18);
        assertEq(report.collectionResults, vault.buildReport().collectionResults);
        assertEq(orderCore.published(0).value, MESSAGE_FEE);
    }

    function test_DEC056_failedSaleWaitsForANewCollectionWithoutLosingOwnership() public {
        _earnIncome(spokeUni, positionKey, 0.1e18, 0);
        spokeSwap.setHaircutBps(100);
        _execute(1, 0, 1);
        assertEq(vault.collectedIncome(address(weth)), 0.1e18);
        assertEq(_results()[0].transitId, bytes32(0));
        _execute(2, 1, 0);
        assertEq(_results()[1].amountSent, 198e6);
        assertEq(_results()[1].sold[0], 0.1e18);
        assertEq(vault.collectedIncome(address(weth)), 0);
    }

    function test_DEC166_noMinimumRequestDustWaitsUntilTheFundCanBridge() public {
        spokeBridge.setFee(1e6);
        _earnIncome(spokeUni, positionKey, 0, 1);
        _execute(1, 0, 0);
        assertEq(_results()[0].transitId, bytes32(0));
        assertEq(vault.collectedIncome(address(usdg)), 1);
        _earnIncome(spokeUni, positionKey, 0, 2e6);
        _execute(2, 1, 0);
        SpokeIncomeTypes.CollectionResult memory result = _results()[1];
        assertEq(result.amountSent, 2e6 + 1);
        assertEq(result.sold[0], 2e6 + 1);
        assertEq(vault.hubBoundTransit(result.transitId).amountToArrive, 1e6 + 1);
    }

    function test_DEC066_refundedIncomeResendsTheSameSaleWithoutNewRecognition() public {
        _earnIncome(spokeUni, positionKey, 0.1e18, 0);
        _execute(1, 0, 0);
        SpokeIncomeTypes.CollectionResult memory first = _results()[0];
        vm.warp(uint256(vault.hubBoundTransit(first.transitId).fillDeadline) + 1);
        spokePool.refund(vault.hubBoundTransit(first.transitId).escrow, address(usdg), first.amountSent);
        vault.recognizeRefund(first.transitId);
        spokeBridge.setFee(1e6);
        _execute(1, 1, 0);
        SpokeIncomeTypes.CollectionResult memory resent = _results()[0];
        assertTrue(resent.transitId != first.transitId);
        assertEq(resent.resultId, first.resultId);
        assertEq(resent.sold[0], first.sold[0]);
        assertEq(resent.obtained[0], first.obtained[0]);
        assertEq(vault.hubBoundTransit(resent.transitId).amountToArrive, 199e6);
        assertEq(vault.cumulativeIncome(address(weth)), 0.1e18);
    }

    function test_DEC161_reportKeepsTheLastEightCollectionResults() public {
        for (uint64 round = 1; round <= 10; ++round) {
            _execute(round, round - 1, 0);
        }
        SpokeIncomeTypes.CollectionResult[] memory results = _results();
        assertEq(results.length, 8);
        assertEq(results[0].resultId, 3);
        assertEq(results[7].resultId, 10);
    }

    function test_DEC080_swapCustodyMismatchRollsBackTheWholeOrder() public {
        _earnIncome(spokeUni, positionKey, 0.1e18, 0);
        spokeSwap.setReportedExtra(1);
        bytes memory vaa = _vaa(1, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.SwapOutputNotReceived.selector, 200e6 + 1, 200e6));
        vm.prank(stranger);
        vault.executeOrder{value: MESSAGE_FEE}(vaa);
        assertEq(vault.reportSequence(), 0);
        assertEq(vault.cumulativeIncome(address(weth)), 0.1e18);
    }
}
