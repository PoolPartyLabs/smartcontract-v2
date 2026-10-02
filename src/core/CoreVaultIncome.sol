// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {CoreVaultBase} from "./CoreVaultBase.sol";
import {CoreVaultIncomeLogic} from "./CoreVaultIncomeLogic.sol";

/// @title CoreVaultIncome
/// @notice Collected income, Attributed Income and Income Withdrawal of the Core Vault. See ICoreVault.
/// @dev Ruling 2026-09-29 (fee split point, replaces the recognition-time booking): the per-token index advances ONLY
///      when collected income reaches the Core Vault, through `receiveCollectedIncome` from the hub Spoke Vault or a
///      matched spoke-to-hub arrival of kind Income (USDC). The split happens right there
///      (CoreVaultIncomeLogic.collectIncome): the performance fee (DEC-107) times the collected amount, of which the
///      protocol slice read from the ManagerRegistry at that moment (DEC-106, DEC-110) is transferred to the Protocol
///      Recipient and the rest to the fund's ManagerFeeVault, in kind (DEC-109); the net enters the shareholders'
///      accumulator. Uncollected income (hub and spoke positions, spoke collected buckets) stays in its own bucket
///      (DEC-092) and only informs Gross Assets.
abstract contract CoreVaultIncome is CoreVaultBase {
    using SafeERC20 for IERC20;
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @inheritdoc ICoreVaultIncome
    /// @dev DEC-080: credited only when the tokens are already above the ledger. Moves value out (the fee transfers),
    ///      so it takes the reentrancy guard; the hub Spoke Vault never forwards income from inside a payout's unwind.
    function receiveCollectedIncome(address token, uint256 amount) external nonReentrant {
        if (msg.sender != hubSpokeVault) revert NotHubSpokeVault(msg.sender);
        if (!_s.income.isRegistered(token)) revert UnknownIncomeToken(token);
        if (amount == 0) revert ZeroAmount();
        _requireUnledgered(token, amount);
        CoreVaultIncomeLogic.collectIncome(_s, _wiring(), token, amount);
    }

    /// @inheritdoc ICoreVaultIncome
    /// @dev LC-100 stance: pays `min(owed, collectedIncome(token))`. No Payout Fee (DEC-075: Instant Payouts only) and
    ///      no flow fee (DEC-113, which closes LC-143: deposits and Payouts only, never an Income Withdrawal).
    function withdrawIncome(address token) external nonReentrant returns (uint256 amount) {
        if (!_s.income.isRegistered(token)) revert UnknownIncomeToken(token);
        _s.income.checkpoint(msg.sender, _sharesOf(msg.sender));
        amount = _takeIncome(msg.sender, token);
    }

    /// @inheritdoc ICoreVaultIncome
    function claimOwedFees(address token, address recipient) external nonReentrant returns (uint256 amount) {
        amount = _s.owedFees[token][recipient];
        if (amount == 0) revert ZeroAmount();
        _s.owedFees[token][recipient] = 0;
        _s.owedFeesTotal[token] -= amount;
        emit OwedFeePaid(token, recipient, amount);
        IERC20(token).safeTransfer(recipient, amount);
    }

    function _takeIncome(address holder, address token) internal returns (uint256 amount) {
        amount = _s.income.takeOwed(holder, token, _s.collectedIncome[token]);
        if (amount == 0) return 0;
        _s.collectedIncome[token] -= amount;
        IERC20(token).safeTransfer(holder, amount);
        emit IncomeWithdrawn(holder, token, amount);
    }

    /// @inheritdoc ICoreVaultIncome
    /// @dev DEC-110: the manager fee only decreases, with immediate effect. Ruling 2026-09-29: fees are charged at
    ///      collection only, so nothing has accrued at the old rate. DEC-108, LC-144: the management fee must stay 0.
    ///      DEC-115, DEC-125 item 3 (D-36): never below the registry's minimum manager fee in force at creation.
    function decreaseManagerFee(uint16 newPerformanceFeeBps, uint16 newManagementFeeBps)
        external
        onlyManager
        nonReentrant
    {
        if (newManagementFeeBps != 0) revert ManagementFeeNotSupported(newManagementFeeBps);
        uint16 previous = _s.performanceFeeBps;
        if (newPerformanceFeeBps >= previous) revert ManagerFeeNotDecreasing();
        if (newPerformanceFeeBps < minPerformanceFeeBps) {
            revert ManagerFeeBelowMinimum(newPerformanceFeeBps, minPerformanceFeeBps);
        }
        _s.performanceFeeBps = newPerformanceFeeBps;
        emit ManagerFeeDecreased(previous, newPerformanceFeeBps, _s.managementFeeBps, newManagementFeeBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultIncome
    function incomeTokens() external view returns (address[] memory) {
        return _s.income.tokens;
    }

    /// @inheritdoc ICoreVaultIncome
    function attributedIncome(address shareholder, address token) external view returns (uint256) {
        if (!_s.income.isRegistered(token)) return 0;
        return _s.income.owed(shareholder, token, _sharesOf(shareholder));
    }

    /// @inheritdoc ICoreVaultIncome
    function collectedIncome(address token) external view returns (uint256) {
        return _s.collectedIncome[token];
    }

    /// @inheritdoc ICoreVaultIncome
    function owedFees(address token, address recipient) external view returns (uint256) {
        return _s.owedFees[token][recipient];
    }

    /// @inheritdoc ICoreVaultIncome
    function ownerlessIncome(address token) external view returns (uint256) {
        return _s.income.tokenIncome[token].ownerless;
    }

    /// @inheritdoc ICoreVaultIncome
    function incomeState(address token) external view returns (IncomeAccumulator.TokenIncome memory) {
        return _s.income.tokenIncome[token];
    }

    /// @inheritdoc ICoreVaultIncome
    function performanceFeeBps() external view returns (uint16) {
        return _s.performanceFeeBps;
    }

    /// @inheritdoc ICoreVaultIncome
    function managementFeeBps() external view returns (uint16) {
        return _s.managementFeeBps;
    }
}
