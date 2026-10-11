// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SwapForkBase, ISwapRouter02Full} from "./SwapForkBase.sol";

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

/// @notice How a route from the Uniswap Trading API becomes a contract parameter, proven on forks.
/// @dev The API's CLASSIC quote (`QuoteResponse.quote.route`, OpenAPI `ClassicQuote.route`) is an array of splits;
///      each split is an array of pool hops (`V3PoolInRoute`: `address`, `tokenIn.address`, `tokenOut.address`, `fee`,
///      `amountIn` on the first hop, `amountOut` on the last). Requested with `protocols: ["V3"]`, every hop is a
///      `v3-pool`, and each split encodes into the packed V3 path that SwapRouter02.exactInput,
///      QuoterV2.quoteExactInput and the Universal Router's V3_SWAP_EXACT_IN all take: one leg per split, which the
///      swap adapter receives as `ApiRoute.paths` and `weightsBps` (see UniswapV3SwapAdapter.fork.t.sol). The
///      fixtures are hand-built in the API's shape (no API key during the research), not live responses. Ported from
///      the swap adapter research.
contract V3ApiRouteForkTest is SwapForkBase {
    bytes1 internal constant V3_SWAP_EXACT_IN = 0x00;

    function test_arbitrum_apiRoute_twoSplits_wethToUsdc() public {
        V3Chain memory c = _arbitrum();
        string memory json = vm.readFile("test/fork/swap/fixtures/classic-quote-arbitrum-weth-usdc-split.json");
        (Leg[] memory legs, address tokenIn, address tokenOut, uint256 amountIn) = _legsFromClassicQuote(c, json);
        assertEq(legs.length, 2, "two splits");
        assertEq(legs[0].path, _path2(c.weth, 500, ARB_USDT, 100, c.base), "split 1 is WETH-0.05%-USDT-0.01%-USDC");
        assertEq(legs[1].path, _path1(c.weth, 500, c.base), "split 2 is WETH-0.05%-USDC");
        _executeLegs(c, legs, tokenIn, tokenOut, amountIn);
    }

    function test_robinhood_apiRoute_twoHop_nvdaToUsdg() public {
        V3Chain memory c = _robinhood();
        string memory json = vm.readFile("test/fork/swap/fixtures/classic-quote-robinhood-nvda-usdg-two-hop.json");
        (Leg[] memory legs, address tokenIn, address tokenOut, uint256 amountIn) = _legsFromClassicQuote(c, json);
        assertEq(legs.length, 1, "one split");
        assertEq(legs[0].path, _path2(tokenIn, 500, c.weth, 100, c.base), "NVDA-0.05%-WETH-0.01%-USDG");
        _executeLegs(c, legs, tokenIn, tokenOut, amountIn);
    }

    /// @dev The API's ready-to-send transaction (`swapTransaction.data`, or `/swap`'s `swap.data`) is a Universal
    ///      Router `execute(commands, inputs, deadline)`. From router 2.1.1 the V3_SWAP_EXACT_IN input is
    ///      `abi.encode(recipient, amountIn, amountOutMin, path, payerIsUser, minHopPriceX36)` (Trading API docs,
    ///      "Supported Chains", SDK compatibility; universal-router `Dispatcher.sol:68-84` at 543e1a19). This test
    ///      builds that calldata, decodes the path back out of it as an off-chain translator would, and executes the
    ///      same calldata on the deployed router 2.1.2 in the API's `swapSource: "UNIVERSAL_ROUTER"` mode (input
    ///      transferred to the router first, `payerIsUser = false`), to confirm the deployed 2.1.2 takes that layout.
    function test_arbitrum_universalRouter212_v3ExactIn_layout() public {
        V3Chain memory c = _arbitrum();
        uint256 amountIn = 1e18;
        bytes memory path = _path1(c.weth, 500, c.base);
        address vault = makeAddr("vault");
        (uint256 quoted,,,) = c.quoter.quoteExactInput(path, amountIn);

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(vault, amountIn, quoted, path, false, new uint256[](0));
        bytes memory data = abi.encodeCall(
            IUniversalRouter.execute, (abi.encodePacked(V3_SWAP_EXACT_IN), inputs, block.timestamp + 1800)
        );
        _checkTranslation(data, vault, amountIn, quoted, path);

        uint256 got = _executeOnRouter(c, data, vault, amountIn);
        assertEq(got, quoted, "pays the quote");

        // The pre-2.1.1 five-field layout, for comparison.
        inputs[0] = abi.encode(vault, amountIn, 0, path, false);
        deal(c.weth, c.universalRouter212, amountIn);
        (bool ok,) = c.universalRouter212
            .call(
                abi.encodeCall(IUniversalRouter.execute, (abi.encodePacked(V3_SWAP_EXACT_IN), inputs, block.timestamp))
            );
        console2.log("five-field input accepted by 2.1.2:", ok);
    }

    /// @dev Off-chain translation the Pool Party API could run: Universal Router calldata -> V3 path.
    function _checkTranslation(bytes memory data, address vault, uint256 amountIn, uint256 minOut, bytes memory path)
        internal
        pure
    {
        (bytes memory commands, bytes[] memory inputs,) = abi.decode(_stripSelector(data), (bytes, bytes[], uint256));
        assertEq(commands.length, 1, "one command");
        assertEq(commands[0] & 0x7f, V3_SWAP_EXACT_IN, "V3_SWAP_EXACT_IN");
        (address recipient, uint256 amt, uint256 min, bytes memory decodedPath, bool payerIsUser,) =
            abi.decode(inputs[0], (address, uint256, uint256, bytes, bool, uint256[]));
        assertEq(recipient, vault);
        assertEq(amt, amountIn);
        assertEq(min, minOut);
        assertEq(decodedPath, path, "the path round-trips");
        assertFalse(payerIsUser);
    }

    /// @dev `swapSource: "UNIVERSAL_ROUTER"` mode: the input sits in the router before `execute`.
    function _executeOnRouter(V3Chain memory c, bytes memory data, address vault, uint256 amountIn)
        internal
        returns (uint256 got)
    {
        deal(c.weth, c.universalRouter212, amountIn);
        uint256 before = IERC20(c.base).balanceOf(vault);
        uint256 g = gasleft();
        (bool ok, bytes memory ret) = c.universalRouter212.call(data);
        uint256 used = g - gasleft();
        assertTrue(ok, string(ret));
        got = IERC20(c.base).balanceOf(vault) - before;
        console2.log("UniversalRouter 2.1.2 V3_SWAP_EXACT_IN (6-field input), gas", used, "out", got);
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Quotes each leg with QuoterV2, executes it through SwapRouter02 to a stand-in vault, and compares the route
    ///      with the best single direct tier (DEC-153's fallback).
    function _executeLegs(V3Chain memory c, Leg[] memory legs, address tokenIn, address tokenOut, uint256 amountIn)
        internal
    {
        // Every quote first, then every swap: a later leg must not be quoted on a state an earlier leg moved.
        uint256 quotedTotal = _quoteLegs(c, legs);
        console2.log("API-style route quote", quotedTotal);
        console2.log("best direct tier quote", _bestDirect(c, tokenIn, tokenOut, amountIn));
        uint256 gotTotal = _swapLegs(c, legs, tokenIn, tokenOut, amountIn);
        // Splits through distinct pools: executing in order reproduces the quotes taken on the untouched state.
        assertEq(gotTotal, quotedTotal, "route pays its quote");
    }

    function _quoteLegs(V3Chain memory c, Leg[] memory legs) internal returns (uint256 total) {
        for (uint256 i; i < legs.length; ++i) {
            uint256 g = gasleft();
            (uint256 out,,,) = c.quoter.quoteExactInput(legs[i].path, legs[i].amountIn);
            console2.log("leg quote, gas", g - gasleft(), "out", out);
            total += out;
        }
    }

    function _swapLegs(V3Chain memory c, Leg[] memory legs, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 total)
    {
        address vault = makeAddr("vault");
        deal(tokenIn, address(this), amountIn);
        IERC20(tokenIn).approve(address(c.router), amountIn);
        uint256 before = IERC20(tokenOut).balanceOf(vault);
        for (uint256 i; i < legs.length; ++i) {
            ISwapRouter02Full.ExactInputParams memory p = ISwapRouter02Full.ExactInputParams({
                path: legs[i].path, recipient: vault, amountIn: legs[i].amountIn, amountOutMinimum: 0
            });
            uint256 g = gasleft();
            uint256 got = c.router.exactInput(p);
            console2.log("SwapRouter02.exactInput leg, gas", g - gasleft(), "out", got);
            total += got;
        }
        assertEq(IERC20(tokenOut).balanceOf(vault) - before, total, "all output reaches the vault");
        assertEq(IERC20(tokenIn).balanceOf(address(this)), 0, "the whole input was spent");
    }

    function _bestDirect(V3Chain memory c, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 best)
    {
        for (uint256 i; i < 4; ++i) {
            if (c.factory.getPool(tokenIn, tokenOut, FEE_TIERS[i]) == address(0)) continue;
            try c.quoter.quoteExactInput{gas: 1_000_000}(_path1(tokenIn, FEE_TIERS[i], tokenOut), amountIn) returns (
                uint256 out, uint160[] memory, uint32[] memory, uint256
            ) {
                if (out > best) best = out;
            } catch {}
        }
    }

    function _stripSelector(bytes memory data) internal pure returns (bytes memory out) {
        out = new bytes(data.length - 4);
        for (uint256 i; i < out.length; ++i) {
            out[i] = data[i + 4];
        }
    }
}
