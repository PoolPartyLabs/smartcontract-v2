// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
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

/// @notice Aave V3 Adapter against the real Aave V3 Pool and aArbUSDCn on Arbitrum One at the pinned block.
contract AaveV3AdapterForkTest is Test {
    address internal constant POOL = 0x794a61358D6845594F94dc1DB02A252b5b4814aD;
    address internal constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address internal constant A_USDC = 0x724dc807b04555b71ed48a6896b6F41593b8C637;
    address internal constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

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

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

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

    function _vaultBalance() internal view returns (uint256) {
        return IERC20(USDC).balanceOf(vault);
    }

    /// @dev IAdapter custody: nothing but the aToken position stays in the adapter; no approval outlives a call.
    function _assertAdapterHoldsNothing() internal view {
        assertEq(IERC20(USDC).balanceOf(address(adapter)), 0, "adapter holds USDC");
        assertEq(IERC20(USDC).allowance(address(adapter), POOL), 0, "approval left");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Tests
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-068: open supplies to the real Pool and records scaled balance, principal and index.
    function test_DEC068_fork_openRecordsLedger() public {
        uint256 indexBefore = IAaveV3Pool(POOL).getReserveNormalizedIncome(USDC);
        _open(SUPPLIED);

        AaveV3Adapter.Ledger memory l = adapter.ledger(USDC);
        assertEq(l.aToken, A_USDC);
        assertEq(l.principal, SUPPLIED);
        assertEq(l.lastIndex, indexBefore);
        assertEq(l.scaledBalance, IAToken(A_USDC).scaledBalanceOf(address(adapter)));

        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.token0, USDC);
        assertEq(v.token1, address(0));
        assertEq(v.poolId, key);
        assertEq(uint256(v.liquidity), l.scaledBalance);
        // Aave rounds the minted scaled amount down: up to ceil(index / 1e27) units of principal are lost at supply.
        assertApproxEqAbs(v.principal0, SUPPLIED, 2);
        assertLe(v.income0, 1);
        assertEq(adapter.positionKeys().length, 1);
        _assertAdapterHoldsNothing();
    }

    /// DEC-068, Q60: time accrues income; principal does not move; cumulative income equals the pending interest.
    function test_DEC068_fork_incomeGrowsPrincipalUnchanged() public {
        _open(SUPPLIED);
        IAdapter.PositionValue memory v0 = adapter.positionValue(key);
        _accrue(30 days);
        IAdapter.PositionValue memory v1 = adapter.positionValue(key);

        assertGt(v1.income0, v0.income0 + 100e6, "income did not grow"); // > 100 USDC in 30 days on 1M
        assertEq(v1.principal0, SUPPLIED, "principal moved");
        assertEq(adapter.cumulativeIncome(USDC), v1.income0);
        assertLe(v1.principal0 + v1.income0, IAToken(A_USDC).balanceOf(address(adapter)));
        assertEq(adapter.ledger(USDC).principal, SUPPLIED);
    }

    /// DEC-068: collect withdraws only the interest; the vault receives exactly the income; principal stays.
    function test_DEC068_fork_collectOnlyInterest() public {
        _open(SUPPLIED);
        _accrue(30 days);
        uint256 pending = adapter.positionValue(key).income0;
        uint256 cumulativeBefore = adapter.cumulativeIncome(USDC);
        uint256 vaultBefore = _vaultBalance();

        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.collectIncome(key);

        assertEq(a.income0, pending);
        assertEq(a.principal0, 0);
        assertEq(_vaultBalance() - vaultBefore, pending, "vault did not receive the income");
        assertEq(adapter.ledger(USDC).principal, SUPPLIED);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.income0, 0);
        assertApproxEqAbs(v.principal0, SUPPLIED, 2);
        assertGe(adapter.cumulativeIncome(USDC), cumulativeBefore, "cumulative income regressed");
        assertEq(adapter.ledger(USDC).realizedIncome, pending);
        _assertAdapterHoldsNothing();

        // Income keeps accruing on the principal after a collection.
        _accrue(7 days);
        assertGt(adapter.positionValue(key).income0, 0);
        assertGt(adapter.cumulativeIncome(USDC), cumulativeBefore);
    }

    /// DEC-068: increase realizes the interest as income before re-basing the principal.
    function test_DEC068_fork_increaseRealizesIncomeThenRebases() public {
        _open(SUPPLIED);
        _accrue(30 days);
        uint256 pending = adapter.positionValue(key).income0;
        uint256 cumulativeBefore = adapter.cumulativeIncome(USDC);
        uint256 vaultBefore = _vaultBalance();

        vm.startPrank(vault);
        IERC20(USDC).transfer(address(adapter), SUPPLIED / 2);
        (uint256 used0, uint256 used1, uint256 income0, uint256 income1) =
            adapter.increasePosition(key, abi.encode(SUPPLIED / 2));
        vm.stopPrank();

        assertEq(used0, SUPPLIED / 2);
        assertEq(used1, 0);
        assertEq(income0, pending);
        assertEq(income1, 0);
        assertEq(vaultBefore - _vaultBalance(), SUPPLIED / 2 - pending, "vault net flow");
        assertEq(adapter.ledger(USDC).principal, SUPPLIED + SUPPLIED / 2);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertLe(v.income0, 1);
        assertApproxEqAbs(v.principal0, SUPPLIED + SUPPLIED / 2, 2);
        assertGe(adapter.cumulativeIncome(USDC), cumulativeBefore);
        assertEq(adapter.ledger(USDC).scaledBalance, IAToken(A_USDC).scaledBalanceOf(address(adapter)));
        _assertAdapterHoldsNothing();
    }

    /// DEC-068, DEC-079: partial and full withdrawals split principal and income exactly and pay every unit to the
    /// vault; after the close the adapter holds nothing.
    function test_DEC068_fork_decreaseThenCloseSplitsExactly() public {
        _open(SUPPLIED);
        _accrue(30 days);

        uint256 pending = adapter.positionValue(key).income0;
        uint256 vaultBefore = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(400_000e6)));
        assertEq(a.principal0, 400_000e6);
        assertEq(a.income0, pending);
        assertEq(a.principal1 + a.income1, 0);
        assertEq(_vaultBalance() - vaultBefore, a.principal0 + a.income0, "vault received the split");
        assertEq(adapter.ledger(USDC).principal, SUPPLIED - 400_000e6);
        assertLe(adapter.positionValue(key).income0, 1);
        uint256 cumulativeAfterDecrease = adapter.cumulativeIncome(USDC);
        _assertAdapterHoldsNothing();

        _accrue(15 days);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        vaultBefore = _vaultBalance();
        vm.prank(vault);
        a = adapter.closePosition(key, "");
        assertEq(a.principal0, v.principal0);
        assertGe(a.income0, v.income0);
        assertLe(a.income0, v.income0 + 1); // Aave may round the full balance one unit up
        assertApproxEqAbs(a.principal0, SUPPLIED - 400_000e6, 2);
        assertEq(_vaultBalance() - vaultBefore, a.principal0 + a.income0, "vault received the close");

        assertEq(IAToken(A_USDC).scaledBalanceOf(address(adapter)), 0, "aToken dust left");
        assertEq(IAToken(A_USDC).balanceOf(address(adapter)), 0);
        assertEq(adapter.positionKeys().length, 0);
        assertGe(adapter.cumulativeIncome(USDC), cumulativeAfterDecrease + v.income0);
        _assertAdapterHoldsNothing();
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPosition.selector, key));
        adapter.positionValue(key);
    }

    /// DEC-068: a withdrawal above the reserve's available liquidity reverts; the adapter never pays less than asked.
    /// Partial Payout handling is the vault's job.
    function test_DEC068_fork_withdrawAboveReserveLiquidityReverts() public {
        _open(SUPPLIED);
        _accrue(1 days);

        // A borrower drains the reserve down to 500k USDC of available liquidity.
        address borrower = makeAddr("borrower");
        uint256 available = IERC20(USDC).balanceOf(A_USDC);
        deal(WETH, borrower, 20_000 ether);
        vm.startPrank(borrower);
        IERC20(WETH).approve(POOL, type(uint256).max);
        IAaveV3Pool(POOL).supply(WETH, 20_000 ether, borrower, 0);
        IAaveV3PoolBorrow(POOL).borrow(USDC, available - 500_000e6, 2, 0, borrower);
        vm.stopPrank();
        assertEq(IERC20(USDC).balanceOf(A_USDC), 500_000e6);

        AaveV3Adapter.Ledger memory before = adapter.ledger(USDC);
        uint256 vaultBefore = _vaultBalance();

        vm.prank(vault);
        vm.expectRevert();
        adapter.decreasePosition(key, abi.encode(uint256(900_000e6)));

        vm.prank(vault);
        vm.expectRevert();
        adapter.closePosition(key, "");

        // Nothing moved and the ledger is intact.
        assertEq(_vaultBalance(), vaultBefore);
        AaveV3Adapter.Ledger memory afterRevert = adapter.ledger(USDC);
        assertEq(afterRevert.scaledBalance, before.scaledBalance);
        assertEq(afterRevert.principal, before.principal);

        // What the reserve can serve is still served in full.
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(100_000e6)));
        assertEq(a.principal0, 100_000e6);
        assertEq(_vaultBalance() - vaultBefore, a.principal0 + a.income0);
        _assertAdapterHoldsNothing();
    }

    /// DEC-080: aTokens transferred to the adapter by a third party are never reported; the close pays them out
    /// unreported to the vault, where the garbage collector sweeps them.
    function test_DEC080_fork_donatedATokensNotReported() public {
        _open(SUPPLIED);
        _accrue(10 days);
        IAdapter.PositionValue memory before = adapter.positionValue(key);

        address donor = makeAddr("donor");
        deal(USDC, donor, 5000e6);
        vm.startPrank(donor);
        IERC20(USDC).approve(POOL, 5000e6);
        IAaveV3Pool(POOL).supply(USDC, 5000e6, donor, 0);
        uint256 donated = IERC20(A_USDC).balanceOf(donor);
        IERC20(A_USDC).transfer(address(adapter), donated);
        vm.stopPrank();

        IAdapter.PositionValue memory afterDonation = adapter.positionValue(key);
        assertEq(afterDonation.principal0, before.principal0);
        assertEq(afterDonation.income0, before.income0);
        assertEq(adapter.cumulativeIncome(USDC), before.income0);

        uint256 vaultBefore = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");
        uint256 received = _vaultBalance() - vaultBefore;
        assertApproxEqAbs(a.principal0 + a.income0, before.principal0 + before.income0, 1);
        assertApproxEqAbs(received - (a.principal0 + a.income0), donated, 2, "donation paid out unreported");
        assertEq(IAToken(A_USDC).scaledBalanceOf(address(adapter)), 0);
        _assertAdapterHoldsNothing();
    }
}
