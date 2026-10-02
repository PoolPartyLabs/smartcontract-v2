// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {EndToEndScenario} from "../../fork/e2e/EndToEnd.t.sol";

/// @notice Part 1.3 of the integration-price review: report 04 H-01 (a deprecated V4 adapter blocks the automatic
///         unwind and strands non-USDC principal) on the fund the project's own end-to-end scenario creates through the
///         real FundFactory (test/fork/e2e/EndToEnd.t.sol phases 1 to 7: hub V4 + Aave, a Robinhood V4 position, the
///         report delivered, income collected, Bruno's deposit), then the factory's guardian deprecates the V4 adapters.
/// @notice Ported to fix/pp-sc-fix-independent-review (review H-07, security sweep S-10): FIXED. A deprecated V4
///         adapter still runs a swap whose output is the vault's base token, so the automatic unwind completes and no
///         WETH is stranded on either chain; swaps out of the base token stay blocked. e5c778a: Bruno asked 9,947.05 and
///         was paid 8,946.71; 0.551 WETH (16.5% of Share Assets) stranded on the hub, 0.5366 WETH on Robinhood. Since
///         DEC-136 the manager's sale of closed WETH runs through the fund's Uniswap V3 swap adapter; the guardian
///         deprecates it too, and the same exit rule holds there (DEC-056).
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
///      ARBITRUM_FORK_BLOCK=<head - 300> ROBINHOOD_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/integration-price/DeprecatedAdapterFork.t.sol' -vv
contract DeprecatedAdapterFork is EndToEndScenario {
    function _fundAfterPhase7() internal {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _phase3HubAllocationAndIncome();
        _phase4SendToRobinhood();
        _phase5FillPositionAndReport();
        _phase6DeliverReport();
        _phase7IncomeAndBrunoDeposit();
    }

    function _wethPrice() internal view returns (uint256 price) {
        (price,) = IPriceSource(hubDeployment.priceSource).priceInUsdc(ARB_WETH);
    }

    function _sawUnwindFailed(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(core)
                    && logs[i].topics[0] == ICoreVaultPayouts.UnwindForPayoutFailed.selector
            ) {
                return true;
            }
        }
        return false;
    }

    function test_REVIEW_H07_deprecatedHubV4StillServesTheUnwindAndTheExitSwap() public {
        _fundAfterPhase7();
        _phase8AnaStandardPayout(); // as the scenario does before phase 9, so Bruno's request exceeds Free Idle
        _onArbitrum();
        vm.prank(guardian);
        IAdapterGuard(hubUniswap).deprecate();
        assertTrue(IAdapterGuard(hubUniswap).deprecated());

        // 1. Bruno's Instant claim above Free Idle, with NO hint (the harder case): the V4 step's WETH is swapped
        //    into USDC through the deprecated adapter and the claim completes.
        InstantPlan memory plan = _planInstant();
        vm.recordLogs();
        vm.prank(bruno);
        ICoreVault.PayoutReceipt memory r = core.requestPayout(plan.request, ICoreVaultPayouts.PayoutMode.Instant, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool failed = _sawUnwindFailed(logs);
        (r,,,) = _settleSpokeUnwind(bruno, logs);
        console2.log("===== hub V4 adapter deprecated");
        console2.log("Bruno asked / paid gross / outstanding", plan.request, r.usdcGross, r.usdcOutstanding);
        console2.log("unwind proceeds", r.unwindProceeds);
        assertFalse(failed, "the unwind ran");
        assertGt(r.unwindProceeds, 0);
        assertEq(r.excludedPositions, 0, "deprecation excludes no position");
        _assertPayoutOutcome(plan, r);

        // 2. Exits still work: the manager closes the V4 position; its WETH lands in Unallocated Balance.
        vm.prank(manager);
        hubSpoke.closePosition(hubUniswap, hubUniswapPosition, _closeParams());
        uint256 weth = hubSpoke.unallocatedBalance(ARB_WETH);
        console2.log("WETH in hub Unallocated Balance after the close", weth);
        console2.log("  worth at the oracle (USDC)", Math.mulDiv(weth, _wethPrice(), 1e18));
        assertGt(weth, 0);

        // 3. That WETH becomes USDC through the deprecated swap adapter (an exit into the base token); the way back
        //    stays gated, so no new exposure can be taken through it.
        vm.prank(guardian);
        IAdapterGuard(hubSwapAdapter).deprecate();
        uint256 minOut = Math.mulDiv(weth, _wethPrice(), 1e18) * 95 / 100;
        vm.prank(manager);
        uint256 usdcOut = hubSpoke.swap(hubSwapAdapter, ARB_WETH, ARB_USDC, weth, 500, "");
        console2.log("USDC from the WETH through the deprecated swap adapter", usdcOut);
        assertGe(usdcOut, minOut, "within 5% of the oracle");
        assertEq(hubSpoke.unallocatedBalance(ARB_WETH), 0, "nothing stranded");
        vm.prank(manager);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hubSpoke.swap(hubSwapAdapter, ARB_USDC, ARB_WETH, 1000e6, 0, "");
    }

    function test_REVIEW_H07_deprecatedSpokeV4StillSwapsWethIntoUsdg() public {
        _fundAfterPhase7();
        _onRobinhood();
        vm.startPrank(guardian);
        IAdapterGuard(spokeUniswap).deprecate();
        IAdapterGuard(spokeSwapAdapter).deprecate();
        vm.stopPrank();

        // Exits work: collect, then close; WETH principal lands in Unallocated, WETH income in the collected bucket.
        vm.startPrank(manager);
        spokeVault.collectIncome(spokeUniswap, spokeUniswapPosition);
        spokeVault.closePosition(spokeUniswap, spokeUniswapPosition, _closeParams());
        vm.stopPrank();
        uint256 wethPrincipal = spokeVault.unallocatedBalance(RH_WETH);
        uint256 wethIncome = spokeVault.collectedIncome(RH_WETH);
        console2.log("===== Robinhood V4 adapter deprecated");
        console2.log("WETH principal / WETH income after the close", wethPrincipal, wethIncome);
        assertGt(wethPrincipal, 0);

        // The principal becomes USDG through the deprecated swap adapter and can go home; the way back stays gated.
        // The WETH income waits in the collected bucket for a collection order, whose sale into USDG is the same exit
        // through the same adapter (DEC-056, DEC-122, DEC-124; WP-10: the manager has no income swap of its own).
        vm.prank(manager);
        uint256 usdg = spokeVault.swap(spokeSwapAdapter, RH_WETH, RH_USDG, wethPrincipal, 0, "");
        console2.log("USDG from the WETH principal", usdg);
        assertGt(usdg, 0);
        assertEq(spokeVault.unallocatedBalance(RH_WETH), 0, "no WETH principal stranded");
        assertEq(spokeVault.collectedIncome(RH_WETH), wethIncome, "the WETH income waits for a collection");
        vm.prank(manager);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        spokeVault.swap(spokeSwapAdapter, RH_USDG, RH_WETH, 100e6, 0, "");
        assertGt(IERC20(RH_USDG).balanceOf(address(spokeVault)), usdg, "the USDG is held by the vault");
    }
}
