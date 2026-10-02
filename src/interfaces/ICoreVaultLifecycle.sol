// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title ICoreVaultLifecycle
/// @notice Lifecycle of a fund on its Hub Chain: the manager's seed at creation and the manager's peak balance.
/// @dev DEC-127, DEC-135, DEC-061: the manager seeds the fund with their own capital in the creation transaction
///      (`FundFactory.createFund`), so a fund is born with shares and its first shares are the manager's; the seed is
///      at least the Mandate's `minFirstDeposit`, pays the flow fee (DEC-113, D-34) and mints at the initial Share Price
///      (1.00). DEC-121, DEC-127: zero shares only exist after closure, so no deposit is taken at supply 0 and a fund
///      never re-opens at 1.00.
interface ICoreVaultLifecycle {
    /// @notice The fund was seeded by its manager at creation (DEC-127).
    /// @param usdcAmount USDC that bought the shares (credited to Idle), the flow fee excluded.
    event FundSeeded(address indexed manager, uint256 usdcAmount, uint256 flowFee, uint256 shares);

    /// @notice A deposit reached a fund with no shares (DEC-121, DEC-127).
    error FundNotSeeded();

    /// @notice The fund was already seeded.
    error AlreadySeeded();

    /// @notice The caller is not the factory that created this Core Vault.
    error NotFactory(address caller);

    /// @notice Seeds the fund: pulls `usdcAmount` less the sub-share remainder from the caller and mints the first
    ///         shares to the manager at the initial Share Price.
    /// @dev Factory only, once, at supply 0; `usdcAmount >= minFirstDeposit` (DEC-061, DEC-127). The flow fee is
    ///      deducted before shares are computed and paid to the Protocol Recipient (DEC-113). Records the manager peak.
    /// @return shares Whole shares minted to the manager.
    function seed(uint256 usdcAmount) external returns (uint256 shares);

    /// @notice The factory that created this Core Vault, the only caller of `seed`.
    function factory() external view returns (address);

    /// @notice The highest share balance the manager address ever held (DEC-146); non-zero once seeded.
    function managerPeakShares() external view returns (uint256);
}
