// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAcrossSpokePool
/// @notice Minimal vendored subset of the Across V3 SpokePool used by the Across bridge adapter.
/// @dev Source: across-protocol/contracts `V3SpokePoolInterface.sol` and `SpokePool.sol`. Verified on 2026-09-29
///      against the live SpokePools on Arbitrum One (0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A) and Robinhood Chain
///      (0xD29C85F15DF544bA632C9E25829fd29d767d7978): `fillDeadlineBuffer()` = 21600, `depositQuoteTimeBuffer()`
///      = 3600, `numberOfDeposits()` returns uint32.
/// @dev The live SpokePool implementations on both chains no longer have `enabledDepositRoutes` (the call reverts
///      with empty data): no on-chain route flag exists, the only on-chain deposit gate is `pausedDeposits()`, and
///      whether relayers fill a route is an off-chain property (an unfilled deposit expires and refunds the depositor,
///      DEC-066). See docs/INTEGRATIONS.md.
interface IAcrossSpokePool {
    /// @notice Emitted by the SpokePool for every deposit, including those made through the legacy `depositV3`.
    event FundsDeposited(
        bytes32 inputToken,
        bytes32 outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 indexed destinationChainId,
        uint256 indexed depositId,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes32 indexed depositor,
        bytes32 recipient,
        bytes32 exclusiveRelayer,
        bytes message
    );

    /// @notice Legacy address-typed deposit entry point. Pulls `inputAmount` of `inputToken` from `msg.sender`.
    /// @dev The deposit id assigned is the value of `numberOfDeposits()` before the call. On expiry (no fill before
    ///      `fillDeadline`) Across refunds `inputAmount` to `depositor` on the origin chain. The SpokePool reverts
    ///      unless `quoteTimestamp` is not in the future and `getCurrentTime() - quoteTimestamp <=
    ///      depositQuoteTimeBuffer()`, and `getCurrentTime() <= fillDeadline <= getCurrentTime() + fillDeadlineBuffer()`.
    /// @param exclusivityDeadline Across's `exclusivityParameter`, despite the legacy name: 0 means no exclusivity; a
    ///        value up to 31,536,000 is an offset in seconds from the deposit time; a larger value is an absolute
    ///        timestamp. A non-zero value requires a non-zero `exclusiveRelayer` (else `InvalidExclusiveRelayer`).
    /// @param quoteTimestamp Quote time; must not be in the future and must be within `depositQuoteTimeBuffer()`.
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable;

    /// @notice Maximum distance, in seconds, between the current time and a deposit's fill deadline.
    function fillDeadlineBuffer() external view returns (uint32);

    /// @notice Maximum age, in seconds, of a deposit's quote timestamp.
    function depositQuoteTimeBuffer() external view returns (uint32);

    /// @notice The SpokePool's notion of the current time (block.timestamp on live deployments).
    function getCurrentTime() external view returns (uint256);

    /// @notice Number of deposits made so far; the next deposit's id.
    function numberOfDeposits() external view returns (uint32);
}
