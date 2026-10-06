pragma solidity 0.8.28;

import {ChainlinkPriceSource} from "./ChainlinkPriceSource.sol";
import {SolanaMandateV6} from "../mandate/SolanaMandateV6.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice Immutable Arbitrum USD feeds for native Solana assets (DEC-123, DEC-188, DEC-194).
/// @dev TSLAx raw units use the issuer multiplier before CLMM composition. The MVP permits only multiplier 1,
///      authenticated in the v6 report by the registry; a non-unit multiplier requires a new version.
contract SolanaPriceSourceV6 {
    struct NativeConfig {
        bytes32 stockMint;
        bytes32 wrappedSolMint;
        bytes32 usdcMint;
        uint32 stockMaxAge;
        uint32 solMaxAge;
        uint64 sessionOpen;
        uint64 sessionClose;
    }
    address public constant TSLA_USD = 0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3;
    address public constant SOL_USD = 0x24ceA4b8ce57cdA5058b924B9B9987992450590c;
    address public constant NVDA_USD = 0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F;
    bytes32 public constant NVDA_MINT = 0x07e8a50e140fda5791f4566a957fd3ae3f873e6a3466ffc13d79119dfa9ab50a;
    bytes32 public constant TSLA_MINT = 0x07e83582411fea1482f0994b80aa512a97c94f25df283bec5a67a381fc862b4a;
    bytes32 public constant WSOL_MINT = 0x069b8857feab8184fb687f634618c035dac439dc1aeb3b5598a0f00000000001;
    bytes32 public constant USDC_MINT = 0xc6fa7af3bedbad3a3d65f36aabc97431b1bbe4c2d2f6e0e47ca60203452f5d61;
    ChainlinkPriceSource public immutable underlying;
    address public immutable stockAccountingId;
    uint64 public immutable stockSessionOpen;
    uint64 public immutable stockSessionClose;

    error InvalidConfiguration();
    error StockMarketClosed();

    /// @dev TODO(decision): durable holiday/DST/calendar and off-hours exit valuation. Fail closed outside one
    ///      immutable, preflight-verified US regular session; timestamp freshness alone never opens the market.
    constructor(
        NativeConfig memory config,
        ChainlinkPriceSource.FeedConfig[] memory evmFeeds,
        ChainlinkPriceSource.FixedConfig[] memory evmFixed
    ) {
        if (
            block.chainid != 42_161 || config.stockMint != TSLA_MINT || config.wrappedSolMint != WSOL_MINT
                || config.usdcMint != USDC_MINT || config.sessionOpen == 0 || config.sessionClose <= config.sessionOpen
                || config.sessionClose - config.sessionOpen > 6 hours + 30 minutes
                || config.sessionOpen / 1 days != (config.sessionClose - 1) / 1 days
        ) revert InvalidConfiguration();
        uint256 weekday = (config.sessionOpen / 1 days + 4) % 7;
        if (
            weekday == 0 || weekday == 6 || config.sessionOpen % 1 days != 13 hours + 30 minutes
                || config.sessionClose % 1 days != 20 hours || config.sessionOpen < 1_791_293_400
                || config.sessionClose > 1_791_576_000
        ) revert InvalidConfiguration();
        stockAccountingId = SolanaMandateV6.accountingId(config.stockMint);
        stockSessionOpen = config.sessionOpen;
        stockSessionClose = config.sessionClose;
        ChainlinkPriceSource.FeedConfig[] memory feeds = new ChainlinkPriceSource.FeedConfig[](evmFeeds.length + 3);
        for (uint256 index; index < evmFeeds.length; ++index) {
            feeds[index] = evmFeeds[index];
        }
        feeds[evmFeeds.length] = ChainlinkPriceSource.FeedConfig(stockAccountingId, 8, TSLA_USD, config.stockMaxAge);
        feeds[evmFeeds.length + 1] = ChainlinkPriceSource.FeedConfig(
            SolanaMandateV6.accountingId(config.wrappedSolMint), 9, SOL_USD, config.solMaxAge
        );
        feeds[evmFeeds.length + 2] =
            ChainlinkPriceSource.FeedConfig(SolanaMandateV6.accountingId(NVDA_MINT), 8, NVDA_USD, config.stockMaxAge);
        ChainlinkPriceSource.FixedConfig[] memory fixedTokens =
            new ChainlinkPriceSource.FixedConfig[](evmFixed.length + 1);
        for (uint256 index; index < evmFixed.length; ++index) {
            fixedTokens[index] = evmFixed[index];
        }
        fixedTokens[evmFixed.length] =
            ChainlinkPriceSource.FixedConfig(SolanaMandateV6.accountingId(config.usdcMint), 6);
        underlying = new ChainlinkPriceSource(feeds, fixedTokens);
    }

    function priceInUsdc(address token) external view returns (uint256 price1e18, uint256 updatedAt) {
        return _price(token);
    }

    function usdcValue(address token, uint256 amount) external view returns (uint256 value, uint256 updatedAt) {
        (uint256 price, uint256 timestamp) = _price(token);
        return (Math.mulDiv(amount, price, 1e18), timestamp);
    }

    function maxPriceAge(address token) external view returns (uint256) {
        return underlying.maxPriceAge(token);
    }

    function nativePrice(bytes32 mint) external view returns (uint256 price1e18, uint256 updatedAt) {
        address identity = SolanaMandateV6.accountingId(mint);
        return _price(identity);
    }

    /// @dev DEC-198: exact binary effective multiplier, authenticated by the registry; changes fail closed.
    function _price(address token) private view returns (uint256 price, uint256 timestamp) {
        _checkSession(token);
        (price, timestamp) = underlying.priceInUsdc(token);
        if (token == SolanaMandateV6.accountingId(NVDA_MINT)) {
            price = Math.mulDiv(price, uint256(0x1006f7d589fea9), uint256(1) << 52);
        }
    }

    function _checkSession(address token) private view {
        uint256 nowTimestamp = block.timestamp;
        if (
            (token == stockAccountingId || token == SolanaMandateV6.accountingId(NVDA_MINT))
                && (nowTimestamp < stockSessionOpen || nowTimestamp >= stockSessionClose)
        ) {
            revert StockMarketClosed();
        }
    }
}
