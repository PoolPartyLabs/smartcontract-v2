// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title SpokeIncomeTypes
/// @notice The income collection's own state in the Spoke Vault (`SpokeVaultIncome`, `SpokeIncomeLib`) and the result
///         record the Core Vault reads from the report (`ReportCodec.Report.collectionResults`).
/// @dev WP-07 D1: the income work adds fields only to `Book` and edits only this types file, never `SpokeVaultTypes`.
library SpokeIncomeTypes {
    /// @notice Most collection results a report carries: the last ones, by result id (WP-10 plan item 5).
    uint256 internal constant REPORTED_RESULTS = 8;

    /// @notice What one executed collection order sent home, as the Core Vault reads it (DEC-122 item 5, DEC-161).
    /// @dev The Hub converts the result when the Income transfer `transitId` is credited: each token's rate is the
    ///      dollars credited times its share of `obtained`, over `sold` (WP-10 plan item 5; DEC-166 item 2: the sale and
    ///      bridge costs enter the rate). An execution that sent nothing still writes a result (zero `transitId`,
    ///      empty arrays) so the Hub learns the spoke ran the round.
    /// @param resultId One-based counter of this vault's results.
    /// @param round The Core Vault's collection round the order served (`OrderCodec.Order.requestId`).
    /// @param transitId The Income send carrying the dollars; zero when nothing was sent. A send whose refund came back
    ///        is sent again and this field names the new send (DEC-066: an expired send is refunded to the vault).
    /// @param amountSent Base token units sent.
    /// @param tokens Ledger tokens sold or sent, base token first.
    /// @param sold Units of each token taken out of the collected income bucket (the base token at face value).
    /// @param obtained Base token units each token yielded (the base token: the units themselves).
    struct CollectionResult {
        uint64 resultId;
        uint64 round;
        bytes32 transitId;
        uint256 amountSent;
        address[] tokens;
        uint256[] sold;
        uint256[] obtained;
    }

    /// @notice The income collection's state inside `SpokeVaultTypes.State`.
    /// @param reportBlob What the next reports carry as `ReportCodec.Report.collectionResults`:
    ///        `abi.encode(CollectionResult[])` of the last `REPORTED_RESULTS` results, rewritten at every execution.
    /// @param resultCount Results written so far.
    /// @param results Every result by id.
    /// @param unsentSold Units sold by executions that could not send (the bridge refused the amount); they join the
    ///        next result that is sent, so the Hub converts every sale once.
    /// @param unsentObtained Base units those sales obtained, per token.
    /// @param unsentBase Base units of the collected income bucket that belong to `unsentObtained`.
    /// @param resendBase Base units of the collected income bucket that belong to results whose send was refunded.
    /// @param awaitingResend Results whose send was refunded and is not sent again yet.
    struct Book {
        bytes reportBlob;
        uint64 resultCount;
        mapping(uint64 resultId => CollectionResult) results;
        mapping(address token => uint256) unsentSold;
        mapping(address token => uint256) unsentObtained;
        uint256 unsentBase;
        uint256 resendBase;
        mapping(uint64 resultId => bool) awaitingResend;
    }
}
