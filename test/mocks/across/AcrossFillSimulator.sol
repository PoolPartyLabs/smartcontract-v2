// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAcrossMessageHandler} from "../../../src/interfaces/external/IAcrossMessageHandler.sol";

/// @notice Simulates an Across fill on the destination chain (docs/INTEGRATIONS.md "Testing on forks"): credits
///         `outputAmount` of `outputToken` to the recipient, then calls `handleV3AcrossMessage` from the SpokePool
///         address, in the order the live SpokePool uses (transfer first, callback second).
/// @dev Pass the test's `stdstore` (forge-std `Test` exposes it). The balance write adds to the recipient's
///      current balance, like a real transfer, and leaves `totalSupply` untouched.
library AcrossFillSimulator {
    using stdStorage for StdStorage;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @param store The calling test's `stdstore`.
    /// @param spokePool Destination SpokePool, the only caller a vault accepts.
    /// @param outputToken Token the fill delivers.
    /// @param outputAmount Amount the fill delivers.
    /// @param recipient Contract recipient implementing `handleV3AcrossMessage`.
    /// @param relayer Relayer reported to the recipient.
    /// @param message Deposit message; the live SpokePool skips the callback when it is empty.
    function simulateFill(
        StdStorage storage store,
        address spokePool,
        address outputToken,
        uint256 outputAmount,
        address recipient,
        address relayer,
        bytes memory message
    ) internal {
        uint256 balance = IERC20(outputToken).balanceOf(recipient);
        store.target(outputToken).sig(IERC20.balanceOf.selector).with_key(recipient)
            .checked_write(balance + outputAmount);
        if (message.length == 0) return;
        VM.prank(spokePool);
        IAcrossMessageHandler(recipient).handleV3AcrossMessage(outputToken, outputAmount, relayer, message);
    }
}
