// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {ICoreVaultLifecycle} from "../interfaces/ICoreVaultLifecycle.sol";
import {Mandate} from "../mandate/Mandate.sol";
import {ShareMath} from "../libraries/ShareMath.sol";
import {ShareToken} from "./ShareToken.sol";
import {CoreVaultBase, CoreVaultConfig} from "./CoreVaultBase.sol";
import {CoreVaultWiring, STANDARD_PAYOUT_TERM} from "./CoreVaultTypes.sol";
import {CoreVaultClosureLogic} from "./CoreVaultClosureLogic.sol";
import {CoreVaultPayout} from "./CoreVaultPayout.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";
import {CoreVaultIncomeLogic} from "./CoreVaultIncomeLogic.sol";

/// @title CoreVault
/// @notice Hub Chain contract of a fund: custody of Idle USDC, the Share ledger, the manager's seed and the fund
///         states, Payout Requests and Payouts, the Attributed Income bucket and Income Withdrawal, sends to spokes and
///         the transit state machine.
/// @dev See ICoreVault and ICoreVaultLifecycle for the rules of every verb. DEC-022, DEC-058: no proxy, no upgrade
///      path, no selfdestruct. The value bases live in the linked external library `CoreVaultLogic`, report
///      application, sends and transit outcomes in `CoreVaultTransitLogic`, the income split in `CoreVaultIncomeLogic`
///      and the payout path in `CoreVaultPayoutLogic` (DEC-131 pattern, D-43), each called by DELEGATECALL over this
///      vault's storage: their addresses are part of the creation code and trust surface; the operator deploys them
///      once per chain and the factory pins the code linked to them. They are the only DELEGATECALLs the vault makes;
///      the Core Vault never calls an adapter. DEC-054: never calls an adapter; reads the hub Spoke Vault and the
///      ValueReportReceiver. Every value-moving external entry is `nonReentrant` (the two hub Spoke Vault callbacks are
///      guarded as described in the base).
contract CoreVault is CoreVaultPayout {
    using SafeERC20 for IERC20;

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
        _requireSharePricing();
        _topUpOperatingCash();
        return CoreVaultClosureLogic.deposit(_s, _wiring(), usdcAmount, minShares);
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
        return CoreVaultClosureLogic.seed(_s, _wiring(), usdcAmount, _minFirstDeposit);
    }

    /// @inheritdoc ICoreVaultLifecycle
    /// @dev DEC-147 items 2-3: from here the manager unwinds with the existing verbs; deposits, new Payout Requests and
    ///      claims are refused (D-26) and Income Withdrawal stays open (DEC-117 item 4). DEC-149 reading: irreversible.
    ///      DEC-114 (D-33): the management fee accrues up to this call and no further; it is booked here (a payout-mode
    ///      valuation, which never reverts on a failing dependency) and paid at the end of the closure (WP-13).
    function closeFund() external onlyManager nonReentrant {
        CoreVaultClosureLogic.closeFund(_s, _wiring());
    }

    /// @inheritdoc ICoreVaultLifecycle
    function fundState() external view returns (FundState) {
        return _s.fundState;
    }

    /// @inheritdoc ICoreVaultLifecycle
    function closingStartedAt() external view returns (uint64) {
        return _s.closingStartedAt;
    }

    function closingDeadline() external view returns (uint256) {
        return uint256(_s.closingStartedAt) + STANDARD_PAYOUT_TERM;
    }

    function closureRequestId() external view returns (bytes32) {
        return CoreVaultClosureLogic.requestId(_s, fundId);
    }

    function closedSupply() external view returns (uint256) {
        return _s.closedSupply;
    }

    function closedIdle() external view returns (uint256) {
        return _s.closedIdle;
    }

    function unwindAllAfterDeadline() external payable nonReentrant {
        CoreVaultClosureLogic.unwindAll(_s, _wiring(), msg.value);
    }

    function finalizeClosure() external nonReentrant {
        CoreVaultClosureLogic.finalize(_s, _wiring());
    }

    function exitClosedFund(address holder) external nonReentrant returns (uint256 paid) {
        _requireSharePricing();
        return CoreVaultClosureLogic.exit(_s, _wiring(), holder);
    }

    /// @inheritdoc ICoreVaultLifecycle
    function managerPeakShares() external view returns (uint256) {
        return _s.managerPeakShares;
    }
}
