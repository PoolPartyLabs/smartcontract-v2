// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAcrossMessageHandler} from "../../../src/interfaces/external/IAcrossMessageHandler.sol";
import {CoreMockToken} from "./CoreMockTokens.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";

/// @notice Across SpokePool stand-in: `depositV3` pulls the input from the caller; `refund` pays the depositor back;
///         `fill` delivers a token to a contract recipient and calls its `handleV3AcrossMessage` from this address.
contract MockAcrossSpokePool {
    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        uint32 fillDeadline;
        bytes message;
    }

    Deposit[] internal _deposits;
    /// @dev Test knob: pull this much less than `inputAmount` (a misbehaving target).
    uint256 public shortPull;

    function setShortPull(uint256 amount) external {
        shortPull = amount;
    }

    function numberOfDeposits() external view returns (uint32) {
        return uint32(_deposits.length);
    }

    function deposit(uint256 id) external view returns (Deposit memory) {
        return _deposits[id];
    }

    /// @notice `IAcrossSpokePool.depositV3`, decoded by hand: twelve parameters are too deep for the legacy pipeline.
    fallback() external {
        require(msg.sig == IAcrossSpokePool.depositV3.selector, "unknown selector");
        Deposit memory d;
        (d.depositor, d.recipient, d.inputToken, d.outputToken, d.inputAmount, d.outputAmount, d.destinationChainId) =
            abi.decode(msg.data[4:], (address, address, address, address, uint256, uint256, uint256));
        d.fillDeadline = abi.decode(msg.data[4 + 9 * 32:], (uint32));
        uint256 offset = abi.decode(msg.data[4 + 11 * 32:], (uint256));
        uint256 length = abi.decode(msg.data[4 + offset:], (uint256));
        d.message = msg.data[4 + offset + 32:4 + offset + 32 + length];
        IERC20(d.inputToken).transferFrom(msg.sender, address(this), d.inputAmount - shortPull);
        _deposits.push(d);
    }

    /// @notice Simulates the Across expiry refund of `id` to its depositor.
    function refund(uint256 id) external {
        Deposit memory d = _deposits[id];
        IERC20(d.inputToken).transfer(d.depositor, d.inputAmount);
    }

    /// @notice Simulates a fill on this chain: mints `amount` of `token` to `recipient`, then calls the handler.
    function fill(address recipient, address token, uint256 amount, bytes calldata message) external {
        CoreMockToken(token).mint(recipient, amount);
        IAcrossMessageHandler(recipient).handleV3AcrossMessage(token, amount, msg.sender, message);
    }
}
