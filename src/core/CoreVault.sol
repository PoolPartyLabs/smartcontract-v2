// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {ShareToken} from "./ShareToken.sol";
import {CoreVaultBase, CoreVaultConfig} from "./CoreVaultBase.sol";
import {CoreVaultTransit} from "./CoreVaultTransit.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";

/// @title CoreVault
/// @notice Hub Chain contract of a fund: custody of Idle USDC, the Share ledger, Payout Requests and Payouts, the
///         Attributed Income bucket and Income Withdrawal, sends to spokes and the transit state machine.
/// @dev See ICoreVault for the rules of every verb. DEC-022, DEC-058: no proxy, no upgrade path, no selfdestruct.
///      DEC-054: never calls an adapter; reads the hub Spoke Vault and the ValueReportReceiver. Every value-moving
///      external entry is `nonReentrant` (the two hub Spoke Vault callbacks are guarded as described in the base).
contract CoreVault is CoreVaultTransit {
    using SafeERC20 for IERC20;
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @notice DEC-081: the unwind targets the shortfall plus 2%.
    uint256 public constant UNWIND_MARGIN_BPS = 200;

    /// @dev Working values of one claim, kept in memory to stay within the stack without via-IR.
    struct Claim {
        uint256 balance;
        uint256 available;
        uint256 wanted;
        uint256 shares;
        uint256 proceeds;
        bool complete;
        uint256 shareAssets;
        uint256 totalShares;
        uint256 price;
    }

    /// @param m The fund's Mandate, validated with MandateLib (DEC-053).
    /// @param c Wiring; see CoreVaultConfig.
    constructor(Mandate memory m, CoreVaultConfig memory c) CoreVaultBase(m, c) {}

    // ---------------------------------------------------------------------------------------------------------------
    // Deposit (DEC-009, DEC-035, DEC-061, DEC-071, DEC-106)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function deposit(uint256 usdcAmount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares, uint256 usdcCharged)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        uint256 supply = _totalShares();
        // DEC-061, DEC-095: the first deposit of a fund with no shares is at least the Mandate minimum.
        if (supply == 0 && usdcAmount < _minFirstDeposit) revert BelowMinFirstDeposit(usdcAmount, _minFirstDeposit);
        // DEC-096: Operating Cash top-up first, so the depositor enters at the post-expense price.
        _topUpOperatingCash();
        // Q57 reading: a mint reverts on a stale spoke report or a stale price. DEC-014: the entrant's checkpoint below
        // gives it no income collected before entry (ruling 2026-09-29: the index moves only at collection).
        (uint256 assets, NavConsolidation memory consolidation) = CoreVaultLogic.recordValuation(_s, _wiring(), true);
        uint256 price = ShareMath.sharePrice(assets, supply);
        uint256 usdcForShares;
        uint256 fee;
        (shares, usdcForShares, fee) = ShareMath.previewDeposit(usdcAmount, flowFeeBps, price);
        // DEC-035: a deposit below one share's price is rejected.
        if (shares == 0) revert DepositBelowOneShare(usdcAmount - fee, price);
        if (shares < minShares) revert SharesBelowMinimum(shares, minShares);
        usdcCharged = usdcForShares + fee;

        // DEC-014, Q60: checkpoint with the balance before the mint.
        _s.income.checkpoint(msg.sender, _sharesOf(msg.sender));
        _s.idle += usdcForShares;
        emit Deposited(msg.sender, usdcForShares, fee, shares, price, assets, supply, consolidation);

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcForShares);
        // DEC-106: the flow fee goes to the protocol in the same transaction.
        if (fee != 0) IERC20(usdc).safeTransferFrom(msg.sender, protocolRecipient, fee);
        ShareToken(shareToken).mint(msg.sender, shares);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout Request (DEC-020, DEC-024, DEC-060, DEC-072, DEC-077, DEC-095)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function requestPayout(uint256 usdcAmount, PayoutMode mode) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        PayoutRequest storage req = _s.requests[msg.sender];
        // DEC-024, DEC-046: one open request per address, never cancellable.
        if (req.open) revert PayoutRequestAlreadyOpen(msg.sender);
        if (_sharesOf(msg.sender) == 0) revert NoShares(msg.sender);
        uint256 reserved;
        uint64 termEndsAt = uint64(block.timestamp);
        if (mode == PayoutMode.Standard) {
            // DEC-072, DEC-095: Standard reserves min(amount, Free Idle) as USDC and starts the term (DEC-060).
            reserved = Math.min(usdcAmount, freeIdle());
            _s.payoutReserve += reserved;
            termEndsAt += standardPayoutTerm;
        }
        // DEC-077: nothing is burned or locked at request.
        _s.requests[msg.sender] = PayoutRequest({
            mode: mode,
            open: true,
            requestedAt: uint64(block.timestamp),
            termEndsAt: termEndsAt,
            usdcRequested: usdcAmount,
            usdcOutstanding: usdcAmount,
            reserved: reserved
        });
        emit PayoutRequested(msg.sender, mode, usdcAmount, reserved, termEndsAt);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout (DEC-020, DEC-045, DEC-047, DEC-065, DEC-067, DEC-068, DEC-069, DEC-077, DEC-081, DEC-095, DEC-097,
    // DEC-102, DEC-105, DEC-106)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev OQ-07: a Standard Payout is claimable only after its term. Feedback question 2 (OPEN): the automatic unwind
    ///      reaches hub positions only (`ISpokeVault.unwindForPayout` on the hub Spoke Vault), so DEC-105 needs no new
    ///      spoke report (erratum 11 reading). Q57 reading: an Idle-paid payout never reverts on a stale report or
    ///      price. Payout liveness (DEC-021, DEC-056): nor when the hub report read or a price read fails; the last
    ///      known value is used with an event (CoreVaultLogic.recordValuation). LC-45 / LC-141: the fund bears the market cost of the unwind (flagged). LC-45 / LC-47: no Network
    ///      Costs are charged to the requester (flagged).
    function claimPayout(bytes calldata unwindHints) external nonReentrant returns (PayoutReceipt memory receipt) {
        PayoutRequest storage req = _s.requests[msg.sender];
        if (!req.open) revert NoOpenPayoutRequest(msg.sender);
        if (req.mode == PayoutMode.Standard && block.timestamp < req.termEndsAt) {
            revert PayoutTermNotEnded(req.termEndsAt);
        }
        Claim memory c;
        c.balance = _sharesOf(msg.sender);
        if (c.balance == 0) revert NoShares(msg.sender);
        _topUpOperatingCash();

        NavConsolidation memory consolidation = _priceClaim(c, req);
        // DEC-067, DEC-095: Idle first (Instant: Free Idle only; Standard: its reserve, then Free Idle).
        if (c.wanted > c.available) {
            // DEC-081, DEC-097: unwind in Mandate order the shortfall plus 2%, proceeds to Idle.
            uint256 shortfall = c.wanted - c.available;
            c.proceeds = _unwindForPayout(shortfall + shortfall * UNWIND_MARGIN_BPS / 10_000, unwindHints);
            // DEC-105: one Share Price for the whole request, read after the unwind.
            if (c.proceeds != 0) consolidation = _priceClaim(c, req);
        }
        // A request whose outstanding amount is below one share's price closes with nothing burned (DEC-077).
        c.shares = _sharesFor(c, req.usdcOutstanding);
        c.complete = true;
        if (c.wanted > c.available) {
            // DEC-068: Partial Payout, burn only what Idle can pay and keep the rest of the request open.
            c.shares = _sharesFor(c, c.available);
            c.complete = false;
            if (c.shares == 0) revert InsufficientFreeIdle(c.wanted, c.available);
        }
        receipt = _executePayout(c, req);
        if (c.complete) emit PayoutExecuted(msg.sender, receipt, consolidation);
        else emit PartialPayoutExecuted(msg.sender, receipt, consolidation);
    }

    /// @notice Prices the claim at the current Share Assets and sizes what it wants.
    function _priceClaim(Claim memory c, PayoutRequest storage req)
        private
        returns (NavConsolidation memory consolidation)
    {
        // Payout liveness (DEC-021, DEC-056): a failing valuation dependency falls back to the last known value.
        (c.shareAssets, consolidation) = CoreVaultLogic.recordValuation(_s, _wiring(), false);
        c.totalShares = _totalShares();
        c.price = ShareMath.sharePrice(c.shareAssets, c.totalShares);
        // DEC-077, DEC-020: floor(outstanding / price) whole shares, capped at the balance.
        c.wanted = ShareMath.usdcFor(_sharesFor(c, req.usdcOutstanding), c.price);
        c.available = freeIdle();
        if (req.mode == PayoutMode.Standard) c.available += req.reserved;
    }

    function _sharesFor(Claim memory c, uint256 usdcAmount) private pure returns (uint256 shares) {
        shares = ShareMath.sharesToBurn(usdcAmount, c.price);
        if (shares > c.balance) shares = c.balance;
    }

    /// @notice Runs the hub Spoke Vault's automatic unwind and credits what reached the Core Vault to Idle.
    /// @dev DEC-080 (Core Vault verifier finding): only what the hub Spoke Vault credits through `returnToIdle` during
    ///      the call (itself backed by USDC above the ledger) reaches Idle; the amount it reports is informational, so
    ///      no `balanceOf`-derived amount can reach a value base. A reverting unwind never blocks the claim (DEC-056):
    ///      the payout continues with Idle and may be partial (DEC-068).
    function _unwindForPayout(uint256 target, bytes calldata hints) private returns (uint256 proceeds) {
        uint256 idleBefore = _s.idle;
        _unwinding = true;
        try ISpokeVault(hubSpokeVault).unwindForPayout(target, hints) {
            _unwinding = false;
        } catch {
            _unwinding = false;
            emit UnwindForPayoutFailed(target);
        }
        proceeds = _s.idle - idleBefore;
    }

    /// @notice Burn and pay atomically (DEC-047), fees, reserve release and the full-burn income payment (DEC-045).
    function _executePayout(Claim memory c, PayoutRequest storage req) private returns (PayoutReceipt memory r) {
        r.mode = req.mode;
        r.usdcRequested = req.usdcRequested;
        r.sharesBurned = c.shares;
        r.usdcGross = ShareMath.usdcFor(c.shares, c.price);
        // DEC-075, DEC-102: Payout Fee on Instant only, whole to Operating Cash.
        if (req.mode == PayoutMode.Instant) r.payoutFee = ShareMath.bpsOf(r.usdcGross, payoutFeeBps);
        // DEC-106, LC-143 reading: flow fee on the amount paid out, deducted from what the shareholder receives.
        r.flowFee = ShareMath.flowFee(r.usdcGross, flowFeeBps);
        r.usdcPaid = r.usdcGross - r.payoutFee - r.flowFee;
        r.sharePrice = c.price;
        r.shareAssets = c.shareAssets;
        r.totalShares = c.totalShares;
        r.unwindProceeds = c.proceeds;
        // DEC-084, DEC-105: recorded only, never used for the burn.
        if (c.proceeds != 0 && c.shares != 0) {
            r.payoutSettlementPrice = Math.mulDiv(c.proceeds, ShareMath.WHOLE_SHARE * ShareMath.PRICE_SCALE, c.shares);
        }

        // Effects. DEC-014: checkpoint with the balance before the burn.
        _s.income.checkpoint(msg.sender, c.balance);
        _s.idle -= r.usdcGross;
        uint256 reserved = req.reserved;
        uint256 used = Math.min(reserved, r.usdcGross);
        reserved -= used;
        _s.operatingCash += r.payoutFee;
        if (c.complete) {
            // Closed: release what is left of the reserve (DEC-072) and the request.
            req.open = false;
            req.usdcOutstanding = 0;
            req.reserved = 0;
            _s.payoutReserve -= used + reserved;
        } else {
            req.usdcOutstanding -= r.usdcGross;
            r.usdcOutstanding = req.usdcOutstanding;
            req.reserved = reserved;
            _s.payoutReserve -= used;
        }

        // Interactions.
        if (c.shares != 0) ShareToken(shareToken).burn(msg.sender, c.shares);
        if (r.flowFee != 0) IERC20(usdc).safeTransfer(protocolRecipient, r.flowFee);
        if (r.usdcPaid != 0) IERC20(usdc).safeTransfer(msg.sender, r.usdcPaid);
        if (c.shares == c.balance) _payAllIncome(msg.sender);
    }
}
