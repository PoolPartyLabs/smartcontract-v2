// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
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
/// @dev OPERATIONAL RULE — never call `closeFund` on a v6 Fund until CR-02 G1-G3 land (post-demo, R9.2):
///      `finalizeClosure` cannot complete today. G1: collected Solana income has no route home for a multi-asset
///      Fund. G2: non-USDC residue cannot be liquidated under CLOSE. G3: the Hub ACK removes the EVM spoke's CLOSE
///      result that finalization needs (also true of the legacy Core). A Closing Fund then strands its holders, who
///      can exit only after Closed. While the Fund is Open, holders exit by payout. Closure stays fail-closed.
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

    /// @dev DEC-194, DEC-198, R9.1: the legacy payout cached-price fallback must not price a native stock on a stale
    ///      feed; the stock feeds' max age is the only time guard (no market-hours gate).
    function _requireSharePricing() internal view override {
        nativeRegistry.requireStockPricing(priceSource);
    }
}
