// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TransientSlot} from "@openzeppelin/contracts/utils/TransientSlot.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {ShareToken} from "./ShareToken.sol";
import {CoreVaultBase, CoreVaultConfig} from "./CoreVaultBase.sol";
import {CORE_VAULT_UNWINDING_SLOT} from "./CoreVaultTypes.sol";
import {CoreVaultTransit} from "./CoreVaultTransit.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";

/// @title CoreVault
/// @notice Hub Chain contract of a fund: custody of Idle USDC, the Share ledger, the manager's seed and the fund
///         states, Payout Requests and Payouts, the Attributed Income bucket and Income Withdrawal, sends to spokes and
///         the transit state machine.
/// @dev See ICoreVault and ICoreVaultLifecycle for the rules of every verb. DEC-022, DEC-058: no proxy, no upgrade
///      path, no selfdestruct. The value bases and collected income live in the linked external library
///      `CoreVaultLogic`, report application, sends and transit outcomes in `CoreVaultTransitLogic` (DEC-131 pattern,
///      D-43), each called by DELEGATECALL over this vault's storage: their addresses are part of the creation code and
///      trust surface; the operator deploys them once per chain and the factory pins the code linked to them. They are
///      the only DELEGATECALLs the vault makes; the Core Vault never calls an adapter. DEC-054: never calls an
///      adapter; reads the hub Spoke Vault and the ValueReportReceiver. Every value-moving external entry is
///      `nonReentrant` (the two hub Spoke Vault callbacks are guarded as described in the base).
contract CoreVault is CoreVaultTransit {
    using SafeERC20 for IERC20;
    using IncomeAccumulator for IncomeAccumulator.State;
    using TransientSlot for *;

    /// @notice DEC-081: the unwind targets the shortfall plus 2%.
    uint256 public constant UNWIND_MARGIN_BPS = 200;

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

    /// @param m The fund's Mandate, validated with MandateLib (DEC-053).
    /// @param c Wiring; see CoreVaultConfig.
    constructor(Mandate memory m, CoreVaultConfig memory c) CoreVaultBase(m, c) {}

    // ---------------------------------------------------------------------------------------------------------------
    // Deposit (DEC-009, DEC-035, DEC-061, DEC-071, DEC-106)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev DEC-121, DEC-127, DEC-147: only an Open fund that was seeded takes deposits; the first-deposit minimum
    ///      (DEC-061, DEC-095) applies to the seed, the only mint at supply 0, so a fund whose shares were all burned
    ///      never re-opens at 1.00.
    function deposit(uint256 usdcAmount, uint256 minShares)
        external
        nonReentrant
        returns (uint256 shares, uint256 usdcCharged)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireOpen();
        uint256 supply = _totalShares();
        if (supply == 0) revert FundNotSeeded();
        // DEC-096: Operating Cash top-up first, so the depositor enters at the post-expense price.
        _topUpOperatingCash();
        // Q57 reading: a mint reverts on a stale spoke report or a stale price. DEC-014: the entrant's checkpoint below
        // gives it no income collected before entry (ruling 2026-09-29: the index moves only at collection).
        (uint256 assets, NavConsolidation memory consolidation) = CoreVaultLogic.recordValuation(_s, _wiring(), true);
        uint256 price = ShareMath.sharePrice(assets, supply);
        // Independent verification plan MM-3 (DEC-035, DEC-061 residual OPEN): below one base unit per whole share a
        // deposit's charge rounds to zero for whole shares, and repeated one-unit deposits compounded to more than 99%
        // of the supply for nothing, a claim on every later recovery of value. Such a fund takes no new money.
        if (price < ShareMath.PRICE_SCALE) revert SharePriceBelowOneUnit(price);
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

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcCharged);
        // DEC-106: the flow fee goes to the protocol in the same transaction; security review S-12: if that transfer
        // fails it is owed, never a reason to refuse the deposit.
        CoreVaultLogic.payFee(_s, usdc, protocolRecipient, fee);
        ShareToken(shareToken).mint(msg.sender, shares);
        // DEC-146: the peak moves on every mint to the manager address.
        if (msg.sender == manager) _recordManagerPeak();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Lifecycle (DEC-061, DEC-113, DEC-121, DEC-127, DEC-146, DEC-147, DEC-149)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultLifecycle
    /// @dev Called by `FundFactory.createFund` in the creation transaction, so no fund exists without the seed. The
    ///      price is the initial Share Price by definition (DEC-061): nothing else is in the fund yet. D-34: the seed
    ///      is a deposit and pays the flow fee (DEC-113). The remainder below one share never leaves the caller
    ///      (DEC-035).
    /// @dev No Operating Cash top-up here (DEC-096 tops up before pricing an entrant; the seed has a fixed price), so
    ///      the first value-moving operation tops hub Operating Cash up out of the seed's Idle and the Share Price
    ///      falls by the top-up. A seed whose Idle is at or below the top-up leaves a Share Price of 0 at that point:
    ///      deposits revert `SharePriceBelowOneUnit` (their top-up reverts with them) until the manager lowers the
    ///      parameters (`setOperatingCashParameters`). Not refused here: the manager can move Free Idle into Operating
    ///      Cash at any time anyway (security review S-5, SEC-OQ-2). CoreVaultSeed.t.sol pins both cases.
    function seed(uint256 usdcAmount) external nonReentrant returns (uint256 shares) {
        if (msg.sender != factory) revert NotFactory(msg.sender);
        // The peak is non-zero once seeded; a supply-0 fund is either new or closed, and a closed one never re-opens.
        if (_s.managerPeakShares != 0 || _totalShares() != 0) revert AlreadySeeded();
        if (usdcAmount < _minFirstDeposit) revert BelowMinFirstDeposit(usdcAmount, _minFirstDeposit);
        uint256 price = ShareMath.INITIAL_SHARE_PRICE;
        (uint256 minted, uint256 usdcForShares, uint256 fee) = ShareMath.previewDeposit(usdcAmount, flowFeeBps, price);
        if (minted == 0) revert DepositBelowOneShare(usdcAmount - fee, price);
        shares = minted;

        // DEC-014: no income checkpoint is needed: no share ever existed, so every income index is still 0 (income met
        // at supply 0 is kept ownerless and never moves an index, IncomeAccumulator.distribute).
        _s.idle += usdcForShares;
        // DEC-146: the manager's first balance is the first peak.
        _s.managerPeakShares = shares;
        emit FundSeeded(manager, usdcForShares, fee, shares);

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcForShares + fee);
        CoreVaultLogic.payFee(_s, usdc, protocolRecipient, fee);
        ShareToken(shareToken).mint(manager, shares);
    }

    /// @inheritdoc ICoreVaultLifecycle
    /// @dev DEC-147 items 2-3: from here the manager unwinds with the existing verbs; deposits, new Payout Requests and
    ///      claims are refused (D-26) and Income Withdrawal stays open (DEC-117 item 4). DEC-149 reading: irreversible.
    function closeFund() external onlyManager nonReentrant {
        _requireOpen();
        _s.fundState = FundState.Closing;
        _s.closingStartedAt = uint64(block.timestamp);
        emit FundClosing(uint64(block.timestamp));
    }

    /// @inheritdoc ICoreVaultLifecycle
    function fundState() external view returns (FundState) {
        return _s.fundState;
    }

    /// @inheritdoc ICoreVaultLifecycle
    function closingStartedAt() external view returns (uint64) {
        return _s.closingStartedAt;
    }

    /// @inheritdoc ICoreVaultLifecycle
    function managerPeakShares() external view returns (uint256) {
        return _s.managerPeakShares;
    }

    function _requireOpen() private view {
        FundState state = _s.fundState;
        if (state != FundState.Open) revert FundNotOpen(state);
    }

    function _recordManagerPeak() private {
        uint256 balance = _sharesOf(manager);
        if (balance > _s.managerPeakShares) _s.managerPeakShares = balance;
    }

    /// @notice DEC-146, DEC-147 item 1, D-27: a manager request that would leave the manager's balance below half of
    ///         the peak reverts, telling the manager to close the fund. Sized at the request's Share Price, rounding
    ///         the shares the request would burn up and the base up, so the check never lets the balance fall below
    ///         half.
    /// @dev Example (DEC-146): peak 200,000 shares at 1.00; a request of 120,000 leaves 80,000 and reverts, 90,000
    ///      leaves 110,000 and passes.
    function _requireManagerBase(uint256 balance, uint256 usdcAmount, uint256 price) private view {
        uint256 peak = _s.managerPeakShares;
        uint256 burned =
            Math.mulDiv(usdcAmount, ShareMath.PRICE_SCALE, price, Math.Rounding.Ceil) * ShareMath.WHOLE_SHARE;
        uint256 balanceAfter = balance > burned ? balance - burned : 0;
        if (balanceAfter < peak - peak / 2) revert ManagerMustCloseFund(peak, balanceAfter);
    }

    /// @notice DEC-146, DEC-147 consequence, D-27: the whole shares the manager may burn at a claim, those above
    ///         `ceil(peak / 2)`. The request was checked at its own Share Price; a price that fell before the claim
    ///         would otherwise burn more shares for the same USDC and take the manager below the base, or a sole
    ///         holder to zero shares while the fund is Open.
    function _managerBurnable(uint256 balance) private view returns (uint256) {
        uint256 peak = _s.managerPeakShares;
        uint256 base = peak - peak / 2;
        return balance > base ? (balance - base) / ShareMath.WHOLE_SHARE * ShareMath.WHOLE_SHARE : 0;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout Request (DEC-020, DEC-024, DEC-060, DEC-072, DEC-077, DEC-095)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev Priced like a claim (payout liveness, DEC-021, DEC-056: a failing valuation dependency falls back to the
    ///      last known value, never a revert on age, OQ-10), so the reserve bound and the one-share floor use the Share
    ///      Price the holder would be paid at if the claim ran now.
    /// @dev DEC-147: refused unless the fund is Open; the manager's request may not cross the base (DEC-146).
    function requestPayout(uint256 usdcAmount, PayoutMode mode) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireOpen();
        PayoutRequest storage req = _s.requests[msg.sender];
        // DEC-024, DEC-046: one open request per address, never cancellable.
        if (req.open) revert PayoutRequestAlreadyOpen(msg.sender);
        uint256 balance = _sharesOf(msg.sender);
        if (balance == 0) revert NoShares(msg.sender);
        (uint256 assets,) = CoreVaultLogic.recordValuation(_s, _wiring(), false);
        uint256 price = ShareMath.sharePrice(assets, _totalShares());
        // DEC-035 spirit, DEC-077 (final verification): a request below one share's price could never burn a share.
        if (ShareMath.sharesToBurn(usdcAmount, price) == 0) revert PayoutBelowOneShare(usdcAmount, price);
        if (msg.sender == manager) _requireManagerBase(balance, usdcAmount, price);
        uint256 reserved;
        uint64 termEndsAt = uint64(block.timestamp);
        if (mode == PayoutMode.Standard) {
            // DEC-072, DEC-095: Standard reserves USDC and starts the term (DEC-060). OPEN reading (final verification,
            // docs/OPEN-QUESTIONS.md FV-OQ-1): the reserve is bounded by the requester's share value now (DEC-020: the
            // most a request can pay is the whole balance), so a small holder cannot lock Free Idle (DEC-017).
            reserved = Math.min(Math.min(usdcAmount, ShareMath.usdcFor(balance, price)), freeIdle());
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
    ///      known value is used with an event (CoreVaultLogic.recordValuation). LC-45 / LC-141: the fund bears the
    ///      market cost of the unwind (flagged). LC-45 / LC-47: no Network Costs are charged to the requester
    ///      (flagged). DEC-147, D-26: refused unless the fund is Open; a request opened before closure is paid as a
    ///      closed-fund exit (DEC-150 item 4).
    /// @dev DEC-146, DEC-147, D-27: the manager's burn stops at `ceil(peak / 2)` whatever the Share Price did since the
    ///      request. When that cap binds the request closes like one capped at the balance (DEC-024: it can never be
    ///      cancelled, so leaving it open would block the manager's next request and keep a Standard reserve locked);
    ///      the receipt shows the USDC paid below the amount requested.
    function claimPayout(bytes calldata unwindHints) external nonReentrant returns (PayoutReceipt memory receipt) {
        _requireOpen();
        PayoutRequest storage req = _s.requests[msg.sender];
        if (!req.open) revert NoOpenPayoutRequest(msg.sender);
        if (req.mode == PayoutMode.Standard && block.timestamp < req.termEndsAt) {
            revert PayoutTermNotEnded(req.termEndsAt);
        }
        Claim memory c;
        c.balance = _sharesOf(msg.sender);
        if (c.balance == 0) revert NoShares(msg.sender);
        c.burnable = msg.sender == manager ? _managerBurnable(c.balance) : c.balance;
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
        // DEC-077: an outstanding amount below one share's price (after a Partial Payout, or a Share Price that rose
        // since the request) closes the request with nothing burned; the receipt says so (`closedBelowOneShare`).
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
        // DEC-077, DEC-020: floor(outstanding / price) whole shares, capped at the balance (the manager: at the base).
        c.wanted = ShareMath.usdcFor(_sharesFor(c, req.usdcOutstanding), c.price);
        c.available = freeIdle();
        if (req.mode == PayoutMode.Standard) c.available += req.reserved;
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
    function _unwindForPayout(uint256 target, bytes calldata hints) private returns (uint256 proceeds) {
        uint256 idleBefore = _s.idle;
        CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(true);
        try ISpokeVault(hubSpokeVault).unwindForPayout(target, hints) {
            CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(false);
        } catch {
            CORE_VAULT_UNWINDING_SLOT.asBoolean().tstore(false);
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
        // DEC-075: Payout Fee on Instant only. DEC-144 items 4-5 (corrects DEC-102 items 2-4): it stays in Idle, in
        // USDC.
        if (req.mode == PayoutMode.Instant) r.payoutFee = ShareMath.bpsOf(r.usdcGross, payoutFeeBps);
        // DEC-106, DEC-113: flow fee on the amount paid out, deducted from what the shareholder receives.
        r.flowFee = ShareMath.flowFee(r.usdcGross, flowFeeBps);
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

        // Effects. DEC-014: checkpoint with the balance before the burn.
        _s.income.checkpoint(msg.sender, c.balance);
        // DEC-144: the Payout Fee never leaves Idle, so it raises the Share Price of those who stay (R-144-A).
        _s.idle -= r.usdcGross - r.payoutFee;
        uint256 reserved = req.reserved;
        uint256 used = Math.min(reserved, r.usdcGross);
        reserved -= used;
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
        // Security review S-12: a failed flow-fee transfer is owed to the protocol, never a reason to refuse the claim.
        CoreVaultLogic.payFee(_s, usdc, protocolRecipient, r.flowFee);
        if (r.usdcPaid != 0) IERC20(usdc).safeTransfer(msg.sender, r.usdcPaid);
        if (c.shares == c.balance) _payAllIncome(msg.sender);
    }
}
