// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";

/// @notice Core Bridge stand-in: a "VAA" is `abi.encode(CoreBridgeVM)`; verification succeeds unless the test turns
///         it off.
contract MockCoreBridge {
    bool public valid = true;
    string public reason;

    function setInvalid(string calldata reason_) external {
        valid = false;
        reason = reason_;
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
