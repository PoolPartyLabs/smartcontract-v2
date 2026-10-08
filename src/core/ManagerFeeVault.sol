// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IManagerFeeVault} from "../interfaces/IManagerFeeVault.sol";

/// @title ManagerFeeVault
/// @notice The manager's portion of the fund's performance fees, per token. See IManagerFeeVault.
/// @dev Ruling 2026-09-29 (DEC-107, DEC-109): the Core Vault transfers the manager portion here at every collection.
///      Deployed by the Core Vault's constructor next to the ShareToken, so `fund` is always the Core Vault.
///      DEC-022, DEC-058: no proxy, no upgrade path, no selfdestruct; the only verb is the manager's `withdraw`.
contract ManagerFeeVault is IManagerFeeVault, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @inheritdoc IManagerFeeVault
    address public immutable fund;

    /// @inheritdoc IManagerFeeVault
    address public immutable manager;

    /// @param fund_ The fund's Core Vault.
    /// @param manager_ The fund's manager, from the Mandate (DEC-002).
    constructor(address fund_, address manager_) {
        if (fund_ == address(0) || manager_ == address(0)) revert ZeroAddress();
        fund = fund_;
        manager = manager_;
    }

    /// @inheritdoc IManagerFeeVault
    function balanceOf(address token) external view returns (uint256) {
        return IERC20(token).balanceOf(address(this));
    }

    /// @inheritdoc IManagerFeeVault
    /// @dev DEC-107: the fee is paid to the manager; the manager chooses where it lands.
    function withdraw(address token, address to, uint256 amount) external nonReentrant {
        if (msg.sender != manager) revert NotManager(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        emit ManagerFeeWithdrawn(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }
}
