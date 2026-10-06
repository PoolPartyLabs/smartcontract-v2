pragma solidity 0.8.28;

import {TransferKind} from "./FundTypes.sol";

/// @notice Constructor-bound, full-width Solana route for new Funds (DEC-188, DEC-191).
struct CctpRoute {
    bytes32 fundId;
    uint256 solanaChainId;
    bytes32 mintRecipient;
    bytes32 destinationCaller;
    bytes32 remoteTokenMessenger;
    bytes32 remoteToken;
    bytes32 remoteVaultAuthority;
}

/// @notice Connector callback: minted tokens are already in Core custody (DEC-191).
interface ICctpCoreVault {
    function creditCctp(
        uint256 originChainId,
        bytes32 transitId,
        TransferKind kind,
        uint256 amount,
        uint256 maxFee,
        uint256 feeExecuted
    ) external;
}
