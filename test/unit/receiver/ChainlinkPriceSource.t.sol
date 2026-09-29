// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ChainlinkPriceSource} from "../../../src/report/ChainlinkPriceSource.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {MockAggregator} from "../../mocks/receiver/MockAggregator.sol";

contract ChainlinkPriceSourceTest is Test {
    address internal constant WETH = address(0x0Bd7);
    address internal constant WBTC = address(0xB7C);
    address internal constant USDG = address(0x5fc5);
    address internal constant USDC = address(0xaf88);

    MockAggregator internal ethUsd;
    MockAggregator internal btcUsd;
    ChainlinkPriceSource internal source;

    function setUp() public {
        vm.warp(1_790_700_000);
        ethUsd = new MockAggregator(8);
        btcUsd = new MockAggregator(8);
        ethUsd.set(2500e8, block.timestamp - 60);
        btcUsd.set(60_000e8, block.timestamp - 10);
        source = new ChainlinkPriceSource(_feeds(), _fixed());
    }

    function _feeds() internal view returns (ChainlinkPriceSource.FeedConfig[] memory f) {
        f = new ChainlinkPriceSource.FeedConfig[](2);
        f[0] = ChainlinkPriceSource.FeedConfig({
            token: WETH, tokenDecimals: 18, aggregator: address(ethUsd), maxPriceAge: 3600
        });
        f[1] = ChainlinkPriceSource.FeedConfig({
            token: WBTC, tokenDecimals: 8, aggregator: address(btcUsd), maxPriceAge: 1800
        });
    }

    function _fixed() internal pure returns (address[] memory t) {
        t = new address[](2);
        t[0] = USDG;
        t[1] = USDC;
    }

    function test_Q57b_wethPricedPerBaseUnitFromChainlink() public view {
        (uint256 price, uint256 updatedAt) = source.priceInUsdc(WETH);
        assertEq(price, 2.5e9); // IPriceSource example: 2,500 USDC per WETH
        assertEq(updatedAt, block.timestamp - 60);
        (uint256 value,) = source.usdcValue(WETH, 1e18);
        assertEq(value, 2500e6);
        (value,) = source.usdcValue(WETH, 3e17);
        assertEq(value, 750e6);
    }

    function test_Q57b_eightDecimalTokenScalesCorrectly() public view {
        (uint256 price,) = source.priceInUsdc(WBTC);
        assertEq(price, 600e18); // one satoshi (1e-8 BTC) = 0.0006 USDC = 600 USDC base units
        (uint256 value,) = source.usdcValue(WBTC, 1e8);
        assertEq(value, 60_000e6);
    }

    function test_QB9_fixedTokensAreOneToOne() public view {
        (uint256 price, uint256 updatedAt) = source.priceInUsdc(USDG);
        assertEq(price, 1e18);
        assertEq(updatedAt, block.timestamp);
        (uint256 value,) = source.usdcValue(USDG, 1234e6);
        assertEq(value, 1234e6);
        assertTrue(source.isFixed(USDC));
        assertFalse(source.isFixed(WETH));
    }

    function test_OQ10_staleFeedStillPricesAndReportsItsAge() public {
        ethUsd.set(2400e8, block.timestamp - 10 days);
        (uint256 price, uint256 updatedAt) = source.priceInUsdc(WETH);
        assertEq(price, 2.4e9);
        assertEq(updatedAt, block.timestamp - 10 days);
    }

    function test_OQ10_maxPriceAgeIsTheStrictestFeedBound() public view {
        assertEq(source.maxPriceAge(), 1800);
        assertEq(source.maxPriceAgeOf(WETH), 3600);
        assertEq(source.maxPriceAgeOf(WBTC), 1800);
        assertEq(source.maxPriceAgeOf(USDG), 0);
        assertEq(source.aggregatorOf(WETH), address(ethUsd));
    }

    function test_OQ10_fixedOnlySourceHasZeroMaxPriceAge() public {
        ChainlinkPriceSource fixedOnly = new ChainlinkPriceSource(new ChainlinkPriceSource.FeedConfig[](0), _fixed());
        assertEq(fixedOnly.maxPriceAge(), 0);
    }

    function test_Q57b_revertsOnZeroOrNegativeAnswer() public {
        ethUsd.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, WETH));
        source.priceInUsdc(WETH);
        ethUsd.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, WETH));
        source.usdcValue(WETH, 1e18);
    }

    function test_Q57b_priceRoundingToZeroIsUnusable() public {
        ethUsd.set(99, block.timestamp); // 0.00000099 USD per ETH: below one USDC base unit per 1e18 wei
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.InvalidPrice.selector, WETH));
        source.priceInUsdc(WETH);
    }

    function test_Q57b_revertsOnUnsupportedToken() public {
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.UnsupportedToken.selector, address(0xDEAD)));
        source.priceInUsdc(address(0xDEAD));
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.UnsupportedToken.selector, address(0xDEAD)));
        source.maxPriceAgeOf(address(0xDEAD));
    }

    function test_Q57b_constructorRejectsBadConfig() public {
        ChainlinkPriceSource.FeedConfig[] memory f = _feeds();
        f[1].token = WETH;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceSource.DuplicateToken.selector, WETH));
        new ChainlinkPriceSource(f, _fixed());

        f = _feeds();
        f[0].maxPriceAge = 0;
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceSource.ZeroMaxPriceAge.selector, WETH));
        new ChainlinkPriceSource(f, _fixed());

        f = _feeds();
        f[0].aggregator = address(0);
        vm.expectRevert(ChainlinkPriceSource.ZeroAddress.selector);
        new ChainlinkPriceSource(f, _fixed());

        address[] memory t = _fixed();
        t[1] = WETH; // already a feed token
        vm.expectRevert(abi.encodeWithSelector(ChainlinkPriceSource.DuplicateToken.selector, WETH));
        new ChainlinkPriceSource(_feeds(), t);

        t[1] = address(0);
        vm.expectRevert(ChainlinkPriceSource.ZeroAddress.selector);
        new ChainlinkPriceSource(_feeds(), t);
    }

    function testFuzz_Q57b_usdcValueMatchesDirectFormula(uint256 amount, int256 answer) public {
        amount = bound(amount, 0, 1e30);
        answer = bound(answer, 100, 1e15); // below 100 the per-wei price rounds to zero (see next test)
        ethUsd.set(answer, block.timestamp);
        (uint256 value,) = source.usdcValue(WETH, amount);
        // IPriceSource scale: price1e18 = answer * 1e6 * 1e18 / (1e8 * 1e18), then value = amount * price1e18 / 1e18
        uint256 price1e18 = uint256(answer) / 100;
        assertEq(value, amount * price1e18 / 1e18);
    }
}
