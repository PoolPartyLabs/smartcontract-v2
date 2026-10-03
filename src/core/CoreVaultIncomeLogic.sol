// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {TokenConfig} from "../mandate/Mandate.sol";
import {DollarIncomeIndex} from "../libraries/DollarIncomeIndex.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {CoreVaultState, CoreVaultWiring} from "./CoreVaultTypes.sol";
import {CoreVaultIncomeTypes} from "./CoreVaultIncomeTypes.sol";
import {CoreVaultIncomeCollectionLogic} from "./CoreVaultIncomeCollectionLogic.sol";

/// @title CoreVaultIncomeLogic
/// @notice Attributed Income of the Core Vault in the Hub dollar index (DEC-161), holders' side: the income sources'
///         registration, the hooks the other paths call at fixed points (valuation, share balance changes, report
///         delivery, Income arrival), the holders' settlement around every balance change, Income Withdrawal in USDC and
///         the views, as an external library that runs in the Core Vault's context (DELEGATECALL into the fund's own
///         linked library, never into an adapter).
/// @dev Mechanism: checklist doc 10 section 2 (`DollarIncomeIndex`), one index per source (the Hub positions, and each
///      spoke; `CoreVaultIncomeTypes.Source`). See ICoreVaultIncome for the rules. Recognition, the collections and the
///      conversion live in the linked `CoreVaultIncomeCollectionLogic` (split by concern under the 24,576-byte limit,
///      DEC-131 pattern, D-43), which the hooks forward to.
/// @dev Linking: it calls `CoreVaultIncomeCollectionLogic` through that library's linked address, so its creation code
///      links it and it is deployed after it. The Core Vault, `CoreVaultLogic`, `CoreVaultTransitLogic` and
///      `CoreVaultPayoutLogic` call this library through its linked address, which is part of the Core Vault's creation
///      code and trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058). It must never call a public
///      function of those four: they link this one, so a link back would make their CREATE2 addresses depend on each
///      other.
/// @dev WP-07 D2: the hooks keep their signatures; their bodies are the income work's (WP-10).
/// @dev Events are emitted with the Core Vault as their address; they and the errors are declared in ICoreVaultIncome,
///      except the `DollarIncomeIndex` events, which the index emits itself (checklist doc 15, gap 5: read them with this
///      library's ABI).
library CoreVaultIncomeLogic {
    using SafeERC20 for IERC20;
    using DollarIncomeIndex for DollarIncomeIndex.State;

    // ---------------------------------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Registers the income sources from the stored Mandate: the Hub (source 0) with USDC first and the Hub's
    ///         other Mandate tokens, then one source per spoke with that spoke chain's Mandate tokens (DEC-123,
    ///         DEC-136: the closed token list; at most `MandateLib.MAX_TOKENS` in all).
    /// @dev Called once by the Core Vault constructor, after it stored the Mandate.
    function initialize(CoreVaultState storage s) public {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 count = 1 + s.mandate.spokes.length;
        b.sourceCount = count;
        TokenConfig[] storage tokens = s.mandate.tokens;
        address usdc = s.mandate.usdc;
        for (uint256 k; k < count; ++k) {
            DollarIncomeIndex.State storage index = b.sources[k].index;
            // casting to 'uint8' is safe because a Mandate lists at most 16 tokens, so at most 15 spokes
            // forge-lint: disable-next-line(unsafe-typecast)
            index.source = uint8(k);
            uint256 chainId =
                k == CoreVaultIncomeTypes.HUB_SOURCE ? s.mandate.hubChainId : s.mandate.spokes[k - 1].chainId;
            if (k == CoreVaultIncomeTypes.HUB_SOURCE) index.registerToken(usdc);
            for (uint256 i; i < tokens.length; ++i) {
                if (tokens[i].chainId != chainId) continue;
                if (k == CoreVaultIncomeTypes.HUB_SOURCE && tokens[i].token == usdc) continue;
                index.registerToken(tokens[i].token);
            }
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Shareholder verbs (DEC-025, DEC-073, DEC-117 item 4, DEC-122, DEC-124; the request is in
    // CoreVaultIncomeCollectionLogic)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVaultIncome.settleIncomeWithdrawal after the guard.
    function settleIncomeWithdrawal(CoreVaultState storage s, CoreVaultWiring memory w, address holder)
        public
        returns (uint256 amount)
    {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        CoreVaultIncomeTypes.Request memory r = b.requests[holder];
        if (!r.open) revert ICoreVaultIncome.NoIncomeWithdrawalRequest(holder);
        if ((r.round == b.round && b.pendingSpokes != 0) || b.openResults != 0) {
            revert ICoreVaultIncome.IncomeCollectionPending(r.round);
        }
        if (!_settle(s, holder, IERC20(w.shareToken).balanceOf(holder))) return 0;
        delete b.requests[holder];
        return _pay(s, w, holder);
    }

    /// @notice ICoreVaultIncome.withdrawIncome for `holder`, after the guard: settles and pays every settled dollar.
    function withdrawIncome(CoreVaultState storage s, CoreVaultWiring memory w, address holder)
        public
        returns (uint256 amount)
    {
        if (!_settle(s, holder, IERC20(w.shareToken).balanceOf(holder))) return 0;
        return _pay(s, w, holder);
    }

    /// @notice DEC-145, DEC-161: permissionless checkpointing without a collection request or income transfer.
    function settleHolderIncome(CoreVaultState storage s, CoreVaultWiring memory w, address holder)
        public
        returns (bool)
    {
        return _settle(s, holder, IERC20(w.shareToken).balanceOf(holder));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Valuation hook (WP-07 D2; DEC-117, DEC-138)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called at the end of every recorded valuation (`CoreVaultLogic.recordValuation`: deposits, Payout
    ///         Requests, claims, management fee bookings) with the hub Spoke Vault's report that valuation read:
    ///         recognizes the Hub income since the last recognition (DEC-117 item 1, DEC-138).
    /// @dev Inside the valuation, before the operation settles any holder, at the supply before the mint or burn: an
    ///      entrant gets none of it and a leaver keeps it (DEC-014). `hubRead` false (a payout could not read the hub
    ///      report, DEC-021, DEC-056): the last counters stay and nothing is recognized now; the next read recognizes
    ///      the whole advance. Never reverts.
    function onValuation(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        ReportCodec.Report memory hubReport,
        bool hubRead,
        bool
    ) public {
        if (hubRead) {
            CoreVaultIncomeCollectionLogic.recognize(s, w, CoreVaultIncomeTypes.HUB_SOURCE, hubReport.cumulativeIncome);
        } else {
            emit ICoreVaultIncome.HubIncomeCollectionFailed();
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Share balance hooks (WP-07 D2; DEC-014, DEC-045, DEC-047)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called before every mint (deposit, seed) and every burn (payout) of `holder`'s shares, with the balance
    ///         before the change: settles the holder in every source (doc 10 section 2, "apuração do investidor").
    /// @dev DEC-145: all sources share one token-operation budget. An incomplete balance-change settlement reverts;
    ///      anyone can call `settleHolderIncome` to persist progress before retrying the balance change.
    function beforeBalanceChange(
        CoreVaultState storage s,
        CoreVaultWiring memory,
        address holder,
        uint256 balanceBefore
    ) public {
        if (!_settle(s, holder, balanceBefore)) revert DollarIncomeIndex.HolderNotSettled(holder);
    }

    /// @notice Called after every mint (deposit, seed): Hub shares exclude already recognized income; spoke shares
    ///         enter one waiting lot until an interval starts at or after their entry (DEC-014, DEC-145).
    function afterMint(CoreVaultState storage s, CoreVaultWiring memory, address holder, uint256 minted) public {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 count = b.sourceCount;
        for (uint256 k; k < count; ++k) {
            if (k == CoreVaultIncomeTypes.HUB_SOURCE) b.sources[k].index.onMint(holder, minted);
            else b.sources[k].index.wait(holder, minted, block.timestamp);
        }
    }

    /// @notice Called after every burn (payout) that burned shares: the `burned` shares keep what they earned in the
    ///         open intervals (DEC-014, DEC-045); a full burn pays every settled dollar now (DEC-045, DEC-047).
    /// @dev What the burned shares earned and no collection converted yet stays the holder's and is paid in dollars once
    ///      a collection converts it (Income Withdrawal, even at a zero balance): the dollar index pays only converted
    ///      income (DEC-124, DEC-161; DEC-045's "a detalhar" on income still in the positions).
    function afterBurn(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        address holder,
        uint256 burned,
        uint256 balanceAfter
    ) public {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 count = b.sourceCount;
        for (uint256 k; k < count; ++k) {
            DollarIncomeIndex.State storage index = b.sources[k].index;
            uint256 activeBurn = k == CoreVaultIncomeTypes.HUB_SOURCE ? burned : index.burnWaiting(holder, burned);
            index.onBurn(holder, activeBurn);
        }
        if (balanceAfter == 0) _pay(s, w, holder);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Cross-chain hooks (WP-07 D2; DEC-122, DEC-124, DEC-161)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called after the Core Vault applied a newly accepted report of spoke `spokeIndex`: recognizes the
    ///         spoke's income from the report's counters, then reads its collection results
    ///         (`CoreVaultIncomeCollectionLogic.readReport`; DEC-122 item 5, DEC-138, DEC-161).
    /// @dev Runs inside the report delivery: never reverts on income (Q60 fitness function) and stays bounded in gas.
    function onReportAccepted(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        ReportCodec.Report memory r
    ) public {
        s.incomeBook.sources[spokeIndex + 1].index.activate(r.timestamp);
        CoreVaultIncomeCollectionLogic.readReport(s, w, spokeIndex, r.cumulativeIncome, r.collectionResults);
    }

    /// @notice Called when an Income transfer of spoke `spokeIndex` reaches the Core Vault and is credited
    ///         (`CoreVaultTransitLogic`: up to what an accepted report of that spoke listed for `transitId`): held for the
    ///         collection result it carries (`CoreVaultIncomeCollectionLogic.creditIncome`; DEC-161, DEC-166).
    /// @dev It runs inside a report delivery or an Across fill (`handleV3AcrossMessage`), so it never reverts.
    function onIncomeArrival(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256 spokeIndex,
        address,
        uint256 amount,
        bytes32 transitId
    ) public {
        CoreVaultIncomeCollectionLogic.creditIncome(s, w, spokeIndex, amount, transitId);
    }

    /// @notice Whether the fund's final income collection is done, so a closure may finish (DEC-147, DEC-149, DEC-163):
    ///         no collection round is waiting for a spoke, no spoke result waits for its dollars, and no income or fee
    ///         recognized in any source is left unconverted.
    function finalCollectionDone(CoreVaultState storage s, CoreVaultWiring memory) public view returns (bool) {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        if (b.pendingSpokes != 0 || b.openResults != 0) return false;
        uint256 count = b.sourceCount;
        for (uint256 k; k < count; ++k) {
            CoreVaultIncomeTypes.Source storage src = b.sources[k];
            address[] storage tokens = src.index.tokens;
            for (uint256 i; i < tokens.length; ++i) {
                if (src.index.token[tokens[i]].recognized != 0 || src.feeUnits[tokens[i]] != 0) return false;
            }
        }
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice ICoreVaultIncome.incomeOwed.
    function incomeOwed(CoreVaultState storage s, CoreVaultWiring memory w, address holder)
        public
        view
        returns (uint256 dollars)
    {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 shares = IERC20(w.shareToken).balanceOf(holder);
        uint256 count = b.sourceCount;
        for (uint256 k; k < count; ++k) {
            dollars += b.sources[k].index.owedDollars(holder, shares);
        }
    }

    /// @notice ICoreVaultIncome.unconvertedIncome.
    function unconvertedIncome(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        address holder,
        uint256 source,
        address token
    ) public view returns (uint256) {
        return _source(s, source).index.tokenOwed(holder, IERC20(w.shareToken).balanceOf(holder), token);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Holders
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Settles `holder` at `shares` in every source within its step budget.
    function _settle(CoreVaultState storage s, address holder, uint256 shares) private returns (bool complete) {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 count = b.sourceCount;
        complete = true;
        DollarIncomeIndex.Work memory work = DollarIncomeIndex.Work(DollarIncomeIndex.MAX_SETTLE_STEPS);
        for (uint256 k; k < count; ++k) {
            DollarIncomeIndex.State storage index = b.sources[k].index;
            if (!index.settle(holder, shares, work)) complete = false;
        }
    }

    /// @dev Pays `holder` every settled dollar of every source in USDC (DEC-124). A transfer that fails is owed to the
    ///      holder and paid by `claimOwedFees` (independent review, plan CF-2: an exit is never blocked by its income;
    ///      checklist doc 15, gap 16: `IncomeTransferOwed`, not `IncomeWithdrawn`).
    function _pay(CoreVaultState storage s, CoreVaultWiring memory w, address holder) private returns (uint256 amount) {
        CoreVaultIncomeTypes.Book storage b = s.incomeBook;
        uint256 count = b.sourceCount;
        for (uint256 k; k < count; ++k) {
            amount += b.sources[k].index.take(holder, type(uint256).max);
        }
        if (amount == 0) return 0;
        b.heldDollars -= amount;
        address usdc = w.usdc;
        if (IERC20(usdc).trySafeTransfer(holder, amount)) {
            emit ICoreVaultIncome.IncomeWithdrawn(holder, usdc, amount);
        } else {
            s.owedFees[usdc][holder] += amount;
            s.owedFeesTotal[usdc] += amount;
            emit ICoreVaultIncome.IncomeTransferOwed(holder, usdc, amount);
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _source(CoreVaultState storage s, uint256 source)
        private
        view
        returns (CoreVaultIncomeTypes.Source storage)
    {
        if (source >= s.incomeBook.sourceCount) revert ICoreVaultIncome.UnknownIncomeSource(source);
        return s.incomeBook.sources[source];
    }
}
