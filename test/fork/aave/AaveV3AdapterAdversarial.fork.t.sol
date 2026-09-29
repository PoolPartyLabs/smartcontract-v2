// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IAaveV3Pool} from "../../../src/interfaces/external/IAaveV3Pool.sol";
import {IAToken} from "../../../src/interfaces/external/IAToken.sol";

/// @dev Borrow entry of the Aave V3 Pool, used only by the test to drain reserve liquidity. The adapter never borrows
///      (DEC-018, DEC-028).
interface IAaveV3PoolBorrow {
    function borrow(address asset, uint256 amount, uint256 interestRateMode, uint16 referralCode, address onBehalfOf)
        external;
}

/// @notice Adversarial round 1 against the real Aave V3 Pool and aArbUSDCn on Arbitrum One at the pinned block.
contract AaveV3AdapterAdversarialForkTest is Test {
    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SUPPLIED = 1_000_000e6;

    AaveV3Adapter internal adapter;
    address internal vault = makeAddr("vault");
    address internal guardian = makeAddr("guardian");
    bytes32 internal key = bytes32(uint256(uint160(USDC)));

    function setUp() public {
        vm.createSelectFork(vm.envString("ARBITRUM_RPC_URL"), vm.envUint("ARBITRUM_FORK_BLOCK"));
        address[] memory assets = new address[](1);
        assets[0] = USDC;
        adapter = new AaveV3Adapter(vault, guardian, POOL, assets);
        deal(USDC, vault, 10 * SUPPLIED);
    }

    function _open(uint256 amount) internal {
        vm.startPrank(vault);
        IERC20(USDC).transfer(address(adapter), amount);
        adapter.openPosition(key, abi.encode(amount));
        vm.stopPrank();
    }

    function _accrue(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        vm.roll(block.number + secs / 12 + 1);
    }

    function _drainReserveTo(uint256 remaining) internal {
        address borrower = makeAddr("borrower");
        uint256 available = IERC20(USDC).balanceOf(A_USDC);
        deal(WETH, borrower, 20_000 ether);
        vm.startPrank(borrower);
        IERC20(WETH).approve(POOL, type(uint256).max);
        IAaveV3Pool(POOL).supply(WETH, 20_000 ether, borrower, 0);
        IAaveV3PoolBorrow(POOL).borrow(USDC, available - remaining, 2, 0, borrower);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(A_USDC), remaining);
    }

    /// DEC-068: the live pool mints the scaled amount rounded down and reads the balance rounded down, which is the
    /// rounding the unit mock labels `Directional`; the ledger's value is never above the amount supplied.
    function test_DEC068_fork_liveRoundingMatchesLedgerAssumptions() public {
        uint256 index = IAaveV3Pool(POOL).getReserveNormalizedIncome(USDC);
        assertGt(index, RAY, "index must have grown for rounding to matter");
        _open(SUPPLIED);
        uint256 scaled = IAToken(A_USDC).scaledBalanceOf(address(adapter));
        assertEq(scaled, SUPPLIED * RAY / index, "mint is rounded down");
        assertEq(IAToken(A_USDC).balanceOf(address(adapter)), scaled * index / RAY, "balance is rounded down");
        assertLe(IAToken(A_USDC).balanceOf(address(adapter)), SUPPLIED);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.principal0, scaled * index / RAY);
        assertEq(v.income0, 0);
    }

    /// DEC-068, DEC-056, DEC-059 (finding, round 1, fixed in the final verification): on the real pool, with available
    /// liquidity below the pending income, the principal asked is still served and the income follows only up to the
    /// liquidity left (a reverting withdrawal is caught); the rest stays pending and `collectIncome` never reverts.
    function test_DEC068_fork_pendingIncomeAboveReserveLiquidityNeverBlocksPrincipal() public {
        _open(SUPPLIED);
        _accrue(30 days);
        uint256 pending = adapter.positionValue(key).income0;
        assertGt(pending, 100e6);
        _drainReserveTo(pending / 2);
        uint256 vaultBefore = IERC20(USDC).balanceOf(vault);

        vm.startPrank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(1e6)));
        IAdapter.Amounts memory c = adapter.collectIncome(key);
        vm.stopPrank();
        assertEq(a.principal0, 1e6, "the principal asked is served");
        assertLe(a.income0 + c.income0, pending / 2 - 1e6, "income bounded by the liquidity left");
        assertEq(IERC20(USDC).balanceOf(vault) - vaultBefore, 1e6 + a.income0 + c.income0, "paid what it reported");
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertGe(v.income0 + a.income0 + c.income0 + 2, pending, "the rest stays pending");
        assertApproxEqAbs(v.principal0, SUPPLIED - 1e6, 2);
    }

    /// Q60: cumulative income never regresses across collect, decrease, increase and close on the real pool, and the
    /// vault receives exactly the sum of what every verb reported.
    function test_Q60_fork_cumulativeIncomeMonotonicAcrossVerbs() public {
        _open(SUPPLIED);
        uint256 last = adapter.cumulativeIncome(USDC);
        uint256 paidOut;
        uint256 paidIn = SUPPLIED;
        uint256 vaultStart = IERC20(USDC).balanceOf(vault); // already net of the open

        _accrue(3 days);
        assertGe(adapter.cumulativeIncome(USDC), last);
        last = adapter.cumulativeIncome(USDC);
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.collectIncome(key);
        paidOut += a.income0;
        assertGe(adapter.cumulativeIncome(USDC), last);
        last = adapter.cumulativeIncome(USDC);

        _accrue(3 days);
        vm.prank(vault);
        a = adapter.decreasePosition(key, abi.encode(uint256(123_456_789)));
        paidOut += a.principal0 + a.income0;
        assertGe(adapter.cumulativeIncome(USDC), last);
        last = adapter.cumulativeIncome(USDC);

        _accrue(3 days);
        vm.startPrank(vault);
        IERC20(USDC).transfer(address(adapter), 55_555e6);
        (uint256 used0,, uint256 income0,) = adapter.increasePosition(key, abi.encode(uint256(55_555e6)));
        vm.stopPrank();
        paidOut += income0;
        paidIn += used0;
        assertGe(adapter.cumulativeIncome(USDC), last);
        last = adapter.cumulativeIncome(USDC);

        _accrue(3 days);
        vm.prank(vault);
        a = adapter.closePosition(key, "");
        paidOut += a.principal0 + a.income0;
        assertGe(adapter.cumulativeIncome(USDC), last);

        assertEq(
            IERC20(USDC).balanceOf(vault) + paidIn,
            vaultStart + SUPPLIED + paidOut,
            "vault got exactly what was reported"
        );
        assertEq(IAToken(A_USDC).scaledBalanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0);
        assertEq(IERC20(USDC).allowance(address(adapter), POOL), 0);
    }
}
