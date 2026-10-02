// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title IAcrossSpokePoolLive
/// @notice Members of the live Across SpokePool that the fork tests read or drive, outside the frozen
///         `IAcrossSpokePool` subset the production adapter uses (DEC-158, DEC-162, LC-159). Test only.
/// @dev Source: across-protocol/contracts at a634bea (2026-09-29): `contracts/spoke-pools/SpokePool.sol`,
///      `contracts/interfaces/V3SpokePoolInterface.sol`, `contracts/interfaces/SpokePoolInterface.sol`. Every selector
///      below was found in the live implementations behind the Arbitrum One and Robinhood Chain proxies on 2026-10-02.
interface IAcrossSpokePoolLive {
    /// @notice V3 relay data, bytes32-typed, as `fillRelay` and `getV3RelayHash` take it.
    struct V3RelayData {
        bytes32 depositor;
        bytes32 recipient;
        bytes32 exclusiveRelayer;
        bytes32 inputToken;
        bytes32 outputToken;
        uint256 inputAmount;
        uint256 outputAmount;
        uint256 originChainId;
        uint256 depositId;
        uint32 fillDeadline;
        uint32 exclusivityDeadline;
        bytes message;
    }

    /// @notice Emitted by `speedUpV3Deposit` / `speedUpDeposit` once the depositor's signature verified.
    event RequestedSpeedUpDeposit(
        uint256 updatedOutputAmount,
        uint256 indexed depositId,
        bytes32 indexed depositor,
        bytes32 updatedRecipient,
        bytes updatedMessage,
        bytes depositorSignature
    );

    /// @notice SpokePoolInterface: the depositor signature of a speed-up did not verify (ECDSA or EIP-1271).
    error InvalidDepositorSignature();

    // ------------------------------------------------------------------ public state (all a contract can read)

    function numberOfDeposits() external view returns (uint32);
    function depositQuoteTimeBuffer() external view returns (uint32);
    function fillDeadlineBuffer() external view returns (uint32);
    function pausedDeposits() external view returns (bool);
    function pausedFills() external view returns (bool);
    function chainId() external view returns (uint256);
    function getCurrentTime() external view returns (uint256);
    function crossDomainAdmin() external view returns (address);
    function withdrawalRecipient() external view returns (address);
    function wrappedNativeToken() external view returns (address);
    function fillStatuses(bytes32 relayHash) external view returns (uint256);
    function getV3RelayHash(V3RelayData calldata relayData) external view returns (bytes32);
    // forge-lint: disable-next-line(mixed-case-function)
    function UPDATE_BYTES32_DEPOSIT_DETAILS_HASH() external view returns (bytes32);

    // ------------------------------------------------------------------ entry points

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

    function speedUpV3Deposit(
        address depositor,
        uint256 depositId,
        uint256 updatedOutputAmount,
        address updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;

    function fillRelay(V3RelayData calldata relayData, uint256 repaymentChainId, bytes32 repaymentAddress) external;

    function fillRelayWithUpdatedDeposit(
        V3RelayData calldata relayData,
        uint256 repaymentChainId,
        bytes32 repaymentAddress,
        uint256 updatedOutputAmount,
        bytes32 updatedRecipient,
        bytes calldata updatedMessage,
        bytes calldata depositorSignature
    ) external;
}
