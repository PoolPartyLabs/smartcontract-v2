pragma solidity 0.8.28;

import {CoreVault} from "./CoreVault.sol";
import {CoreVaultConfig} from "./CoreVaultTypes.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {SolanaSpokeRegistryV6} from "../mandate/SolanaMandateV6.sol";
import {ISolanaTransportV6} from "../interfaces/ISolanaTransportV6.sol";

/// @notice New-Fund Core with an immutable native Mandate commitment (DEC-188, DEC-190).
/// @dev Accounting uses the receiver's checked v5 projection; transport is owned by the CCTP track (DEC-191).
///      TODO(decision): integrate native result codecs; T2b must integrate pending-claim transit before deployment.
contract CoreVaultV6 is CoreVault {
    SolanaSpokeRegistryV6 public immutable nativeRegistry;
    bytes32 public immutable nativeMandateHash;
    bytes32 public immutable managerSolanaKey;

    error InvalidNativeRegistry();

    constructor(Mandate memory mandate_, CoreVaultConfig memory config, SolanaSpokeRegistryV6 registry)
        CoreVault(mandate_, config)
    {
        if (address(registry).code.length == 0) revert InvalidNativeRegistry();
        bool foundNative;
        for (uint256 index; index < mandate_.spokes.length; ++index) {
            if (mandate_.spokes[index].wormholeChainId != 1) continue;
            if (
                foundNative || mandate_.spokes[index].chainId != registry.chainId()
                    || mandate_.spokes[index].spokeVault != registry.spoke()
            ) revert InvalidNativeRegistry();
            foundNative = true;
        }
        if (!foundNative) revert InvalidNativeRegistry();
        bool foundTransport;
        for (uint256 index; index < mandate_.bridgeAdapters.length; ++index) {
            if (
                mandate_.bridgeAdapters[index].spokeChainId != registry.chainId()
                    || mandate_.bridgeAdapters[index].chainId != mandate_.hubChainId
            ) continue;
            ISolanaTransportV6 adapter = ISolanaTransportV6(mandate_.bridgeAdapters[index].adapter);
            if (adapter.target() != 0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d || adapter.fillDeadlineSeconds() != 0) {
                revert InvalidNativeRegistry();
            }
            foundTransport = true;
        }
        if (!foundTransport) revert InvalidNativeRegistry();
        nativeRegistry = registry;
        nativeMandateHash = registry.nativeMandateHash();
        managerSolanaKey = registry.managerKey();
    }
}
