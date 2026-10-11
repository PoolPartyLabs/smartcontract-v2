// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {HubStackFixture} from "./HubStackFixture.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";

/// @title Regression (security review S-10): a deprecated hub adapter no longer breaks the automatic unwind or strands
///        the WETH leg
/// @notice Was PoC `test_POC_deprecatedHubAdapterBreaksUnwindAndStrandsWeth` (medium, liveness lens): deprecation gated
///         `swapExactInput`, the only way to turn a position's WETH leg into USDC, so after `deprecate()` every unwind
///         reverted (Partial Payouts from Free Idle only) and closed WETH had no path to Idle.
/// @notice FIX (S-10, `UniswapV4Adapter.swapExactInput`): a deprecated adapter still runs a swap INTO the vault's base
///         token (an exit, DEC-056, DEC-058 "withdraw-only"); a swap out of it stays blocked. The test asserts the
///         deprecated claim now completes like the one before deprecation, and the manager can sell closed WETH, now
///         through the Mandate swap adapter (DEC-136: the manager never swaps in the position's pool).
contract POC_DeprecatedAdapterUnwind is HubStackFixture {
    function test_SEC_S10_deprecatedHubAdapterStillUnwindsAndSellsWeth() public {
        _deposit(alice, 200_000e6); // 199,500 Idle after the flow fee
        bytes32 positionKey = _openHubPosition(100_000e6, 50_000e6, 50_000e6); // 20 WETH + 50,000 USDC in range
        assertEq(vault.freeIdle(), SEED_IDLE + 99_500e6);

        // Alice's Instant request is its own claim (DEC-120 item 1).
        uint256 snapshot = vm.snapshotState();
        ICoreVault.PayoutReceipt memory before = _request(alice, 150_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertEq(before.usdcOutstanding, 0);
        vm.revertToState(snapshot);

        vm.prank(guardian);
        adapter.deprecate();

        // The same claim completes: the unwind's WETH-to-USDC swap is an exit and runs.
        vm.recordLogs();
        ICoreVault.PayoutReceipt memory after_ = _request(alice, 150_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertFalse(_sawUnwindFailed(), "S-10: the unwind did not fail");
        assertEq(after_.usdcOutstanding, 0, "S-10: paid in full");
        assertApproxEqAbs(after_.unwindProceeds, before.unwindProceeds, 1e6, "S-10: the same unwind as before");

        // The manager can still close and sell the WETH into USDC through the swap adapter; re-entering the
        // deprecated adapter's pool stays blocked.
        vm.startPrank(manager);
        hubSpoke.closePosition(
            address(adapter), positionKey, abi.encode(UniswapV4Adapter.CloseParams(0, 0, block.timestamp))
        );
        uint256 wethHeld = hubSpoke.unallocatedBalance(address(weth));
        assertGt(wethHeld, 0);
        hubSpoke.swap(address(hubSwap), address(weth), address(usdc), wethHeld, 0, "");
        assertEq(hubSpoke.unallocatedBalance(address(weth)), 0, "S-10: no WETH stranded");
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hubSpoke.openPosition(address(adapter), poolId, 0, 1e6, "");
        vm.stopPrank();
    }

    function _sawUnwindFailed() internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(vault)
                    && logs[i].topics[0] == ICoreVaultPayouts.UnwindForPayoutFailed.selector
            ) {
                return true;
            }
        }
        return false;
    }
}
