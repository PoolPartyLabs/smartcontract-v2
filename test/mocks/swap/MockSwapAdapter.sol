// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A Mandate swap adapter stand-in for fixtures that never swap: code at the address, so the Spoke Vault can
///         pin it (DEC-136, Q17-4). Tests of swaps use the real `UniswapV3SwapAdapter` over the V3 mocks.
contract MockSwapAdapter {}
