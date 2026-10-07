// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {MockAaveV3Pool} from "../../mocks/aave/MockAaveV3Pool.sol";
import {AaveV3AdapterFixture} from "./AaveV3Adapter.t.sol";

/// @notice Regression of the independent verification plan's F1 (review L-08, PoC
///         `AaveIncomeBurnUnderflow.t.sol`): when the reserve cannot pay the adapter's whole aToken balance, the exit
///         withdraws the principal and then the income best effort; Aave rounds that last burn up, one scaled unit
///         above what the ledger holds. Without foreign aTokens Aave refuses it (the income stays pending); with a
///         stranger's aTokens in the adapter Aave took the unit from them and the adapter reverted `LedgerUnderflow`,
///         blocking the whole exit. That one unit now empties the ledger. Mock pool with the live Arbitrum rounding.
contract AaveV3AdapterForeignATokensTest is AaveV3AdapterFixture {
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");

    function _rounding() internal pure override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.Directional;
    }

    /// @dev 1,000 USDC supplied at index 1.0, index grown to 1.1: principal 1,000, pending income 100; a stranger
    ///      supplies 50 on the adapter's behalf; the reserve holds 1,110 of liquidity, so the one-shot maximum
    ///      withdrawal (1,150) fails and the exit takes the principal-then-income path.
    function _positionWithForeignATokens() internal {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        asset.mint(stranger, 50e6);
        vm.startPrank(stranger);
        asset.approve(address(pool), 50e6);
        pool.supply(address(asset), 50e6, address(adapter), 0);
        vm.stopPrank();
        uint256 held = asset.balanceOf(address(aToken));
        aToken.lendOut(borrower, held - 1110e6);
    }

    function test_REVIEW_F1_foreignATokensNoLongerBlockTheClose() public {
        _positionWithForeignATokens();
        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");
        assertEq(a.principal0, 1000e6, "the principal left");
        assertEq(a.income0, 100e6, "and the income with it");
        assertEq(_vaultBalance() - before, 1100e6);
        assertEq(adapter.ledger(address(asset)).scaledBalance, 0, "the last rounding unit emptied the ledger");
        assertFalse(adapter.ledger(address(asset)).open);
        _assertAdapterHoldsNothing();
    }

    function test_REVIEW_F1_foreignATokensNoLongerBlockAWholePrincipalDecrease() public {
        _positionWithForeignATokens();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(1000e6)));
        assertEq(a.principal0, 1000e6);
        assertEq(a.income0, 100e6);
    }
}
