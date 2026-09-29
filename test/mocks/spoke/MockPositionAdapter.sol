// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";

/// @notice Position adapter mock for Spoke Vault tests.
/// @dev Keeps `reserved[token]`: every token it holds on the books (principal, funded income, swap liquidity). What the
///      vault sent is `balanceOf - reserved`. Income is simulated with `earnIncome` after the test transferred the tokens
///      in; swap output comes from liquidity added with `addLiquidity`. Knobs make it misbehave for negative tests.
///      `decreasePosition` params: `abi.encode(uint256 bps)` of principal to remove (every fee is realized, as on V4).
contract MockPositionAdapter is AdapterGuard, IAdapter {
    using SafeERC20 for IERC20;

    struct Pool {
        address token0;
        address token1;
        bool exists;
        bool hooked;
    }

    struct Position {
        bytes32 poolKey;
        uint256 principal0;
        uint256 principal1;
        uint256 uncollected0;
        uint256 uncollected1;
        bool open;
    }

    address public vault;
    bool public isExactValue;

    mapping(bytes32 => Pool) public pools;
    mapping(bytes32 => Position) public position;
    bytes32[] internal _keys;
    uint256 internal _nonce;
    mapping(address => uint256) public reserved;
    mapping(address => uint256) public realizedIncome;

    // Knobs.
    uint256 public useBps = 10_000;
    uint256 public unusedShortfall;
    uint256 public principalOverReport;
    uint256 public swapNumerator = 1;
    uint256 public swapDenominator = 1;
    /// @dev Share of the spot output a swap loses (price impact and fee); `spotQuote` ignores it.
    uint256 public swapHaircutBps;
    bool public revertOnExit;
    /// @dev When set, `closePosition` pays the principal but keeps the key open with its income pending, as the Aave
    ///      adapter does when the reserve cannot pay the income (final verification, DEC-056, DEC-068).
    bool public keepKeyOnClose;

    error ExitReverted();

    constructor(address guardian_, bool exactValue_) AdapterGuard(guardian_) {
        isExactValue = exactValue_;
    }

    // ---- test setup ----

    function setVault(address vault_) external {
        vault = vault_;
    }

    function addPool(bytes32 poolKey, address token0, address token1) external {
        pools[poolKey] = Pool(token0, token1, true, false);
    }

    function addHookedPool(bytes32 poolKey, address token0, address token1) external {
        pools[poolKey] = Pool(token0, token1, true, true);
    }

    function setUseBps(uint256 bps) external {
        useBps = bps;
    }

    function setUnusedShortfall(uint256 amount) external {
        unusedShortfall = amount;
    }

    function setPrincipalOverReport(uint256 amount) external {
        principalOverReport = amount;
    }

    function setSwapRate(uint256 numerator, uint256 denominator) external {
        swapNumerator = numerator;
        swapDenominator = denominator;
    }

    function setSwapHaircutBps(uint256 bps) external {
        swapHaircutBps = bps;
    }

    function setRevertOnExit(bool value) external {
        revertOnExit = value;
    }

    function setKeepKeyOnClose(bool value) external {
        keepKeyOnClose = value;
    }

    /// @dev The test transferred `amount0`/`amount1` of the pool tokens to this adapter before calling.
    function earnIncome(bytes32 positionKey, uint256 amount0, uint256 amount1) external {
        Position storage p = position[positionKey];
        require(p.open, "closed");
        Pool memory pool = pools[p.poolKey];
        p.uncollected0 += amount0;
        p.uncollected1 += amount1;
        reserved[pool.token0] += amount0;
        if (amount1 != 0) reserved[pool.token1] += amount1;
    }

    /// @dev The test transferred `amount` of `token` to this adapter before calling.
    function addLiquidity(address token, uint256 amount) external {
        reserved[token] += amount;
    }

    // ---- IAdapter ----

    modifier onlyVault() {
        if (msg.sender != vault) revert NotVault(msg.sender);
        _;
    }

    function poolTokens(bytes32 poolKey) external view returns (address token0, address token1) {
        Pool memory pool = pools[poolKey];
        if (!pool.exists || pool.hooked) revert UnknownPool(poolKey);
        return (pool.token0, pool.token1);
    }

    function openPosition(bytes32 poolKey, bytes calldata)
        external
        onlyVault
        returns (bytes32 positionKey, uint256 used0, uint256 used1)
    {
        _requireEntryAllowed();
        Pool memory pool = pools[poolKey];
        if (!pool.exists) revert UnknownPool(poolKey);
        positionKey = keccak256(abi.encode(address(this), ++_nonce));
        used0 = _take(pool.token0);
        used1 = pool.token1 == address(0) ? 0 : _take(pool.token1);
        position[positionKey] = Position(poolKey, used0, used1, 0, 0, true);
        _keys.push(positionKey);
        emit PositionOpened(positionKey, poolKey, used0, used1);
    }

    function increasePosition(bytes32 positionKey, bytes calldata)
        external
        onlyVault
        returns (uint256 used0, uint256 used1, uint256 income0, uint256 income1)
    {
        _requireEntryAllowed();
        Position storage p = _open(positionKey);
        Pool memory pool = pools[p.poolKey];
        used0 = _take(pool.token0);
        used1 = pool.token1 == address(0) ? 0 : _take(pool.token1);
        p.principal0 += used0;
        p.principal1 += used1;
        (income0, income1) = _realize(p, pool);
        emit PositionIncreased(positionKey, used0, used1, income0, income1);
    }

    function decreasePosition(bytes32 positionKey, bytes calldata params)
        external
        onlyVault
        returns (Amounts memory a)
    {
        if (revertOnExit) revert ExitReverted();
        Position storage p = _open(positionKey);
        Pool memory pool = pools[p.poolKey];
        uint256 bps = params.length == 0 ? 10_000 : abi.decode(params, (uint256));
        a.principal0 = p.principal0 * bps / 10_000;
        a.principal1 = p.principal1 * bps / 10_000;
        p.principal0 -= a.principal0;
        p.principal1 -= a.principal1;
        _pay(pool.token0, a.principal0);
        _pay(pool.token1, a.principal1);
        (a.income0, a.income1) = _realize(p, pool);
        a.principal0 += principalOverReport;
        emit PositionDecreased(positionKey, a);
    }

    function closePosition(bytes32 positionKey, bytes calldata) external onlyVault returns (Amounts memory a) {
        if (revertOnExit) revert ExitReverted();
        Position storage p = _open(positionKey);
        Pool memory pool = pools[p.poolKey];
        a.principal0 = p.principal0;
        a.principal1 = p.principal1;
        p.principal0 = 0;
        p.principal1 = 0;
        _pay(pool.token0, a.principal0);
        _pay(pool.token1, a.principal1);
        if (keepKeyOnClose) {
            emit PositionDecreased(positionKey, a);
            return a;
        }
        (a.income0, a.income1) = _realize(p, pool);
        p.open = false;
        _removeKey(positionKey);
        a.principal0 += principalOverReport;
        emit PositionClosed(positionKey, a);
    }

    function collectIncome(bytes32 positionKey) external onlyVault returns (Amounts memory a) {
        Position storage p = _open(positionKey);
        (a.income0, a.income1) = _realize(p, pools[p.poolKey]);
        emit IncomeCollected(positionKey, a.income0, a.income1);
    }

    function swapExactInput(bytes32 poolKey, address tokenIn, uint256 amountIn, uint256 minAmountOut, bytes calldata)
        external
        onlyVault
        returns (uint256 amountOut)
    {
        if (deprecated) revert AdapterIsDeprecated();
        Pool memory pool = pools[poolKey];
        if (!pool.exists) revert UnknownPool(poolKey);
        address tokenOut = tokenIn == pool.token0 ? pool.token1 : pool.token0;
        reserved[tokenIn] += amountIn;
        amountOut = amountIn * swapNumerator / swapDenominator * (10_000 - swapHaircutBps) / 10_000;
        if (amountOut < minAmountOut) revert InsufficientOutput(amountOut, minAmountOut);
        _pay(tokenOut, amountOut);
        emit Swapped(poolKey, tokenIn, tokenOut, amountIn, amountOut);
    }

    function positionValue(bytes32 positionKey) external view returns (PositionValue memory v) {
        Position memory p = position[positionKey];
        if (!p.open) revert UnknownPosition(positionKey);
        Pool memory pool = pools[p.poolKey];
        v.poolKey = p.poolKey;
        v.poolId = keccak256(abi.encode(p.poolKey));
        v.tickLower = -600;
        v.tickUpper = 600;
        v.liquidity = uint128(p.principal0 + p.principal1);
        v.token0 = pool.token0;
        v.token1 = pool.token1;
        v.principal0 = p.principal0;
        v.principal1 = p.principal1;
        v.income0 = p.uncollected0;
        v.income1 = p.uncollected1;
    }

    function cumulativeIncome(address token) external view returns (uint256 total) {
        total = realizedIncome[token];
        for (uint256 i; i < _keys.length; ++i) {
            Position memory p = position[_keys[i]];
            Pool memory pool = pools[p.poolKey];
            if (pool.token0 == token) total += p.uncollected0;
            if (pool.token1 == token) total += p.uncollected1;
        }
    }

    function positionKeys() external view returns (bytes32[] memory) {
        return _keys;
    }

    /// @dev `decreasePosition` takes bps of principal: `ceil(numerator * 10_000 / denominator)`; 10_000 is a close.
    function unwindExitParams(bytes32 positionKey, uint256 numerator, uint256 denominator)
        external
        view
        returns (bool close, bytes memory params)
    {
        _open(positionKey);
        uint256 bps = (numerator * 10_000 + denominator - 1) / denominator;
        if (bps >= 10_000) return (true, "");
        return (false, abi.encode(bps));
    }

    /// @dev The swap rate is the pool's spot price in the mock.
    function spotQuote(bytes32 poolKey, address, uint256 amountIn) external view returns (uint256) {
        if (!pools[poolKey].exists) revert UnknownPool(poolKey);
        return amountIn * swapNumerator / swapDenominator;
    }

    // ---- internals ----

    function _open(bytes32 positionKey) internal view returns (Position storage p) {
        p = position[positionKey];
        if (!p.open) revert UnknownPosition(positionKey);
    }

    /// @dev Keeps `useBps` of what the vault sent, returns the rest minus the shortfall knob.
    function _take(address token) internal returns (uint256 used) {
        uint256 received = IERC20(token).balanceOf(address(this)) - reserved[token];
        used = received * useBps / 10_000;
        uint256 unused = received - used;
        uint256 shortfall = unusedShortfall > unused ? unused : unusedShortfall;
        reserved[token] += used + shortfall;
        if (unused - shortfall != 0) IERC20(token).safeTransfer(vault, unused - shortfall);
    }

    function _realize(Position storage p, Pool memory pool) internal returns (uint256 income0, uint256 income1) {
        income0 = p.uncollected0;
        income1 = p.uncollected1;
        p.uncollected0 = 0;
        p.uncollected1 = 0;
        realizedIncome[pool.token0] += income0;
        if (pool.token1 != address(0)) realizedIncome[pool.token1] += income1;
        _pay(pool.token0, income0);
        _pay(pool.token1, income1);
    }

    function _pay(address token, uint256 amount) internal {
        if (amount == 0 || token == address(0)) return;
        reserved[token] -= amount;
        IERC20(token).safeTransfer(vault, amount);
    }

    function _removeKey(bytes32 positionKey) internal {
        for (uint256 i; i < _keys.length; ++i) {
            if (_keys[i] == positionKey) {
                _keys[i] = _keys[_keys.length - 1];
                _keys.pop();
                return;
            }
        }
    }
}
