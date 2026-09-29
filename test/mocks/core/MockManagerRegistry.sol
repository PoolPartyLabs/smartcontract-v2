// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The IManagerRegistry read the Core Vault makes: `protocolSliceBps(manager)`, default 5,000.
contract MockManagerRegistry {
    uint16 public slice = 5000;
    bool public reverts;
    uint256 public reads;

    function setSlice(uint16 bps) external {
        slice = bps;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function protocolSliceBps(address) external view returns (uint16) {
        require(!reverts, "registry down");
        return slice;
    }
}
