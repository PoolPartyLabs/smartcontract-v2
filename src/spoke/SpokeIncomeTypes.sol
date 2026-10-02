// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SpokeIncomeTypes
/// @notice The income collection's own state in the Spoke Vault (`SpokeVaultIncome`, `SpokeIncomeLib`).
/// @dev WP-07 D1: the income work (the collection on every chain and the Hub dollar index, DEC-122, DEC-124,
///      DEC-161) adds fields only to `Book` and edits only this types file, never `SpokeVaultTypes`.
library SpokeIncomeTypes {
    /// @notice The income collection's state inside `SpokeVaultTypes.State`.
    /// @param reportBlob What the next reports carry as `ReportCodec.Report.collectionResults`: the results of the
    ///        collection orders this vault executed (DEC-122 item 5, DEC-161), opaque to the report builder. Empty
    ///        until the collection orders exist; their work owns its encoding and how long an entry stays in it.
    struct Book {
        bytes reportBlob;
    }
}
