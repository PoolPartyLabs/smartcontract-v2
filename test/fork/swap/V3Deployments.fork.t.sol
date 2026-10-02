// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IPeripheryImmutableState} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import {SwapForkBase} from "./SwapForkBase.sol";

/// @notice Fact check, on forks of both MVP chains, of every Uniswap V3 contract and pool the swap adapter (DEC-136,
///         DEC-153) relies on (ported from the swap adapter research): code present, wiring (router and quoter point at
///         the factory the adapter trusts), fee tiers enabled in the factory, and the MVP pairs' pools per fee tier,
///         derived from the factory, with their `slot0` and in-range `liquidity`.
contract V3DeploymentsForkTest is SwapForkBase {
    function test_arbitrum_contractsAndWiring() public {
        V3Chain memory c = _arbitrum();
        _checkContracts(c);
    }

    function test_robinhood_contractsAndWiring() public {
        V3Chain memory c = _robinhood();
        _checkContracts(c);
    }

    function test_arbitrum_usdcWethPoolsPerTier() public {
        V3Chain memory c = _arbitrum();
        address[4] memory expected =
            [ARB_POOL_USDC_WETH_100, ARB_POOL_USDC_WETH_500, ARB_POOL_USDC_WETH_3000, ARB_POOL_USDC_WETH_10000];
        _checkTiers(c, c.weth, c.base, expected);
        // Two-hop candidates an API route may use (research doc 07, section 6.1).
        _checkPool(c, ARB_POOL_WETH_USDT_500, c.weth, ARB_USDT, 500);
        _checkPool(c, ARB_POOL_USDC_USDT_100, c.base, ARB_USDT, 100);
    }

    function test_robinhood_wethUsdgPoolsPerTier() public {
        V3Chain memory c = _robinhood();
        address[4] memory expected =
            [RH_POOL_WETH_USDG_100, RH_POOL_WETH_USDG_500, RH_POOL_WETH_USDG_3000, RH_POOL_WETH_USDG_10000];
        _checkTiers(c, c.weth, c.base, expected);
    }

    /// @dev Stock tokens on the spoke: the direct pair with USDG (the only route without the API, DEC-153) and the
    ///      pair with WETH (an API two-hop candidate).
    function test_robinhood_stockPools() public {
        V3Chain memory c = _robinhood();
        address nvda = _otherToken(RH_POOL_NVDA_USDG_500, c.base);
        address spy = _otherToken(RH_POOL_SPY_USDG_500, c.base);
        console2.log("NVDA token", nvda);
        console2.log("SPY token", spy);
        _checkPool(c, RH_POOL_NVDA_USDG_500, nvda, c.base, 500);
        _checkPool(c, RH_POOL_NVDA_WETH_500, nvda, c.weth, 500);
        _checkPool(c, RH_POOL_SPY_USDG_500, spy, c.base, 500);
        // Every tier of the direct NVDA/USDG pair, as the adapter would see it (zero address = no pool).
        for (uint256 i; i < 4; ++i) {
            address p = c.factory.getPool(nvda, c.base, FEE_TIERS[i]);
            uint128 liq = p == address(0) ? 0 : IUniswapV3Pool(p).liquidity();
            console2.log("NVDA/USDG fee", uint256(FEE_TIERS[i]), p, uint256(liq));
        }
    }

    function _checkContracts(V3Chain memory c) internal view {
        console2.log(c.name);
        assertGt(address(c.factory).code.length, 0, "factory code");
        assertGt(address(c.router).code.length, 0, "SwapRouter02 code");
        assertGt(address(c.quoter).code.length, 0, "QuoterV2 code");
        assertGt(c.universalRouter212.code.length, 0, "Universal Router 2.1.2 code");
        console2.log("factory bytes", address(c.factory).code.length);
        console2.log("SwapRouter02 bytes", address(c.router).code.length);
        console2.log("QuoterV2 bytes", address(c.quoter).code.length);
        console2.log("UniversalRouter 2.1.2 bytes", c.universalRouter212.code.length);

        // The router and the quoter derive pool addresses from this factory (CREATE2), so a path can only reach
        // pools this factory deployed.
        assertEq(c.router.factory(), address(c.factory), "SwapRouter02.factory");
        assertEq(c.router.WETH9(), c.weth, "SwapRouter02.WETH9");
        assertEq(IPeripheryImmutableState(address(c.quoter)).factory(), address(c.factory), "QuoterV2.factory");
        assertEq(IPeripheryImmutableState(address(c.quoter)).WETH9(), c.weth, "QuoterV2.WETH9");

        // The four fee tiers of DEC-153 are enabled with the canonical tick spacings.
        int24[4] memory spacing = [int24(1), 10, 60, 200];
        for (uint256 i; i < 4; ++i) {
            assertEq(c.factory.feeAmountTickSpacing(FEE_TIERS[i]), spacing[i], "fee tier tick spacing");
        }
    }

    function _checkTiers(V3Chain memory c, address a, address b, address[4] memory expected) internal view {
        for (uint256 i; i < 4; ++i) {
            _checkPool(c, expected[i], a, b, FEE_TIERS[i]);
        }
    }

    function _checkPool(V3Chain memory c, address pool, address a, address b, uint24 fee) internal view {
        assertEq(c.factory.getPool(a, b, fee), pool, "factory.getPool");
        assertEq(c.factory.getPool(b, a, fee), pool, "factory.getPool is order-independent");
        IUniswapV3Pool p = IUniswapV3Pool(pool);
        assertEq(p.factory(), address(c.factory), "pool.factory");
        assertEq(uint256(p.fee()), uint256(fee), "pool.fee");
        (address t0, address t1) = a < b ? (a, b) : (b, a);
        assertEq(p.token0(), t0, "token0");
        assertEq(p.token1(), t1, "token1");
        (uint160 sqrtPriceX96, int24 tick,, uint16 card,,, bool unlocked) = p.slot0();
        uint128 liq = p.liquidity();
        assertTrue(unlocked, "pool unlocked");
        assertGt(sqrtPriceX96, 0, "initialized");
        assertGt(liq, 0, "in-range liquidity");
        console2.log("pool", pool, "fee", uint256(fee));
        console2.log("  tick", int256(tick));
        console2.log("  liquidity", uint256(liq), "cardinality", uint256(card));
    }
}
