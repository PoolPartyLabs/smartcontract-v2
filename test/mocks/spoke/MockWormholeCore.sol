// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Wormhole Core Bridge mock: records every `publishMessage` call and returns a per-emitter sequence.
contract MockWormholeCore {
    struct Published {
        address emitter;
        uint32 nonce;
        bytes payload;
        uint8 consistencyLevel;
        uint256 value;
        uint64 sequence;
    }

    uint256 public messageFee;
    mapping(address => uint64) public nextSequence;
    Published[] internal _published;

    error WrongFee(uint256 sent, uint256 fee);

    function setMessageFee(uint256 fee) external {
        messageFee = fee;
    }

    function publishMessage(uint32 nonce, bytes memory payload, uint8 consistencyLevel)
        external
        payable
        returns (uint64 sequence)
    {
        if (msg.value != messageFee) revert WrongFee(msg.value, messageFee);
        sequence = nextSequence[msg.sender]++;
        _published.push(Published(msg.sender, nonce, payload, consistencyLevel, msg.value, sequence));
    }

    function publishedCount() external view returns (uint256) {
        return _published.length;
    }

    function published(uint256 index) external view returns (Published memory) {
        return _published[index];
    }
}
