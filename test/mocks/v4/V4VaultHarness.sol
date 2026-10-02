// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";

/// @notice Stand-in for the Spoke Vault: transfers the input tokens to the adapter, then calls the verb, exactly as
///         `ISpokeVault` describes the custody flow.
contract V4VaultHarness {
    using SafeERC20 for IERC20;

    IAdapter public adapter;
    /// @notice The vault's base token as `ISpokeVault.baseToken`; a deprecated adapter still swaps into it (S-10).
    address public baseToken;

    function setAdapter(IAdapter adapter_) external {
        adapter = adapter_;
    }

    function setBaseToken(address baseToken_) external {
        baseToken = baseToken_;
    }

    function open(bytes32 poolKey, address token0, uint256 amount0, address token1, uint256 amount1, bytes calldata p)
        external
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        _send(token0, amount0);
        _send(token1, amount1);
        return adapter.openPosition(poolKey, p);
    }

    function increase(
        bytes32 positionKey,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1,
        bytes calldata p
    ) external returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1) {
        _send(token0, amount0);
        _send(token1, amount1);
        return adapter.increasePosition(positionKey, p);
    }

    function decrease(bytes32 positionKey, bytes calldata p) external returns (IAdapter.Amounts memory) {
        return adapter.decreasePosition(positionKey, p);
    }

    function close(bytes32 positionKey, bytes calldata p) external returns (IAdapter.Amounts memory) {
        return adapter.closePosition(positionKey, p);
    }

    function collect(bytes32 positionKey) external returns (IAdapter.Amounts memory) {
        return adapter.collectIncome(positionKey);
    }

    function _send(address token, uint256 amount) private {
        if (amount != 0) IERC20(token).safeTransfer(address(adapter), amount);
    }
}
