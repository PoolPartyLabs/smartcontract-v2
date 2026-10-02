// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {IManagerRegistry} from "../interfaces/IManagerRegistry.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {ReportCodec} from "../libraries/ReportCodec.sol";
import {CoreVaultState, CoreVaultWiring} from "./CoreVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";

/// @title CoreVaultIncomeLogic
/// @notice Collected income of the Core Vault: the fee split at collection and the advance of the shareholders'
///         accumulator, and the income hooks the other paths call at fixed points (valuation, share balance changes),
///         as an external library that runs in the Core Vault's context (DELEGATECALL into the fund's own linked
///         library, never into an adapter).
/// @dev DEC-131 pattern (alternative C) applied to the Core Vault (D-43): moved out of `CoreVaultLogic` unchanged so
///      each linked library keeps room under the 24,576-byte limit. It calls no other linked library (the fee transfer
///      `CoreVaultLogic.payFee` is internal, so it is compiled in); the Core Vault, `CoreVaultLogic`,
///      `CoreVaultTransitLogic` and `CoreVaultPayoutLogic` call it through its linked address, which is part of the
///      Core Vault's creation code and trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058). It must
///      never call a public function of those libraries: they link this one, so a link back would make their CREATE2
///      addresses depend on each other.
/// @dev WP-07 D2: the hooks keep today's behaviour (a no-op where nothing happened before); the income work (DEC-117,
///      DEC-122, DEC-145, DEC-161) changes their bodies here without editing the callers.
/// @dev Events are emitted with the Core Vault as their address; they and the errors are declared in ICoreVaultIncome.
library CoreVaultIncomeLogic {
    using IncomeAccumulator for IncomeAccumulator.State;

    /// @dev DEC-106: default protocol slice when the registry cannot be read.
    uint16 internal constant DEFAULT_PROTOCOL_SLICE_BPS = 5000;

    uint256 private constant BPS = 10_000;

    // ---------------------------------------------------------------------------------------------------------------
    // Collected income (ruling 2026-09-29; DEC-092, DEC-106, DEC-107, DEC-109, DEC-110)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Splits income that reached the Core Vault and advances the index (ruling 2026-09-29: fee split and
    ///         attribution at collection).
    /// @dev DEC-107: performance fee = `amount * performanceFeeBps`, on income only, no high-water mark. DEC-106,
    ///      DEC-110: its protocol slice is read from the ManagerRegistry at this charge. DEC-109: both are paid in the
    ///      collected token at once, the slice to the Protocol Recipient and the rest of the fee to the ManagerFeeVault,
    ///      so no fee ever waits in the Core Vault. The net enters the shareholders' accumulator (DEC-014, Q60; with no
    ///      shares outstanding it is kept ownerless, LC-32) and the collected balance (LC-100). The caller checked the
    ///      token is an income token and that `amount` is held above the ledger (DEC-080). Rounding: the fee rounds
    ///      down (in the holders' favour), the slice rounds down (in the manager's favour).
    function collectIncome(CoreVaultState storage s, CoreVaultWiring memory w, address token, uint256 amount) public {
        _collectIncome(s, w, token, amount);
    }

    function _collectIncome(CoreVaultState storage s, CoreVaultWiring memory w, address token, uint256 amount) private {
        uint16 sliceBps = protocolSliceBps(w);
        uint256 managerFee = amount * s.performanceFeeBps / BPS;
        uint256 slice = managerFee * sliceBps / BPS;
        managerFee -= slice;
        uint256 net = amount - managerFee - slice;
        s.incomeBook.collectedIncome[token] += net;
        s.incomeBook.index.distribute(token, net, IERC20(w.shareToken).totalSupply());
        emit ICoreVaultIncome.CollectedIncomeReceived(token, amount, managerFee, slice, sliceBps);
        CoreVaultLogic.payFee(s, token, w.protocolRecipient, slice);
        CoreVaultLogic.payFee(s, token, w.managerFeeVault, managerFee);
    }

    /// @notice DEC-106, DEC-110: the registry is read at every charge. A failed read or a value above 100% never blocks
    ///         recognition (DEC-107 reading 3): the DEC-106 default of 50% applies; values are capped at 100%.
    function protocolSliceBps(CoreVaultWiring memory w) public view returns (uint16 bps) {
        try IManagerRegistry(w.managerRegistry).protocolSliceBps(w.manager) returns (uint16 value) {
            // forge-lint: disable-next-line(unsafe-typecast)
            bps = value > BPS ? uint16(BPS) : value;
        } catch {
            bps = DEFAULT_PROTOCOL_SLICE_BPS;
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Cross-chain hooks (WP-07 D2; DEC-122, DEC-124, DEC-161)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called when an Income transfer of spoke `spokeIndex` reaches the Core Vault and is credited
    ///         (`CoreVaultTransitLogic`: up to what an accepted report of that spoke listed for `transitId`).
    /// @dev Ruling 2026-09-29: the collected income is split at once (`collectIncome`). The income work (DEC-161: the
    ///      Hub dollar index with each collection's rates) changes this body. It runs inside a report delivery or an
    ///      Across fill (`handleV3AcrossMessage`), so it must not revert: a revert would refuse the report or fail the
    ///      relayer's fill.
    function onIncomeArrival(
        CoreVaultState storage s,
        CoreVaultWiring memory w,
        uint256,
        address token,
        uint256 amount,
        bytes32
    ) public {
        _collectIncome(s, w, token, amount);
    }

    /// @notice Called after the Core Vault applied a newly accepted report of spoke `spokeIndex`. Nothing to do yet.
    /// @dev The income work reads the report's `collectionResults` here (DEC-122 item 5, DEC-161). It runs inside the
    ///      report delivery, so it must not revert (Q60 fitness function: report admission never reverts because of
    ///      income) and must stay bounded in gas.
    function onReportAccepted(CoreVaultState storage, CoreVaultWiring memory, uint256, ReportCodec.Report memory)
        public
        pure {}

    /// @notice Whether the fund's final income collection is done, so a closure may finish (DEC-147, DEC-149). Always
    ///         true until the collection orders exist (DEC-122, DEC-161); the closure work reads it.
    function finalCollectionDone(CoreVaultState storage, CoreVaultWiring memory) public pure returns (bool) {
        return true;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Valuation hook (WP-07 D2; DEC-117)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called at the end of every recorded valuation (`CoreVaultLogic.recordValuation`: deposits, Payout
    ///         Requests, claims, management fee bookings) with the hub Spoke Vault's report that valuation read.
    ///         Nothing to do yet.
    /// @dev DEC-117: the income work recognizes hub income here, inside the valuation and so before the operation
    ///      checkpoints any holder. `hubRead` is false when a payout's valuation could not read the hub report (payout
    ///      liveness, DEC-021, DEC-056), and `hubReport` is then empty; `mint` tells a mint's valuation (every
    ///      dependency answered, fresh) from a payout's. In a payout's valuation it must never revert: an exit is never
    ///      blocked (DEC-021, DEC-056).
    function onValuation(CoreVaultState storage, CoreVaultWiring memory, ReportCodec.Report memory, bool, bool)
        public
        pure {}

    // ---------------------------------------------------------------------------------------------------------------
    // Share balance hooks (WP-07 D2; DEC-014, DEC-045, DEC-047, Q60)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Called before every mint (deposit, seed) and every burn (payout) of `holder`'s shares, with the balance
    ///         before the change.
    /// @dev DEC-014, Q60: checkpoints the holder's Attributed Income at that balance, so an entrant gets none of the
    ///      income collected before it entered and a leaver keeps what it earned. The income work changes this body,
    ///      not its callers.
    function beforeBalanceChange(
        CoreVaultState storage s,
        CoreVaultWiring memory,
        address holder,
        uint256 balanceBefore
    ) public {
        s.incomeBook.index.checkpoint(holder, balanceBefore);
    }

    /// @notice Called after every mint (deposit, seed): `minted` shares went to `holder`. Nothing to do yet; the income
    ///         work fills it (DEC-145, entry time).
    function afterMint(CoreVaultState storage, CoreVaultWiring memory, address, uint256) public pure {}

    /// @notice Called after every burn (payout) that burned shares: `burned` shares of `holder` were burned, leaving
    ///         `balanceAfter`.
    /// @dev DEC-045, DEC-047: a full burn pays all Attributed Income payable now, in every token, in the same
    ///      transaction; `beforeBalanceChange` checkpointed the holder before the burn.
    function afterBurn(CoreVaultState storage s, CoreVaultWiring memory, address holder, uint256, uint256 balanceAfter)
        public
    {
        if (balanceAfter == 0) _payAllIncome(s, holder);
    }

    /// @notice DEC-045, DEC-047: pays all Attributed Income payable now to `holder`, in every token.
    /// @dev Independent review (verification plan CF-2; DEC-021, DEC-056: an exit is never blocked): an income token
    ///      that cannot be transferred to the holder (paused, blocklisting the holder, reverting) no longer reverts the
    ///      claim and with it the exit of the holder's principal. That token's income leaves the accumulator as usual
    ///      and is kept for the holder as an owed transfer (the S-12 path, `CoreVaultLogic.payFee`), paid to the holder
    ///      by the permissionless `claimOwedFees(token, holder)`. `withdrawIncome` still reverts on a failed transfer:
    ///      there the holder asked for that one token.
    function _payAllIncome(CoreVaultState storage s, address holder) private {
        address[] memory tokens = s.incomeBook.index.tokens;
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = s.incomeBook.index.takeOwed(holder, token, s.incomeBook.collectedIncome[token]);
            if (amount == 0) continue;
            s.incomeBook.collectedIncome[token] -= amount;
            CoreVaultLogic.payFee(s, token, holder, amount);
            emit ICoreVaultIncome.IncomeWithdrawn(holder, token, amount);
        }
    }
}
