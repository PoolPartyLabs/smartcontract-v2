// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Slot0} from "@uniswap/v4-core/src/types/Slot0.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {MockPermit2} from "../../../mocks/v4/MockPermit2.sol";

/// @notice Uniswap V4 PoolManager, PositionManager and StateView in one contract for the security proofs of concept,
///         with the pool mathematics of the deployed protocol: every swap and liquidity change runs through v4-core's
///         own `Pool` library (tick bitmap, tick crossing, `SwapMath`, `Position.update`, fee growth), the library the
///         live PoolManager is built on.
/// @dev Why not `test/mocks/v4/MockV4.sol`: that mock swaps at a fixed rate and moves its price only through a test
///      control, which cannot show what a price manipulation costs. Here the price moves only through swaps, swaps
///      pay the pool's LP fee, and liquidity of several owners shares the pool, so a proof of concept measures the
///      attacker's real cost and profit without a network. The PoolManager and PositionManager contracts themselves
///      are pinned to solc 0.8.26 and cannot be compiled in this repository; only their thin shells (unlock and delta
///      bookkeeping, the PositionManager action router) are re-implemented here, after `MockV4`.
/// @dev Surfaces mirrored: `IPoolManager.unlock / swap / sync / settle / take`, `IPositionManager.modifyLiquidities`
///      with `MINT_POSITION`, `INCREASE_LIQUIDITY`, `DECREASE_LIQUIDITY`, `BURN_POSITION`, `SETTLE` (through Permit2,
///      an explicit amount or the open delta) and `TAKE`, `nextTokenId`, and `IStateView.getSlot0 / getPositionInfo / getFeeGrowthInside /
///      getLiquidity`. Positions are owned in the pool by this contract with `salt = bytes32(tokenId)`, as in V4. One
///      per-currency delta ledger must be zero when a lock ends (`CurrencyNotSettled`). No protocol fee, no hooks.
contract PoolLibV4 {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using SafeCast for int256;
    using Pool for Pool.State;
    using Position for mapping(bytes32 => Position.State);

    struct TokenState {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        address owner;
    }

    MockPermit2 public immutable permit2;
    uint256 public nextTokenId = 1;

    mapping(PoolId poolId => Pool.State) internal _pools;
    mapping(uint256 tokenId => TokenState) internal _tokens;
    mapping(address currency => int256) public deltas;
    address[] internal _touched;
    address internal _locker;
    address internal _synced;
    uint256 internal _syncedReserve;

    error CurrencyNotSettled();
    error DeadlinePassed(uint256 deadline);
    error NotApproved(address caller);
    error MaximumAmountExceeded();
    error MinimumAmountInsufficient();
    error UnsupportedAction(uint256 action);
    error OpenDeltaUnsupported();
    error NotLocker();
    error AlreadyLocked();
    error SwapAmountCannotBeZero();

    constructor(MockPermit2 permit2_) {
        permit2 = permit2_;
    }

    // ------------------------------------------------------------------ pool creation (permissionless, as in V4)

    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick) {
        return _pools[key.toId()].initialize(sqrtPriceX96, key.fee);
    }

    // ------------------------------------------------------------------ StateView

    function getSlot0(PoolId poolId) external view returns (uint160, int24, uint24, uint24) {
        Slot0 slot0 = _pools[poolId].slot0;
        return (slot0.sqrtPriceX96(), slot0.tick(), slot0.protocolFee(), slot0.lpFee());
    }

    function getLiquidity(PoolId poolId) external view returns (uint128) {
        return _pools[poolId].liquidity;
    }

    function getPositionInfo(PoolId poolId, address owner, int24 tickLower, int24 tickUpper, bytes32 salt)
        external
        view
        returns (uint128, uint256, uint256)
    {
        Position.State storage p = _pools[poolId].positions.get(owner, tickLower, tickUpper, salt);
        return (p.liquidity, p.feeGrowthInside0LastX128, p.feeGrowthInside1LastX128);
    }

    function getFeeGrowthInside(PoolId poolId, int24 tickLower, int24 tickUpper)
        external
        view
        returns (uint256, uint256)
    {
        return _pools[poolId].getFeeGrowthInside(tickLower, tickUpper);
    }

    // ------------------------------------------------------------------ PositionManager

    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable {
        if (block.timestamp > deadline) revert DeadlinePassed(deadline);
        _lock();
        (bytes memory actions, bytes[] memory params) = abi.decode(unlockData, (bytes, bytes[]));
        for (uint256 i; i < actions.length; ++i) {
            _handle(uint8(actions[i]), params[i]);
        }
        _unlock();
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
            TokenState memory t = _tokens[tokenId];
            uint128 liq =
                _pools[t.key.toId()].positions.get(address(this), t.tickLower, t.tickUpper, bytes32(tokenId)).liquidity;
            if (liq > 0) {
                (int256 p0, int256 p1) = _modify(tokenId, -int256(uint256(liq)));
                if (uint256(p0) < min0 || uint256(p1) < min1) revert MinimumAmountInsufficient();
            }
            delete _tokens[tokenId];
        } else if (action == Actions.SETTLE) {
            (Currency currency, uint256 amount, bool payerIsUser) = abi.decode(p, (Currency, uint256, bool));
            if (!payerIsUser) revert OpenDeltaUnsupported();
            // `ActionConstants.OPEN_DELTA` (0): the whole debt, as `DeltaResolver._mapSettleAmount` does.
            if (amount == 0) amount = _fullDebt(Currency.unwrap(currency));
            if (amount == 0) return;
            permit2.transferFrom(_locker, address(this), amount.toUint160(), Currency.unwrap(currency));
            _account(Currency.unwrap(currency), amount.toInt256());
        } else if (action == Actions.TAKE) {
            (Currency currency, address recipient, uint256 amount) = abi.decode(p, (Currency, address, uint256));
            // `ActionConstants.OPEN_DELTA` (0): the whole credit, as `DeltaResolver._mapTakeAmount` does.
            if (amount == 0) amount = _fullCredit(Currency.unwrap(currency));
            if (amount == 0) return;
            IERC20(Currency.unwrap(currency)).safeTransfer(recipient, amount);
            _account(Currency.unwrap(currency), -amount.toInt256());
        } else {
            revert UnsupportedAction(action);
        }
    }

    /// @dev `PoolManager.modifyLiquidity`: the caller delta is the principal delta plus the fees the change realized.
    ///      Returns the principal part (what the PositionManager checks slippage on).
    function _modify(uint256 tokenId, int256 liquidityDelta) internal returns (int256 p0, int256 p1) {
        TokenState memory t = _tokens[tokenId];
        (BalanceDelta principal, BalanceDelta fees) = _pools[t.key
            .toId()].modifyLiquidity(
            Pool.ModifyLiquidityParams({
                owner: address(this),
                tickLower: t.tickLower,
                tickUpper: t.tickUpper,
                liquidityDelta: liquidityDelta.toInt128(),
                tickSpacing: t.key.tickSpacing,
                salt: bytes32(tokenId)
            })
        );
        p0 = principal.amount0();
        p1 = principal.amount1();
        _account(Currency.unwrap(t.key.currency0), p0 + fees.amount0());
        _account(Currency.unwrap(t.key.currency1), p1 + fees.amount1());
    }

    // ------------------------------------------------------------------ PoolManager

    function unlock(bytes calldata data) external returns (bytes memory result) {
        _lock();
        result = IUnlockCallback(msg.sender).unlockCallback(data);
        _unlock();
    }

    function swap(PoolKey memory key, IPoolManager.SwapParams memory params, bytes calldata)
        external
        returns (BalanceDelta delta)
    {
        if (msg.sender != _locker) revert NotLocker();
        if (params.amountSpecified == 0) revert SwapAmountCannotBeZero();
        Pool.State storage pool = _pools[key.toId()];
        pool.checkPoolInitialized();
        (delta,,,) = pool.swap(
            Pool.SwapParams({
                amountSpecified: params.amountSpecified,
                tickSpacing: key.tickSpacing,
                zeroForOne: params.zeroForOne,
                sqrtPriceLimitX96: params.sqrtPriceLimitX96,
                lpFeeOverride: 0
            })
        );
        _account(Currency.unwrap(key.currency0), delta.amount0());
        _account(Currency.unwrap(key.currency1), delta.amount1());
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

    function _lock() internal {
        if (_locker != address(0)) revert AlreadyLocked();
        _locker = msg.sender;
    }

    function _unlock() internal {
        for (uint256 i; i < _touched.length; ++i) {
            if (deltas[_touched[i]] != 0) revert CurrencyNotSettled();
        }
        delete _touched;
        _locker = address(0);
    }

    function _requireOwner(uint256 tokenId) internal view {
        if (_tokens[tokenId].owner != _locker) revert NotApproved(_locker);
    }

    function _account(address currency, int256 delta) internal {
        if (delta == 0) return;
        if (deltas[currency] == 0) _touched.push(currency);
        deltas[currency] += delta;
    }

    function _fullDebt(address currency) internal view returns (uint256) {
        int256 d = deltas[currency];
        return d < 0 ? uint256(-d) : 0;
    }

    function _fullCredit(address currency) internal view returns (uint256) {
        int256 d = deltas[currency];
        return d > 0 ? uint256(d) : 0;
    }
}
