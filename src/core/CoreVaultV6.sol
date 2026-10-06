pragma solidity 0.8.28;

import {CoreVault} from "./CoreVault.sol";
import {CoreVaultConfig} from "./CoreVaultTypes.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {SolanaSpokeRegistryV6} from "../mandate/SolanaMandateV6.sol";

/// @notice New-Fund Core with an immutable native Mandate commitment (DEC-188, DEC-190).
/// @dev Accounting uses the receiver's checked v5 projection; transport is owned by the CCTP track (DEC-191).
contract CoreVaultV6 is CoreVault {
    SolanaSpokeRegistryV6 public immutable nativeRegistry;
    bytes32 public immutable nativeMandateHash;
    bytes32 public immutable managerSolanaKey;

    error InvalidNativeRegistry();

    constructor(Mandate memory mandate_, CoreVaultConfig memory config, SolanaSpokeRegistryV6 registry)
        CoreVault(mandate_, config)
    {
        if (address(registry).code.length == 0) revert InvalidNativeRegistry();
        nativeRegistry = registry;
        nativeMandateHash = registry.nativeMandateHash();
        managerSolanaKey = registry.managerKey();
    }
}
