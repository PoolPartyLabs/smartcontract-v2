// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DollarIncomeIndex} from "../libraries/DollarIncomeIndex.sol";

/// @title CoreVaultIncomeTypes
/// @notice The income book of the Core Vault: the state the income path (`CoreVaultIncome`, `CoreVaultIncomeLogic`)
///         keeps inside `CoreVaultState`.
/// @dev WP-07 D1: the income path and the payout path each keep their state in a book of their own, so the income work
///      adds fields here without editing `CoreVaultTypes.sol`. The book lives inside `CoreVaultState`; no fund sits
///      behind a proxy (DEC-022, DEC-058), so a new field only changes the storage layout of funds created after it.
library CoreVaultIncomeTypes {
    /// @notice Source id of the Hub positions' income; spoke `i` is source `1 + i`.
    uint256 internal constant HUB_SOURCE = 0;

    /// @notice One income source: its dollar index and what feeds it.
    /// @dev DEC-161 item 1, doc 10 section 6: the Hub's income and each spoke's are converted by different sales at
    ///      different rates, so each has its own token indices and dollar index. One per spoke rather than one for every
    ///      spoke (reading of the plan's "spoke source"): each spoke's collection then closes its own interval when its
    ///      own Income transfer is credited, and a late spoke never holds another's conversion.
    /// @param index The source's dollar index (`DollarIncomeIndex`), tagged with the source id.
    /// @param counter Last counter recognized per token (Q60: monotonic per chain; the next advance is recognized).
    /// @param feeUnits Performance fee owed per token in token units, converted at the collection rate (D-40).
    struct Source {
        DollarIncomeIndex.State index;
        mapping(address token => uint256) counter;
        mapping(address token => uint256) feeUnits;
    }

    /// @notice A spoke's collection result the Hub read from its reports (`SpokeIncomeTypes.CollectionResult`).
    /// @param round The collection round it served.
    /// @param seen Whether a report listed it.
    /// @param closed Whether it was converted (or held nothing to convert).
    /// @param transitId The Income transfer carrying its dollars; a refunded send's successor replaces it.
    /// @param sold Units sold per token, in the source's token order.
    /// @param obtained Spoke base units obtained per token, in the source's token order (the dollars credited are split
    ///        between the tokens in this proportion).
    struct SpokeResult {
        uint64 round;
        bool seen;
        bool closed;
        bytes32 transitId;
        uint256[] sold;
        uint256[] obtained;
    }

    /// @notice An Income Withdrawal request (DEC-122): the collection round it waits for.
    struct Request {
        uint64 round;
        bool open;
    }

    /// @notice Income state of the Core Vault.
    /// @param sources Income sources by id (`HUB_SOURCE`, then one per Mandate spoke).
    /// @param sourceCount `1 + ` the number of spokes.
    /// @param heldDollars USDC held for holders: attributed and not taken, plus Income credited and not converted yet
    ///        (part of the USDC ledger, DEC-080).
    /// @param results Spoke collection results by spoke and result id.
    /// @param resultOf The result whose dollars a spoke's Income transfer carries, by transfer id.
    /// @param credited USDC credited for a spoke's Income transfer and not converted yet.
    /// @param openResults Results read and not converted yet.
    /// @param round The latest collection round of the spokes.
    /// @param attempt The latest attempt of `round`.
    /// @param deadline The latest order's deadline.
    /// @param pendingSpokes Bitmask of spokes whose result for `round` is not converted yet.
    /// @param requests Income Withdrawal requests by shareholder.
    struct Book {
        mapping(uint256 source => Source) sources;
        uint256 sourceCount;
        uint256 heldDollars;
        mapping(uint256 spokeIndex => mapping(uint64 resultId => SpokeResult)) results;
        mapping(uint256 spokeIndex => mapping(bytes32 transitId => uint64)) resultOf;
        mapping(uint256 spokeIndex => mapping(bytes32 transitId => uint256)) credited;
        uint256 openResults;
        uint64 round;
        uint32 attempt;
        uint64 deadline;
        uint256 pendingSpokes;
        mapping(address holder => Request) requests;
    }
}
