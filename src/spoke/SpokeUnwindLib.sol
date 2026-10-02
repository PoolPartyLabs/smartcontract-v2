// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {TransitState, Transit} from "../interfaces/FundTypes.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {OrderVerifier} from "../libraries/OrderVerifier.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeUnwindTypes} from "./SpokeUnwindTypes.sol";
import {SpokeLedger} from "./SpokeLedger.sol";

/// @title SpokeUnwindLib
/// @notice The automatic unwind of the hub Spoke Vault (the body of `SpokeVault.unwindForPayout` and its atomic step)
///         and the checks of the order entry. Deployed once per chain and linked into `SpokeVault`; it runs in the
///         vault's context (library call) over the vault's own `SpokeVaultTypes.State`, holds no state and is
///         immutable (DEC-022, DEC-058).
/// @dev DEC-131 (alternative C, b1, b2): kept out of the vault so the vault stays under the smallest code limit across
///      the chains (24,576 bytes, Arbitrum One; b3, b4). The vault keeps the access control (hub only, Core Vault
///      only, self only for the step), the reentrancy guard and the public `STANDARD_SALE_LOSS_ABSORB_BPS`. Events and
///      errors are the vault's (ISpokeVault, SpokeVaultTypes, SpokeUnwindTypes), emitted from the vault's address. The
///      library is part of the vault's creation code and trust surface, like `SpokeCrossChainLib`.
library SpokeUnwindLib {
    /// @notice DEC-141: in a Standard Payout the fund absorbs each sale's loss up to 1% of the value sold (its mid
    ///         value before the sale, D-19); the requester bears the excess. A protocol constant. Published by the
    ///         vault as `SpokeVault.STANDARD_SALE_LOSS_ABSORB_BPS`.
    uint256 internal constant STANDARD_SALE_LOSS_ABSORB_BPS = 100;

    uint256 private constant BPS = 10_000;

    /// @dev Transient namespace of the fee tier chosen per token within one unwind (D-21: `bestDirectFee` once per
    ///      token per unwind); the slot of a token is `keccak256(abi.encode(TIER_NAMESPACE, token))`.
    bytes32 private constant TIER_NAMESPACE = keccak256("pool-party.SpokeUnwindLib.tier");

    /// @notice DEC-120/139/151: execute the same proportional steps as the Hub, retaining unsent proceeds on refusal.
    /// @dev DEC-149: CLOSE always takes everything, with Standard Market Costs and no requester maximum.
    function executeUnwindOrder(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        OrderCodec.Order memory order
    ) external {
        bool closing = order.kind == OrderCodec.CLOSE;
        if (s.unwind.closed && !closing) revert SpokeUnwindTypes.SpokeClosed();
        if (closing) {
            order.fracNum = 1;
            order.fracDen = 1;
            order.maxLossBps = 0;
            order.payoutMode = uint8(ICoreVaultPayouts.PayoutMode.Standard);
            s.unallocated[c.baseToken] += s.operatingCash;
            s.operatingCash = 0;
        }
        SpokeUnwindTypes.Pending storage pending = s.unwind.pending[order.requestId];
        _recoverSend(s, c.baseToken, order.requestId, pending);
        if (closing) s.unwind.reservedBase = pending.proceeds;
        uint256 beforeBase = s.unallocated[c.baseToken];
        bytes32 baseId = SpokeUnwindTypes.stepId(address(0), bytes32(uint256(uint160(c.baseToken))));
        uint256 basePart;
        if (!s.unwind.delivered[order.requestId][baseId]) {
            basePart = Math.mulDiv(beforeBase - s.unwind.reservedBase, order.fracNum, order.fracDen);
            s.unwind.delivered[order.requestId][baseId] = true;
        }
        ISpokeVaultUnwind.UnwindResult memory result;
        SpokeUnwindTypes.Step memory step = SpokeUnwindTypes.Step(
            address(0),
            bytes32(0),
            order.fracNum,
            order.fracDen,
            order.maxLossBps,
            order.payoutMode == uint8(ICoreVaultPayouts.PayoutMode.Instant)
        );
        address[] memory tokens = s.tokens;
        for (uint256 index; index < tokens.length; ++index) {
            if (tokens[index] == c.baseToken || s.unallocated[tokens[index]] == 0) continue;
            step.positionKey = bytes32(uint256(uint160(tokens[index])));
            _deliver(s, order.requestId, step, result);
        }
        ISpokeVault.PositionRef[] memory positions = s.positions;
        for (uint256 index; index < positions.length; ++index) {
            step.adapter = positions[index].adapter;
            step.positionKey = positions[index].positionKey;
            _deliver(s, order.requestId, step, result);
        }
        _clearTiers(tokens);
        uint256 obtained = basePart + s.unallocated[c.baseToken] - beforeBase;
        pending.proceeds += obtained;
        s.unwind.reservedBase += obtained;
        pending.spotOut += result.spotOut;
        pending.marketCost += result.marketCost;
        pending.leaverCost += result.leaverCost;
        _sendResult(s, c, order, result, pending);
        if (closing) s.unwind.closed = true;
    }

    function _recoverSend(
        SpokeVaultTypes.State storage s,
        address base,
        bytes32 requestId,
        SpokeUnwindTypes.Pending storage pending
    ) private {
        bytes32[] storage transits = s.unwind.transits[requestId];
        for (uint256 index; index < transits.length; ++index) {
            bytes32 transitId = transits[index];
            Transit storage transit = s.hubBoundTransits[transitId];
            if (
                transit.state == TransitState.Sent && block.timestamp > transit.fillDeadline
                    && IERC20(base).balanceOf(transit.escrow) >= transit.amountSent
            ) {
                SpokeCrossChainLib.recognizeRefund(s, base, transitId);
            }
            if (transit.state == TransitState.RefundRecognized && !s.unwind.refundRecovered[transitId]) {
                s.unwind.refundRecovered[transitId] = true;
                pending.proceeds += transit.amountSent;
                s.unwind.reservedBase += transit.amountSent;
                if (pending.bridgeCost >= transit.amountSent - transit.amountToArrive) {
                    pending.bridgeCost -= transit.amountSent - transit.amountToArrive;
                }
            }
        }
        if (s.hubBoundTransits[pending.transitId].state == TransitState.RefundRecognized) {
            pending.transitId = bytes32(0);
        }
    }

    function _sendResult(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        OrderCodec.Order memory order,
        ISpokeVaultUnwind.UnwindResult memory result,
        SpokeUnwindTypes.Pending storage pending
    ) private {
        SpokeUnwindTypes.OrderResult memory record;
        record.orderId = OrderCodec.orderId(order);
        record.requestId = order.requestId;
        record.attempt = order.attempt;
        record.spotOut = pending.spotOut;
        record.marketCost = pending.marketCost;
        record.leaverCost = pending.leaverCost + pending.bridgeCost;
        record.delivered = result.delivered;
        record.excluded = result.excluded;
        uint256 amount = pending.proceeds;
        if (pending.transitId != bytes32(0)) {
            record.transitId = pending.transitId;
            record.amountSent = s.hubBoundTransits[pending.transitId].amountSent;
            record.amountToArrive = s.hubBoundTransits[pending.transitId].amountToArrive;
        }
        if (amount != 0) {
            uint256 arrival;
            try IBridgeAdapter(s.bridgeAdapters[0]).quoteSend(c.baseToken, c.hubChainId, amount, "") returns (
                uint256 quoted, uint256
            ) {
                arrival = quoted;
            } catch (bytes memory reason) {
                ++record.excluded;
                emit ISpokeVaultUnwind.UnwindStepExcluded(order.requestId, s.bridgeAdapters[0], bytes32(0), reason);
                _append(s, record);
                return;
            }
            if (arrival == 0 || arrival > amount) {
                ++record.excluded;
                _append(s, record);
                return;
            }
            if (order.maxLossBps != 0 && order.maxLossBps < BPS && (amount - arrival) * BPS > amount * order.maxLossBps)
            {
                ++record.excluded;
                emit ISpokeVaultUnwind.UnwindBridgeExcluded(order.requestId, amount, arrival, order.maxLossBps);
            } else {
                try ISpokeVaultUnwind(address(this)).unwindSend(amount) returns (bytes32 transitId) {
                    record.transitId = transitId;
                } catch (bytes memory reason) {
                    ++record.excluded;
                    emit ISpokeVaultUnwind.UnwindStepExcluded(order.requestId, s.bridgeAdapters[0], bytes32(0), reason);
                    _append(s, record);
                    return;
                }
                record.amountSent = amount;
                record.amountToArrive = s.hubBoundTransits[record.transitId].amountToArrive;
                if (order.payoutMode == uint8(ICoreVaultPayouts.PayoutMode.Instant)) {
                    record.leaverCost += amount - record.amountToArrive;
                    pending.bridgeCost += amount - record.amountToArrive;
                }
                pending.proceeds = 0;
                s.unwind.reservedBase -= amount;
                pending.transitId = record.transitId;
                s.unwind.transits[order.requestId].push(record.transitId);
            }
        }
        _append(s, record);
    }

    function _append(SpokeVaultTypes.State storage s, SpokeUnwindTypes.OrderResult memory record) private {
        SpokeUnwindTypes.OrderResult[] memory previous = s.unwind.reportBlob.length == 0
            ? new SpokeUnwindTypes.OrderResult[](0)
            : abi.decode(s.unwind.reportBlob, (SpokeUnwindTypes.OrderResult[]));
        uint256 count = previous.length < SpokeUnwindTypes.REPORTED_RESULTS ? previous.length + 1 : previous.length;
        SpokeUnwindTypes.OrderResult[] memory records = new SpokeUnwindTypes.OrderResult[](count);
        uint256 offset = previous.length + 1 - count;
        if (offset != 0) {
            uint256 removable = type(uint256).max;
            for (uint256 index; index < previous.length; ++index) {
                if (previous[index].transitId == bytes32(0) || previous[index].transitId == record.transitId) {
                    removable = index;
                    break;
                }
            }
            if (removable == type(uint256).max) revert SpokeUnwindTypes.OrderResultCapacity();
            for (uint256 index = removable; index + 1 < previous.length; ++index) {
                previous[index] = previous[index + 1];
            }
            offset = 0;
        }
        for (uint256 index; index + 1 < count; ++index) {
            records[index] = previous[index + offset];
        }
        records[count - 1] = record;
        s.unwind.reportBlob = abi.encode(records);
    }

    /// @notice DEC-068: a confirmed refund is reported as proof that this Principal send did not arrive.
    function onRefund(SpokeVaultTypes.State storage s, bytes32 transitId) external {
        _markRefunds(s, transitId);
    }

    /// @notice DEC-105/068: automatically recognized refunds appear in the same post-unwind report.
    function _nextReport(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory config)
        private
        returns (uint64 sequence, bytes memory payload)
    {
        (sequence, payload) = SpokeCrossChainLib.nextReport(s, config);
        if (_markRefunds(s, bytes32(0))) {
            ReportCodec.Report memory report = ReportCodec.decode(payload);
            report.unwindResults = s.unwind.reportBlob;
            payload = ReportCodec.encode(report);
        }
    }

    function publishReport(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory config,
        address wormholeCore,
        uint256 messageFee
    ) external returns (uint64 sequence, uint64 wormholeSequence) {
        bytes memory payload;
        (sequence, payload) = _nextReport(s, config);
        wormholeSequence = ICoreBridge(wormholeCore).publishMessage{value: messageFee}(0, payload, 1);
        emit ISpokeVault.ReportPublished(sequence, wormholeSequence, uint64(block.number));
    }

    function _markRefunds(SpokeVaultTypes.State storage s, bytes32 transitId) private returns (bool changed) {
        if (s.unwind.reportBlob.length == 0) return false;
        bytes memory blob = s.unwind.reportBlob;
        uint256 offset;
        uint256 count;
        assembly ("memory-safe") {
            offset := mload(add(blob, 32))
            count := mload(add(blob, 64))
        }
        if (
            blob.length < 64 || offset != 32 || count > SpokeUnwindTypes.REPORTED_RESULTS
                || blob.length != 64 + count * 384
        ) return false;
        SpokeUnwindTypes.OrderResult[] memory records = abi.decode(blob, (SpokeUnwindTypes.OrderResult[]));
        for (uint256 index; index < records.length; ++index) {
            if (
                !records[index].refunded
                    && (s.hubBoundTransits[records[index].transitId].state == TransitState.RefundRecognized
                        || (transitId != bytes32(0) && records[index].transitId == transitId))
            ) {
                records[index].refunded = true;
                changed = true;
            }
        }
        if (changed) s.unwind.reportBlob = abi.encode(records);
    }

    /// @notice The checks of `SpokeVault.executeOrder` (DEC-111, DEC-120 item 2, DEC-139, DEC-093):
    ///         `OrderVerifier.accept` on the vault's order cursor, which also moves the cursor past the order, then
    ///         the order's id.
    /// @dev Here rather than inlined in the vault: the checks and the id take about 2.1 KB (measured, WP-07 D4). The
    ///      vault checks the chain and reentrancy first and executes the order after.
    /// @return o The decoded and checked order (`OrderCodec.check`).
    /// @return orderId `OrderCodec.orderId(o)`, the id the Core Vault published it under.
    /// @return wormholeSequence The order message's Wormhole sequence.
    function acceptOrder(
        SpokeVaultTypes.State storage s,
        address wormholeCore,
        uint16 hubWormholeChainId,
        address coreVault,
        bytes32 fundId,
        bytes calldata vaa
    ) external returns (OrderCodec.Order memory o, bytes32 orderId, uint64 wormholeSequence) {
        OrderVerifier.Cursor storage cursor = s.orders;
        (o, wormholeSequence) = OrderVerifier.accept(cursor, wormholeCore, vaa, hubWormholeChainId, coreVault, fundId);
        orderId = OrderCodec.orderId(o);
        if (o.kind == OrderCodec.UNWIND || o.kind == OrderCodec.CLOSE) {
            if (s.unwind.executed[orderId]) revert SpokeUnwindTypes.OrderAlreadyExecuted(orderId);
            s.unwind.executed[orderId] = true;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Automatic unwind (DEC-137, DEC-140, DEC-141, DEC-148, DEC-151, DEC-118, DEC-136 item 4)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Body of `ISpokeVaultUnwind.unwindForPayout`; the vault checks the chain, the caller and reentrancy
    ///         first. See the interface for the rules.
    /// @dev Each step is an external call of the vault to itself (`unwindStep`) inside try/catch, so a failing exit or
    ///      a sale above the requester's maximum undoes that step alone and leaves the position out (DEC-148); what
    ///      delivered is remembered per request (DEC-151) by `SpokeUnwindTypes.stepId`. The registry is read once
    ///      before the first exit: a close removes a position by swap-and-pop (D-25: a position closed meanwhile simply
    ///      leaves the count). The non-base Unallocated Balances go first, so their share is taken of what the fund held
    ///      before the unwind; a step sells all the non-base principal its exit returned, so it never adds to them.
    /// @dev A step runs with the gas the call has left (EIP-150 forwards 63/64): a requester who sends too little gas
    ///      can make steps fail and leave positions out, which the requester's own maximum loss can do anyway (DEC-148);
    ///      the request then stays open with its memory (DEC-151) and is never paid for what did not deliver.
    function unwindForPayout(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        ISpokeVaultUnwind.UnwindRequest calldata r
    ) external returns (ISpokeVaultUnwind.UnwindResult memory res) {
        address base = c.baseToken;
        if (r.fracNum != 0) {
            SpokeUnwindTypes.Step memory step = SpokeUnwindTypes.Step({
                adapter: address(0),
                positionKey: bytes32(0),
                fracNum: r.fracNum,
                fracDen: r.fracDen,
                maxLossBps: r.maxLossBps,
                instant: r.mode == ICoreVaultPayouts.PayoutMode.Instant
            });
            address[] memory tokens = s.tokens;
            for (uint256 i; i < tokens.length; ++i) {
                if (tokens[i] == base || s.unallocated[tokens[i]] == 0) continue;
                step.positionKey = bytes32(uint256(uint160(tokens[i])));
                _deliver(s, r.requestId, step, res);
            }
            ISpokeVault.PositionRef[] memory refs = s.positions;
            for (uint256 i; i < refs.length; ++i) {
                step.adapter = refs[i].adapter;
                step.positionKey = refs[i].positionKey;
                _deliver(s, r.requestId, step, res);
            }
            _clearTiers(tokens);
        }
        // D-11: the base token's whole Unallocated Balance counted as available in the fraction, so all of it is paid.
        res.proceeds = s.unallocated[base];
        if (res.proceeds != 0) {
            s.unallocated[base] = 0;
            SpokeLedger.payCoreVaultIdle(base, c.coreVault, res.proceeds);
        }
        emit ISpokeVaultUnwind.UnwoundForPayout(r.requestId, r.fracNum, r.fracDen, res);
    }

    /// @dev One step unless it already delivered for the request: its result added to `res` and remembered, or its
    ///      revert data emitted and the step left out.
    function _deliver(
        SpokeVaultTypes.State storage s,
        bytes32 requestId,
        SpokeUnwindTypes.Step memory step,
        ISpokeVaultUnwind.UnwindResult memory res
    ) private {
        bytes32 id = SpokeUnwindTypes.stepId(step.adapter, step.positionKey);
        if (s.unwind.delivered[requestId][id]) return;
        try ISpokeVaultUnwind(address(this)).unwindStep(abi.encode(step)) returns (bytes memory out) {
            SpokeUnwindTypes.StepResult memory sr = abi.decode(out, (SpokeUnwindTypes.StepResult));
            res.spotOut += sr.spotOut;
            res.marketCost += sr.marketCost;
            res.leaverCost += sr.leaverCost;
            ++res.delivered;
            s.unwind.delivered[requestId][id] = true;
        } catch (bytes memory reason) {
            ++res.excluded;
            emit ISpokeVaultUnwind.UnwindStepExcluded(requestId, step.adapter, step.positionKey, reason);
        }
    }

    /// @notice Body of `ISpokeVaultUnwind.unwindStep`; the vault checks that it called itself.
    /// @dev A position: the exit of `fracNum / fracDen` of it (`IAdapter.unwindExitParams`, the vault sizes it, never a
    ///      caller), principal to Unallocated Balance and income to the collected bucket (DEC-079, DEC-092), then the
    ///      sale of each non-base principal it returned. A non-base Unallocated Balance (zero adapter): the sale of
    ///      `fracNum / fracDen` of it.
    function unwindStep(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory c, bytes calldata data)
        external
        returns (bytes memory)
    {
        SpokeUnwindTypes.Step memory st = abi.decode(data, (SpokeUnwindTypes.Step));
        SpokeUnwindTypes.StepResult memory sr;
        if (st.adapter == address(0)) {
            address token = address(uint160(uint256(st.positionKey)));
            _sell(s, c.baseToken, st, token, Math.mulDiv(s.unallocated[token], st.fracNum, st.fracDen), sr);
        } else {
            IAdapter a = SpokeLedger.positionAdapter(s, st.adapter);
            (bool close, bytes memory params) = a.unwindExitParams(st.positionKey, st.fracNum, st.fracDen);
            (IAdapter.Amounts memory amounts, SpokeVaultTypes.PoolTokens memory p) = SpokeLedger.exit(
                s,
                c.baseToken,
                st.adapter,
                st.positionKey,
                close ? SpokeVaultTypes.ExitKind.Close : SpokeVaultTypes.ExitKind.Decrease,
                params
            );
            _sell(s, c.baseToken, st, p.token0, amounts.principal0, sr);
            _sell(s, c.baseToken, st, p.token1, amounts.principal1, sr);
        }
        return abi.encode(sr);
    }

    /// @dev Sells `amount` of `token` into the base token through the Mandate swap adapter of this chain (DEC-136 item
    ///      4: the first one; the alpha lists one per chain) in the tier chosen for `token` in this unwind, held to the
    ///      requester's maximum (DEC-140), and books the sale's Market Cost by mode (DEC-118, DEC-141, D-19).
    /// @dev Checklist doc 15 gap 4: the `Swapped` event carries the requester's maximum and the minimum applied.
    function _sell(
        SpokeVaultTypes.State storage s,
        address base,
        SpokeUnwindTypes.Step memory st,
        address token,
        uint256 amount,
        SpokeUnwindTypes.StepResult memory sr
    ) private {
        if (amount == 0 || token == base || token == address(0)) return;
        ISwapAdapter sa = SpokeLedger.swapAdapter(s, s.swapAdapters[0]);
        uint24 fee = _tier(sa, token, base, amount);
        (uint256 amountOut, uint256 spotOut, uint256 minOut) =
            SpokeLedger.sellDirect(s, sa, token, base, amount, fee, st.maxLossBps);
        emit ISpokeVault.Swapped(address(sa), token, base, amount, amountOut, spotOut, st.maxLossBps, minOut);
        uint256 loss = spotOut > amountOut ? spotOut - amountOut : 0;
        sr.spotOut += spotOut;
        sr.marketCost += loss;
        if (st.instant) {
            sr.leaverCost += loss;
        } else {
            uint256 absorbed = Math.mulDiv(spotOut, STANDARD_SALE_LOSS_ABSORB_BPS, BPS);
            if (loss > absorbed) sr.leaverCost += loss - absorbed;
        }
    }

    /// @dev D-21: the tier `bestDirectFee` chooses for `token`'s first sale in this unwind, reused for the next ones
    ///      (each choice costs 0.56 to 2.46M gas, measured). Kept in transient storage, so a step that reverts takes its
    ///      choice with it; `_clearTiers` empties it at the end of the unwind.
    function _tier(ISwapAdapter sa, address token, address base, uint256 amount) private returns (uint24 fee) {
        bytes32 slot = keccak256(abi.encode(TIER_NAMESPACE, token));
        assembly ("memory-safe") {
            fee := tload(slot)
        }
        if (fee != 0) return fee;
        (fee,) = sa.bestDirectFee(token, base, amount);
        assembly ("memory-safe") {
            tstore(slot, fee)
        }
    }

    function _clearTiers(address[] memory tokens) private {
        for (uint256 i; i < tokens.length; ++i) {
            bytes32 slot = keccak256(abi.encode(TIER_NAMESPACE, tokens[i]));
            assembly ("memory-safe") {
                tstore(slot, 0)
            }
        }
    }
}
