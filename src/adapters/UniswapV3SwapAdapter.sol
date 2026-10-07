// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Factory} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import {IUniswapV3Pool} from "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {IPeripheryImmutableState} from "@uniswap/v3-periphery/contracts/interfaces/IPeripheryImmutableState.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {AdapterGuard} from "./AdapterGuard.sol";
import {ISwapAdapter} from "../interfaces/ISwapAdapter.sol";
import {ISwapRouter02} from "../interfaces/external/ISwapRouter02.sol";

/// @title UniswapV3SwapAdapter
/// @notice The alpha's only swap adapter (DEC-136 item 3): swaps a fund's Mandate tokens on Uniswap V3 through
///         SwapRouter02, either in the best direct fee tier it chooses itself (DEC-153) or along a route the Pool Party
///         API signed (DEC-129, founder, 2026-10-02: "receive the route from uniswap api that we'll send via our api's
///         signed interaction"). One instance per fund per chain, called only by that chain's Spoke Vault.
/// @dev See ISwapAdapter for the route, maximum-loss, custody and guard rules. Immutable: no proxy, no setter, no
///      SELFDESTRUCT (DEC-058). The route signer is fixed at construction; rotating it needs a new fund (LC-16).
/// @dev Gas (DEC-153 reading D-21): an uncapped QuoterV2 quote of an empty or dust tier walks the tick bitmap (25M to
///      36M gas measured on Arbitrum One, above its 32M cap), and anyone can create a missing tier. Every quote is
///      therefore capped at `QUOTE_GAS_CAP` inside try/catch, and pools without in-range liquidity are skipped. A tier
///      whose honest quote needs more than the cap drops out and the next best tier is used, still bounded by the
///      caller's maximum loss. With more than the cap left, a quote gets exactly the cap, so the outcome does not depend
///      on the transaction's gas. With less, EIP-150 forwards 63/64 of what is left, and a quote that then runs out
///      hands back up to about 2/64 of it: the adapter's own 1/64, plus most of the 1/64 QuoterV2 keeps, since QuoterV2
///      runs the pool's swap in its own try/catch and reverts cheaply after the pool runs out. That is about 30k gas
///      just under the cap, too little to finish the swap (over 100k): a caller cannot starve a better tier by limiting
///      gas and still complete the trade. A vault that wraps a swap in try/catch must guard its own catch.
/// @dev Known limit: SwapRouter02 does not require a hop of a multi-hop path to consume its whole input. The adapter
///      checks the first hop (the vault's input is spent exactly) and the output against the maximum loss; an
///      intermediate hop that stops at a price limit leaves its unspent intermediate token in the router, where anyone
///      can take it with `sweepToken`. For such a route DEC-136 item 2 (the output always returns to the fund) holds
///      only up to the output minimum. Only signed API routes have more than one hop; a direct swap has one.
/// @dev Open, for the founder (swap adapter review, rounds 2 to 4): the empty route chooses the tier on output alone
///      (DEC-153 item 2), and the loss reference is that tier's own mid price (DEC-153 consequence, D-19). Anyone can
///      create a missing tier or push a dust one to a mid price of their choosing, and such a tier can stand in place:
///      - A tier above the market whose mid sits on dust and whose fill liquidity sits at or just above the market
///        offers no arbitrage (about 1.5e-9 token on a fork). When it outbids the honest tier it is chosen: the fund
///        receives more, but `spotOut` is the third party's price. With a maximum, every bounded sale of the pair
///        reverts `InsufficientOutput` although the honest tier fills within it (DEC-148 leaves the position out), and
///        the tier, untouched, blocks the next one too; with its mid tuned just under the maximum, the sale passes and
///        reports a loss it did not have (4.7% under a 5% maximum on a fork, for a sale that lost 2 bps against the
///        market). Without a maximum the overstatement has no bound (899 on a sale worth 100 on a fork). None of this
///        needs a transaction from the third party at sale time: it hits the leaver's own sale, and a vault would
///        charge the overstatement to the leaver (DEC-118 item 2, DEC-141) or the manager (D-29).
///      - A tier below the market that holds only the output token below its price offers no arbitrage either. It
///        outbids the honest tier whenever its discount is smaller than the honest tier's loss on the sale, then meets
///        the maximum against its own mid, so it buys a sale beyond the caller's maximum that DEC-148 would refuse
///        (5.3% below the market under a 1% maximum on a fork, reported as a 0.35% loss). Ranked by output, the fund
///        still receives at least what the honest tier pays, so the loss the maximum misses is bounded by the honest
///        tier's own loss. Ranking the tiers by the maximum against each tier's own mid (review round 2) removed that
///        bound: such a tier won every sale whose maximum no honest tier meets, at its own price (a tenth of the
///        market on a fork), so that ranking was withdrawn (review round 3).
///      - When the sale exceeds what every honest tier can fill, such a tier below the market is the only one that
///        fills, so it is chosen, meets the maximum against its own mid, and buys the input at its own price.
///      No selection within the register closes this: DEC-153 fixes the reference at the chosen pool's mid. Review
///      round 2 proposed measuring every empty-route sale against the mid of the pair's tier with the most in-range
///      liquidity, but that is the liquidity at one tick: a one-tick position at a third party's mid outweighs an
///      honest tier about 1,000 tokens deep for about 0.1 of each token (fork). Depth summed over a price band is
///      bought the same way with one-sided depth on the side of the mid away from the market, which arbitrage never
///      takes. Proposed instead (review round 4): the tier with the most depth on both sides of its mid (the smaller
///      of its two token reserves within a band around the mid); one side of an off-market mid always faces the
///      market, so depth posted there to win the reference goes to arbitrage and moves the mid back. Until ruled, a
///      vault must not charge any cost measured against the `spotOut` of an empty-route sale (DEC-118 item 2, the
///      DEC-141 excess, D-29), with or without a maximum; the maximum still refuses a sale (DEC-148).
contract UniswapV3SwapAdapter is AdapterGuard, EIP712, ISwapAdapter {
    using SafeERC20 for IERC20;

    /// @notice EIP-712 type of a signed API route (ISwapAdapter.ApiRoute).
    bytes32 public constant ROUTE_TYPEHASH = keccak256(
        "SwapRoute(address tokenIn,address tokenOut,bytes32 legsHash,uint256 quotedAmountIn,uint256 minAmountOut,uint256 deadline)"
    );

    /// @notice Gas forwarded to each QuoterV2 call when the adapter compares fee tiers (DEC-153, D-21).
    /// @dev OPEN (swap research, open question 3): 1,000,000 bounds a griefed tier; the deep tiers of the MVP pairs
    ///      quoted at 105k to 192k gas for trades up to 100 WETH on both chains (2026-10-02).
    uint256 public constant QUOTE_GAS_CAP = 1_000_000;

    /// @notice Most paths (splits) an API route may have.
    uint256 public constant MAX_LEGS = 4;

    /// @notice Most hops a path of an API route may have.
    uint256 public constant MAX_HOPS = 3;

    uint256 private constant BPS = 10_000;

    /// @dev Packed V3 path layout: a 20-byte token, then 23 bytes (3-byte fee and 20-byte token) per hop.
    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant HOP_SIZE = 23;

    /// @inheritdoc ISwapAdapter
    address public immutable vault;

    /// @inheritdoc ISwapAdapter
    address public immutable baseToken;

    /// @inheritdoc ISwapAdapter
    address public immutable routeSigner;

    /// @notice The Uniswap V3 factory every pool of every route must come from.
    IUniswapV3Factory public immutable v3Factory;

    /// @notice SwapRouter02 of this chain, wired to `v3Factory`.
    ISwapRouter02 public immutable swapRouter;

    /// @notice QuoterV2 of this chain, wired to `v3Factory`.
    IQuoterV2 public immutable quoterV2;

    /// @inheritdoc ISwapAdapter
    mapping(address token => bool) public isMandateToken;

    /// @notice The vault or the V3 factory address is zero, or a Mandate token is zero.
    error ZeroAddress();

    /// @notice SwapRouter02 or QuoterV2 is not wired to `v3Factory`.
    error WiringMismatch();

    /// @param vault_ This chain's Spoke Vault, the only caller of `swap` and `swapDirect` and the receiver of outputs.
    /// @param guardian_ Immutable guardian of the quarantine and deprecation flags (DEC-021, DEC-058; R128-31: the
    ///        factory's guardian).
    /// @param baseToken_ The vault's base token; must be one of `mandateTokens_`.
    /// @param mandateTokens_ This chain's Mandate tokens (DEC-136 item 2): the only tokens a swap may take in or pay
    ///        out; an API route's intermediate hops may be any token (DEC-173).
    /// @param v3Factory_ The chain's Uniswap V3 factory.
    /// @param swapRouter_ The chain's SwapRouter02.
    /// @param quoterV2_ The chain's QuoterV2.
    /// @param routeSigner_ The Pool Party API route signer (D-01); zero for a fund without API routes (DEC-052).
    constructor(
        address vault_,
        address guardian_,
        address baseToken_,
        address[] memory mandateTokens_,
        address v3Factory_,
        address swapRouter_,
        address quoterV2_,
        address routeSigner_
    ) AdapterGuard(guardian_) EIP712("Pool Party Swap Adapter", "1") {
        if (vault_ == address(0) || v3Factory_ == address(0)) revert ZeroAddress();
        if (
            IPeripheryImmutableState(swapRouter_).factory() != v3Factory_
                || IPeripheryImmutableState(quoterV2_).factory() != v3Factory_
        ) revert WiringMismatch();
        vault = vault_;
        baseToken = baseToken_;
        routeSigner = routeSigner_;
        v3Factory = IUniswapV3Factory(v3Factory_);
        swapRouter = ISwapRouter02(swapRouter_);
        quoterV2 = IQuoterV2(quoterV2_);
        for (uint256 i; i < mandateTokens_.length; ++i) {
            if (mandateTokens_[i] == address(0)) revert ZeroAddress();
            isMandateToken[mandateTokens_[i]] = true;
        }
        if (!isMandateToken[baseToken_]) revert TokenNotInMandate(baseToken_);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Swaps (vault only)
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISwapAdapter
    /// @dev DEC-153 for an empty route; DEC-129, DEC-136 and D-01/D-02 for a signed one. DEC-142: the stricter of the
    ///      caller's maximum loss and the API minimum, scaled to the amount actually sold.
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint16 maxLossBps, bytes calldata route)
        external
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut)
    {
        _requireSwap(tokenIn, tokenOut, amountIn);
        if (route.length == 0) {
            (uint24 fee,) = _bestDirectFee(tokenIn, tokenOut, amountIn);
            return _swapDirect(tokenIn, tokenOut, amountIn, fee, maxLossBps);
        }

        ApiRoute memory r = abi.decode(route, (ApiRoute));
        bytes32 legsHash = _verify(r, tokenIn, tokenOut);
        uint256[] memory amounts = _split(amountIn, r.weightsBps);
        // Every pool's spot price is read before any leg trades (DEC-118: the price before the swap).
        for (uint256 i; i < amounts.length; ++i) {
            spotOut += _spotAlong(r.paths[i], amounts[i], tokenIn, tokenOut);
        }
        minOut = _minOut(spotOut, maxLossBps, Math.mulDiv(r.minAmountOut, amountIn, r.quotedAmountIn));
        amountOut = _execute(tokenIn, r.paths, amounts, amountIn, minOut);
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut, spotOut, 0, legsHash);
    }

    /// @inheritdoc ISwapAdapter
    function swapDirect(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint16 maxLossBps)
        external
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut)
    {
        _requireSwap(tokenIn, tokenOut, amountIn);
        return _swapDirect(tokenIn, tokenOut, amountIn, fee, maxLossBps);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Reads (anyone)
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc ISwapAdapter
    function bestDirectFee(address tokenIn, address tokenOut, uint256 amountIn)
        external
        returns (uint24 fee, uint256 quotedOut)
    {
        _requirePair(tokenIn, tokenOut);
        if (amountIn == 0) revert ZeroAmount();
        return _bestDirectFee(tokenIn, tokenOut, amountIn);
    }

    /// @inheritdoc ISwapAdapter
    function spotValue(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee)
        external
        view
        returns (uint256)
    {
        _requirePair(tokenIn, tokenOut);
        return _spotAlong(abi.encodePacked(tokenIn, fee, tokenOut), amountIn, tokenIn, tokenOut);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev Vault only; DEC-056/DEC-058: only a swap into the base token passes while paused or deprecated.
    function _requireSwap(address tokenIn, address tokenOut, uint256 amountIn) private view {
        if (msg.sender != vault) revert NotVault(msg.sender);
        if (tokenOut != baseToken) _requireEntryAllowed();
        if (amountIn == 0) revert ZeroAmount();
        _requirePair(tokenIn, tokenOut);
    }

    /// @dev DEC-136 item 2: only tokens the Mandate has.
    function _requirePair(address tokenIn, address tokenOut) private view {
        if (tokenIn == tokenOut) revert IdenticalTokens(tokenIn);
        if (!isMandateToken[tokenIn]) revert TokenNotInMandate(tokenIn);
        if (!isMandateToken[tokenOut]) revert TokenNotInMandate(tokenOut);
    }

    /// @dev One hop in the direct pool of `fee`; the pool must exist (checked while reading its spot price).
    function _swapDirect(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee, uint16 maxLossBps)
        private
        returns (uint256 amountOut, uint256 spotOut, uint256 minOut)
    {
        bytes[] memory paths = new bytes[](1);
        paths[0] = abi.encodePacked(tokenIn, fee, tokenOut);
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = amountIn;
        spotOut = _spotAlong(paths[0], amountIn, tokenIn, tokenOut);
        minOut = _minOut(spotOut, maxLossBps, 0);
        amountOut = _execute(tokenIn, paths, amounts, amountIn, minOut);
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut, spotOut, fee, bytes32(0));
    }

    /// @dev DEC-153 item 2: the highest QuoterV2 output among the factory pools of the direct pair in the four tiers,
    ///      skipping missing pools and pools without in-range liquidity; each quote capped at `QUOTE_GAS_CAP` (D-21).
    ///      - A quote counts only if it fills the whole input. For an exact input QuoterV2 returns the output and
    ///        drops the amount the pool took, so a tier whose liquidity runs out quotes what it drained and could
    ///        outbid a tier that fills, while the swap in it would revert `PartialFill`. A V3 pool stops an exact-input
    ///        swap only when the input is spent or the price reaches the limit, and the quote uses the widest limit,
    ///        so a quote whose price ends at that limit is a partial fill and the tier is skipped.
    ///      - A tier that fills counts even at a zero output: a dust input sells, as it does through `swapDirect`
    ///        (DEC-129 item 3, "em qualquer quantia"), and the first such tier wins ties.
    ///      - The caller's maximum loss plays no part in the choice; the swap applies it to the chosen tier only.
    ///        Measured against each tier's own mid price, a maximum cannot rank tiers: whoever creates or pushes a
    ///        tier sets its mid, so a tier priced below the market would meet it and win every sale whose maximum no
    ///        honest tier meets, at its own price (see the contract's open note).
    function _bestDirectFee(address tokenIn, address tokenOut, uint256 amountIn)
        private
        returns (uint24 fee, uint256 best)
    {
        uint24[4] memory tiers = [uint24(100), 500, 3000, 10_000];
        // QuoterV2's limit for `sqrtPriceLimitX96 == 0` (V4's MIN/MAX_SQRT_PRICE equal V3's MIN/MAX_SQRT_RATIO).
        uint160 limit = tokenIn < tokenOut ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        for (uint256 i; i < 4; ++i) {
            address pool = v3Factory.getPool(tokenIn, tokenOut, tiers[i]);
            if (pool == address(0) || IUniswapV3Pool(pool).liquidity() == 0) continue;
            try quoterV2.quoteExactInputSingle{gas: QUOTE_GAS_CAP}(
                IQuoterV2.QuoteExactInputSingleParams(tokenIn, tokenOut, amountIn, tiers[i], 0)
            ) returns (
                uint256 out, uint160 sqrtPriceX96After, uint32, uint256
            ) {
                if (sqrtPriceX96After != limit && (fee == 0 || out > best)) (best, fee) = (out, tiers[i]);
            } catch {}
        }
        if (fee == 0) revert NoRoute(tokenIn, tokenOut);
    }

    /// @dev Deadline, leg structure and signature of an API route (D-01). Paths are checked hop by hop in `_spotAlong`.
    ///      A zero `routeSigner` matches no signature: SignatureChecker never recovers address(0) and address(0) has no
    ///      EIP-1271 code.
    function _verify(ApiRoute memory r, address tokenIn, address tokenOut) private view returns (bytes32 legsHash) {
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > r.deadline) revert RouteExpired(r.deadline);
        uint256 n = r.paths.length;
        if (n == 0 || n > MAX_LEGS || r.weightsBps.length != n || r.quotedAmountIn == 0) revert InvalidLegs();
        uint256 sum;
        for (uint256 i; i < n; ++i) {
            if (r.weightsBps[i] == 0) revert InvalidLegs();
            sum += r.weightsBps[i];
        }
        if (sum != BPS) revert InvalidLegs();
        legsHash = keccak256(abi.encode(r.paths, r.weightsBps));
        bytes32 digest = _hashTypedDataV4(
            keccak256(
                abi.encode(ROUTE_TYPEHASH, tokenIn, tokenOut, legsHash, r.quotedAmountIn, r.minAmountOut, r.deadline)
            )
        );
        if (!SignatureChecker.isValidSignatureNow(routeSigner, digest, r.signature)) revert InvalidRouteSignature();
    }

    /// @dev The input per leg by weight; the last leg takes the rounding remainder, so the legs sum to `amountIn`.
    function _split(uint256 amountIn, uint16[] memory weightsBps) private pure returns (uint256[] memory amounts) {
        uint256 n = weightsBps.length;
        amounts = new uint256[](n);
        uint256 left = amountIn;
        for (uint256 i; i + 1 < n; ++i) {
            amounts[i] = Math.mulDiv(amountIn, weightsBps[i], BPS);
            left -= amounts[i];
        }
        amounts[n - 1] = left;
    }

    /// @dev Minimum output: the API minimum (0 for a direct swap) or, when the caller set a maximum loss (1 to 9,999
    ///      bps, D-23), the stricter of it and `spotOut` less that loss (DEC-142 item 3).
    function _minOut(uint256 spotOut, uint16 maxLossBps, uint256 apiMin) private pure returns (uint256) {
        if (maxLossBps == 0 || maxLossBps >= BPS) return apiMin;
        return Math.max(apiMin, Math.mulDiv(spotOut, BPS - maxLossBps, BPS));
    }

    /// @dev Custody (ISwapAdapter): pulls exactly `amountIn` from the vault, approves the router for exactly that
    ///      amount, runs every leg with the vault as recipient, clears the approval, and requires the legs to have
    ///      spent exactly the pulled input. Any balance the adapter held before stays untouched by construction.
    function _execute(address tokenIn, bytes[] memory paths, uint256[] memory amounts, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 amountOut)
    {
        IERC20 token = IERC20(tokenIn);
        uint256 held = token.balanceOf(address(this));
        token.safeTransferFrom(vault, address(this), amountIn);
        token.forceApprove(address(swapRouter), amountIn);
        for (uint256 i; i < paths.length; ++i) {
            // A leg whose share of a dust amount rounds to zero is skipped: SwapRouter02 reads `amountIn == 0` as
            // Constants.CONTRACT_BALANCE and would sell the router's own balance of the token, paid by the router (or
            // revert when it holds none).
            if (amounts[i] == 0) continue;
            amountOut += swapRouter.exactInput(ISwapRouter02.ExactInputParams(paths[i], vault, amounts[i], 0));
        }
        token.forceApprove(address(swapRouter), 0);
        uint256 left = token.balanceOf(address(this));
        if (left != held) revert PartialFill(held, left);
        if (amountOut < minOut) revert InsufficientOutput(amountOut, minOut);
    }

    /// @dev Validates `path` (from `tokenIn` to `tokenOut`, 1 to `MAX_HOPS` hops, the four tiers only, every pool
    ///      deployed by `v3Factory`) and returns `amountIn` valued along it at each pool's current `sqrtPriceX96`,
    ///      without fee or price impact (DEC-118, D-19, D-20). DEC-173: only the first and last tokens must be Mandate
    ///      tokens, and the caller checked both (`_requirePair`); an intermediate hop token may be any token, since it
    ///      enters and leaves the route within the swap and never stays in the fund.
    function _spotAlong(bytes memory path, uint256 amountIn, address tokenIn, address tokenOut)
        private
        view
        returns (uint256 out)
    {
        uint256 len = path.length;
        if (len < ADDR_SIZE + HOP_SIZE || (len - ADDR_SIZE) % HOP_SIZE != 0 || len > ADDR_SIZE + HOP_SIZE * MAX_HOPS) {
            revert InvalidPath();
        }
        address a = _readAddress(path, 0);
        if (a != tokenIn) revert InvalidPath();
        out = amountIn;
        for (uint256 off = ADDR_SIZE; off < len; off += HOP_SIZE) {
            uint24 fee = _readFee(path, off);
            address b = _readAddress(path, off + 3);
            if (fee != 100 && fee != 500 && fee != 3000 && fee != 10_000) revert InvalidFee(fee);
            address pool = v3Factory.getPool(a, b, fee);
            if (pool == address(0)) revert PoolNotFound(a, b, fee);
            (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
            // Anyone can create a factory pool without initializing it: no price, no mid value, no swap.
            if (sqrtPriceX96 == 0) revert PoolNotFound(a, b, fee);
            out = _atSpot(out, sqrtPriceX96, a < b);
            a = b;
        }
        if (a != tokenOut) revert InvalidPath();
    }

    /// @dev `amount` of token0 in token1 (`zeroForOne`) or the reverse at `sqrtPriceX96`; the rounding of Uniswap's
    ///      OracleLibrary.getQuoteAtTick.
    function _atSpot(uint256 amount, uint160 sqrtPriceX96, bool zeroForOne) private pure returns (uint256) {
        if (sqrtPriceX96 <= type(uint128).max) {
            uint256 ratioX192 = uint256(sqrtPriceX96) * sqrtPriceX96;
            return zeroForOne ? Math.mulDiv(ratioX192, amount, 1 << 192) : Math.mulDiv(1 << 192, amount, ratioX192);
        }
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return zeroForOne ? Math.mulDiv(ratioX128, amount, 1 << 128) : Math.mulDiv(1 << 128, amount, ratioX128);
    }

    function _readAddress(bytes memory p, uint256 off) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(p, 32), off)))
        }
    }

    function _readFee(bytes memory p, uint256 off) private pure returns (uint24 f) {
        assembly ("memory-safe") {
            f := shr(232, mload(add(add(p, 32), off)))
        }
    }
}
