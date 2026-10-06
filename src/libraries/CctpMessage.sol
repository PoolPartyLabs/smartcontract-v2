pragma solidity 0.8.28;

import {TransferKind} from "../interfaces/FundTypes.sol";
import {TransitMessage} from "./TransitMessage.sol";

/// @notice Strict parser for Circle's deployed V2 packed message and Pool Party hook (DEC-191).
library CctpMessage {
    struct Receipt {
        bytes32 nonce;
        bytes32 sender;
        bytes32 recipient;
        bytes32 destinationCaller;
        bytes32 burnToken;
        bytes32 mintRecipient;
        bytes32 messageSender;
        uint256 amount;
        uint256 maxFee;
        uint256 feeExecuted;
        bytes32 fundId;
        uint256 originChainId;
        bytes32 transitId;
        TransferKind kind;
    }

    error InvalidMessage();

    /// @dev Circle header/body version is 1 for V2; body starts at 148, hook at 376.
    function decode(bytes calldata message) internal pure returns (Receipt memory receipt) {
        if (
            message.length != 536 || uint32(bytes4(message[0:4])) != 1 || uint32(bytes4(message[4:8])) != 5
                || uint32(bytes4(message[8:12])) != 3 || uint32(bytes4(message[140:144])) != 1000
                || uint32(bytes4(message[144:148])) < 1000 || uint32(bytes4(message[148:152])) != 1
        ) {
            revert InvalidMessage();
        }
        receipt.nonce = bytes32(message[12:44]);
        receipt.sender = bytes32(message[44:76]);
        receipt.recipient = bytes32(message[76:108]);
        receipt.destinationCaller = bytes32(message[108:140]);
        receipt.burnToken = bytes32(message[152:184]);
        receipt.mintRecipient = bytes32(message[184:216]);
        receipt.amount = uint256(bytes32(message[216:248]));
        receipt.messageSender = bytes32(message[248:280]);
        receipt.maxFee = uint256(bytes32(message[280:312]));
        receipt.feeExecuted = uint256(bytes32(message[312:344]));
        (receipt.fundId, receipt.originChainId, receipt.transitId, receipt.kind) = TransitMessage.decode(message[376:]);
        if (
            receipt.nonce == bytes32(0) || receipt.transitId == bytes32(0) || receipt.amount == 0
                || receipt.amount > type(uint64).max || receipt.maxFee >= receipt.amount
                || receipt.feeExecuted > receipt.maxFee
        ) revert InvalidMessage();
    }
}
