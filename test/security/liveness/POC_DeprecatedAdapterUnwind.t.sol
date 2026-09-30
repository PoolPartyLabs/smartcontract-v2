// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {HubStackFixture} from "./HubStackFixture.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";

/// @title POC: deprecating the hub Uniswap V4 adapter breaks the automatic unwind and strands the WETH leg for good
/// @notice SEVERITY: medium (permanent DoS of the payout path through hub positions and a permanent freeze of every
///         non-USDC principal on the hub, from one irreversible guardian call, including a legitimate emergency one).
///
/// ATTACK / FAILURE
///   DEC-058 makes `deprecate()` global, immediate and irreversible, meant as "withdraw-only thereafter"; DEC-056 and
///   DEC-021 require the exit path (protocol -> Spoke Vault -> Core Vault -> Shareholder) to stay open. The OQ-04
///   stance gates `swapExactInput` on `deprecated` (UniswapV4Adapter.sol:523, AdapterGuard). But the exit path of a
///   two-token position is not only the liquidity removal: the automatic unwind (`SpokeVault.unwindForPayout`,
///   SpokeVault.sol:524) removes liquidity and then MUST swap the non-USDC leg into USDC through the same adapter
///   (`_unwindSwap` -> `_swap` -> `adapter.swapExactInput`, SpokeVault.sol:905-921), with no try/catch per step.
///   After `deprecate()`:
///     1. every claim whose shortfall needs a WETH/USDC position reverts inside the unwind (`AdapterIsDeprecated`),
///        the Core Vault catches it (`UnwindForPayoutFailed`) and pays only Free Idle: a Partial Payout, or
///        `InsufficientFreeIdle` when Free Idle is 0. The USDC leg the removal already produced is lost with the
///        revert, so not even that part is paid;
///     2. the manager's manual path is no better: `closePosition` works and books the WETH in Unallocated Balance,
///        but the vault's only way to turn it into USDC is the same gated `swapExactInput`, `returnToCoreVault`
///        moves the base token only, and the Mandate's closed lists (DEC-030, DEC-053) admit no other route.
///   The WETH therefore stays in the hub Spoke Vault forever, counted in Share Assets at the oracle price but
///   unpayable, while payouts drain the USDC first: the last holders own shares backed only by stranded WETH.
///
/// IMPACT
///   From the guardian key (an immutable address, Q17-2b OPEN): a compromised key can freeze every non-USDC leg of
///   every fund whose adapters it guards; a legitimate deprecation of a buggy adapter has the same effect, i.e. the
///   emergency tool destroys the exit it was meant to protect. Here a 150,000 USDC Instant claim that completed
///   before the call pays 99,500 (Free Idle) after it, leaves 50,500 outstanding, and 20 WETH have no path home.
///
/// FIX
///   Treat the unwind swap as an exit verb: never gate `swapExactInput` on `deprecated` when the input is a Mandate
///   pool token and the output is the base token (or add an explicit ungated `swapToBase` exit verb), and let
///   `unwindForPayout` skip a reverting swap while still crediting the USDC leg (continue to the next step, DEC-069's
///   "wait" applies to illiquidity, not to a flag). Alternatively make the Core Vault able to pay a payout in kind
///   (WETH) when USDC is exhausted, which DEC-109 already allows for fees.
contract POC_DeprecatedAdapterUnwind is HubStackFixture {
    function test_POC_deprecatedHubAdapterBreaksUnwindAndStrandsWeth() public {
        _deposit(alice, 200_000e6); // 199,500 Idle after the flow fee
        bytes32 positionKey = _openHubPosition(100_000e6, 50_000e6, 50_000e6); // 20 WETH + 50,000 USDC in range
        assertEq(vault.freeIdle(), 99_500e6);

        // A 150,000 USDC Instant claim needs 50,500 above Free Idle: the unwind removes part of the position and
        // swaps its WETH leg. Before the deprecation the claim completes.
        _request(alice, 150_000e6, ICoreVault.PayoutMode.Instant);
        uint256 snapshot = vm.snapshotState();
        ICoreVault.PayoutReceipt memory before = _claim(alice);
        assertEq(before.usdcOutstanding, 0);
        assertGt(before.unwindProceeds, 50_000e6);
        vm.revertToState(snapshot);

        // The guardian deprecates the adapter (irreversible, DEC-058).
        vm.prank(guardian);
        adapter.deprecate();

        // 1. The same claim now fails to unwind at all and pays only Free Idle.
        vm.recordLogs();
        ICoreVault.PayoutReceipt memory after_ = _claim(alice);
        assertTrue(_sawUnwindFailed(), "UnwindForPayoutFailed emitted");
        assertEq(after_.unwindProceeds, 0);
        assertApproxEqAbs(after_.usdcGross, 99_500e6, 1e6);
        assertApproxEqAbs(after_.usdcOutstanding, 50_500e6, 1e6);
        assertLt(vault.freeIdle(), 1e6);

        // 2. A second claim cannot serve anything: Free Idle is 0 and the unwind keeps reverting.
        vm.prank(alice);
        vm.expectPartialRevert(ICoreVault.InsufficientFreeIdle.selector);
        vault.claimPayout("");

        // 3. The manager can pull the liquidity, but the WETH has no path to USDC: the swap is gated, the return to
        //    the Core Vault takes USDC only, and the Mandate lists no other adapter or pool.
        vm.startPrank(manager);
        hubSpoke.closePosition(
            address(adapter), positionKey, abi.encode(UniswapV4Adapter.CloseParams(0, 0, block.timestamp))
        );
        uint256 strandedWeth = hubSpoke.unallocatedBalance(address(weth));
        assertGt(strandedWeth, 19e18);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hubSpoke.swapExactInput(address(adapter), poolId, address(weth), strandedWeth, 0, "");
        hubSpoke.returnToCoreVault(hubSpoke.unallocatedBalance(address(usdc)));
        vm.stopPrank();

        // 4. The USDC that came back pays part of the outstanding claim; the WETH stays counted but unpayable.
        ICoreVault.PayoutReceipt memory last = _claim(alice);
        assertEq(last.unwindProceeds, 0);
        assertGt(last.usdcOutstanding, 0);
        assertLt(vault.freeIdle(), 1e6);
        assertEq(hubSpoke.unallocatedBalance(address(weth)), strandedWeth);
        assertGt(vault.shareAssets(), 49_000e6); // about 20 WETH at 2,500 still backing alice's remaining shares
        assertGt(shares.balanceOf(alice), 0);
    }

    function _sawUnwindFailed() internal view returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(vault) && logs[i].topics[0] == ICoreVault.UnwindForPayoutFailed.selector) {
                return true;
            }
        }
        return false;
    }
}
