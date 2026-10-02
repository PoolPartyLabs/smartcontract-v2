// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISpokeVaultIncome} from "../interfaces/ISpokeVaultIncome.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";

/// @title SpokeLedger
/// @notice The Spoke Vault's position registry and internal ledger helpers (DEC-079, DEC-080), shared by `SpokeVault`
///         and the libraries linked into it.
/// @dev Internal library: inlined into each user, no deployed code of its own. Every function works on the vault's
///      own `SpokeVaultTypes.State`; the vault's immutables a helper needs (the base token, the Core Vault) are passed
///      in, because linked library code cannot read them. Events and errors are the vault's (ISpokeVault and
///      SpokeVaultTypes), emitted from the vault's address. DEC-131: split out of the vault so the automatic unwind
///      could move into the linked library `SpokeUnwindLib` without copying these helpers.
library SpokeLedger {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------------------------
    // Adapters and positions
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-053: Mandate adapters on this chain only. Q17-4: the pinned codehash must still match.
    function positionAdapter(SpokeVaultTypes.State storage s, address adapter) internal view returns (IAdapter) {
        if (!s.isPositionAdapter[adapter]) revert ISpokeVault.AdapterNotInMandate(adapter);
        bytes32 expected = s.codehash[adapter];
        bytes32 actual = adapter.codehash;
        if (actual != expected) revert ISpokeVault.AdapterCodehashMismatch(adapter, expected, actual);
        return IAdapter(adapter);
    }

    /// @dev DEC-030: Mandate pools on this chain only.
    function pool(SpokeVaultTypes.State storage s, address adapter, bytes32 poolKey)
        internal
        view
        returns (SpokeVaultTypes.PoolTokens memory p)
    {
        p = s.pools[adapter][poolKey];
        if (!p.listed) revert ISpokeVault.PoolNotInMandate(adapter, poolKey);
    }

    function positionPool(SpokeVaultTypes.State storage s, address adapter, bytes32 positionKey)
        internal
        view
        returns (bytes32)
    {
        uint256 slot = s.positionSlot[adapter][positionKey];
        if (slot == 0) revert ISpokeVault.UnknownPosition(adapter, positionKey);
        return s.positions[slot - 1].poolKey;
    }

    function removePosition(SpokeVaultTypes.State storage s, address adapter, bytes32 positionKey) internal {
        uint256 slot = s.positionSlot[adapter][positionKey];
        uint256 last = s.positions.length;
        if (slot != last) {
            ISpokeVault.PositionRef memory moved = s.positions[last - 1];
            s.positions[slot - 1] = moved;
            s.positionSlot[moved.adapter][moved.positionKey] = slot;
        }
        s.positions.pop();
        delete s.positionSlot[adapter][positionKey];
    }

    /// @dev Whether `a` still lists `positionKey` among its open positions.
    function adapterLists(IAdapter a, bytes32 positionKey) internal view returns (bool) {
        bytes32[] memory keys = a.positionKeys();
        for (uint256 i; i < keys.length; ++i) {
            if (keys[i] == positionKey) return true;
        }
        return false;
    }

    /// @dev DEC-056, DEC-079: decrease, close or collect; principal to Unallocated Balance, income to the collected
    ///      income bucket, both from what the adapter returned. A close leaves the registry only when the adapter no
    ///      longer lists the key: an adapter may keep it open holding income the protocol could not pay yet (Aave
    ///      reserve liquidity, final verification, DEC-056, DEC-068), and that income stays reachable and reported.
    function exit(
        SpokeVaultTypes.State storage s,
        address baseToken,
        address adapter,
        bytes32 positionKey,
        SpokeVaultTypes.ExitKind kind,
        bytes memory params
    ) internal returns (IAdapter.Amounts memory amounts, SpokeVaultTypes.PoolTokens memory p) {
        IAdapter a = positionAdapter(s, adapter);
        p = pool(s, adapter, positionPool(s, adapter, positionKey));
        if (kind == SpokeVaultTypes.ExitKind.Decrease) {
            amounts = a.decreasePosition(positionKey, params);
            emit ISpokeVault.PositionDecreased(adapter, positionKey, amounts);
        } else if (kind == SpokeVaultTypes.ExitKind.Close) {
            amounts = a.closePosition(positionKey, params);
            if (adapterLists(a, positionKey)) {
                emit ISpokeVault.PositionDecreased(adapter, positionKey, amounts);
            } else {
                removePosition(s, adapter, positionKey);
                emit ISpokeVault.PositionClosed(adapter, positionKey, amounts);
            }
        } else {
            amounts = a.collectIncome(positionKey);
            emit ISpokeVault.IncomeCollected(adapter, positionKey, amounts.income0, amounts.income1);
        }
        credit(s, p, amounts);
        requireBacked(s, baseToken, p);
    }

    /// @dev Swaps `tokenIn` for the pool's other token (DEC-079, DEC-080), from and into Unallocated Balance, or from
    ///      and into the collected income bucket when `income` is true (DEC-092: the two never mix).
    function swap(
        SpokeVaultTypes.State storage s,
        address baseToken,
        IAdapter a,
        SpokeVaultTypes.PoolTokens memory p,
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes memory params,
        bool income
    ) internal returns (uint256 amountOut) {
        address tokenOut = otherToken(p, tokenIn);
        if (amountIn == 0) revert ISpokeVault.ZeroAmount();
        if (income) {
            uint256 available = s.collectedIncome[tokenIn];
            if (amountIn > available) revert ISpokeVault.InsufficientCollectedIncome(tokenIn, available, amountIn);
            s.collectedIncome[tokenIn] = available - amountIn;
            IERC20(tokenIn).safeTransfer(address(a), amountIn);
        } else {
            sendToAdapter(s, address(a), tokenIn, amountIn);
        }
        amountOut = a.swapExactInput(poolKey, tokenIn, amountIn, minAmountOut, params);
        if (amountOut < minAmountOut) revert SpokeVaultTypes.SwapOutputBelowMinimum(amountOut, minAmountOut);
        if (income) {
            s.collectedIncome[tokenOut] += amountOut;
            emit ISpokeVaultIncome.IncomeSwapped(address(a), poolKey, tokenIn, tokenOut, amountIn, amountOut);
        } else {
            s.unallocated[tokenOut] += amountOut;
            emit ISpokeVault.Swapped(address(a), poolKey, tokenIn, tokenOut, amountIn, amountOut);
        }
        requireBacked(s, baseToken, tokenOut);
    }

    function otherToken(SpokeVaultTypes.PoolTokens memory p, address tokenIn) internal pure returns (address out) {
        if (tokenIn != address(0)) {
            if (tokenIn == p.token0) out = p.token1;
            else if (tokenIn == p.token1) out = p.token0;
        }
        if (out == address(0)) revert ISpokeVault.UnexpectedToken(tokenIn);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ledger (DEC-080)
    // ---------------------------------------------------------------------------------------------------------------

    function sendToAdapter(SpokeVaultTypes.State storage s, address adapter, address token, uint256 amount) internal {
        if (amount == 0) return;
        if (token == address(0)) revert ISpokeVault.UnexpectedToken(token);
        debitUnallocated(s, token, amount);
        IERC20(token).safeTransfer(adapter, amount);
    }

    function creditUnused(
        SpokeVaultTypes.State storage s,
        address adapter,
        SpokeVaultTypes.PoolTokens memory p,
        uint256 sent0,
        uint256 used0,
        uint256 sent1,
        uint256 used1
    ) internal {
        if (used0 > sent0) {
            revert SpokeVaultTypes.AdapterUsedAboveInput(adapter, p.token0, sent0, used0);
        }
        if (used1 > sent1) revert SpokeVaultTypes.AdapterUsedAboveInput(adapter, p.token1, sent1, used1);
        if (sent0 != used0) s.unallocated[p.token0] += sent0 - used0;
        if (sent1 != used1) s.unallocated[p.token1] += sent1 - used1;
    }

    /// @dev DEC-079: principal to Unallocated Balance, income to the collected income bucket (DEC-092).
    function credit(SpokeVaultTypes.State storage s, SpokeVaultTypes.PoolTokens memory p, IAdapter.Amounts memory a)
        internal
    {
        if (p.token1 == address(0) && (a.principal1 != 0 || a.income1 != 0)) {
            revert ISpokeVault.UnexpectedToken(address(0));
        }
        s.unallocated[p.token0] += a.principal0;
        s.collectedIncome[p.token0] += a.income0;
        if (p.token1 != address(0)) {
            s.unallocated[p.token1] += a.principal1;
            s.collectedIncome[p.token1] += a.income1;
        }
    }

    function debitUnallocated(SpokeVaultTypes.State storage s, address token, uint256 amount) internal {
        uint256 available = s.unallocated[token];
        if (amount > available) revert ISpokeVault.InsufficientUnallocatedBalance(token, available, amount);
        s.unallocated[token] = available - amount;
    }

    function ledgerTotal(SpokeVaultTypes.State storage s, address baseToken, address token)
        internal
        view
        returns (uint256 total)
    {
        total = s.unallocated[token] + s.collectedIncome[token];
        if (token == baseToken) total += s.operatingCash;
    }

    /// @dev DEC-080 fitness function: the ledger never exceeds the balance. An adapter or a caller that reports more
    ///      than it delivered makes the operation revert instead of inflating a value base.
    function requireBacked(SpokeVaultTypes.State storage s, address baseToken, address token) internal view {
        if (token == address(0)) return;
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 ledger = ledgerTotal(s, baseToken, token);
        if (balance < ledger) revert SpokeVaultTypes.LedgerExceedsBalance(token, balance, ledger);
    }

    function requireBacked(SpokeVaultTypes.State storage s, address baseToken, SpokeVaultTypes.PoolTokens memory p)
        internal
        view
    {
        requireBacked(s, baseToken, p.token0);
        requireBacked(s, baseToken, p.token1);
    }

    /// @dev Pays `amount` of the base token (hub USDC) into the Core Vault's Idle.
    function payCoreVaultIdle(address baseToken, address coreVault, uint256 amount) internal {
        IERC20(baseToken).safeTransfer(coreVault, amount);
        ICoreVault(coreVault).returnToIdle(amount);
    }
}
