// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

/// @title ICoreVaultLifecycle
/// @notice Lifecycle of a fund on its Hub Chain: the manager's seed at creation, the fund states and the manager base.
/// @dev DEC-127, DEC-135, DEC-061: the manager seeds the fund with their own capital in the creation transaction
///      (`FundFactory.createFund`), so a fund is born with shares and its first shares are the manager's; the seed is
///      at least the Mandate's `minFirstDeposit`, pays the flow fee (DEC-113, D-34) and mints at the initial Share
///      Price (1.00). DEC-121, DEC-127: zero shares only exist after closure, so no deposit is taken at supply 0 and a
///      fund never re-opens at 1.00.
/// @dev DEC-146, DEC-147 item 1: the manager base is half of the highest share balance the manager address ever held
///      (`managerPeakShares`, updated on every mint to the manager); a manager Payout Request that would leave the
///      balance below it reverts `ManagerMustCloseFund` at the request's Share Price, and the claim's burn stops at the
///      base whatever the Share Price did since the request, closing the request (D-27), so the manager never holds
///      less than half of the peak while the fund is Open; nothing closes the fund automatically. Capital in another
///      wallet is not the manager's (DEC-046).
/// @dev DEC-147 items 2-3, DEC-149 (reading: irreversible): `closeFund` is a manager call that moves the fund from
///      Open to Closing. While Closing no deposit, no new Payout Request and no claim are accepted (D-26: requests
///      opened before closure are paid as closed-fund exits, DEC-150 item 4); Income Withdrawal works in every state
///      (DEC-117 item 4) and the manager keeps every unwind verb. The Closed state (DEC-150) is reached by the
///      closure's finalization.
interface ICoreVaultLifecycle {
    event ClosureDustExcluded(uint256 indexed chainId, uint256 amount, bool income);
    /// @notice Frozen closure split and the manager's final settlement (DEC-147/163/167).
    event FundClosed(
        uint64 closedAt,
        uint256 closedSupply,
        uint256 closedIdle,
        uint256 closingSharePrice,
        uint256 managementFeePaid,
        uint256 managerSharesBurned,
        uint256 excessCostDeducted
    );
    event ClosedFundExited(address indexed holder, uint256 shares, uint256 gross, uint256 flowFee, uint256 paid);
    event ClosureUnwindFailed(bytes reason);
    error FundNotClosing(FundState state);
    error FundNotClosed(FundState state);
    error ClosingDeadlineNotReached(uint256 deadline);
    error ClosureNotReady();

    function closingDeadline() external view returns (uint256);
    function closureRequestId() external view returns (bytes32);
    function closedSupply() external view returns (uint256);
    function closedIdle() external view returns (uint256);
    /// @notice Full Standard unwind and CLOSE publication (DEC-147/149): manager anytime while Closing, anyone
    ///         strictly after the 72-hour deadline. Repeatable for excluded positions and expired orders.
    function unwindAllAfterDeadline() external payable;
    /// @notice Finalizes only on empty fresh reports, completed CLOSE orders, no transit and converted income;
    ///         pays management fees, burns and pays the manager, then freezes the remaining split (DEC-114/163/167).
    function finalizeClosure() external;
    /// @notice Pays only holder, anytime after closure, at shares * closedIdle / closedSupply, with the flow fee
    ///         but no Payout Fee or report; clears their open request and pays income (DEC-150/163/167).
    function exitClosedFund(address holder) external returns (uint256 paid);

    /// @notice Open -> Closing -> Closed (DEC-147, DEC-149, DEC-150); never backwards.
    enum FundState {
        Open,
        Closing,
        Closed
    }

    /// @notice The fund was seeded by its manager at creation (DEC-127).
    /// @param usdcAmount USDC that bought the shares (credited to Idle), the flow fee excluded.
    event FundSeeded(address indexed manager, uint256 usdcAmount, uint256 flowFee, uint256 shares);

    /// @notice The manager called `closeFund` (DEC-147).
    event FundClosing(uint64 closingStartedAt);

    /// @notice The verb needs an Open fund.
    error FundNotOpen(FundState state);

    /// @notice A deposit reached a fund with no shares (DEC-121, DEC-127).
    error FundNotSeeded();

    /// @notice The fund was already seeded.
    error AlreadySeeded();

    /// @notice The caller is not the factory that created this Core Vault.
    error NotFactory(address caller);

    /// @notice A manager Payout Request would leave the manager's balance below half of the peak (DEC-146, DEC-147):
    ///         the manager must close the fund instead.
    error ManagerMustCloseFund(uint256 peakShares, uint256 balanceAfter);

    /// @notice `decreaseManagerFee` would take the performance fee below `MandateLib.MIN_PERFORMANCE_FEE_BPS`, 10%
    ///         (DEC-182, DEC-184).
    error ManagerFeeBelowMinimum(uint16 bps, uint16 minBps);

    /// @notice Seeds the fund: pulls `usdcAmount` less the sub-share remainder from the caller and mints the first
    ///         shares to the manager at the initial Share Price.
    /// @dev Factory only, once, at supply 0; `usdcAmount >= minFirstDeposit` (DEC-061, DEC-127). The flow fee is
    ///      deducted before shares are computed and paid to the Protocol Recipient (DEC-113). Records the manager peak.
    ///      Hub Operating Cash is not topped up here: the first value-moving operation tops it up out of the seed's
    ///      Idle (DEC-096), so a seed should exceed the hub floor plus top-up or deposits revert until the manager
    ///      lowers them.
    /// @return shares Whole shares minted to the manager.
    function seed(uint256 usdcAmount) external returns (uint256 shares);

    /// @notice Starts the closure: Open -> Closing, irreversible (DEC-147, DEC-149). Manager only.
    function closeFund() external;

    /// @notice The factory that created this Core Vault, the only caller of `seed`.
    function factory() external view returns (address);

    /// @notice The fund's state.
    function fundState() external view returns (FundState);

    /// @notice When `closeFund` was called; 0 while Open. The closing deadline (DEC-149) counts from here.
    function closingStartedAt() external view returns (uint64);

    /// @notice The highest share balance the manager address ever held (DEC-146); non-zero once seeded.
    function managerPeakShares() external view returns (uint256);
}
