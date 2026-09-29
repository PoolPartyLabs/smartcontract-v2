// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";

/// @notice ChainlinkPriceSource against the live Chainlink ETH / USD feed on Arbitrum One.
contract ChainlinkPriceSourceForkTest is Test {
    /// @dev Chainlink ETH / USD proxy on Arbitrum One. Verified on the pinned fork block (510044719): description()
    ///      "ETH / USD", decimals() 8, answer 269854786322 (2,698.54786322 USD), updatedAt 1790694712.
    address internal constant ARB_ETH_USD = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address internal constant ARB_WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    address internal constant ARB_USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant RH_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant RH_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint32 internal constant MAX_PRICE_AGE = 1 hours;

    ChainlinkPriceSource internal source;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](2);
        // Hub WETH and the Robinhood WETH carried in reports share the hub ETH / USD feed (Q57 (b) OPEN).
        feeds[0] = ChainlinkPriceSource.FeedConfig({
            token: ARB_WETH, tokenDecimals: 18, aggregator: ARB_ETH_USD, maxPriceAge: MAX_PRICE_AGE
        });
        feeds[1] = ChainlinkPriceSource.FeedConfig({
            token: RH_WETH, tokenDecimals: 18, aggregator: ARB_ETH_USD, maxPriceAge: MAX_PRICE_AGE
        });
        address[] memory fixedTokens = new address[](2);
        fixedTokens[0] = ARB_USDC;
        fixedTokens[1] = RH_USDG;
        source = new ChainlinkPriceSource(feeds, fixedTokens);
    }

    function test_Q57b_forkPricesWethFromLiveEthUsdFeed() public view {
        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(ARB_ETH_USD);
        assertEq(feed.description(), "ETH / USD");
        assertEq(feed.decimals(), 8);
        (, int256 answer,, uint256 feedUpdatedAt,) = feed.latestRoundData();

        (uint256 price, uint256 updatedAt) = source.priceInUsdc(ARB_WETH);
        assertEq(updatedAt, feedUpdatedAt);
        assertEq(price, uint256(answer) / 100); // answer * 1e6 * 1e18 / (1e8 * 1e18)
        assertGt(price, 500e6); // sanity: between 500 and 50,000 USDC per ETH
        assertLt(price, 50_000e6);
        assertLe(block.timestamp - updatedAt, MAX_PRICE_AGE);

        (uint256 value,) = source.usdcValue(ARB_WETH, 1e18);
        assertEq(value, price);
        (uint256 spokeValue,) = source.usdcValue(RH_WETH, 1e18);
        assertEq(spokeValue, value);
    }

    function test_QB9_forkFixedTokensAreOneToOne() public view {
        (uint256 value, uint256 updatedAt) = source.usdcValue(RH_USDG, 2500e6);
        assertEq(value, 2500e6);
        assertEq(updatedAt, block.timestamp);
        assertEq(source.maxPriceAge(), MAX_PRICE_AGE);
    }
}
