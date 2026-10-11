// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Create3} from "./Create3.sol";

/// @title Create3Deployer
/// @notice Places a contract at the same address on every chain although its constructor arguments differ per chain.
///         The protocol operator deploys the Fund Factory through it, with the same salt, once per chain.
/// @dev Why it exists: the Fund Factory's protocol wiring (USDC, the Across SpokePool, the Wormhole Core, Uniswap V4,
///      Aave, the linked libraries) is per chain and immutable, so its creation code differs per chain and a plain
///      CREATE2 through the deterministic deployer (0x4e59b44847b379578588920cA78FbF26c0B4956C) would give a different
///      address on each chain. The factory must sit at one address everywhere, because every fund address it predicts
///      is a function of that address (DEC-054: hub and spoke addresses are known to each other at creation). This
///      contract has no constructor arguments, so the deterministic deployer puts it at one address on every chain,
///      and CREATE3 (see Create3) makes the factory address depend only on this contract, the caller and the salt.
/// @dev The salt is bound to `msg.sender`, so only the operator that deployed the factory on the first chain can claim
///      the same address on another chain. No owner, no state, no proxy, no selfdestruct (DEC-022, DEC-058).
contract Create3Deployer {
    /// @notice A contract was deployed.
    event Deployed(address indexed deployer, bytes32 indexed salt, address deployed);

    /// @notice Deploys `initCode` at `addressOf(msg.sender, salt)`; bubbles the constructor's revert data.
    function deploy(bytes32 salt, bytes calldata initCode) external returns (address deployed) {
        deployed = Create3.deploy(_saltOf(msg.sender, salt), initCode);
        emit Deployed(msg.sender, salt, deployed);
    }

    /// @notice The address `deploy(salt, ...)` gives when called by `deployer`, whatever the creation code.
    function addressOf(address deployer, bytes32 salt) external view returns (address) {
        return Create3.addressOf(address(this), _saltOf(deployer, salt));
    }

    function _saltOf(address deployer, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(deployer, salt));
    }
}
