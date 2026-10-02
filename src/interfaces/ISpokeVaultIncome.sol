// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ISpokeVaultIncome
/// @notice The Spoke Vault's income collection: on the Hub Chain, the collection the Core Vault runs at every Income
///         Withdrawal request; on a Spoke Chain, the executor of the Core Vault's collection orders (DEC-122, DEC-124,
///         DEC-161, DEC-172). Part of ISpokeVault.
/// @dev Split out of ISpokeVault (WP-07 A4) so the income verbs and their events sit with `SpokeVaultIncome`.
/// @dev DEC-124, DEC-161, DEC-172: a collection collects every position's income, sells every non-base token through
///      the chain's Mandate swap adapter into the base token (USDC on the hub, USDG on Robinhood Chain) and hands the
///      dollars to the Core Vault (on a spoke, as an Income send home), with what each token sold for, so the Hub's
///      dollar index converts each token at that collection's rate. DEC-122 item 4 (the manager converts income at any
///      time) is superseded (DEC-178 item 5: the conversion happens at the collection), so the manager has no income
///      swap and no Income send of its own.
interface ISpokeVaultIncome {
    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice A collection sold `amountIn` of collected income in `token` for `amountOut` of the base token through a
    ///         Mandate swap adapter (DEC-124, DEC-136, DEC-172).
    /// @dev Same fields as `ISpokeVault.Swapped` (checklist doc 15, gap 4: the limit the sale was accepted under).
    /// @param spotOut Mid value of `amountIn` before the trade, without fee or price impact (DEC-118, DEC-141).
    /// @param maxLossBps The collection's maximum loss against `spotOut`, in bps; 0 or >= 10,000 for none (D-23).
    /// @param minOut The minimum output the sale was held to, 0 when no bound applied.
    event IncomeSold(
        address indexed swapAdapter,
        address indexed token,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spotOut,
        uint16 maxLossBps,
        uint256 minOut
    );

    /// @notice A collection's sale of `token` failed (no route, the maximum loss, the adapter's own refusal) and was
    ///         skipped: the income stays in the collected income bucket, and the token's interval on the Hub stays open
    ///         until a later collection sells it (DEC-056: a failing dependency never blocks the collection).
    event IncomeSaleFailed(address indexed swapAdapter, address indexed token, uint256 amountIn);

    /// @notice A spoke executed a collection order of `round`: result `resultId`, its dollars sent home as Income in
    ///         `transitId` (zero when nothing was sent: no income, or an amount the bridge refused, which waits for the
    ///         next execution).
    event IncomeCollectionExecuted(
        uint64 indexed round, uint64 indexed resultId, bytes32 indexed transitId, uint256 amountSent
    );

    /// @notice The send of result `resultId` was refunded (DEC-066) and its dollars were sent home again in
    ///         `transitId`.
    event IncomeResent(uint64 indexed resultId, bytes32 indexed transitId, uint256 amountSent);

    // ---------------------------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Income goes home only through a collection order (DEC-122, DEC-124, DEC-161): an Income send outside one
    ///         would reach the Hub without the sale record its conversion needs.
    error IncomeSentOnlyByCollection();

    // ---------------------------------------------------------------------------------------------------------------
    // Hub collection (DEC-122 item 1, DEC-161, DEC-172)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Collects every position's income, sells every non-base income token for USDC through the Mandate swap
    ///         adapter and transfers the collected USDC to the Core Vault. Core Vault only; Hub Chain only.
    /// @dev DEC-172: the Hub positions' income is sold for USDC in the same collection as the spokes'. The Core Vault
    ///      recognizes the Hub income before it calls (DEC-138: what is sold was recognized) and closes the Hub
    ///      interval with the arrays returned. A position whose collection fails and a sale that fails are skipped
    ///      (DEC-056); a skipped token's income stays here for a later collection.
    /// @param maxLossBps Maximum loss of each sale against its mid, in bps; 0 or >= 10,000 for none (D-23, DEC-144).
    /// @return tokens The ledger tokens of this chain, USDC first.
    /// @return sold Units of each token taken out of the collected income bucket (USDC at face value).
    /// @return obtained USDC each token yielded (USDC: the units themselves); their sum was transferred.
    function collectIncomeAll(uint16 maxLossBps)
        external
        returns (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained);
}
