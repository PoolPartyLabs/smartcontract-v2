// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";

/// @title CoreVaultIncomeTypes
/// @notice The income book of the Core Vault: the state the income path (`CoreVaultIncome`, `CoreVaultIncomeLogic`)
///         keeps inside `CoreVaultState`.
/// @dev WP-07 D1: the income path and the payout path each keep their state in a book of their own, so the work that
///      builds the income path out (the Hub dollar index and the collection on every chain, DEC-122, DEC-124,
///      DEC-161) adds fields here without editing `CoreVaultTypes.sol`. The book lives inside `CoreVaultState`; no
///      fund sits behind a proxy (DEC-022, DEC-058), so a new field only changes the storage layout of funds created
///      after it.
library CoreVaultIncomeTypes {
    /// @notice Income state of the Core Vault.
    /// @param index Attributed Income accumulator (Q60).
    /// @param collectedIncome Collected income per token, net of fees, payable now to holders (LC-100; ruling
    ///        2026-09-29: fees leave at collection, so nothing owed to the manager or the protocol waits here).
    struct Book {
        IncomeAccumulator.State index;
        mapping(address token => uint256) collectedIncome;
    }
}
