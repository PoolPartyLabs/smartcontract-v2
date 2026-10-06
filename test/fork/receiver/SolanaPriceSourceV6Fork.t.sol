pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaPriceSourceV6} from "../../../src/report/SolanaPriceSourceV6.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {IChainlinkAggregatorV3} from "../../../src/interfaces/external/IChainlinkAggregatorV3.sol";
import {SolanaFixture} from "../../unit/solana/SolanaFixture.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Read-only Arbitrum fork; real TSLA and SOL feed proxies (DEC-194).
contract SolanaPriceSourceV6ForkTest is Test {
    SolanaPriceSourceV6 private source;

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), 512_239_244);
        source = new SolanaPriceSourceV6(
            SolanaPriceSourceV6.NativeConfig(
                SolanaFixture.STOCK, SolanaFixture.SOL, SolanaFixture.USDC, 3600, 3600, 1_791_293_400, 1_791_316_800
            ),
            new ChainlinkPriceSource.FeedConfig[](0),
            new ChainlinkPriceSource.FixedConfig[](0)
        );
    }

    function testRealTslaAndSolProxiesAndRawUnitScaling() public {
        _assertFeed(source.TSLA_USD(), SolanaFixture.STOCK, 1e8, "TSLA / USD");
        _assertFeed(source.SOL_USD(), SolanaFixture.SOL, 1e9, "SOL / USD");
    }

    function testRealNvdaFeedAndEffectiveBinaryMultiplier() public {
        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(source.NVDA_USD());
        assertGt(address(feed).code.length, 0);
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), "NVDA / USD");
        (uint80 round, int256 answer,, uint256 timestamp, uint80 answered) = feed.latestRoundData();
        assertGt(answer, 0);
        assertGe(answered, round);
        vm.warp(1_791_293_400);
        (uint256 price, uint256 updatedAt) = source.nativePrice(source.NVDA_MINT());
        assertEq(price, Math.mulDiv(uint256(answer) * 1e8, 0x1006f7d589fea9, uint256(1) << 52));
        assertEq(updatedAt, timestamp);
        bytes32 mint = source.NVDA_MINT();
        vm.warp(1_791_316_800);
        vm.expectRevert(SolanaPriceSourceV6.StockMarketClosed.selector);
        source.nativePrice(mint);
    }

    function _assertFeed(address proxy, bytes32 mint, uint256 oneToken, string memory description) private {
        IChainlinkAggregatorV3 feed = IChainlinkAggregatorV3(proxy);
        assertGt(proxy.code.length, 0);
        assertEq(feed.decimals(), 8);
        assertEq(feed.description(), description);
        (, int256 answer,, uint256 timestamp,) = feed.latestRoundData();
        assertGt(answer, 0);
        assertGt(timestamp, 0);
        vm.warp(1_791_293_400);
        (uint256 price, uint256 reportedTimestamp) = source.nativePrice(mint);
        assertEq(reportedTimestamp, timestamp);
        assertEq(price * oneToken / 1e18, uint256(answer) / 100);
    }
}
