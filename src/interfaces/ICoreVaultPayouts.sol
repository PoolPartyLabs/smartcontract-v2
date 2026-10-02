// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICoreVaultPayouts
/// @notice Payout Requests and Payouts of the Core Vault: the request, the claim with its automatic unwind, the
///         receipts and their events (DEC-020, DEC-024, DEC-047, DEC-065, DEC-074, DEC-075). Part of ICoreVault.
/// @dev Split out of ICoreVault (WP-07 A4) so the payout path's types, events, errors and verbs sit with
///      `CoreVaultPayout` and `CoreVaultPayoutLogic`. ICoreVault inherits it: the Core Vault's selectors, event
///      topics and error selectors are unchanged; the ABI's `internalType` of the moved types names this interface.
///      `NavConsolidation` is carried by the deposit event of ICoreVault too (DEC-083: every mint and burn).
interface ICoreVaultPayouts {
    /// @notice Payout speed (DEC-075).
    enum PayoutMode {
        Instant,
        Standard
    }

    /// @notice The open Payout Request of a Shareholder (DEC-024: at most one per address, never cancellable).
    /// @param mode Instant or Standard.
    /// @param open Whether the request is open.
    /// @param requestedAt Timestamp of the request.
    /// @param termEndsAt Standard: `requestedAt + standardPayoutTerm` (DEC-060, DEC-154); Instant: `requestedAt`.
    /// @param usdcRequested Gross USDC amount requested (DEC-020, DEC-023).
    /// @param usdcOutstanding USDC still to pay after Partial Payouts (DEC-068).
    /// @param reserved USDC held in the Payout Reserve for this request; Standard only (DEC-072, DEC-077, DEC-095).
    struct PayoutRequest {
        PayoutMode mode;
        bool open;
        uint64 requestedAt;
        uint64 termEndsAt;
        uint256 usdcRequested;
        uint256 usdcOutstanding;
        uint256 reserved;
    }

    /// @notice How Share Assets were consolidated for a mint or burn (DEC-083). Carried by every mint and burn event.
    /// @param chainsSummed Number of chains whose value was summed (hub included).
    /// @param reportBlockNumbers Block of each spoke report used, in Mandate spoke order.
    /// @param reportSequences Sequence of each spoke report used, in Mandate spoke order.
    /// @param oldestReportAge Age in seconds of the oldest spoke report used.
    /// @param inFlightValue In-flight Value included, on its own line.
    struct NavConsolidation {
        uint256 chainsSummed;
        uint64[] reportBlockNumbers;
        uint64[] reportSequences;
        uint256 oldestReportAge;
        uint256 inFlightValue;
    }

    /// @notice Result of a Payout or Partial Payout.
    /// @param mode Instant or Standard.
    /// @param usdcRequested Gross amount of the request (DEC-020).
    /// @param sharesBurned Whole shares burned, rounded down (DEC-077).
    /// @param usdcGross `ShareMath.usdcFor(sharesBurned, sharePrice)`, never above the amount requested (DEC-077).
    /// @param payoutFee Payout Fee to Operating Cash, Instant only (DEC-075, DEC-102).
    /// @param flowFee Protocol flow fee (DEC-106; incidence on payouts is the LC-143 reading, OPEN).
    /// @param usdcPaid USDC transferred to the Shareholder.
    /// @param usdcOutstanding Amount still open after a Partial Payout (DEC-068); 0 for a full Payout.
    /// @param sharePrice Share Price used for the burn (DEC-105: one price for the whole request).
    /// @param shareAssets Numerator of that price.
    /// @param totalShares Denominator of that price, before the burn.
    /// @param unwindProceeds USDC realized by an automatic unwind in this claim; 0 when Idle paid.
    /// @param payoutSettlementPrice Realized unwind proceeds per whole share burned, same scale as Share Price;
    ///        event-only measure (DEC-084, DEC-105); 0 when nothing was unwound.
    /// @param closedBelowOneShare True when the request closed with no share burned and nothing paid because its
    ///        outstanding amount was below one share's price at this claim's Share Price (DEC-077 rounds the burn
    ///        down; final verification: a zero-share close is explicit, never a silent zero receipt).
    struct PayoutReceipt {
        PayoutMode mode;
        uint256 usdcRequested;
        uint256 sharesBurned;
        uint256 usdcGross;
        uint256 payoutFee;
        uint256 flowFee;
        uint256 usdcPaid;
        uint256 usdcOutstanding;
        uint256 sharePrice;
        uint256 shareAssets;
        uint256 totalShares;
        uint256 unwindProceeds;
        uint256 payoutSettlementPrice;
        bool closedBelowOneShare;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A Payout Request was opened (DEC-024, DEC-077: nothing is burned or locked).
    event PayoutRequested(
        address indexed shareholder, PayoutMode indexed mode, uint256 usdcRequested, uint256 reserved, uint64 termEndsAt
    );

    /// @notice A Payout closed the request (DEC-074, DEC-083).
    event PayoutExecuted(address indexed shareholder, PayoutReceipt receipt, NavConsolidation consolidation);

    /// @notice A Partial Payout paid part of the request and left the rest open (DEC-068, DEC-074).
    event PartialPayoutExecuted(address indexed shareholder, PayoutReceipt receipt, NavConsolidation consolidation);

    /// @notice An automatic unwind reverted; the claim continues with the Idle available (DEC-056: exits stay open;
    ///         DEC-068: Partial Payout).
    event UnwindForPayoutFailed(uint256 usdcTarget);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    error PayoutRequestAlreadyOpen(address shareholder);
    error NoOpenPayoutRequest(address shareholder);
    error PayoutTermNotEnded(uint64 termEndsAt);
    error NoShares(address shareholder);

    /// @notice A Payout Request below one share's price at the current Share Price, which could never burn a share
    ///         (DEC-035 spirit, DEC-077; final verification).
    error PayoutBelowOneShare(uint256 usdcAmount, uint256 sharePrice);

    // ---------------------------------------------------------------------------------------------------------------
    // Shareholder verbs (DEC-020, DEC-024, DEC-047, DEC-065)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Opens the caller's Payout Request for a gross USDC amount (DEC-020, DEC-023, DEC-024).
    /// @dev Shares are neither locked nor burned (DEC-077). The request is priced at the current Share Price as a
    ///      claim would be (payout liveness: last known values on a failing dependency, never a revert on age). Reverts
    ///      `PayoutBelowOneShare` when `usdcAmount` buys less than one whole share at that price (DEC-035 spirit,
    ///      DEC-077; final verification). Standard: reserves
    ///      `min(usdcAmount, ShareMath.usdcFor(balance, sharePrice), freeIdle())` in the Payout Reserve and starts the
    ///      term (DEC-060, DEC-072, DEC-095); the bound by the requester's share value at request time is an OPEN
    ///      reading (docs/OPEN-QUESTIONS.md FV-OQ-1, DEC-017, DEC-020, DEC-024): the most a request can ever pay is
    ///      the holder's whole balance (DEC-020), so a holder cannot lock more Free Idle than its shares are worth.
    ///      The requested amount itself is kept as asked (DEC-020: an insufficient balance burns all at the claim).
    ///      Instant: no reserve (DEC-095).
    function requestPayout(uint256 usdcAmount, PayoutMode mode) external;

    /// @notice Executes the caller's Payout Request: burn and pay atomically (DEC-047, DEC-065, DEC-074). Only the
    ///         requester. Unlike an ERC-7540 claim, it runs the missing unwind and pays in the same transaction.
    /// @dev Idle first (Instant: Free Idle only, never the Payout Reserve; Standard: its reserve, then Free Idle,
    ///      DEC-095); otherwise automatic unwind in Mandate order of the shortfall plus 2% (DEC-069, DEC-081, DEC-097),
    ///      of hub positions only, so no post-unwind spoke report is needed before burning (DEC-105, erratum 11 reading);
    ///      the claim is priced again after the unwind. Burns
    ///      `ShareMath.sharesToBurn(outstanding, sharePrice)` capped at the balance (DEC-020, DEC-077). A full burn
    ///      pays all Attributed Income payable now in the same transaction (DEC-045). Partial Payout when not
    ///      everything can be paid (DEC-068). When the outstanding amount is below one share's price at the claim's
    ///      Share Price, the request closes with nothing burned or paid, the reserve is released and the receipt
    ///      carries `closedBelowOneShare = true` in `PayoutExecuted` (DEC-077; final verification).
    /// @param unwindHints Parameters forwarded to `ISpokeVault.unwindForPayout`; empty when Idle covers the request.
    function claimPayout(bytes calldata unwindHints) external returns (PayoutReceipt memory receipt);

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A Shareholder's Payout Request.
    function payoutRequest(address shareholder) external view returns (PayoutRequest memory);

    /// @notice Payout Fee on Instant Payouts, bps; immutable (DEC-006, DEC-102, DEC-110).
    function payoutFeeBps() external view returns (uint16);

    /// @notice Standard Payout term, seconds: 72 hours in every fund, a protocol constant (DEC-154; corrects DEC-060,
    ///         DEC-095 item 5).
    function standardPayoutTerm() external view returns (uint32);
}
