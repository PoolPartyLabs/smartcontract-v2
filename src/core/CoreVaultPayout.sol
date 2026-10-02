// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {CoreVaultTransit} from "./CoreVaultTransit.sol";
import {CoreVaultPayoutLogic} from "./CoreVaultPayoutLogic.sol";
import {STANDARD_PAYOUT_TERM} from "./CoreVaultTypes.sol";

/// @title CoreVaultPayout
/// @notice Payout Requests and Payouts of the Core Vault. See ICoreVault.
/// @dev The entries keep the reentrancy guard, the open-fund check (DEC-147, D-26), the request checks and the
///      Operating Cash top-up, in their original order; the bodies run in the linked library `CoreVaultPayoutLogic`
///      (DEC-131 pattern, D-43).
abstract contract CoreVaultPayout is CoreVaultTransit {
    /// @notice DEC-081: the unwind targets the shortfall plus 2%. Applied by the linked `CoreVaultPayoutLogic`, whose
    ///         constant this is.
    uint256 public constant UNWIND_MARGIN_BPS = CoreVaultPayoutLogic.UNWIND_MARGIN_BPS;

    // ---------------------------------------------------------------------------------------------------------------
    // Payout Request (DEC-020, DEC-024, DEC-060, DEC-072, DEC-077, DEC-095)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultPayouts
    /// @dev Priced like a claim (payout liveness, DEC-021, DEC-056: a failing valuation dependency falls back to the
    ///      last known value, never a revert on age, OQ-10), so the reserve bound and the one-share floor use the Share
    ///      Price the holder would be paid at if the claim ran now.
    /// @dev DEC-147: refused unless the fund is Open; the manager's request may not cross the base (DEC-146).
    function requestPayout(uint256 usdcAmount, PayoutMode mode) external nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireOpen();
        CoreVaultPayoutLogic.requestPayout(_s, _wiring(), usdcAmount, mode);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout (DEC-020, DEC-045, DEC-047, DEC-065, DEC-067, DEC-068, DEC-069, DEC-077, DEC-081, DEC-095, DEC-097,
    // DEC-102, DEC-105, DEC-106)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultPayouts
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
        PayoutRequest storage req = _s.payouts.requests[msg.sender];
        if (!req.open) revert NoOpenPayoutRequest(msg.sender);
        if (req.mode == PayoutMode.Standard && block.timestamp < req.termEndsAt) {
            revert PayoutTermNotEnded(req.termEndsAt);
        }
        uint256 balance = _sharesOf(msg.sender);
        if (balance == 0) revert NoShares(msg.sender);
        _topUpOperatingCash();
        receipt = CoreVaultPayoutLogic.claimPayout(_s, _wiring(), balance, unwindHints);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultPayouts
    function payoutRequest(address shareholder) external view returns (PayoutRequest memory) {
        return _s.payouts.requests[shareholder];
    }

    /// @inheritdoc ICoreVaultPayouts
    function standardPayoutTerm() external pure returns (uint32) {
        return STANDARD_PAYOUT_TERM;
    }
}
