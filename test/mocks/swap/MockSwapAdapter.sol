// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";

interface IMintableToken {
    function mint(address to, uint256 amount) external;
}

/// @notice Third-party code a swap runs between taking the input and paying the output.
interface IMidSwapHook {
    function onMidSwap() external;
}

/// @notice A Mandate swap adapter stand-in (DEC-136): code at an address the Spoke Vault can pin (Q17-4) and a swap at
///         a rate the test sets, with the custody of ISwapAdapter: it pulls exactly the input from the caller and pays
///         the whole output to it. `swapDirect` and `bestDirectFee` (one tier, `directFee`) serve the automatic
///         unwind's sales (DEC-136 item 4, D-21). Tests of the adapter's own rules (tiers, signed routes, the maximum loss against a
///         pool's mid) use the real `UniswapV3SwapAdapter` over the V3 mocks or on a fork.
/// @dev `spotOut` is the input at the pair's rate; the output is `spotOut` less `haircutBps` (fee and price impact).
///      `maxLossBps` is applied as the real adapter does (0 or >= 10,000: none, D-23) and the minimum is returned. The
///      output is paid from the mock's balance when it holds enough (a fork test `deal`s it) and minted otherwise (every
///      unit-test token is a mintable mock). Misbehaviours for the vault's custody checks: `pullBps` pulls only that
///      share of the input; `reportedExtra` reports more output than it pays. `midSwapHook`, when set, is called once
///      the input is taken and before the output is paid, as SwapRouter02 calls a hop token's `transfer` on an API
///      route through a token outside the Mandate (DEC-173).
contract MockSwapAdapter {
    using SafeERC20 for IERC20;

    struct Rate {
        uint256 numerator;
        uint256 denominator;
    }

    mapping(address tokenIn => mapping(address tokenOut => Rate)) public rates;
    uint256 public haircutBps;
    uint256 public pullBps = 10_000;
    uint256 public reportedExtra;
    address public midSwapHook;
    uint256 public calls;
    uint16 public lastMaxLossBps;
    bytes public lastRoute;

    /// @notice Sets the rate of `tokenA` in `tokenB` (`numerator` of `tokenB` per `denominator` of `tokenA`) and its
    ///         inverse.
    function setPrice(address tokenA, address tokenB, uint256 numerator, uint256 denominator) external {
        rates[tokenA][tokenB] = Rate(numerator, denominator);
        rates[tokenB][tokenA] = Rate(denominator, numerator);
    }

    function setHaircutBps(uint256 bps) external {
        haircutBps = bps;
    }

    function setPullBps(uint256 bps) external {
        pullBps = bps;
    }

    function setReportedExtra(uint256 amount) external {
        reportedExtra = amount;
    }

    function setMidSwapHook(address hook) external {
        midSwapHook = hook;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint16 maxLossBps, bytes calldata route)
        external
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut)
    {
        lastRoute = route;
        return _swap(tokenIn, tokenOut, amountIn, maxLossBps);
    }

    /// @notice The tier `bestDirectFee` reports (`directFee`, 0.05% by default) and the calls it got.
    uint24 public directFee = 500;
    uint256 public tierChoices;
    /// @notice The tier the last `swapDirect` was asked for.
    uint24 public lastFee;
    /// @notice When set, `bestDirectFee` reverts `NoRoute` (a pair without a direct V3 pool, DEC-153).
    bool public noRoute;

    function setDirectFee(uint24 fee) external {
        directFee = fee;
    }

    function setNoRoute(bool on) external {
        noRoute = on;
    }

    /// @notice ISwapAdapter.bestDirectFee: the mock's single tier and its output at the pair's rate after the haircut.
    function bestDirectFee(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint24 fee, uint256 quotedOut)
    {
        if (noRoute) revert ISwapAdapter.NoRoute(tokenIn, tokenOut);
        Rate memory r = rates[tokenIn][tokenOut];
        require(r.denominator != 0, "MockSwapAdapter: no rate");
        ++tierChoices;
        fee = directFee;
        quotedOut = amountIn * r.numerator / r.denominator * (10_000 - haircutBps) / 10_000;
    }

    /// @notice ISwapAdapter.swapDirect: the same swap as `swap` in the tier `fee`.
    function swapDirect(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint16 maxLossBps)
        external
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut)
    {
        lastFee = fee;
        return _swap(tokenIn, tokenOut, amountIn, maxLossBps);
    }

    function _swap(address tokenIn, address tokenOut, uint256 amountIn, uint16 maxLossBps)
        internal
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut)
    {
        if (tokenIn == tokenOut) revert ISwapAdapter.IdenticalTokens(tokenIn);
        Rate memory r = rates[tokenIn][tokenOut];
        require(r.denominator != 0, "MockSwapAdapter: no rate");
        calls++;
        lastMaxLossBps = maxLossBps;
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn * pullBps / 10_000);
        if (midSwapHook != address(0)) IMidSwapHook(midSwapHook).onMidSwap();
        spotOut = amountIn * r.numerator / r.denominator;
        amountOut = spotOut * (10_000 - haircutBps) / 10_000;
        if (maxLossBps != 0 && maxLossBps < 10_000) minOut = spotOut * (10_000 - maxLossBps) / 10_000;
        if (amountOut < minOut) revert ISwapAdapter.InsufficientOutput(amountOut, minOut);
        if (amountOut != 0) {
            if (IERC20(tokenOut).balanceOf(address(this)) >= amountOut) {
                IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
            } else {
                IMintableToken(tokenOut).mint(msg.sender, amountOut);
            }
        }
        amountOut += reportedExtra;
    }
}
