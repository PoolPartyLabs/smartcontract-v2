// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {IChainlinkAggregatorV3} from "../interfaces/external/IChainlinkAggregatorV3.sol";

/// @title ChainlinkPriceSource
/// @notice Prices report and hub-position tokens into hub USDC from Chainlink feeds, with a list of tokens held at a
///         fixed 1:1. See IPriceSource.
/// @dev OPEN (Q57 (b), QB9, docs/ARCHITECTURE.md §5): the pricing rule is not decided. Founder ruling of 2026-09-29
///      (working assumption): Chainlink for WETH, 1:1 for USDG; adding a token is a new price source, never a Mandate
///      change. Hence no owner and no setter: every feed and fixed token is fixed at construction (DEC-022, DEC-058).
/// @dev The feeds are USD feeds read as USDC: USD and USDC are treated as 1:1, the same working assumption as the
///      fixed tokens (QB9 OPEN).
/// @dev Tokens are keyed by address and may be addresses on a Spoke Chain (a report carries the spoke's token
///      addresses), so token decimals are constructor input and never read from the token.
/// @dev OQ-10 (Q57): never reverts on age. It returns `updatedAt` and exposes `maxPriceAge()`; the consumer decides
///      (MVP: mints revert on a stale price, payouts use the last price).
contract ChainlinkPriceSource is IPriceSource {
    /// @notice Decimals of hub USDC, the unit every price is expressed in.
    uint8 public constant USDC_DECIMALS = 6;

    /// @notice Price of a fixed token: one base unit is worth one USDC base unit, scaled by 1e18 (QB9 OPEN).
    /// @dev Exact only for a token with USDC's 6 decimals (USDC, USDG); only such tokens may be listed as fixed.
    uint256 public constant FIXED_PRICE_1E18 = 1e18;

    /// @notice A Chainlink-priced token.
    /// @param token Token address as it appears in reports or hub positions.
    /// @param tokenDecimals Decimals of `token` on its own chain.
    /// @param aggregator Chainlink USD feed of the token's asset on the hub (WETH: ETH / USD).
    /// @param maxPriceAge Age in seconds above which a consumer must treat this feed's price as stale.
    struct FeedConfig {
        address token;
        uint8 tokenDecimals;
        address aggregator;
        uint32 maxPriceAge;
    }

    /// @notice Stored per-token configuration. `kind` 0 = unsupported, 1 = feed, 2 = fixed.
    struct Price {
        uint8 kind;
        address aggregator;
        uint32 maxPriceAge;
        uint256 scaleNumerator;
        uint256 scaleDenominator;
    }

    uint8 internal constant KIND_NONE = 0;
    uint8 internal constant KIND_FEED = 1;
    uint8 internal constant KIND_FIXED = 2;

    /// @notice A constructor token or aggregator is zero.
    error ZeroAddress();

    /// @notice A token is configured twice.
    error DuplicateToken(address token);

    /// @notice A feed has a zero max price age.
    error ZeroMaxPriceAge(address token);

    /// @notice Decimals too large to scale safely.
    error DecimalsTooLarge(address token, uint256 decimals);

    /// @inheritdoc IPriceSource
    /// @dev The strictest (smallest) `maxPriceAge` across the configured feeds, because the interface exposes one
    ///      bound for every token; 0 when only fixed tokens are configured (their `updatedAt` is always now).
    ///      `maxPriceAgeOf` gives the per-feed bound.
    uint256 public immutable maxPriceAge;

    mapping(address token => Price) internal _prices;

    /// @param feeds Chainlink-priced tokens.
    /// @param fixedTokens Tokens held at 1:1 with USDC, each with 6 decimals (USDC, USDG; QB9 OPEN).
    constructor(FeedConfig[] memory feeds, address[] memory fixedTokens) {
        uint256 strictest = type(uint256).max;
        for (uint256 i; i < feeds.length; ++i) {
            FeedConfig memory f = feeds[i];
            if (f.token == address(0) || f.aggregator == address(0)) revert ZeroAddress();
            if (f.maxPriceAge == 0) revert ZeroMaxPriceAge(f.token);
            if (_prices[f.token].kind != KIND_NONE) revert DuplicateToken(f.token);
            uint256 feedDecimals = IChainlinkAggregatorV3(f.aggregator).decimals();
            // price1e18 = answer * 10^USDC_DECIMALS * 1e18 / (10^feedDecimals * 10^tokenDecimals)
            uint256 denominatorDecimals = feedDecimals + f.tokenDecimals;
            if (denominatorDecimals > 60) revert DecimalsTooLarge(f.token, denominatorDecimals);
            _prices[f.token] = Price({
                kind: KIND_FEED,
                aggregator: f.aggregator,
                maxPriceAge: f.maxPriceAge,
                scaleNumerator: 10 ** (USDC_DECIMALS + 18),
                scaleDenominator: 10 ** denominatorDecimals
            });
            if (f.maxPriceAge < strictest) strictest = f.maxPriceAge;
        }
        for (uint256 i; i < fixedTokens.length; ++i) {
            address token = fixedTokens[i];
            if (token == address(0)) revert ZeroAddress();
            if (_prices[token].kind != KIND_NONE) revert DuplicateToken(token);
            _prices[token] = Price({
                kind: KIND_FIXED, aggregator: address(0), maxPriceAge: 0, scaleNumerator: 0, scaleDenominator: 0
            });
        }
        maxPriceAge = feeds.length == 0 ? 0 : strictest;
    }

    /// @inheritdoc IPriceSource
    /// @dev Reverts with `InvalidPrice` on a zero or negative answer; never on age (OQ-10). A fixed token returns
    ///      `FIXED_PRICE_1E18` with `updatedAt = block.timestamp`.
    function priceInUsdc(address token) public view returns (uint256 price1e18, uint256 updatedAt) {
        Price storage p = _prices[token];
        uint8 kind = p.kind;
        if (kind == KIND_FIXED) return (FIXED_PRICE_1E18, block.timestamp);
        if (kind == KIND_NONE) revert UnsupportedToken(token);
        int256 answer;
        (, answer,, updatedAt,) = IChainlinkAggregatorV3(p.aggregator).latestRoundData();
        if (answer <= 0) revert InvalidPrice(token);
        // casting to 'uint256' is safe because `answer` is strictly positive here
        // forge-lint: disable-next-line(unsafe-typecast)
        price1e18 = Math.mulDiv(uint256(answer), p.scaleNumerator, p.scaleDenominator);
        if (price1e18 == 0) revert InvalidPrice(token);
    }

    /// @inheritdoc IPriceSource
    function usdcValue(address token, uint256 amount) external view returns (uint256 value, uint256 updatedAt) {
        uint256 price1e18;
        (price1e18, updatedAt) = priceInUsdc(token);
        value = Math.mulDiv(amount, price1e18, 1e18);
    }

    /// @notice Max price age of `token`'s feed; 0 for a fixed token. Reverts with `UnsupportedToken` if unknown.
    function maxPriceAgeOf(address token) external view returns (uint256) {
        Price storage p = _prices[token];
        if (p.kind == KIND_NONE) revert UnsupportedToken(token);
        return p.maxPriceAge;
    }

    /// @notice Chainlink aggregator of `token`; zero for a fixed token. Reverts with `UnsupportedToken` if unknown.
    function aggregatorOf(address token) external view returns (address) {
        Price storage p = _prices[token];
        if (p.kind == KIND_NONE) revert UnsupportedToken(token);
        return p.aggregator;
    }

    /// @notice Whether `token` is held at a fixed 1:1 with USDC.
    function isFixed(address token) external view returns (bool) {
        return _prices[token].kind == KIND_FIXED;
    }
}
