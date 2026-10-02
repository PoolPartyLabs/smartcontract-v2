// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {ISpokeVaultUnwind} from "../interfaces/ISpokeVaultUnwind.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {ICoreVault} from "../interfaces/ICoreVault.sol";
import {IPriceSource} from "../interfaces/IPriceSource.sol";
import {MandateLib, UnwindStep} from "../mandate/Mandate.sol";
import {SpokeVaultTypes} from "./SpokeVaultTypes.sol";
import {SpokeLedger} from "./SpokeLedger.sol";

/// @title SpokeUnwindLib
/// @notice The automatic unwind of the hub Spoke Vault (the body of `SpokeVault.unwindForPayout`). Deployed once per
///         chain and linked into `SpokeVault`; it runs in the vault's context (library call) over the vault's own
///         `SpokeVaultTypes.State`, holds no state and is immutable (DEC-022, DEC-058).
/// @dev DEC-131 (alternative C, b1, b2): moved out of the vault unchanged, before the fix batch, so the vault keeps room
///      under the smallest code limit across the chains (24,576 bytes, Arbitrum One; b3, b4). The vault keeps the
///      access control (hub only, Core Vault only), the reentrancy guard and the public `MAX_UNWIND_SLIPPAGE_BPS`.
///      Events and errors are the vault's (ISpokeVault and SpokeVaultTypes), emitted from the vault's address. The
///      library is part of the vault's creation code and trust surface, like `SpokeCrossChainLib`.
library SpokeUnwindLib {
    /// @notice Largest shortfall below the pool's current price, in bps, that an automatic unwind swap accepts: the
    ///         swap's minimum output is at least the route's `IAdapter.spotQuote` less this share.
    /// @dev OPEN parameter (QA3: the price guard of hub positions is undecided; final verification). Measured from the
    ///      higher of the route's spot quote and the Core Vault's price-source value (security review S-2: a spot price
    ///      can be moved within a block by the claimant); a claimant hint may only raise the minimum. Published by the
    ///      vault as `SpokeVault.MAX_UNWIND_SLIPPAGE_BPS`.
    uint256 internal constant MAX_UNWIND_SLIPPAGE_BPS = 500;

    /// @notice Body of `ISpokeVault.unwindForPayout`; the vault checks the chain, the caller and reentrancy first.
    /// @dev DEC-069: walks the Mandate unwind order restricted to this chain; within a step, every open position of
    ///      that (adapter, pool) in registry order. An illiquid step reverts (no try/catch, a position is never
    ///      skipped). The stop condition (USDC Unallocated Balance at `usdcTarget`) is re-evaluated before every
    ///      position.
    /// @dev Final verification (DEC-069, DEC-081, DEC-097, QA3 OPEN): the vault, not the claimant, sizes every step.
    ///      For each position it values the principal in USDC (`IAdapter.positionValue`, non-USDC legs at the route's
    ///      `spotQuote`), takes the shortfall still needed (`usdcTarget` minus the USDC Unallocated Balance so far)
    ///      and asks the adapter for the exit that removes only that share (`IAdapter.unwindExitParams`); the whole
    ///      position is closed only when its whole value is needed. A position with no principal value is skipped.
    /// @dev DEC-059, DEC-067: Unallocated USDC (exact value) is used first; every position, Exact-Value ones included
    ///      (`isExactValue`), is only exited while the target is not reached, so an Exact-Value position is read, not
    ///      exited, when what comes before it covers the target.
    /// @dev Non-USDC principal an exit returns is swapped to USDC through `swapExactInput` with a minimum output of
    ///      at least the route's spot quote less `MAX_UNWIND_SLIPPAGE_BPS` (DEC-081: `usdcTarget` already holds the 2%
    ///      margin; DEC-097: its Market Costs are the fund's). The claimant's hints can only raise that minimum or
    ///      restrict the swap; they never size an exit. Income from the exits goes to the collected income bucket,
    ///      never to the proceeds (DEC-092).
    /// @param unwindHints `abi.encode(SpokeVaultTypes.UnwindHint[])`, optional, one per position visited in order.
    function unwindForPayout(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        uint256 usdcTarget,
        bytes calldata unwindHints
    ) external returns (uint256 usdcProceeds) {
        if (usdcTarget == 0) revert ISpokeVault.ZeroAmount();
        SpokeVaultTypes.UnwindHint[] memory hints = unwindHints.length == 0
            ? new SpokeVaultTypes.UnwindHint[](0)
            : abi.decode(unwindHints, (SpokeVaultTypes.UnwindHint[]));

        address usdc = c.baseToken;
        uint256 visited;
        for (uint256 i; i < s.unwindOrder.length && s.unallocated[usdc] < usdcTarget; ++i) {
            visited = _unwindStep(s, c, s.unwindOrder[i], hints, visited, usdcTarget);
        }

        usdcProceeds = Math.min(s.unallocated[usdc], usdcTarget);
        if (usdcProceeds != 0) {
            s.unallocated[usdc] -= usdcProceeds;
            SpokeLedger.payCoreVaultIdle(usdc, c.coreVault, usdcProceeds);
        }
        emit ISpokeVaultUnwind.UnwoundForPayout(usdcTarget, usdcProceeds);
    }

    /// @dev Every open position of one Mandate unwind step, in registry order, while the target is not reached; the
    ///      `visited`-th position takes the `visited`-th hint, if any. Returns the positions visited so far.
    function _unwindStep(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        UnwindStep memory step,
        SpokeVaultTypes.UnwindHint[] memory hints,
        uint256 visited,
        uint256 usdcTarget
    ) private returns (uint256) {
        bytes32[] memory keys = SpokeLedger.positionKeysOf(s, step.adapter, step.poolKey);
        for (uint256 k; k < keys.length; ++k) {
            uint256 held = s.unallocated[c.baseToken];
            if (held >= usdcTarget) break;
            SpokeVaultTypes.UnwindSwap[] memory swaps;
            if (visited < hints.length) swaps = hints[visited].swaps;
            ++visited;
            _unwindPosition(s, c, step.adapter, step.poolKey, keys[k], usdcTarget - held, swaps);
        }
        return visited;
    }

    /// @dev One unwind step on one position (final verification): value the principal in USDC, exit only the share
    ///      of it the `shortfall` needs (the whole position when its whole value is needed), then swap the non-USDC
    ///      principal the exit returned into USDC above the vault's floor.
    function _unwindPosition(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        address adapter,
        bytes32 poolKey,
        bytes32 positionKey,
        uint256 shortfall,
        SpokeVaultTypes.UnwindSwap[] memory swaps
    ) private {
        IAdapter a = SpokeLedger.positionAdapter(s, adapter);
        SpokeVaultTypes.PoolTokens memory p = SpokeLedger.pool(s, adapter, poolKey);
        SpokeVaultTypes.UnwindSwap memory r0 = _unwindRoute(s, c.baseToken, adapter, poolKey, p, p.token0, swaps);
        SpokeVaultTypes.UnwindSwap memory r1 = _unwindRoute(s, c.baseToken, adapter, poolKey, p, p.token1, swaps);
        uint256 value;
        {
            IAdapter.PositionValue memory v = a.positionValue(positionKey);
            value = _unwindValue(r0, v.principal0) + _unwindValue(r1, v.principal1);
        }
        if (value == 0) return;
        (bool close, bytes memory params) = a.unwindExitParams(positionKey, Math.min(shortfall, value), value);
        (IAdapter.Amounts memory amounts,) = SpokeLedger.exit(
            s,
            c.baseToken,
            adapter,
            positionKey,
            close ? SpokeVaultTypes.ExitKind.Close : SpokeVaultTypes.ExitKind.Decrease,
            params
        );
        _unwindSwap(s, c, r0, amounts.principal0);
        _unwindSwap(s, c, r1, amounts.principal1);
    }

    /// @dev The swap route of `token` into USDC for an unwind exit: none for USDC (or a missing token1); the
    ///      position's own pool when it pairs `token` with USDC (a hint for `token` must then name that same route);
    ///      otherwise the hint's route, which must be a Mandate pool of a Mandate adapter pairing `token` with USDC.
    ///      The hint entry's `minAmountOut` and `params` travel with the route.
    /// @dev Independent verification plan T14: a single-asset position (`token1` zero, an Aave reserve) has no pair of
    ///      its own, so a non-USDC one takes the hint's route; asking its one-token pool for the other token reverted
    ///      every unwind that reached the step.
    function _unwindRoute(
        SpokeVaultTypes.State storage s,
        address usdc,
        address adapter,
        bytes32 poolKey,
        SpokeVaultTypes.PoolTokens memory p,
        address token,
        SpokeVaultTypes.UnwindSwap[] memory swaps
    ) private view returns (SpokeVaultTypes.UnwindSwap memory r) {
        if (token == usdc || token == address(0)) return r;
        for (uint256 i; i < swaps.length; ++i) {
            if (swaps[i].tokenIn == token) r = swaps[i];
        }
        if (p.token1 != address(0) && SpokeLedger.otherToken(p, token) == usdc) {
            if (r.adapter != address(0) && (r.adapter != adapter || r.poolKey != poolKey)) {
                revert SpokeVaultTypes.InvalidUnwindSwap(r.adapter, r.poolKey, token);
            }
            (r.adapter, r.poolKey, r.tokenIn) = (adapter, poolKey, token);
        } else {
            if (r.adapter == address(0)) revert SpokeVaultTypes.MissingUnwindSwap(token);
            SpokeLedger.positionAdapter(s, r.adapter);
            if (SpokeLedger.otherToken(SpokeLedger.pool(s, r.adapter, r.poolKey), token) != usdc) {
                revert SpokeVaultTypes.InvalidUnwindSwap(r.adapter, r.poolKey, token);
            }
        }
    }

    /// @dev USDC value of `amount` of a route's token at the route's spot price; USDC itself (no route) at par.
    function _unwindValue(SpokeVaultTypes.UnwindSwap memory r, uint256 amount) private view returns (uint256) {
        if (amount == 0 || r.adapter == address(0)) return amount;
        return IAdapter(r.adapter).spotQuote(r.poolKey, r.tokenIn, amount);
    }

    /// @dev Swaps `amountIn` along route `r` into USDC with a minimum output of at least the higher of the route's
    ///      spot quote and the Core Vault's price-source value, less `MAX_UNWIND_SLIPPAGE_BPS`; the hint's minimum
    ///      only when it is higher (final verification, QA3 OPEN).
    /// @dev Security review S-2: the claimant runs this inside its own transaction and can move `slot0` first, so a
    ///      floor measured against the spot quote alone followed the moved price. The price-source value (Chainlink
    ///      for WETH, the price Share Assets use) cannot be moved in the same block; a pushed-down spot now makes the
    ///      swap revert, the whole unwind reverts and the claim is paid from Idle only (DEC-068). A reverting price
    ///      source reverts the unwind the same way (the claim itself never reverts,
    ///      `CoreVaultPayoutLogic._unwindForPayout`).
    function _unwindSwap(
        SpokeVaultTypes.State storage s,
        SpokeVaultTypes.Config memory c,
        SpokeVaultTypes.UnwindSwap memory r,
        uint256 amountIn
    ) private {
        if (amountIn == 0 || r.adapter == address(0)) return;
        IAdapter a = IAdapter(r.adapter);
        (uint256 oracleValue,) = IPriceSource(ICoreVault(c.coreVault).priceSource()).usdcValue(r.tokenIn, amountIn);
        uint256 floor = Math.mulDiv(
            Math.max(a.spotQuote(r.poolKey, r.tokenIn, amountIn), oracleValue),
            MandateLib.BPS - MAX_UNWIND_SLIPPAGE_BPS,
            MandateLib.BPS
        );
        SpokeLedger.swap(
            s,
            c.baseToken,
            a,
            SpokeLedger.pool(s, r.adapter, r.poolKey),
            r.poolKey,
            r.tokenIn,
            amountIn,
            Math.max(floor, r.minAmountOut),
            r.params,
            false
        );
    }
}
