// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAToken
/// @notice Minimal vendored subset of an Aave V3 aToken used by the Aave V3 Adapter.
/// @dev Source: aave-dao/aave-v3-origin `IScaledBalanceToken.sol` and `IERC20`. Verified on 2026-09-29 against
///      aArbUSDCn (0x724dc807b04555b71ed48a6896b6F41593b8C637) on Arbitrum One.
interface IAToken {
    /// @notice Balance of `user` in scaled units: the amount that does not grow with the supply index.
    function scaledBalanceOf(address user) external view returns (uint256);

    /// @notice Balance of `user` in asset units: `scaledBalanceOf(user)` times the current normalized income.
    function balanceOf(address user) external view returns (uint256);
}
