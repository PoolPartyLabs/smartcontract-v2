// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAcrossMessageHandler} from "../../../src/interfaces/external/IAcrossMessageHandler.sol";

/// @notice Records the Across fill callback. Accepts it only from the configured SpokePool, as a vault must.
contract MockAcrossMessageHandler is IAcrossMessageHandler {
    error NotSpokePool(address caller);

    address public immutable spokePool;

    uint256 public calls;
    address public lastTokenSent;
    uint256 public lastAmount;
    address public lastRelayer;
    bytes public lastMessage;
    /// @dev Balance of `tokenSent` seen inside the callback: proves the tokens arrived before the call.
    uint256 public balanceAtCallback;

    constructor(address spokePool_) {
        spokePool = spokePool_;
    }

    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external {
        if (msg.sender != spokePool) revert NotSpokePool(msg.sender);
        ++calls;
        lastTokenSent = tokenSent;
        lastAmount = amount;
        lastRelayer = relayer;
        lastMessage = message;
        balanceAtCallback = IERC20(tokenSent).balanceOf(address(this));
    }
}
