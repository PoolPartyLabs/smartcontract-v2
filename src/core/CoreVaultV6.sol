pragma solidity 0.8.28;

import {CoreVaultCctp} from "./CoreVaultCctp.sol";
import {CoreVaultConfig} from "./CoreVaultTypes.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {SolanaSpokeRegistryV6} from "../mandate/SolanaMandateV6.sol";
import {SolanaDeploymentV6} from "../factory/SolanaDeploymentV6.sol";
import {CctpBridgeAdapter} from "../adapters/CctpBridgeAdapter.sol";
import {CctpReceiveConnector} from "./CctpReceiveConnector.sol";

/// @notice New-Fund Core with an immutable native Mandate commitment (DEC-188, DEC-190).
/// @dev DEC-191, DEC-199: native reports and pending CCTP claims share the same Core accounting.
contract CoreVaultV6 is CoreVaultCctp {
    SolanaSpokeRegistryV6 public immutable nativeRegistry;
    bytes32 public immutable nativeMandateHash;
    bytes32 public immutable managerSolanaKey;

    error InvalidNativeRegistry();

    constructor(
        Mandate memory mandate_,
        CoreVaultConfig memory config,
        SolanaSpokeRegistryV6 registry,
        CctpBridgeAdapter adapter,
        CctpReceiveConnector connector
    )
        CoreVaultCctp(
            mandate_,
            config,
            SolanaDeploymentV6.route(registry.nativeConfig(), config.fundId),
            SolanaDeploymentV6.spokeIndex(mandate_),
            adapter,
            connector
        )
    {
        if (address(registry).code.length == 0) {
            revert InvalidNativeRegistry();
        }
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
        if (
            adapter.maxFeeBps() != 50_000 || adapter.target() != registry.nativeConfig().transport.tokenMessenger
                || connector.messageTransmitter() != registry.nativeConfig().transport.messageTransmitter
        ) {
            revert InvalidNativeRegistry();
        }
        nativeRegistry = registry;
        nativeMandateHash = registry.nativeMandateHash();
        managerSolanaKey = registry.managerKey();
    }
}
