// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {UniswapV3SwapAdapter} from "../../../src/adapters/UniswapV3SwapAdapter.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-10): deprecating the Uniswap V4 adapter no longer traps the fund's non-base
///        tokens or breaks the automatic unwind
/// @notice Was PoCs `test_POC_deprecationBreaksTheAutomaticUnwindOfAClaim` and
///         `test_POC_deprecationTrapsTheWethPrincipalForGood` (high, access lens): `swapExactInput` reverted when
///         deprecated and is the only way a Spoke Vault turns WETH into its base token, so one guardian call cut every
///         unwinding claim to Idle and left closed WETH unreachable while Share Assets kept counting it.
/// @notice FIX (S-10, `UniswapV4Adapter.swapExactInput`): a deprecated adapter still runs a swap INTO the vault's base
///         token (an exit, DEC-056, DEC-058); a swap out of it and every entry stay blocked. Both tests assert the
///         attack now FAILS. Since DEC-136 the manager's sale runs through the fund's swap adapter, never in the
///         position's pool; the same exit rule holds there (`UniswapV3SwapAdapter`), and the test deprecates both.
contract DeprecationTrapsNonBaseTokensPoC is AccessFundFixture {
    CoreVault internal core;
    SpokeVault internal hub;
    address internal adapter;
    address internal swapAdapter;
    bytes32 internal poolId;
    bytes32 internal positionKey;

    function setUp() public override {
        super.setUp();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        core = CoreVault(a.coreVault);
        hub = _hubVault(a);
        adapter = a.chains[0].uniswapV4Adapter;
        swapAdapter = a.chains[0].uniswapV3SwapAdapter;
        poolId = _hubPoolId();
        _v3WethUsdcPool();

        _deposit(core, alice, 500_000e6);
        _deposit(core, bob, 500_000e6);
        // The manager puts 800,000 USDC to work in the Mandate's WETH / USDC pool: half swapped into WETH through the
        // swap adapter (its 0.01% pool keeps 40 USDC), then one position around the current price. 197,500 USDC stay
        // in Idle.
        vm.startPrank(manager);
        core.allocateToHubSpokeVault(800_000e6);
        uint128 wethOut = uint128(hub.swap(swapAdapter, address(usdc), address(weth), 400_000e6, 0, ""));
        (positionKey,,) = hub.openPosition(adapter, poolId, wethOut, wethOut, _openParams(wethOut, wethOut));
        vm.stopPrank();
        assertApproxEqAbs(
            core.shareAssets(), SEED_IDLE + 997_460e6, 10, "Idle plus the position, WETH at the oracle price"
        );
    }

    /// @dev With the flag the claim still unwinds the position and pays in full.
    function test_SEC_S10_deprecationNoLongerBreaksTheAutomaticUnwindOfAClaim() public {
        vm.prank(alice);
        core.requestPayout(400_000e6, ICoreVaultPayouts.PayoutMode.Instant);

        uint256 snapshot = vm.snapshotState();
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory healthy = core.claimPayout("");
        assertEq(healthy.usdcOutstanding, 0);
        vm.revertToState(snapshot);

        vm.prank(guardian);
        UniswapV4Adapter(adapter).deprecate();

        vm.prank(alice);
        ICoreVault.PayoutReceipt memory r = core.claimPayout("");
        assertEq(r.usdcOutstanding, 0, "S-10: paid in full");
        assertEq(r.unwindProceeds, healthy.unwindProceeds, "S-10: the same unwind as without the flag");
        assertFalse(core.payoutRequest(alice).open, "request closed");
    }

    /// @dev After the flag the manager closes the position and sells the WETH into USDC; nothing is trapped.
    function test_SEC_S10_deprecationNoLongerTrapsTheWethPrincipal() public {
        vm.startPrank(guardian);
        UniswapV4Adapter(adapter).deprecate();
        UniswapV3SwapAdapter(swapAdapter).deprecate();
        vm.stopPrank();

        vm.startPrank(manager);
        hub.closePosition(adapter, positionKey, abi.encode(UniswapV4Adapter.CloseParams(0, 0, block.timestamp)));
        uint256 wethHeld = hub.unallocatedBalance(address(weth));
        assertGt(wethHeld, 0);

        // Entries stay blocked; the exit swap into USDC runs.
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hub.openPosition(adapter, poolId, wethHeld, wethHeld, _openParams(uint128(wethHeld), uint128(wethHeld)));
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hub.swap(swapAdapter, address(usdc), address(weth), 1e6, 0, "");
        hub.swap(swapAdapter, address(weth), address(usdc), wethHeld, 0, "");
        assertEq(hub.unallocatedBalance(address(weth)), 0, "S-10: no WETH left behind");
        hub.returnToCoreVault(hub.unallocatedBalance(address(usdc)));
        vm.stopPrank();

        // Alice and Bob, with the same shares, are paid the same.
        vm.startPrank(alice);
        core.requestPayout(498_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory first = core.claimPayout("");
        vm.stopPrank();
        vm.startPrank(bob);
        core.requestPayout(498_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory second = core.claimPayout("");
        vm.stopPrank();
        assertEq(first.usdcOutstanding, 0);
        assertEq(second.usdcOutstanding, 0, "S-10: Bob is paid in full too");
        assertApproxEqRel(second.usdcGross, first.usdcGross, 0.01e18, "S-10: for the same shares, the same USDC");
    }
}
