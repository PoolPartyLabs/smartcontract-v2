// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAcrossMessageHandler
/// @notice Callback a contract recipient of an Across fill implements.
/// @dev The destination SpokePool transfers `amount` of `tokenSent` to the recipient and then calls this function
///      with the deposit's `message`. It is only called when the message is non-empty. The depositor is NOT passed,
///      so the recipient cannot authenticate the origin of the funds from this call alone.
interface IAcrossMessageHandler {
    /// @param tokenSent Output token delivered to the recipient.
    /// @param amount Amount of `tokenSent` delivered.
    /// @param relayer Relayer that filled the deposit.
    /// @param message Message attached by the depositor.
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;
}
