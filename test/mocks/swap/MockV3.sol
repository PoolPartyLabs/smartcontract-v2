// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IQuoterV2} from "@uniswap/v3-periphery/contracts/interfaces/IQuoterV2.sol";
import {MockToken} from "../v4/MockToken.sol";

/// @notice Uniswap V3 pool stand-in for the swap adapter unit tests: a mid price (`sqrtPriceX96`), in-range liquidity
///         and a deterministic output (`out`) that QuoterV2 and SwapRouter02 stand-ins share, so a quote equals the
///         execution in the same state.
/// @dev `out` = mid value less the pool fee, less `impactBps`. After an executed swap the mid price moves `driftBps`
///      against the trader, so a test can tell a spot read before the trade from one read after it. `mode` makes the
///      quote revert or burn every unit of gas it is given (an empty or dust tier, swap research section 5).
///      `fillableIn` (0 = unlimited) is the most input the in-range liquidity takes: a larger exact-input swap stops at
///      the price limit having spent only that much (a drained tier).
contract MockV3Pool {
    enum Mode {
        Normal,
        QuoteReverts,
        QuoteBurnsGas
    }

    address public immutable token0;
    address public immutable token1;
    uint24 public immutable fee;
    uint160 public sqrtPriceX96;
    uint128 public liquidity;
    uint256 public impactBps;
    uint256 public driftBps;
    uint256 public fillableIn;
    Mode public mode;

    constructor(address tokenA, address tokenB, uint24 fee_, uint160 sqrtPriceX96_, uint128 liquidity_) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        fee = fee_;
        sqrtPriceX96 = sqrtPriceX96_;
        liquidity = liquidity_;
    }

    function setLiquidity(uint128 liquidity_) external {
        liquidity = liquidity_;
    }

    function setImpactBps(uint256 impactBps_) external {
        impactBps = impactBps_;
    }

    function setDriftBps(uint256 driftBps_) external {
        driftBps = driftBps_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setFillableIn(uint256 fillableIn_) external {
        fillableIn = fillableIn_;
    }

    /// @notice The part of `amountIn` an exact-input swap spends before the price reaches the limit.
    function filled(uint256 amountIn) public view returns (uint256) {
        return fillableIn != 0 && amountIn > fillableIn ? fillableIn : amountIn;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (sqrtPriceX96, 0, 0, 0, 0, 0, true);
    }

    /// @notice Mid value of `amountIn` of `tokenIn` in the other token: the exact floor of `amountIn * P` or
    ///         `amountIn / P`, with `P = (sqrtPriceX96 / 2^96)^2`.
    /// @dev Never squares `sqrtPriceX96` in 256 bits, so it holds over the whole V3 price range (for `amountIn` below
    ///      2^96) and serves as the reference of the adapter's `_atSpot`. token0 -> token1: `amountIn * sqrtPriceX96` is
    ///      exact, then one 512-bit `mulDiv`. token1 -> token0: two nested floor divisions by integers equal one
    ///      division by their product.
    function mid(address tokenIn, uint256 amountIn) public view returns (uint256) {
        uint256 s = sqrtPriceX96;
        return tokenIn == token0 ? Math.mulDiv(amountIn * s, s, 1 << 192) : Math.mulDiv(amountIn, 1 << 192, s) / s;
    }

    /// @notice Output of an exact-input swap of `amountIn` of `tokenIn` in the current state.
    function out(address tokenIn, uint256 amountIn) public view returns (uint256) {
        return mid(tokenIn, amountIn) * (1e6 - fee) / 1e6 * (10_000 - impactBps) / 10_000;
    }

    /// @notice Executes the swap's effect on the price; called by the router stand-in.
    function swapped(address tokenIn) external {
        if (driftBps == 0) return;
        // Selling token0 lowers the price of token0 (sqrtPrice falls); selling token1 raises it.
        sqrtPriceX96 = tokenIn == token0
            ? uint160(uint256(sqrtPriceX96) * (10_000 - driftBps) / 10_000)
            : uint160(uint256(sqrtPriceX96) * (10_000 + driftBps) / 10_000);
    }
}

/// @notice Uniswap V3 factory stand-in: `getPool` in either token order, like the real one.
contract MockV3Factory {
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;

    function createPool(address tokenA, address tokenB, uint24 fee, uint160 sqrtPriceX96, uint128 liquidity)
        external
        returns (MockV3Pool pool)
    {
        pool = new MockV3Pool(tokenA, tokenB, fee, sqrtPriceX96, liquidity);
        getPool[tokenA][tokenB][fee] = address(pool);
        getPool[tokenB][tokenA][fee] = address(pool);
    }
}

/// @notice QuoterV2 stand-in: quotes a single pool from the shared pricing model and records which pools it quoted.
/// @dev Like QuoterV2 for an exact input, a quote of a drained tier returns the output of the part the pool took and
///      the price limit as `sqrtPriceX96After`; it does not report the input left unspent.
contract MockQuoterV2 {
    /// @notice V3 TickMath.MIN_SQRT_RATIO and MAX_SQRT_RATIO: QuoterV2 swaps to one past them when given no limit.
    uint160 public constant MIN_SQRT_RATIO = 4_295_128_739;
    uint160 public constant MAX_SQRT_RATIO = 1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_342;

    MockV3Factory public immutable factory;
    mapping(address pool => uint256) public quotes;
    mapping(uint256 => uint256) private _burn;

    constructor(MockV3Factory factory_) {
        factory = factory_;
    }

    function quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32, uint256)
    {
        MockV3Pool pool = MockV3Pool(factory.getPool(params.tokenIn, params.tokenOut, params.fee));
        quotes[address(pool)]++;
        if (pool.mode() == MockV3Pool.Mode.QuoteReverts) revert("quote reverted");
        if (pool.mode() == MockV3Pool.Mode.QuoteBurnsGas) {
            // An empty or dust tier walking the tick bitmap: consumes all the gas it was given.
            for (uint256 i;; ++i) {
                _burn[i] = i + 1;
            }
        }
        uint256 used = pool.filled(params.amountIn);
        amountOut = pool.out(params.tokenIn, used);
        if (used == params.amountIn) sqrtPriceX96After = pool.sqrtPriceX96();
        else sqrtPriceX96After = params.tokenIn < params.tokenOut ? MIN_SQRT_RATIO + 1 : MAX_SQRT_RATIO - 1;
    }
}

/// @notice SwapRouter02 stand-in: `exactInput` along a packed path through factory pools, paying the first pool from
///         the caller with `transferFrom` and minting the output to the recipient. A hop spends only what its pool
///         fills (`MockV3Pool.fillableIn`), and `partialBps` makes the first hop spend less than the input (a fill
///         stopped at a price limit).
contract MockSwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    MockV3Factory public immutable factory;
    uint256 public partialBps;
    uint256 public calls;

    constructor(MockV3Factory factory_) {
        factory = factory_;
    }

    function setPartialBps(uint256 partialBps_) external {
        partialBps = partialBps_;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut) {
        calls++;
        // UniswapV3Pool.swap: `require(amountSpecified != 0, 'AS')`.
        require(params.amountIn != 0, "AS");
        bytes memory path = params.path;
        address tokenIn = _addr(path, 0);
        amountOut = params.amountIn - params.amountIn * partialBps / 10_000;
        address a = tokenIn;
        for (uint256 off = 20; off < path.length; off += 23) {
            uint24 fee = _fee(path, off);
            address b = _addr(path, off + 3);
            MockV3Pool pool = MockV3Pool(factory.getPool(a, b, fee));
            require(address(pool) != address(0), "no pool");
            uint256 used = pool.filled(amountOut);
            // The caller pays the first pool what it took, in the pool's callback.
            if (off == 20) require(IERC20(tokenIn).transferFrom(msg.sender, address(pool), used), "pull failed");
            amountOut = pool.out(a, used);
            pool.swapped(a);
            a = b;
        }
        require(amountOut >= params.amountOutMinimum, "Too little received");
        MockToken(a).mint(params.recipient, amountOut);
    }

    function _addr(bytes memory p, uint256 off) private pure returns (address a) {
        assembly ("memory-safe") {
            a := shr(96, mload(add(add(p, 32), off)))
        }
    }

    function _fee(bytes memory p, uint256 off) private pure returns (uint24 f) {
        assembly ("memory-safe") {
            f := shr(232, mload(add(add(p, 32), off)))
        }
    }
}

/// @notice Periphery contract wired to another factory, for the constructor's wiring check.
contract MockMiswiredPeriphery {
    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }
}

/// @notice A contract route signer (EIP-1271), e.g. a multisig holding the API key: accepts what `owner` signed.
contract MockRouteSigner1271 {
    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    function isValidSignature(bytes32 hash, bytes calldata signature) external view returns (bytes4) {
        (bytes32 r, bytes32 s) = abi.decode(signature[:64], (bytes32, bytes32));
        uint8 v = uint8(signature[64]);
        return ecrecover(hash, v, r, s) == owner ? bytes4(0x1626ba7e) : bytes4(0xffffffff);
    }
}
