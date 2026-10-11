// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";
import {EndToEndScenario} from "../e2e/EndToEnd.t.sol";

contract FundClosureForkTest is EndToEndScenario {
    function test_DEC163_forkFullHubClosureWithRealAaveV4AndUsdcExits() public {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        vm.prank(manager);
        core.closeFund();
        assertEq(uint8(core.fundState()), uint8(ICoreVaultLifecycle.FundState.Closing));
        _advance(72 hours + 1);
        _onArbitrum();
        _refreshEthUsdFeed();
        vm.prank(bruno);
        core.unwindAllAfterDeadline();
        ReportCodec.Report memory hub = hubSpoke.buildReport();
        assertEq(hub.positions.length, 0);
        for (uint256 index; index < hub.unallocated.length; ++index) {
            assertEq(hub.unallocated[index].amount, 0);
        }
        core.requestIncomeWithdrawal(0);
        ReportCodec.Report memory emptySpoke;
        emptySpoke.timestamp = uint64(block.timestamp);
        assertEq(emptySpoke.positions.length, 0);
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].requestId = core.closureRequestId();
        results[0].attempt = 1;
        results[0].orderId = keccak256(abi.encode(OrderCodec.CLOSE, fundId, results[0].requestId, uint32(1)));
        emptySpoke.unwindResults = abi.encode(results);
        vm.mockCall(
            address(receiver),
            abi.encodeCall(IValueReportReceiver.latestReport, (0)),
            abi.encode(emptySpoke, uint64(1), uint64(block.timestamp))
        );
        vm.mockCall(address(receiver), abi.encodeCall(IValueReportReceiver.isReportFresh, (0)), abi.encode(true));
        core.finalizeClosure();
        assertEq(uint8(core.fundState()), uint8(ICoreVaultLifecycle.FundState.Closed));
        assertEq(IERC20(core.shareToken()).balanceOf(manager), 0);
        uint256 frozenIdle = core.closedIdle();
        uint256 frozenSupply = core.closedSupply();
        uint256 gross = Math.mulDiv(IERC20(core.shareToken()).balanceOf(ana), frozenIdle, frozenSupply);
        uint256 income = core.incomeOwed(ana);
        uint256 before = IERC20(ARB_USDC).balanceOf(ana);
        _advance(7 days);
        _onArbitrum();
        vm.prank(bruno);
        uint256 paid = core.exitClosedFund(ana);
        assertEq(paid, gross - gross * core.flowFeeBps() / 10_000);
        assertEq(IERC20(ARB_USDC).balanceOf(ana) - before, paid + income);
        assertEq(IERC20(core.shareToken()).totalSupply(), 0);
        core.sweepExcess(ARB_USDC);
        assertEq(core.closedIdle(), frozenIdle);
        assertEq(core.closedSupply(), frozenSupply);
        assertEq(core.idle(), 0);
    }
}
