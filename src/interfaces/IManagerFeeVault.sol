// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

/// @title IManagerFeeVault
/// @notice One per fund: holds the manager's portion of every performance fee, in the tokens the income was collected
///         in, until the manager withdraws it.
/// @dev Ruling 2026-09-29 (fee split point, DEC-107, DEC-109): at collection the manager portion goes into the
///      manager's own fee vault, the protocol portion to the Protocol Recipient and the net into the shareholders'
///      accumulator. DEC-109: paid in kind (several tokens), never in shares, no swap. DEC-022, DEC-058: no proxy, no
///      owner, no setter; fund and manager are fixed at construction.
/// @dev The Core Vault pushes tokens with a plain ERC-20 transfer; the vault has no deposit verb and keeps no ledger:
///      it is outside every value base of the fund (DEC-104), so its balance of a token is what the manager may take.
interface IManagerFeeVault {
    /// @notice The manager took `amount` of `token` out to `to`.
    event ManagerFeeWithdrawn(address indexed token, address indexed to, uint256 amount);

    /// @notice The caller is not the fund's manager.
    error NotManager(address caller);

    /// @notice A zero address was given.
    error ZeroAddress();

    /// @notice The fund's Core Vault, the only contract that pushes fees here.
    function fund() external view returns (address);

    /// @notice The fund's manager (DEC-002), the only caller of `withdraw` (DEC-107: the fee is the manager's).
    function manager() external view returns (address);

    /// @notice Balance of `token` held for the manager.
    function balanceOf(address token) external view returns (uint256);

    /// @notice Transfers `amount` of `token` to `to`. Manager only.
    function withdraw(address token, address to, uint256 amount) external;
}
