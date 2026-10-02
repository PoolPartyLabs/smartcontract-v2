// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";

/// @title ICoreVaultIncome
/// @notice Collected income, Attributed Income, Income Withdrawal, owed transfers and the manager fee of the Core Vault
///         (ruling 2026-09-29; DEC-014, DEC-092, DEC-106, DEC-107, DEC-109, DEC-110). Part of ICoreVault.
/// @dev Split out of ICoreVault (WP-07 A4) so the income verbs, events and errors sit with `CoreVaultIncome` and
///      `CoreVaultIncomeLogic`. ICoreVault inherits it: the Core Vault's selectors, event topics and error selectors
///      are unchanged.
interface ICoreVaultIncome {
    // ---------------------------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Attributed Income was paid without burning shares (DEC-025, DEC-029, DEC-073), or with a full burn
    ///         (DEC-045).
    event IncomeWithdrawn(address indexed shareholder, address indexed token, uint256 amount);

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

    error UnknownIncomeToken(address token);
    error ManagerFeeNotDecreasing();

    // ---------------------------------------------------------------------------------------------------------------
    // Shareholder verbs (DEC-025, DEC-029, DEC-045, DEC-073)
    // ---------------------------------------------------------------------------------------------------------------

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
    // Manager verbs (DEC-110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Lowers the manager fee: the performance fee, the management fee or both; neither can rise on a live
    ///         fund and at least one must fall (DEC-110). Manager only.
    /// @dev Ruling 2026-09-29: the performance fee is charged only when collected income reaches the Core Vault, so
    ///      nothing of it is left to settle at the old rate; income collected afterwards is charged at the new rate.
    ///      DEC-110 ("settling what accrued first"), DEC-114: the management fee accrued so far is booked at the old
    ///      rate (a payout-mode valuation) before the new rate applies. The performance fee never goes below the
    ///      registry's minimum in force at creation (DEC-115, DEC-125 item 3, D-36).
    function decreaseManagerFee(uint16 newPerformanceFeeBps, uint16 newManagementFeeBps) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Callbacks from the fund's own contracts (DEC-090, DEC-092)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Credits collected income the hub Spoke Vault transferred and splits it at once (ruling 2026-09-29): the
    ///         performance fee (DEC-107) times `amount`, of which the protocol slice (ManagerRegistry at this moment,
    ///         DEC-106, DEC-110) is transferred to the Protocol Recipient and the rest to the ManagerFeeVault, in kind
    ///         (DEC-109); the net enters the shareholders' accumulator and the collected balance. Hub Spoke Vault only.
    /// @dev This and a matched spoke-to-hub Income arrival are the only points where the income index advances;
    ///      uncollected income stays in its own bucket (DEC-092) and only informs Gross Assets.
    function receiveCollectedIncome(address token, uint256 amount) external;

    // ---------------------------------------------------------------------------------------------------------------
    // Attributed Income and fees (DEC-014, DEC-092, DEC-106..110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Income tokens of the fund: USDC, then the Mandate's other hub tokens (closed list, WP-07 B2).
    function incomeTokens() external view returns (address[] memory);

    /// @notice Attributed Income of `shareholder` in `token`, pending part included.
    function attributedIncome(address shareholder, address token) external view returns (uint256);

    /// @notice Collected income of `token` held by the Core Vault, payable now (LC-100).
    function collectedIncome(address token) external view returns (uint256);

    /// @notice Income recognized with no shares outstanding (LC-32 OPEN: retained).
    function ownerlessIncome(address token) external view returns (uint256);

    /// @notice Amount in `token` owed to `recipient` because its transfer failed when due (fees, S-12; full-exit
    ///         income, plan CF-2).
    function owedFees(address token, address recipient) external view returns (uint256);

    /// @notice Accumulator state of an income token: index (Q128), remainder, ownerless, distributed and taken totals
    ///         (Q60 fitness functions).
    function incomeState(address token) external view returns (IncomeAccumulator.TokenIncome memory);

    /// @notice Manager performance fee on collected income, bps (DEC-107); only decreases (DEC-110).
    function performanceFeeBps() external view returns (uint16);

    /// @notice Manager management fee, bps per year on Share Assets (DEC-108, DEC-114); only decreases (DEC-110).
    function managementFeeBps() external view returns (uint16);

    /// @notice Management fee owed now, in USDC: what was booked plus what accrued since, on the current Share Assets
    ///         net of it (DEC-114, D-33). Outside Share Assets; paid at fund closure. Reverts like `shareAssets`.
    function managementFeeAccrued() external view returns (uint256);
}
