// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVaultIncome} from "../interfaces/ISpokeVaultIncome.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeIncomeLib} from "./SpokeIncomeLib.sol";
import {SpokeVaultBase} from "./SpokeVaultBase.sol";

/// @title SpokeVaultIncome
/// @notice The Spoke Vault's income collection: the hub Spoke Vault's collection for the Core Vault and the executor of
///         the Core Vault's collection orders on a spoke (DEC-122, DEC-124, DEC-161, DEC-172). See ISpokeVaultIncome.
/// @dev Split out of SpokeVault (WP-07 A3, DEC-131 pattern) so the income verbs have their own source file; the bodies
///      run in the linked library `SpokeIncomeLib`. DEC-092: collected income stays in its own bucket, outside Share
///      Assets, until a collection sells it and hands the dollars to the Core Vault. DEC-178 item 5 (supersedes DEC-122
///      item 4): the conversion happens at the collection, so the manager's income swap and the forward of collected
///      income in kind are gone.
abstract contract SpokeVaultIncome is SpokeVaultBase {
    /// @inheritdoc ISpokeVaultIncome
    /// @dev DEC-172: the Hub positions' income is sold in the same collection as the spokes'; the Core Vault recognizes
    ///      it first (DEC-138) and converts it with what this returns.
    function collectIncomeAll(uint16 maxLossBps)
        external
        onlyOnHubChain
        nonReentrant
        returns (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained)
    {
        if (msg.sender != coreVault) revert NotCoreVault(msg.sender);
        return SpokeIncomeLib.collectHub(_s, baseToken, coreVault, maxLossBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Orders (DEC-122, DEC-124, DEC-161; WP-07 D4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Executes an accepted income collection order (`OrderCodec.COLLECT`): collect the positions' income, sell
    ///         it for the base token and send it home with what each token sold for (DEC-122 item 5, DEC-124, DEC-161).
    ///         `SpokeVault.executeOrder` calls it after the order checks and publishes the report after it.
    /// @dev The body runs in the linked library `SpokeIncomeLib` (WP-07 D5).
    function _executeCollectOrder(OrderCodec.Order memory o) internal virtual {
        SpokeIncomeLib.executeCollectOrder(_s, _config(), o);
    }
}
