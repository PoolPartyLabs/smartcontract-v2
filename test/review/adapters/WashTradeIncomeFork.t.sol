// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {SpokeAForkBase, PoolTrader} from "../spoke-a/SpokeAForkBase.sol";

/// @notice (adapters review) The manager turned the fund's principal into "income" by wash-trading its Unallocated
///         Balance through a Mandate pool in which the fund is the main in-range LP, then collected and forwarded it: the
///         Core Vault charged the performance fee on what was principal (DEC-107 charges it on income, no high-water
///         mark). Real Arbitrum One contracts: Uniswap V4 PoolManager, PositionManager, StateView, Permit2 and the
///         WETH/USDC 0.05% pool (docs/INTEGRATIONS.md); real CoreVault, hub SpokeVault and UniswapV4Adapter.
///         e5c778a: manager 288.04, protocol 288.04, holders -1,461.50 on 6,000,000 of wash volume.
/// @notice FIXED by DEC-136 (founder, 2026-10-02: "swaps are not done in the fund pools"): the Spoke Vault's only swap
///         verb runs through the Mandate swap adapter, here the real `UniswapV3SwapAdapter` on Arbitrum One's V3, which
///         trades in a V3 pool and never in the fund's V4 range. The same round trips leave the fund's pool and its
///         position untouched: no income, no performance fee, nothing for the manager or the protocol; the holders
///         bear only the V3 Market Costs, paid to third-party LPs. The question of a fee net of the fund's own swap fees
///         (founder question 5 of the review) loses its channel through the vault.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/adapters/WashTradeIncomeFork.t.sol' -vv
contract WashTradeIncomeFork is SpokeAForkBase {
    uint256 internal constant ROUND_TRIPS = 3;
    uint256 internal constant LEG = 50_000e6;

    address internal protocolRecipient = makeAddr("protocol");

    struct Snapshot {
        uint256 shareAssets;
        uint256 holderIncome;
        uint256 manager;
        uint256 protocol;
    }

    /// @dev USDC value at the oracle (the fork base sets it to the pool price at the fork block).
    function _usd(uint256 wethAmount, uint256 usdcAmount) internal view returns (uint256) {
        (uint256 price1e18,) = prices.priceInUsdc(WETH);
        return wethAmount * price1e18 / 1e18 + usdcAmount;
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        address mfv = vault.managerFeeVault();
        s.shareAssets = vault.shareAssets();
        s.holderIncome = vault.incomeCollection().heldDollars; // DEC-161: the holders' income is held in USDC
        s.manager = _usd(IERC20(WETH).balanceOf(mfv), IERC20(USDC).balanceOf(mfv));
        s.protocol = _usd(IERC20(WETH).balanceOf(protocolRecipient), IERC20(USDC).balanceOf(protocolRecipient));
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = IStateView(SV).getSlot0(PoolId.wrap(poolId));
    }

    /// @dev Steps 1-3: deposit, a USDC-only range just below the price, then a market sell that makes it two-sided.
    function _setUpFundAsMainLp() internal {
        _depositAs(alice, 1_000_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(600_000e6);

        int24 hi = _floor10(tick0);
        bytes memory params = abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: hi - 200,
                tickUpper: hi,
                liquidity: 0,
                amount0Max: 0,
                amount1Max: uint128(400_000e6),
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
        vm.prank(manager);
        (positionKey,,) = hubVault.openPosition(address(adapter), poolId, 0, 400_000e6, params);

        PoolTrader market = new PoolTrader(IPoolManager(PM), key);
        deal(WETH, address(market), 1000e18);
        market.swapTo(true, hi - 100);
        vm.prank(manager);
        hubVault.collectIncome(address(adapter), positionKey);
        // DEC-161, DEC-172: an Income Withdrawal request collects, sells and converts it (WP-10).
        vault.requestIncomeWithdrawal(0);
    }

    function test_REVIEW_M02_DEC136_washTradesNoLongerReachTheFundsPool() public {
        // 1-3. Alice deposits 1,000,000 USDC; the manager allocates 600,000 and places 400,000 in a 200-tick range just
        //      below the price; the market sells WETH into it down to its middle, so the fund is the main in-range LP.
        //      That trade's fees are legitimate income and are collected and forwarded before the window starts.
        _setUpFundAsMainLp();
        int24 tickStart = _tick();
        Snapshot memory before = _snapshot();

        // 4. The same round trips: 50,000 USDC of Unallocated Balance into WETH and all of it back, with no maximum
        //    loss. They run through the swap adapter, in Uniswap V3.
        for (uint256 i; i < ROUND_TRIPS; ++i) {
            vm.prank(manager);
            uint256 wethOut = hubVault.swap(address(hubSwap), USDC, WETH, LEG, 0, "");
            vm.prank(manager);
            hubVault.swap(address(hubSwap), WETH, USDC, wethOut, 0, "");
        }

        // 5. The position earned nothing from them; collecting and forwarding pays no fee.
        vm.prank(manager);
        IAdapter.Amounts memory inc = hubVault.collectIncome(address(adapter), positionKey);
        Snapshot memory afterWash = _snapshot();
        uint256 marketCosts = before.shareAssets - afterWash.shareAssets;
        console2.log("round trips through the swap adapter", ROUND_TRIPS);
        console2.log("volume (USDC)", 2 * LEG * ROUND_TRIPS);
        console2.log("fund pool tick before", int256(tickStart));
        console2.log("fund pool tick after", int256(_tick()));
        console2.log("income collected, WETH / USDC", inc.income0, inc.income1);
        console2.log("holders' Market Costs in V3 (USDC)", marketCosts);

        assertEq(_tick(), tickStart, "DEC-136: the fund's pool never traded");
        assertEq(inc.income0, 0, "no WETH income from the fund's own swaps");
        assertEq(inc.income1, 0, "no USDC income from the fund's own swaps");
        assertEq(afterWash.manager, before.manager, "nothing for the manager");
        assertEq(afterWash.protocol, before.protocol, "nothing for the protocol");
        assertEq(afterWash.holderIncome, before.holderIncome);
        // Market Costs of 300,000 of volume in the 0.05% tier: the pool fee plus a little impact.
        assertLt(marketCosts, 2 * LEG * ROUND_TRIPS * 10 / 10_000, "under 0.1% of the volume");
    }
}
