// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockPermit2} from "./MockPermit2.sol";

/// @notice One contract playing the Uniswap V4 PoolManager, PositionManager and StateView for unit tests.
/// @dev Mirrors the parts of V4 the adapter relies on: fee growth per pool (the same value inside every range, set by
///      the test), `Position.update` fee realization, `Pool.modifyLiquidity` principal branches and rounding, a
///      per-currency delta ledger that must be zero when the unlock ends (`CurrencyNotSettled`), explicit-amount
///      `SETTLE` through Permit2 and `TAKE`, and an exact-input swap at a fixed rate. The test mints the tokens that
///      back fees and swap outputs to this contract.
contract MockV4 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct PoolState {
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowth0;
        uint256 feeGrowth1;
    }

    struct PositionState {
        uint128 liquidity;
        uint256 last0;
        uint256 last1;
    }

    struct TokenState {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        address owner;
    }

    uint256 private constant Q128 = 1 << 128;

    MockPermit2 public immutable permit2;
    uint256 public nextTokenId = 1;

    /// @notice Extra wei the mock adds to realized fees of token0, to prove the adapter's exact accounting.
    uint256 public feeSkew0;
    /// @notice Output per input, 1e18 = 1:1.
    uint256 public swapRate = 1e18;
    /// @notice Share of the requested input a swap uses, in bps (below 10,000 simulates hitting the price limit).
    uint256 public swapFillBps = 10_000;

    mapping(bytes32 poolId => PoolState) public pools;
    mapping(bytes32 positionId => PositionState) internal _positions;
    mapping(uint256 tokenId => TokenState) internal _tokens;
    mapping(address currency => int256) public deltas;
    address[] internal _touched;
    address internal _locker;
    address internal _synced;
    uint256 internal _syncedReserve;

    error CurrencyNotSettled();
    error DeadlinePassed(uint256 deadline);
    error NotApproved(address caller);
    error CannotUpdateEmptyPosition();
    error MaximumAmountExceeded();
    error MinimumAmountInsufficient();
    error UnsupportedAction(uint256 action);
    error OpenDeltaUnsupported();
    error NotLocker();

    constructor(MockPermit2 permit2_) {
        permit2 = permit2_;
    }

    // ------------------------------------------------------------------ test controls

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external {
        bytes32 id = PoolId.unwrap(key.toId());
        pools[id].sqrtPriceX96 = sqrtPriceX96;
        pools[id].tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
    }

    function setTick(bytes32 poolId, int24 tick) external {
        pools[poolId].tick = tick;
        pools[poolId].sqrtPriceX96 = TickMath.getSqrtPriceAtTick(tick);
    }

    function accrueFees(bytes32 poolId, uint256 growth0, uint256 growth1) external {
        unchecked {
            pools[poolId].feeGrowth0 += growth0;
            pools[poolId].feeGrowth1 += growth1;
        }
    }

    function setFeeSkew0(uint256 skew) external {
        feeSkew0 = skew;
    }

    function setSwap(uint256 rate, uint256 fillBps) external {
        swapRate = rate;
        swapFillBps = fillBps;
    }

    // ------------------------------------------------------------------ StateView

    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        PoolState memory s = pools[PoolId.unwrap(poolId)];
        return (s.sqrtPriceX96, s.tick, 0, 500);
    }

    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128, uint256, uint256)
    {
        PositionState memory p = _positions[_positionId(PoolId.unwrap(poolId), owner, tickLower, tickUpper, salt)];
        return (p.liquidity, p.last0, p.last1);
    }

    function getFeeGrowthInside(PoolId poolId, int24, int24) external view returns (uint256, uint256) {
        PoolState memory s = pools[PoolId.unwrap(poolId)];
        return (s.feeGrowth0, s.feeGrowth1);
    }

    // ------------------------------------------------------------------ PositionManager

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _locker = msg.sender;
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        for (uint256 i; i < actions.length; ++i) {
            _handle(uint8(actions[i]), params[i]);
        }
        _checkSettled();
        _locker = address(0);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _tokens[tokenId].owner;
    }

    function _handle(uint256 action, bytes memory p) internal {
        if (action == Actions.MINT_POSITION) {
            (PoolKey memory key, int24 lo, int24 hi, uint256 liq, uint128 max0, uint128 max1, address owner,) =
                abi.decode(p, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes));
            uint256 tokenId = nextTokenId++;
            _tokens[tokenId] = TokenState(key, lo, hi, owner);
            (int256 p0, int256 p1) = _modify(tokenId, liq.toInt256());
            if (uint256(-p0) > max0 || uint256(-p1) > max1) revert MaximumAmountExceeded();
        } else if (action == Actions.INCREASE_LIQUIDITY) {
            (uint256 tokenId, uint256 liq, uint128 max0, uint128 max1,) =
                abi.decode(p, (uint256, uint256, uint128, uint128, bytes));
            _requireOwner(tokenId);
            (int256 p0, int256 p1) = _modify(tokenId, liq.toInt256());
            if (uint256(-p0) > max0 || uint256(-p1) > max1) revert MaximumAmountExceeded();
        } else if (action == Actions.DECREASE_LIQUIDITY) {
            (uint256 tokenId, uint256 liq, uint128 min0, uint128 min1,) =
                abi.decode(p, (uint256, uint256, uint128, uint128, bytes));
            _requireOwner(tokenId);
            (int256 p0, int256 p1) = _modify(tokenId, -liq.toInt256());
            if (uint256(p0) < min0 || uint256(p1) < min1) revert MinimumAmountInsufficient();
        } else if (action == Actions.BURN_POSITION) {
            (uint256 tokenId, uint128 min0, uint128 min1,) = abi.decode(p, (uint256, uint128, uint128, bytes));
            _requireOwner(tokenId);
            uint128 liq = _positions[_tokenPositionId(tokenId)].liquidity;
            if (liq > 0) {
                (int256 p0, int256 p1) = _modify(tokenId, -int256(uint256(liq)));
                if (uint256(p0) < min0 || uint256(p1) < min1) revert MinimumAmountInsufficient();
            }
            delete _tokens[tokenId];
        } else if (action == Actions.SETTLE) {
            (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(p, (Currency, uint256, bool));
            if (!payerIsUser || amount == 0) revert OpenDeltaUnsupported();
            permit2.transferFrom(_locker, address(this), amount.toUint160(), Currency.unwrap(currency));
            _account(Currency.unwrap(currency), amount.toInt256());
        } else if (action == Actions.TAKE) {
            (Currency currency, address recipient, uint256 amount) = abi.decode(p, (Currency, address, uint256));
            if (amount == 0) revert OpenDeltaUnsupported();
            IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
            _account(Currency.unwrap(currency), -amount.toInt256());
        } else {
            revert UnsupportedAction(action);
        }
    }

    /// @dev `Position.update` then `Pool.modifyLiquidity`; returns the principal part of the caller delta.
    function _modify(uint256 tokenId, int256 liquidityDelta) internal returns (int256 p0, int256 p1) {
        TokenState memory t = _tokens[tokenId];
        bytes32 poolId = PoolId.unwrap(t.key.toId());
        PoolState memory pool = pools[poolId];
        PositionState storage pos = _positions[_tokenPositionId(tokenId)];
        if (liquidityDelta == 0 && pos.liquidity == 0) revert CannotUpdateEmptyPosition();

        uint256 fees0;
        uint256 fees1;
        unchecked {
            fees0 = Math.mulDiv(pool.feeGrowth0 - pos.last0, pos.liquidity, Q128);
            fees1 = Math.mulDiv(pool.feeGrowth1 - pos.last1, pos.liquidity, Q128);
        }
        if (fees0 != 0) fees0 += feeSkew0;
        pos.last0 = pool.feeGrowth0;
        pos.last1 = pool.feeGrowth1;
        pos.liquidity = (int256(uint256(pos.liquidity)) + liquidityDelta).toUint256().toUint128();

        if (liquidityDelta != 0) {
            int128 l = liquidityDelta.toInt128();
            uint160 sa = TickMath.getSqrtPriceAtTick(t.tickLower);
            uint160 sb = TickMath.getSqrtPriceAtTick(t.tickUpper);
            if (pool.tick < t.tickLower) {
                p0 = SqrtPriceMath.getAmount0Delta(sa, sb, l);
            } else if (pool.tick < t.tickUpper) {
                p0 = SqrtPriceMath.getAmount0Delta(pool.sqrtPriceX96, sb, l);
                p1 = SqrtPriceMath.getAmount1Delta(sa, pool.sqrtPriceX96, l);
            } else {
                p1 = SqrtPriceMath.getAmount1Delta(sa, sb, l);
            }
        }
        _account(Currency.unwrap(t.key.currency0), p0 + fees0.toInt256());
        _account(Currency.unwrap(t.key.currency1), p1 + fees1.toInt256());
    }

    // ------------------------------------------------------------------ PoolManager

    function unlock(bytes calldata data) external returns (bytes memory result) {
        _locker = msg.sender;
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        _checkSettled();
        _locker = address(0);
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta)
    {
        if (msg.sender != _locker) revert NotLocker();
        uint256 amountIn = uint256(-params.amountSpecified) * swapFillBps / 10_000;
        uint256 amountOut = amountIn * swapRate / 1e18;
        (Currency cIn, Currency cOut) =
            params.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        _account(Currency.unwrap(cIn), -amountIn.toInt256());
        _account(Currency.unwrap(cOut), amountOut.toInt256());
        int128 dIn = -amountIn.toInt256().toInt128();
        int128 dOut = amountOut.toInt256().toInt128();
        return params.zeroForOne ? toBalanceDelta(dIn, dOut) : toBalanceDelta(dOut, dIn);
    }

    function sync(Currency currency) external {
        _synced = Currency.unwrap(currency);
        _syncedReserve = IERC20(_synced).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(_synced).balanceOf(address(this)) - _syncedReserve;
        _account(_synced, paid.toInt256());
    }

    function take(Currency currency, address to, uint256 amount) external {
        if (msg.sender != _locker) revert NotLocker();
        IERC20(Currency.unwrap(currency)).safeTransfer(to, amount);
        _account(Currency.unwrap(currency), -amount.toInt256());
    }

    // ------------------------------------------------------------------ internals

    function _requireOwner(uint256 tokenId) internal view {
        if (_tokens[tokenId].owner != _locker) revert NotApproved(_locker);
    }

    function _account(address currency, int256 delta) internal {
        if (delta == 0) return;
        if (deltas[currency] == 0) _touched.push(currency);
        deltas[currency] += delta;
    }

    function _checkSettled() internal {
        for (uint256 i; i < _touched.length; ++i) {
            if (deltas[_touched[i]] != 0) revert CurrencyNotSettled();
        }
        delete _touched;
    }

    function _tokenPositionId(uint256 tokenId) internal view returns (bytes32) {
        TokenState memory t = _tokens[tokenId];
        return _positionId(PoolId.unwrap(t.key.toId()), address(this), t.tickLower, t.tickUpper, bytes32(tokenId));
    }

    function _positionId(bytes32 poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(poolId, owner, tickLower, tickUpper, salt));
    }
}
