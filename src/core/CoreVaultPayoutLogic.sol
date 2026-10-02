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
import {ShareMath} from "../libraries/ShareMath.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
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

    /// @notice DEC-081: the unwind targets the shortfall plus 2%.
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
        uint256 shareAssets;
        uint256 totalShares;
        uint256 price;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout Request (DEC-020, DEC-024, DEC-060, DEC-072, DEC-077, DEC-095)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVaultPayouts.requestPayout after the guard, the zero-amount check and the open-fund check.
    /// @dev Priced like a claim (payout liveness, DEC-021, DEC-056: a failing valuation dependency falls back to the
    ///      last known value, never a revert on age, OQ-10), so the reserve bound and the one-share floor use the Share
    ///      Price the holder would be paid at if the claim ran now. DEC-146: the manager's request may not cross the
    ///      base.
    function requestPayout(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 usdcAmount,
        ICoreVaultPayouts.PayoutMode mode
    ) public {
        ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[msg.sender];
        // DEC-024, DEC-046: one open request per address, never cancellable.
        if (req.open) revert ICoreVaultPayouts.PayoutRequestAlreadyOpen(msg.sender);
        uint256 balance = IERC20(w.shareToken).balanceOf(msg.sender);
        if (balance == 0) revert ICoreVaultPayouts.NoShares(msg.sender);
        (uint256 assets,) = CoreVaultLogic.recordValuation(s, w, false);
        uint256 price = ShareMath.sharePrice(assets, IERC20(w.shareToken).totalSupply());
        // DEC-035 spirit, DEC-077 (final verification): a request below one share's price could never burn a share.
        if (ShareMath.sharesToBurn(usdcAmount, price) == 0) {
            revert ICoreVaultPayouts.PayoutBelowOneShare(usdcAmount, price);
        }
        if (msg.sender == w.manager) _requireManagerBase(s, balance, usdcAmount, price);
        uint256 reserved;
        uint64 termEndsAt = uint64(block.timestamp);
        if (mode == ICoreVaultPayouts.PayoutMode.Standard) {
            // DEC-072, DEC-095: Standard reserves USDC and starts the 72-hour term (DEC-154). OPEN reading (final verification,
            // docs/OPEN-QUESTIONS.md FV-OQ-1): the reserve is bounded by the requester's share value now (DEC-020: the
            // most a request can pay is the whole balance), so a small holder cannot lock Free Idle (DEC-017).
            reserved = Math.min(Math.min(usdcAmount, ShareMath.usdcFor(balance, price)), s.idle - s.payoutReserve);
            s.payoutReserve += reserved;
            termEndsAt += STANDARD_PAYOUT_TERM;
        }
        // DEC-077: nothing is burned or locked at request.
        s.payouts.requests[msg.sender] = ICoreVaultPayouts.PayoutRequest({
            mode: mode,
            open: true,
            requestedAt: uint64(block.timestamp),
            termEndsAt: termEndsAt,
            usdcRequested: usdcAmount,
            usdcOutstanding: usdcAmount,
            reserved: reserved
        });
        emit ICoreVaultPayouts.PayoutRequested(msg.sender, mode, usdcAmount, reserved, termEndsAt);
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

    /// @notice ICoreVaultPayouts.claimPayout after the guard, the open-fund check, the request checks and the Operating
    ///         Cash top-up; `balance` is the claimant's share balance, checked non-zero.
    /// @dev See `CoreVaultPayout.claimPayout` for the rules (OQ-07, DEC-105, DEC-146, DEC-147, D-26, D-27).
    function claimPayout(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 balance,
        bytes calldata unwindHints
    ) public returns (ICoreVaultPayouts.PayoutReceipt memory receipt) {
        ICoreVaultPayouts.PayoutRequest storage req = s.payouts.requests[msg.sender];
        Claim memory c;
        c.balance = balance;
        c.burnable = msg.sender == w.manager ? _managerBurnable(s, c.balance) : c.balance;

        ICoreVaultPayouts.NavConsolidation memory consolidation = _priceClaim(s, w, c, req);
        // DEC-067, DEC-095: Idle first (Instant: Free Idle only; Standard: its reserve, then Free Idle).
        if (c.wanted > c.available) {
            // DEC-081, DEC-097: unwind the shortfall plus 2% (registry order until WP-09, DEC-137), proceeds to Idle.
            uint256 shortfall = c.wanted - c.available;
            c.proceeds = _unwindForPayout(s, w, shortfall + shortfall * UNWIND_MARGIN_BPS / 10_000, unwindHints);
            // DEC-105: one Share Price for the whole request, read after the unwind.
            if (c.proceeds != 0) consolidation = _priceClaim(s, w, c, req);
        }
        // DEC-077: an outstanding amount below one share's price (after a Partial Payout, or a Share Price that rose
        // since the request) closes the request with nothing burned; the receipt says so (`closedBelowOneShare`).
        c.shares = _sharesFor(c, req.usdcOutstanding);
        c.complete = true;
        if (c.wanted > c.available) {
            // DEC-068: Partial Payout, burn only what Idle can pay and keep the rest of the request open.
            c.shares = _sharesFor(c, c.available);
            c.complete = false;
            if (c.shares == 0) revert ICoreVault.InsufficientFreeIdle(c.wanted, c.available);
        }
        receipt = _executePayout(s, w, c, req);
        if (c.complete) emit ICoreVaultPayouts.PayoutExecuted(msg.sender, receipt, consolidation);
        else emit ICoreVaultPayouts.PartialPayoutExecuted(msg.sender, receipt, consolidation);
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
        c.price = ShareMath.sharePrice(c.shareAssets, c.totalShares);
        // DEC-077, DEC-020: floor(outstanding / price) whole shares, capped at the balance (the manager: at the base).
        c.wanted = ShareMath.usdcFor(_sharesFor(c, req.usdcOutstanding), c.price);
        c.available = s.idle - s.payoutReserve;
        if (req.mode == ICoreVaultPayouts.PayoutMode.Standard) c.available += req.reserved;
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
    }

    /// @notice Runs the hub Spoke Vault's automatic unwind and credits what reached the Core Vault to Idle.
    /// @dev DEC-080 (Core Vault verifier finding): only what the hub Spoke Vault credits through `returnToIdle` during
    ///      the call (itself backed by USDC above the ledger) reaches Idle; the amount it reports is informational, so
    ///      no `balanceOf`-derived amount can reach a value base. A reverting unwind never blocks the claim (DEC-056):
    ///      the payout continues with Idle and may be partial (DEC-068).
    /// @dev The unwinding flag (`CORE_VAULT_UNWINDING_SLOT`, transient) is set only around the call, so the hub Spoke
    ///      Vault may call back `returnToIdle` from inside it and from nowhere else in the claim
    ///      (`CoreVaultBase.onlyHubSpokeVaultCallback`).
    function _unwindForPayout(CoreVaultState storage s, CoreVaultWiring memory w, uint256 target, bytes calldata hints)
        private
        returns (uint256 proceeds)
    {
        uint256 idleBefore = s.idle;
        CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(true);
        try ISpokeVault(w.hubSpokeVault).unwindForPayout(target, hints) {
            CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(false);
        } catch {
            CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(false);
            emit ICoreVaultPayouts.UnwindForPayoutFailed(target);
        }
        proceeds = s.idle - idleBefore;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report hook (WP-07 D2; DEC-105, DEC-120, DEC-139)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called after the Core Vault applied a newly accepted report of spoke `spokeIndex`
    ///         (`CoreVaultTransitLogic.applyReport`). Nothing to do yet.
    /// @dev The payout work reads the report's `unwindResults` here: DEC-105 and DEC-120 item 3, the settlement waits
    ///      for every reached spoke's post-unwind report. It runs inside the report delivery, so it must not revert (a
    ///      revert would refuse the report) and must stay bounded in gas.
    function onReportAccepted(CoreVaultState storage, CoreVaultWiring memory, uint256, ReportCodec.Report memory)
        public
        pure {}

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
        r.usdcPaid = r.usdcGross - r.payoutFee - r.flowFee;
        r.sharePrice = c.price;
        r.shareAssets = c.shareAssets;
        r.totalShares = c.totalShares;
        r.unwindProceeds = c.proceeds;
        r.closedBelowOneShare = c.complete && c.shares == 0;
        // DEC-084, DEC-105: recorded only, never used for the burn.
        if (c.proceeds != 0 && c.shares != 0) {
            r.payoutSettlementPrice = Math.mulDiv(c.proceeds, ShareMath.WHOLE_SHARE * ShareMath.PRICE_SCALE, c.shares);
        }

        // Effects. DEC-014: the income hook checkpoints with the balance before the burn.
        CoreVaultIncomeLogic.beforeBalanceChange(s, w, msg.sender, c.balance);
        // DEC-144: the Payout Fee never leaves Idle, so it raises the Share Price of those who stay (R-144-A).
        s.idle -= r.usdcGross - r.payoutFee;
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
        }

        // Interactions.
        if (c.shares != 0) ShareToken(w.shareToken).burn(msg.sender, c.shares);
        // Security review S-12: a failed flow-fee transfer is owed to the protocol, never a reason to refuse the claim.
        CoreVaultLogic.payFee(s, w.usdc, w.protocolRecipient, r.flowFee);
        if (r.usdcPaid != 0) IERC20(w.usdc).safeTransfer(msg.sender, r.usdcPaid);
        // DEC-045, DEC-047: after a full burn the hook pays all Attributed Income.
        if (c.shares != 0) CoreVaultIncomeLogic.afterBurn(s, w, msg.sender, c.shares, c.balance - c.shares);
    }
}
