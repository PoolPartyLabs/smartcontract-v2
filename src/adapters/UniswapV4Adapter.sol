// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IStateView} from "@uniswap/v4-periphery/src/interfaces/IStateView.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {IAdapter} from "../interfaces/IAdapter.sol";
import {ISpokeVault} from "../interfaces/ISpokeVault.sol";
import {AdapterGuard} from "./AdapterGuard.sol";

/// @title UniswapV4Adapter
/// @notice Position adapter for Uniswap V4 on one chain, owned by exactly one Spoke Vault.
/// @dev DEC-018: the MVP integrates Uniswap V4 on the Hub Chain and on the Spoke Chain. DEC-053, DEC-058: immutable, one
///      instance per fund per chain, no proxy, no setter, no SELFDESTRUCT (Q17-4: the vault pins this codehash).
/// @dev Pools: the adapter's `poolKey` is the Uniswap `PoolId` (`keccak256(abi.encode(PoolKey))`). The closed list of
///      `PoolKey` structs is registered once in the constructor (DEC-030); nothing may be added later.
/// @dev DEC-079 (OPEN for hooks that charge on withdrawal), OQ-12: a registered pool whose `hooks` is not address(0) is
///      treated as unknown by `poolTokens`, `openPosition` and `swapExactInput`, so the Spoke Vault's creation check
///      rejects it. Native-currency pools are rejected at construction (the adapter never handles ETH).
/// @dev Liquidity goes through the PositionManager (`modifyLiquidities` with `Actions`); position NFTs are owned by this
///      adapter. Token payment goes through Permit2 with an ephemeral allowance of exactly the amount owed, cleared in
///      the same call. Swaps go through `PoolManager.unlock` and `unlockCallback`.
/// @dev DEC-079: principal and income are separated from the PoolManager's own accounting. Before any liquidity change
///      the adapter reads the position (`StateView.getPositionInfo`, `getFeeGrowthInside`, `getSlot0`) and computes,
///      with the pool's own formulas and rounding, the income the change realizes (`liquidity * (feeGrowthInside -
///      feeGrowthInsideLast) / 2^128`, `Position.update`) and the principal it moves (`SqrtPriceMath`, `Pool
///      .modifyLiquidity`). The adapter then settles and takes exactly those amounts (`SETTLE`, `TAKE` with explicit
///      amounts, never an open delta), so the PoolManager's end-of-unlock check (`CurrencyNotSettled`) proves that
///      the split matches the protocol to the wei: any mismatch reverts the whole call.
/// @dev DEC-080: no value this adapter reports is derived from `balanceOf`. The only balance read is the adapter's own,
///      at the end of `openPosition` and `increasePosition`, to hand back every token the vault sent and the position
///      did not use (the adapter holds nothing between calls); the vault books that return from its own ledger
///      (`amount - used`), not from what arrives.
contract UniswapV4Adapter is IAdapter, AdapterGuard, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    using SafeCast for uint256;

    /// @notice Parameters of `openPosition`, ABI-encoded as this struct.
    /// @param tickLower Lower tick of the range (a multiple of the pool's tick spacing).
    /// @param tickUpper Upper tick of the range.
    /// @param liquidity Liquidity to mint; 0 derives it from `amount0Max`/`amount1Max` at the current price.
    /// @param amount0Max Maximum token0 the position may take (Uniswap slippage bound; the desired amount when
    ///        `liquidity` is 0).
    /// @param amount1Max Maximum token1 the position may take.
    /// @param amount0Min Minimum token0 the position must take, else revert (protects a derived liquidity).
    /// @param amount1Min Minimum token1 the position must take.
    /// @param deadline Timestamp after which the PositionManager rejects the call.
    struct OpenParams {
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `increasePosition`, ABI-encoded as this struct. Same meaning as in `OpenParams`.
    struct IncreaseParams {
        uint128 liquidity;
        uint128 amount0Max;
        uint128 amount1Max;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `decreasePosition`, ABI-encoded as this struct.
    /// @param liquidity Liquidity to remove; must be above 0 and below the position's liquidity (use `closePosition`
    ///        to remove all of it, `collectIncome` to take only the income).
    /// @param amount0Min Minimum token0 principal, else revert (income does not count toward it).
    /// @param amount1Min Minimum token1 principal.
    /// @param deadline Timestamp after which the PositionManager rejects the call.
    struct DecreaseParams {
        uint128 liquidity;
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `closePosition`, ABI-encoded as this struct. Same meaning as in `DecreaseParams`.
    struct CloseParams {
        uint128 amount0Min;
        uint128 amount1Min;
        uint256 deadline;
    }

    /// @notice Parameters of `swapExactInput`, ABI-encoded as this struct; empty `params` mean no price limit and the
    ///         current block as deadline (the Spoke Vault's automatic unwind without a claimant hint; its minimum
    ///         output is the vault's floor, final verification, QA3).
    /// @param sqrtPriceLimitX96 Price limit of the swap; 0 means no limit. A swap that stops at the limit before
    ///        using the whole input reverts with `PartialSwap`.
    /// @param deadline Timestamp after which the swap reverts.
    struct SwapExactInputParams {
        uint160 sqrtPriceLimitX96;
        uint256 deadline;
    }

    /// @dev One open position. The position key is `bytes32(tokenId)` of the PositionManager NFT.
    struct Position {
        bytes32 poolId;
        int24 tickLower;
        int24 tickUpper;
    }

    /// @dev Actions and parameters of one `modifyLiquidities` call, built in memory.
    struct Plan {
        bytes actions;
        bytes[] params;
        uint256 count;
    }

    /// @dev Q128 fixed-point unit of the PoolManager's fee growth.
    uint256 private constant Q128 = 1 << 128;

    /// @dev Upper bound on the actions of one `modifyLiquidities` call built here.
    uint256 private constant MAX_ACTIONS = 6;

    /// @inheritdoc IAdapter
    address public immutable vault;

    /// @notice Uniswap V4 PoolManager (swaps).
    IPoolManager public immutable poolManager;

    /// @notice Uniswap V4 PositionManager (liquidity; owner of record of every position in the PoolManager).
    IPositionManager public immutable positionManager;

    /// @notice Uniswap V4 StateView (reads of the PoolManager's state).
    IStateView public immutable stateView;

    /// @notice Permit2, through which the PositionManager pulls tokens.
    IAllowanceTransfer public immutable permit2;

    /// @notice Income in `token` realized by the protocol and transferred to the vault since inception (DEC-079, Q60).
    mapping(address token => uint256 amount) public realizedIncome;

    mapping(bytes32 poolId => PoolKey key) private _pools;
    mapping(bytes32 positionKey => Position position) private _positions;
    EnumerableSet.Bytes32Set private _openPositions;

    /// @notice A pool was registered at construction (DEC-030). A pool with `hooks != address(0)` is registered but
    ///         never operable (DEC-079 OPEN, OQ-12).
    event PoolRegistered(
        bytes32 indexed poolId, address token0, address token1, uint24 fee, int24 tickSpacing, address hooks
    );

    /// @notice A constructor address is zero.
    error ZeroAddress();

    /// @notice A constructor pool key is malformed or uses the native currency.
    error InvalidPoolKey(bytes32 poolId);

    /// @notice A constructor pool key is listed twice.
    error DuplicatePool(bytes32 poolId);

    /// @notice The liquidity of an open, increase or decrease is zero or not below the position's liquidity.
    error InvalidLiquidity(uint256 liquidity, uint256 positionLiquidity);

    /// @notice The principal of an operation is below the caller's minimums.
    error AmountBelowMinimum(uint256 amount0, uint256 amount1);

    /// @notice The swap input token is not one of the pool's tokens.
    error TokenNotInPool(address token);

    /// @notice The swap stopped at the price limit before using the whole input.
    error PartialSwap(uint256 amountUsed, uint256 amountIn);

    /// @notice `unlockCallback` was called by an address other than the PoolManager.
    error NotPoolManager(address caller);

    /// @notice The operation's deadline has passed.
    error DeadlineExpired(uint256 deadline);

    /// @notice A swap was requested with a zero input.
    error ZeroAmount();

    /// @dev DEC-053, DEC-058: every mutating verb is restricted to the fund's Spoke Vault.
    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    /// @param vault_ The Spoke Vault that owns this adapter.
    /// @param guardian_ Immutable address allowed to pause and deprecate (DEC-021, DEC-058; Q17-2b OPEN).
    /// @param poolManager_ Uniswap V4 PoolManager of this chain.
    /// @param positionManager_ Uniswap V4 PositionManager of this chain.
    /// @param stateView_ Uniswap V4 StateView of this chain.
    /// @param permit2_ Permit2 used by the PositionManager.
    /// @param pools Closed list of pools this fund may use on this chain (DEC-030, DEC-053).
    constructor(
        address vault_,
        address guardian_,
        IPoolManager poolManager_,
        IPositionManager positionManager_,
        IStateView stateView_,
        IAllowanceTransfer permit2_,
        PoolKey[] memory pools
    ) AdapterGuard(guardian_) {
        if (
            vault_ == address(0) || address(poolManager_) == address(0) || address(positionManager_) == address(0)
                || address(stateView_) == address(0) || address(permit2_) == address(0)
        ) revert ZeroAddress();
        vault = vault_;
        poolManager = poolManager_;
        positionManager = positionManager_;
        stateView = stateView_;
        permit2 = permit2_;

        for (uint256 i; i < pools.length; ++i) {
            PoolKey memory key = pools[i];
            bytes32 poolId = PoolId.unwrap(key.toId());
            if (key.tickSpacing <= 0 || Currency.unwrap(key.currency0) == address(0)) revert InvalidPoolKey(poolId);
            if (_pools[poolId].tickSpacing != 0) revert DuplicatePool(poolId);
            _pools[poolId] = key;
            emit PoolRegistered(
                poolId,
                Currency.unwrap(key.currency0),
                Currency.unwrap(key.currency1),
                key.fee,
                key.tickSpacing,
                address(key.hooks)
            );
        }
    }

    // ------------------------------------------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @dev DEC-059: Uniswap V4 positions are price-dependent and are unwound, never read as exact value.
    function isExactValue() external pure returns (bool) {
        return false;
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-079 OPEN, OQ-12: reverts `UnknownPool` for an unregistered id and for a pool with hooks.
    function poolTokens(bytes32 poolKey) external view returns (address token0, address token1) {
        PoolKey memory key = _operablePool(poolKey);
        return (Currency.unwrap(key.currency0), Currency.unwrap(key.currency1));
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-079: principal is the amount the position would return if removed now (the pool's rounding, down);
    ///      income is `liquidity * (feeGrowthInside_now - feeGrowthInsideLast) / 2^128` per token, read through the
    ///      StateView.
    function positionValue(bytes32 positionKey) external view returns (PositionValue memory value) {
        Position memory position = _openPosition(positionKey);
        PoolKey memory key = _pools[position.poolId];
        (uint128 liquidity, uint256 income0, uint256 income1) = _uncollectedIncome(positionKey, position);
        (uint256 principal0, uint256 principal1) = _principal(position, liquidity, false);
        value = PositionValue({
            poolKey: position.poolId,
            poolId: position.poolId,
            tickLower: position.tickLower,
            tickUpper: position.tickUpper,
            liquidity: liquidity,
            token0: Currency.unwrap(key.currency0),
            token1: Currency.unwrap(key.currency1),
            principal0: principal0,
            principal1: principal1,
            income0: income0,
            income1: income1
        });
    }

    /// @inheritdoc IAdapter
    /// @dev Q60, DEC-092: `realizedIncome[token]` plus the uncollected income of every open position in `token`.
    ///      Monotonic: uncollected income only grows with fee growth, and every realization moves the exact same
    ///      amount from the uncollected term to the realized term (closed positions leave nothing uncollected).
    /// @dev Cost: O(open positions), two StateView reads per position (the set is bounded by what the manager opens).
    ///      DEC-092 forbids reading all positions on each user operation, so the Spoke Vault calls this only when it
    ///      builds a report or after a collect, never from a Shareholder path (Uniswap V4 verifier finding).
    function cumulativeIncome(address token) external view returns (uint256 total) {
        total = realizedIncome[token];
        uint256 count = _openPositions.length();
        for (uint256 i; i < count; ++i) {
            bytes32 positionKey = _openPositions.at(i);
            Position memory position = _positions[positionKey];
            PoolKey memory key = _pools[position.poolId];
            bool isToken0 = Currency.unwrap(key.currency0) == token;
            if (!isToken0 && Currency.unwrap(key.currency1) != token) continue;
            (, uint256 income0, uint256 income1) = _uncollectedIncome(positionKey, position);
            total += isToken0 ? income0 : income1;
        }
    }

    /// @inheritdoc IAdapter
    function positionKeys() external view returns (bytes32[] memory) {
        return _openPositions.values();
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-079: principal is linear in liquidity at a given price, so removing `ceil(liquidity * numerator /
    ///      denominator)` removes at least that share of it; the whole liquidity is a close. Minimums are 0: the price
    ///      guard of an unwind is the vault's swap floor (QA3 OPEN).
    function unwindExitParams(bytes32 positionKey, uint256 numerator, uint256 denominator)
        external
        view
        returns (bool close, bytes memory params)
    {
        Position memory position = _openPosition(positionKey);
        (uint128 liquidity,,) = stateView.getPositionInfo(
            PoolId.wrap(position.poolId), address(positionManager), position.tickLower, position.tickUpper, positionKey
        );
        uint256 part = Math.mulDiv(liquidity, numerator, denominator, Math.Rounding.Ceil);
        if (part >= liquidity) return (true, abi.encode(CloseParams(0, 0, block.timestamp)));
        return (false, abi.encode(DecreaseParams(uint128(part), 0, 0, block.timestamp)));
    }

    /// @inheritdoc IAdapter
    /// @dev `slot0` price of token1 per token0 as `sqrtPriceX96^2 / 2^192`, kept in Q128 with 512-bit `mulDiv`
    ///      (`sqrtPriceX96 >= MIN_SQRT_PRICE`, so the Q128 price is never 0). DEC-079 OPEN: hooked pools revert.
    function spotQuote(bytes32 poolKey, address tokenIn, uint256 amountIn) external view returns (uint256) {
        PoolKey memory key = _operablePool(poolKey);
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(PoolId.wrap(poolKey));
        uint256 priceX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        if (Currency.unwrap(key.currency0) == tokenIn) return Math.mulDiv(amountIn, priceX128, Q128);
        if (Currency.unwrap(key.currency1) != tokenIn) revert TokenNotInPool(tokenIn);
        return Math.mulDiv(amountIn, Q128, priceX128);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Entry verbs (DEC-056, DEC-058: blocked when paused or deprecated)
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @dev `params` is `abi.encode(OpenParams)`. DEC-056, DEC-058: reverts when paused or deprecated. DEC-079 OPEN:
    ///      hooked pools revert `UnknownPool`. The vault transferred the tokens before the call; the adapter pays the
    ///      exact owed amounts through Permit2 and hands every unused token back to the vault.
    function openPosition(bytes32 poolKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        _requireEntryAllowed();
        PoolKey memory key = _operablePool(poolKey);
        OpenParams memory p = abi.decode(params, (OpenParams));
        Position memory position = Position({poolId: poolKey, tickLower: p.tickLower, tickUpper: p.tickUpper});

        uint128 liquidity = p.liquidity == 0 ? _liquidityForAmounts(position, p.amount0Max, p.amount1Max) : p.liquidity;
        if (liquidity == 0) revert InvalidLiquidity(0, 0);
        (used0, used1) = _principal(position, liquidity, true);
        _requireMinimums(used0, used1, p.amount0Min, p.amount1Min);

        uint256 tokenId = positionManager.nextTokenId();
        positionKey = bytes32(tokenId);
        _positions[positionKey] = position;
        _openPositions.add(positionKey);

        Plan memory plan = _newPlan();
        _push(
            plan,
            Actions.MINT_POSITION,
            abi.encode(key, p.tickLower, p.tickUpper, uint256(liquidity), p.amount0Max, p.amount1Max, address(this), "")
        );
        _pushSettle(plan, key.currency0, used0);
        _pushSettle(plan, key.currency1, used1);
        _pay(key, used0, used1, plan, p.deadline);

        emit PositionOpened(positionKey, poolKey, used0, used1);
    }

    /// @inheritdoc IAdapter
    /// @dev `params` is `abi.encode(IncreaseParams)`. DEC-056, DEC-058: reverts when paused or deprecated. DEC-079: the
    ///      increase realizes the position's income; it is taken to the vault and reported as income, apart from the
    ///      principal paid in.
    function increasePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1)
    {
        _requireEntryAllowed();
        Position memory position = _openPosition(positionKey);
        PoolKey memory key = _pools[position.poolId];
        IncreaseParams memory p = abi.decode(params, (IncreaseParams));

        uint128 liquidity = p.liquidity == 0 ? _liquidityForAmounts(position, p.amount0Max, p.amount1Max) : p.liquidity;
        if (liquidity == 0) revert InvalidLiquidity(0, 0);
        (used0, used1) = _principal(position, liquidity, true);
        _requireMinimums(used0, used1, p.amount0Min, p.amount1Min);
        (, income0, income1) = _uncollectedIncome(positionKey, position);
        _recordIncome(key, income0, income1);

        Plan memory plan = _newPlan();
        _push(
            plan,
            Actions.INCREASE_LIQUIDITY,
            abi.encode(uint256(positionKey), uint256(liquidity), p.amount0Max, p.amount1Max, "")
        );
        _pushSettle(plan, key.currency0, used0);
        _pushSettle(plan, key.currency1, used1);
        _pushTake(plan, key.currency0, income0);
        _pushTake(plan, key.currency1, income1);
        _pay(key, used0, used1, plan, p.deadline);

        emit PositionIncreased(positionKey, used0, used1, income0, income1);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Exit verbs (DEC-021, DEC-056: never read pause or deprecation)
    // ------------------------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    /// @dev `params` is `abi.encode(DecreaseParams)`. DEC-056: never gated. DEC-079: a `DECREASE_LIQUIDITY` of 0 first
    ///      realizes only the income, then the principal is removed; both are taken to the vault in exact amounts.
    function decreasePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (Amounts memory amounts)
    {
        Position memory position = _openPosition(positionKey);
        PoolKey memory key = _pools[position.poolId];
        DecreaseParams memory p = abi.decode(params, (DecreaseParams));

        uint128 positionLiquidity;
        (positionLiquidity, amounts.income0, amounts.income1) = _uncollectedIncome(positionKey, position);
        if (p.liquidity == 0 || p.liquidity >= positionLiquidity) {
            revert InvalidLiquidity(p.liquidity, positionLiquidity);
        }
        (amounts.principal0, amounts.principal1) = _principal(position, p.liquidity, false);
        _requireMinimums(amounts.principal0, amounts.principal1, p.amount0Min, p.amount1Min);
        _recordIncome(key, amounts.income0, amounts.income1);

        Plan memory plan = _newPlan();
        _pushRealizeIncome(plan, positionKey);
        _push(
            plan,
            Actions.DECREASE_LIQUIDITY,
            abi.encode(uint256(positionKey), uint256(p.liquidity), p.amount0Min, p.amount1Min, "")
        );
        _pushTake(plan, key.currency0, amounts.principal0 + amounts.income0);
        _pushTake(plan, key.currency1, amounts.principal1 + amounts.income1);
        _execute(plan, p.deadline);

        emit PositionDecreased(positionKey, amounts);
    }

    /// @inheritdoc IAdapter
    /// @dev `params` is `abi.encode(CloseParams)`. DEC-056: never gated. DEC-079: a `DECREASE_LIQUIDITY` of 0 first
    ///      realizes only the income, then `BURN_POSITION` removes the whole principal and burns the NFT.
    function closePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        nonReentrant
        returns (Amounts memory amounts)
    {
        Position memory position = _openPosition(positionKey);
        PoolKey memory key = _pools[position.poolId];
        CloseParams memory p = abi.decode(params, (CloseParams));

        uint128 positionLiquidity;
        (positionLiquidity, amounts.income0, amounts.income1) = _uncollectedIncome(positionKey, position);
        (amounts.principal0, amounts.principal1) = _principal(position, positionLiquidity, false);
        _requireMinimums(amounts.principal0, amounts.principal1, p.amount0Min, p.amount1Min);
        _recordIncome(key, amounts.income0, amounts.income1);
        delete _positions[positionKey];
        _openPositions.remove(positionKey);

        Plan memory plan = _newPlan();
        if (positionLiquidity != 0) _pushRealizeIncome(plan, positionKey);
        _push(plan, Actions.BURN_POSITION, abi.encode(uint256(positionKey), p.amount0Min, p.amount1Min, ""));
        _pushTake(plan, key.currency0, amounts.principal0 + amounts.income0);
        _pushTake(plan, key.currency1, amounts.principal1 + amounts.income1);
        _execute(plan, p.deadline);

        emit PositionClosed(positionKey, amounts);
    }

    /// @inheritdoc IAdapter
    /// @dev DEC-056, Q17-2a (OPEN, reading C1): never gated. DEC-079: a `DECREASE_LIQUIDITY` of 0 realizes the income,
    ///      taken to the vault in exact amounts; principal fields stay zero. Nothing is called when there is no income.
    function collectIncome(bytes32 positionKey) external onlyVault nonReentrant returns (Amounts memory amounts) {
        Position memory position = _openPosition(positionKey);
        PoolKey memory key = _pools[position.poolId];
        (, amounts.income0, amounts.income1) = _uncollectedIncome(positionKey, position);

        if (amounts.income0 != 0 || amounts.income1 != 0) {
            _recordIncome(key, amounts.income0, amounts.income1);
            Plan memory plan = _newPlan();
            _pushRealizeIncome(plan, positionKey);
            _pushTake(plan, key.currency0, amounts.income0);
            _pushTake(plan, key.currency1, amounts.income1);
            _execute(plan, block.timestamp);
        }

        emit IncomeCollected(positionKey, amounts.income0, amounts.income1);
    }

    /// @inheritdoc IAdapter
    /// @dev `params` is `abi.encode(SwapExactInputParams)`. OQ-04: never blocked when paused; when deprecated only a
    ///      swap INTO the vault's base token runs (security review S-10: DEC-056, DEC-058 "withdraw-only" keep the exit
    ///      path open, and this swap is the only way a Spoke Vault turns the non-base leg of a closed position, or of
    ///      the automatic unwind, into its base token; a swap out of the base token is an entry and stays blocked).
    ///      DEC-030, DEC-079 OPEN: registered hookless pools only. The swap runs in `unlockCallback`; the output goes
    ///      straight from the PoolManager to the vault; a swap that does not use the whole input reverts `PartialSwap`.
    function swapExactInput(
        bytes32 poolKey,
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut,
        bytes calldata params
    ) external onlyVault nonReentrant returns (uint256 amountOut) {
        PoolKey memory key = _operablePool(poolKey);
        bool zeroForOne = Currency.unwrap(key.currency0) == tokenIn;
        if (!zeroForOne && Currency.unwrap(key.currency1) != tokenIn) revert TokenNotInPool(tokenIn);
        if (deprecated) {
            address tokenOut = Currency.unwrap(zeroForOne ? key.currency1 : key.currency0);
            if (tokenOut != ISpokeVault(vault).baseToken()) revert AdapterIsDeprecated();
        }
        if (amountIn == 0) revert ZeroAmount();
        SwapExactInputParams memory p =
            params.length == 0 ? SwapExactInputParams(0, block.timestamp) : abi.decode(params, (SwapExactInputParams));
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        uint160 limit = p.sqrtPriceLimitX96;
        if (limit == 0) limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        amountOut = abi.decode(poolManager.unlock(abi.encode(key, zeroForOne, amountIn, limit)), (uint256));
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        // IAdapter custody: no idle balance stays here between calls; anything above `amountIn` goes back, unreported
        // (DEC-080: a physical hand-back, never a reported amount).
        _returnUnused(tokenIn);

        address tokenOut = zeroForOne ? Currency.unwrap(key.currency1) : Currency.unwrap(key.currency0);
        emit Swapped(poolKey, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @notice PoolManager callback of `swapExactInput`: swaps, pays the exact input, sends the output to the vault.
    /// @dev Only the PoolManager may call it, and the PoolManager only calls back the address that unlocked it, so it
    ///      runs only inside this adapter's own `swapExactInput`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) =
            abi.decode(data, (PoolKey, bool, uint256, uint160));

        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -amountIn.toInt256(), sqrtPriceLimitX96: limit
            }),
            ""
        );
        (int128 deltaIn, int128 deltaOut) =
            zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        // casting to 'uint128' is safe because both values are checked to be positive first
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountUsed = deltaIn < 0 ? uint256(uint128(-deltaIn)) : 0;
        if (amountUsed != amountIn) revert PartialSwap(amountUsed, amountIn);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 amountOut = deltaOut > 0 ? uint256(uint128(deltaOut)) : 0;

        (Currency currencyIn, Currency currencyOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        poolManager.sync(currencyIn);
        IERC20(Currency.unwrap(currencyIn)).safeTransfer(address(poolManager), amountIn);
        // A fee-on-transfer or rebasing input surfaces as a named error instead of the PoolManager's opaque
        // CurrencyNotSettled.
        uint256 paid = poolManager.settle();
        if (paid != amountIn) revert PartialSwap(paid, amountIn);
        if (amountOut != 0) poolManager.take(currencyOut, vault, amountOut);
        return abi.encode(amountOut);
    }

    // ------------------------------------------------------------------------------------------------------------
    // Internals
    // ------------------------------------------------------------------------------------------------------------

    /// @dev DEC-030: registered pools only. DEC-079 OPEN, OQ-12: a pool with hooks is not operable.
    function _operablePool(bytes32 poolId) private view returns (PoolKey memory key) {
        key = _pools[poolId];
        if (key.tickSpacing == 0 || address(key.hooks) != address(0)) revert UnknownPool(poolId);
    }

    function _openPosition(bytes32 positionKey) private view returns (Position memory position) {
        if (!_openPositions.contains(positionKey)) revert UnknownPosition(positionKey);
        position = _positions[positionKey];
    }

    /// @dev DEC-079: the position's liquidity and the income a liquidity change would realize now, with the
    ///      PoolManager's own formula (`Position.update`: fee growth difference, wrapping, times liquidity, over 2^128).
    function _uncollectedIncome(bytes32 positionKey, Position memory position)
        private
        view
        returns (uint128 liquidity, uint256 income0, uint256 income1)
    {
        PoolId poolId = PoolId.wrap(position.poolId);
        uint256 last0;
        uint256 last1;
        (liquidity, last0, last1) = stateView.getPositionInfo(
            poolId, address(positionManager), position.tickLower, position.tickUpper, positionKey
        );
        (uint256 inside0, uint256 inside1) =
            stateView.getFeeGrowthInside(poolId, position.tickLower, position.tickUpper);
        unchecked {
            income0 = Math.mulDiv(inside0 - last0, liquidity, Q128);
            income1 = Math.mulDiv(inside1 - last1, liquidity, Q128);
        }
    }

    /// @dev DEC-079: principal moved by a liquidity change of `liquidity` at the current price, with the PoolManager's
    ///      own branches and rounding (`Pool.modifyLiquidity`): rounded up when adding, down when removing. The
    ///      v4-periphery `LiquidityAmounts` in use only converts amounts to liquidity, so the amounts come from
    ///      `SqrtPriceMath`, the same library the PoolManager uses.
    function _principal(Position memory position, uint128 liquidity, bool roundUp)
        private
        view
        returns (uint256 amount0, uint256 amount1)
    {
        (uint160 sqrtPriceX96, int24 tick,,) = stateView.getSlot0(PoolId.wrap(position.poolId));
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(position.tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(position.tickUpper);
        if (tick < position.tickLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        } else if (tick < position.tickUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtUpper, liquidity, roundUp);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPriceX96, liquidity, roundUp);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, roundUp);
        }
    }

    function _liquidityForAmounts(Position memory position, uint256 amount0, uint256 amount1)
        private
        view
        returns (uint128)
    {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(PoolId.wrap(position.poolId));
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(position.tickLower),
            TickMath.getSqrtPriceAtTick(position.tickUpper),
            amount0,
            amount1
        );
    }

    function _requireMinimums(uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min) private pure {
        if (amount0 < amount0Min || amount1 < amount1Min) revert AmountBelowMinimum(amount0, amount1);
    }

    /// @dev Q60: realized income is booked before the protocol call (checks-effects-interactions); the call then
    ///      transfers exactly this amount to the vault or reverts.
    function _recordIncome(PoolKey memory key, uint256 income0, uint256 income1) private {
        if (income0 != 0) realizedIncome[Currency.unwrap(key.currency0)] += income0;
        if (income1 != 0) realizedIncome[Currency.unwrap(key.currency1)] += income1;
    }

    /// @dev Grants the PositionManager, through Permit2, exactly the owed amounts, runs the plan, clears both
    ///      allowances and hands every token the vault sent and the position did not use back to the vault.
    function _pay(PoolKey memory key, uint256 amount0, uint256 amount1, Plan memory plan, uint256 deadline) private {
        address token0 = Currency.unwrap(key.currency0);
        address token1 = Currency.unwrap(key.currency1);
        _grant(token0, amount0);
        _grant(token1, amount1);
        _execute(plan, deadline);
        _revoke(token0, amount0);
        _revoke(token1, amount1);
        _returnUnused(token0);
        _returnUnused(token1);
    }

    /// @dev IAdapter custody: ephemeral allowance of exactly the owed amount, cleared in the same call (forceApprove to
    ///      zero in `_revoke`); the Permit2 allowance expires at this block.
    function _grant(address token, uint256 amount) private {
        if (amount == 0) return;
        IERC20(token).forceApprove(address(permit2), amount);
        permit2.approve(token, address(positionManager), amount.toUint160(), uint48(block.timestamp));
    }

    /// @dev IAdapter custody: clears both allowances `_grant` set, in the same call.
    function _revoke(address token, uint256 amount) private {
        if (amount == 0) return;
        permit2.approve(token, address(positionManager), 0, 0);
        IERC20(token).forceApprove(address(permit2), 0);
    }

    /// @dev DEC-080: a physical hand-back only; no reported amount is derived from this balance.
    function _returnUnused(address token) private {
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance != 0) IERC20(token).safeTransfer(vault, balance);
    }

    function _newPlan() private pure returns (Plan memory plan) {
        plan.params = new bytes[](MAX_ACTIONS);
    }

    function _push(Plan memory plan, uint256 action, bytes memory param) private pure {
        // casting to 'uint8' is safe because every `Actions` constant is below 0x20
        // forge-lint: disable-next-line(unsafe-typecast)
        plan.actions = bytes.concat(plan.actions, bytes1(uint8(action)));
        plan.params[plan.count++] = param;
    }

    /// @dev DEC-079: `DECREASE_LIQUIDITY` of 0 realizes only the position's income.
    function _pushRealizeIncome(Plan memory plan, bytes32 positionKey) private pure {
        _push(
            plan, Actions.DECREASE_LIQUIDITY, abi.encode(uint256(positionKey), uint256(0), uint128(0), uint128(0), "")
        );
    }

    /// @dev An explicit amount (never 0, which the PositionManager reads as "the whole open delta").
    function _pushSettle(Plan memory plan, Currency currency, uint256 amount) private pure {
        if (amount != 0) _push(plan, Actions.SETTLE, abi.encode(currency, amount, true));
    }

    /// @dev An explicit amount to the vault (never 0, which the PositionManager reads as "the whole open delta").
    function _pushTake(Plan memory plan, Currency currency, uint256 amount) private view {
        if (amount != 0) _push(plan, Actions.TAKE, abi.encode(currency, vault, amount));
    }

    function _execute(Plan memory plan, uint256 deadline) private {
        bytes[] memory params = new bytes[](plan.count);
        for (uint256 i; i < plan.count; ++i) {
            params[i] = plan.params[i];
        }
        positionManager.modifyLiquidities(abi.encode(plan.actions, params), deadline);
    }
}
