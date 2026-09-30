// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-10): deprecating the Uniswap V4 adapter no longer traps the fund's non-base
///        tokens or breaks the automatic unwind
/// @notice Was PoCs `test_POC_deprecationBreaksTheAutomaticUnwindOfAClaim` and
///         `test_POC_deprecationTrapsTheWethPrincipalForGood` (high, access lens): `swapExactInput` reverted when
///         deprecated and is the only way a Spoke Vault turns WETH into its base token, so one guardian call cut every
///         unwinding claim to Idle and left closed WETH unreachable while Share Assets kept counting it.
/// @notice FIX (S-10, `UniswapV4Adapter.swapExactInput`): a deprecated adapter still runs a swap INTO the vault's base
///         token (an exit, DEC-056, DEC-058); a swap out of it and every entry stay blocked. Both tests assert the
///         attack now FAILS.
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

    /// @dev With the flag the claim still unwinds the position and pays in full.
    function test_SEC_S10_deprecationNoLongerBreaksTheAutomaticUnwindOfAClaim() public {
        vm.prank(alice);
        core.requestPayout(400_000e6, ICoreVault.PayoutMode.Instant);

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
        vm.prank(guardian);
        UniswapV4Adapter(adapter).deprecate();

        vm.startPrank(manager);
        hub.closePosition(adapter, positionKey, abi.encode(UniswapV4Adapter.CloseParams(0, 0, block.timestamp)));
        uint256 wethHeld = hub.unallocatedBalance(address(weth));
        assertGt(wethHeld, 0);

        // Entries stay blocked; the exit swap into USDC runs.
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        hub.openPosition(adapter, poolId, wethHeld, wethHeld, _openParams(uint128(wethHeld), uint128(wethHeld)));
        hub.swapExactInput(adapter, poolId, address(weth), wethHeld, 0, "");
        assertEq(hub.unallocatedBalance(address(weth)), 0, "S-10: no WETH left behind");
        hub.returnToCoreVault(hub.unallocatedBalance(address(usdc)));
        vm.stopPrank();

        // Alice and Bob, with the same shares, are paid the same.
        vm.startPrank(alice);
        core.requestPayout(498_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory first = core.claimPayout("");
        vm.stopPrank();
        vm.startPrank(bob);
        core.requestPayout(498_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory second = core.claimPayout("");
        vm.stopPrank();
        assertEq(first.usdcOutstanding, 0);
        assertEq(second.usdcOutstanding, 0, "S-10: Bob is paid in full too");
        assertApproxEqRel(second.usdcGross, first.usdcGross, 0.01e18, "S-10: for the same shares, the same USDC");
    }
}
