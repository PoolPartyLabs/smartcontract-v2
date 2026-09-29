// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {TransferKind, BridgeQuote} from "../interfaces/FundTypes.sol";
import {TransitMessage} from "../libraries/TransitMessage.sol";
import {CoreVaultIncome} from "./CoreVaultIncome.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";

/// @title CoreVaultTransit
/// @notice Sends to spokes, the DEC-066 transit state machine, spoke-to-hub arrivals, report application, hub
///         allocation and the garbage collector of the Core Vault. See ICoreVault.
abstract contract CoreVaultTransit is CoreVaultIncome {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------------------------
    // Hub allocation (DEC-017, DEC-072)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function allocateToHubSpokeVault(uint256 usdcAmount) external onlyManager nonReentrant {
        if (usdcAmount == 0) revert ZeroAmount();
        _topUpOperatingCash();
        uint256 free = freeIdle();
        if (usdcAmount > free) revert InsufficientFreeIdle(usdcAmount, free);
        _s.idle -= usdcAmount;
        emit AllocatedToHubSpokeVault(usdcAmount);
        IERC20(usdc).safeTransfer(hubSpokeVault, usdcAmount);
        ISpokeVault(hubSpokeVault).receiveFromCoreVault(usdcAmount);
    }

    /// @inheritdoc ICoreVault
    /// @dev DEC-080: credited only when the USDC is already above the ledger. Callable while a payout's automatic
    ///      unwind is in progress (`ISpokeVault.unwindForPayout`).
    function returnToIdle(uint256 usdcAmount) external onlyHubSpokeVaultCallback {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireUnledgered(usdc, usdcAmount);
        _s.idle += usdcAmount;
        emit ReturnedToIdle(usdcAmount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Send to a spoke (DEC-037, DEC-066, DEC-085, DEC-087, DEC-088, DEC-095, QA19)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev Checks, escrow, call building, bookkeeping and the custody-checked call run in CoreVaultLogic.sendToSpoke.
    function sendToSpoke(uint256 spokeIndex, uint256 usdcAmount, uint256 bridgeRank, BridgeQuote calldata quote)
        external
        onlyManager
        nonReentrant
        returns (bytes32 transitId)
    {
        if (usdcAmount == 0) revert ZeroAmount();
        if (spokeIndex >= _s.mandate.spokes.length) revert UnknownSpoke(spokeIndex);
        // DEC-096: Operating Cash top-up before Free Idle is measured.
        _topUpOperatingCash();
        return CoreVaultLogic.sendToSpoke(_s, _wiring(), spokeIndex, usdcAmount, bridgeRank, quote);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Transit outcomes (DEC-066, DEC-090; QB11 / QB10 OPEN)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function attestExpiry(bytes32 transitId) external nonReentrant {
        CoreVaultLogic.attestExpiry(_s, _wiring(), transitId);
    }

    /// @inheritdoc ICoreVault
    /// @dev DEC-066, DEC-090: only an ExpiryAttested transit (Sent -> ExpiryAttested -> RefundRecognized); DEC-063:
    ///      only once its escrow holds the full amount sent (the Across refund), which is what enters Idle; a surplus
    ///      donated to the escrow becomes sweepable excess (DEC-080). Reverts with `NoRefund` before the refund lands.
    function recognizeRefund(bytes32 transitId) external nonReentrant returns (uint256 amount) {
        return CoreVaultLogic.recognizeRefund(_s, _wiring(), transitId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reports (DEC-066, DEC-080, DEC-090, Q60)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev Confirms arrived transits and credits matched spoke-to-hub arrivals, in CoreVaultLogic. Never reverts because
    ///      of an unknown or repeated transit id.
    function onReportAccepted(uint256 spokeIndex) external nonReentrant {
        if (msg.sender != reportReceiver) revert NotReportReceiver(msg.sender);
        CoreVaultLogic.applyReport(_s, _wiring(), spokeIndex);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Spoke-to-hub arrivals (DEC-080, DEC-090, DEC-092, OQ-01)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    /// @dev A Principal arrival goes to Idle; an Income arrival is collected income reaching the Core Vault, split at
    ///      once (ruling 2026-09-29: fee to the Protocol Recipient and the ManagerFeeVault, net to the accumulator);
    ///      both only up to what an accepted report of the origin spoke listed for that id. Before any report lists it
    ///      the amount is held apart in `unmatchedArrivals`, outside every base and never swept, and it is credited on
    ///      the report that lists it. A fabricated id therefore never reaches a base.
    function handleV3AcrossMessage(address tokenSent, uint256 amount, address, bytes memory message)
        external
        override(ICoreVault)
        nonReentrant
    {
        if (msg.sender != acrossSpokePool) revert NotAcrossSpokePool(msg.sender);
        if (tokenSent != usdc) revert UnexpectedToken(tokenSent);
        if (amount == 0) revert ZeroAmount();
        (bytes32 messageFundId, uint256 originChainId, bytes32 transitId, TransferKind kind) =
            TransitMessage.decode(message);
        if (messageFundId != fundId) revert WrongFund(messageFundId);
        CoreVaultLogic.receiveHubBound(_s, _wiring(), originChainId, transitId, kind, amount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Garbage collector (DEC-080, DEC-096, DEC-101)
    // ---------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ICoreVault
    function sweepExcess(address token) external nonReentrant returns (uint256 amount) {
        amount = _unledgered(token);
        if (amount == 0) return 0;
        IERC20(token).safeTransfer(excessRecipient, amount);
        emit ExcessSwept(token, excessRecipient, amount);
    }
}
