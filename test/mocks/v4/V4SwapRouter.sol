// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @notice Test swap router on `PoolManager.unlock`, after v4-core's `PoolSwapTest`: the caller pays what it owes by
///         `transferFrom` and receives what it is owed. Used by the fork tests to generate fees in a real pool.
contract V4SwapRouter is IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96)
        external
        returns (BalanceDelta delta)
    {
        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
        });
        delta = abi.decode(manager.unlock(abi.encode(msg.sender, key, params)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (address payer, PoolKey memory key, IPoolManager.SwapParams memory params) =
            abi.decode(data, (address, PoolKey, IPoolManager.SwapParams));
        BalanceDelta delta = manager.swap(key, params, "");
        _resolve(key.currency0, delta.amount0(), payer);
        _resolve(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
    }

    function _resolve(Currency currency, int128 amount, address payer) private {
        if (amount < 0) {
            manager.sync(currency);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(payer, address(manager), uint256(uint128(-amount)));
            manager.settle();
        } else if (amount > 0) {
            manager.take(currency, payer, uint256(uint128(amount)));
        }
    }
}
