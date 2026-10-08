// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";

/// @notice Freely mintable token for pools the fork tests create on the live V3 factory (a new pair, a griefed tier).
contract ForkToken is ERC20 {
    constructor(string memory symbol) ERC20(symbol, symbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Adds liquidity straight on a V3 pool (no position manager), paying in the mint callback.
contract DustMinter {
    function mint(IUniswapV3Pool pool, int24 lower, int24 upper, uint128 liquidity) external {
        pool.mint(address(this), lower, upper, liquidity, "");
    }

    function uniswapV3MintCallback(uint256 owed0, uint256 owed1, bytes calldata) external {
        IUniswapV3Pool pool = IUniswapV3Pool(msg.sender);
        if (owed0 != 0) ForkToken(pool.token0()).mint(msg.sender, owed0);
        if (owed1 != 0) ForkToken(pool.token1()).mint(msg.sender, owed1);
    }
}
