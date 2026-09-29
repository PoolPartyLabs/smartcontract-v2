// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Create3} from "../../../src/factory/Create3.sol";
import {CodeStore} from "../../../src/factory/CodeStore.sol";

/// @notice Exposes the Create3 and CodeStore internal functions to the unit tests.
contract Create3Harness {
    function deploy(bytes32 salt, bytes memory initCode) external returns (address) {
        return Create3.deploy(salt, initCode);
    }

    function addressOf(bytes32 salt) external view returns (address) {
        return Create3.addressOf(address(this), salt);
    }

    function createAddress(address creator, uint8 nonce) external pure returns (address) {
        return Create3.createAddress(creator, nonce);
    }

    function write(bytes memory data) external returns (address[] memory) {
        return CodeStore.write(data);
    }

    function read(address[] memory chunks) external view returns (bytes memory) {
        return CodeStore.read(chunks);
    }
}

/// @notice A contract whose runtime reports a constructor argument, to tell two creation codes apart.
contract Create3Child {
    uint256 public immutable tag;
    address public immutable creator;

    constructor(uint256 tag_) {
        tag = tag_;
        creator = msg.sender;
    }
}

/// @notice A second, different contract at the same salt.
contract Create3OtherChild {
    function kind() external pure returns (bytes32) {
        return "other";
    }
}

/// @notice A constructor that reverts with a named error, as the Across adapter does on a short fill deadline buffer.
contract Create3RevertingChild {
    error ConstructorRefused(uint256 code);

    constructor() {
        revert ConstructorRefused(42);
    }
}

/// @notice A constructor that creates two contracts, as the Core Vault creates its ShareToken and ManagerFeeVault.
contract Create3Parent {
    address public first;
    address public second;

    constructor() {
        first = address(new Create3OtherChild());
        second = address(new Create3OtherChild());
    }
}
