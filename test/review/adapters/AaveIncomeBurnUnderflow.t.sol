// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {AaveV3AdapterFixture} from "../../unit/aave/AaveV3Adapter.t.sol";

/// @notice (adapters review) The "income best effort" withdrawal of `AaveV3Adapter._takeIncome` can burn one scaled
///         unit more than the ledger holds after a whole-principal withdrawal. Without foreign aTokens Aave itself
///         refuses that withdrawal (caught, income stays pending); with any foreign aTokens in the adapter Aave accepts it
///         and the adapter's own `LedgerUnderflow` check (outside the try/catch) reverts the whole exit. Mock pool with
///         the live Arbitrum rounding (mint down, burn up, balance down), as in the adapter's own unit suite.
/// @dev Run: forge test --match-path 'test/review/adapters/AaveIncomeBurnUnderflow.t.sol' -vv
contract AaveIncomeBurnUnderflowTest is AaveV3AdapterFixture {
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");

    function _rounding() internal pure override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.Directional;
    }

    /// @dev 1,000 USDC supplied at index 1.0, index grown to 1.1: principal 1,000, pending income 100.
    function _position() internal {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        assertEq(adapter.positionValue(key).principal0, 1000e6);
        assertEq(adapter.positionValue(key).income0, 100e6);
    }

    function _setReserveLiquidity(uint256 liquidity) internal {
        uint256 held = asset.balanceOf(address(aToken));
        if (held > liquidity) aToken.lendOut(borrower, held - liquidity);
        else asset.mint(address(aToken), liquidity - held);
        assertEq(asset.balanceOf(address(aToken)), liquidity);
    }

    /// Control: the reserve holds 1,110 USDC of liquidity, enough for the fund's whole 1,100. The close succeeds.
    function test_control_closeSucceedsWithoutForeignATokens() public {
        _position();
        _setReserveLiquidity(1110e6);
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");
        assertEq(a.principal0 + a.income0, 1100e6);
        assertFalse(adapter.ledger(address(asset)).open);
    }

    function _foreignATokens() internal returns (uint256 ledgerAfterPrincipal, uint256 incomeBurn) {
        _position();
        asset.mint(stranger, 50e6);
        vm.startPrank(stranger);
        asset.approve(address(pool), 50e6);
        pool.supply(address(asset), 50e6, address(adapter), 0);
        vm.stopPrank();
        _setReserveLiquidity(1110e6);

        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        ledgerAfterPrincipal = l.scaledBalance - (1000e6 * RAY + RAY * 11 / 10 - 1) / (RAY * 11 / 10);
        incomeBurn = (100e6 * RAY + RAY * 11 / 10 - 1) / (RAY * 11 / 10);
        assertEq(incomeBurn, ledgerAfterPrincipal + 1, "the income burn is still one scaled unit above the ledger left");
    }

    /// Ported to fix/pp-sc-fix-independent-review (review L-08, plan F1): FIXED. A stranger supplies 50 USDC on the
    /// adapter's behalf (foreign aTokens, DEC-080: never reported). Same reserve liquidity (1,110): the one-shot maximum
    /// withdrawal asks for 1,150 and fails, the fallback withdraws the 1,000 of principal, then the 100 of income burns
    /// one scaled unit more than the ledger holds. e5c778a: `LedgerUnderflow`, the whole exit reverted. Now the one
    /// unit is taken from the foreign aTokens and empties the ledger: the exit completes with principal and income.
    function test_REVIEW_L08_foreignATokensNoLongerBlockTheClose() public {
        _foreignATokens();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");
        assertEq(a.principal0, 1000e6, "the whole principal left");
        assertEq(a.income0, 100e6, "and the income with it");
        assertFalse(adapter.ledger(address(asset)).open, "the position is closed");
        assertEq(adapter.ledger(address(asset)).scaledBalance, 0, "the ledger is empty");
    }

    /// The same for a decrease of the whole principal by amount (the same path).
    function test_REVIEW_L08_foreignATokensNoLongerBlockAWholeDecrease() public {
        _foreignATokens();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(1000e6)));
        assertEq(a.principal0, 1000e6, "the whole principal left");
        assertEq(a.income0, 100e6, "and the income with it");
        assertEq(adapter.ledger(address(asset)).scaledBalance, 0, "the ledger is empty");
    }
}
