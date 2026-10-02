// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {ForkToken, DustMinter} from "../../mocks/swap/V3ForkHelpers.sol";
import {SwapForkBase} from "./SwapForkBase.sol";

/// @notice The Uniswap V3 swap adapter on forks of both MVP chains (DEC-129, DEC-136, DEC-140, DEC-142, DEC-143,
///         DEC-153; founder chat 1, 2026-10-02): every mode against the live V3 factory, QuoterV2 and SwapRouter02, the
///         gas of each mode, and the validation rules. The test contract plays the Spoke Vault: it holds the input,
///         approves the adapter for exactly that amount and receives the output.
/// @dev Block-independent: a chosen tier is compared with QuoterV2 quotes taken in the same state, and a swap must pay
///      exactly its quote. The one market assertion kept is DEC-153's own journey (10 WETH on Arbitrum: the 0.05% tier,
///      whose in-range liquidity was about 7x the 0.3% tier's on 2026-10-02).
contract UniswapV3SwapAdapterForkTest is SwapForkBase {
    uint16 internal constant NO_MAX = 0;
    /// @dev V3 TickMath.MAX_SQRT_RATIO; QuoterV2 swaps token1 for token0 up to one below it when given no limit.
    uint160 internal constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    UniswapV3SwapAdapter internal adapter;
    V3Chain internal chain;
    address internal guardian = makeAddr("guardian");
    address internal apiSigner;
    uint256 internal apiKey;

    // -----------------------------------------------------------------------------------------------------------
    // Without the API: DEC-153, the adapter picks the best V3 tier of the direct pair
    // -----------------------------------------------------------------------------------------------------------

    function test_arbitrum_noApi_wethToUsdc_10_bestTier() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        uint24 fee = _assertBestTier(ARB_WETH, ARB_USDC, 10e18);
        assertEq(uint256(fee), 500, "DEC-153 journey: 10 WETH on Arbitrum sells in the 0.05% tier");
        (uint256 out, uint256 spot,) = _swap(ARB_WETH, ARB_USDC, 10e18, NO_MAX, "", "no API, 10 WETH -> USDC");
        assertLt(_lossBps(spot, out), 50, "fee plus impact well under 0.5%");
    }

    function test_arbitrum_noApi_usdcToWeth_25k() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        _assertBestTier(ARB_USDC, ARB_WETH, 25_000e6);
        _swap(ARB_USDC, ARB_WETH, 25_000e6, NO_MAX, "", "no API, 25,000 USDC -> WETH");
    }

    function test_robinhood_noApi_wethToUsdg_10() public {
        _setUp(_robinhood(), _tokens2(RH_WETH, RH_USDG));
        _assertBestTier(RH_WETH, RH_USDG, 10e18);
        _swap(RH_WETH, RH_USDG, 10e18, NO_MAX, "", "no API, 10 WETH -> USDG");
    }

    function test_robinhood_noApi_nvdaToUsdg_100() public {
        _setUp(_robinhood(), _tokens3(RH_WETH, RH_USDG, RH_NVDA));
        _assertBestTier(RH_NVDA, RH_USDG, 100e18);
        _swap(RH_NVDA, RH_USDG, 100e18, NO_MAX, "", "no API, 100 NVDA -> USDG");
    }

    /// @dev DEC-140 / DEC-142: the maximum loss is measured against the chosen pool's mid price before the trade, so it
    ///      counts the pool fee: 1 bp cannot pass a 0.05% pool, 50 bps can.
    function test_arbitrum_noApi_maxLossCountsFeeAndImpact() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        _fund(ARB_WETH, 10e18);
        vm.expectPartialRevert(ISwapAdapter.InsufficientOutput.selector);
        adapter.swap(ARB_WETH, ARB_USDC, 10e18, 1, "");
        _swapFunded(ARB_WETH, ARB_USDC, 10e18, 50, "", "no API, maxLoss 50 bps");
    }

    /// @dev D-21: a pair with one real pool (0.05%) and a dust 0.01% pool someone created. The capped quote of the dust
    ///      tier fails, the real tier wins, the gas stays bounded (an uncapped quote of it burns 25-36M gas).
    function test_arbitrum_noApi_griefedTierBounded() public {
        V3Chain memory c = _arbitrum();
        ForkToken a = new ForkToken("AAA");
        ForkToken b = new ForkToken("BBB");
        DustMinter minter = new DustMinter();
        IUniswapV3Pool deep = IUniswapV3Pool(c.factory.createPool(address(a), address(b), 500));
        deep.initialize(2 ** 96);
        minter.mint(deep, -10_000, 10_000, 1e24);
        IUniswapV3Pool dust = IUniswapV3Pool(c.factory.createPool(address(a), address(b), 100));
        dust.initialize(2 ** 96);
        minter.mint(dust, -1, 1, 1000);

        chain = c;
        (apiSigner, apiKey) = makeAddrAndKey("pool-party-api");
        adapter = new UniswapV3SwapAdapter(
            address(this),
            guardian,
            address(b),
            _tokens2(address(a), address(b)),
            address(c.factory),
            address(c.router),
            address(c.quoter),
            apiSigner
        );
        a.mint(address(this), 1e18);
        a.approve(address(adapter), 1e18);
        uint256 g = gasleft();
        (uint256 out,) = adapter.swap(address(a), address(b), 1e18, NO_MAX, "");
        uint256 used = g - gasleft();
        console2.log("griefed pair, adapter.swap gas", used, "out", out);
        assertGt(out, 0, "the real tier filled");
        assertLt(used, 2_500_000, "bounded by the quote gas cap");
    }

    /// @dev A drained tier (review round 1): two new tokens at price 1, a 0.05% full-range pool and a 1% pool with more
    ///      liquidity but only in ticks [-200, 200]. Selling 497 of token1 drains the 1% pool, whose quote (about 479.6)
    ///      beats the full fill of the 0.05% pool (about 473.2) because QuoterV2 drops the unspent input of an exact
    ///      input. Its price ends at the limit, so the adapter skips it and the sale fills in the 0.05% tier. Anyone can
    ///      place such liquidity at the market price, at no arbitrage loss.
    function test_arbitrum_noApi_drainedTierDoesNotOutbidATierThatFills() public {
        V3Chain memory c = _arbitrum();
        (address t0, address t1) = _drainablePair(c);
        uint256 amountIn = 497e18;
        uint256 fullOut = _assertTheDrainedTierQuotesMore(c, t1, t0, amountIn);

        _setUpWithBase(c, t0, _tokens2(t0, t1));
        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(t1, t0, amountIn);
        assertEq(uint256(fee), 500, "the best tier that fills");
        assertEq(quoted, fullOut);
        (uint256 out,,) = _swap(t1, t0, amountIn, NO_MAX, "", "no API, a drained 1% tier next to a 0.05% tier");
        assertEq(out, fullOut, "the sale fills in the 0.05% tier");

        // What choosing the drained tier would have done.
        _fund(t1, amountIn);
        vm.expectPartialRevert(ISwapAdapter.PartialFill.selector);
        adapter.swapDirect(t1, t0, amountIn, 10_000, NO_MAX);
    }

    /// @dev DEC-153 accepted consequence: a Mandate token without a direct V3 pool against the base token has no route
    ///      without the API.
    function test_arbitrum_noApi_tokenWithoutADirectPoolHasNoRoute() public {
        V3Chain memory c = _arbitrum();
        address lonely = address(new ForkToken("LONELY"));
        _setUp(c, _tokens3(ARB_WETH, ARB_USDC, lonely));
        ForkToken(lonely).mint(address(this), 1e18);
        IERC20(lonely).approve(address(adapter), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NoRoute.selector, lonely, ARB_USDC));
        adapter.swap(lonely, ARB_USDC, 1e18, NO_MAX, "");
    }

    /// @dev D-21: the vault's own libraries choose the tier once and reuse it; `swapDirect` skips the quotes.
    function test_robinhood_bestDirectFeeThenSwapDirect() public {
        _setUp(_robinhood(), _tokens2(RH_WETH, RH_USDG));
        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(RH_WETH, RH_USDG, 10e18);
        uint256 spot = adapter.spotValue(RH_WETH, RH_USDG, 10e18, fee);
        assertGt(spot, quoted, "the mid value has no fee and no impact");
        assertLt(_lossBps(spot, quoted), 100, "within 1% of the quote");
        _fund(RH_WETH, 10e18);
        uint256 g = gasleft();
        (uint256 out, uint256 spotOut) = adapter.swapDirect(RH_WETH, RH_USDG, 10e18, fee, 100);
        console2.log("swapDirect 10 WETH -> USDG, gas", g - gasleft(), "fee", uint256(fee));
        assertEq(out, quoted, "pays the chosen tier's quote");
        assertEq(spotOut, spot);
    }

    // -----------------------------------------------------------------------------------------------------------
    // With the API: a route from a Trading API CLASSIC quote, signed by the Pool Party API (DEC-129, DEC-143)
    // -----------------------------------------------------------------------------------------------------------

    /// @dev Founder chat 1: the route the Uniswap API returns, sent to the contract through the Pool Party API's
    ///      signature. The CLASSIC quote fixture (two splits, through USDT and direct) becomes `paths` and `weightsBps`,
    ///      the API signs it with a 0.5% minimum, and the adapter pays exactly the route's quote.
    function test_arbitrum_api_classicQuoteSplitRoute() public {
        _setUp(_arbitrum(), _tokens3(ARB_WETH, ARB_USDC, ARB_USDT));
        (bytes[] memory paths, uint16[] memory w, uint256 amountIn) =
            _routeFromFixture("test/fork/swap/fixtures/classic-quote-arbitrum-weth-usdc-split.json");
        uint256 quoted = _quotePaths(paths, w, amountIn);
        bytes memory route = _signRoute(paths, w, ARB_WETH, ARB_USDC, amountIn, quoted * 995 / 1000, apiKey);
        (uint256 out,,) = _swap(ARB_WETH, ARB_USDC, amountIn, NO_MAX, route, "API route, two splits, 10 WETH");
        assertEq(out, quoted, "pays the route's quote");
    }

    function test_robinhood_api_classicQuoteTwoHop() public {
        _setUp(_robinhood(), _tokens3(RH_WETH, RH_USDG, RH_NVDA));
        (bytes[] memory paths, uint16[] memory w, uint256 amountIn) =
            _routeFromFixture("test/fork/swap/fixtures/classic-quote-robinhood-nvda-usdg-two-hop.json");
        uint256 quoted = _quotePaths(paths, w, amountIn);
        bytes memory route = _signRoute(paths, w, RH_NVDA, RH_USDG, amountIn, quoted * 995 / 1000, apiKey);
        (uint256 out,,) = _swap(RH_NVDA, RH_USDG, amountIn, NO_MAX, route, "API route, NVDA -> WETH -> USDG");
        assertEq(out, quoted, "pays the route's quote");
    }

    /// @dev D-52 (DEC-136 item 2): only Mandate tokens. With USDT outside the Mandate the same signed route is refused.
    function test_arbitrum_api_rejectsTokenOutsideMandate() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        (bytes[] memory paths, uint16[] memory w) = _arbSplitRoute();
        bytes memory route = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, 0, apiKey);
        _expectRefused(route, abi.encodeWithSelector(ISwapAdapter.TokenNotInMandate.selector, ARB_USDT));
    }

    /// @dev DEC-143: a route the API did not sign is the caller choosing the route.
    function test_arbitrum_api_rejectsOtherSigner() public {
        _setUp(_arbitrum(), _tokens3(ARB_WETH, ARB_USDC, ARB_USDT));
        (bytes[] memory paths, uint16[] memory w) = _arbSplitRoute();
        (, uint256 managerKey) = makeAddrAndKey("manager");
        bytes memory route = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, 0, managerKey);
        _expectRefused(route, abi.encodeWithSelector(ISwapAdapter.InvalidRouteSignature.selector));
    }

    function test_arbitrum_api_rejectsTamperedWeights() public {
        _setUp(_arbitrum(), _tokens3(ARB_WETH, ARB_USDC, ARB_USDT));
        (bytes[] memory paths, uint16[] memory w) = _arbSplitRoute();
        ISwapAdapter.ApiRoute memory r =
            abi.decode(_signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, 0, apiKey), (ISwapAdapter.ApiRoute));
        (r.weightsBps[0], r.weightsBps[1]) = (1000, 9000);
        _expectRefused(abi.encode(r), abi.encodeWithSelector(ISwapAdapter.InvalidRouteSignature.selector));
    }

    function test_arbitrum_api_rejectsExpired() public {
        _setUp(_arbitrum(), _tokens3(ARB_WETH, ARB_USDC, ARB_USDT));
        (bytes[] memory paths, uint16[] memory w) = _arbSplitRoute();
        bytes memory route = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, 0, apiKey);
        vm.warp(block.timestamp + 301);
        _expectRefused(route, abi.encodeWithSelector(ISwapAdapter.RouteExpired.selector, block.timestamp - 1));
    }

    /// @dev Only the four fee tiers, even when the API signed it.
    function test_arbitrum_api_rejectsNonStandardFee() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(ARB_WETH, 2500, ARB_USDC));
        bytes memory route = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, 0, apiKey);
        _expectRefused(route, abi.encodeWithSelector(ISwapAdapter.InvalidFee.selector, uint24(2500)));
    }

    /// @dev DEC-142: the stricter of the API's minimum and the caller's maximum loss wins, in both directions.
    function test_arbitrum_api_stricterMinimumWins() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        (bytes[] memory paths, uint16[] memory w) = _one(_path1(ARB_WETH, 500, ARB_USDC));
        uint256 quoted = _quotePaths(paths, w, 10e18);

        // API minimum above what the pool pays; the caller sent no maximum: refused.
        bytes memory tight = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, quoted + 1, apiKey);
        _expectRefused(tight, abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, quoted, quoted + 1));

        // API minimum zero; the caller's 1 bp is stricter: refused.
        bytes memory loose = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, 0, apiKey);
        vm.expectPartialRevert(ISwapAdapter.InsufficientOutput.selector);
        adapter.swap(ARB_WETH, ARB_USDC, 10e18, 1, loose);

        // Both satisfiable: passes and pays the quote.
        bytes memory fair = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, quoted, apiKey);
        (uint256 out,,) = _swapFunded(ARB_WETH, ARB_USDC, 10e18, 50, fair, "API route, maxLoss 50 bps");
        assertEq(out, quoted);
    }

    /// @dev DEC-136 item 4, DEC-137: an unwind sells an amount known only on-chain. The route signed for 10 WETH
    ///      executes for 9.5 WETH with legs and minimum scaled to it.
    function test_arbitrum_api_routeScalesToTheAmountSold() public {
        _setUp(_arbitrum(), _tokens3(ARB_WETH, ARB_USDC, ARB_USDT));
        (bytes[] memory paths, uint16[] memory w) = _arbSplitRoute();
        uint256 quoted = _quotePaths(paths, w, 10e18);
        bytes memory route = _signRoute(paths, w, ARB_WETH, ARB_USDC, 10e18, quoted * 995 / 1000, apiKey);
        (uint256 out,,) = _swap(ARB_WETH, ARB_USDC, 9.5e18, NO_MAX, route, "API route signed for 10, sold 9.5");
        assertGe(out, quoted * 995 / 1000 * 95 / 100, "scaled minimum held");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Guard and access
    // -----------------------------------------------------------------------------------------------------------

    /// @dev DEC-056: pause and deprecation stop entries (output not the base token), never the sale into the base
    ///      token that an unwind needs.
    function test_arbitrum_pauseAndDeprecation_keepTheExitOpen() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        vm.prank(guardian);
        adapter.setPaused(true);
        _fund(ARB_USDC, 1000e6);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.swap(ARB_USDC, ARB_WETH, 1000e6, NO_MAX, "");
        _swap(ARB_WETH, ARB_USDC, 1e18, NO_MAX, "", "paused, exit into USDC");

        vm.prank(guardian);
        adapter.deprecate();
        _fund(ARB_USDC, 1000e6);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        adapter.swap(ARB_USDC, ARB_WETH, 1000e6, NO_MAX, "");
        _swap(ARB_WETH, ARB_USDC, 1e18, NO_MAX, "", "deprecated, exit into USDC");
    }

    function test_arbitrum_onlyVault() public {
        _setUp(_arbitrum(), _tokens2(ARB_WETH, ARB_USDC));
        address manager = makeAddr("manager");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NotVault.selector, manager));
        adapter.swap(ARB_WETH, ARB_USDC, 1e18, NO_MAX, "");
    }

    // -----------------------------------------------------------------------------------------------------------
    // Internals
    // -----------------------------------------------------------------------------------------------------------

    function _setUp(V3Chain memory c, address[] memory tokens) internal {
        _setUpWithBase(c, c.base, tokens);
    }

    function _setUpWithBase(V3Chain memory c, address base, address[] memory tokens) internal {
        chain = c;
        (apiSigner, apiKey) = makeAddrAndKey("pool-party-api");
        adapter = new UniswapV3SwapAdapter(
            address(this), guardian, base, tokens, address(c.factory), address(c.router), address(c.quoter), apiSigner
        );
    }

    /// @dev Two new tokens at price 1: a 0.05% pool with L = 1e22 over the full range, and a 1% pool with L = 4.82e22
    ///      only in ticks [-200, 200] (about 480 of each token), which a sale of 497 drains.
    function _drainablePair(V3Chain memory c) internal returns (address t0, address t1) {
        (t0, t1) = _sorted(address(new ForkToken("AAA")), address(new ForkToken("BBB")));
        DustMinter minter = new DustMinter();
        IUniswapV3Pool full = IUniswapV3Pool(c.factory.createPool(t0, t1, 500));
        full.initialize(2 ** 96);
        minter.mint(full, -887_270, 887_270, 1e22);
        IUniswapV3Pool thin = IUniswapV3Pool(c.factory.createPool(t0, t1, 10_000));
        thin.initialize(2 ** 96);
        minter.mint(thin, -200, 200, 4.82e22);
    }

    /// @dev QuoterV2 on its own: the drained 1% tier quotes more than the 0.05% tier, and only because its price ends at
    ///      the limit (selling token1 raises the price). Returns the 0.05% quote.
    function _assertTheDrainedTierQuotesMore(V3Chain memory c, address tokenIn, address tokenOut, uint256 amountIn)
        internal
        returns (uint256 fullOut)
    {
        assertGt(uint160(tokenIn), uint160(tokenOut), "selling token1");
        (uint256 thinOut, uint160 thinAfter,,) = c.quoter
        .quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, 10_000, 0));
        uint160 fullAfter;
        (fullOut, fullAfter,,) =
            c.quoter.quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, 500, 0));
        console2.log("drained 1% quote", thinOut, "full 0.05% quote", fullOut);
        assertGt(thinOut, fullOut, "the drained tier quotes more");
        assertEq(thinAfter, MAX_SQRT_RATIO - 1, "because it stopped at the price limit");
        assertLt(fullAfter, MAX_SQRT_RATIO - 1, "the 0.05% tier fills");
    }

    /// @dev The vault side: holds exactly `amount` and approves the adapter for it.
    function _fund(address token, uint256 amount) internal {
        deal(token, address(this), amount);
        IERC20(token).approve(address(adapter), amount);
    }

    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint16 maxLossBps,
        bytes memory route,
        string memory label
    ) internal returns (uint256 out, uint256 spot, uint256 used) {
        _fund(tokenIn, amountIn);
        return _swapFunded(tokenIn, tokenOut, amountIn, maxLossBps, route, label);
    }

    function _swapFunded(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint16 maxLossBps,
        bytes memory route,
        string memory label
    ) internal returns (uint256 out, uint256 spot, uint256 used) {
        uint256 before = IERC20(tokenOut).balanceOf(address(this));
        uint256 g = gasleft();
        (out, spot) = adapter.swap(tokenIn, tokenOut, amountIn, maxLossBps, route);
        used = g - gasleft();
        console2.log(label);
        console2.log("  adapter.swap gas", used, "route bytes", route.length);
        console2.log("  out", out, "spotOut", spot);
        console2.log("  loss vs pre-trade spot, millionths", spot > out ? (spot - out) * 1e6 / spot : 0);
        assertEq(IERC20(tokenOut).balanceOf(address(this)) - before, out, "output reached the vault");
        assertEq(IERC20(tokenIn).balanceOf(address(this)), 0, "exactly amountIn left the vault");
        assertEq(IERC20(tokenIn).balanceOf(address(adapter)), 0, "the adapter keeps nothing");
        assertEq(IERC20(tokenIn).allowance(address(adapter), address(chain.router)), 0, "router approval cleared");
        assertEq(IERC20(tokenIn).allowance(address(this), address(adapter)), 0, "vault approval consumed");
    }

    /// @dev The adapter's tier equals the highest of QuoterV2's capped quotes of the direct pair's live pools with
    ///      in-range liquidity, taken here independently in the same state (DEC-153).
    function _assertBestTier(address tokenIn, address tokenOut, uint256 amountIn) internal returns (uint24 fee) {
        uint256 best;
        uint24 bestFee;
        for (uint256 i; i < 4; ++i) {
            address pool = chain.factory.getPool(tokenIn, tokenOut, FEE_TIERS[i]);
            if (pool == address(0) || IUniswapV3Pool(pool).liquidity() == 0) continue;
            try chain.quoter.quoteExactInputSingle{gas: 1_000_000}(
                IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, FEE_TIERS[i], 0)
            ) returns (
                uint256 out, uint160, uint32, uint256
            ) {
                console2.log("  tier", uint256(FEE_TIERS[i]), "quote", out);
                if (out > best) (best, bestFee) = (out, FEE_TIERS[i]);
            } catch {
                console2.log("  tier", uint256(FEE_TIERS[i]), "quote failed or hit the cap");
            }
        }
        uint256 quoted;
        (fee, quoted) = adapter.bestDirectFee(tokenIn, tokenOut, amountIn);
        console2.log("adapter's tier", uint256(fee));
        assertEq(fee, bestFee, "the tier with the highest quote");
        assertEq(quoted, best);
    }

    function _lossBps(uint256 spot, uint256 out) internal pure returns (uint256) {
        return spot > out ? (spot - out) * 10_000 / spot : 0;
    }

    /// @dev 60% WETH -0.05%- USDT -0.01%- USDC and 40% WETH -0.05%- USDC.
    function _arbSplitRoute() internal pure returns (bytes[] memory paths, uint16[] memory w) {
        paths = new bytes[](2);
        paths[0] = _path2(ARB_WETH, 500, ARB_USDT, 100, ARB_USDC);
        paths[1] = _path1(ARB_WETH, 500, ARB_USDC);
        w = new uint16[](2);
        (w[0], w[1]) = (6000, 4000);
    }

    function _one(bytes memory path) internal pure returns (bytes[] memory paths, uint16[] memory w) {
        paths = new bytes[](1);
        paths[0] = path;
        w = new uint16[](1);
        w[0] = 10_000;
    }

    function _routeFromFixture(string memory file)
        internal
        view
        returns (bytes[] memory paths, uint16[] memory w, uint256 amountIn)
    {
        (Leg[] memory legs,,, uint256 quotedIn) = _legsFromClassicQuote(chain, vm.readFile(file));
        (paths, w) = _pathsAndWeights(legs, quotedIn);
        amountIn = quotedIn;
    }

    /// @dev What the API would quote for these legs with the adapter's split, on the untouched state.
    function _quotePaths(bytes[] memory paths, uint16[] memory w, uint256 amountIn) internal returns (uint256 total) {
        uint256 left = amountIn;
        for (uint256 i; i < paths.length; ++i) {
            uint256 amt = i + 1 == paths.length ? left : amountIn * w[i] / 10_000;
            left -= amt;
            (uint256 out,,,) = chain.quoter.quoteExactInput(paths[i], amt);
            total += out;
        }
    }

    /// @dev Funds `amountIn` of WETH (Arbitrum) and expects the WETH -> USDC swap with `route` to revert with `err`.
    function _expectRefused(bytes memory route, bytes memory err) internal {
        _fund(ARB_WETH, 10e18);
        vm.expectRevert(err);
        adapter.swap(ARB_WETH, ARB_USDC, 10e18, NO_MAX, route);
    }

    /// @dev The Pool Party API's side: EIP-712 over the route, domain bound to this adapter (one fund, one chain),
    ///      valid for 5 minutes.
    function _signRoute(
        bytes[] memory paths,
        uint16[] memory w,
        address tokenIn,
        address tokenOut,
        uint256 quotedAmountIn,
        uint256 minAmountOut,
        uint256 key
    ) internal view returns (bytes memory) {
        ISwapAdapter.ApiRoute memory r =
            ISwapAdapter.ApiRoute(paths, w, quotedAmountIn, minAmountOut, block.timestamp + 300, "");
        bytes32 structHash = keccak256(
            abi.encode(
                adapter.ROUTE_TYPEHASH(),
                tokenIn,
                tokenOut,
                keccak256(abi.encode(r.paths, r.weightsBps)),
                r.quotedAmountIn,
                r.minAmountOut,
                r.deadline
            )
        );
        bytes32 domain = keccak256(
            abi.encode(
                DOMAIN_TYPEHASH, keccak256("Pool Party Swap Adapter"), keccak256("1"), block.chainid, address(adapter)
            )
        );
        (uint8 v, bytes32 rr, bytes32 ss) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", domain, structHash)));
        r.signature = abi.encodePacked(rr, ss, v);
        return abi.encode(r);
    }

    function _sorted(address a, address b) internal pure returns (address, address) {
        return a < b ? (a, b) : (b, a);
    }

    function _tokens2(address a, address b) internal pure returns (address[] memory t) {
        t = new address[](2);
        (t[0], t[1]) = (a, b);
    }

    function _tokens3(address a, address b, address c) internal pure returns (address[] memory t) {
        t = new address[](3);
        (t[0], t[1], t[2]) = (a, b, c);
    }
}
