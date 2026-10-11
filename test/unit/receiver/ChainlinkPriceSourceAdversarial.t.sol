// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {MockAggregator} from "../../mocks/receiver/MockAggregator.sol";

/// @notice Aggregator that answers `decimals()` but reverts on every read.
contract RevertingAggregator {
    uint8 public constant decimals = 8;

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("feed down");
    }
}

/// @notice Adversarial verification of ChainlinkPriceSource: scaling across every decimals combination, answer
///         extremes, feed failures and the fixed-token decimals assumption.
contract ChainlinkPriceSourceAdversarialTest is Test {
    address internal constant TOKEN = address(0x70);

    function setUp() public {
        vm.warp(1_790_700_000);
    }

    function _source(uint8 feedDecimals, uint8 tokenDecimals, int256 answer)
        internal
        returns (ChainlinkPriceSource source, MockAggregator feed)
    {
        feed = new MockAggregator(feedDecimals);
        feed.set(answer, block.timestamp);
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](1);
        feeds[0] = ChainlinkPriceSource.FeedConfig({
            token: TOKEN, tokenDecimals: tokenDecimals, aggregator: address(feed), maxPriceAge: 3600
        });
        source = new ChainlinkPriceSource(feeds, new ChainlinkPriceSource.FixedConfig[](0));
    }

    /// @dev One whole token is worth `answer / 10^feedDecimals` USD, i.e. `answer * 1e6 / 10^feedDecimals` USDC base
    ///      units, for every (feed decimals, token decimals) pair; the per-base-unit representation loses at most one
    ///      USDC base unit on the whole-token value for tokens up to 18 decimals.
    function testFuzz_Q57b_wholeTokenValueMatchesFeedAcrossDecimals(
        uint8 feedDecimals,
        uint8 tokenDecimals,
        uint256 answer
    ) public {
        feedDecimals = uint8(bound(feedDecimals, 0, 18));
        tokenDecimals = uint8(bound(tokenDecimals, 0, 30));
        answer = bound(answer, 1e24, 1e36); // keeps the per-base-unit price above zero for every pair
        // Prices above MAX_PRICE are refused (CF-R2), see test_REVIEW_CFR2_priceAboveTheBoundIsRefused.
        vm.assume(answer * 1e24 / 10 ** (uint256(feedDecimals) + tokenDecimals) <= type(uint128).max);
        (ChainlinkPriceSource source,) = _source(feedDecimals, tokenDecimals, int256(answer));

        (uint256 value,) = source.usdcValue(TOKEN, 10 ** tokenDecimals);
        uint256 expected = answer * 1e6 / 10 ** feedDecimals;
        // The per-base-unit price is truncated at 1e18 precision, so a token with more than 18 decimals loses up to
        // 10^(decimals - 18) USDC base units on its whole-token value; up to 18 decimals the loss is at most one.
        uint256 tolerance = tokenDecimals > 18 ? 10 ** (tokenDecimals - 18) + 1 : 1;
        assertLe(value, expected);
        assertGe(value + tolerance, expected);
    }

    /// @dev Interface example: WETH (18) at 2,500 USD on an 8-decimals feed is 2.5e9 per base unit, exactly.
    function test_Q57b_interfaceExampleScalesExactly() public {
        (ChainlinkPriceSource source,) = _source(8, 18, 2500e8);
        (uint256 price,) = source.priceInUsdc(TOKEN);
        assertEq(price, 2.5e9);
        (uint256 value,) = source.usdcValue(TOKEN, 1e18);
        assertEq(value, 2500e6);
        // a feed with 18 decimals for the same asset gives the same price
        (ChainlinkPriceSource source18,) = _source(18, 18, 2500e18);
        (uint256 price18,) = source18.priceInUsdc(TOKEN);
        assertEq(price18, price);
    }

    /// @dev Any non-positive answer, down to type(int256).min, reverts with InvalidPrice and never underflows.
    function testFuzz_Q57b_nonPositiveAnswerAlwaysReverts(int256 answer) public {
        answer = bound(answer, type(int256).min, 0);
        (ChainlinkPriceSource source,) = _source(8, 18, answer);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, TOKEN));
        source.priceInUsdc(TOKEN);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, TOKEN));
        source.usdcValue(TOKEN, 1);
    }

    /// @dev Independent verification plan CF-R2: type(int256).max on an 8-decimals feed used to come back as a price of
    ///      5.8e74, which then overflowed the Core Vault's value sums inside every payout. A price above MAX_PRICE
    ///      (2^128) is refused, so a payout falls back to the last price instead; MAX_PRICE itself is accepted.
    function test_REVIEW_CFR2_priceAboveTheBoundIsRefused() public {
        (ChainlinkPriceSource source, MockAggregator feed) = _source(8, 18, type(int256).max);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, TOKEN));
        source.priceInUsdc(TOKEN);

        // price1e18 = answer * 1e24 / 1e26 = answer / 100 on an 8-decimals feed for an 18-decimals token.
        uint256 atBound = uint256(type(uint128).max) * 100;
        feed.set(int256(atBound), block.timestamp);
        (uint256 price,) = source.priceInUsdc(TOKEN);
        assertEq(price, type(uint128).max);
        feed.set(int256(atBound + 100), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, TOKEN));
        source.priceInUsdc(TOKEN);
    }

    /// @dev Independent verification plan CF-R3: the scale is fixed with the feed's decimals at construction; a feed
    ///      that now reports other decimals would misprice by a power of ten, so the read is refused.
    function test_REVIEW_CFR3_feedWhoseDecimalsChangedIsRefused() public {
        (ChainlinkPriceSource source, MockAggregator feed) = _source(8, 18, 2700e8);
        (uint256 price,) = source.priceInUsdc(TOKEN);
        assertEq(price, 2.7e9);
        feed.setDecimals(18);
        feed.set(2700e18, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, TOKEN));
        source.priceInUsdc(TOKEN);
    }

    /// @dev An `updatedAt` ahead of the chain's clock is a broken round, never a fresh one: refused.
    function test_REVIEW_CFR_futureUpdatedAtIsRefused() public {
        (ChainlinkPriceSource source, MockAggregator feed) = _source(8, 18, 2700e8);
        feed.set(2700e8, block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, TOKEN));
        source.priceInUsdc(TOKEN);
        feed.set(2700e8, block.timestamp);
        source.priceInUsdc(TOKEN);
    }

    /// @dev A feed that reverts at read time bubbles the revert: there is no silent fallback price (OQ-10 covers
    ///      age only, never a failed read).
    function test_OQ10_feedRevertBubblesUpNoFallback() public {
        RevertingAggregator feed = new RevertingAggregator();
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](1);
        feeds[0] = ChainlinkPriceSource.FeedConfig({
            token: TOKEN, tokenDecimals: 18, aggregator: address(feed), maxPriceAge: 1
        });
        ChainlinkPriceSource source = new ChainlinkPriceSource(feeds, new ChainlinkPriceSource.FixedConfig[](0));
        vm.expectRevert("feed down");
        source.priceInUsdc(TOKEN);
    }

    /// @dev An aggregator address without code (or without `decimals()`) cannot be configured.
    function test_Q57b_aggregatorWithoutCodeRejectedAtConstruction() public {
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](1);
        feeds[0] = ChainlinkPriceSource.FeedConfig({
            token: TOKEN, tokenDecimals: 18, aggregator: address(0xDEAD), maxPriceAge: 3600
        });
        vm.expectRevert();
        new ChainlinkPriceSource(feeds, new ChainlinkPriceSource.FixedConfig[](0));
    }

    /// @dev QB9 (verifier finding, fixed): a fixed token is configured with its decimals, so one whole 18-decimals
    ///      token listed as fixed is worth one whole USDC, not 1e12 of them.
    function test_QB9_fixedTokenHonoursItsDecimals() public {
        ChainlinkPriceSource.FixedConfig[] memory fixedTokens = new ChainlinkPriceSource.FixedConfig[](1);
        fixedTokens[0] = ChainlinkPriceSource.FixedConfig(TOKEN, 18);
        ChainlinkPriceSource source = new ChainlinkPriceSource(new ChainlinkPriceSource.FeedConfig[](0), fixedTokens);
        (uint256 value,) = source.usdcValue(TOKEN, 1e18); // one whole 18-decimals token
        assertEq(value, 1e6, "one USDC");
        (uint256 price,) = source.priceInUsdc(TOKEN);
        assertEq(price, 1e6);
    }
}
