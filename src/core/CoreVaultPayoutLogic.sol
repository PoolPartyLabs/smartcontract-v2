// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {IValueReportReceiver} from "../interfaces/IValueReportReceiver.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeUnwindTypes} from "../spoke/SpokeUnwindTypes.sol";
import {TransferKind, TransitState} from "../interfaces/FundTypes.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {ShareToken} from "./ShareToken.sol";
import {CoreVaultState, CoreVaultWiring, CORE_VAULT_UNWINDING_SLOT, STANDARD_PAYOUT_TERM} from "./CoreVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {CoreVaultIncomeLogic} from "./CoreVaultIncomeLogic.sol";

/// @title CoreVaultPayoutLogic
/// @notice The payout path of the Core Vault (Payout Request, claim, automatic unwind, burn and pay), as an external
///         library that runs in the Core Vault's context (DELEGATECALL into the fund's own linked library, never into
///         an adapter).
/// @dev DEC-131 pattern (alternative C) applied to the Core Vault (D-43): moved out of `CoreVault.sol` unchanged so the
///      Core Vault keeps room under the 24,576-byte limit. `CoreVaultPayout` keeps the entries, the reentrancy guard,
///      the open-fund check, the request checks before the Operating Cash top-up and the top-up itself. It calls
///      `CoreVaultLogic` (the valuation) and `CoreVaultIncomeLogic` (the full-burn income payment) through their own
///      linked addresses, so its creation code links them and its address is part of the Core Vault's creation code
///      and trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058).
/// @dev Events are emitted with the Core Vault as their address; they and the errors are declared in
///      ICoreVaultPayouts, ICoreVault and ICoreVaultLifecycle.
library CoreVaultPayoutLogic {
    using SafeERC20 for IERC20;
    using TransientSlot for *;

    /// @notice DEC-081, DEC-132, DEC-137: the margin of the unwind fraction, 2%.
    uint256 internal constant UNWIND_MARGIN_BPS = 200;

    /// @dev Working values of one claim, kept in memory to stay within the stack without via-IR. `burnable` is the
    ///      most the claim may burn: the balance, or for the manager what lies above the base (DEC-146, D-27).
    struct Claim {
        uint256 balance;
        uint256 burnable;
        uint256 available;
        uint256 wanted;
        uint256 shares;
        uint256 proceeds;
        bool complete;
        bool cappedByManagerBase;
        uint256 shareAssets;
        uint256 totalShares;
        uint256 price;
        uint256 marketCost;
        uint256 leaverCost;
        uint256 excluded;
        uint256 served;
        address holder;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout Request (DEC-020, DEC-024, DEC-060, DEC-072, DEC-077, DEC-095)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVaultPayouts.requestPayout after the guard, the zero-amount check, the open-fund check and, for an
    ///         Instant request, the Operating Cash top-up.
    /// @dev Priced like a claim (payout liveness, DEC-021, DEC-056: a failing valuation dependency falls back to the
    ///      last known value), so the reserve bound and the one-share floor use the Share Price the holder would be
    ///      paid at if the claim ran now. DEC-146: the manager's request may not cross the base. DEC-120 item 1, D-51:
    ///      an Instant request is its own claim and runs it here.
    function requestPayout(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 usdcAmount,
        ICoreVaultPayouts.PayoutMode mode,
        uint16 maxLossBps,
        uint256 messageFee
    ) public returns (ICoreVaultPayouts.PayoutReceipt memory receipt) {
        ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[msg.sender];
        // DEC-024, DEC-046: one open request per address, never cancellable.
        if (req.open) revert ICoreVaultPayouts.PayoutRequestAlreadyOpen(msg.sender);
        uint256 balance = IERC20(w.shareToken).balanceOf(msg.sender);
        if (balance == 0) revert ICoreVaultPayouts.NoShares(msg.sender);
        uint256 price = _requestPrice(s, w, usdcAmount, balance);
        // DEC-077: nothing is burned or locked at request. A closed request leaves nothing behind for the next one.
        delete s.payouts.requests[msg.sender];
        req.mode = mode;
        req.open = true;
        req.requestedAt = uint64(block.timestamp);
        req.termEndsAt = uint64(block.timestamp);
        req.usdcRequested = usdcAmount;
        req.usdcOutstanding = usdcAmount;
        req.requestId = bytes32((uint256(uint160(msg.sender)) << 96) | ++s.payouts.requestCount);
        req.maxLossBps = maxLossBps;
        if (mode == ICoreVaultPayouts.PayoutMode.Standard) {
            // DEC-072, DEC-095: Standard reserves USDC and starts the 72-hour term (DEC-154). OPEN reading (final
            // verification, docs/OPEN-QUESTIONS.md FV-OQ-1): the reserve is bounded by the requester's share value now
            // (DEC-020: the most a request can pay is the whole balance), so a small holder cannot lock Free Idle
            // (DEC-017).
            uint256 reserved =
                Math.min(Math.min(usdcAmount, ShareMath.usdcFor(balance, price)), s.idle - s.payoutReserve);
            s.payoutReserve += reserved;
            req.reserved = reserved;
            req.termEndsAt += STANDARD_PAYOUT_TERM;
        }
        emit ICoreVaultPayouts.PayoutRequested(
            msg.sender, mode, req.requestId, usdcAmount, req.reserved, req.termEndsAt, maxLossBps
        );
        if (mode == ICoreVaultPayouts.PayoutMode.Instant) receipt = _claim(s, w, req, balance, messageFee);
        else if (messageFee != 0) revert ICoreVaultPayouts.PayoutMessageFeeNotUsed(messageFee);
    }

    /// @notice The Share Price a request is checked at: a claim's (payout liveness), with the one-share floor and the
    ///         manager's base checked against it.
    function _requestPrice(CoreVaultState storage s, CoreVaultWiring memory w, uint256 usdcAmount, uint256 balance)
        private
        returns (uint256 price)
    {
        (uint256 assets,) = CoreVaultLogic.recordValuation(s, w, false);
        price = ShareMath.sharePrice(assets, IERC20(w.shareToken).totalSupply());
        // DEC-035 spirit, DEC-077 (final verification): a request below one share's price could never burn a share.
        if (ShareMath.sharesToBurn(usdcAmount, price) == 0) {
            revert ICoreVaultPayouts.PayoutBelowOneShare(usdcAmount, price);
        }
        if (msg.sender == w.manager) _requireManagerBase(s, balance, usdcAmount, price);
    }

    /// @notice DEC-146, DEC-147 item 1, D-27: a manager request that would leave the manager's balance below half of
    ///         the peak reverts, telling the manager to close the fund. Sized at the request's Share Price, rounding
    ///         the shares the request would burn up and the base up, so the check never lets the balance fall below
    ///         half.
    /// @dev Example (DEC-146): peak 200,000 shares at 1.00; a request of 120,000 leaves 80,000 and reverts, 90,000
    ///      leaves 110,000 and passes.
    function _requireManagerBase(CoreVaultState storage s, uint256 balance, uint256 usdcAmount, uint256 price)
        private
        view
    {
        uint256 peak = s.managerPeakShares;
        uint256 burned =
            Math.mulDiv(usdcAmount, ShareMath.PRICE_SCALE, price, Math.Rounding.Ceil) * ShareMath.WHOLE_SHARE;
        uint256 balanceAfter = balance > burned ? balance - burned : 0;
        if (balanceAfter < peak - peak / 2) revert ICoreVaultLifecycle.ManagerMustCloseFund(peak, balanceAfter);
    }

    /// @notice DEC-146, DEC-147 consequence, D-27: the whole shares the manager may burn at a claim, those above
    ///         `ceil(peak / 2)`. The request was checked at its own Share Price; a price that fell before the claim
    ///         would otherwise burn more shares for the same USDC and take the manager below the base, or a sole
    ///         holder to zero shares while the fund is Open.
    function _managerBurnable(CoreVaultState storage s, uint256 balance) private view returns (uint256) {
        uint256 peak = s.managerPeakShares;
        uint256 base = peak - peak / 2;
        return balance > base ? (balance - base) / ShareMath.WHOLE_SHARE * ShareMath.WHOLE_SHARE : 0;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout (DEC-020, DEC-045, DEC-047, DEC-065, DEC-067, DEC-068, DEC-069, DEC-077, DEC-081, DEC-095, DEC-097,
    // DEC-102, DEC-105, DEC-106)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVaultPayouts.claimPayout after the guard, the open-fund check and the Operating Cash top-up.
    /// @dev See `CoreVaultPayout.claimPayout` for the rules (OQ-07, DEC-105, DEC-146, DEC-147, DEC-154, D-26, D-27).
    function claimPayout(CoreVaultState storage s, CoreVaultWiring memory w, uint16 maxLossBps, uint256 messageFee)
        public
        returns (ICoreVaultPayouts.PayoutReceipt memory receipt)
    {
        ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[msg.sender];
        if (!req.open) revert ICoreVaultPayouts.NoOpenPayoutRequest(msg.sender);
        if (req.awaitingSettlement && block.timestamp <= req.orderDeadline) {
            revert ICoreVaultPayouts.PayoutAwaitingSettlement(msg.sender);
        }
        if (req.mode == ICoreVaultPayouts.PayoutMode.Standard && block.timestamp < req.termEndsAt) {
            revert ICoreVaultPayouts.PayoutTermNotEnded(req.termEndsAt);
        }
        uint256 balance = IERC20(w.shareToken).balanceOf(msg.sender);
        if (balance == 0) revert ICoreVaultPayouts.NoShares(msg.sender);
        // DEC-140 item 2, DEC-148: each attempt may come with its own maximum.
        req.maxLossBps = maxLossBps;
        if (req.awaitingSettlement && req.reportedSpokes == req.expectedSpokes) {
            return settlePayout(s, w, msg.sender, messageFee);
        }
        if (req.awaitingSettlement) {
            Claim memory pendingClaim;
            _settlementTransits(s, w, req, pendingClaim, false);
        }
        receipt = _claim(s, w, req, balance, messageFee);
    }

    /// @notice The claim of `msg.sender`'s open request `req`; `balance` is the claimant's share balance, non-zero.
    function _claim(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ICoreVaultPayouts.PayoutRequest storage req,
        uint256 balance,
        uint256 messageFee
    ) private returns (ICoreVaultPayouts.PayoutReceipt memory receipt) {
        // DEC-160: no share is burned on a stale report, whether Idle pays or not (D-28).
        _requireFreshReports(s, w);
        Claim memory c;
        c.holder = msg.sender;
        c.balance = balance;
        c.burnable = msg.sender == w.manager ? _managerBurnable(s, c.balance) : c.balance;

        ICoreVaultPayouts.NavConsolidation memory consolidation = _priceClaim(s, w, c, req);
        // DEC-067, DEC-095, DEC-151 item 3: Idle first (Instant: Free Idle only; Standard: its reserve, then Free Idle).
        if (c.wanted > c.available || req.awaitingSettlement) {
            c.served = _sharesFor(c, req.usdcOutstanding);
            uint256 previousMask = req.awaitingSettlement ? req.expectedSpokes : 0;
            uint256 previousReported = req.reportedSpokes;
            uint32 previousAttempt = req.attempt;
            _unwindForPayout(s, w, c, req);
            if (req.awaitingSettlement) {
                c.marketCost += s.payouts.marketCost[req.requestId];
                c.leaverCost += s.payouts.leaverCost[req.requestId];
                c.proceeds += s.payouts.proceeds[req.requestId];
            }
            uint256 mask = _spokesToUnwind(s, w, req);
            mask |= previousMask & ~previousReported;
            if (req.fracDen == 0 && !req.awaitingSettlement) mask = 0;
            if (mask != 0) {
                if (req.attempt == previousAttempt) ++req.attempt;
                _publishUnwind(s, w, req, c, mask, messageFee);
                return receipt;
            }
            _requireFreshReports(s, w);
            // DEC-105, D-17: one Share Price for the whole request, read after the unwind, on NAV + leaverCost.
            consolidation = _priceClaim(s, w, c, req);
        }
        if (messageFee != 0) revert ICoreVaultPayouts.PayoutMessageFeeNotUsed(messageFee);
        // DEC-077: an outstanding amount below one share's price (after a Partial Payout, or a Share Price that rose
        // since the request) closes the request with nothing burned; the receipt says so (`closedBelowOneShare`).
        c.shares = _sharesFor(c, req.usdcOutstanding);
        c.complete = true;
        // DEC-146, DEC-183 item 1: the manager's burn stopped at the base; the request still closes.
        if (c.burnable < c.balance && c.price != 0) {
            c.cappedByManagerBase = ShareMath.sharesToBurn(req.usdcOutstanding, c.price) > c.burnable;
        }
        if (c.wanted > c.available) {
            // DEC-068: Partial Payout, burn only what Idle can pay and keep the rest of the request open.
            c.shares = _sharesFor(c, c.available);
            c.complete = false;
            c.cappedByManagerBase = false;
        }
        receipt = _executePayout(s, w, c, req);
        if (c.complete) emit ICoreVaultPayouts.PayoutExecuted(msg.sender, receipt, consolidation);
        else emit ICoreVaultPayouts.PartialPayoutExecuted(msg.sender, receipt, consolidation);
    }

    /// @notice DEC-160: every spoke with an accepted report must have a fresh one (within its lifetime, DEC-099) before
    ///         any share is burned, else `StaleSpokeReport(spokeIndex)`.
    /// @dev The hub Spoke Vault is read directly in the valuation, so it needs no report. A spoke without any accepted
    ///      report holds nothing the fund counts. The price-source fallback is unchanged (D-28, SEC-OQ-6).
    function _requireFreshReports(CoreVaultState storage s, CoreVaultWiring memory w) private view {
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        uint256 spokes = s.mandate.spokes.length;
        for (uint256 i; i < spokes; ++i) {
            if (receiver.hasReport(i) && !receiver.isReportFresh(i)) revert ICoreVault.StaleSpokeReport(i);
        }
    }

    /// @notice Prices the claim at the current Share Assets and sizes what it wants.
    function _priceClaim(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Claim memory c,
        ICoreVaultPayouts.PayoutRequest storage req
    ) private returns (ICoreVaultPayouts.NavConsolidation memory consolidation) {
        // Payout liveness (DEC-021, DEC-056): a failing valuation dependency falls back to the last known value.
        (c.shareAssets, consolidation) = CoreVaultLogic.recordValuation(s, w, false);
        c.totalShares = IERC20(w.shareToken).totalSupply();
        // D-17: the requester's Market Cost is added back, so the burn price does not charge it to everyone and the
        // requester pays it once, from the gross (0 before an unwind).
        c.price = ShareMath.sharePrice(c.shareAssets + c.leaverCost, c.totalShares);
        // DEC-077, DEC-020: floor(outstanding / price) whole shares, capped at the balance (the manager: at the base).
        c.wanted = ShareMath.usdcFor(_sharesFor(c, req.usdcOutstanding), c.price);
        c.available = s.idle - s.payoutReserve;
        c.available += req.reserved;
    }

    /// @dev Security review S-18 (DEC-021, DEC-056, FV-OQ-2): at a zero Share Price with shares outstanding (a total
    ///      loss, or every value base reading zero) nothing can be paid, so no share is burned and the claim closes the
    ///      request like an outstanding tail below one share (`closedBelowOneShare`) instead of reverting
    ///      `ZeroSharePrice`; the holder keeps its shares and may request again once value returns.
    /// @dev Capped at `burnable` (the balance; for the manager, the shares above the base, D-27). `wanted` is sized
    ///      with the same cap, so a Partial Payout never burns more than the cap either.
    function _sharesFor(Claim memory c, uint256 usdcAmount) private pure returns (uint256 shares) {
        if (c.price == 0) return 0;
        shares = ShareMath.sharesToBurn(usdcAmount, c.price);
        if (shares > c.burnable) shares = c.burnable;
        if (c.served != 0 && shares > c.served) shares = c.served;
    }

    /// @notice Runs the hub Spoke Vault's proportional automatic unwind for the claim `c` of request `req` and credits
    ///         what reached the Core Vault to Idle (`c.proceeds`), with the unwind's Market Costs (`c.marketCost`,
    ///         `c.leaverCost`) and exclusions (`c.excluded`).
    /// @dev DEC-137, D-11: A = what Idle makes available to the request plus the hub Spoke Vault's base token
    ///      Unallocated Balance, which the unwind pays into Idle first. When A covers what the request wants, only that
    ///      balance moves (DEC-067: no position is touched). Otherwise every position and every non-base Unallocated
    ///      Balance gives `f = (S - A/P) / (T - A/P) x (10,000 + UNWIND_MARGIN_BPS) / 10,000`, capped at 1: S the
    ///      shares to serve, T all shares, P the Share Price before the unwind. Computed from shares (A/P rounded down,
    ///      which only raises f), never from what a pool says a position is worth, so one share unwinds 0.0102% of each
    ///      position whatever the pool's price (DEC-132). Fixed at the first attempt that unwinds positions and kept in
    ///      the request; a retry applies it to the positions that have not delivered (DEC-151), at their size then
    ///      (D-25). The hub only: the spokes' share is their unwind order's (DEC-120, DEC-139).
    /// @dev DEC-080 (Core Vault verifier finding): only what the hub Spoke Vault credits through `returnToIdle` during
    ///      the call (itself backed by USDC above the ledger) reaches Idle; the proceeds it reports are informational.
    ///      Its Market Costs are the fund's own vault's measure and are taken as reported. A reverting unwind never
    ///      blocks the claim (DEC-056): the payout continues with Idle and may be partial (DEC-068); the event carries
    ///      the revert data.
    /// @dev The unwinding flag (`CORE_VAULT_UNWINDING_SLOT`, transient) is set only around the call, so the hub Spoke
    ///      Vault may call back `returnToIdle` from inside it and from nowhere else in the claim
    ///      (`CoreVaultBase.onlyHubSpokeVaultCallback`).
    function _unwindForPayout(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Claim memory c,
        ICoreVaultPayouts.PayoutRequest storage req
    ) private {
        uint256 available = c.available + ISpokeVault(w.hubSpokeVault).unallocatedBalance(w.usdc);
        bool positions = available < c.wanted;
        if (positions && req.fracDen == 0) {
            (req.fracNum, req.fracDen) = _fraction(c, available, req.usdcOutstanding);
        }
        ISpokeVaultUnwind.UnwindRequest memory u;
        u.requestId = req.requestId;
        u.maxLossBps = req.maxLossBps;
        u.mode = req.mode;
        if (positions) {
            (u.fracNum, u.fracDen) = (req.fracNum, req.fracDen);
            ++req.attempt;
        }
        uint256 idleBefore = s.idle;
        CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(true);
        try ISpokeVault(w.hubSpokeVault).unwindForPayout(u) returns (ISpokeVaultUnwind.UnwindResult memory r) {
            (c.marketCost, c.leaverCost, c.excluded) = (r.marketCost, r.leaverCost, r.excluded);
        } catch (bytes memory reason) {
            emit ICoreVaultPayouts.UnwindForPayoutFailed(req.requestId, reason);
        }
        CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(false);
        c.proceeds = s.idle - idleBefore;
    }

    /// @notice D-11's fraction for the claim `c`: `(S - A/P) / (T - A/P) x 1.02`, capped at 1 (DEC-137, DEC-081).
    /// @dev Called only when A < S x P (so P > 0, A/P < S <= T and both differences are positive). Example (DEC-137): 100,000
    ///      shares at 1.00, 30,000 available, a request of 40,000: 10,000 / 70,000 x 1.02 = 14.57%.
    function _fraction(Claim memory c, uint256 available, uint256 outstanding)
        private
        pure
        returns (uint256 fracNum, uint256 fracDen)
    {
        uint256 availableShares = Math.mulDiv(available, ShareMath.WHOLE_SHARE * ShareMath.PRICE_SCALE, c.price);
        uint256 served = _sharesFor(c, outstanding);
        fracNum = (served - availableShares) * (ShareMath.BPS + UNWIND_MARGIN_BPS);
        fracDen = (c.totalShares - availableShares) * ShareMath.BPS;
        if (fracNum > fracDen) fracNum = fracDen;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report hook (WP-07 D2; DEC-105, DEC-120, DEC-139)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called after the Core Vault applied a newly accepted report of spoke `spokeIndex`
    ///         (`CoreVaultTransitLogic.applyReport`). Records costs and retains every Principal identity.
    /// @dev The payout work reads the report's `unwindResults` here: DEC-105 and DEC-120 item 3, the settlement waits
    ///      for every reached spoke's post-unwind report. It runs inside the report delivery, so it must not revert (a
    ///      revert would refuse the report) and must stay bounded in gas.
    function onReportAccepted(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        ReportCodec.Report memory report
    ) public {
        if (!_validResults(report.unwindResults)) return;
        SpokeUnwindTypes.OrderResult[] memory results =
            abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
        if (results.length > SpokeUnwindTypes.REPORTED_RESULTS) return;
        for (uint256 index; index < results.length; ++index) {
            SpokeUnwindTypes.OrderResult memory result = results[index];
            address holder = address(uint160(uint256(result.requestId) >> 96));
            ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[holder];
            if (
                !req.open || !req.awaitingSettlement || req.requestId != result.requestId || result.attempt == 0
                    || result.attempt > req.attempt || req.expectedSpokes & (uint256(1) << spokeIndex) == 0
            ) continue;
            OrderCodec.Order memory order;
            order.kind = OrderCodec.UNWIND;
            order.fundId = w.fundId;
            order.requestId = result.requestId;
            order.attempt = result.attempt;
            if (result.orderId != OrderCodec.orderId(order)) continue;
            SpokeUnwindTypes.OrderResult storage latest = s.payouts.legs[result.requestId][spokeIndex];
            if (result.attempt >= latest.attempt) {
                if (
                    latest.attempt == result.attempt && latest.transitId != bytes32(0)
                        && latest.transitId != result.transitId
                ) continue;
                s.payouts.legs[result.requestId][spokeIndex] = result;
            }
            if (result.transitId != bytes32(0)) {
                bytes32 key = CoreVaultLogic.hubBoundKey(s.mandate.spokes[spokeIndex].chainId, result.transitId);
                SpokeUnwindTypes.OrderResult storage retained = s.payouts.transitResults[key];
                if (retained.transitId == bytes32(0)) {
                    s.payouts.transits[result.requestId][spokeIndex].push(result.transitId);
                    s.payouts.transitResults[key] = result;
                    s.payouts.transitHolder[key] = holder;
                } else if (retained.requestId == result.requestId && result.refunded) {
                    retained.refunded = true;
                }
                onPrincipalCredit(s, s.mandate.spokes[spokeIndex].chainId, result.transitId);
            }
            if (result.attempt == req.attempt) req.reportedSpokes |= uint256(1) << spokeIndex;
        }
    }

    /// @notice DEC-105/120: newly credited payout Principal enters Payout Reserve, never Free Idle.
    function onPrincipalCredit(CoreVaultState storage s, uint256 chainId, bytes32 transitId) public {
        bytes32 key = CoreVaultLogic.hubBoundKey(chainId, transitId);
        ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[s.payouts.transitHolder[key]];
        SpokeUnwindTypes.OrderResult storage leg = s.payouts.transitResults[key];
        if (
            !req.open || req.requestId != leg.requestId || leg.refunded
                || s.hubBound[key].kind != TransferKind.Principal
        ) return;
        uint256 credited = Math.min(s.hubBound[key].credited, leg.amountToArrive);
        uint256 reserved = s.payouts.reservedCredit[key];
        if (credited <= reserved) return;
        s.payouts.reservedCredit[key] = credited;
        req.reserved += credited - reserved;
        s.payoutReserve += credited - reserved;
    }

    function _validResults(bytes memory blob) private pure returns (bool) {
        if (blob.length < 64) return false;
        uint256 offset;
        uint256 count;
        assembly ("memory-safe") {
            offset := mload(add(blob, 32))
            count := mload(add(blob, 64))
        }
        if (offset != 32 || count > SpokeUnwindTypes.REPORTED_RESULTS || blob.length != 64 + count * 384) return false;
        for (uint256 index; index < count; ++index) {
            uint256 attempt;
            uint256 refunded;
            assembly ("memory-safe") {
                let entry := add(add(blob, 96), mul(index, 384))
                attempt := mload(add(entry, 64))
                refunded := mload(add(entry, 352))
            }
            if (attempt > type(uint32).max || refunded > 1) return false;
        }
        return true;
    }

    function _spokesToUnwind(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ICoreVaultPayouts.PayoutRequest storage req
    ) private view returns (uint256 mask) {
        IValueReportReceiver receiver = IValueReportReceiver(w.reportReceiver);
        for (uint256 index; index < s.mandate.spokes.length; ++index) {
            if (
                req.attempt > 1 && !s.payouts.legs[req.requestId][index].refunded
                    && s.payouts.legs[req.requestId][index].transitId != bytes32(0)
                    && (req.awaitingSettlement || s.payouts.legs[req.requestId][index].excluded == 0)
                    && req.reportedSpokes & (uint256(1) << index) != 0
            ) continue;
            if (!receiver.hasReport(index)) continue;
            (ReportCodec.Report memory report,,) = receiver.latestReport(index);
            bool value = report.positions.length != 0;
            for (uint256 tokenIndex; tokenIndex < report.unallocated.length; ++tokenIndex) {
                if (report.unallocated[tokenIndex].amount != 0) value = true;
            }
            if (value || s.payouts.legs[req.requestId][index].refunded) mask |= uint256(1) << index;
        }
    }

    function _publishUnwind(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ICoreVaultPayouts.PayoutRequest storage req,
        Claim memory claim,
        uint256 mask,
        uint256 messageFee
    ) private {
        uint256 available = s.idle - s.payoutReserve + req.reserved;
        uint256 earmark = Math.min(available, claim.wanted);
        s.payoutReserve = s.payoutReserve - req.reserved + earmark;
        req.reserved = earmark;
        if (req.awaitingSettlement) {
            req.expectedSpokes |= mask;
            req.reportedSpokes &= ~mask;
        } else {
            req.expectedSpokes = mask;
            req.reportedSpokes = 0;
        }
        req.awaitingSettlement = true;
        s.payouts.marketCost[req.requestId] = claim.marketCost;
        s.payouts.leaverCost[req.requestId] = claim.leaverCost;
        s.payouts.proceeds[req.requestId] = claim.proceeds;
        OrderCodec.Order memory order;
        order.kind = OrderCodec.UNWIND;
        order.fundId = w.fundId;
        order.requestId = req.requestId;
        order.attempt = req.attempt;
        order.fracNum = req.fracNum;
        order.fracDen = req.fracDen;
        order.maxLossBps = req.maxLossBps;
        order.payoutMode = uint8(req.mode);
        req.orderSequence = OrderCodec.publish(w.wormholeCore, order, messageFee);
        req.orderDeadline = order.deadline;
        emit ICoreVault.OrderPublished(
            order.kind, OrderCodec.orderId(order), order.requestId, order.attempt, req.orderSequence
        );
    }

    /// @notice DEC-105/047: one post-unwind Share Price, after every reached spoke reported and its Principal arrived.
    function settlePayout(CoreVaultState storage s, CoreVaultWiring memory w, address holder, uint256 messageFee)
        public
        returns (ICoreVaultPayouts.PayoutReceipt memory receipt)
    {
        if (messageFee != 0) revert ICoreVaultPayouts.PayoutMessageFeeNotUsed(messageFee);
        ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[holder];
        if (!req.open || !req.awaitingSettlement) revert ICoreVaultPayouts.NoOpenPayoutRequest(holder);
        _requireFreshReports(s, w);
        Claim memory claim;
        claim.holder = holder;
        claim.balance = IERC20(w.shareToken).balanceOf(holder);
        claim.burnable = holder == w.manager ? _managerBurnable(s, claim.balance) : claim.balance;
        claim.marketCost = s.payouts.marketCost[req.requestId];
        claim.leaverCost = s.payouts.leaverCost[req.requestId];
        claim.proceeds = s.payouts.proceeds[req.requestId];
        _settlementLegs(s, w, req, claim);
        ICoreVaultPayouts.NavConsolidation memory consolidation = _priceClaim(s, w, claim, req);
        claim.shares = _sharesFor(claim, Math.min(req.usdcOutstanding, claim.available));
        claim.complete = claim.wanted <= claim.available;
        claim.cappedByManagerBase = claim.price != 0 && claim.burnable < claim.balance
            && ShareMath.sharesToBurn(req.usdcOutstanding, claim.price) > claim.burnable;
        req.awaitingSettlement = false;
        delete s.payouts.marketCost[req.requestId];
        delete s.payouts.leaverCost[req.requestId];
        delete s.payouts.proceeds[req.requestId];
        receipt = _executePayout(s, w, claim, req);
        if (claim.complete) emit ICoreVaultPayouts.PayoutExecuted(holder, receipt, consolidation);
        else emit ICoreVaultPayouts.PartialPayoutExecuted(holder, receipt, consolidation);
    }

    function _settlementLegs(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ICoreVaultPayouts.PayoutRequest storage req,
        Claim memory claim
    ) private {
        for (uint256 index; index < s.mandate.spokes.length; ++index) {
            uint256 bit = uint256(1) << index;
            if (req.expectedSpokes & bit == 0) continue;
            if (req.reportedSpokes & bit == 0) revert ICoreVaultPayouts.SpokeUnwindNotReported(index);
            SpokeUnwindTypes.OrderResult storage leg = s.payouts.legs[req.requestId][index];
            uint256 rate;
            try IPriceSource(w.priceSource).priceInUsdc(s.mandate.spokes[index].spokeToken) returns (
                uint256 price, uint256
            ) {
                rate = price;
            } catch {
                rate = s.lastPrice[s.mandate.spokes[index].spokeToken];
            }
            bytes32 costKey = keccak256(abi.encode(req.requestId, index));
            uint256 marketCost = Math.mulDiv(leg.marketCost, rate, 1e18);
            uint256 leaverCostBase = leg.leaverCost;
            if (leg.refunded && req.mode == ICoreVaultPayouts.PayoutMode.Instant) {
                uint256 bridgeCost = leg.amountSent > leg.amountToArrive ? leg.amountSent - leg.amountToArrive : 0;
                leaverCostBase -= Math.min(leaverCostBase, bridgeCost);
            }
            uint256 leaverCost = Math.mulDiv(leaverCostBase, rate, 1e18);
            claim.marketCost += marketCost > s.payouts.paidMarketCost[costKey]
                ? marketCost - s.payouts.paidMarketCost[costKey]
                : 0;
            claim.leaverCost += leaverCost > s.payouts.paidLeaverCost[costKey]
                ? leaverCost - s.payouts.paidLeaverCost[costKey]
                : 0;
            s.payouts.paidMarketCost[costKey] = Math.max(marketCost, s.payouts.paidMarketCost[costKey]);
            s.payouts.paidLeaverCost[costKey] = Math.max(leaverCost, s.payouts.paidLeaverCost[costKey]);
            claim.excluded += leg.excluded;
        }
        _settlementTransits(s, w, req, claim, true);
    }

    /// @notice DEC-068/139: publish retirement only after Principal credit or accepted refund proof.
    function acknowledgeSpokeTransit(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        bytes32 transitId,
        uint256 messageFee
    ) external returns (uint64 sequence) {
        bytes32 key = CoreVaultLogic.hubBoundKey(s.mandate.spokes[spokeIndex].chainId, transitId);
        bool refunded = s.payouts.transitResults[key].refunded;
        (ReportCodec.Report memory report,,) = IValueReportReceiver(w.reportReceiver).latestReport(spokeIndex);
        if (_validResults(report.unwindResults)) {
            SpokeUnwindTypes.OrderResult[] memory results =
                abi.decode(report.unwindResults, (SpokeUnwindTypes.OrderResult[]));
            for (uint256 index; index < results.length; ++index) {
                if (results[index].transitId == transitId && results[index].refunded) refunded = true;
            }
        }
        if (
            !refunded
                && (s.hubBound[key].kind != TransferKind.Principal
                    || s.hubBound[key].credited == 0
                    || s.hubBound[key].credited < s.hubBound[key].listed)
        ) {
            revert ICoreVaultPayouts.SpokeUnwindNotCredited(spokeIndex, transitId);
        }
        OrderCodec.Order memory order;
        order.kind = OrderCodec.ACKNOWLEDGE;
        order.fundId = w.fundId;
        order.requestId = transitId;
        order.fracNum = s.mandate.spokes[spokeIndex].chainId;
        order.fracDen = uint256(refunded ? TransitState.RefundRecognized : TransitState.ArrivalConfirmed);
        sequence = OrderCodec.publish(w.wormholeCore, order, messageFee);
        emit ICoreVault.OrderPublished(order.kind, OrderCodec.orderId(order), transitId, 0, sequence);
    }

    function _settlementTransits(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ICoreVaultPayouts.PayoutRequest storage req,
        Claim memory claim,
        bool consume
    ) private {
        for (uint256 index; index < s.mandate.spokes.length; ++index) {
            bytes32[] storage transits = s.payouts.transits[req.requestId][index];
            for (uint256 transitIndex; transitIndex < transits.length; ++transitIndex) {
                bytes32 key = CoreVaultLogic.hubBoundKey(s.mandate.spokes[index].chainId, transits[transitIndex]);
                SpokeUnwindTypes.OrderResult storage leg = s.payouts.transitResults[key];
                if (leg.refunded) continue;
                if (s.hubBound[key].kind != TransferKind.Principal || s.hubBound[key].credited < leg.amountToArrive) {
                    revert ICoreVaultPayouts.SpokeUnwindNotCredited(index, leg.transitId);
                }
                if (consume && !s.payouts.proceedsConsumed[key]) {
                    uint256 rate;
                    try IPriceSource(w.priceSource).priceInUsdc(s.mandate.spokes[index].spokeToken) returns (
                        uint256 price, uint256
                    ) {
                        rate = price;
                    } catch {
                        rate = s.lastPrice[s.mandate.spokes[index].spokeToken];
                    }
                    claim.proceeds += Math.mulDiv(leg.amountToArrive, rate, 1e18);
                    s.payouts.proceedsConsumed[key] = true;
                }
            }
        }
    }

    /// @notice Burn and pay atomically (DEC-047), fees, reserve release and the full-burn income payment (DEC-045).
    function _executePayout(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        Claim memory c,
        ICoreVaultPayouts.PayoutRequest storage req
    ) private returns (ICoreVaultPayouts.PayoutReceipt memory r) {
        r.mode = req.mode;
        r.usdcRequested = req.usdcRequested;
        r.sharesBurned = c.shares;
        r.usdcGross = ShareMath.usdcFor(c.shares, c.price);
        // DEC-075: Payout Fee on Instant only. DEC-144 items 4-5 (corrects DEC-102 items 2-4): it stays in Idle, in
        // USDC.
        if (req.mode == ICoreVaultPayouts.PayoutMode.Instant) {
            r.payoutFee = ShareMath.bpsOf(r.usdcGross, w.payoutFeeBps);
        }
        // DEC-106, DEC-113: flow fee on the amount paid out, deducted from what the shareholder receives.
        r.flowFee = ShareMath.flowFee(r.usdcGross, w.flowFeeBps);
        // DEC-118, DEC-141, D-17: the requester's Market Cost is deducted once and stays in Idle for those who stay;
        // what the payout cannot carry is the fund's.
        r.leaverCost = Math.min(c.leaverCost, r.usdcGross - r.payoutFee - r.flowFee);
        r.marketCost = c.marketCost;
        r.marketCostAbsorbed = c.marketCost > r.leaverCost ? c.marketCost - r.leaverCost : 0;
        r.usdcPaid = r.usdcGross - r.payoutFee - r.flowFee - r.leaverCost;
        r.excludedPositions = c.excluded;
        r.fracNum = req.fracNum;
        r.fracDen = req.fracDen;
        r.sharePrice = c.price;
        r.shareAssets = c.shareAssets;
        r.totalShares = c.totalShares;
        r.unwindProceeds = c.proceeds;
        r.closedBelowOneShare = c.complete && c.shares == 0;
        r.requestId = req.requestId;
        r.cappedByManagerBase = c.cappedByManagerBase;
        // DEC-084, DEC-105: recorded only, never used for the burn.
        if (c.proceeds != 0 && c.shares != 0) {
            r.payoutSettlementPrice = Math.mulDiv(c.proceeds, ShareMath.WHOLE_SHARE * ShareMath.PRICE_SCALE, c.shares);
        }

        // Effects. DEC-014: the income hook checkpoints with the balance before the burn.
        CoreVaultIncomeLogic.beforeBalanceChange(s, w, c.holder, c.balance);
        // DEC-144: the Payout Fee never leaves Idle, so it raises the Share Price of those who stay (R-144-A); nor
        // does the requester's Market Cost (DEC-118, DEC-141).
        s.idle -= r.usdcGross - r.payoutFee - r.leaverCost;
        uint256 reserved = req.reserved;
        uint256 used = Math.min(reserved, r.usdcGross);
        reserved -= used;
        if (c.complete) {
            // Closed: release what is left of the reserve (DEC-072) and the request.
            req.open = false;
            req.usdcOutstanding = 0;
            req.reserved = 0;
            s.payoutReserve -= used + reserved;
        } else {
            req.usdcOutstanding -= r.usdcGross;
            r.usdcOutstanding = req.usdcOutstanding;
            req.reserved = reserved;
            s.payoutReserve -= used;
            if (req.mode == ICoreVaultPayouts.PayoutMode.Instant && !req.awaitingSettlement) {
                req.reserved = 0;
                s.payoutReserve -= reserved;
            }
        }

        // Interactions.
        if (c.shares != 0) ShareToken(w.shareToken).burn(c.holder, c.shares);
        // Security review S-12: a failed flow-fee transfer is owed to the protocol, never a reason to refuse the claim.
        CoreVaultLogic.payFee(s, w.usdc, w.protocolRecipient, r.flowFee);
        if (r.usdcPaid != 0) IERC20(w.usdc).safeTransfer(c.holder, r.usdcPaid);
        // DEC-045, DEC-047: after a full burn the hook pays all Attributed Income.
        if (c.shares != 0) CoreVaultIncomeLogic.afterBurn(s, w, c.holder, c.shares, c.balance - c.shares);
    }
}
