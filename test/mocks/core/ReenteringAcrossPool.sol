// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";

/// @notice Across SpokePool stand-in that, once armed, re-enters the Core Vault with fixed calldata from inside
///         `depositV3`, after pulling the input like the real pool. It is the pinned bridge target AND the vault's
///         `acrossSpokePool`, so its re-entrant call passes the `NotAcrossSpokePool` check and only the reentrancy
///         guard can stop it (verification of the Across callback path during a send).
contract ReenteringAcrossPool {
    address public vault;
    bytes public payload;
    bool public armed;
    uint32 public numberOfDeposits;

    function arm(address vault_, bytes calldata payload_) external {
        vault = vault_;
        payload = payload_;
        armed = true;
    }

    /// @notice A refused re-entrant call rolls `armed` back with the send, so the test disarms explicitly.
    function disarm() external {
        armed = false;
    }

    /// @notice `IAcrossSpokePool.depositV3`, decoded by hand (twelve parameters are too deep for the legacy pipeline).
    fallback() external {
        require(msg.sig == IAcrossSpokePool.depositV3.selector, "unknown selector");
        (,, address inputToken,, uint256 inputAmount,,) =
            abi.decode(msg.data[4:], (address, address, address, address, uint256, uint256, uint256));
        IERC20(inputToken).transferFrom(msg.sender, address(this), inputAmount);
        if (armed) {
            armed = false;
            (bool ok, bytes memory ret) = vault.call(payload);
            if (!ok) {
                assembly ("memory-safe") {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
        ++numberOfDeposits;
    }
}
