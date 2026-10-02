// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVaultPayouts} from "../interfaces/ICoreVaultPayouts.sol";
import {CoreVaultTransit} from "./CoreVaultTransit.sol";
import {CoreVaultPayoutLogic} from "./CoreVaultPayoutLogic.sol";
import {STANDARD_PAYOUT_TERM} from "./CoreVaultTypes.sol";

/// @title CoreVaultPayout
/// @notice Payout Requests and Payouts of the Core Vault. See ICoreVault.
/// @dev The entries keep the reentrancy guard, the open-fund check (DEC-147, D-26) and the Operating Cash top-up; the
///      bodies, the request checks included, run in the linked library `CoreVaultPayoutLogic` (DEC-131 pattern, D-43).
abstract contract CoreVaultPayout is CoreVaultTransit {
    /// @notice DEC-081, DEC-132, DEC-137: the margin of the automatic unwind's fraction, 2%. Applied by the linked
    ///         `CoreVaultPayoutLogic`, whose constant this is.
    uint256 public constant UNWIND_MARGIN_BPS = CoreVaultPayoutLogic.UNWIND_MARGIN_BPS;

    // ---------------------------------------------------------------------------------------------------------------
    // Payout Request (DEC-020, DEC-024, DEC-060, DEC-072, DEC-077, DEC-095, DEC-120 item 1)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultPayouts
    /// @dev DEC-147: refused unless the fund is Open; the manager's request may not cross the base (DEC-146). DEC-096:
    ///      an Instant request is a claim, so Operating Cash is topped up first, as before every claim.
    function requestPayout(uint256 usdcAmount, PayoutMode mode, uint16 maxLossBps)
        external
        payable
        nonReentrant
        returns (PayoutReceipt memory receipt)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireOpen();
        if (mode == PayoutMode.Instant) _topUpOperatingCash();
        receipt = CoreVaultPayoutLogic.requestPayout(_s, _wiring(), usdcAmount, mode, maxLossBps, msg.value);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout (DEC-020, DEC-045, DEC-047, DEC-065, DEC-067, DEC-068, DEC-069, DEC-077, DEC-081, DEC-095, DEC-097,
    // DEC-105, DEC-106, DEC-160)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVaultPayouts
    /// @dev OQ-07, DEC-154: a Standard Payout is claimable only after its term. DEC-147, D-26: refused unless the fund
    ///      is Open; a request opened before closure is paid as a closed-fund exit (DEC-150 item 4). DEC-096: Operating
    ///      Cash is topped up before the claim is priced. The request checks run in the library.
    /// @dev DEC-146, DEC-147, D-27, DEC-183 item 1: the manager's burn stops at `ceil(peak / 2)` whatever the Share
    ///      Price did since the request. When that cap binds the request closes like one capped at the balance
    ///      (DEC-024: it can never be cancelled, so leaving it open would block the manager's next request and keep a
    ///      Standard reserve locked); the receipt says so (`cappedByManagerBase`).
    function claimPayout(uint16 maxLossBps) external payable nonReentrant returns (PayoutReceipt memory receipt) {
        _requireOpen();
        _topUpOperatingCash();
        receipt = CoreVaultPayoutLogic.claimPayout(_s, _wiring(), maxLossBps, msg.value);
    }

    function settlePayout(address holder) external payable nonReentrant returns (PayoutReceipt memory receipt) {
        _requireOpen();
        receipt = CoreVaultPayoutLogic.settlePayout(_s, _wiring(), holder, msg.value);
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
