// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";

/// @title SpokeIncomeLib
/// @notice The Spoke Vault's income collection on a spoke: the body of its collection order executor
///         (`SpokeVaultIncome._executeCollectOrder`). Deployed once per chain and linked into `SpokeVault`; it runs in
///         the vault's context (library call) over the vault's own `SpokeVaultTypes.State`, holds no state and is
///         immutable (DEC-022, DEC-058).
/// @dev WP-07 D5: linked before it holds any logic, so the income work (DEC-122, DEC-124, DEC-161) fills it without
///      touching the deployment, the Spoke Vault code the factory pins or the size test (DEC-131 pattern, like
///      `SpokeCrossChainLib` and `SpokeUnwindLib`). Events and errors are the vault's (ISpokeVault, SpokeVaultTypes,
///      SpokeIncomeTypes), emitted from the vault's address. The library is part of the vault's creation code and
///      trust surface.
library SpokeIncomeLib {
    /// @notice Body of `SpokeVaultIncome._executeCollectOrder`: collect the positions' income and send it home
    ///         (DEC-122 item 5, DEC-124, DEC-161), the results in the income book for the next report.
    /// @dev Not built yet: refuses the order whole, so the vault's order cursor does not move.
    function executeCollectOrder(
        SpokeVaultTypes.State storage,
        SpokeVaultTypes.Config memory,
        OrderCodec.Order memory o
    ) external pure {
        revert ISpokeVault.OrderKindNotSupported(o.kind);
    }
}
