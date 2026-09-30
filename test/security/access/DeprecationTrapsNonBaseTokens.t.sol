// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: deprecating the Uniswap V4 adapter traps every non-base token of the fund for good
/// @notice ATTACK / TRIGGER. The adapter guardian (one immutable address for every adapter of every fund,
///         FundFactory.sol:110) calls `deprecate()` on a fund's Uniswap V4 adapter (AdapterGuard.sol:43,
///         irreversible). DEC-056 and DEC-058 promise "withdraw-only thereafter" with the exit path protocol ->
///         Spoke Vault -> Core Vault -> Shareholder always open. But `UniswapV4Adapter.swapExactInput` reverts when
///         deprecated (UniswapV4Adapter.sol:523, the OQ-04 stance "a swap is blocked when deprecated"), and that
///         swap is the ONLY way a Spoke Vault can turn a non-base token (WETH) into its base token:
///         - the automatic unwind of a claim exits the position and then swaps the WETH it returned
///           (SpokeVault.sol:863-864, 905-920); the swap reverts, the whole `unwindForPayout` reverts, and the claim
///           is cut down to what Idle holds (`UnwindForPayoutFailed`);
///         - the manager can still close the position, but the WETH lands in Unallocated Balance and no verb moves
///           it: `swapExactInput` reverts, `openPosition` reverts, `returnToCoreVault` / `sendToHub` only move the
///           base token, `sweepExcess` never touches ledger value.
///         This is not only a rogue or compromised guardian: the INTENDED use of the flag (a bug in the adapter,
///         DEC-058) has the same effect on every fund at once.
/// @notice IMPACT. The WETH half of every Uniswap V4 position (all of it when the price left the range on the WETH
///         side) is frozen permanently in the Spoke Vault while Share Assets keep counting it at the oracle price.
///         Payouts are served from Idle at that overstated Share Price until Idle runs out; the last shareholders
///         hold shares backed only by WETH nobody can ever pay out. Same on a Spoke Chain: WETH cannot be swapped
///         into USDG, so it can never be sent home.
/// @notice FIX. Treat a swap INTO the chain's base token as an exit verb, never gated by `deprecated` (keep the gate
///         for swaps out of the base token), or give the Spoke Vault an exit for non-base principal that does not go
///         through the deprecated adapter (for example a second, swap-only adapter role in the Mandate).
contract DeprecationTrapsNonBaseTokensPoC is AccessFundFixture {
    CoreVault internal core;
    SpokeVault internal hub;
    address internal adapter;
    bytes32 internal poolId;
    bytes32 internal positionKey;

    function setUp() public override {
        super.setUp();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        core = CoreVault(a.coreVault);
        hub = _hubVault(a);
        adapter = a.chains[0].uniswapV4Adapter;
        poolId = _hubPoolId();

        _deposit(core, alice, 500_000e6);
        _deposit(core, bob, 500_000e6);
        // The manager puts 800,000 USDC to work in the Mandate's WETH / USDC pool: half swapped into WETH, then one
        // position around the current price. 197,500 USDC stay in Idle.
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(800_000e6);
        hub.swapExactInput(adapter, poolId, address(usdc), 400_000e6, 0, "");
        (positionKey,,) = hub.openPosition(adapter, poolId, 400_000e6, 400_000e6, _openParams(400_000e6, 400_000e6));
        vm.stopPrank();
        assertApproxEqAbs(core.shareAssets(), 997_500e6, 10, "Idle plus the position, WETH at the oracle price");
    }

    /// @dev Without the flag the claim unwinds the position and pays in full; with it the unwind fails and the claim
    ///      is cut down to Idle.
    function test_POC_deprecationBreaksTheAutomaticUnwindOfAClaim() public {
        vm.prank(alice);
        core.requestPayout(400_000e6, ICoreVault.PayoutMode.Instant);

        // Control: the same claim before the flag is a complete Payout.
        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory healthy = core.claimPayout("");
        assertEq(healthy.usdcOutstanding, 0);
        assertGt(healthy.unwindProceeds, 200_000e6, "the unwind brought the shortfall to Idle");
        assertFalse(core.payoutRequest(alice).open, "request closed");
        vm.revertToState(snapshot);

        vm.prank(guardian);
        UniswapV4Adapter(adapter).deprecate();

        vm.expectEmit(false, false, false, false, address(core));
        emit ICoreVault.UnwindForPayoutFailed(0);
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory r = core.claimPayout("");
        assertEq(r.unwindProceeds, 0, "the unwind reverted on the WETH swap");
        assertLt(r.usdcGross, 197_501e6, "paid from Idle only");
        assertGt(r.usdcOutstanding, 202_000e6, "more than half of the request stays unpaid");
        assertTrue(core.payoutRequest(alice).open, "and the request can never be cancelled (DEC-024)");
    }

    /// @dev The manager does everything the contracts allow after the flag. The WETH never leaves.
    function test_POC_deprecationTrapsTheWethPrincipalForGood() public {
        vm.prank(guardian);
        UniswapV4Adapter(adapter).deprecate();

        // Exit verbs still work (DEC-056): the position comes back in kind.
        vm.startPrank(manager);
        hub.closePosition(adapter, positionKey, abi.encode(UniswapV4Adapter.CloseParams(0, 0, block.timestamp)));
        uint256 trapped = hub.unallocatedBalance(address(weth));
        assertGt(trapped, 399_000e6, "about 400,000 USDC worth of WETH is back in Unallocated Balance");

        // The only verb that turns WETH into USDC is gated by the flag; so is re-entering a position.
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hub.swapExactInput(adapter, poolId, address(weth), trapped, 0, "");
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hub.openPosition(adapter, poolId, trapped, trapped, _openParams(uint128(trapped), uint128(trapped)));

        // Everything the manager can bring home is the USDC.
        hub.returnToCoreVault(hub.unallocatedBalance(address(usdc)));
        vm.stopPrank();
        assertEq(hub.sweepExcess(address(weth)), 0, "ledger value is never swept");

        // Alice exits first and is paid in full at a Share Price that still counts the trapped WETH.
        vm.startPrank(alice);
        core.requestPayout(498_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory first = core.claimPayout("");
        vm.stopPrank();
        assertEq(first.usdcOutstanding, 0);
        assertApproxEqRel(first.sharePrice, 1e24, 0.01e18, "still about 1.00 USDC per share");

        // Bob holds the same number of shares. He gets what Idle has left; the rest of his claim is backed by WETH
        // that no function can move.
        vm.startPrank(bob);
        core.requestPayout(498_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory second = core.claimPayout("");
        assertLt(second.usdcGross, 110_000e6, "Bob is paid about a fifth of what Alice got for the same shares");
        assertGt(second.usdcOutstanding, 388_000e6);

        vm.expectPartialRevert(ICoreVault.InsufficientFreeIdle.selector);
        core.claimPayout("");
        vm.stopPrank();

        assertLt(core.idle(), 1e6, "Idle is empty");
        assertEq(hub.unallocatedBalance(address(weth)), trapped, "the WETH is still there");
        assertGt(core.shareAssets(), 399_000e6, "and Share Assets still count it behind Bob's remaining shares");
        assertGt(_shares(core, bob), 380_000e18);
    }
}
