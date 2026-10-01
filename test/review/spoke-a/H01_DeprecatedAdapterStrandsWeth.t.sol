// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {SpokeAHubFixture} from "./SpokeAHubFixture.sol";

/// @notice [H-07] (spoke-a report H-01), ported to main. At `e5c778a` a deprecated V4 adapter refused every swap, so
///         the first V4 step made the whole automatic unwind revert (Mallory paid 47,370.86 from Idle, 1,629.14
///         outstanding) and the WETH of a closed position could never become USDC (Alice left 249,125.25 short for
///         good). Security review S-10: a deprecated adapter still runs a swap INTO the vault's base token, so the
///         unwind and the manager's exit swap work again; a swap out of the base token (an entry) stays blocked.
contract H01_DeprecatedAdapterStrandsWeth is SpokeAHubFixture {
    bytes32 internal exactKey;

    function _setUpFund() internal {
        _deposit(alice, 1_000_000e6);
        _deposit(mallory, 50_000e6);
        _managerOpensHubPosition(500_000e6); // V4 WETH/USDC, first in the unwind order
        exactKey = _managerSuppliesExact(500_000e6); // exact-value USDC, second in the unwind order
        _unwindSwapsAtOracle();
        // Free Idle ~47,372 USDC; Mallory's shares are worth ~49,875 USDC.
        _request(mallory, 49_000e6, ICoreVault.PayoutMode.Instant);
    }

    /// @dev Control: before the deprecation the claim needs ~1,580 USDC of unwind and is paid in full.
    function test_REVIEW_H07_control_unwindPaysBeforeDeprecation() public {
        _setUpFund();
        ICoreVault.PayoutReceipt memory r = _claim(mallory);
        assertGt(r.unwindProceeds, 1500e6);
        assertFalse(vault.payoutRequest(mallory).open, "paid in full");
    }

    function test_REVIEW_H07_deprecatedV4AdapterStillServesTheAutomaticUnwind() public {
        _setUpFund();
        ICoreVault.PayoutReceipt memory control;
        {
            uint256 snap = vm.snapshotState();
            control = _claim(mallory);
            vm.revertToState(snap);
        }
        vm.prank(guardian);
        IAdapterGuard(address(adapter)).deprecate();

        ICoreVault.PayoutReceipt memory r = _claim(mallory);
        console2.log("unwind proceeds (deprecated)", r.unwindProceeds);
        console2.log("usdc gross paid", r.usdcGross);

        // The same unwind as without deprecation: the V4 exit's WETH is swapped into USDC, the claim is paid in full.
        assertEq(r.unwindProceeds, control.unwindProceeds, "deprecation no longer changes the unwind");
        assertEq(r.usdcGross, control.usdcGross);
        assertEq(r.usdcOutstanding, 0);
        assertFalse(vault.payoutRequest(mallory).open, "paid in full");
    }

    function test_REVIEW_H07_deprecationNoLongerStrandsTheWethLeg() public {
        _setUpFund();
        vm.prank(guardian);
        IAdapterGuard(address(adapter)).deprecate();

        // The manager exits the V4 position (exit verbs are never gated, DEC-056).
        bytes memory closeParams =
            abi.encode(UniswapV4Adapter.CloseParams({amount0Min: 0, amount1Min: 0, deadline: block.timestamp}));
        vm.prank(manager);
        hubVault.closePosition(address(adapter), positionKey, closeParams);
        uint256 wethHeld = hubVault.unallocatedBalance(address(weth));
        assertEq(wethHeld, 99_999_999_999_999_999_999);

        // An entry (USDC -> WETH) stays blocked on the deprecated adapter (DEC-058) ...
        vm.prank(manager);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hubVault.swapExactInput(address(adapter), poolId, address(usdc), 1e6, 0, "");

        // ... but the exit swap into the base token runs (S-10): the WETH becomes USDC at the oracle rate.
        vm.prank(manager);
        uint256 usdcOut = hubVault.swapExactInput(address(adapter), poolId, address(weth), wethHeld, 0, "");
        console2.log("USDC from the stranded WETH", usdcOut);
        assertEq(hubVault.unallocatedBalance(address(weth)), 0, "no WETH left behind");
        assertEq(usdcOut, wethHeld * 2500e6 / 1e18);

        // Mallory, then Alice for her whole value, are paid in full.
        _claim(mallory);
        assertFalse(vault.payoutRequest(mallory).open);
        uint256 aliceValue = _valueOf(alice);
        _request(alice, aliceValue, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        console2.log("alice asked", aliceValue);
        console2.log("alice paid (gross)", r.usdcGross);
        assertEq(r.usdcOutstanding, 0, "e5c778a: 249,125.25 outstanding for good");
        assertFalse(vault.payoutRequest(alice).open, "Alice's request closes");
    }
}
