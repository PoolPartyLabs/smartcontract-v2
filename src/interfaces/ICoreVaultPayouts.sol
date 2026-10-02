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
    /// @param requestId The request's id: the requester's address in the high 160 bits and the Core Vault's request
    ///        counter in the low 96 (`OrderCodec.Order.requestId`). The hub Spoke Vault remembers per id which
    ///        positions already delivered (DEC-151).
    /// @param maxLossBps The requester's maximum loss per sale of the automatic unwind, in bps, as given at the
    ///        request or at the last claim; 0 or >= 10,000 for none (DEC-140, DEC-148, D-23, DEC-178 item 2).
    struct PayoutRequest {
        PayoutMode mode;
        bool open;
        uint64 requestedAt;
        uint64 termEndsAt;
        uint256 usdcRequested;
        uint256 usdcOutstanding;
        uint256 reserved;
        bytes32 requestId;
        uint16 maxLossBps;
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
    /// @param payoutFee Payout Fee, Instant only (DEC-075, DEC-155); it stays in Idle, in USDC (DEC-144 items 4-5,
    ///        correcting DEC-102).
    /// @param flowFee Protocol flow fee on the gross amount (DEC-106, DEC-113).
    /// @param usdcPaid USDC transferred to the Shareholder: `usdcGross - payoutFee - flowFee`.
    /// @param usdcOutstanding Amount still open after a Partial Payout (DEC-068); 0 for a full Payout.
    /// @param sharePrice Share Price used for the burn (DEC-105: one price for the whole request, read after the
    ///        unwind).
    /// @param shareAssets Numerator of that price.
    /// @param totalShares Denominator of that price, before the burn.
    /// @param unwindProceeds USDC realized by an automatic unwind in this claim; 0 when Idle paid.
    /// @param payoutSettlementPrice Realized unwind proceeds per whole share burned, same scale as Share Price;
    ///        event-only measure (DEC-084, DEC-105); 0 when nothing was unwound.
    /// @param closedBelowOneShare True when the request closed with no share burned and nothing paid because its
    ///        outstanding amount was below one share's price at this claim's Share Price (DEC-077 rounds the burn
    ///        down; final verification: a zero-share close is explicit, never a silent zero receipt).
    /// @param requestId The request's id (`PayoutRequest.requestId`).
    /// @param cappedByManagerBase True when the manager's burn stopped at `ceil(peak / 2)` shares and the request
    ///        closed below the amount requested (DEC-146, DEC-183 item 1, D-27).
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
        bytes32 requestId;
        bool cappedByManagerBase;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A Payout Request was opened (DEC-024, DEC-077: nothing is burned or locked). An Instant one is claimed in
    ///         the same transaction, so `PayoutExecuted` or `PartialPayoutExecuted` follows it (DEC-120 item 1).
    event PayoutRequested(
        address indexed shareholder,
        PayoutMode indexed mode,
        bytes32 indexed requestId,
        uint256 usdcRequested,
        uint256 reserved,
        uint64 termEndsAt,
        uint16 maxLossBps
    );

    /// @notice A Payout closed the request (DEC-074, DEC-083).
    event PayoutExecuted(address indexed shareholder, PayoutReceipt receipt, NavConsolidation consolidation);

    /// @notice A Partial Payout paid part of the request and left the rest open (DEC-068, DEC-074).
    event PartialPayoutExecuted(address indexed shareholder, PayoutReceipt receipt, NavConsolidation consolidation);

    /// @notice An automatic unwind reverted as a whole; the claim continues with the Idle available (DEC-056: exits
    ///         stay open; DEC-068: Partial Payout). `reason` is the revert data (checklist doc 15, gap 3).
    event UnwindForPayoutFailed(bytes32 indexed requestId, bytes reason);

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

    /// @notice Opens the caller's Payout Request for a gross USDC amount (DEC-020, DEC-023, DEC-024). An Instant
    ///         request is also its claim: it runs `claimPayout`'s payout in the same transaction and returns its receipt
    ///         (DEC-120 item 1: the holder signs once; D-51). A Standard request returns an empty receipt.
    /// @dev Shares are neither locked nor burned by the request itself (DEC-077). The request is priced at the current
    ///      Share Price as a claim would be (payout liveness: last known values on a failing dependency). Reverts
    ///      `PayoutBelowOneShare` when `usdcAmount` buys less than one whole share at that price (DEC-035 spirit,
    ///      DEC-077; final verification). Standard: reserves
    ///      `min(usdcAmount, ShareMath.usdcFor(balance, sharePrice), freeIdle())` in the Payout Reserve and starts the
    ///      term (DEC-060, DEC-072, DEC-095); the bound by the requester's share value at request time is an OPEN
    ///      reading (docs/OPEN-QUESTIONS.md FV-OQ-1, DEC-017, DEC-020, DEC-024): the most a request can ever pay is
    ///      the holder's whole balance (DEC-020), so a holder cannot lock more Free Idle than its shares are worth.
    ///      The requested amount itself is kept as asked (DEC-020: an insufficient balance burns all at the claim).
    ///      Instant: no reserve (DEC-095); when nothing at all can be paid the whole request reverts.
    /// @param maxLossBps The requester's optional maximum loss per sale of the automatic unwind, in bps, measured
    ///        against the mid value before the sale; 0 or >= 10,000 for none (DEC-140, DEC-148, D-23, DEC-178 item 2).
    ///        Kept in the request; a later claim may replace it.
    function requestPayout(uint256 usdcAmount, PayoutMode mode, uint16 maxLossBps)
        external
        returns (PayoutReceipt memory receipt);

    /// @notice Executes the caller's open Payout Request: burn and pay atomically (DEC-047, DEC-065, DEC-074). Only the
    ///         requester. A Standard request after its term (DEC-154); an Instant one whose payout was partial
    ///         (DEC-068 (b)), as its next attempt (DEC-151).
    /// @dev DEC-160: every spoke with an accepted report must have a fresh one, else `StaleSpokeReport`, whether Idle
    ///      pays or not; the price-source fallback is unchanged (D-28). Idle first (Instant: Free Idle only, never the
    ///      Payout Reserve; Standard: its reserve, then Free Idle, DEC-067, DEC-095); otherwise the automatic unwind of
    ///      the hub Spoke Vault (`ISpokeVault.unwindForPayout`), whose proceeds reach Idle (DEC-080), then one Share
    ///      Price read after it (DEC-105). Burns `ShareMath.sharesToBurn(outstanding, sharePrice)` capped at the
    ///      balance (DEC-020, DEC-077; the manager: at the base, DEC-146, D-27). A full burn pays all Attributed Income
    ///      payable now in the same transaction (DEC-045). Partial Payout when not everything can be paid (DEC-068);
    ///      reverts `InsufficientFreeIdle` when nothing can. When the outstanding amount is below one share's price at
    ///      the claim's Share Price, the request closes with nothing burned or paid, the reserve is released and the
    ///      receipt carries `closedBelowOneShare = true` in `PayoutExecuted` (DEC-077; final verification).
    /// @param maxLossBps The requester's maximum loss per sale for this attempt, replacing the one kept in the request
    ///        (DEC-140 item 2, DEC-148: the next attempt may come with another maximum); 0 or >= 10,000 for none.
    function claimPayout(uint16 maxLossBps) external returns (PayoutReceipt memory receipt);

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
