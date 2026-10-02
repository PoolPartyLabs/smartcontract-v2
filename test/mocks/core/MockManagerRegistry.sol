// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice The IManagerRegistry reads the Core Vault and the factory make: `protocolSliceBps(manager)`, default 5,000,
///         and `minManagerFeeBps()`, default 0 (DEC-125 item 3).
contract MockManagerRegistry {
    uint16 public slice = 5000;
    uint16 public minManagerFeeBps;
    bool public reverts;
    uint256 public reads;

    function setSlice(uint16 bps) external {
        slice = bps;
    }

    function setMinManagerFeeBps(uint16 bps) external {
        minManagerFeeBps = bps;
    }

    function setReverts(bool r) external {
        reverts = r;
    }

    function protocolSliceBps(address) external view returns (uint16) {
        require(!reverts, "registry down");
        return slice;
    }
}
