// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAcrossMessageHandler} from "./external/IAcrossMessageHandler.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {Transit, TransferKind, ExpensePayer} from "./FundTypes.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";

/// @title ICoreVault
/// @notice Hub Chain contract of a fund: custody of Idle USDC, the Share ledger, Payout Requests and Payouts, the
///         Attributed Income bucket and Income Withdrawal, sends to spokes and the transit state machine.
/// @dev DEC-011: deposits and payouts only on the Hub Chain. DEC-054: never talks to adapters or collectors; it reads
///      the hub Spoke Vault directly and spoke values from the ValueReportReceiver. DEC-022, DEC-058: not upgradeable.
///      Every value-moving entry point is `nonReentrant` and follows checks-effects-interactions.
/// @dev Value bases (DEC-042, DEC-083, DEC-084, DEC-098, DEC-104):
///      Share Assets = Idle (Payout Reserve included) + hub Spoke Vault Unallocated Balance and position principal +
///      In-flight Value at the amount that will arrive (DEC-085) + each spoke's principal and Unallocated Balance from
///      its last accepted report. Excludes Operating Cash, Attributed Income and external rewards (DEC-078, DEC-092).
///      Gross Assets = Share Assets + Operating Cash + Attributed Income (collected or not) + external rewards;
///      informational only (DEC-098, DEC-103). Pricing of non-USDC quantities goes through IPriceSource (OPEN).
/// @dev Share Price is `ShareMath.sharePrice(shareAssets, totalShares)`: USDC base units per whole share scaled by
///      1e18; 1e24 = 1.00 USDC.
interface ICoreVault is IAcrossMessageHandler {
    /// @notice Payout speed (DEC-075).
    enum PayoutMode {
        Instant,
        Standard
    }

    /// @notice The open Payout Request of a Shareholder (DEC-024: at most one per address, never cancellable).
    /// @param mode Instant or Standard.
    /// @param open Whether the request is open.
    /// @param requestedAt Timestamp of the request.
    /// @param termEndsAt Standard: `requestedAt + standardPayoutTerm` (DEC-060); Instant: `requestedAt`.
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
    // Events (names per DEC-074, DEC-075)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Shares were minted for a deposit (DEC-009, DEC-035, DEC-071). Carries the price numerator and
    ///         denominator.
    /// @dev DEC-083: every mint and every burn publishes how its Share Assets were consolidated (chains summed, block
    ///      and sequence of each spoke report, age of the oldest report, In-flight Value on its own line), so the
    ///      mint event carries the same `NavConsolidation` as `PayoutExecuted` and `PartialPayoutExecuted`.
    event Deposited(
        address indexed shareholder,
        uint256 usdcForShares,
        uint256 flowFee,
        uint256 shares,
        uint256 sharePrice,
        uint256 shareAssets,
        uint256 totalShares,
        NavConsolidation consolidation
    );

    /// @notice A Payout Request was opened (DEC-024, DEC-077: nothing is burned or locked).
    event PayoutRequested(
        address indexed shareholder, PayoutMode indexed mode, uint256 usdcRequested, uint256 reserved, uint64 termEndsAt
    );

    /// @notice A Payout closed the request (DEC-074, DEC-083).
    event PayoutExecuted(address indexed shareholder, PayoutReceipt receipt, NavConsolidation consolidation);

    /// @notice A Partial Payout paid part of the request and left the rest open (DEC-068, DEC-074).
    event PartialPayoutExecuted(address indexed shareholder, PayoutReceipt receipt, NavConsolidation consolidation);

    /// @notice Attributed Income was paid without burning shares (DEC-025, DEC-029, DEC-073), or with a full burn
    ///         (DEC-045).
    event IncomeWithdrawn(address indexed shareholder, address indexed token, uint256 amount);

    /// @notice Capital was sent to a spoke. Cross-chain fields: hub chain id, destination chain id, transit id.
    event SentToSpoke(bytes32 indexed transitId, uint256 indexed spokeIndex, Transit transit, uint256 hubChainId);

    /// @notice A spoke report confirmed a hub-to-spoke transit's arrival (DEC-066, DEC-090).
    event TransitArrived(
        bytes32 indexed transitId, uint256 indexed spokeIndex, uint256 amountArrived, uint64 reportSequence
    );

    /// @notice A transit's expiry was attested; the Spoke Cap is released, Share Assets still count it (DEC-066).
    event TransitExpiryAttested(bytes32 indexed transitId, uint256 indexed spokeIndex, address indexed attester);

    /// @notice A transit's refund was pulled from its escrow back to Idle (DEC-066).
    event TransitRefundRecognized(bytes32 indexed transitId, uint256 indexed spokeIndex, uint256 amount);

    /// @notice The bridge adapter refused or failed `noteExpiry` for an expired transit; the outcome went through
    ///         anyway (DEC-056, DEC-162), and the adapter's fee rule did not step up for it.
    event BridgeExpiryNoteFailed(bytes32 indexed transitId, address indexed bridgeAdapter);

    /// @notice A spoke-to-hub transfer arrived through `handleV3AcrossMessage`. `matched` is false when no accepted
    ///         report lists the transit yet; such an amount is held apart until matched (DEC-080).
    event TransitReceived(
        bytes32 indexed transitId, uint256 indexed originChainId, TransferKind kind, uint256 amount, bool matched
    );

    /// @notice The Core Vault applied a newly accepted spoke report (arrivals, income).
    event ReportAccepted(
        uint256 indexed spokeIndex, uint64 reportSequence, uint64 blockNumber, uint64 timestamp, uint256 transitsArrived
    );

    /// @notice An Operating Expense was paid, with its funding source (DEC-041). `shareholder` is zero for a
    ///         fund-level expense.
    event OperatingExpensePaid(
        uint256 indexed chainId, address indexed shareholder, bytes32 indexed kind, uint256 amount, ExpensePayer payer
    );

    /// @notice Hub Operating Cash was topped up from Share Assets (DEC-096, DEC-100).
    event OperatingCashToppedUp(uint256 amount, uint256 balance);

    /// @notice The manager changed the hub Operating Cash floor and top-up (DEC-096).
    event OperatingCashParametersSet(uint256 floor, uint256 topUp);

    /// @notice Free Idle was moved to the hub Spoke Vault's Unallocated Balance (DEC-017, DEC-072).
    event AllocatedToHubSpokeVault(uint256 amount);

    /// @notice The hub Spoke Vault returned USDC to Idle.
    event ReturnedToIdle(uint256 amount);

    /// @notice Collected income reached the Core Vault and was split there (ruling 2026-09-29; DEC-107, DEC-109):
    ///         `amount` is the gross collected amount, `managerFee` the manager portion transferred to the
    ///         ManagerFeeVault, `protocolSlice` the protocol portion transferred to the Protocol Recipient (read from the
    ///         ManagerRegistry at this moment as `protocolSliceBps`, DEC-106, DEC-110); the rest entered the
    ///         shareholders' accumulator.
    event CollectedIncomeReceived(
        address indexed token, uint256 amount, uint256 managerFee, uint256 protocolSlice, uint16 protocolSliceBps
    );

    /// @notice A transfer to `recipient` failed, so the amount is owed to it and waits in the Core Vault, outside every
    ///         value base: a fee to the Protocol Recipient or the ManagerFeeVault (security review S-12), or a full
    ///         exit's income to the holder (independent review, plan CF-2).
    event FeeAccrued(address indexed token, address indexed recipient, uint256 amount);

    /// @notice An owed fee was paid to its recipient (security review S-12).
    event OwedFeePaid(address indexed token, address indexed recipient, uint256 amount);

    /// @notice The manager lowered the manager fee (DEC-110).
    event ManagerFeeDecreased(
        uint16 previousPerformanceFeeBps,
        uint16 newPerformanceFeeBps,
        uint16 previousManagementFeeBps,
        uint16 newManagementFeeBps
    );

    /// @notice Balance above the ledger was swept (DEC-080, DEC-096, DEC-101).
    event ExcessSwept(address indexed token, address indexed recipient, uint256 amount);

    /// @notice DEC-041, the explicit "insufficient cash" state: Operating Cash was below its floor and Free Idle could
    ///         not fund the whole top-up, so cash stays unable to pay and the next expense falls through to Share Assets.
    ///         `toppedUp` is what the top-up could take, below the configured top-up. Never emitted on a routine
    ///         top-up.
    event OperatingCashInsufficient(uint256 balance, uint256 floor, uint256 toppedUp);

    /// @notice An automatic unwind reverted; the claim continues with the Idle available (DEC-056: exits stay open;
    ///         DEC-068: Partial Payout).
    event UnwindForPayoutFailed(uint256 usdcTarget);

    /// @notice A payout could not read the hub Spoke Vault's report and used its last known value (payout liveness,
    ///         DEC-021, DEC-056).
    event HubValuationFallback(uint256 lastHubValue);

    /// @notice A payout could not read `token`'s price and used its last known price (payout liveness, DEC-021, DEC-056;
    ///         0 when the token was never priced).
    event PriceFallback(address indexed token, uint256 lastPrice1e18);

    /// @notice A spoke-to-hub arrival or its remainder was held apart because no report listed it or the listed amount
    ///         was already credited (DEC-080, OQ-01).
    event ArrivalHeldApart(bytes32 indexed transitId, uint256 indexed originChainId, TransferKind kind, uint256 amount);

    /// @notice An arrival no accepted report ever listed was credited to Idle as Principal once no report could list
    ///         it any more (security review S-4).
    event UnlistedArrivalRecovered(bytes32 indexed transitId, uint256 indexed originChainId, uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    error NotManager(address caller);
    error NotReportReceiver(address caller);
    error NotHubSpokeVault(address caller);
    error NotAcrossSpokePool(address caller);
    error ZeroAmount();
    error BelowMinFirstDeposit(uint256 amount, uint256 minFirstDeposit);
    error DepositBelowOneShare(uint256 usdcNet, uint256 sharePrice);

    /// @notice The Share Price is below one USDC base unit per whole share, where whole shares would be charged nothing
    ///         (independent verification plan MM-3).
    error SharePriceBelowOneUnit(uint256 sharePrice);
    error SharesBelowMinimum(uint256 shares, uint256 minShares);
    error StaleSpokeReport(uint256 spokeIndex);
    error StalePrice(address token, uint256 updatedAt);
    error PayoutRequestAlreadyOpen(address shareholder);
    error NoOpenPayoutRequest(address shareholder);
    error PayoutTermNotEnded(uint64 termEndsAt);
    error NoShares(address shareholder);
    error InsufficientFreeIdle(uint256 requested, uint256 available);

    /// @notice A Payout Request below one share's price at the current Share Price, which could never burn a share
    ///         (DEC-035 spirit, DEC-077; final verification).
    error PayoutBelowOneShare(uint256 usdcAmount, uint256 sharePrice);
    error UnknownSpoke(uint256 spokeIndex);
    error SpokeCapExceeded(uint256 spokeIndex, uint256 used, uint256 amount, uint256 spokeCap);
    error BridgeAdapterUnavailable(address bridgeAdapter);
    error UnknownTransit(bytes32 transitId);
    error InvalidTransitState(bytes32 transitId, uint8 state);
    error FillDeadlineNotReached(bytes32 transitId, uint32 fillDeadline);
    error ExpiryNotProvable(bytes32 transitId);
    error NoRefund(bytes32 transitId);
    /// @notice The hub has accepted no report from that spoke yet, so it may not fund it (security review S-14).
    error SpokeNotReporting(uint256 spokeIndex);
    /// @notice No arrival of that transit is held apart without a listing (security review S-4).
    error NothingToRecover(bytes32 transitId);
    /// @notice No accepted report of the spoke was built after `builtAfter` (the last unlisted arrival plus one report
    ///         lifetime), so a report could still list the transit or still counts it on the spoke (security review
    ///         S-4).
    error RecoveryNotReady(bytes32 transitId, uint256 builtAfter);
    error WrongFund(bytes32 fundId);
    /// @notice A report came from a Spoke Vault running another Mandate than the Core Vault's (security review S-6).
    error WrongMandate(bytes32 mandateHash);
    error UnexpectedToken(address token);
    error ManagerFeeNotDecreasing();
    error ManagementFeeNotSupported(uint16 bps);
    error UnknownIncomeToken(address token);
    error ZeroAddress();
    error UsdcMismatch(address configured, address mandateUsdc);
    error NotOnHubChain(uint256 chainId, uint256 hubChainId);
    error FlowFeeAboveCap(uint16 bps);
    error BridgeTargetUnset(address bridgeAdapter);

    /// @notice DEC-080: a credit call is not backed by tokens above the ledger.
    error UnbackedCredit(address token, uint256 amount, uint256 unledgered);

    /// @notice The adapter's call does not match what the vault requires: the pinned target, an amount to arrive above
    ///         zero and not above the amount sent, and a fill deadline in the future.
    error BridgeCallMismatch(address bridgeAdapter);

    /// @notice A token movement did not match the expected amount (IBridgeAdapter custody rule 3, escrow release).
    error BalanceChangeMismatch(uint256 expected, uint256 actual);

    /// @notice The bridge adapter's runtime code changed since creation (Q17-4 reading O2).
    error BridgeAdapterCodehashMismatch(address bridgeAdapter);

    // ---------------------------------------------------------------------------------------------------------------
    // Shareholder verbs
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Deposits USDC and mints whole shares in the same transaction (DEC-009, DEC-071).
    /// @dev DEC-061, DEC-095: the first deposit is at least `minFirstDeposit`. DEC-106: the flow fee is taken from the
    ///      amount before pricing (MVP reading, OPEN). DEC-035: shares are `floor(net / sharePrice)` whole shares and
    ///      only `shares * sharePrice` (truncated) is charged; the rest stays in the wallet; revert below one share or
    ///      below `minShares`. DEC-014, Q60: income checkpoint before the mint. Q57 reading (OPEN): reverts with
    ///      `StaleSpokeReport` when a spoke's last accepted report is past its max age, and with `StalePrice` when a
    ///      price is older than its feed's `maxPriceAge` (OQ-10).
    /// @return shares Whole shares minted, in base units.
    /// @return usdcCharged USDC pulled from the depositor: `usdcForShares + flowFee`.
    function deposit(uint256 usdcAmount, uint256 minShares) external returns (uint256 shares, uint256 usdcCharged);

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

    /// @notice Pays the caller's Attributed Income in `token` without burning shares (DEC-025, DEC-029, DEC-073).
    /// @dev No Payout Fee, no flow fee (LC-143 reading), not a Payout Request (DEC-029). Checkpoint first. LC-100
    ///      (OPEN): pays `min(owed, collectedIncome(token))`.
    function withdrawIncome(address token) external returns (uint256 amount);

    /// @notice Pays `recipient` every transfer in `token` that could not be made to it when due: a fee, or a full
    ///         exit's Attributed Income. Permissionless.
    /// @dev Security review S-12 (DEC-106, DEC-107, DEC-109): the flow fee, the protocol slice and the manager fee are
    ///      transferred when charged; a transfer that fails (a USDC blocklist entry on the fee wallet, a reverting
    ///      recipient) no longer reverts the Shareholder's deposit, claim or the income collection but is owed here.
    ///      Independent review (plan CF-2, DEC-021): the same holds for the income a full burn pays in each token
    ///      (DEC-045); the holder is then the recipient. Reverts if the transfer still fails.
    function claimOwedFees(address token, address recipient) external returns (uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Permissionless verbs
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Attests that a hub-to-spoke transit expired without arriving (DEC-066). Permissionless.
    /// @dev Requires the fill deadline to have passed and proof of non-arrival: a spoke report built after the
    ///      deadline that does not list the transit and lists fewer than `ReportCodec.ARRIVAL_WINDOW` arrivals (a full
    ///      window cannot prove absence, OQ-09), or the deadline plus the report lifetime having passed. With a
    ///      report's proof it releases the Spoke Cap; on the time path alone the cap stays held until the arrival is
    ///      confirmed or the refund recognized (security review S-13). Share Assets keep counting the transit until its
    ///      refund is recognized (QB11, QB10 OPEN). DEC-162: with a report's proof, the transit's bridge adapter is
    ///      told the send expired (`IBridgeAdapter.noteExpiry`, in try/catch, DEC-056).
    function attestExpiry(bytes32 transitId) external;

    /// @notice Pulls an expired transit's refund from its escrow back to Idle (DEC-066, QA6). Permissionless.
    /// @dev Only for a transit in state ExpiryAttested (DEC-066, DEC-090: Sent -> ExpiryAttested -> RefundRecognized)
    ///      whose escrow holds at least `amountSent` (DEC-063: Across refunds the full input amount); reverts
    ///      `InvalidTransitState` or `NoRefund` otherwise. Exactly `amountSent` is credited to Idle; any surplus in the
    ///      escrow reaches the Core Vault unledgered and is swept as excess (DEC-080). DEC-162: after an attestation by
    ///      time alone, the transit's bridge adapter is told the send expired here (in try/catch, DEC-056).
    function recognizeRefund(bytes32 transitId) external returns (uint256 amount);

    /// @notice Credits to Idle, as Principal, what arrived from spoke `spokeIndex` for `transitId` while no accepted
    ///         report of that spoke ever listed it, once no report can list it any more. Permissionless.
    /// @dev Security review S-4 (DEC-080, DEC-104, OQ-01): a send home is filled within minutes and credited only
    ///      against a listing, but a spoke lists it only until `fillDeadline + ReportCodec.HUB_BOUND_RETENTION`; if no
    ///      report built in that window is accepted (keeper, guardian or sequencer outage) the fund's own USDC would
    ///      stay in `unmatchedArrivals` for good. Recovery opens once the spoke's latest accepted report was built more
    ///      than one report lifetime (clock-skew margin) after the last unlisted arrival for that id and still does
    ///      not list it: the transfer is then past the spoke's listing retention (or was never the spoke's) and that
    ///      report's principal no longer counts it, so crediting Idle counts it once (cross-check of the independent
    ///      review: a delay counted from the first arrival could be started early with dust, and a report outage left
    ///      the transfer counted on the spoke and in Idle at once). The amount is added to the transit's credited
    ///      total, so a later listing of the same id nets it out; an Income transfer recovered this way reaches holders
    ///      as Principal (no fee split). Reverts `UnknownSpoke`, `NothingToRecover` or `RecoveryNotReady`.
    function recoverUnlistedArrival(uint256 spokeIndex, bytes32 transitId) external returns (uint256 amount);

    /// @notice Sends `balanceOf(token)` minus every ledger amount of `token` to the excess recipient. Permissionless.
    /// @dev DEC-080, DEC-096, DEC-101. Never sweeps ledger value (Idle, Operating Cash, collected income, owed fees).
    function sweepExcess(address token) external returns (uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Manager verbs
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Moves Free Idle to the hub Spoke Vault's Unallocated Balance. Manager only (DEC-017, DEC-072).
    function allocateToHubSpokeVault(uint256 usdcAmount) external;

    /// @notice Sends Free Idle to a spoke through the Mandate bridge adapter of priority `bridgeRank`. Manager only.
    /// @dev DEC-037, DEC-095: reverts unless `spoke value + in flight to the spoke (amount sent) + usdcAmount <=
    ///      spokeCap`. DEC-087: the vault fixes the recipient (the Mandate Spoke Vault), the token pair (USDC to the
    ///      spoke token) and the amount sent. DEC-158, DEC-162: the manager passes no bridge parameter; the bridge
    ///      adapter fixes the amount to arrive and every other term with its own fee rule, and no bridge fee cap lives
    ///      in the fund (DEC-156). DEC-021, DEC-056, DEC-058: reverts with `BridgeAdapterUnavailable` when the bridge
    ///      adapter is paused or deprecated. DEC-066: a per-send TransitEscrow is the depositor. DEC-085: counted in
    ///      Share Assets at the adapter's amount to arrive. Custody: the vault executes the call
    ///      `IBridgeAdapter.buildSend` returns against the pinned target, with an exact approval reset to zero; the
    ///      adapter never holds USDC (DEC-087).
    /// @param bridgeData Opaque input the bridge adapter verifies itself (reserved for a signed API quote, R-162-B);
    ///        empty for the Across adapter, which refuses anything else.
    function sendToSpoke(uint256 spokeIndex, uint256 usdcAmount, uint256 bridgeRank, bytes calldata bridgeData)
        external
        returns (bytes32 transitId);

    /// @notice Lowers the manager fee; it can never rise on a live fund (DEC-110). Manager only.
    /// @dev Ruling 2026-09-29: the performance fee is charged only when collected income reaches the Core Vault, so
    ///      no fee accrues between collections and nothing is left to settle at the old rate (DEC-110 "settling
    ///      accrued first" is empty); income collected afterwards is charged at the new rate. `newManagementFeeBps`
    ///      must stay 0 in the MVP (DEC-108, LC-144).
    function decreaseManagerFee(uint16 newPerformanceFeeBps, uint16 newManagementFeeBps) external;

    /// @notice Sets the hub Operating Cash floor and top-up. Manager only (DEC-096, DEC-100).
    function setOperatingCashParameters(uint256 floor, uint256 topUp) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Callbacks from the fund's own contracts (DEC-090: transitions only from the Mandate's contracts)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Applies a newly accepted report: confirms arrived transits, reconciles spoke-to-hub transfers and, if
    ///         the MVP recognizes spoke income on delivery, advances the index. ValueReportReceiver only.
    function onReportAccepted(uint256 spokeIndex) external;

    /// @notice Credits USDC the hub Spoke Vault transferred to Idle. Hub Spoke Vault only.
    function returnToIdle(uint256 usdcAmount) external;

    /// @notice Credits collected income the hub Spoke Vault transferred and splits it at once (ruling 2026-09-29): the
    ///         performance fee (DEC-107) times `amount`, of which the protocol slice (ManagerRegistry at this moment,
    ///         DEC-106, DEC-110) is transferred to the Protocol Recipient and the rest to the ManagerFeeVault, in kind
    ///         (DEC-109); the net enters the shareholders' accumulator and the collected balance. Hub Spoke Vault only.
    /// @dev This and a matched spoke-to-hub Income arrival are the only points where the income index advances;
    ///      uncollected income stays in its own bucket (DEC-092) and only informs Gross Assets.
    function receiveCollectedIncome(address token, uint256 amount) external;

    /// @notice Across fill callback for spoke-to-hub transfers. Only the Across SpokePool; only USDC.
    /// @dev Decodes TransitMessage and rejects another fund's id. Across passes no depositor, so the amount is credited
    ///      to Idle (Principal) or, split as in `receiveCollectedIncome`, to the collected income bucket (Income) only
    ///      when an accepted report lists the transit id as in flight to the hub; otherwise it is held apart until a
    ///      report matches it (DEC-080, DEC-104).
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes memory message) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Identity and wiring
    // ---------------------------------------------------------------------------------------------------------------

    function fundId() external view returns (bytes32);
    function mandateHash() external view returns (bytes32);
    /// @notice The Mandate as created. Its `performanceFeeBps` keeps the creation value after `decreaseManagerFee`;
    ///         the fee in force is `performanceFeeBps()` (independent review I-05).
    function mandate() external view returns (Mandate memory);
    function manager() external view returns (address);
    function usdc() external view returns (address);
    function shareToken() external view returns (address);
    function hubSpokeVault() external view returns (address);
    function reportReceiver() external view returns (address);
    function managerRegistry() external view returns (address);
    function priceSource() external view returns (address);
    function acrossSpokePool() external view returns (address);

    /// @notice Recipient of the protocol slice and the flow fee (DEC-106; LC-132: identity to confirm).
    function protocolRecipient() external view returns (address);

    /// @notice Recipient of swept excess balances (DEC-096, DEC-101; LC-132 OPEN).
    function excessRecipient() external view returns (address);

    /// @notice The fund's ManagerFeeVault, deployed by the Core Vault's constructor (ruling 2026-09-29, DEC-107).
    function managerFeeVault() external view returns (address);

    // ---------------------------------------------------------------------------------------------------------------
    // Value bases (DEC-072, DEC-083, DEC-084, DEC-085, DEC-098)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Total USDC in the Core Vault that backs shares, Payout Reserve included (DEC-055, DEC-072).
    function idle() external view returns (uint256);

    /// @notice Part of Idle reserved for Standard Payouts; always `<= idle()` (DEC-072).
    function payoutReserve() external view returns (uint256);

    /// @notice `idle() - payoutReserve()`: what the manager may allocate (DEC-017, DEC-072).
    function freeIdle() external view returns (uint256);

    /// @notice Share Assets in USDC base units (DEC-083, DEC-084).
    function shareAssets() external view returns (uint256);

    /// @notice Share Price, USDC base units per whole share scaled by 1e18 (DEC-061, DEC-084).
    function sharePrice() external view returns (uint256);

    /// @notice Gross Assets in USDC base units; informational only (DEC-098, DEC-103).
    function grossAssets() external view returns (uint256);

    /// @notice In-flight Value included in Share Assets, at the amount that will arrive (DEC-085).
    function inFlightValue() external view returns (uint256);

    /// @notice Hub Operating Cash (DEC-013, DEC-096, DEC-102).
    function operatingCash() external view returns (uint256);

    function operatingCashFloor() external view returns (uint256);
    function operatingCashTopUp() external view returns (uint256);

    /// @notice Spoke Cap usage of a spoke (DEC-037, DEC-066, DEC-095): a send must keep
    ///         `spokeValue + inFlightSent + inFlightToHub + amount <= spokeCap`.
    /// @return spokeValue Principal value of the spoke from its last accepted report.
    /// @return inFlightSent Amount sent to the spoke whose outcome is unknown, at the amount sent (DEC-066 C1).
    /// @return inFlightToHub The spoke's pending return leg: transfers home (Principal and Income) its last report lists
    ///         as in flight and the hub has not yet credited (DEC-066 B1).
    /// @return spokeCap The Mandate's Spoke Cap.
    function spokeCapUsage(uint256 spokeIndex)
        external
        view
        returns (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub, uint256 spokeCap);

    /// @notice Spoke-to-hub arrivals held apart: arrived before any report listed them, or above the listed amount;
    ///         outside every base and never swept (DEC-080, DEC-104, OQ-01).
    function unmatchedArrivals() external view returns (uint256);

    /// @notice A hub-to-spoke transit.
    function transit(bytes32 transitId) external view returns (Transit memory);

    /// @notice A Shareholder's Payout Request.
    function payoutRequest(address shareholder) external view returns (PayoutRequest memory);

    // ---------------------------------------------------------------------------------------------------------------
    // Attributed Income (DEC-014, DEC-092)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Income tokens of the fund (closed list from the Mandate pools).
    function incomeTokens() external view returns (address[] memory);

    /// @notice Attributed Income of `shareholder` in `token`, pending part included.
    function attributedIncome(address shareholder, address token) external view returns (uint256);

    /// @notice Collected income of `token` held by the Core Vault, payable now (LC-100).
    function collectedIncome(address token) external view returns (uint256);

    /// @notice Income recognized with no shares outstanding (LC-32 OPEN: retained).
    function ownerlessIncome(address token) external view returns (uint256);

    /// @notice Whether an ExpiryAttested transit still holds its Spoke Cap because its expiry was attested by time
    ///         alone (security review S-13).
    function spokeCapHeld(bytes32 transitId) external view returns (bool);

    /// @notice Amount in `token` owed to `recipient` because its transfer failed when due (fees, S-12; full-exit
    ///         income, plan CF-2).
    function owedFees(address token, address recipient) external view returns (uint256);

    /// @notice Accumulator state of an income token: index (Q128), remainder, ownerless, distributed and taken totals
    ///         (Q60 fitness functions).
    function incomeState(address token) external view returns (IncomeAccumulator.TokenIncome memory);

    // ---------------------------------------------------------------------------------------------------------------
    // Fees (DEC-102, DEC-106..110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Manager performance fee on collected income, bps (DEC-107); only decreases (DEC-110).
    function performanceFeeBps() external view returns (uint16);

    /// @notice Manager management fee, bps per year; 0 in the MVP (DEC-108, LC-144).
    function managementFeeBps() external view returns (uint16);

    /// @notice Protocol flow fee, bps; default 25, capped at 100 (DEC-106, DEC-110; where it is stored, LC-143 OPEN).
    function flowFeeBps() external view returns (uint16);

    /// @notice Payout Fee on Instant Payouts, bps; immutable (DEC-006, DEC-102, DEC-110).
    function payoutFeeBps() external view returns (uint16);

    /// @notice Standard Payout term, seconds (DEC-060, DEC-095).
    function standardPayoutTerm() external view returns (uint32);
}
