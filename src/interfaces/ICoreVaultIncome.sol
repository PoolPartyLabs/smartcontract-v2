// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

/// @title ICoreVaultIncome
/// @notice Attributed Income in the Hub dollar index, its collection on every chain, Income Withdrawal in USDC, owed
///         transfers and the manager fee of the Core Vault (DEC-014, DEC-045, DEC-117, DEC-122, DEC-124, DEC-128 item 4,
///         DEC-138, DEC-152, DEC-161, DEC-166, DEC-172, DEC-175). Part of ICoreVault.
/// @dev Split out of ICoreVault (WP-07 A4) so the income verbs, events and errors sit with `CoreVaultIncome` and
///      `CoreVaultIncomeLogic`. ICoreVault inherits it.
/// @dev The mechanism (checklist doc 10 section 2, DEC-161), per income source (`source` 0: the Hub positions; source
///      `1 + i`: spoke `i`), each a `DollarIncomeIndex`:
///      - Recognition (DEC-117, DEC-138): the Hub's income at every mint and burn, inside the valuation they already run,
///        from the hub Spoke Vault's monotonic counters; a spoke's from each accepted report's counters. A failed read
///        keeps the last counter and never blocks a mint or burn. Of each counter's advance, the performance fee
///        (`performanceFeeBps` at that moment, DEC-107) is owed in token units (D-40: one more owner at the same
///        collection rate) and the net enters the source's token index of the open interval (DEC-117 item 3, DEC-152).
///      - Collection (DEC-122, DEC-124, DEC-161, DEC-172): an Income Withdrawal request collects and sells the Hub's
///        income at once (`ISpokeVaultIncome.collectIncomeAll`) and publishes one collection order for the spokes
///        whose last report shows income; each spoke sells its income for its base token and sends it home as Income.
///        A collection closes the source's interval at its own rate per token, `dollars / units sold` (on a spoke the
///        dollars credited on the Hub, so the fund pays the sale and the bridge: DEC-166 item 2, DEC-175), stored for
///        holders who moved shares in the interval (DEC-161 item 2), and pays the fee part in USDC: the protocol slice
///        (ManagerRegistry, clamped to [500, 5,000], DEC-106, DEC-112) to the Protocol Recipient, the rest to the
///        ManagerFeeVault (DEC-124 item 2, DEC-128 item 4).
///      - Holders (DEC-014): every mint and burn settles the holder and records its per-token adjustment; Income
///        Withdrawal pays settled dollars in USDC (DEC-124), in every fund state (DEC-117 item 4), never by average
///        (DEC-161 item 3). A full burn pays every settled dollar (DEC-045).
interface ICoreVaultIncome {
    // ---------------------------------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice One income token of a source (`incomeToken`).
    /// @param registered Whether the token is one of the source's income tokens.
    /// @param interval Collections that converted the token so far (its open interval's number).
    /// @param openIndex Token units per share in the open interval, Q128.
    /// @param recognized Units the holders can claim in the open interval.
    /// @param counter Last counter recognized (the chain's monotonic income counter, Q60).
    /// @param feeUnits Units owed as performance fee, not yet converted (D-40).
    struct IncomeTokenState {
        bool registered;
        uint64 interval;
        uint256 openIndex;
        uint256 recognized;
        uint256 counter;
        uint256 feeUnits;
    }

    /// @notice The collection rounds' state (`incomeCollection`).
    /// @param round The latest collection round of the spokes (0 before the first order).
    /// @param attempt The latest attempt of that round (DEC-151 pattern: a retry is a new order).
    /// @param deadline When the latest order of the round expires (`OrderCodec.ORDER_LIFETIME`).
    /// @param pendingSpokes Bitmask of the spokes whose result for the round the Hub has not converted yet.
    /// @param openResults Spoke results the Hub knows and has not converted (waiting for their Income transfer).
    /// @param heldDollars USDC the Core Vault holds for holders: converted and not taken, plus Income credited and not
    ///        converted yet (part of the ledger, DEC-080).
    struct IncomeCollectionState {
        uint64 round;
        uint32 attempt;
        uint64 deadline;
        uint256 pendingSpokes;
        uint256 openResults;
        uint256 heldDollars;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Attributed Income was paid to `shareholder` in USDC (`token`), without burning shares (DEC-025, DEC-073)
    ///         or with a full burn (DEC-045).
    event IncomeWithdrawn(address indexed shareholder, address indexed token, uint256 amount);

    /// @notice Attributed Income due to `shareholder` could not be transferred (a USDC blocklist entry, a reverting
    ///         recipient): it is owed and waits in the Core Vault, paid by `claimOwedFees(token, shareholder)`
    ///         (independent review, plan CF-2; checklist doc 15, gap 16: emitted instead of `IncomeWithdrawn`).
    event IncomeTransferOwed(address indexed shareholder, address indexed token, uint256 amount);

    /// @notice A source's counter for `token` advanced to `cumulative` and the advance was recognized (DEC-117,
    ///         DEC-138): `fee` units owed as performance fee, `amount - fee` into the open interval's index for the
    ///         shares outstanding (`entered` false: no share existed, or the index skipped it; those units are nobody's
    ///         and their dollars stay out of every ledger).
    event IncomeRecognized(
        uint256 indexed source, address indexed token, uint256 cumulative, uint256 amount, uint256 fee, bool entered
    );

    /// @notice A source reported a counter for `token` below the last recognized (`reported < last`) or an advance
    ///         above the index's step bound; nothing was recognized and the last counter stays (Q60: never reverts).
    event IncomeCounterSkipped(uint256 indexed source, address indexed token, uint256 last, uint256 reported);

    /// @notice A collection closed a source's interval (DEC-161): `dollars` USDC for the units sold, of which `fee` paid
    ///         the performance fee (`protocolSlice` to the Protocol Recipient at `protocolSliceBps`, the rest to the
    ///         ManagerFeeVault, DEC-128 item 4) and `attributed` went to the holders; the rest (rounding, units nobody
    ///         was recognized for) stays out of every ledger. `ref` is the spoke's Income transfer, zero for the Hub.
    event IncomeCollectionClosed(
        uint256 indexed source,
        bytes32 indexed ref,
        uint256 dollars,
        uint256 attributed,
        uint256 fee,
        uint256 protocolSlice,
        uint16 protocolSliceBps
    );

    /// @notice The hub Spoke Vault's collection failed and was skipped (DEC-056); the Hub income waits for the next one.
    event HubIncomeCollectionFailed();

    /// @notice `shareholder` asked for an Income Withdrawal that waits for collection round `round` (DEC-122).
    event IncomeWithdrawalRequested(address indexed shareholder, uint64 indexed round);

    /// @notice A transfer to `recipient` failed, so the amount is owed to it and waits in the Core Vault, outside every
    ///         value base: a fee to the Protocol Recipient or the ManagerFeeVault (security review S-12).
    event FeeAccrued(address indexed token, address indexed recipient, uint256 amount);

    /// @notice An owed transfer was paid to its recipient (security review S-12).
    event OwedFeePaid(address indexed token, address indexed recipient, uint256 amount);

    /// @notice The management fee was booked for the time since the last accrual (DEC-114, D-33): `amount` more is
    ///         owed, `accrued` in total, a liability outside Share Assets until it is paid at fund closure.
    event ManagementFeeAccrued(uint256 amount, uint256 accrued);

    /// @notice The manager lowered the manager fee (DEC-110).
    event ManagerFeeDecreased(
        uint16 previousPerformanceFeeBps,
        uint16 newPerformanceFeeBps,
        uint16 previousManagementFeeBps,
        uint16 newManagementFeeBps
    );

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    error ManagerFeeNotDecreasing();

    /// @notice `source` is not an income source of this fund (0 for the Hub, `1 + i` for spoke `i`).
    error UnknownIncomeSource(uint256 source);

    /// @notice `shareholder` has no open Income Withdrawal request.
    error NoIncomeWithdrawalRequest(address shareholder);

    /// @notice The collection round `round` the request waits for is not converted on every spoke yet.
    error IncomeCollectionPending(uint64 round);

    /// @notice `msg.value` was sent but no collection order was published (it would stay in the Core Vault).
    error MessageFeeNotUsed(uint256 value);

    // ---------------------------------------------------------------------------------------------------------------
    // Shareholder verbs (DEC-025, DEC-045, DEC-073, DEC-117 item 4, DEC-122, DEC-124)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Asks for an Income Withdrawal: collects and converts the Hub positions' income now and publishes one
    ///         collection order for the spokes whose last report shows income, unless a round is already in flight, in
    ///         which case the request waits for it (DEC-122 items 1-2, DEC-161, DEC-172). Any fund state (DEC-117 item
    ///         4). `settleIncomeWithdrawal` pays once the round is converted on every spoke.
    /// @dev DEC-166, DEC-175 (MVP): the fund pays the sales and the bridge (they lower the conversion rate); the caller
    ///      pays the gas and the Wormhole message fee (`msg.value`, forwarded only when an order is published,
    ///      `MessageFeeNotUsed` otherwise). An order whose deadline passed before every spoke's result was converted is
    ///      published again (`attempt + 1`) by the next request. No minimum (DEC-166 item 3). DEC-160: no mint or burn,
    ///      so no fresh report is needed.
    /// @param maxLossBps Maximum loss of every sale of the collection against its mid, in bps; 0 or >= 10,000 for none
    ///        (D-23; DEC-144 consequence: none unless given).
    /// @return round The collection round the request waits for.
    function requestIncomeWithdrawal(uint16 maxLossBps) external payable returns (uint64 round);

    /// @notice Pays `shareholder` every settled dollar of Attributed Income in USDC once the collection round its request
    ///         waits for is converted on every spoke, and closes the request. Anyone; pays only the shareholder
    ///         (DEC-047 pattern).
    /// @dev No Payout Fee, no flow fee (DEC-075, DEC-113). A transfer that fails is owed (`IncomeTransferOwed`).
    function settleIncomeWithdrawal(address shareholder) external returns (uint256 amount);

    /// @notice DEC-145, DEC-161: anyone may persist bounded settlement progress for a holder in any fund state.
    /// @dev Returns false until complete. Call repeatedly before an Income Withdrawal, Payout burn, closed-fund exit
    ///      or closure finalization whose balance hook needs historical settlement. No collection request is required.
    function settleHolderIncome(address shareholder) external returns (bool complete);

    /// @notice Pays the caller every settled dollar of Attributed Income in USDC now, without waiting for a collection
    ///         (DEC-117 item 4). No Payout Fee, no flow fee.
    /// @dev DEC-145: a history exceeding the bounded settlement budget returns zero and persists progress. Repeat
    ///      before retrying a mint or burn; waiting lots and their historical collection rights are preserved.
    function withdrawIncome() external returns (uint256 amount);

    /// @notice Pays `recipient` every transfer in `token` that could not be made to it when due: a fee, or Attributed
    ///         Income. Permissionless.
    /// @dev Security review S-12 (DEC-106, DEC-107): a failed transfer never reverts the deposit, claim, collection or
    ///      Income Withdrawal that made it; it is owed here. Reverts if the transfer still fails.
    function claimOwedFees(address token, address recipient) external returns (uint256 amount);

    // ---------------------------------------------------------------------------------------------------------------
    // Manager verbs (DEC-110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Lowers the manager fee: the performance fee, the management fee or both; neither can rise on a live
    ///         fund and at least one must fall (DEC-110). Manager only.
    /// @dev DEC-110 ("settling what accrued first"): the Hub income earned so far is recognized at the old performance
    ///      fee and the management fee accrued so far is booked at the old rate (a payout-mode valuation) before the new
    ///      rates apply; spoke income is recognized at the rate in force when its report is accepted. DEC-182, DEC-184:
    ///      the performance fee never goes below 10% (`MandateLib.MIN_PERFORMANCE_FEE_BPS`; `ManagerFeeBelowMinimum`).
    function decreaseManagerFee(uint16 newPerformanceFeeBps, uint16 newManagementFeeBps) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice USDC of Attributed Income `shareholder` could withdraw now: settled plus converted since (DEC-161).
    function incomeOwed(address shareholder) external view returns (uint256);

    /// @notice Units of `token` of `source` attributed to `shareholder` and not converted yet (open interval, plus a
    ///         partial sale's carried part).
    function unconvertedIncome(address shareholder, uint256 source, address token) external view returns (uint256);

    /// @notice The state of `token` in income source `source` (0: the Hub; `1 + i`: spoke `i`). A source's tokens are
    ///         the Mandate tokens of its chain (the Hub: USDC first).
    function incomeToken(uint256 source, address token) external view returns (IncomeTokenState memory);

    /// @notice The collection rounds' state and the USDC held for holders.
    function incomeCollection() external view returns (IncomeCollectionState memory);

    /// @notice The collection round `shareholder`'s open Income Withdrawal request waits for, and whether one is open.
    function incomeWithdrawalRequest(address shareholder) external view returns (uint64 round, bool open);

    /// @notice Amount in `token` owed to `recipient` because its transfer failed when due (S-12, plan CF-2).
    function owedFees(address token, address recipient) external view returns (uint256);

    /// @notice Manager performance fee on income, bps (DEC-107); only decreases (DEC-110).
    function performanceFeeBps() external view returns (uint16);

    /// @notice Manager management fee, bps per year on Share Assets (DEC-108, DEC-114); only decreases (DEC-110).
    function managementFeeBps() external view returns (uint16);

    /// @notice Management fee owed now, in USDC: what was booked plus what accrued since, on the current Share Assets
    ///         net of it (DEC-114, D-33). Outside Share Assets; paid at fund closure. Reverts like `shareAssets`.
    function managementFeeAccrued() external view returns (uint256);
}
