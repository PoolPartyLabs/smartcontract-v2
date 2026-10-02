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
        uint256 supply = _totalShares();
        if (supply == 0) revert FundNotSeeded();
        // DEC-096: Operating Cash top-up first, so the depositor enters at the post-expense price.
        _topUpOperatingCash();
        // Q57 reading: a mint reverts on a stale spoke report or a stale price. DEC-014: the entrant's checkpoint below
        // gives it no income collected before entry (ruling 2026-09-29: the index moves only at collection).
        CoreVaultWiring memory w = _wiring();
        (uint256 assets, NavConsolidation memory consolidation) = CoreVaultLogic.recordValuation(_s, w, true);
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

        // DEC-014, Q60: the income hook checkpoints with the balance before the mint (WP-07 D2).
        CoreVaultIncomeLogic.beforeBalanceChange(_s, w, msg.sender, _sharesOf(msg.sender));
        _s.idle += usdcForShares;
        emit Deposited(msg.sender, usdcForShares, fee, shares, price, assets, supply, consolidation);

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcCharged);
        // DEC-106: the flow fee goes to the protocol in the same transaction; security review S-12: if that transfer
        // fails it is owed, never a reason to refuse the deposit.
        CoreVaultLogic.payFee(_s, usdc, protocolRecipient, fee);
        ShareToken(shareToken).mint(msg.sender, shares);
        CoreVaultIncomeLogic.afterMint(_s, w, msg.sender, shares);
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

        // DEC-014: the income hooks run around the seed like around every mint (WP-07 D2). The manager's balance before
        // it is 0 (no share exists yet) and every income index is still 0 (income met at supply 0 is kept ownerless and
        // never moves an index, IncomeAccumulator.distribute), so the checkpoint records nothing.
        CoreVaultWiring memory w = _wiring();
        CoreVaultIncomeLogic.beforeBalanceChange(_s, w, manager, 0);
        _s.idle += usdcForShares;
        // DEC-146: the manager's first balance is the first peak.
        _s.managerPeakShares = shares;
        emit FundSeeded(manager, usdcForShares, fee, shares);

        IERC20(usdc).safeTransferFrom(msg.sender, address(this), usdcForShares + fee);
        CoreVaultLogic.payFee(_s, usdc, protocolRecipient, fee);
        ShareToken(shareToken).mint(manager, shares);
        CoreVaultIncomeLogic.afterMint(_s, w, manager, shares);
    }

    /// @inheritdoc ICoreVaultLifecycle
    /// @dev DEC-147 items 2-3: from here the manager unwinds with the existing verbs; deposits, new Payout Requests and
    ///      claims are refused (D-26) and Income Withdrawal stays open (DEC-117 item 4). DEC-149 reading: irreversible.
    ///      DEC-114 (D-33): the management fee accrues up to this call and no further; it is booked here (a payout-mode
    ///      valuation, which never reverts on a failing dependency) and paid at the end of the closure (WP-13).
    function closeFund() external onlyManager nonReentrant {
        _requireOpen();
        if (_s.managementFeeBps != 0) CoreVaultLogic.recordValuation(_s, _wiring(), false);
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
        return CoreVaultClosureLogic.exit(_s, _wiring(), holder);
    }

    /// @inheritdoc ICoreVaultLifecycle
    function managerPeakShares() external view returns (uint256) {
        return _s.managerPeakShares;
    }

    function _recordManagerPeak() private {
        uint256 balance = _sharesOf(manager);
        if (balance > _s.managerPeakShares) _s.managerPeakShares = balance;
    }
}
