// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {MockV3Pool, MockMiswiredPeriphery} from "../../mocks/swap/MockV3.sol";
import {SwapAdapterTestBase} from "./SwapAdapterTestBase.sol";

/// @notice The Uniswap V3 swap adapter without the API (DEC-153), its custody, its guard and the caller's maximum loss
///         (DEC-140, DEC-142), against the mock V3 stack.
contract UniswapV3SwapAdapterTest is SwapAdapterTestBase {
    // ------------------------------------------------------------------------------------------------------------
    // Construction and size
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC136_constructorStoresTheWiringAndTheMandateTokens() public view {
        assertEq(adapter.vault(), address(this));
        assertEq(adapter.guardian(), guardian);
        assertEq(adapter.baseToken(), address(base));
        assertEq(adapter.routeSigner(), apiSigner);
        assertEq(address(adapter.v3Factory()), address(factory));
        assertEq(address(adapter.swapRouter()), address(router));
        assertEq(address(adapter.quoterV2()), address(quoter));
        assertTrue(adapter.isMandateToken(address(base)));
        assertTrue(adapter.isMandateToken(address(weth)));
        assertTrue(adapter.isMandateToken(address(stock)));
        assertTrue(adapter.isMandateToken(address(usdt)));
        assertFalse(adapter.isMandateToken(address(outsider)));
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            adapter.eip712Domain();
        assertEq(name, "Pool Party Swap Adapter");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(adapter));
    }

    function test_DEC136_constructorRejectsZeroAddresses() public {
        address[] memory tokens = _mandate4();
        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);
        new UniswapV3SwapAdapter(
            address(0), guardian, address(base), tokens, address(factory), address(router), address(quoter), apiSigner
        );
        vm.expectRevert(AdapterGuard.ZeroGuardian.selector);
        new UniswapV3SwapAdapter(
            address(this),
            address(0),
            address(base),
            tokens,
            address(factory),
            address(router),
            address(quoter),
            apiSigner
        );
        tokens[2] = address(0);
        vm.expectRevert(UniswapV3SwapAdapter.ZeroAddress.selector);
        _deploy(apiSigner, tokens);
    }

    function test_DEC136_constructorRejectsABaseTokenOutsideTheMandate() public {
        address[] memory tokens = new address[](1);
        tokens[0] = address(weth);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.TokenNotInMandate.selector, address(base)));
        _deploy(apiSigner, tokens);
    }

    /// @dev SwapRouter02 derives every pool from its factory, so the router and the quoter must use the factory the
    ///      adapter validates pools against.
    function test_DEC153_constructorRejectsARouterOrQuoterOfAnotherFactory() public {
        address other = address(new MockMiswiredPeriphery(makeAddr("other factory")));
        address[] memory tokens = _mandate4();
        vm.expectRevert(UniswapV3SwapAdapter.WiringMismatch.selector);
        new UniswapV3SwapAdapter(
            address(this), guardian, address(base), tokens, address(factory), other, address(quoter), apiSigner
        );
        vm.expectRevert(UniswapV3SwapAdapter.WiringMismatch.selector);
        new UniswapV3SwapAdapter(
            address(this), guardian, address(base), tokens, address(factory), address(router), other, apiSigner
        );
    }

    /// @dev DEC-131 (b4): every production contract fits Arbitrum One's 24,576 bytes. Interim check until the suite's
    ///      size test (WP-01) lists this contract.
    function test_DEC131_fitsTheSmallestCodeLimit() public view {
        uint256 size = vm.getDeployedCode("UniswapV3SwapAdapter.sol:UniswapV3SwapAdapter").length;
        console2.log("UniswapV3SwapAdapter runtime bytes", size, "margin", 24_576 - size);
        assertLe(size, 24_576);
        assertEq(address(adapter).code.length, size);
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-153: without the API the adapter picks the best direct V3 fee tier
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC153_emptyRouteSwapsInTheTierWithTheHighestQuote() public {
        uint256 expected = _out(AMOUNT, 500, 0);
        _fund(address(weth), AMOUNT);
        vm.expectEmit(address(adapter));
        emit ISwapAdapter.Swapped(address(weth), address(base), AMOUNT, expected, AMOUNT, 500, bytes32(0));
        (uint256 out, uint256 spot) = adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, expected, "0.05% tier");
        assertEq(spot, AMOUNT, "mid value at price 1");
        assertEq(base.balanceOf(address(this)), expected, "output reached the vault");
        _assertNothingKept(address(weth));
    }

    function test_DEC153_bestDirectFeeIsOpenToAnyoneAndMatchesTheSwap() public {
        vm.prank(stranger);
        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 500);
        assertEq(quoted, _out(AMOUNT, 500, 0));
        (uint256 out,) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, quoted, "the swap pays the chosen tier's quote");
    }

    function test_DEC153_missingTiersAreSkipped() public {
        factory.createPool(address(stock), address(usdt), 3000, PRICE_ONE, LIQUIDITY);
        factory.createPool(address(stock), address(usdt), 10_000, PRICE_ONE, LIQUIDITY);
        (uint24 fee,) = adapter.bestDirectFee(address(stock), address(usdt), AMOUNT);
        assertEq(fee, 3000);
    }

    /// @dev D-21: a tier without in-range liquidity is not quoted, even when its fee would make it the best.
    function test_DEC153_zeroLiquidityTierIsSkippedWithoutAQuote() public {
        wethBase[0].setImpactBps(0);
        wethBase[0].setLiquidity(0);
        (uint24 fee,) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 500);
        assertEq(quoter.quotes(address(wethBase[0])), 0, "never quoted");
        assertEq(quoter.quotes(address(wethBase[1])), 1);
    }

    function test_DEC153_aRevertingQuoteIsSkipped() public {
        wethBase[1].setMode(MockV3Pool.Mode.QuoteReverts);
        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 3000, "0.3% beats 0.01% with 60 bps of impact");
        assertEq(quoted, _out(AMOUNT, 3000, 0));
    }

    /// @dev A tier whose in-range liquidity runs out before the whole input quotes only the output of what it took
    ///      (QuoterV2 drops the amount spent for an exact input) and ends at the price limit. Here that drained quote is
    ///      the highest, yet the tier is skipped: the swap in it would revert `PartialFill`, and anyone can place such
    ///      liquidity at the market price to block a sale.
    function test_DEC153_aTierThatCannotFillTheWholeInputIsSkipped() public {
        wethBase[0].setImpactBps(0);
        wethBase[0].setFillableIn(AMOUNT * 99 / 100);
        for (uint256 i = 1; i < 4; ++i) {
            wethBase[i].setImpactBps(200);
        }
        (uint256 drained, uint160 sqrtPriceX96After,,) = quoter.quoteExactInputSingle(
            IQuoterV2.QuoteExactInputSingleParams(address(weth), address(base), AMOUNT, 100, 0)
        );
        assertGt(drained, _out(AMOUNT, 500, 200), "the drained tier quotes the most");
        assertEq(sqrtPriceX96After, _limit(address(weth), address(base)), "and stops at the price limit");

        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 500, "the best tier that fills");
        assertEq(quoted, _out(AMOUNT, 500, 200));
        (uint256 out,) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, quoted, "the swap fills in it");
        _assertNothingKept(address(weth));

        // What choosing the drained tier would have done.
        _fund(address(weth), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.PartialFill.selector, 0, AMOUNT / 100));
        adapter.swapDirect(address(weth), address(base), AMOUNT, 100, NO_MAX);
    }

    /// @dev Both directions (the limit is the lowest price when selling token0, the highest when selling token1), and
    ///      no tier filling the whole input is no route.
    function test_DEC153_noTierFillingTheWholeInputIsNoRoute() public {
        for (uint256 i; i < 4; ++i) {
            wethBase[i].setFillableIn(AMOUNT - 1);
        }
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NoRoute.selector, address(weth), address(base)));
        adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NoRoute.selector, address(base), address(weth)));
        adapter.bestDirectFee(address(base), address(weth), AMOUNT);
        (uint24 fee,) = adapter.bestDirectFee(address(weth), address(base), AMOUNT - 1);
        assertEq(fee, 500, "an input the tiers can fill still routes");
    }

    /// @dev DEC-129 item 3 ("em qualquer quantia"): a dust input that every tier fills with a zero output still sells,
    ///      in the first tier that fills, as it does through `swapDirect`; an unwind's dust remainder must not revert.
    function test_DEC129_aDustInputEveryTierFillsAtZeroStillSells() public {
        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), 1);
        assertEq(fee, 100, "the first tier that fills");
        assertEq(quoted, 0);
        (uint256 out, uint256 spot) = _swap(address(weth), address(base), 1, 100, "");
        assertEq(out, 0);
        assertEq(spot, 1);
        _assertNothingKept(address(weth));
        (out,) = _directSwap(address(weth), address(base), 1, 500);
        assertEq(out, 0, "swapDirect sells it too");
    }

    /// @dev Open for the founder (review rounds 2 and 3): a third party's tier (here it replaces the 1% one) at a mid
    ///      price four times the market's fills the whole input and outbids every honest tier, so it is chosen
    ///      (DEC-153 item 2). Against its own mid it loses 74%, so a sale with a 1% maximum reverts, although the 0.05%
    ///      tier fills it within that maximum.
    function test_DEC153_aThirdPartyTierAboveTheMarketFailsABoundedSale() public {
        uint256 trapOut = _trapTier().out(address(weth), AMOUNT);
        assertGt(trapOut, _out(AMOUNT, 500, 0), "the trap quotes the most");
        assertEq(adapter.spotValue(address(weth), address(base), AMOUNT, 10_000), 4 * AMOUNT, "at its own mid");

        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 10_000, "chosen on output");
        assertEq(quoted, trapOut);
        _fund(address(weth), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, trapOut, AMOUNT * 396 / 100));
        adapter.swap(address(weth), address(base), AMOUNT, 100, "");

        (uint256 out, uint256 spot) = adapter.swapDirect(address(weth), address(base), AMOUNT, 500, 100);
        assertEq(out, _out(AMOUNT, 500, 0), "the 0.05% tier fills it within the maximum");
        assertEq(spot, AMOUNT);
    }

    /// @dev Review round 3: a third party's tier at a quarter of the market's mid loses only its 0.01% fee against
    ///      that mid. With a 4 bps maximum, which no honest tier meets (the 0.05% tier's fee alone is 5 bps), the sale
    ///      is refused (DEC-148) instead of selling to that tier at a quarter of its value, which is what ranking the
    ///      tiers by the maximum against each tier's own mid did (review round 2). A maximum an honest tier meets sells
    ///      in the honest tier.
    function test_DEC153_aThirdPartyTierBelowTheMarketNeverBuysABoundedSale() public {
        uint256 trapOut = _tierBelowTheMarket().out(address(weth), AMOUNT);
        assertEq(adapter.spotValue(address(weth), address(base), AMOUNT, 100), AMOUNT / 4, "a quarter of the market");
        assertGe(trapOut, AMOUNT / 4 * 9996 / 10_000, "within 4 bps of its own mid");

        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 500, "the honest tier pays the most");
        assertEq(quoted, _out(AMOUNT, 500, 0));
        _fund(address(weth), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, quoted, AMOUNT * 9996 / 10_000)
        );
        adapter.swap(address(weth), address(base), AMOUNT, 4, "");

        (uint256 out, uint256 spot) = adapter.swap(address(weth), address(base), AMOUNT, 10, "");
        assertEq(out, quoted, "a maximum the honest tier meets sells there");
        assertEq(spot, AMOUNT);
        _assertNothingKept(address(weth));
    }

    /// @dev Open for the founder (review round 3): when the sale is larger than every honest tier can fill (here each
    ///      takes one unit less), the same tier below the market is the only one that fills. It is chosen, meets the
    ///      maximum against its own mid, and buys the input at a quarter of its value.
    function test_DEC153_whenNoHonestTierFillsATierBelowTheMarketIsTheOnlyRoute() public {
        uint256 trapOut = _tierBelowTheMarket().out(address(weth), AMOUNT);
        for (uint256 i = 1; i < 4; ++i) {
            wethBase[i].setFillableIn(AMOUNT - 1);
        }
        (uint24 fee, uint256 quoted) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 100, "the only tier that fills");
        assertEq(quoted, trapOut);
        (uint256 out, uint256 spot) = _swap(address(weth), address(base), AMOUNT, 4, "");
        assertEq(out, trapOut, "a quarter of the market");
        assertEq(spot, AMOUNT / 4, "measured against its own mid");
    }

    /// @dev Open for the founder (review round 2): without a maximum the same trap wins on output and the fund receives
    ///      more than any honest tier pays, but `spotOut` is the trap's own mid, so the sale reports a loss it did not
    ///      have. Until the founder rules, a vault must not charge a cost measured against the `spotOut` of an
    ///      empty-route sale without a maximum.
    function test_DEC153_withoutAMaximumAThirdPartyTierStillSetsSpotOut() public {
        uint256 trapOut = _trapTier().out(address(weth), AMOUNT);
        (uint24 fee,) = adapter.bestDirectFee(address(weth), address(base), AMOUNT);
        assertEq(fee, 10_000);
        (uint256 out, uint256 spot) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, trapOut, "more than any honest tier pays");
        assertEq(spot, 4 * AMOUNT, "but valued at the trap's own mid");
    }

    /// @dev D-21: a griefed tier (an empty or dust pool whose quote walks the tick bitmap) costs at most the cap, the
    ///      other tiers still compete, and the swap completes.
    function test_DEC153_aGriefedTierCostsAtMostTheQuoteGasCap() public {
        wethBase[0].setImpactBps(0);
        wethBase[0].setMode(MockV3Pool.Mode.QuoteBurnsGas);
        _fund(address(weth), AMOUNT);
        uint256 g = gasleft();
        (uint256 out,) = adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        uint256 used = g - gasleft();
        console2.log("swap gas with a griefed tier", used);
        assertEq(out, _out(AMOUNT, 500, 0), "the 0.05% tier filled");
        assertGt(used, adapter.QUOTE_GAS_CAP(), "the griefed quote burned its cap");
        assertLt(used, adapter.QUOTE_GAS_CAP() + 600_000, "and no more");
    }

    /// @dev DEC-153 accepted consequence: a pair without a direct V3 pool has no route without the API.
    function test_DEC153_aPairWithoutADirectPoolHasNoRoute() public {
        _fund(address(stock), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NoRoute.selector, address(stock), address(usdt)));
        adapter.swap(address(stock), address(usdt), AMOUNT, NO_MAX, "");
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NoRoute.selector, address(stock), address(usdt)));
        adapter.bestDirectFee(address(stock), address(usdt), AMOUNT);
    }

    function test_DEC153_noTierQuotingIsNoRoute() public {
        for (uint256 i; i < 4; ++i) {
            wethBase[i].setMode(MockV3Pool.Mode.QuoteReverts);
        }
        _fund(address(weth), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NoRoute.selector, address(weth), address(base)));
        adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-140, DEC-142: the caller's optional maximum loss against the pre-trade mid value
    // ------------------------------------------------------------------------------------------------------------

    /// @dev The maximum counts the pool fee: 4 bps cannot pass the 0.05% pool, 5 bps can.
    function test_DEC142_maximumLossCountsThePoolFee() public {
        _fund(address(weth), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISwapAdapter.InsufficientOutput.selector, _out(AMOUNT, 500, 0), AMOUNT * 9996 / 10_000
            )
        );
        adapter.swap(address(weth), address(base), AMOUNT, 4, "");
        (uint256 out,) = adapter.swap(address(weth), address(base), AMOUNT, 5, "");
        assertEq(out, _out(AMOUNT, 500, 0));
    }

    /// @dev D-23: 0 and anything from 10,000 up mean "no maximum"; 1 to 9,999 bind. Every tier loses half to price
    ///      impact here, so the 0.01% tier (the lowest fee) is the best.
    function test_D23_zeroOrFullBpsMeanNoMaximum() public {
        for (uint256 i; i < 4; ++i) {
            wethBase[i].setImpactBps(5000);
        }
        uint256 expected = _out(AMOUNT, 100, 5000);
        uint16[3] memory none = [uint16(0), 10_000, type(uint16).max];
        for (uint256 i; i < 3; ++i) {
            (uint256 out,) = _swap(address(weth), address(base), AMOUNT, none[i], "");
            assertEq(out, expected, "sold at whatever price (DEC-132 item 2)");
        }
        _fund(address(weth), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, expected, AMOUNT / 2));
        adapter.swap(address(weth), address(base), AMOUNT, 5000, "");
        (uint256 passed,) = adapter.swap(address(weth), address(base), AMOUNT, 5001, "");
        assertEq(passed, expected);
    }

    function testFuzz_DEC142_maximumLossBoundsTheOutput(uint16 maxLossBps, uint16 impactBps) public {
        impactBps = uint16(bound(impactBps, 0, 9999));
        for (uint256 i; i < 4; ++i) {
            wethBase[i].setImpactBps(impactBps);
        }
        uint256 expected = _out(AMOUNT, 100, impactBps);
        _fund(address(weth), AMOUNT);
        bool bounded = maxLossBps != 0 && maxLossBps < 10_000;
        uint256 minOut = bounded ? AMOUNT * (10_000 - maxLossBps) / 10_000 : 0;
        if (expected < minOut) {
            vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, expected, minOut));
            adapter.swap(address(weth), address(base), AMOUNT, maxLossBps, "");
        } else {
            (uint256 out, uint256 spot) = adapter.swap(address(weth), address(base), AMOUNT, maxLossBps, "");
            assertEq(out, expected);
            assertEq(spot, AMOUNT);
            assertGe(out, minOut);
            _assertNothingKept(address(weth));
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // DEC-118, D-19, D-20: spotOut is the mid value before the trade
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC118_spotValueIsTheMidPriceInBothDirections() public {
        // Price 4: one token0 is worth four token1.
        MockV3Pool pool = factory.createPool(address(stock), address(usdt), 500, uint160(1 << 97), LIQUIDITY);
        (address t0, address t1) = (pool.token0(), pool.token1());
        assertEq(adapter.spotValue(t0, t1, AMOUNT, 500), AMOUNT * 4);
        assertEq(adapter.spotValue(t1, t0, AMOUNT, 500), AMOUNT / 4);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.PoolNotFound.selector, t0, t1, uint24(3000)));
        adapter.spotValue(t0, t1, AMOUNT, 3000);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.InvalidFee.selector, uint24(2500)));
        adapter.spotValue(t0, t1, AMOUNT, 2500);
    }

    /// @dev `_atSpot` squares the price in 256 bits up to 2^128 and drops 64 bits first above it. Over the whole V3
    ///      range, in both directions, the first branch is exact and the second within 1 wei of the exact floor (the
    ///      mock pool's `mid`, which never squares the price).
    function testFuzz_DEC118_spotValueHoldsOverTheWholePriceRange(uint160 sqrtPriceX96, uint256 amount) public {
        sqrtPriceX96 = uint160(bound(sqrtPriceX96, quoter.MIN_SQRT_RATIO(), quoter.MAX_SQRT_RATIO() - 1));
        amount = bound(amount, 1, (1 << 96) - 1);
        _assertSpotValueMatchesTheMid(sqrtPriceX96, amount);
    }

    /// @dev Both ends of the range and both sides of the 2^128 switch.
    function test_DEC118_spotValueAtTheEdgesOfThePriceRange() public {
        uint160[6] memory prices = [
            quoter.MIN_SQRT_RATIO(),
            uint160(1 << 96),
            type(uint128).max,
            uint160(1) << 128,
            (uint160(1) << 128) + 1,
            quoter.MAX_SQRT_RATIO() - 1
        ];
        for (uint256 i; i < prices.length; ++i) {
            _assertSpotValueMatchesTheMid(prices[i], 1);
            _assertSpotValueMatchesTheMid(prices[i], AMOUNT);
            _assertSpotValueMatchesTheMid(prices[i], (1 << 96) - 1);
        }
    }

    /// @dev Anyone can create a factory pool without initializing it (`sqrtPriceX96 == 0`). It has no mid value: the
    ///      read reverts in both directions instead of returning 0 one way and dividing by zero the other.
    function test_DEC118_anUninitializedPoolHasNoSpotValue() public {
        MockV3Pool pool = factory.createPool(address(stock), address(usdt), 3000, 0, 0);
        (address t0, address t1) = (pool.token0(), pool.token1());
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.PoolNotFound.selector, t0, t1, uint24(3000)));
        adapter.spotValue(t0, t1, AMOUNT, 3000);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.PoolNotFound.selector, t1, t0, uint24(3000)));
        adapter.spotValue(t1, t0, AMOUNT, 3000);
        _fund(address(stock), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapAdapter.PoolNotFound.selector, address(stock), address(usdt), uint24(3000))
        );
        adapter.swapDirect(address(stock), address(usdt), AMOUNT, 3000, NO_MAX);
    }

    /// @dev The pool's mid price moves after a swap; `spotOut` is the price read before it.
    function test_DEC118_spotOutIsReadBeforeTheTrade() public {
        wethBase[1].setDriftBps(100);
        (, uint256 spot) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(spot, AMOUNT, "pre-trade mid value");
        assertLt(adapter.spotValue(address(weth), address(base), AMOUNT, 500), AMOUNT, "the trade moved the price");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Custody
    // ------------------------------------------------------------------------------------------------------------

    function test_custodyPullsExactlyTheInputAndKeepsNothing() public {
        weth.mint(address(this), 1e18);
        (uint256 out,) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(weth.balanceOf(address(this)), 1e18, "only amountIn left the vault");
        assertEq(base.balanceOf(address(this)), out);
        _assertNothingKept(address(weth));
    }

    function test_custodyNeedsTheVaultApproval() public {
        weth.mint(address(this), AMOUNT);
        weth.approve(address(adapter), AMOUNT - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector, address(adapter), AMOUNT - 1, AMOUNT
            )
        );
        adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
    }

    /// @dev A fill that stops before spending the whole input (a price limit) reverts; nothing moves.
    function test_custodyRevertsOnAPartialFill() public {
        router.setPartialBps(1);
        _fund(address(weth), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.PartialFill.selector, 0, AMOUNT / 10_000));
        adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(weth.balanceOf(address(this)), AMOUNT);
    }

    /// @dev A donation to the adapter neither blocks a swap nor is spent by it.
    function test_custodyADonationNeitherBlocksNorFundsASwap() public {
        weth.mint(address(adapter), 5);
        (uint256 out,) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, _out(AMOUNT, 500, 0));
        assertEq(weth.balanceOf(address(adapter)), 5, "the donation stays where it was");
    }

    // ------------------------------------------------------------------------------------------------------------
    // Access, tokens and the guard (DEC-056, DEC-058, DEC-136 item 2)
    // ------------------------------------------------------------------------------------------------------------

    function test_DEC136_onlyTheVaultSwaps() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NotVault.selector, stranger));
        adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.NotVault.selector, stranger));
        adapter.swapDirect(address(weth), address(base), AMOUNT, 500, NO_MAX);
        vm.stopPrank();
    }

    function test_DEC136_onlyMandateTokensAndDistinctNonZeroInputs() public {
        bytes4 notInMandate = ISwapAdapter.TokenNotInMandate.selector;
        vm.expectRevert(abi.encodeWithSelector(notInMandate, address(outsider)));
        adapter.swap(address(outsider), address(base), AMOUNT, NO_MAX, "");
        vm.expectRevert(abi.encodeWithSelector(notInMandate, address(outsider)));
        adapter.swap(address(weth), address(outsider), AMOUNT, NO_MAX, "");
        vm.expectRevert(abi.encodeWithSelector(notInMandate, address(outsider)));
        adapter.swapDirect(address(outsider), address(base), AMOUNT, 500, NO_MAX);
        vm.expectRevert(abi.encodeWithSelector(notInMandate, address(outsider)));
        adapter.bestDirectFee(address(outsider), address(base), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(notInMandate, address(outsider)));
        adapter.spotValue(address(base), address(outsider), AMOUNT, 500);

        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.IdenticalTokens.selector, address(weth)));
        adapter.swap(address(weth), address(weth), AMOUNT, NO_MAX, "");
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.IdenticalTokens.selector, address(weth)));
        adapter.bestDirectFee(address(weth), address(weth), AMOUNT);

        vm.expectRevert(ISwapAdapter.ZeroAmount.selector);
        adapter.swap(address(weth), address(base), 0, NO_MAX, "");
        vm.expectRevert(ISwapAdapter.ZeroAmount.selector);
        adapter.swapDirect(address(weth), address(base), 0, 500, NO_MAX);
        vm.expectRevert(ISwapAdapter.ZeroAmount.selector);
        adapter.bestDirectFee(address(weth), address(base), 0);
    }

    /// @dev DEC-056: pause is a quarantine of entries. A swap out of the base token (or between two non-base tokens)
    ///      is an entry; a sale into the base token is the exit and always passes.
    function test_DEC056_pauseBlocksEntriesNeverSalesIntoTheBaseToken() public {
        factory.createPool(address(weth), address(stock), 500, PRICE_ONE, LIQUIDITY);
        vm.prank(guardian);
        adapter.setPaused(true);

        _fund(address(base), AMOUNT);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.swap(address(base), address(weth), AMOUNT, NO_MAX, "");
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.swapDirect(address(base), address(weth), AMOUNT, 500, NO_MAX);
        _fund(address(weth), AMOUNT);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.swap(address(weth), address(stock), AMOUNT, NO_MAX, "");

        (uint256 out,) = adapter.swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertGt(out, 0, "exit open while paused");
        (out,) = _directSwap(address(stock), address(base), AMOUNT, 500);
        assertGt(out, 0, "swapDirect exit open while paused");
    }

    /// @dev DEC-058: a deprecated adapter is withdraw-only: only sales into the base token run.
    function test_DEC058_deprecationKeepsOnlyTheExit() public {
        vm.prank(guardian);
        adapter.deprecate();
        _fund(address(base), AMOUNT);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        adapter.swap(address(base), address(weth), AMOUNT, NO_MAX, "");
        (uint256 out,) = _swap(address(weth), address(base), AMOUNT, NO_MAX, "");
        assertEq(out, _out(AMOUNT, 500, 0), "exit open after deprecation");
    }

    // ------------------------------------------------------------------------------------------------------------
    // swapDirect (D-21): the vault's own libraries reuse a tier bestDirectFee chose
    // ------------------------------------------------------------------------------------------------------------

    function test_D21_swapDirectUsesTheGivenTier() public {
        _fund(address(weth), AMOUNT);
        vm.expectEmit(address(adapter));
        emit ISwapAdapter.Swapped(address(weth), address(base), AMOUNT, _out(AMOUNT, 3000, 0), AMOUNT, 3000, bytes32(0));
        (uint256 out, uint256 spot) = adapter.swapDirect(address(weth), address(base), AMOUNT, 3000, NO_MAX);
        assertEq(out, _out(AMOUNT, 3000, 0));
        assertEq(spot, AMOUNT);
        assertEq(quoter.quotes(address(wethBase[2])), 0, "no quote: the tier was chosen before");
        _assertNothingKept(address(weth));
    }

    function test_D21_swapDirectAppliesTheMaximumLoss() public {
        _fund(address(weth), AMOUNT);
        vm.expectPartialRevert(ISwapAdapter.InsufficientOutput.selector);
        adapter.swapDirect(address(weth), address(base), AMOUNT, 3000, 29);
        (uint256 out,) = adapter.swapDirect(address(weth), address(base), AMOUNT, 3000, 30);
        assertEq(out, _out(AMOUNT, 3000, 0));
    }

    function test_D21_swapDirectRejectsNonTiersAndMissingPools() public {
        _fund(address(weth), AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(ISwapAdapter.InvalidFee.selector, uint24(2500)));
        adapter.swapDirect(address(weth), address(base), AMOUNT, 2500, NO_MAX);
        _fund(address(stock), AMOUNT);
        vm.expectRevert(
            abi.encodeWithSelector(ISwapAdapter.PoolNotFound.selector, address(stock), address(base), uint24(3000))
        );
        adapter.swapDirect(address(stock), address(base), AMOUNT, 3000, NO_MAX);
    }

    function _directSwap(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        internal
        returns (uint256, uint256)
    {
        _fund(tokenIn, amountIn);
        return adapter.swapDirect(tokenIn, tokenOut, amountIn, fee, NO_MAX);
    }

    function _assertSpotValueMatchesTheMid(uint160 sqrtPriceX96, uint256 amount) internal {
        MockV3Pool pool = factory.createPool(address(stock), address(usdt), 3000, sqrtPriceX96, LIQUIDITY);
        (address t0, address t1) = (pool.token0(), pool.token1());
        uint256 forward = adapter.spotValue(t0, t1, amount, 3000);
        uint256 backward = adapter.spotValue(t1, t0, amount, 3000);
        if (sqrtPriceX96 <= type(uint128).max) {
            assertEq(forward, pool.mid(t0, amount), "token0 -> token1, exact");
            assertEq(backward, pool.mid(t1, amount), "token1 -> token0, exact");
        } else {
            // The price drops below its exact value: token0 is worth at most 1 wei less, token1 at most 1 wei more.
            assertLe(forward, pool.mid(t0, amount), "token0 -> token1, never above");
            assertGe(forward + 1, pool.mid(t0, amount), "token0 -> token1, within 1 wei");
            assertGe(backward, pool.mid(t1, amount), "token1 -> token0, never below");
            assertLe(backward, pool.mid(t1, amount) + 1, "token1 -> token0, within 1 wei");
        }
    }

    /// @dev A third party's tier (review round 2): replaces the 1% WETH/base pool with one at a mid price four times the
    ///      market's (a quarter when WETH is token1) whose quote, after 74% of price impact, beats every honest tier.
    function _trapTier() internal returns (MockV3Pool trap) {
        uint160 sqrtPriceX96 = address(weth) < address(base) ? uint160(1 << 97) : uint160(1 << 95);
        trap = factory.createPool(address(weth), address(base), 10_000, sqrtPriceX96, LIQUIDITY);
        trap.setImpactBps(7400);
    }

    /// @dev A third party's tier below the market (review round 3): replaces the 0.01% WETH/base pool with one at a
    ///      quarter of the market's mid price (four times when WETH is token1) and no price impact, so it loses only its
    ///      fee against its own mid.
    function _tierBelowTheMarket() internal returns (MockV3Pool trap) {
        uint160 sqrtPriceX96 = address(weth) < address(base) ? uint160(1 << 95) : uint160(1 << 97);
        trap = factory.createPool(address(weth), address(base), 100, sqrtPriceX96, LIQUIDITY);
    }

    /// @dev QuoterV2's price limit when it is given none: one inside the end of the range the price moves towards.
    function _limit(address tokenIn, address tokenOut) internal view returns (uint160) {
        return tokenIn < tokenOut ? quoter.MIN_SQRT_RATIO() + 1 : quoter.MAX_SQRT_RATIO() - 1;
    }
}
