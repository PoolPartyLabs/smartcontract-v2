// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Adversarial SpokePool stand-in: its counter getter writes state, so any caller that reaches it through a
///         STATICCALL (a `view` adapter function) must revert instead of letting the pool mutate anything.
contract MaliciousAcrossSpokePool {
    uint32 public fillDeadlineBuffer = 21_600;
    uint32 public reads;

    /// @dev Not `view` on purpose: the adapter's `buildSend` must be unable to trigger this write.
    function numberOfDeposits() external returns (uint32) {
        ++reads;
        return reads;
    }
}
