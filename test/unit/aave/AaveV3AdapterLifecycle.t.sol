// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {AaveV3AdapterFixture} from "./AaveV3Adapter.t.sol";

/// @notice Random sequences of adapter verbs with a growing index. After every step: the vault's balance moved by
///         exactly what the adapter reported, the adapter holds no asset and no approval, the ledger matches the aToken's
///         scaled balance, and cumulative income never decreases. At the end, every unit supplied or earned came back
///         as principal or income, up to Aave's per-operation rounding.
contract AaveV3AdapterLifecycleTest is AaveV3AdapterFixture {
    uint256 internal suppliedTotal;
    uint256 internal principalReturned;
    uint256 internal incomeReturned;
    uint256 internal lastCumulative;
    uint256 internal operations;

    function _rounding() internal pure virtual override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.Directional;
    }

    function _checkStep() internal {
        _assertAdapterHoldsNothing();
        assertEq(adapter.ledger(address(asset)).scaledBalance, aToken.scaledBalanceOf(address(adapter)), "ledger");
        uint256 cumulative = adapter.cumulativeIncome(address(asset));
        assertGe(cumulative, lastCumulative, "Q60: cumulative income regressed");
        lastCumulative = cumulative;
        ++operations;
    }

    function _step(uint256 r) internal {
        uint256 op = r % 4;
        r >>= 8;
        if (op == 0) {
            uint256 index = pool.indexOf(address(asset));
            _grow(index + index * bound(r, 0, 500) / 10_000);
            return;
        }
        uint256 before = _vaultBalance();
        if (op == 1) {
            vm.prank(vault);
            IAdapter.Amounts memory a = adapter.collectIncome(key);
            assertEq(_vaultBalance() - before, a.income0, "collect paid what it reported");
            assertEq(a.principal0, 0);
            incomeReturned += a.income0;
        } else if (op == 2) {
            uint256 amount = bound(r, 1, 1e13);
            _fund(amount);
            vm.prank(vault);
            (uint256 used0,, uint256 income0,) = adapter.increasePosition(key, "");
            assertEq(used0, amount);
            assertEq(before + income0 - _vaultBalance(), amount, "increase net flow");
            suppliedTotal += used0;
            incomeReturned += income0;
        } else {
            uint256 principalNow = adapter.positionValue(key).principal0;
            if (principalNow < 2) return;
            uint256 amount = bound(r, 1, principalNow - 1);
            vm.prank(vault);
            IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(amount));
            assertEq(a.principal0, amount);
            assertEq(_vaultBalance() - before, a.principal0 + a.income0, "decrease paid what it reported");
            principalReturned += a.principal0;
            incomeReturned += a.income0;
        }
        _checkStep();
    }

    function testFuzz_DEC068_Q60_lifecycleConservesValue(uint256 seed, uint256 firstAmount) public {
        firstAmount = bound(firstAmount, 1e6, 1e13);
        _open(firstAmount);
        suppliedTotal = firstAmount;
        _checkStep();

        for (uint256 i; i < 16; ++i) {
            _step(uint256(keccak256(abi.encode(seed, i))));
        }

        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");
        assertEq(_vaultBalance() - before, a.principal0 + a.income0, "close paid what it reported");
        principalReturned += a.principal0;
        incomeReturned += a.income0;
        _checkStep();

        assertEq(aToken.scaledBalanceOf(address(adapter)), 0, "aToken dust left");
        assertEq(adapter.cumulativeIncome(address(asset)), incomeReturned, "counter equals income paid");
        assertLe(principalReturned, suppliedTotal, "principal never grows");
        // Aave's scaled arithmetic loses at most ceil(index / 1e27) + 1 units per operation, borne by principal.
        assertGe(principalReturned + 4 * operations, suppliedTotal, "principal lost beyond rounding");
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertEq(l.principal + l.scaledBalance, 0);
    }
}

/// @notice Same lifecycle under the half-up rounding of Aave up to v3.4.
contract AaveV3AdapterLifecycleHalfUpTest is AaveV3AdapterLifecycleTest {
    function _rounding() internal pure override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.HalfUp;
    }
}
