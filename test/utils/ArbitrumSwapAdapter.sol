// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {UniswapV3SwapAdapter} from "../../src/adapters/UniswapV3SwapAdapter.sol";

/// @title ArbitrumSwapAdapter
/// @notice Deploys the real `UniswapV3SwapAdapter` on an Arbitrum One fork (DEC-136, DEC-153), for the fork fixtures
///         that build a hub Spoke Vault by hand instead of through the FundFactory.
/// @dev Addresses as in `script/FactoryDeployment.sol` (verified in test/fork/swap/V3Deployments.fork.t.sol).
library ArbitrumSwapAdapter {
    address internal constant V3_FACTORY = 0x1F98431c8aD98523631AE4a59f267346ea31F984;
    address internal constant SWAP_ROUTER02 = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;
    address internal constant QUOTER_V2 = 0x61fFE014bA17989E743c5F6cB21bF9697530B21e;

    /// @notice The swap adapter of the hub Spoke Vault at `vault`, with the fund's two Mandate tokens (USDC, the base
    ///         token, and WETH) and no route signer (DEC-052: every swap works without the API).
    function deploy(address vault, address guardian, address usdc, address weth)
        internal
        returns (UniswapV3SwapAdapter)
    {
        address[] memory tokens = new address[](2);
        (tokens[0], tokens[1]) = (usdc, weth);
        return new UniswapV3SwapAdapter(vault, guardian, usdc, tokens, V3_FACTORY, SWAP_ROUTER02, QUOTER_V2, address(0));
    }
}
