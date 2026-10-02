// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdapterGuard} from "./IAdapterGuard.sol";

/// @title ISwapAdapter
/// @notice Swap adapter: the third adapter type, next to position adapters and bridge adapters. Every swap a fund makes
///         runs through one; no swap runs in a Mandate position pool (DEC-136; founder, 2026-10-02: "swaps are not done
///         in the fund pools, we need a swap adapter").
/// @dev DEC-136 closing note, items 1-4: swap adapters are fixed in the Mandate at creation (DEC-053), one immutable
///      instance per fund per chain, called only by that chain's Spoke Vault; they swap only tokens the Mandate has, and
///      every output goes back to the vault; the sale inside an unwind uses the same adapter. DEC-058: no proxy, no
///      setter, so the vault can pin the address and its codehash.
/// @dev Who chooses the route (DEC-129, DEC-143, DEC-153; readings D-01, D-02, D-22):
///      - Empty `route`: the adapter chooses. It asks the Uniswap V3 factory which pools of the direct pair exist in the
///        four fee tiers (0.01%, 0.05%, 0.3%, 1%), quotes each with QuoterV2 and swaps in the one with the highest
///        output among the quotes that fill the whole input (DEC-153 item 2). Nothing is stored; a pair without a
///        direct V3 pool has no route without the API (DEC-153, accepted).
///      - Non-empty `route`: an `ApiRoute` signed (EIP-712) by `routeSigner`, the Pool Party API. The signature is what
///        lets the contract tell an API route from a caller's choice, which DEC-143 forbids. Anyone may relay a signed
///        route; every swap still works without the API (DEC-052).
/// @dev Maximum loss (DEC-140, DEC-142; readings D-19, D-20, D-23): `maxLossBps` is the caller's optional maximum,
///      measured against `spotOut`, the mid value of `amountIn` along the route's pools read before any leg trades
///      (pool fee plus price impact, DEC-118; the "value sold" of DEC-141). 0 or >= 10,000 means no maximum. With an
///      API route the stricter of that bound and the API's minimum applies (DEC-142). No oracle floor (DEC-129,
///      DEC-132); no protocol cap on the maximum (DEC-140 item 3, DEC-142 item 2). Open (founder): the `spotOut` of an
///      empty-route swap is the chosen tier's own mid, which a third party can set through a tier it creates or
///      pushes, and which can stand in place without arbitrage; until ruled, do not charge any cost against the
///      `spotOut` of an empty-route swap, with or without a maximum (see `UniswapV3SwapAdapter`).
/// @dev Custody: the vault approves exactly `amountIn` of `tokenIn` before calling `swap` or `swapDirect`; the adapter
///      pulls it, approves the router for exactly that amount, has every leg pay the vault directly, clears the
///      approval and keeps nothing. A swap that does not spend the whole input reverts with `PartialFill`.
/// @dev Quarantine and deprecation (DEC-056, DEC-058): a swap into the base token is the exit path (manual sale, income
///      conversion, unwind sale) and is never blocked; any other swap is an entry and reverts while paused or deprecated.
interface ISwapAdapter is IAdapterGuard {
    /// @notice A route from the Pool Party API, built from a Uniswap Trading API CLASSIC quote requested with
    ///         `protocols: ["V3"]`: each split of `quote.route` becomes one packed V3 path (`token | fee | token ...`,
    ///         `fee` in hundredths of a bip, as in the quote) and one weight.
    /// @dev Signed as EIP-712 `SwapRoute(address tokenIn,address tokenOut,bytes32 legsHash,uint256 quotedAmountIn,
    ///      uint256 minAmountOut,uint256 deadline)` with `legsHash = keccak256(abi.encode(paths, weightsBps))`, domain
    ///      `("Pool Party Swap Adapter", "1", chainId, adapter)`: bound to one adapter, so to one fund on one chain.
    ///      The route is amount-agnostic, because an unwind sells an amount only known on-chain (DEC-136 item 4,
    ///      DEC-137): the input is split by weight and `minAmountOut` is scaled to the amount actually sold.
    /// @param paths Packed V3 paths from `tokenIn` to `tokenOut`, one per split; at most `MAX_LEGS`, each at most
    ///        `MAX_HOPS` hops, every fee one of the four tiers, every pool deployed by the V3 factory. Only `tokenIn`
    ///        and `tokenOut` must be Mandate tokens; an intermediate hop may be any token (DEC-173).
    /// @param weightsBps Share of the input per path, each above zero, summing to 10,000; the last path takes the
    ///        rounding remainder.
    /// @param quotedAmountIn Input amount the API quoted; non-zero.
    /// @param minAmountOut The API's minimum output for `quotedAmountIn`.
    /// @param deadline Last timestamp at which the route is valid.
    /// @param signature ECDSA signature of `routeSigner`, or an EIP-1271 signature when it is a contract.
    struct ApiRoute {
        bytes[] paths;
        uint16[] weightsBps;
        uint256 quotedAmountIn;
        uint256 minAmountOut;
        uint256 deadline;
        bytes signature;
    }

    /// @notice A swap ran and its whole output reached the vault.
    /// @param spotOut Mid value of `amountIn` along the route before the trade (the reference of the maximum loss).
    /// @param directFee Fee tier of the direct pool used, or 0 for an API route.
    /// @param legsHash `keccak256(abi.encode(paths, weightsBps))` of the API route, or zero for a direct swap.
    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 spotOut,
        uint24 directFee,
        bytes32 indexed legsHash
    );

    /// @notice Caller is not the vault.
    error NotVault(address caller);

    /// @notice Zero input amount.
    error ZeroAmount();

    /// @notice `tokenIn` equals `tokenOut`.
    error IdenticalTokens(address token);

    /// @notice The swap's input or output token is not a Mandate token on this chain (DEC-136 item 2, DEC-173).
    error TokenNotInMandate(address token);

    /// @notice No direct V3 pool of the pair quoted a fill of the whole input within the gas cap (DEC-153: no route
    ///         without the API).
    error NoRoute(address tokenIn, address tokenOut);

    /// @notice A fee outside the four V3 tiers (100, 500, 3,000, 10,000).
    error InvalidFee(uint24 fee);

    /// @notice The V3 factory has no pool for this pair and tier, or the pool was never initialized (no price).
    error PoolNotFound(address tokenA, address tokenB, uint24 fee);

    /// @notice A path is malformed, too long, or does not run from `tokenIn` to `tokenOut`.
    error InvalidPath();

    /// @notice An API route has no leg, too many legs, mismatched weights, a zero weight, weights not summing to
    ///         10,000, or a zero quoted amount.
    error InvalidLegs();

    /// @notice The API route's deadline has passed.
    error RouteExpired(uint256 deadline);

    /// @notice The API route is not signed by `routeSigner` (or `routeSigner` is zero: API routes are disabled).
    error InvalidRouteSignature();

    /// @notice The legs did not spend exactly the input pulled from the vault.
    error PartialFill(uint256 balanceBefore, uint256 balanceAfter);

    /// @notice The output is below the caller's maximum loss or the API's minimum.
    error InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    /// @notice The Spoke Vault this adapter swaps for; the only caller of `swap` and `swapDirect`.
    function vault() external view returns (address);

    /// @notice The vault's base token (USDC on the Hub Chain, USDG on Robinhood Chain): a swap into it is an exit.
    function baseToken() external view returns (address);

    /// @notice Whether `token` is one of this chain's Mandate tokens, fixed at construction (DEC-136 item 2).
    function isMandateToken(address token) external view returns (bool);

    /// @notice The Pool Party API key that signs routes (D-01); immutable. Zero: API routes are refused.
    function routeSigner() external view returns (address);

    /// @notice Swaps `amountIn` of `tokenIn` (approved by the vault) into `tokenOut`, delivered to the vault. Vault only.
    /// @param maxLossBps The caller's maximum loss against `spotOut`, in bps; 0 or >= 10,000 for none (D-23).
    /// @param route Empty for the best direct V3 fee tier (DEC-153); otherwise `abi.encode(ApiRoute)`.
    /// @return amountOut Output delivered to the vault.
    /// @return spotOut Mid value of `amountIn` along the route before the trade, without fee or price impact: the
    ///         reference of the sale's loss (DEC-118, DEC-141).
    /// @return minOut The minimum output the swap was held to: the stricter of `spotOut` less `maxLossBps` and the API
    ///         route's minimum scaled to `amountIn` (DEC-142), 0 when neither applies. Returned so the vault's events
    ///         carry the limit each swap was accepted under (checklist doc 15, gap 4).
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint16 maxLossBps, bytes calldata route)
        external
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut);

    /// @notice The direct fee tier the adapter would choose for this swap (DEC-153) and its quoted output. Anyone.
    /// @dev State-changing only because QuoterV2 simulates each swap and reverts; meant for `eth_call` by the API and
    ///      for the vault's own libraries, which choose a tier once per token per unwind or collection (D-21). The
    ///      choice does not depend on the maximum loss: `swap` and `swapDirect` apply it to the chosen tier.
    function bestDirectFee(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint24 fee, uint256 quotedOut);

    /// @notice Swaps in the direct pool of `fee` (one of the four tiers; the pool must exist). Vault only.
    /// @dev Lets the vault's own libraries reuse a tier `bestDirectFee` chose within one unwind or collection (D-21).
    ///      The vault must never forward a caller-chosen fee here (DEC-143, D-02). Same custody, guard and maximum
    ///      loss as `swap`.
    function swapDirect(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint16 maxLossBps)
        external
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut);

    /// @notice Mid value of `amountIn` of `tokenIn` in `tokenOut` in the direct pool of `fee`, at its current
    ///         `slot0` price, without fee or price impact. Not an oracle: a spot price can be moved within a block.
    function spotValue(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee) external view returns (uint256);
}
