pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {Transit, TransitState, TransferKind} from "../interfaces/FundTypes.sol";
import {CoreVaultState, CoreVaultWiring, SpokeBook, HubBoundTransfer} from "./CoreVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {CoreVaultTransitLogic} from "./CoreVaultTransitLogic.sol";
import {CoreVaultPayoutLogic} from "./CoreVaultPayoutLogic.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {CctpBridgeAdapter} from "../adapters/CctpBridgeAdapter.sol";

/// @notice Opt-in linked accounting for new CCTP Funds; legacy Across accounting is untouched (DEC-188, DEC-191).
library CoreVaultCctpLogic {
    using SafeERC20 for IERC20;

    struct Receipt {
        uint256 minimum;
        uint256 surplus;
        TransferKind kind;
        bool settled;
    }

    error ReceiptReportMismatch(bytes32 transitId);

    /// @notice DEC-191: authentic actual arrival includes unspent outbound maxFee as principal, once only.
    function confirmFeeSurplus(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        mapping(bytes32 => uint256) storage surplusById,
        uint256 spokeIndex,
        address adapter
    ) public {
        (ReportCodec.Report memory report,,) = IValueReportReceiver(wiring.reportReceiver).latestReport(spokeIndex);
        for (uint256 index; index < report.arrivedTransits.length; ++index) {
            ReportCodec.TransitAmount memory arrival = report.arrivedTransits[index];
            Transit storage transit = state.transits[arrival.transitId];
            if (transit.bridgeAdapter != adapter || transit.state != TransitState.ArrivalConfirmed) continue;
            if (arrival.amount > transit.amountSent) revert ReceiptReportMismatch(arrival.transitId);
            if (arrival.amount <= transit.amountToArrive) continue;
            uint256 surplus = arrival.amount - transit.amountToArrive;
            if (surplus <= surplusById[arrival.transitId]) continue;
            state.spokeBooks[spokeIndex].confirmedArrived += surplus - surplusById[arrival.transitId];
            surplusById[arrival.transitId] = surplus;
        }
    }

    function send(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        uint256 spokeIndex,
        CctpBridgeAdapter adapter,
        uint256 amount,
        bytes calldata feeData
    ) public returns (bytes32 id) {
        if (!IValueReportReceiver(wiring.reportReceiver).hasReport(spokeIndex)) {
            revert ICoreVault.SpokeNotReporting(spokeIndex);
        }
        if (adapter.paused() || adapter.deprecated()) revert ICoreVault.BridgeAdapterUnavailable(address(adapter));
        uint256 free = state.idle - state.payoutReserve;
        if (amount > free) revert ICoreVault.InsufficientFreeIdle(amount, free);
        _checkCap(state, wiring, spokeIndex, amount);
        id = keccak256(abi.encode(block.chainid, address(this), ++state.transitNonce));
        IBridgeAdapter.SendRequest memory request = IBridgeAdapter.SendRequest(
            wiring.usdc,
            address(0),
            amount,
            adapter.solanaChainId(),
            adapter.mintRecipient(),
            TransitMessage.encode(wiring.fundId, wiring.hubChainId, id, TransferKind.Principal)
        );
        IBridgeAdapter.BridgeCall memory call = adapter.buildSend(request, address(this), feeData);
        if (
            call.target != adapter.target() || call.amountToArrive == 0 || call.amountToArrive > amount
                || call.fillDeadline != 0 || call.transitRef != id
        ) revert ICoreVault.BridgeCallMismatch(address(adapter));
        _book(state, wiring, spokeIndex, address(adapter), amount, id, call);
        IERC20 token = IERC20(wiring.usdc);
        uint256 beforeBalance = token.balanceOf(address(this));
        token.forceApprove(call.target, amount);
        (bool success, bytes memory result) = call.target.call(call.data);
        if (!success) assembly ("memory-safe") { revert(add(result, 32), mload(result)) }
        uint256 debit = beforeBalance - token.balanceOf(address(this));
        if (debit != amount) revert ICoreVault.BalanceChangeMismatch(amount, debit);
        token.forceApprove(call.target, 0);
    }

    function _checkCap(CoreVaultState storage state, CoreVaultWiring memory wiring, uint256 spokeIndex, uint256 amount)
        private
        view
    {
        (uint256 value, uint256 sent, uint256 returning, uint256 cap) =
            CoreVaultLogic.spokeCapUsage(state, wiring, spokeIndex);
        uint256 used = value + sent + returning;
        if (used + amount > cap) revert ICoreVault.SpokeCapExceeded(spokeIndex, used, amount, cap);
    }

    function _book(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        uint256 spokeIndex,
        address adapter,
        uint256 amount,
        bytes32 id,
        IBridgeAdapter.BridgeCall memory call
    ) private {
        state.idle -= amount;
        SpokeBook storage book = state.spokeBooks[spokeIndex];
        book.inFlightSent += amount;
        book.inFlightToArrive += call.amountToArrive;
        Transit memory transit = Transit(
            state.mandate.spokes[spokeIndex].chainId,
            adapter,
            address(0),
            wiring.usdc,
            address(0),
            amount,
            call.amountToArrive,
            id,
            uint64(block.timestamp),
            0,
            TransferKind.Principal,
            TransitState.Sent
        );
        state.transits[id] = transit;
        state.transitSpoke[id] = spokeIndex;
        emit ICoreVault.SentToSpoke(id, spokeIndex, transit, wiring.hubChainId);
    }

    /// @dev Hold the unspent fee apart until a finalized report proves the source ledger decrease (DEC-080, DEC-191).
    function receiveReturn(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        Receipt storage receipt,
        uint256 origin,
        bytes32 id,
        TransferKind kind,
        uint256 amount,
        uint256 maxFee,
        uint256 feeExecuted
    ) public {
        receipt.minimum = amount - maxFee;
        receipt.surplus = maxFee - feeExecuted;
        receipt.kind = kind;
        state.unmatchedArrivals += receipt.surplus;
        CoreVaultTransitLogic.receiveHubBound(state, wiring, origin, id, kind, receipt.minimum);
        settle(state, receipt, origin, id);
    }

    /// @dev Only capped principal/income is classified by the report; unspent maxFee is principal (DEC-191).
    function settle(CoreVaultState storage state, Receipt storage receipt, uint256 origin, bytes32 id) public {
        if (receipt.minimum == 0 || receipt.settled) return;
        HubBoundTransfer storage transfer = state.hubBound[CoreVaultLogic.hubBoundKey(origin, id)];
        if (transfer.listed == 0) return;
        if (transfer.listed != receipt.minimum || transfer.kind != receipt.kind) revert ReceiptReportMismatch(id);
        if (transfer.credited != receipt.minimum) return;
        receipt.settled = true;
        state.unmatchedArrivals -= receipt.surplus;
        state.idle += receipt.surplus;
        if (receipt.surplus != 0) CoreVaultPayoutLogic.onPrincipalCredit(state, origin, id);
    }

    function settleReport(
        CoreVaultState storage state,
        CoreVaultWiring memory wiring,
        mapping(bytes32 => Receipt) storage receipts,
        uint256 spokeIndex
    ) public {
        (ReportCodec.Report memory report,,) = IValueReportReceiver(wiring.reportReceiver).latestReport(spokeIndex);
        uint256 origin = state.mandate.spokes[spokeIndex].chainId;
        for (uint256 index; index < report.inFlightToHub.length; ++index) {
            bytes32 id = report.inFlightToHub[index].transitId;
            settle(state, receipts[id], origin, id);
        }
    }
}
