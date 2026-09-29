// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {CoreVaultBase} from "./CoreVaultBase.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";

/// @title CoreVaultIncome
/// @notice Attributed Income, owed fees and Income Withdrawal of the Core Vault. See ICoreVault.
/// @dev Q60 / OQ-02 / OQ-03 stance (docs/OPEN-QUESTIONS.md): the per-token index advances when income is RECOGNIZED
///      (hub: the hub Spoke Vault's cumulative counters, read by `recognizeHubIncome` and before every mint, burn and
///      Income Withdrawal; spoke: the report's cumulative counters on acceptance). At each recognition the performance
///      fee (DEC-107) and the protocol slice read from the ManagerRegistry at that moment (DEC-106, DEC-110) are booked
///      as owed on the recognized delta and only the net enters the accumulator (CoreVaultLogic). Owed fees and
///      Attributed Income are then paid in kind from the collected balance of the token (DEC-109); collection
///      (`receiveCollectedIncome`, matched Income arrivals) only credits that balance, with no second split.
abstract contract CoreVaultIncome is CoreVaultBase {
    using SafeERC20 for IERC20;
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @inheritdoc ICoreVault
    function recognizeHubIncome() external nonReentrant {
        CoreVaultLogic.recognizeHubIncome(_s, _wiring());
    }

    /// @inheritdoc ICoreVault
    /// @dev OQ-02 / OQ-03 stance: the fee split happened at recognition, so collection only moves the tokens into the
    ///      collected balance; the event reports zero fees here, the booked fees are in `IncomeFeesBooked`. The hub
    ///      counters are recognized first so the collected amount is already booked. Callable while a payout's
    ///      automatic unwind is in progress.
    function receiveCollectedIncome(address token, uint256 amount) external onlyHubSpokeVaultCallback {
        if (!_s.income.isRegistered(token)) revert UnknownIncomeToken(token);
        if (amount == 0) revert ZeroAmount();
        CoreVaultLogic.recognizeHubIncome(_s, _wiring());
        _requireUnledgered(token, amount);
        _s.collectedIncome[token] += amount;
        emit CollectedIncomeReceived(token, amount, 0, 0, CoreVaultLogic.protocolSliceBps(_wiring()));
    }

    /// @inheritdoc ICoreVault
    /// @dev LC-100 stance: pays `min(owed, collectedIncome(token))`. No Payout Fee and no flow fee (LC-143 reading).
    function withdrawIncome(address token) external nonReentrant returns (uint256 amount) {
        if (!_s.income.isRegistered(token)) revert UnknownIncomeToken(token);
        CoreVaultLogic.recognizeHubIncome(_s, _wiring());
        _s.income.checkpoint(msg.sender, _sharesOf(msg.sender));
        amount = _takeIncome(msg.sender, token);
    }

    /// @notice DEC-045, DEC-047: a full burn pays all Attributed Income payable now, in every token, in the same
    ///         transaction. The caller has checkpointed the holder.
    function _payAllIncome(address holder) internal {
        address[] memory tokens = _s.income.tokens;
        for (uint256 i; i < tokens.length; ++i) {
            _takeIncome(holder, tokens[i]);
        }
    }

    function _takeIncome(address holder, address token) internal returns (uint256 amount) {
        amount = _s.income.takeOwed(holder, token, _s.collectedIncome[token]);
        if (amount == 0) return 0;
        _s.collectedIncome[token] -= amount;
        IERC20(token).safeTransfer(holder, amount);
        emit IncomeWithdrawn(holder, token, amount);
    }

    /// @inheritdoc ICoreVault
    /// @dev DEC-109: paid in the collected token, never in shares. LC-100 stance applied to fees: each owed amount is
    ///      paid up to the collected balance, manager fee first, then the protocol slice.
    function payOwedFees(address token) external nonReentrant {
        uint256 available = _s.collectedIncome[token];
        uint256 toManager = _s.managerOwed[token];
        if (toManager > available) toManager = available;
        available -= toManager;
        uint256 toProtocol = _s.protocolOwed[token];
        if (toProtocol > available) toProtocol = available;
        _s.managerOwed[token] -= toManager;
        _s.protocolOwed[token] -= toProtocol;
        _s.collectedIncome[token] = available - toProtocol;
        if (toManager != 0) {
            IERC20(token).safeTransfer(manager, toManager);
            emit FeesPaid(token, manager, toManager);
        }
        if (toProtocol != 0) {
            IERC20(token).safeTransfer(protocolRecipient, toProtocol);
            emit FeesPaid(token, protocolRecipient, toProtocol);
        }
    }

    /// @inheritdoc ICoreVault
    /// @dev DEC-110: the manager fee only decreases, with immediate effect, after booking the hub income recognized so
    ///      far at the old rate (spoke income is booked on each report acceptance, so none of it is pending here).
    ///      DEC-108, LC-144: the management fee must stay 0.
    function decreaseManagerFee(uint16 newPerformanceFeeBps, uint16 newManagementFeeBps)
        external
        onlyManager
        nonReentrant
    {
        if (newManagementFeeBps != 0) revert ManagementFeeNotSupported(newManagementFeeBps);
        uint16 previous = _s.performanceFeeBps;
        if (newPerformanceFeeBps >= previous) revert ManagerFeeNotDecreasing();
        CoreVaultLogic.recognizeHubIncome(_s, _wiring());
        _s.performanceFeeBps = newPerformanceFeeBps;
        emit ManagerFeeDecreased(previous, newPerformanceFeeBps, _s.managementFeeBps, newManagementFeeBps);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function incomeTokens() external view returns (address[] memory) {
        return _s.income.tokens;
    }

    /// @inheritdoc ICoreVault
    function attributedIncome(address shareholder, address token) external view returns (uint256) {
        if (!_s.income.isRegistered(token)) return 0;
        return _s.income.owed(shareholder, token, _sharesOf(shareholder));
    }

    /// @inheritdoc ICoreVault
    function collectedIncome(address token) external view returns (uint256) {
        return _s.collectedIncome[token];
    }

    /// @inheritdoc ICoreVault
    function ownerlessIncome(address token) external view returns (uint256) {
        return _s.income.tokenIncome[token].ownerless;
    }

    /// @notice Accumulator state of an income token (index, remainder, ownerless, distributed and taken totals).
    function incomeState(address token) external view returns (IncomeAccumulator.TokenIncome memory) {
        return _s.income.tokenIncome[token];
    }

    /// @inheritdoc ICoreVault
    function performanceFeeBps() external view returns (uint16) {
        return _s.performanceFeeBps;
    }

    /// @inheritdoc ICoreVault
    function managementFeeBps() external view returns (uint16) {
        return _s.managementFeeBps;
    }

    /// @inheritdoc ICoreVault
    function protocolOwed(address token) external view returns (uint256) {
        return _s.protocolOwed[token];
    }

    /// @inheritdoc ICoreVault
    function managerOwed(address token) external view returns (uint256) {
        return _s.managerOwed[token];
    }
}
