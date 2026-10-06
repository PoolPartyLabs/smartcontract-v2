pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaPriceSourceV6} from "../../../src/report/SolanaPriceSourceV6.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {SolanaMandateV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {MockAggregator} from "../../mocks/receiver/MockAggregator.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

contract SolanaPriceSourceV6Test is Test {
    SolanaPriceSourceV6 private source;
    uint64 private constant OPEN = 1_791_293_400;
    uint64 private constant CLOSE = 1_791_316_800;

    function setUp() public {
        vm.chainId(42_161);
        vm.warp(OPEN);
        MockAggregator feed = new MockAggregator(8);
        vm.etch(0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3, address(feed).code);
        vm.etch(0x24ceA4b8ce57cdA5058b924B9B9987992450590c, address(feed).code);
        MockAggregator(0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3).setDecimals(8);
        MockAggregator(0x24ceA4b8ce57cdA5058b924B9B9987992450590c).setDecimals(8);
        MockAggregator(0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3).set(380e8, OPEN);
        MockAggregator(0x24ceA4b8ce57cdA5058b924B9B9987992450590c).set(120e8, OPEN);
        source = _source(OPEN, CLOSE);
    }

    function _source(uint64 sessionOpen, uint64 sessionClose) private returns (SolanaPriceSourceV6) {
        return new SolanaPriceSourceV6(
            SolanaPriceSourceV6.NativeConfig(
                SolanaFixture.STOCK, SolanaFixture.SOL, SolanaFixture.USDC, 3600, 3600, sessionOpen, sessionClose
            ),
            new ChainlinkPriceSource.FeedConfig[](0),
            new ChainlinkPriceSource.FixedConfig[](0)
        );
    }

    function testRawUnitStockSolAndUsdcValues() public view {
        (uint256 stockValue,) = source.usdcValue(SolanaMandateV6.accountingId(SolanaFixture.STOCK), 1e8);
        (uint256 solValue,) = source.usdcValue(SolanaMandateV6.accountingId(SolanaFixture.SOL), 1e9);
        (uint256 usdcValue,) = source.usdcValue(SolanaMandateV6.accountingId(SolanaFixture.USDC), 50e6);
        assertEq(stockValue, 380e6);
        assertEq(solValue, 120e6);
        assertEq(usdcValue, 50e6);
    }

    function testRefuseStockOffHoursDespiteFreshTimestamp() public {
        vm.warp(CLOSE);
        MockAggregator(source.TSLA_USD()).set(380e8, CLOSE);
        vm.expectRevert(SolanaPriceSourceV6.StockMarketClosed.selector);
        source.nativePrice(SolanaFixture.STOCK);
        (uint256 solPrice,) = source.nativePrice(SolanaFixture.SOL);
        assertGt(solPrice, 0);
        vm.warp(OPEN - 1);
        vm.expectRevert(SolanaPriceSourceV6.StockMarketClosed.selector);
        source.nativePrice(SolanaFixture.STOCK);
    }

    function testRefuseInvalidFeedAnswerAndDecimals() public {
        MockAggregator(source.TSLA_USD()).set(0, OPEN);
        vm.expectRevert();
        source.nativePrice(SolanaFixture.STOCK);
        MockAggregator(source.TSLA_USD()).set(380e8, OPEN);
        MockAggregator(source.TSLA_USD()).setDecimals(9);
        vm.expectRevert();
        source.nativePrice(SolanaFixture.STOCK);
    }

    function testRefuseWeekendAndNonDemoSession() public {
        vm.expectRevert(SolanaPriceSourceV6.InvalidConfiguration.selector);
        _source(OPEN + 4 days, CLOSE + 4 days);
        vm.expectRevert(SolanaPriceSourceV6.InvalidConfiguration.selector);
        _source(OPEN + 7 days, CLOSE + 7 days);
    }
}
