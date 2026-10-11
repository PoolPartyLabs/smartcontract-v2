// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IAdapterGuard} from "./IAdapterGuard.sol";

/// @title IAdapter
/// @notice Position adapter: executes on one external protocol on behalf of exactly one Spoke Vault.
/// @dev DEC-053: an Adapter is fixed in the Mandate at creation and never added later. DEC-058: one immutable
///      instance per fund per chain; no proxy, no mutable logic pointer, no target setter; a live fund never adopts
///      new code. The Spoke Vault calls it with a normal CALL, never DELEGATECALL.
/// @dev Q17-4 (OPEN, MVP reading O2): the Spoke Vault stores `adapter.codehash` next to the adapter address when it
///      is created and revalidates it on every call; an adapter therefore must not be able to change its runtime
///      code (no SELFDESTRUCT, no proxy).
/// @dev Token custody: before `openPosition` and `increasePosition` the vault transfers the input
///      tokens to the adapter; the adapter returns any unused amount to the vault in the same call. Every amount a
///      decrease, close or collect produces is transferred to the vault in the same call. The adapter holds
///      no idle balance between calls and clears every approval it grants (`forceApprove` to zero).
/// @dev Quarantine and deprecation (DEC-021, DEC-056, DEC-058): `openPosition` and `increasePosition` revert when
///      `paused()` or `deprecated()`; `decreasePosition`, `closePosition` and `collectIncome` never read either flag.
interface IAdapter is IAdapterGuard {
    /// @notice Value of one position read from the protocol's own accounting.
    /// @dev DEC-079: principal and income are reported separately; the vault does not classify.
    /// @dev Single-token positions (Aave V3 supply) set `token1 = address(0)`, ticks to 0 and every token1 amount to
    ///      0; `liquidity` then holds the protocol's scaled balance.
    /// @param poolKey Adapter-specific pool key, as listed in the Mandate.
    /// @param poolId Protocol pool identifier (Uniswap V4: `PoolId`, keccak256 of the `PoolKey`; Aave V3: the reserve
    ///        asset as bytes32).
    /// @param tickLower Lower tick (0 for protocols without ticks).
    /// @param tickUpper Upper tick (0 for protocols without ticks).
    /// @param liquidity Position liquidity (Uniswap V4) or scaled balance (Aave V3).
    /// @param token0 First token of the position.
    /// @param token1 Second token of the position (address(0) for single-token positions).
    /// @param principal0 Principal in token0 if the position were removed now (at the pool's current state).
    /// @param principal1 Principal in token1 if the position were removed now.
    /// @param income0 Income in token0 generated and not yet collected.
    /// @param income1 Income in token1 generated and not yet collected.
    struct PositionValue {
        bytes32 poolKey;
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token0;
        address token1;
        uint256 principal0;
        uint256 principal1;
        uint256 income0;
        uint256 income1;
    }

    /// @notice Amounts an exit verb transferred to the vault, principal and income separated per token (DEC-079).
    struct Amounts {
        uint256 principal0;
        uint256 principal1;
        uint256 income0;
        uint256 income1;
    }

    /// @notice A position was opened.
    event PositionOpened(bytes32 indexed positionKey, bytes32 indexed poolKey, uint256 used0, uint256 used1);

    /// @notice A position was increased. `income0`/`income1` is income the protocol realized during the increase and
    ///         the adapter transferred to the vault.
    event PositionIncreased(
        bytes32 indexed positionKey, uint256 used0, uint256 used1, uint256 income0, uint256 income1
    );

    /// @notice A position was decreased.
    event PositionDecreased(bytes32 indexed positionKey, Amounts amounts);

    /// @notice A position was closed and removed from `positionKeys()`.
    event PositionClosed(bytes32 indexed positionKey, Amounts amounts);

    /// @notice Income of a position was collected.
    event IncomeCollected(bytes32 indexed positionKey, uint256 income0, uint256 income1);

    /// @notice A swap was executed in a Mandate pool.
    event Swapped(
        bytes32 indexed poolKey, address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut
    );

    /// @notice Caller is not this adapter's vault.
    error NotVault(address caller);

    /// @notice The pool key is not one this adapter can operate.
    error UnknownPool(bytes32 poolKey);

    /// @notice The position key is not an open position of this adapter.
    error UnknownPosition(bytes32 positionKey);

    /// @notice Output of a swap is below the caller's minimum.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    /// @notice The verb does not exist for this protocol (for example a swap on Aave V3).
    error UnsupportedOperation();

    /// @notice The Spoke Vault that owns this adapter. Every mutating verb is restricted to it.
    function vault() external view returns (address);

    /// @notice Whether this adapter's positions have an exact USDC value that is read, never unwound (DEC-059).
    /// @dev Uniswap V4 positions are price-dependent: false. Aave V3 aUSDC supply: true.
    function isExactValue() external view returns (bool);

    /// @notice Tokens of a pool. Reverts with `UnknownPool` if the key is not valid for this adapter.
    /// @dev DEC-079 (OPEN for hooks that charge on withdrawal): the Uniswap V4 adapter reverts with `UnknownPool` for a
    ///      pool with hooks, so the MVP accepts only hookless pools. The Spoke Vault calls this for every Mandate pool
    ///      on its chain at creation, which is where that rule is enforced (a Mandate `poolKey` is a hash and cannot be
    ///      checked for hooks in memory).
    function poolTokens(bytes32 poolKey) external view returns (address token0, address token1);

    /// @notice Opens a position. Vault only; reverts when paused or deprecated (DEC-056, DEC-058).
    /// @param poolKey Mandate-listed pool key; the vault checks the Mandate, the adapter checks the protocol.
    /// @param params Adapter-specific parameters (Uniswap V4: ticks, liquidity or desired amounts, maximum amounts,
    ///        deadline).
    /// @return positionKey Adapter-assigned key of the new position.
    /// @return used0 Amount of token0 placed in the position; the rest was returned to the vault.
    /// @return used1 Amount of token1 placed in the position; the rest was returned to the vault.
    function openPosition(bytes32 poolKey, bytes calldata params)
        external
        returns (bytes32 positionKey, uint256 used0, uint256 used1);

    /// @notice Adds to a position. Vault only; reverts when paused or deprecated (DEC-056, DEC-058).
    /// @return used0 Amount of token0 added; the rest was returned to the vault.
    /// @return used1 Amount of token1 added; the rest was returned to the vault.
    /// @return income0 Income in token0 the protocol realized during the increase, transferred to the vault.
    /// @return income1 Income in token1 the protocol realized during the increase, transferred to the vault.
    function increasePosition(bytes32 positionKey, bytes calldata params)
        external
        returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1);

    /// @notice Removes part of a position. Vault only; never gated by pause or deprecation (DEC-056).
    /// @dev The principal asked leaves first; income the protocol cannot pay now stays pending and never blocks it
    ///      (final verification, DEC-056, DEC-068).
    /// @return amounts Principal and income transferred to the vault, separated per token (DEC-079).
    function decreasePosition(bytes32 positionKey, bytes calldata params) external returns (Amounts memory amounts);

    /// @notice Removes a position entirely. Vault only; never gated by pause or deprecation (DEC-056).
    /// @dev The whole principal always leaves. Income the protocol cannot pay now never blocks it (final verification,
    ///      DEC-056, DEC-068): an adapter may then keep the key open, holding only that pending income, and emit
    ///      `PositionDecreased` instead of `PositionClosed`; the Spoke Vault keeps the position registered while
    ///      `positionKeys()` lists it.
    /// @return amounts Principal and income transferred to the vault, separated per token (DEC-079).
    function closePosition(bytes32 positionKey, bytes calldata params) external returns (Amounts memory amounts);

    /// @notice Collects the income of a position. Vault only; never gated by pause or deprecation.
    /// @dev OPEN (Q17-2a): whether quarantine should suspend collection. MVP reading C1: never gated.
    /// @return amounts Income transferred to the vault; principal fields are always zero.
    function collectIncome(bytes32 positionKey) external returns (Amounts memory amounts);

    /// @notice Value of an open position from the protocol's own accounting. Reverts with `UnknownPosition` for a
    ///         key that is not open.
    function positionValue(bytes32 positionKey) external view returns (PositionValue memory);

    /// @notice Exit parameters that remove at least `numerator / denominator` of an open position's principal at the
    ///         protocol's current state (rounded up), with no minimum amounts and the current block as deadline.
    /// @dev DEC-137: the Spoke Vault supplies the fraction fixed from shares, never exit sizes from a claimant.
    ///      `close` is true when that share is
    ///      the whole position (call `closePosition` with `params`), else `decreasePosition` takes `params`.
    ///      `numerator <= denominator`, `denominator > 0`.
    function unwindExitParams(bytes32 positionKey, uint256 numerator, uint256 denominator)
        external
        view
        returns (bool close, bytes memory params);

    /// @notice Income in `token` since inception: all income ever realized plus the currently uncollected income of
    ///         open positions. Never a balance.
    /// @dev Q60 and DEC-092: monotonic non-decreasing, including across closed positions, so the income index can
    ///      advance from deltas. Uniswap V4: realized `feesAccrued` of every liquidity change plus the current
    ///      uncollected fees from `feeGrowthInside`. Aave V3: the sum of `scaledBalance * (index_now - index_last)`
    ///      (DEC-068).
    function cumulativeIncome(address token) external view returns (uint256);

    /// @notice Keys of every open position, in no particular order.
    function positionKeys() external view returns (bytes32[] memory);
}
