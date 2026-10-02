pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {CoreVaultState, CoreVaultWiring, STANDARD_PAYOUT_TERM, CORE_VAULT_UNWINDING_SLOT} from "./CoreVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {CoreVaultIncomeLogic} from "./CoreVaultIncomeLogic.sol";
import {CoreVaultIncomeCollectionLogic} from "./CoreVaultIncomeCollectionLogic.sol";
import {ShareToken} from "./ShareToken.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {SpokeUnwindTypes} from "../spoke/SpokeUnwindTypes.sol";

/// @notice Linked Core Vault closure implementation (DEC-114/147/149/150/163/167, ruling 2026-10-02).
library CoreVaultClosureLogic {
    using SafeERC20 for IERC20;

    struct FinalPayment {
        uint256 fee;
        uint256 price;
        uint256 shares;
        uint256 flowFee;
        uint256 deducted;
        uint256 paid;
    }

    function onReportAccepted(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        uint256 spokeIndex,
        ReportCodec.Report memory report
    ) public {
        if (state.fundState != ICoreVaultLifecycle.FundState.Closing || report.unwindResults.length == 0) return;
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        bytes32 closureId = requestId(state, wiring.fundId);
        for (uint256 index; index < results.length; ++index) {
            SpokeUnwindTypes.OrderResult memory result = results[index];
            if (result.requestId != closureId || result.amountToArrive == 0) continue;
            bytes32 key = CoreVaultLogic.hubBoundKey(state.mandate.spokes[spokeIndex].chainId, result.transitId);
            if (state.closureExpected[key] == 0) {
                state.closureTransits[spokeIndex].push(result.transitId);
                state.closureExpected[key] = result.amountToArrive;
            }
            if (result.refunded) state.closureRefunded[key] = true;
        }
    }

    function requestId(CoreVaultState storage state, bytes32 fundId) public view returns (bytes32) {
        return keccak256(abi.encode("CLOSE", fundId, state.closingStartedAt));
    }

    function unwindAll(CoreVaultState storage state, CoreVaultWiring memory wiring, uint256 messageFee) public {
        _requireClosing(state);
        uint256 deadline = uint256(state.closingStartedAt) + STANDARD_PAYOUT_TERM;
        if (msg.sender != wiring.manager && block.timestamp <= deadline) {
            revert ICoreVaultLifecycle.ClosingDeadlineNotReached(deadline);
        }
        bytes32 closureId = requestId(state, wiring.fundId);
        uint32 attempt = ++state.closureAttempt;
        bytes32 slot = CORE_VAULT_UNWINDING_SLOT;
        assembly ("memory-safe") { tstore(slot, 1) }
        try ISpokeVault(wiring.hubSpokeVault)
            .unwindForPayout(
                ISpokeVaultUnwind.UnwindRequest(
                    keccak256(abi.encode(closureId, attempt)), 1, 1, 0, ICoreVaultPayouts.PayoutMode.Standard
                )
            ) returns (
            ISpokeVaultUnwind.UnwindResult memory result
        ) {
            state.closureExcessCost += result.leaverCost;
        } catch (bytes memory reason) {
            emit ICoreVaultLifecycle.ClosureUnwindFailed(reason);
        }
        assembly ("memory-safe") { tstore(slot, 0) }
        if (state.mandate.spokes.length == 0) {
            if (messageFee != 0) revert ICoreVaultLifecycle.ClosureNotReady();
            return;
        }
        OrderCodec.Order memory order;
        order.kind = OrderCodec.CLOSE;
        order.fundId = wiring.fundId;
        order.requestId = closureId;
        order.attempt = attempt;
        order.fracNum = 1;
        order.fracDen = 1;
        order.payoutMode = uint8(ICoreVaultPayouts.PayoutMode.Standard);
        order.closingStartedAt = state.closingStartedAt;
        uint64 sequence = OrderCodec.publish(wiring.wormholeCore, order, messageFee);
        emit ICoreVault.OrderPublished(order.kind, OrderCodec.orderId(order), closureId, order.attempt, sequence);
    }

    function finalize(CoreVaultState storage state, CoreVaultWiring memory wiring) public {
        _requireClosing(state);
        ReportCodec.Report memory hub = ISpokeVault(wiring.hubSpokeVault).buildReport();
        _requireEmpty(hub);
        uint256 excess = state.closureExcessCost + ISpokeVaultUnwind(wiring.hubSpokeVault).closureCost();
        IValueReportReceiver receiver = IValueReportReceiver(wiring.reportReceiver);
        for (uint256 index; index < state.mandate.spokes.length; ++index) {
            if (!receiver.isReportFresh(index)) revert ICoreVaultLifecycle.ClosureNotReady();
            (ReportCodec.Report memory report,,) = receiver.latestReport(index);
            if (report.timestamp < state.closingStartedAt) revert ICoreVaultLifecycle.ClosureNotReady();
            _requireEmpty(report);
            if (state.spokeBooks[index].inFlightSent != 0 || state.spokeBooks[index].inFlightToArrive != 0) {
                revert ICoreVaultLifecycle.ClosureNotReady();
            }
            excess += _spokeExcess(state, wiring, index, report.unwindResults);
        }
        CoreVaultIncomeLogic.onValuation(state, wiring, hub, true, false);
        if (!CoreVaultIncomeLogic.finalCollectionDone(state, wiring) || state.unmatchedArrivals != 0) {
            revert ICoreVaultLifecycle.ClosureNotReady();
        }
        state.idle += state.operatingCash;
        state.operatingCash = 0;
        state.operatingCashFloor = 0;
        state.operatingCashTopUp = 0;
        _finalPayment(state, wiring, excess);
    }

    function _finalPayment(CoreVaultState storage state, CoreVaultWiring memory wiring, uint256 excess) private {
        FinalPayment memory payment;
        payment.fee = Math.min(state.managementFeeAccrued, state.idle);
        state.managementFeeAccrued = 0;
        state.idle -= payment.fee;
        uint256 protocolFee = ShareMath.bpsOf(payment.fee, CoreVaultIncomeCollectionLogic.protocolSliceBps(wiring));
        CoreVaultLogic.payFee(state, wiring.usdc, wiring.protocolRecipient, protocolFee);
        CoreVaultLogic.payFee(state, wiring.usdc, wiring.managerFeeVault, payment.fee - protocolFee);
        uint256 supply = IERC20(wiring.shareToken).totalSupply();
        payment.shares = IERC20(wiring.shareToken).balanceOf(wiring.manager);
        uint256 denominator = supply * 10_000 - payment.shares * (10_000 - wiring.flowFeeBps);
        if (denominator != 0) {
            excess =
                Math.min(excess, Math.mulDiv(state.idle, payment.shares * (10_000 - wiring.flowFeeBps), denominator));
        }
        payment.price = ShareMath.sharePrice(state.idle + excess, supply);
        uint256 gross = supply == 0 ? 0 : Math.mulDiv(payment.shares, state.idle + excess, supply);
        payment.flowFee = ShareMath.flowFee(gross, wiring.flowFeeBps);
        payment.deducted = Math.min(excess, gross - payment.flowFee);
        payment.paid = gross - payment.flowFee - payment.deducted;
        if (payment.paid + payment.flowFee > state.idle) revert ICoreVaultLifecycle.ClosureNotReady();
        state.idle -= payment.paid + payment.flowFee;
        _burn(state, wiring, wiring.manager, payment.shares);
        state.closedSupply = IERC20(wiring.shareToken).totalSupply();
        state.closedIdle = state.idle;
        state.payoutReserve = 0;
        state.fundState = ICoreVaultLifecycle.FundState.Closed;
        CoreVaultLogic.payFee(state, wiring.usdc, wiring.protocolRecipient, payment.flowFee);
        if (payment.paid != 0) IERC20(wiring.usdc).safeTransfer(wiring.manager, payment.paid);
        emit ICoreVaultLifecycle.FundClosed(
            uint64(block.timestamp),
            state.closedSupply,
            state.closedIdle,
            payment.price,
            payment.fee,
            payment.shares,
            payment.deducted
        );
    }

    function exit(CoreVaultState storage state, CoreVaultWiring memory wiring, address holder)
        public
        returns (uint256 paid)
    {
        if (state.fundState != ICoreVaultLifecycle.FundState.Closed) {
            revert ICoreVaultLifecycle.FundNotClosed(state.fundState);
        }
        uint256 shares = IERC20(wiring.shareToken).balanceOf(holder);
        uint256 gross = shares == 0 ? 0 : Math.mulDiv(shares, state.closedIdle, state.closedSupply);
        uint256 fee = ShareMath.flowFee(gross, wiring.flowFeeBps);
        paid = gross - fee;
        state.idle -= gross;
        _burn(state, wiring, holder, shares);
        CoreVaultLogic.payFee(state, wiring.usdc, wiring.protocolRecipient, fee);
        if (paid != 0) IERC20(wiring.usdc).safeTransfer(holder, paid);
        emit ICoreVaultLifecycle.ClosedFundExited(holder, shares, gross, fee, paid);
    }

    function _burn(CoreVaultState storage state, CoreVaultWiring memory wiring, address holder, uint256 shares)
        private
    {
        delete state.payouts.requests[holder];
        CoreVaultIncomeLogic.beforeBalanceChange(state, wiring, holder, shares);
        if (shares != 0) ShareToken(wiring.shareToken).burn(holder, shares);
        CoreVaultIncomeLogic.afterBurn(state, wiring, holder, shares, 0);
    }

    function _requireClosing(CoreVaultState storage state) private view {
        if (state.fundState != ICoreVaultLifecycle.FundState.Closing) {
            revert ICoreVaultLifecycle.FundNotClosing(state.fundState);
        }
    }

    function _requireEmpty(ReportCodec.Report memory report) private pure {
        if (report.positions.length != 0 || report.inFlightToHub.length != 0 || report.operatingCash != 0) {
            revert ICoreVaultLifecycle.ClosureNotReady();
        }
        for (uint256 index; index < report.unallocated.length; ++index) {
            if (report.unallocated[index].amount != 0) revert ICoreVaultLifecycle.ClosureNotReady();
        }
        for (uint256 index; index < report.collectedIncome.length; ++index) {
            if (report.collectedIncome[index].amount != 0) revert ICoreVaultLifecycle.ClosureNotReady();
        }
    }

    function _spokeExcess(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        uint256 spokeIndex,
        bytes memory blob
    ) private view returns (uint256) {
        if (blob.length == 0) revert ICoreVaultLifecycle.ClosureNotReady();
        SpokeUnwindTypes.OrderResult[] memory results = abi.decode(blob, (SpokeUnwindTypes.OrderResult[]));
        bytes32 closureId = requestId(state, wiring.fundId);
        bytes32[] storage transits = state.closureTransits[spokeIndex];
        for (uint256 index; index < transits.length; ++index) {
            bytes32 key = CoreVaultLogic.hubBoundKey(state.mandate.spokes[spokeIndex].chainId, transits[index]);
            if (!state.closureRefunded[key] && state.hubBound[key].credited < state.closureExpected[key]) {
                revert ICoreVaultLifecycle.ClosureNotReady();
            }
        }
        for (uint256 index = results.length; index != 0; --index) {
            SpokeUnwindTypes.OrderResult memory result = results[index - 1];
            if (
                result.requestId == closureId && result.excluded == 0 && !result.refunded && result.attempt != 0
                    && result.attempt <= state.closureAttempt
                    && result.orderId
                        == keccak256(abi.encode(OrderCodec.CLOSE, wiring.fundId, closureId, result.attempt))
            ) {
                for (uint256 sendIndex; sendIndex < results.length; ++sendIndex) {
                    SpokeUnwindTypes.OrderResult memory sent = results[sendIndex];
                    if (sent.requestId != closureId || sent.refunded || sent.amountToArrive == 0) continue;
                    if (
                        state.hubBound[CoreVaultLogic.hubBoundKey(
                                    state.mandate.spokes[spokeIndex].chainId, sent.transitId
                                )].credited < sent.amountToArrive
                    ) {
                        revert ICoreVaultLifecycle.ClosureNotReady();
                    }
                }
                return result.closureExcessCost;
            }
        }
        revert ICoreVaultLifecycle.ClosureNotReady();
    }
}
