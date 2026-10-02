// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreVaultIncome} from "../interfaces/ICoreVaultIncome.sol";
import {IManagerRegistry} from "../interfaces/IManagerRegistry.sol";
import {IncomeAccumulator} from "../libraries/IncomeAccumulator.sol";
import {CoreVaultState, CoreVaultWiring} from "./CoreVaultTypes.sol";
import {CoreVaultLogic} from "./CoreVaultLogic.sol";

/// @title CoreVaultIncomeLogic
/// @notice Collected income of the Core Vault: the fee split at collection and the advance of the shareholders'
///         accumulator, and the income payment of a full exit, as an external library that runs in the Core Vault's
///         context (DELEGATECALL into the fund's own linked library, never into an adapter).
/// @dev DEC-131 pattern (alternative C) applied to the Core Vault (D-43): moved out of `CoreVaultLogic` unchanged so
///      each linked library keeps room under the 24,576-byte limit. It calls no other linked library (the fee transfer
///      `CoreVaultLogic.payFee` is internal, so it is compiled in); the Core Vault, `CoreVaultTransitLogic` and
///      `CoreVaultPayoutLogic` call it through its linked address, which is part of the Core Vault's creation code and
///      trust surface (immutable: no proxy, no upgrade path, DEC-022, DEC-058).
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
        s.collectedIncome[token] += net;
        s.income.distribute(token, net, IERC20(w.shareToken).totalSupply());
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
    // Full exit (DEC-045, DEC-047)
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice DEC-045, DEC-047: a full burn pays all Attributed Income payable now, in every token, in the same
    ///         transaction. The caller (`CoreVaultPayoutLogic`, after the burn) has checkpointed the holder.
    /// @dev Independent review (verification plan CF-2; DEC-021, DEC-056: an exit is never blocked): an income token
    ///      that cannot be transferred to the holder (paused, blocklisting the holder, reverting) no longer reverts the
    ///      claim and with it the exit of the holder's principal. That token's income leaves the accumulator as usual
    ///      and is kept for the holder as an owed transfer (the S-12 path, `CoreVaultLogic.payFee`), paid to the holder
    ///      by the permissionless `claimOwedFees(token, holder)`. `withdrawIncome` still reverts on a failed transfer:
    ///      there the holder asked for that one token.
    function payAllIncome(CoreVaultState storage s, address holder) public {
        address[] memory tokens = s.income.tokens;
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 amount = s.income.takeOwed(holder, token, s.collectedIncome[token]);
            if (amount == 0) continue;
            s.collectedIncome[token] -= amount;
            CoreVaultLogic.payFee(s, token, holder, amount);
            emit ICoreVaultIncome.IncomeWithdrawn(holder, token, amount);
        }
    }
}
