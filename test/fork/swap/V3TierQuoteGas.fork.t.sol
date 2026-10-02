// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {SwapForkBase, ISwapRouter02Full} from "./SwapForkBase.sol";
import {ForkToken, DustMinter} from "../../mocks/swap/V3ForkHelpers.sol";

/// @notice DEC-153 on a fork: the cost of choosing the best V3 fee tier on-chain (factory lookup plus one
///         `QuoterV2.quoteExactInputSingle` per existing tier) against the cost of reading `slot0` and `liquidity`
///         only, the tier each method picks, and the gas of the swap itself through SwapRouter02.
/// @dev Each test is one transaction, so the first access to every contract and pool is cold, as in production.
///      `gasUsed` is measured with `gasleft()` around each external call and includes the call overhead.
contract V3TierQuoteGasForkTest is SwapForkBase {
    uint256 internal constant QUOTE_GAS_CAP = 1_000_000;

    struct TierQuote {
        uint24 fee;
        address pool;
        uint128 liquidity;
        bool ok;
        uint256 amountOut;
        uint32 ticksCrossed;
        uint256 quoterEstimate;
        uint256 gasUsed;
    }

    // -----------------------------------------------------------------------------------------------------------
    // Arbitrum: WETH -> USDC (Hub Chain, the unwind sale into the base token)
    // -----------------------------------------------------------------------------------------------------------

    function test_arbitrum_wethToUsdc_1() public {
        V3Chain memory c = _arbitrum();
        _selectAndSwap(c, c.weth, c.base, 1e18);
    }

    function test_arbitrum_wethToUsdc_10() public {
        V3Chain memory c = _arbitrum();
        (uint24 fee,) = _selectAndSwap(c, c.weth, c.base, 10e18);
        // DEC-153's journey (10 ETH on Arbitrum without the API) picked the 0.05% tier on 2026-10-01.
        assertEq(uint256(fee), 500, "best tier for 10 WETH");
    }

    function test_arbitrum_wethToUsdc_100() public {
        V3Chain memory c = _arbitrum();
        _selectAndSwap(c, c.weth, c.base, 100e18);
    }

    function test_arbitrum_usdcToWeth_25k() public {
        V3Chain memory c = _arbitrum();
        _selectAndSwap(c, c.base, c.weth, 25_000e6);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Robinhood: WETH -> USDG and a stock token -> USDG (Spoke Chain)
    // -----------------------------------------------------------------------------------------------------------

    function test_robinhood_wethToUsdg_1() public {
        V3Chain memory c = _robinhood();
        _selectAndSwap(c, c.weth, c.base, 1e18);
    }

    function test_robinhood_wethToUsdg_10() public {
        V3Chain memory c = _robinhood();
        _selectAndSwap(c, c.weth, c.base, 10e18);
    }

    function test_robinhood_wethToUsdg_100() public {
        V3Chain memory c = _robinhood();
        _selectAndSwap(c, c.weth, c.base, 100e18);
    }

    function test_robinhood_nvdaToUsdg_10() public {
        V3Chain memory c = _robinhood();
        _selectAndSwap(c, _otherToken(RH_POOL_NVDA_USDG_500, c.base), c.base, 10e18);
    }

    function test_robinhood_nvdaToUsdg_100() public {
        V3Chain memory c = _robinhood();
        _selectAndSwap(c, _otherToken(RH_POOL_NVDA_USDG_500, c.base), c.base, 100e18);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Griefing: a quote through an empty or near-empty tier walks the tick bitmap to the price limit
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Anyone can create the missing fee tier of a pair. An initialized pool with no liquidity makes
    ///      `quoteExactInputSingle` walk every bitmap word to the price limit and then revert: the gas measured here is
    ///      what an uncapped quote of that tier costs the transaction that compares tiers.
    function test_arbitrum_griefing_emptyTierQuote() public {
        V3Chain memory c = _arbitrum();
        (IUniswapV3Pool pool, address a, address b) = _newPool(c, 100);
        assertEq(pool.liquidity(), 0, "empty pool");

        IQuoterV2.QuoteExactInputSingleParams memory p = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: a, tokenOut: b, amountIn: 1e18, fee: 100, sqrtPriceLimitX96: 0
        });
        uint256 g = gasleft();
        try c.quoter.quoteExactInputSingle(p) {
            revert("an empty pool should not quote");
        } catch {}
        uint256 uncapped = g - gasleft();
        console2.log("uncapped quote of an empty 0.01% pool, gas", uncapped);

        g = gasleft();
        try c.quoter.quoteExactInputSingle{gas: QUOTE_GAS_CAP}(p) {
            revert("an empty pool should not quote");
        } catch {}
        uint256 capped = g - gasleft();
        console2.log("capped quote (cap 1,000,000), gas", capped);
        assertGt(uncapped, 5_000_000, "the uncapped quote is a griefing vector");
        assertLt(capped, QUOTE_GAS_CAP + 50_000, "the cap bounds it");
    }

    /// @dev The `liquidity() == 0` skip does not close it: one unit of in-range liquidity passes the skip, the swap
    ///      consumes it within the first tick and then walks the bitmap the same way.
    function test_arbitrum_griefing_dustTierQuote() public {
        V3Chain memory c = _arbitrum();
        (IUniswapV3Pool pool, address a, address b) = _newPool(c, 100);
        DustMinter minter = new DustMinter();
        minter.mint(pool, -1, 1, 1000);
        assertGt(pool.liquidity(), 0, "dust is in range");

        (address tokenIn, address tokenOut) = a < b ? (a, b) : (b, a);
        IQuoterV2.QuoteExactInputSingleParams memory p = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: 1e18, fee: 100, sqrtPriceLimitX96: 0
        });
        uint256 g = gasleft();
        uint256 out;
        try c.quoter.quoteExactInputSingle(p) returns (uint256 o, uint160, uint32, uint256) {
            out = o;
        } catch {}
        uint256 uncapped = g - gasleft();
        console2.log("uncapped quote of a dust 0.01% pool, gas", uncapped, "out", out);
        assertGt(uncapped, 5_000_000, "dust liquidity does not stop the walk");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev The DEC-153 selection the adapter would run, measured step by step, then the swap through SwapRouter02
    ///      in the winning tier with the quote as the minimum (the same block state, so it must match exactly).
    function _selectAndSwap(V3Chain memory c, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint24 bestFee, uint256 bestOut)
    {
        console2.log("==", c.name);
        console2.log("tokenIn", tokenIn, "amountIn", amountIn);
        console2.log("tokenOut", tokenOut);
        uint256 readGas = _readOnlySelection(c, tokenIn, tokenOut);
        uint256 quotesGas;
        (bestFee, bestOut, quotesGas) = _quoterSelection(c, tokenIn, tokenOut, amountIn);
        console2.log("read-only selection (4 x getPool + slot0 + liquidity), gas", readGas);
        console2.log("QuoterV2 calls only, gas", quotesGas);
        console2.log("DEC-153 selection (lookups + quotes), gas", readGas + quotesGas);
        console2.log("best tier by QuoterV2", uint256(bestFee), "out", bestOut);
        assertGt(bestOut, 0, "some tier quoted");
        _swapExact(c, tokenIn, tokenOut, bestFee, amountIn, bestOut);
    }

    /// @dev (a) Read-only alternative: factory lookup plus `slot0` and `liquidity` of each existing tier. Cold.
    function _readOnlySelection(V3Chain memory c, address tokenIn, address tokenOut)
        internal
        view
        returns (uint256 gas_)
    {
        uint256 g = gasleft();
        uint128 maxLiq;
        uint24 maxLiqFee;
        for (uint256 i; i < 4; ++i) {
            address pool = c.factory.getPool(tokenIn, tokenOut, FEE_TIERS[i]);
            if (pool == address(0)) continue;
            IUniswapV3Pool(pool).slot0();
            uint128 liq = IUniswapV3Pool(pool).liquidity();
            if (liq > maxLiq) (maxLiq, maxLiqFee) = (liq, FEE_TIERS[i]);
        }
        gas_ = g - gasleft();
        console2.log("tier with the most in-range liquidity", uint256(maxLiqFee));
    }

    /// @dev (b) DEC-153: one QuoterV2 call per existing tier, capped at `QUOTE_GAS_CAP`; the highest output wins. The
    ///      read-only pass warmed the factory slots and pools, so these quotes run on warm pools.
    function _quoterSelection(V3Chain memory c, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint24 bestFee, uint256 bestOut, uint256 quotesGas)
    {
        for (uint256 i; i < 4; ++i) {
            TierQuote memory q = _quoteTier(c, tokenIn, tokenOut, amountIn, FEE_TIERS[i]);
            quotesGas += q.gasUsed;
            if (q.ok && q.amountOut > bestOut) (bestOut, bestFee) = (q.amountOut, q.fee);
        }
    }

    function _quoteTier(V3Chain memory c, address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        internal
        returns (TierQuote memory q)
    {
        q.fee = fee;
        q.pool = c.factory.getPool(tokenIn, tokenOut, fee);
        if (q.pool == address(0)) {
            console2.log("  fee", uint256(fee), "no pool");
            return q;
        }
        q.liquidity = IUniswapV3Pool(q.pool).liquidity();
        IQuoterV2.QuoteExactInputSingleParams memory p = IQuoterV2.QuoteExactInputSingleParams({
            tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
        });
        uint256 g = gasleft();
        try c.quoter.quoteExactInputSingle{gas: QUOTE_GAS_CAP}(p) returns (
            uint256 out, uint160, uint32 crossed, uint256 est
        ) {
            q.gasUsed = g - gasleft();
            (q.ok, q.amountOut, q.ticksCrossed, q.quoterEstimate) = (true, out, crossed, est);
        } catch {
            q.gasUsed = g - gasleft();
        }
        console2.log("  fee", uint256(fee), q.ok ? "quoted" : "quote reverted or hit the gas cap");
        console2.log("    amountOut", q.amountOut, "ticksCrossed", uint256(q.ticksCrossed));
        console2.log("    gasUsed", q.gasUsed, "quoter gasEstimate", q.quoterEstimate);
    }

    /// @dev (c) The swap in the winning tier, through SwapRouter02, output straight to a stand-in vault.
    function _swapExact(
        V3Chain memory c,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) internal {
        address vault = makeAddr("vault");
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).approve(address(c.router), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(vault);
        ISwapRouter02Full.ExactInputSingleParams memory p = ISwapRouter02Full.ExactInputSingleParams({
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            fee: fee,
            recipient: vault,
            amountIn: amountIn,
            amountOutMinimum: minOut,
            sqrtPriceLimitX96: 0
        });
        uint256 g = gasleft();
        uint256 got = c.router.exactInputSingle(p);
        uint256 swapGas = g - gasleft();
        console2.log("SwapRouter02.exactInputSingle, gas", swapGas, "out", got);
        assertEq(got, minOut, "the swap pays exactly the quote in the same state");
        assertEq(IERC20(tokenOut).balanceOf(vault) - before, got, "output reaches the recipient");
        assertEq(IERC20(tokenIn).balanceOf(address(this)), 0, "exact input fully spent");
    }

    /// @dev A brand-new pair of tokens and a pool in fee tier `fee`, initialized at price 1.
    function _newPool(V3Chain memory c, uint24 fee) internal returns (IUniswapV3Pool pool, address a, address b) {
        a = address(new ForkToken("AAA"));
        b = address(new ForkToken("BBB"));
        pool = IUniswapV3Pool(c.factory.createPool(a, b, fee));
        pool.initialize(2 ** 96);
    }
}
