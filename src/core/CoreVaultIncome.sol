// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {MandateLib} from "../mandate/Mandate.sol";
import {DollarIncomeIndex} from "../libraries/DollarIncomeIndex.sol";
import {CoreVaultBase} from "./CoreVaultBase.sol";
import {CoreVaultIncomeLogic} from "./CoreVaultIncomeLogic.sol";
import {CoreVaultIncomeCollectionLogic} from "./CoreVaultIncomeCollectionLogic.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {CoreVaultIncomeTypes} from "./CoreVaultIncomeTypes.sol";

/// @title CoreVaultIncome
/// @notice Attributed Income in the Hub dollar index, its collection on every chain and Income Withdrawal in USDC, owed
///         transfers and the manager fee of the Core Vault. See ICoreVaultIncome.
/// @dev DEC-138 (corrects DEC-128 item 4 on when the index advances), DEC-152, DEC-161: income is recognized per token
///      at every mint, burn and accepted report and converted to dollars at each collection's rate; the fee split
///      stays at the collection (DEC-128 item 4, DEC-138), paid in USDC (DEC-124 item 2). The bodies run in the linked
///      libraries `CoreVaultIncomeLogic` (holders, views) and `CoreVaultIncomeCollectionLogic` (the request's
///      collections); the entries keep the reentrancy guard.
abstract contract CoreVaultIncome is CoreVaultBase {
    using SafeERC20 for IERC20;

    /// @inheritdoc ICoreVaultIncome
    function settleHolderIncome(address shareholder) external nonReentrant returns (bool complete) {
        return CoreVaultIncomeLogic.settleHolderIncome(_s, _wiring(), shareholder);
    }

    /// @inheritdoc ICoreVaultIncome
    function requestIncomeWithdrawal(uint16 maxLossBps) external payable nonReentrant returns (uint64 round) {
        return CoreVaultIncomeCollectionLogic.requestIncomeWithdrawal(_s, _wiring(), msg.sender, maxLossBps, msg.value);
    }

    /// @inheritdoc ICoreVaultIncome
    function settleIncomeWithdrawal(address shareholder) external nonReentrant returns (uint256 amount) {
        return CoreVaultIncomeLogic.settleIncomeWithdrawal(_s, _wiring(), shareholder);
    }

    /// @inheritdoc ICoreVaultIncome
    function withdrawIncome() external nonReentrant returns (uint256 amount) {
        return CoreVaultIncomeLogic.withdrawIncome(_s, _wiring(), msg.sender);
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

    /// @inheritdoc ICoreVaultIncome
    /// @dev DEC-110: the manager fee only decreases, with immediate effect, after settling what accrued: the payout-mode
    ///      valuation (it never reverts on a failing dependency, DEC-056) recognizes the Hub income at the old
    ///      performance fee (DEC-117 item 3: the fee is taken at recognition) and books the management fee at the old
    ///      rate (DEC-114). DEC-182, DEC-184: the performance fee never goes below `MandateLib.MIN_PERFORMANCE_FEE_BPS`
    ///      (10%), the floor it was created at or above.
    function decreaseManagerFee(uint16 newPerformanceFeeBps, uint16 newManagementFeeBps)
        external
        onlyManager
        nonReentrant
    {
        uint16 previousPerformance = _s.performanceFeeBps;
        uint16 previousManagement = _s.managementFeeBps;
        if (
            newPerformanceFeeBps > previousPerformance || newManagementFeeBps > previousManagement
                || (newPerformanceFeeBps == previousPerformance && newManagementFeeBps == previousManagement)
        ) revert ManagerFeeNotDecreasing();
        if (newPerformanceFeeBps < MandateLib.MIN_PERFORMANCE_FEE_BPS) {
            revert ManagerFeeBelowMinimum(newPerformanceFeeBps, MandateLib.MIN_PERFORMANCE_FEE_BPS);
        }
        CoreVaultLogic.recordValuation(_s, _wiring(), false);
        if (newManagementFeeBps != previousManagement) _s.managementFeeLastAccrual = uint64(block.timestamp);
        _s.performanceFeeBps = newPerformanceFeeBps;
        _s.managementFeeBps = newManagementFeeBps;
        emit ManagerFeeDecreased(previousPerformance, newPerformanceFeeBps, previousManagement, newManagementFeeBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultIncome
    function incomeOwed(address shareholder) external view returns (uint256) {
        return CoreVaultIncomeLogic.incomeOwed(_s, _wiring(), shareholder);
    }

    /// @inheritdoc ICoreVaultIncome
    function unconvertedIncome(address shareholder, uint256 source, address token) external view returns (uint256) {
        return CoreVaultIncomeLogic.unconvertedIncome(_s, _wiring(), shareholder, source, token);
    }

    /// @inheritdoc ICoreVaultIncome
    function incomeToken(uint256 source, address token) external view returns (IncomeTokenState memory v) {
        CoreVaultIncomeTypes.Source storage src = _incomeSource(source);
        DollarIncomeIndex.IncomeToken storage t = src.index.token[token];
        (v.registered, v.interval, v.openIndex, v.recognized, v.counter, v.feeUnits) =
        (t.registered, t.interval, t.openIndex, t.recognized, src.counter[token], src.feeUnits[token]);
    }

    /// @inheritdoc ICoreVaultIncome
    function incomeCollection() external view returns (IncomeCollectionState memory c) {
        CoreVaultIncomeTypes.Book storage b = _s.incomeBook;
        (c.round, c.attempt, c.deadline, c.pendingSpokes, c.openResults, c.heldDollars) =
        (b.round, b.attempt, b.deadline, b.pendingSpokes, b.openResults, b.heldDollars);
    }

    /// @inheritdoc ICoreVaultIncome
    function incomeWithdrawalRequest(address shareholder) external view returns (uint64 round, bool open) {
        CoreVaultIncomeTypes.Request memory r = _s.incomeBook.requests[shareholder];
        return (r.round, r.open);
    }

    /// @inheritdoc ICoreVaultIncome
    function owedFees(address token, address recipient) external view returns (uint256) {
        return _s.owedFees[token][recipient];
    }

    /// @inheritdoc ICoreVaultIncome
    function performanceFeeBps() external view returns (uint16) {
        return _s.performanceFeeBps;
    }

    /// @inheritdoc ICoreVaultIncome
    function managementFeeBps() external view returns (uint16) {
        return _s.managementFeeBps;
    }

    /// @inheritdoc ICoreVaultIncome
    function managementFeeAccrued() external view returns (uint256) {
        return CoreVaultLogic.managementFeeOwed(_s, _wiring());
    }

    function _incomeSource(uint256 source) private view returns (CoreVaultIncomeTypes.Source storage) {
        if (source >= _s.incomeBook.sourceCount) revert UnknownIncomeSource(source);
        return _s.incomeBook.sources[source];
    }
}
