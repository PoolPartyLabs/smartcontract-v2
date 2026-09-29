// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ITransitEscrow} from "../interfaces/ITransitEscrow.sol";

/// @title TransitEscrow
/// @notice Minimal keyless depositor of record for one bridge transfer. See ITransitEscrow.
/// @dev Deliberately has no `receive`, no `fallback`, no EIP-1271 and no other function: nothing but the vault can
///      move value out, and nobody can sign for it (DEC-066).
contract TransitEscrow is ITransitEscrow {
    using SafeERC20 for IERC20;

    address public vault;
    address public token;

    /// @dev The implementation binds itself so it can never be initialized by a stranger; clones start unbound.
    constructor() {
        vault = address(this);
    }

    /// @inheritdoc ITransitEscrow
    /// @dev DEC-066: a zero `vault_` would leave `vault` unset, so anyone could initialize the clone again and become
    ///      the only address able to release a refund (Across verifier finding); a zero token cannot hold one.
    function initialize(address vault_, address token_) external {
        if (vault != address(0)) revert AlreadyInitialized();
        if (vault_ == address(0) || token_ == address(0)) revert ZeroAddress();
        vault = vault_;
        token = token_;
    }

    /// @inheritdoc ITransitEscrow
    function release(address to) external returns (uint256 amount) {
        if (msg.sender != vault) revert NotVault(msg.sender);
        amount = IERC20(token).balanceOf(address(this));
        if (amount != 0) IERC20(token).safeTransfer(to, amount);
    }
}
