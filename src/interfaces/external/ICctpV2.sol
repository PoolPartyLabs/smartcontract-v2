pragma solidity 0.8.28;

/// @notice Arbitrum CCTP V2 ABI at Circle commit 7d703109 (DEC-191).
interface ITokenMessengerV2 {
    function depositForBurnWithHook(
        uint256 amount,
        uint32 destinationDomain,
        bytes32 mintRecipient,
        address burnToken,
        bytes32 destinationCaller,
        uint256 maxFee,
        uint32 minFinalityThreshold,
        bytes calldata hookData
    ) external;
}

/// @notice Only the pinned transmitter authenticates Circle attestations (DEC-191).
interface IMessageTransmitterV2 {
    function receiveMessage(bytes calldata message, bytes calldata attestation) external returns (bool);
}
