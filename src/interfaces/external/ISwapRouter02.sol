// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISwapRouter02
/// @notice Minimal vendored subset of Uniswap's SwapRouter02 used by the Uniswap V3 swap adapter: multi-hop exact input.
/// @dev Source: Uniswap swap-router-contracts v1.1.0, `contracts/interfaces/IV3SwapRouter.sol` (not a submodule of this
///      repository). Unlike the first V3 `SwapRouter`, the params carry no deadline. Verified on 2026-10-02 on both MVP
///      chains (SwapRouter02 `0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45` on Arbitrum One,
///      `0xCaf681a66D020601342297493863E78C959E5cb2` on Robinhood Chain): `factory()` is the chain's V3 factory, so every
///      pool a path reaches is derived from that factory (CREATE2) and authenticated in the swap callback. The old V3
///      `SwapRouter` address is a different, non-Uniswap contract on Robinhood Chain; only SwapRouter02 is used.
interface ISwapRouter02 {
    /// @param path Packed V3 path: token (20 bytes) | fee (3 bytes) | token | fee | token ...
    /// @param recipient Receiver of the last hop's output.
    /// @param amountIn Exact input, pulled from `msg.sender` for the first hop.
    /// @param amountOutMinimum Minimum output of the whole path.
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` along `path`; returns the output of the last hop.
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}
