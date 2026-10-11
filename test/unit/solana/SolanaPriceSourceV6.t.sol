// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SolanaPriceSourceV6} from "../../../src/report/SolanaPriceSourceV6.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {SolanaMandateV6, SolanaSpokeRegistryV6} from "../../../src/mandate/SolanaMandateV6.sol";
import {ReportCodecV6} from "../../../src/libraries/ReportCodecV6.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MockAggregator} from "../../mocks/receiver/MockAggregator.sol";
import {SolanaFixture} from "./SolanaFixture.sol";

contract SolanaPriceSourceV6Test is Test {
    SolanaPriceSourceV6 private source;
    /// @dev Tue 2026-10-06 13:30 UTC, a US regular-session open.
    uint64 private constant WEEKDAY = 1_791_293_400;
    /// @dev Sat 2026-10-10 02:00 UTC: no US session; R9.1 prices it anyway.
    uint64 private constant SATURDAY = 1_791_597_600;
    /// @dev CR-12 deploy values: stock = 24 h heartbeat + 1 h, SOL tight.
    uint32 private constant STOCK_MAX_AGE = 90_000;
    uint32 private constant SOL_MAX_AGE = 7200;

    function setUp() public {
        vm.chainId(42_161);
        vm.warp(WEEKDAY);
        MockAggregator feed = new MockAggregator(8);
        vm.etch(0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3, address(feed).code);
        vm.etch(0x24ceA4b8ce57cdA5058b924B9B9987992450590c, address(feed).code);
        vm.etch(0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F, address(feed).code);
        MockAggregator(0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F).setDecimals(8);
        MockAggregator(0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F).set(240e8, WEEKDAY);
        MockAggregator(0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3).setDecimals(8);
        MockAggregator(0x24ceA4b8ce57cdA5058b924B9B9987992450590c).setDecimals(8);
        MockAggregator(0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3).set(380e8, WEEKDAY);
        MockAggregator(0x24ceA4b8ce57cdA5058b924B9B9987992450590c).set(120e8, WEEKDAY);
        source = _source(SolanaFixture.STOCK);
    }

    function _source(bytes32 stockMint) private returns (SolanaPriceSourceV6) {
        return _source(stockMint, STOCK_MAX_AGE, SOL_MAX_AGE);
    }

    function _source(bytes32 stockMint, uint32 stockMaxAge, uint32 solMaxAge) private returns (SolanaPriceSourceV6) {
        return new SolanaPriceSourceV6(
            SolanaPriceSourceV6.NativeConfig(stockMint, SolanaFixture.SOL, SolanaFixture.USDC, stockMaxAge, solMaxAge),
            new ChainlinkPriceSource.FeedConfig[](0),
            new ChainlinkPriceSource.FixedConfig[](0)
        );
    }

    /// @dev CR-12: stock and SOL max ages are separate, non-zero and capped by the measured feed cadence.
    function testSeparateMaxAgesBoundedByMeasuredCadence() public {
        assertEq(source.MAX_STOCK_PRICE_AGE(), STOCK_MAX_AGE);
        assertEq(source.MAX_SOL_PRICE_AGE(), SOL_MAX_AGE);
        assertEq(source.maxPriceAge(SolanaMandateV6.accountingId(source.NVDA_MINT())), STOCK_MAX_AGE);
        assertEq(source.maxPriceAge(SolanaMandateV6.accountingId(SolanaFixture.SOL)), SOL_MAX_AGE);
        _source(SolanaFixture.STOCK, 3600, 600);
        bytes32 stock = SolanaFixture.STOCK;
        uint32[2][4] memory refused = [
            [uint32(0), SOL_MAX_AGE],
            [STOCK_MAX_AGE + 1, SOL_MAX_AGE],
            [STOCK_MAX_AGE, uint32(0)],
            [STOCK_MAX_AGE, SOL_MAX_AGE + 1]
        ];
        for (uint256 index; index < refused.length; ++index) {
            vm.expectRevert(SolanaPriceSourceV6.InvalidConfiguration.selector);
            _source(stock, refused[index][0], refused[index][1]);
        }
    }

    function _registry() private returns (SolanaSpokeRegistryV6) {
        return new SolanaSpokeRegistryV6(SolanaFixture.nativeConfig());
    }

    function testRawUnitStockSolAndUsdcValues() public view {
        (uint256 stockValue,) = source.usdcValue(SolanaMandateV6.accountingId(SolanaFixture.STOCK), 1e8);
        (uint256 solValue,) = source.usdcValue(SolanaMandateV6.accountingId(SolanaFixture.SOL), 1e9);
        (uint256 usdcValue,) = source.usdcValue(SolanaMandateV6.accountingId(SolanaFixture.USDC), 50e6);
        assertEq(stockValue, 380e6);
        assertEq(solValue, 120e6);
        assertEq(usdcValue, 50e6);
    }

    /// @dev DEC-198: the effective multiplier is applied exactly once, on every read path, at any hour (R9.1).
    function testNvdaValuesUseEffectiveMultiplierOnceAtAnyHour() public {
        (uint256 price,) = source.nativePrice(source.NVDA_MINT());
        assertEq(price, Math.mulDiv(240e16, 0x1006f7d589fea9, uint256(1) << 52));
        (uint256 value,) = source.usdcValue(SolanaMandateV6.accountingId(source.NVDA_MINT()), 1e8);
        assertEq(value, price / 1e10);
        (uint256 viaPriceInUsdc,) = source.priceInUsdc(SolanaMandateV6.accountingId(source.NVDA_MINT()));
        assertEq(viaPriceInUsdc, price);
        vm.warp(SATURDAY);
        MockAggregator(source.NVDA_USD()).set(240e8, SATURDAY);
        (uint256 weekendPrice, uint256 updatedAt) = source.nativePrice(source.NVDA_MINT());
        assertEq(weekendPrice, price);
        assertEq(updatedAt, SATURDAY);
    }

    function testNvdaRegistryRejectsChangedMissingOrPausedMultiplier() public {
        SolanaMandateV6.Config memory config = SolanaFixture.nativeConfig();
        config.assets[1] =
            SolanaMandateV6.Asset(source.NVDA_MINT(), SolanaMandateV6.accountingId(source.NVDA_MINT()), true);
        config.venues[0].token0 = source.NVDA_MINT();
        SolanaSpokeRegistryV6 registry = new SolanaSpokeRegistryV6(config);
        ReportCodecV6.MintState[] memory states = new ReportCodecV6.MintState[](1);
        states[0] = ReportCodecV6.MintState(
            source.NVDA_MINT(), 0x3ff003c2ac1bf43f, 0x3ff006f7d589fea9, 1_789_000_200, false, false, 0
        );
        registry.validateMintStates(states);
        states[0].newMultiplierBits = 0x3ff0000000000000;
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, source.NVDA_MINT()));
        registry.validateMintStates(states);
        states[0].newMultiplierBits = 0x3ff006f7d589fea9;
        states[0].paused = true;
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, source.NVDA_MINT()));
        registry.validateMintStates(states);
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, source.NVDA_MINT()));
        registry.validateMintStates(new ReportCodecV6.MintState[](0));
    }

    /// @dev R9.1: no market-hours gate. A fresh stock price is accepted on a weekend, before the US open and after
    ///      the US close; nothing about the hour reverts.
    function testPricesStockTwentyFourSeven() public {
        SolanaSpokeRegistryV6 registry = _registry();
        uint64[3] memory times = [SATURDAY, WEEKDAY - 1, WEEKDAY + 6 hours + 30 minutes];
        for (uint256 index; index < times.length; ++index) {
            vm.warp(times[index]);
            MockAggregator(source.TSLA_USD()).set(380e8, times[index]);
            (uint256 stockPrice, uint256 updatedAt) = source.nativePrice(SolanaFixture.STOCK);
            assertEq(stockPrice, 380e16);
            assertEq(updatedAt, times[index]);
            registry.requireStockPricing(address(source));
        }
    }

    /// @dev R9.1: staleness is the only time guard. At exactly `stockMaxAge` the price is live; one second later, an
    ///      incomplete round (`updatedAt == 0`) or a zero answer, share pricing fails closed. SOL is not a stock.
    function testStaleOrIncompleteStockRoundFailsClosed() public {
        SolanaSpokeRegistryV6 registry = _registry();
        address stockId = SolanaMandateV6.accountingId(SolanaFixture.STOCK);
        assertEq(source.maxPriceAge(stockId), STOCK_MAX_AGE);
        assertEq(source.maxPriceAge(SolanaMandateV6.accountingId(SolanaFixture.SOL)), SOL_MAX_AGE);
        vm.warp(SATURDAY);
        MockAggregator(source.TSLA_USD()).set(380e8, SATURDAY - STOCK_MAX_AGE);
        registry.requireStockPricing(address(source));
        vm.warp(SATURDAY + 1);
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK));
        registry.requireStockPricing(address(source));
        MockAggregator(source.TSLA_USD()).set(380e8, 0);
        vm.expectRevert(abi.encodeWithSelector(SolanaSpokeRegistryV6.UnsafeStockState.selector, SolanaFixture.STOCK));
        registry.requireStockPricing(address(source));
        MockAggregator(source.TSLA_USD()).set(0, SATURDAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, stockId));
        registry.requireStockPricing(address(source));
        MockAggregator(source.TSLA_USD()).set(380e8, SATURDAY + 1);
        registry.requireStockPricing(address(source));
        MockAggregator(source.SOL_USD()).set(120e8, 1);
        registry.requireStockPricing(address(source));
    }

    function testRefuseInvalidFeedAnswerAndDecimals() public {
        MockAggregator(source.TSLA_USD()).set(0, WEEKDAY);
        vm.expectRevert();
        source.nativePrice(SolanaFixture.STOCK);
        MockAggregator(source.TSLA_USD()).set(380e8, WEEKDAY);
        MockAggregator(source.TSLA_USD()).setDecimals(9);
        vm.expectRevert();
        source.nativePrice(SolanaFixture.STOCK);
    }

    function testRefuseWrongChainOrMint() public {
        bytes32 nvda = source.NVDA_MINT();
        vm.expectRevert(SolanaPriceSourceV6.InvalidConfiguration.selector);
        _source(nvda);
        vm.chainId(1);
        vm.expectRevert(SolanaPriceSourceV6.InvalidConfiguration.selector);
        _source(SolanaFixture.STOCK);
    }
}
