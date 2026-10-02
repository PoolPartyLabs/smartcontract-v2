// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {SpokeUnwindTypes} from "../spoke/SpokeUnwindTypes.sol";

/// @title CoreVaultPayoutTypes
/// @notice The payout book of the Core Vault: the state the payout path (`CoreVaultPayout`, `CoreVaultPayoutLogic`)
///         keeps inside `CoreVaultState`.
/// @dev WP-07 D1: the payout path and the income path each keep their state in a book of their own, so the work
///      that builds them out (the proportional unwind and its settlement, DEC-120, DEC-137, DEC-139) adds fields here
///      without editing `CoreVaultTypes.sol`. The book lives inside `CoreVaultState`; no fund sits behind a proxy
///      (DEC-022, DEC-058), so a new field only changes the storage layout of funds created after it.
library CoreVaultPayoutTypes {
    /// @notice Payout state of the Core Vault.
    /// @param requests Payout Request per address (DEC-024, DEC-046).
    /// @param requestCount Payout Requests ever opened; the low 96 bits of every request id
    ///        (`ICoreVaultPayouts.PayoutRequest.requestId`), so no two requests share one.
    struct Book {
        mapping(address shareholder => ICoreVaultPayouts.PayoutRequest) requests;
        uint96 requestCount;
        mapping(bytes32 requestId => mapping(uint256 spokeIndex => SpokeUnwindTypes.OrderResult)) legs;
        mapping(bytes32 requestId => uint256) marketCost;
        mapping(bytes32 requestId => uint256) leaverCost;
        mapping(bytes32 requestId => uint256) proceeds;
        mapping(bytes32 requestId => mapping(uint256 spokeIndex => bytes32[])) transits;
        mapping(bytes32 key => SpokeUnwindTypes.OrderResult) transitResults;
        mapping(bytes32 key => address) transitHolder;
        mapping(bytes32 key => uint256) reservedCredit;
        mapping(bytes32 key => uint256) paidMarketCost;
        mapping(bytes32 key => uint256) paidLeaverCost;
        mapping(bytes32 key => bool) proceedsConsumed;
    }
}
