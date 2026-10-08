// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Mandate, AdapterConfig, TokenConfig} from "../../src/mandate/Mandate.sol";

/// @title MandateFixture
/// @notice Appends Mandate v2 entries (WP-07 B1: tokens and swap adapters) to a Mandate a test builds by hand, so a
///         fixture lists them next to its pools instead of sizing arrays.
library MandateFixture {
    /// @notice Arbitrum One's Wormhole chain id, the Hub Chain of every fixture (D-15).
    uint16 internal constant ARBITRUM_WORMHOLE_CHAIN_ID = 23;

    /// @notice Appends `token` on `chainId` to the Mandate tokens, unless already listed there.
    function addToken(Mandate memory m, uint256 chainId, address token) internal pure {
        for (uint256 i; i < m.tokens.length; ++i) {
            if (m.tokens[i].chainId == chainId && m.tokens[i].token == token) return;
        }
        TokenConfig[] memory tokens = new TokenConfig[](m.tokens.length + 1);
        for (uint256 i; i < m.tokens.length; ++i) {
            tokens[i] = m.tokens[i];
        }
        tokens[m.tokens.length] = TokenConfig(chainId, token);
        m.tokens = tokens;
    }

    /// @notice Appends a swap adapter on `chainId`.
    function addSwapAdapter(Mandate memory m, uint256 chainId, address adapter) internal pure {
        AdapterConfig[] memory adapters = new AdapterConfig[](m.swapAdapters.length + 1);
        for (uint256 i; i < m.swapAdapters.length; ++i) {
            adapters[i] = m.swapAdapters[i];
        }
        adapters[m.swapAdapters.length] = AdapterConfig(chainId, adapter);
        m.swapAdapters = adapters;
    }
}
