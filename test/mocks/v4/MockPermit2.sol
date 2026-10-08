// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal Permit2 AllowanceTransfer: per (owner, token, spender) amount and expiration, decremented on use.
contract MockPermit2 {
    using SafeERC20 for IERC20;

    struct Allowance {
        uint160 amount;
        uint48 expiration;
    }

    mapping(address owner => mapping(address token => mapping(address spender => Allowance))) internal _allowances;

    error AllowanceExpired(uint256 deadline);
    error InsufficientAllowance(uint256 amount);

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        _allowances[msg.sender][token][spender] =
            Allowance({amount: amount, expiration: expiration == 0 ? uint48(block.timestamp) : expiration});
    }

    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce)
    {
        Allowance memory a = _allowances[user][token][spender];
        return (a.amount, a.expiration, 0);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        Allowance storage a = _allowances[from][token][msg.sender];
        if (block.timestamp > a.expiration) revert AllowanceExpired(a.expiration);
        if (a.amount != type(uint160).max) {
            if (a.amount < amount) revert InsufficientAllowance(a.amount);
            a.amount -= amount;
        }
        IERC20(token).safeTransferFrom(from, to, amount);
    }
}
