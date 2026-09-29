// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title Create3
/// @notice Deploys a contract at an address that depends only on the deploying contract and a salt, never on the
///         contract's creation code.
/// @dev The CREATE3 pattern (0age's metamorphic proxy idea, as packaged by Solady's `CREATE3` and 0xsequence's
///      `create3`): CREATE2 a fixed minimal proxy whose address is `f(deployer, salt, PROXY_INITCODE_HASH)`, then have
///      the proxy CREATE the real contract with its first nonce (1, EIP-161), so the real address is
///      `f(proxy, 1)`. Neither step reads the real creation code, which is what lets the Fund Factory predict hub and
///      spoke addresses before any of them exists and write them into the Mandate that their creation code contains
///      (DEC-053, DEC-054: hub and spoke addresses are known to each other at creation).
/// @dev Difference from Solady's proxy: this proxy bubbles the child constructor's revert data, so a revert such as
///      the Across adapter's `FillDeadlineBufferTooShort` (DEC-066) surfaces as the deployment's revert reason instead
///      of an opaque failure. The proxy stays callable after use, like Solady's; a later call can only CREATE at the
///      proxy's next nonces, never at the address already deployed.
library Create3 {
    /// @notice Proxy creation code: returns the 22-byte runtime below.
    /// @dev Init: `PUSH22 runtime; RETURNDATASIZE; MSTORE; PUSH1 22; PUSH1 10; RETURN`.
    ///      Runtime: `calldatacopy(0, 0, calldatasize()); a := create(callvalue(), 0, calldatasize());
    ///      if iszero(a) { returndatacopy(0, 0, returndatasize()); revert(0, returndatasize()) }; stop()`
    ///      (`363d3d37363d34f0 601457 3d6000803e3d6000fd 5b00`).
    bytes internal constant PROXY_INITCODE = hex"75363d3d37363d34f06014573d6000803e3d6000fd5b003d526016600af3";

    /// @notice keccak256 of `PROXY_INITCODE`.
    bytes32 internal constant PROXY_INITCODE_HASH = keccak256(PROXY_INITCODE);

    /// @notice The salt was already used by this deployer (the proxy's CREATE2 collided).
    error SaltAlreadyUsed(bytes32 salt);

    /// @notice The contract was created without runtime code.
    error DeploymentWithoutCode(bytes32 salt);

    /// @notice `createAddress` only encodes one-byte nonces.
    error NonceOutOfRange(uint8 nonce);

    /// @notice Deploys `initCode` (creation code plus constructor arguments) at `addressOf(address(this), salt)`.
    /// @dev Reverts with the child constructor's revert data when it reverts.
    /// @dev A CREATE2 collision consumes all the gas it is given, so a used salt is refused before the attempt.
    function deploy(bytes32 salt, bytes memory initCode) internal returns (address deployed) {
        if (proxyOf(address(this), salt).code.length != 0) revert SaltAlreadyUsed(salt);
        bytes memory proxyCode = PROXY_INITCODE;
        address proxy;
        assembly ("memory-safe") {
            proxy := create2(0, add(proxyCode, 0x20), mload(proxyCode), salt)
        }
        if (proxy == address(0)) revert SaltAlreadyUsed(salt);
        (bool ok, bytes memory returned) = proxy.call(initCode);
        if (!ok) {
            assembly ("memory-safe") {
                revert(add(returned, 0x20), mload(returned))
            }
        }
        deployed = childOf(proxy);
        if (deployed.code.length == 0) revert DeploymentWithoutCode(salt);
    }

    /// @notice The address `deployer` gives to a contract deployed with `salt`, whatever its creation code.
    function addressOf(address deployer, bytes32 salt) internal pure returns (address) {
        return childOf(proxyOf(deployer, salt));
    }

    /// @notice The CREATE2 address of the proxy `deployer` uses for `salt`.
    function proxyOf(address deployer, bytes32 salt) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, PROXY_INITCODE_HASH)))));
    }

    /// @notice The address of the first contract `proxy` creates (nonce 1).
    function childOf(address proxy) internal pure returns (address) {
        return createAddress(proxy, 1);
    }

    /// @notice The address of the contract `creator` creates with plain CREATE at `nonce` (1 to 127).
    /// @dev RLP of `[creator, nonce]` for a one-byte nonce: `0xd6 0x94 creator nonce`. The Core Vault deploys its
    ///      ShareToken (nonce 1) and ManagerFeeVault (nonce 2) this way (ruling 2026-09-29).
    function createAddress(address creator, uint8 nonce) internal pure returns (address) {
        if (nonce == 0 || nonce > 0x7f) revert NonceOutOfRange(nonce);
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes2(0xd694), creator, bytes1(nonce))))));
    }
}
