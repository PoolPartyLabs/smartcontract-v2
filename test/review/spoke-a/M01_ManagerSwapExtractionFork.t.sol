// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {SpokeAForkBase, PoolTrader} from "./SpokeAForkBase.sol";

/// @notice [M-01] (spoke-a) What the Mandate does not bound: a manager verb takes any minimum, and nothing in the Spoke
///         Vault compares an execution price with an oracle. A manager and an accomplice (or a compromised manager key,
///         DEC-003) moved the fund's Unallocated Balance to the accomplice through one swap in a Mandate pool the
///         accomplice had pushed: the real Arbitrum V4 WETH/USDC 0.05% pool, real PoolManager, real hub SpokeVault and
///         adapter. e5c778a: 0.369 WETH (989.72 USDC) for 100,000 USDC, accomplice +98,911.
/// @notice Since DEC-136 (founder, 2026-10-02: "swaps are not done in the fund pools") the manager's swap runs through
///         the Mandate swap adapter, which chooses the best direct Uniswap V3 tier itself (DEC-153): pushing the
///         fund's V4 pool no longer sets the fund's price. The attack moves to the V3 tiers of the pair, every one of
///         which the accomplice would have to push (risk accepted by DEC-129 and DEC-142: the maximum loss is optional
///         and measured against the chosen pool's mid; register S-8 stays open for the founder).
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 100>
///      forge test --match-path 'test/review/spoke-a/M01_ManagerSwapExtractionFork.t.sol' -vv
contract M01_ManagerSwapExtractionFork is SpokeAForkBase {
    /// @dev The same push of the fund's V4 pool; the manager's swap with no maximum loss pays the V3 market price.
    function test_REVIEW_SEC9_DEC136_fork_pushingTheFundsPoolNoLongerSetsTheSwapPrice() public {
        _depositAs(alice, 200_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100_000e6);
        uint256 price1e18 = _poolPrice();
        uint256 assetsBefore = vault.shareAssets();

        // The accomplice: 1,000 WETH and 1,000,000 USDC of flash capital.
        PoolTrader accomplice = new PoolTrader(IPoolManager(PM), key);
        deal(WETH, address(accomplice), 1000e18);
        deal(USDC, address(accomplice), 1_000_000e6);

        // 1. Push the WETH price up 100x (46,050 ticks) and leave a WETH-only range just above it.
        int24 up = _floor10(tick0 + 46_050);
        accomplice.swapTo(false, up);
        accomplice.modify(up + 10, up + 1010, 2e16);
        // 2. The manager swaps 100,000 USDC of Unallocated Balance with no maximum loss, through the swap adapter.
        vm.prank(manager);
        uint256 wethOut = hubVault.swap(address(hubSwap), USDC, WETH, 100_000e6, 0, "");
        // 3. The accomplice takes its range back and swaps the pool back to where it was.
        accomplice.modify(up + 10, up + 1010, -2e16);
        accomplice.swapTo(true, tick0);

        uint256 assetsAfter = vault.shareAssets();
        console2.log("WETH the fund got for 100,000 USDC", wethOut);
        console2.log("worth at the oracle (USDC)", wethOut * price1e18 / 1e18);
        console2.log("share assets before", assetsBefore);
        console2.log("share assets after", assetsAfter);

        assertGt(wethOut * price1e18 / 1e18, 99_000e6, "100,000 USDC bought over 99,000 USDC of WETH");
        assertLt(assetsBefore - assetsAfter, 1000e6, "the fund lost under 1% (V3 Market Costs)");
    }
}
