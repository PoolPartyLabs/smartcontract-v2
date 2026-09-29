// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAcrossMessageHandler} from "../../../src/interfaces/external/IAcrossMessageHandler.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";

/// @notice Across SpokePool mock: records `depositV3` calls, pulls the input amount from the caller, fills to a
///         recipient with its message, and refunds a depositor. `pullShortfall` makes a deposit pull less than asked.
contract MockAcrossSpokePool {
    using SafeERC20 for IERC20;

    struct Deposit {
        address depositor;
        address recipient;
        address inputToken;
        address outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 destinationChainId;
        address exclusiveRelayer;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    uint32 public numberOfDeposits;
    uint256 public pullShortfall;
    Deposit[] internal _deposits;
    address[] internal _callers;

    function setPullShortfall(uint256 amount) external {
        pullShortfall = amount;
    }

    /// @dev `depositV3` is decoded here into one struct: twelve named parameters exceed the legacy code generator's
    ///      stack. The parameter tuple's encoding equals the struct's tail, so an offset word is prepended.
    fallback() external payable {
        require(msg.sig == IAcrossSpokePool.depositV3.selector, "unknown selector");
        Deposit memory d = abi.decode(bytes.concat(abi.encode(uint256(0x20)), msg.data[4:]), (Deposit));
        IERC20(d.inputToken).safeTransferFrom(msg.sender, address(this), d.inputAmount - pullShortfall);
        _deposits.push(d);
        _callers.push(msg.sender);
        ++numberOfDeposits;
    }

    function depositCount() external view returns (uint256) {
        return _deposits.length;
    }

    function caller(uint256 index) external view returns (address) {
        return _callers[index];
    }

    function deposit(uint256 index) external view returns (Deposit memory) {
        return _deposits[index];
    }

    /// @dev Simulates a relayer fill: the pool must hold `amount` of `token`.
    function fill(address recipient, address token, uint256 amount, bytes calldata message) external {
        IERC20(token).safeTransfer(recipient, amount);
        IAcrossMessageHandler(recipient).handleV3AcrossMessage(token, amount, msg.sender, message);
    }

    /// @dev Simulates an expiry refund to the depositor of record.
    function refund(address depositor, address token, uint256 amount) external {
        IERC20(token).safeTransfer(depositor, amount);
    }
}
