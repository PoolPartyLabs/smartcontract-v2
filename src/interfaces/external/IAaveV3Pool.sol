// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAaveV3Pool
/// @notice Minimal vendored subset of the Aave V3 Pool used by the Aave V3 Adapter: supply, withdraw and the two reads
///         the Exact-Value Position ledger needs (DEC-068). Borrowing is deliberately absent (DEC-018, DEC-028).
/// @dev Source: aave-dao/aave-v3-origin `IPool.sol` and `DataTypes.sol`. Verified on 2026-09-29 against the live Pool on
///      Arbitrum One (0x794a61358D6845594F94dc1DB02A252b5b4814aD, `POOL_REVISION()` = 11): `getReserveData` still returns
///      the 15-word legacy layout below. Field names follow the upstream ones except where the glossary forbids a word
///      in identifiers; ABI decoding is positional, so a renamed field decodes the same word.
interface IAaveV3Pool {
    /// @notice Reserve state as returned by `getReserveData` (upstream `DataTypes.ReserveDataLegacy`).
    /// @param configuration Packed reserve configuration bitmap.
    /// @param liquidityIndex Supply index at `lastUpdateTimestamp`, in ray (1e27).
    /// @param currentLiquidityRate Current supply rate, in ray.
    /// @param variableBorrowIndex Variable borrow index, in ray.
    /// @param currentVariableBorrowRate Current variable borrow rate, in ray.
    /// @param currentStableBorrowRate Deprecated upstream (0 on the live USDC reserve); kept for the layout.
    /// @param lastUpdateTimestamp Last time the indexes were updated.
    /// @param id Reserve id.
    /// @param aTokenAddress The reserve's aToken.
    /// @param stableDebtTokenAddress Deprecated upstream; kept for the layout.
    /// @param variableDebtTokenAddress The reserve's variable debt token.
    /// @param interestRateStrategyAddress Interest rate strategy.
    /// @param reserveFactorShareToMint Upstream `accruedToTreasury` (renamed: glossary R2 and the Operating Cash entry
    ///        forbid both words in identifiers): scaled amount owed to Aave's own collector.
    /// @param unbacked Portal unbacked amount.
    /// @param isolationModeTotalDebt Isolation mode debt.
    struct ReserveData {
        uint256 configuration;
        uint128 liquidityIndex;
        uint128 currentLiquidityRate;
        uint128 variableBorrowIndex;
        uint128 currentVariableBorrowRate;
        uint128 currentStableBorrowRate;
        uint40 lastUpdateTimestamp;
        uint16 id;
        address aTokenAddress;
        address stableDebtTokenAddress;
        address variableDebtTokenAddress;
        address interestRateStrategyAddress;
        uint128 reserveFactorShareToMint;
        uint128 unbacked;
        uint128 isolationModeTotalDebt;
    }

    /// @notice Supplies `amount` of `asset`, pulled from `msg.sender`, and mints aTokens to `onBehalfOf`.
    /// @dev Reverts for a zero amount, an inactive, paused or frozen reserve, or above the supply cap.
    function supply(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) external;

    /// @notice Burns `msg.sender`'s aTokens and sends `amount` of `asset` to `to`. `type(uint256).max` withdraws the
    ///         caller's whole aToken balance.
    /// @dev Reverts when the reserve does not hold `amount` of available liquidity (underflow of the virtual balance or
    ///      of the aToken's underlying balance); it never pays less than asked. Reverts when the reserve is paused.
    /// @return The amount withdrawn.
    function withdraw(address asset, uint256 amount, address to) external returns (uint256);

    /// @notice Reserve state of `asset`.
    function getReserveData(address asset) external view returns (ReserveData memory);

    /// @notice The reserve's supply index as of the current block, in ray: `aToken.balanceOf(user)` is
    ///         `scaledBalanceOf(user)` times this index.
    function getReserveNormalizedIncome(address asset) external view returns (uint256);
}
