// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IPriceSource
/// @notice Prices tokens carried in spoke reports and hub positions into hub USDC, for Share Assets.
/// @dev OPEN (docs/ARCHITECTURE.md §5; Q57 (b), QB9, QA3): how spoke and hub positions are priced is not decided.
///      Decisions only say that no oracle prices the unwound part of a payout (DEC-032, DEC-081) and that the report
///      is read before the burn (DEC-081, DEC-105). Pricing sits behind this interface so the founder's answer slots
///      in. MVP working assumption: Chainlink for WETH on Arbitrum and 1:1 for USDG (QB9, OPEN).
/// @dev Scale: `price1e18` is the number of USDC base units (6 decimals) that ONE base unit of `token` is worth,
///      multiplied by 1e18. It is decimal-agnostic: `usdcValue = amount * price1e18 / 1e18`. Examples: WETH (18
///      decimals) at 2,500 USDC is 2,500e6 / 1e18 * 1e18 = 2.5e9; USDG (6 decimals) at 1:1 is 1e18; USDC is 1e18.
/// @dev Staleness: this interface does not revert on an old price; it returns `updatedAt` and the consumer decides.
///      MVP reading (Q57, OPEN): a mint reverts when a price is older than `maxPriceAge()`; the payout policy on a
///      stale price is OPEN.
interface IPriceSource {
    /// @notice The token has no configured price.
    error UnsupportedToken(address token);

    /// @notice The underlying feed returned an unusable answer (zero or negative).
    error InvalidPrice(address token);

    /// @notice Price of one base unit of `token` in USDC base units, scaled by 1e18, and when it was last updated.
    /// @dev Reverts with `UnsupportedToken` or `InvalidPrice`; never reverts because of age.
    function priceInUsdc(address token) external view returns (uint256 price1e18, uint256 updatedAt);

    /// @notice `amount` of `token` in USDC base units (rounded down) and the price's update time.
    function usdcValue(address token, uint256 amount) external view returns (uint256 value, uint256 updatedAt);

    /// @notice Age, in seconds, above which a consumer must treat a price as stale.
    function maxPriceAge() external view returns (uint256);
}
