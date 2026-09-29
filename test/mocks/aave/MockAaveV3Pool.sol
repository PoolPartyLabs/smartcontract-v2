// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAaveV3Pool} from "../../../src/interfaces/external/IAaveV3Pool.sol";

/// @notice 6-decimal test asset with an open mint.
contract MockAaveAsset is ERC20 {
    constructor() ERC20("Mock USD Coin", "mUSDC") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Aave-like aToken: scaled balances, `balanceOf = scaled * index`, holds the reserve's underlying.
contract MockAToken {
    MockAaveV3Pool public immutable pool;
    IERC20 public immutable underlying;
    mapping(address => uint256) public scaledBalanceOf;
    uint256 public scaledTotalSupply;

    constructor(MockAaveV3Pool pool_, IERC20 underlying_) {
        pool = pool_;
        underlying = underlying_;
    }

    modifier onlyPool() {
        require(msg.sender == address(pool), "only pool");
        _;
    }

    function balanceOf(address user) public view returns (uint256) {
        return pool.toAmount(scaledBalanceOf[user], pool.getReserveNormalizedIncome(address(underlying)));
    }

    function mint(address to, uint256 scaled) external onlyPool {
        scaledBalanceOf[to] += scaled;
        scaledTotalSupply += scaled;
    }

    function burn(address from, uint256 scaled) external onlyPool {
        scaledBalanceOf[from] -= scaled; // underflow reverts, as in Aave
        scaledTotalSupply -= scaled;
    }

    function transferUnderlying(address to, uint256 amount) external onlyPool {
        underlying.transfer(to, amount); // reverts when the reserve lacks liquidity
    }

    /// @notice aToken transfer (used by tests to donate aTokens).
    function transfer(address to, uint256 amount) external returns (bool) {
        uint256 scaled = pool.toScaledForBurn(amount, pool.getReserveNormalizedIncome(address(underlying)));
        scaledBalanceOf[msg.sender] -= scaled;
        scaledBalanceOf[to] += scaled;
        return true;
    }

    /// @notice Simulates borrowers taking the reserve's liquidity.
    function lendOut(address borrower, uint256 amount) external {
        underlying.transfer(borrower, amount);
    }
}

/// @notice Minimal Aave V3 Pool for unit tests. `Rounding.HalfUp` mirrors Aave up to v3.4 (half-up `rayDiv` and
///         `rayMul`); `Rounding.Directional` mirrors the pool live on Arbitrum One at the pinned block (mint rounded
///         down, burn rounded up, balance rounded down).
contract MockAaveV3Pool is IAaveV3Pool {
    enum Rounding {
        HalfUp,
        Directional
    }

    uint256 internal constant RAY = 1e27;

    Rounding public rounding;
    /// @notice When set, `withdraw` pays one unit less than asked (a misbehaving pool).
    bool public payOneLess;
    mapping(address asset => MockAToken) public aTokenOf;
    mapping(address asset => uint256) public indexOf;
    uint256 public supplyCalls;
    uint256 public withdrawCalls;

    constructor(Rounding rounding_) {
        rounding = rounding_;
    }

    function listReserve(address asset) external returns (MockAToken aToken) {
        aToken = new MockAToken(this, IERC20(asset));
        aTokenOf[asset] = aToken;
        indexOf[asset] = RAY;
    }

    /// @notice Grows the index; the caller funds the interest by minting underlying to the aToken.
    function setIndex(address asset, uint256 index) external {
        require(index >= indexOf[asset], "index only grows");
        indexOf[asset] = index;
    }

    function setPayOneLess(bool value) external {
        payOneLess = value;
    }

    /// @notice Scaled units a misbehaving pool burns on top of what a withdrawal needs.
    uint256 public extraBurn;

    function setExtraBurn(uint256 value) external {
        extraBurn = value;
    }

    function toAmount(uint256 scaled, uint256 index) public view returns (uint256) {
        if (rounding == Rounding.HalfUp) return (scaled * index + RAY / 2) / RAY;
        return Math.mulDiv(scaled, index, RAY);
    }

    function toScaledForBurn(uint256 amount, uint256 index) public view returns (uint256) {
        if (rounding == Rounding.HalfUp) return (amount * RAY + index / 2) / index;
        return Math.mulDiv(amount, RAY, index, Math.Rounding.Ceil);
    }

    function supply(address asset, uint256 amount, address onBehalfOf, uint16) external {
        require(amount != 0, "invalid amount");
        MockAToken aToken = aTokenOf[asset];
        uint256 index = indexOf[asset];
        uint256 scaled = rounding == Rounding.HalfUp ? (amount * RAY + index / 2) / index : amount * RAY / index;
        require(scaled != 0, "invalid mint amount");
        ++supplyCalls;
        IERC20(asset).transferFrom(msg.sender, address(aToken), amount);
        aToken.mint(onBehalfOf, scaled);
    }

    function withdraw(address asset, uint256 amount, address to) external returns (uint256) {
        MockAToken aToken = aTokenOf[asset];
        uint256 index = indexOf[asset];
        uint256 userBalance = aToken.balanceOf(msg.sender);
        if (amount == type(uint256).max) amount = userBalance;
        require(amount != 0, "invalid amount");
        require(amount <= userBalance, "not enough balance");
        uint256 scaled = toScaledForBurn(amount, index);
        require(scaled != 0, "invalid burn amount");
        ++withdrawCalls;
        aToken.burn(msg.sender, scaled + extraBurn);
        uint256 paid = payOneLess ? amount - 1 : amount;
        aToken.transferUnderlying(to, paid);
        return paid;
    }

    function getReserveData(address asset) external view returns (ReserveData memory data) {
        data.liquidityIndex = uint128(indexOf[asset]);
        data.aTokenAddress = address(aTokenOf[asset]);
    }

    function getReserveNormalizedIncome(address asset) external view returns (uint256) {
        return indexOf[asset];
    }
}
