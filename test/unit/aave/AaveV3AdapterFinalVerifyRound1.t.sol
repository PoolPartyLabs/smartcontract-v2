// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {AaveV3AdapterFixture} from "./AaveV3Adapter.t.sol";

/// @notice Adversarial verification, round 1, of the final verification fixes on the Aave V3 Adapter (DEC-056,
///         DEC-059, DEC-068, DEC-080, Q60): the principal-first exits and the best-effort income under a reserve
///         short of liquidity, with the rounding of the live Arbitrum pool.
contract AaveV3AdapterFinalVerifyRound1Test is AaveV3AdapterFixture {
    address internal borrower = makeAddr("borrower");

    function _rounding() internal pure override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.Directional;
    }

    /// @dev Borrowers take everything but `liquidity` out of the reserve.
    function _drainReserveTo(uint256 liquidity) internal {
        aToken.lendOut(borrower, asset.balanceOf(address(aToken)) - liquidity);
        assertEq(asset.balanceOf(address(aToken)), liquidity);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-068 / DEC-056: the whole principal asked by amount, not by `type(uint256).max`, under low liquidity
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-068, DEC-056, DEC-059 (final verification): a decrease that asks the whole current principal by amount is
    /// a full exit too. The one-shot maximum withdrawal fails on the reserve's liquidity, the ledger is restored and
    /// the principal-first path serves all of it, then the income up to the liquidity left. A decrease never closes,
    /// so the key stays open holding only the pending income, and the scaled ledger still matches the aToken (nothing
    /// was debited twice across the failed attempt and the fallback).
    function test_DEC068_decreaseOfTheWholePrincipalByAmountUnderLowLiquidityServesItPrincipalFirst() public {
        _open(1000e6);
        _grow(RAY * 11 / 10); // 100e6 of pending income
        _drainReserveTo(1040e6); // the principal and 40 of the income

        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(1000e6)));
        assertEq(a.principal0, 1000e6, "the whole principal is served");
        assertEq(a.income0, 40e6, "income only up to the liquidity left");
        assertEq(_vaultBalance() - before, 1040e6);
        assertEq(asset.balanceOf(address(aToken)), 0, "the reserve is empty");

        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertTrue(l.open, "a decrease never closes the key");
        assertEq(adapter.positionKeys().length, 1);
        assertEq(l.principal, 0);
        assertEq(
            l.scaledBalance, aToken.scaledBalanceOf(address(adapter)), "the ledger was restored before the fallback"
        );
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.principal0, 0);
        assertApproxEqAbs(v.income0, 60e6, 2, "the rest of the income stays pending");
        _assertAdapterHoldsNothing();

        // Liquidity returns: the close takes exactly what is pending and empties the position.
        asset.mint(address(aToken), 100e6);
        before = _vaultBalance();
        vm.prank(vault);
        a = adapter.closePosition(key, "");
        assertEq(a.principal0, 0);
        assertEq(a.income0, v.income0);
        assertEq(_vaultBalance() - before, v.income0);
        assertFalse(adapter.ledger(address(asset)).open);
        assertEq(adapter.positionKeys().length, 0);
        assertEq(aToken.scaledBalanceOf(address(adapter)), 0);
        _assertAdapterHoldsNothing();
    }

    /// DEC-068, DEC-056 (final verification): an increase under a reserve with no liquidity at all never blocks: the
    /// income is paid from the liquidity the increase itself supplied, the rest stays pending.
    function test_DEC068_increaseUnderAnEmptyReservePaysIncomeFromItsOwnSupply() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        _drainReserveTo(0);

        _fund(30e6);
        uint256 before = _vaultBalance();
        vm.prank(vault);
        (uint256 used0,, uint256 income0,) = adapter.increasePosition(key, abi.encode(uint256(30e6)));
        assertEq(used0, 30e6);
        assertEq(income0, 30e6, "the income is paid from the liquidity the increase supplied");
        assertEq(_vaultBalance() - before, 30e6);
        assertEq(asset.balanceOf(address(aToken)), 0);
        assertApproxEqAbs(adapter.ledger(address(asset)).principal, 1030e6, 2);
        assertApproxEqAbs(adapter.positionValue(key).income0, 70e6, 2, "the rest stays pending");
        _assertAdapterHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Q60 (MINOR, pinned): the counter is not strictly monotonic under partial income
    // ---------------------------------------------------------------------------------------------------------------

    /// Q60 (final verification, MINOR, pinned): `cumulativeIncome` is documented as never regressing, and the fix
    /// charges a withdrawal's rounding to principal (AAVE-3) so that it does not. Two paths still lower it by Aave's
    /// scaled rounding, up to ceil(index / 1e27) units per Aave call: (a) an increase whose income is only partly
    /// paid, because the rounding of the supply itself is measured into the pending income (`valueBefore` is read
    /// after the supply); (b) any exit that leaves the principal at zero with income still pending, because there is
    /// no principal left to charge. Dust, and the counter is informational on the hub (the income index advances only
    /// at collection), so the behaviour is pinned as it is: the fix documents the bound or keeps the rounding out of
    /// the pending income.
    function test_Q60_MINOR_partialIncomeUnderLowLiquidityRegressesTheCounterByTheRounding() public {
        // (a) increase: the supply's rounding lands on the pending income.
        _open(1000e6);
        _grow(RAY * 11 / 10);
        _drainReserveTo(0);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);
        _fund(30e6);
        vm.prank(vault);
        adapter.increasePosition(key, abi.encode(uint256(30e6)));
        assertEq(adapter.ledger(address(asset)).principal, 1_029_999_999, "the withdrawal's rounding is on principal");
        assertEq(adapter.positionValue(key).income0, 69_999_999, "the supply's rounding is on the income");
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6 - 1, "the counter regressed by one unit");

        // (b) exit that exhausts the principal: the two withdrawals' rounding has no principal to be charged to.
        asset.mint(address(aToken), 1_029_999_999 + 40e6);
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(1_029_999_999)));
        assertEq(a.principal0, 1_029_999_999);
        assertEq(a.income0, 40e6);
        assertEq(adapter.ledger(address(asset)).principal, 0);
        assertLt(adapter.cumulativeIncome(address(asset)), 100e6 - 1, "the counter regressed again");
        assertGe(adapter.cumulativeIncome(address(asset)), 100e6 - 4, "by the rounding of two Aave calls at most");
        _assertAdapterHoldsNothing();
    }
}
