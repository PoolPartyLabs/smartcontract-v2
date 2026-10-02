// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISpokeVaultIncome} from "../interfaces/ISpokeVaultIncome.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {TransitState, TransferKind} from "../interfaces/FundTypes.sol";
import {OrderCodec} from "../libraries/OrderCodec.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeIncomeTypes} from "./SpokeIncomeTypes.sol";
import {SpokeLedger} from "./SpokeLedger.sol";
import {SpokeCrossChainLib} from "./SpokeCrossChainLib.sol";

/// @title SpokeIncomeLib
/// @notice The Spoke Vault's income collection: the executor of the Core Vault's collection orders on a spoke and the
///         collection the Core Vault runs on the hub Spoke Vault (DEC-122, DEC-124, DEC-161, DEC-172). Deployed once per
///         chain and linked into `SpokeVault`; it runs in the vault's context (library call) over the vault's own
///         `SpokeVaultTypes.State`, holds no state and is immutable (DEC-022, DEC-058).
/// @dev A collection, on either side (doc 10 sections 2 and 8, DEC-161):
///      1. collects every open position's income into the collected income bucket (DEC-079, DEC-092); a position whose
///         adapter refuses is skipped (DEC-056);
///      2. sells the whole bucket of every non-base token for the base token through the chain's Mandate swap adapter
///         (DEC-124: income travels as dollars; DEC-136, DEC-153: the adapter picks the best direct V3 tier, a swap
///         into the base token is never blocked by its pause; DEC-172: on the hub too), with the order's maximum loss
///         (none unless given, DEC-144 consequence); a failed sale is skipped and the token waits for a later
///         collection;
///      3. hands the dollars to the Core Vault with what each token sold for: on the hub by transfer, on a spoke as one
///         Income send home through the primary bridge adapter on its own terms (DEC-158, DEC-162; DEC-166, DEC-175:
///         the fund pays the bridge, which lowers the conversion rate), with the result in the next report.
/// @dev Calls `SpokeCrossChainLib.sendHome` (the single send path home) through that library's linked address, so its
///      creation code links it and it is deployed after it (script/FactoryDeployment.sol).
/// @dev Events and errors are the vault's (ISpokeVault, ISpokeVaultIncome, SpokeVaultTypes), emitted from the vault's
///      address. The library is part of the vault's creation code and trust surface.
library SpokeIncomeLib {
    using SafeERC20 for IERC20;
    using SpokeLedger for SpokeVaultTypes.State;

    // ---------------------------------------------------------------------------------------------------------------
    // Entries
    // ---------------------------------------------------------------------------------------------------------------

    /// @notice Body of `SpokeVaultIncome._executeCollectOrder`: a spoke's collection for the order's round (DEC-122
    ///         item 5, DEC-124, DEC-161).
    /// @dev Order of work: a send of an earlier result whose refund came back is noted; positions are collected; the
    ///      base token income not owed to an earlier result (`fresh`) and the sales of this execution join what earlier
    ///      executions could not send; refunded results are sent again; then everything unsent goes home in one Income
    ///      send, recorded as this execution's result. When the primary bridge adapter would deliver nothing for the
    ///      amount (a dust amount), nothing is sent and the result records an empty send: the sales wait, in the
    ///      bucket and in the book, for the next execution. The report published right after carries the last
    ///      `REPORTED_RESULTS` results.
    function executeCollectOrder(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        OrderCodec.Order memory o
    ) external {
        SpokeIncomeTypes.Book storage b = s.income;
        address base = c.baseToken;
        _noteRefunds(s, b);
        _collectPositions(s, base);
        uint256 held = b.unsentBase + b.resendBase;
        uint256 bucket = s.collectedIncome[base];
        (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained) =
            _sellAll(s, base, o.maxLossBps, bucket > held ? bucket - held : 0);
        uint256 added;
        for (uint256 i; i < tokens.length; ++i) {
            if (sold[i] == 0) continue;
            b.unsentSold[tokens[i]] += sold[i];
            b.unsentObtained[tokens[i]] += obtained[i];
            added += obtained[i];
        }
        b.unsentBase += added;
        _resend(s, c, b);
        _sendResult(s, c, b, uint64(uint256(o.requestId)), tokens);
        _writeBlob(b);
    }

    /// @notice Body of `SpokeVaultIncome.collectIncomeAll` on the hub Spoke Vault: collects every position, sells every
    ///         non-USDC token for USDC and transfers the whole collected USDC to the Core Vault (DEC-172).
    /// @dev Everything in the hub's collected income bucket is income the Core Vault recognized from the hub counters
    ///      (DEC-138), so it all goes; the Core Vault requires the transfer above its ledger (DEC-080) and converts it.
    function collectHub(SpokeVaultTypes.State storage s, address baseToken, address coreVault, uint16 maxLossBps)
        external
        returns (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained)
    {
        _collectPositions(s, baseToken);
        (tokens, sold, obtained) = _sellAll(s, baseToken, maxLossBps, s.collectedIncome[baseToken]);
        uint256 total = s.collectedIncome[baseToken];
        if (total == 0) return (tokens, sold, obtained);
        s.collectedIncome[baseToken] = 0;
        IERC20(baseToken).safeTransfer(coreVault, total);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Collection
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-079, DEC-092, DEC-056: collects every open position's income into the collected income bucket; a
    ///      position whose adapter code changed (Q17-4) or whose adapter refuses is skipped. The ledger must stay backed
    ///      afterwards (DEC-080: an adapter that reports more than it paid reverts the collection).
    function _collectPositions(SpokeVaultTypes.State storage s, address base) private {
        uint256 n = s.positions.length;
        for (uint256 i; i < n; ++i) {
            ISpokeVault.PositionRef memory ref = s.positions[i];
            if (ref.adapter.codehash != s.codehash[ref.adapter]) continue;
            try IAdapter(ref.adapter).collectIncome(ref.positionKey) returns (IAdapter.Amounts memory a) {
                s.credit(s.pools[ref.adapter][ref.poolKey], a);
                emit ISpokeVault.IncomeCollected(ref.adapter, ref.positionKey, a.income0, a.income1);
            } catch {}
        }
        address[] storage tokens = s.tokens;
        for (uint256 i; i < tokens.length; ++i) {
            s.requireBacked(base, tokens[i]);
        }
    }

    /// @dev Sells the collected income bucket of every non-base ledger token for the base token; the base token's own
    ///      `baseAmount` counts as sold at face value. Returns the ledger tokens (base first) and, per token, the units
    ///      sold and the base units obtained (zero for a token not sold).
    function _sellAll(SpokeVaultTypes.State storage s, address base, uint16 maxLossBps, uint256 baseAmount)
        private
        returns (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained)
    {
        tokens = s.tokens;
        uint256 n = tokens.length;
        sold = new uint256[](n);
        obtained = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            if (tokens[i] == base) (sold[i], obtained[i]) = (baseAmount, baseAmount);
            else (sold[i], obtained[i]) = _sellBucket(s, tokens[i], base, maxLossBps);
        }
    }

    /// @dev One sale of the whole collected income bucket of `token` into the base token, through the chain's first
    ///      Mandate swap adapter (the alpha lists one, DEC-136) with an empty route (DEC-153: the adapter's best direct
    ///      tier; D-02: never a caller's route). A refused sale changes nothing and returns zeros.
    function _sellBucket(SpokeVaultTypes.State storage s, address token, address base, uint16 maxLossBps)
        private
        returns (uint256 sold, uint256 obtained)
    {
        uint256 amount = s.collectedIncome[token];
        if (amount == 0) return (0, 0);
        ISwapAdapter a = s.swapAdapter(s.swapAdapters[0]);
        uint256 inBefore = IERC20(token).balanceOf(address(this));
        uint256 outBefore = IERC20(base).balanceOf(address(this));
        IERC20(token).forceApprove(address(a), amount);
        bool done;
        (done, obtained) = _trySwap(a, token, base, amount, maxLossBps);
        IERC20(token).forceApprove(address(a), 0);
        if (!done) return (0, 0);
        _requireSwapped(token, base, amount, obtained, inBefore, outBefore);
        s.collectedIncome[token] -= amount;
        s.collectedIncome[base] += obtained;
        sold = amount;
    }

    /// @dev The swap adapter call, its refusal caught (DEC-056: a failing sale never blocks the collection).
    function _trySwap(ISwapAdapter a, address token, address base, uint256 amount, uint16 maxLossBps)
        private
        returns (bool done, uint256 out)
    {
        try a.swap(token, base, amount, maxLossBps, "") returns (uint256 amountOut, uint256 spotOut, uint256 minOut) {
            emit ISpokeVaultIncome.IncomeSold(address(a), token, amount, amountOut, spotOut, maxLossBps, minOut);
            return (true, amountOut);
        } catch {
            emit ISpokeVaultIncome.IncomeSaleFailed(address(a), token, amount);
        }
    }

    /// @dev Custody of a sale, as `SpokeLedger.swapThrough` (DEC-080): the vault's balances show exactly `amount` of
    ///      `token` out and at least the returned output of the base token in.
    function _requireSwapped(
        address token,
        address base,
        uint256 amount,
        uint256 out,
        uint256 inBefore,
        uint256 outBefore
    ) private view {
        uint256 debited = inBefore - IERC20(token).balanceOf(address(this));
        if (debited != amount) revert SpokeVaultTypes.SwapDebitMismatch(amount, debited);
        uint256 received = IERC20(base).balanceOf(address(this)) - outBefore;
        if (received < out) revert SpokeVaultTypes.SwapOutputNotReceived(out, received);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Sends home and results
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-066: a send home whose fill deadline passed is refunded to the vault, and its refund recognized puts
    ///      the dollars back into the collected income bucket. Each reported result whose send came back that way is
    ///      noted, so those dollars are sent again under the same result instead of being counted as new income.
    function _noteRefunds(SpokeVaultTypes.State storage s, SpokeIncomeTypes.Book storage b) private {
        (uint64 first, uint64 last) = _window(b);
        for (uint64 id = first; id <= last; ++id) {
            SpokeIncomeTypes.CollectionResult storage r = b.results[id];
            bytes32 transitId = r.transitId;
            if (transitId == bytes32(0) || b.awaitingResend[id]) continue;
            if (s.hubBoundTransits[transitId].state != TransitState.RefundRecognized) continue;
            b.awaitingResend[id] = true;
            b.resendBase += r.amountSent;
        }
    }

    /// @dev Sends again the dollars of each result whose send was refunded, under the same result (the Hub converts it
    ///      when the new send is credited). A send the bridge would refuse waits for the next execution.
    function _resend(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory c, SpokeIncomeTypes.Book storage b)
        private
    {
        if (b.resendBase == 0) return;
        (uint64 first, uint64 last) = _window(b);
        for (uint64 id = first; id <= last; ++id) {
            if (!b.awaitingResend[id]) continue;
            SpokeIncomeTypes.CollectionResult storage r = b.results[id];
            uint256 amount = r.amountSent;
            if (!_bridgeable(s, c, amount)) continue;
            bytes32 transitId = SpokeCrossChainLib.sendHome(s, c, amount, TransferKind.Income, 0, "");
            r.transitId = transitId;
            b.awaitingResend[id] = false;
            b.resendBase -= amount;
            emit ISpokeVaultIncome.IncomeResent(id, transitId, amount);
        }
    }

    /// @dev Writes this execution's result: when the unsent dollars can be bridged they go home in one Income send and
    ///      the result carries every unsent sale (only tokens with a sale); otherwise an empty result tells the Hub the
    ///      spoke ran the round.
    function _sendResult(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        SpokeIncomeTypes.Book storage b,
        uint64 round,
        address[] memory tokens
    ) private {
        uint64 id = ++b.resultCount;
        SpokeIncomeTypes.CollectionResult storage r = b.results[id];
        r.resultId = id;
        r.round = round;
        uint256 amount = b.unsentBase;
        if (amount == 0 || !_bridgeable(s, c, amount)) {
            emit ISpokeVaultIncome.IncomeCollectionExecuted(round, id, bytes32(0), 0);
            return;
        }
        bytes32 transitId = SpokeCrossChainLib.sendHome(s, c, amount, TransferKind.Income, 0, "");
        r.transitId = transitId;
        r.amountSent = amount;
        b.unsentBase = 0;
        for (uint256 i; i < tokens.length; ++i) {
            address token = tokens[i];
            uint256 sold = b.unsentSold[token];
            if (sold == 0) continue;
            r.tokens.push(token);
            r.sold.push(sold);
            r.obtained.push(b.unsentObtained[token]);
            delete b.unsentSold[token];
            delete b.unsentObtained[token];
        }
        emit ISpokeVaultIncome.IncomeCollectionExecuted(round, id, transitId, amount);
    }

    /// @dev Whether a send home of `amount` would leave now and deliver something: the in-flight list has room
    ///      (security review S-11; checked before the send's own sweep, so conservatively) and the primary bridge
    ///      adapter quotes a non-zero amount to arrive (it reverts on a dust amount).
    function _bridgeable(SpokeVaultTypes.State storage s, SpokeVaultTypes.Config memory c, uint256 amount)
        private
        view
        returns (bool)
    {
        if (s.bridgeAdapters.length == 0 || s.inFlightIds.length >= SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT) {
            return false;
        }
        try IBridgeAdapter(s.bridgeAdapters[0]).quoteSend(c.baseToken, c.hubChainId, amount, "") returns (
            uint256 amountToArrive, uint256
        ) {
            return amountToArrive != 0;
        } catch {
            return false;
        }
    }

    /// @dev Rewrites the report blob with the last `REPORTED_RESULTS` results, oldest first.
    function _writeBlob(SpokeIncomeTypes.Book storage b) private {
        (uint64 first, uint64 last) = _window(b);
        SpokeIncomeTypes.CollectionResult[] memory list = new SpokeIncomeTypes.CollectionResult[](last + 1 - first);
        for (uint64 id = first; id <= last; ++id) {
            list[id - first] = b.results[id];
        }
        b.reportBlob = abi.encode(list);
    }

    /// @dev Ids of the results the report carries, `first` to `last` inclusive (`first > last` when there is none).
    function _window(SpokeIncomeTypes.Book storage b) private view returns (uint64 first, uint64 last) {
        last = b.resultCount;
        first = last > SpokeIncomeTypes.REPORTED_RESULTS ? last - uint64(SpokeIncomeTypes.REPORTED_RESULTS) + 1 : 1;
    }
}
