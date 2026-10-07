// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";

/// @notice Wormhole Core stand-in for the order channel's unit tests, on both ends:
///         - `publishMessage` records each call and returns a per-emitter sequence from 0, requiring exactly
///           `messageFee` like the real Core;
///         - `parseAndVerifyVM` reads a "VAA" that is `abi.encode(CoreBridgeVM)` and reports it valid unless the test
///           turns verification off. `vaaOf` turns a recorded message into such a VAA as this Core's chain emitted it.
contract MockOrderCore {
    struct Published {
        address emitter;
        uint32 nonce;
        bytes payload;
        uint8 consistencyLevel;
        uint256 value;
        uint64 sequence;
    }

    uint16 public immutable chainId;
    uint256 public messageFee;
    bool public valid = true;
    string public reason;
    mapping(address emitter => uint64) public nextSequence;
    Published[] internal _published;

    error WrongFee(uint256 sent, uint256 fee);

    constructor(uint16 chainId_) {
        chainId = chainId_;
    }

    function setMessageFee(uint256 fee) external {
        messageFee = fee;
    }

    function setInvalid(string calldata reason_) external {
        valid = false;
        reason = reason_;
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

    /// @notice The VAA a guardian quorum would sign for the recorded message at `index`.
    function vaaOf(uint256 index) external view returns (bytes memory) {
        Published memory p = _published[index];
        return craft(chainId, bytes32(uint256(uint160(p.emitter))), p.sequence, p.consistencyLevel, p.payload);
    }

    /// @notice A VAA with any envelope, for the negative cases.
    function craft(
        uint16 emitterChainId,
        bytes32 emitterAddress,
        uint64 sequence,
        uint8 consistencyLevel,
        bytes memory payload
    ) public view returns (bytes memory) {
        CoreBridgeVM memory vm;
        vm.version = 1;
        vm.timestamp = uint32(block.timestamp);
        vm.emitterChainId = emitterChainId;
        vm.emitterAddress = emitterAddress;
        vm.sequence = sequence;
        vm.consistencyLevel = consistencyLevel;
        vm.payload = payload;
        vm.signatures = new GuardianSignature[](0);
        return abi.encode(vm);
    }

    function parseAndVerifyVM(bytes calldata encodedVm)
        external
        view
        returns (CoreBridgeVM memory vm, bool valid_, string memory reason_)
    {
        vm = abi.decode(encodedVm, (CoreBridgeVM));
        return (vm, valid, reason);
    }
}
