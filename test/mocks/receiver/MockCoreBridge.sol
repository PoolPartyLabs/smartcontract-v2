// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreBridgeVM} from "wormhole-sdk/interfaces/ICoreBridge.sol";

/// @notice Core Bridge stand-in: a "VAA" is `abi.encode(CoreBridgeVM)`; verification succeeds unless the test turns
///         it off.
/// @dev `chainId()` is Arbitrum One's Wormhole chain id (23), the Hub Chain of every fixture, which the Core Vault checks
///      against `Mandate.hubWormholeChainId` (WP-07 B2, D-15).
contract MockCoreBridge {
    bool public valid = true;
    string public reason;
    uint16 public chainId = 23;

    function setChainId(uint16 chainId_) external {
        chainId = chainId_;
    }

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
