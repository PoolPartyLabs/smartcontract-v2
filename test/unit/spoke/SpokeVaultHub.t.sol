// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {ISpokeVaultIncome} from "../../../src/interfaces/ISpokeVaultIncome.sol";
import {ISpokeVaultUnwind} from "../../../src/interfaces/ISpokeVaultUnwind.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";

/// @notice Hub Chain role of the Spoke Vault (Arbitrum One in the MVP): Core Vault interplay and automatic unwind.
contract SpokeVaultHubTest is SpokeVaultTestBase {
    function setUp() public {
        _setUpMocks();
        _deployHub();
        usdc.mint(address(core), 10_000e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Construction and role (DEC-054, DEC-086, DEC-096)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC054_hubRoleConstruction() public view {
        assertTrue(vault.onHubChain());
        assertEq(vault.baseToken(), address(usdc));
        assertEq(vault.wormholeCore(), address(0));
        assertEq(vault.maxReportAge(), 0);
        address[] memory a = vault.adapters();
        assertEq(a.length, 2);
        assertEq(a[0], address(hubUni));
        assertEq(a[1], address(hubAave));
        assertEq(vault.bridgeAdapters().length, 0);
        address[] memory t = vault.ledgerTokens();
        assertEq(t.length, 2);
        assertEq(t[0], address(usdc));
        assertEq(t[1], address(weth));
        assertEq(vault.operatingCash(), 0);
        assertEq(vault.operatingCashFloor(), 0);
        assertEq(vault.operatingCashTopUp(), 0);
    }

    function test_DEC086_hubPublishesNoReportSoRejectsWormholeCore() public {
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.UnexpectedWormholeCore.selector, address(wormhole)));
        new SpokeVault(
            _mandate(),
            FUND_ID,
            HUB,
            address(core),
            address(usdc),
            makeAddr("hubAcrossSpokePool"),
            address(wormhole),
            address(escrowImplementation),
            excessRecipient
        );
    }

    function test_DEC096_hubHasNoOperatingCash() public {
        vm.prank(manager);
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.setOperatingCashParameters(1e6, 3e6);
        core.allocate(vault, 1000e6);
        vm.prank(manager);
        vault.openPosition(address(hubAave), AAVE_USDC, 100e6, 0, "");
        assertEq(vault.operatingCash(), 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 900e6);
    }

    function test_DEC054_spokeVerbsRevertOnHub() public {
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.report();
        _willArrive(1);
        vm.prank(manager);
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.sendToHub(1, TransferKind.Principal, 0);
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.recognizeRefund(bytes32(0));
        vm.prank(vault.acrossSpokePool());
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.handleV3AcrossMessage(
            address(usdc), 1, address(0), TransitMessage.encode(FUND_ID, HUB, bytes32(0), TransferKind.Principal)
        );
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Core Vault interplay (DEC-017, DEC-055, DEC-072, DEC-080, DEC-092)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC072_receiveFromCoreVaultOnlyCoreVault() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotCoreVault.selector, stranger));
        vault.receiveFromCoreVault(1);

        vm.expectEmit(address(vault));
        emit ISpokeVault.ReceivedFromCoreVault(1000e6);
        core.allocate(vault, 1000e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 1000e6);
    }

    function test_DEC080_creditWithoutTransferReverts() public {
        vm.expectPartialRevert(SpokeVaultTypes.LedgerExceedsBalance.selector);
        core.credit(vault, 1);
    }

    function test_DEC055_returnToCoreVaultTransfersThenCallsReturnToIdle() public {
        core.allocate(vault, 1000e6);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.returnToCoreVault(1);

        vm.expectEmit(address(vault));
        emit ISpokeVault.ReturnedToCoreVault(400e6);
        vm.prank(manager);
        vault.returnToCoreVault(400e6);
        assertEq(core.idleReturned(), 400e6);
        assertEq(usdc.balanceOf(address(core)), 9400e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 600e6);

        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdc), 600e6, 601e6)
        );
        vault.returnToCoreVault(601e6);
    }

    function test_DEC092_forwardIncomeToCoreVaultIsPermissionlessWithFixedDestination() public {
        core.allocate(vault, 1000e6);
        vm.prank(manager);
        (bytes32 key,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        _earnIncome(hubAave, key, 7e6, 0);
        vm.prank(manager);
        vault.collectIncome(address(hubAave), key);
        assertEq(vault.collectedIncome(address(usdc)), 7e6);

        vm.expectEmit(address(vault));
        emit ISpokeVaultIncome.IncomeForwardedToCoreVault(address(usdc), 7e6);
        vm.prank(stranger);
        assertEq(vault.forwardIncomeToCoreVault(address(usdc)), 7e6);
        assertEq(core.incomeReceived(address(usdc)), 7e6);
        assertEq(vault.collectedIncome(address(usdc)), 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 500e6);

        vm.expectRevert(ISpokeVault.ZeroAmount.selector);
        vault.forwardIncomeToCoreVault(address(usdc));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Automatic unwind (DEC-059, DEC-067, DEC-068, DEC-069, DEC-081, DEC-092, DEC-097)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC054_unwindOnlyCoreVault() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotCoreVault.selector, stranger));
        vault.unwindForPayout(1, "");
    }

    function test_DEC059_unallocatedUsdcPaysFirstWithoutUnwinding() public {
        (bytes32 uniKey, bytes32 aaveKey) = _twoPositions();
        vm.expectEmit(address(vault));
        emit ISpokeVaultUnwind.UnwoundForPayout(80e6, 80e6);
        assertEq(core.unwind(vault, 80e6, ""), 80e6);
        assertEq(core.idleReturned(), 80e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 20e6);
        assertEq(vault.positions().length, 2);
        (,,,,, bool uniOpen) = hubUni.position(uniKey);
        (,,,,, bool aaveOpen) = hubAave.position(aaveKey);
        assertTrue(uniOpen && aaveOpen);
    }

    /// @dev Final verification (DEC-069): the vault sizes the step from the shortfall, never from a hint. 100
    ///      Unallocated + 350 of the 400 in the Uniswap position (opened first) covers 450; the Aave position is not
    ///      visited. DEC-137 interim: the walk is the registry's order, the Mandate holds no unwind order.
    function test_DEC137_unwindFollowsRegistryOrderSizesTheStepAndStopsAtTarget() public {
        (bytes32 uniKey, bytes32 aaveKey) = _twoPositions();
        assertEq(core.unwind(vault, 450e6, ""), 450e6);
        assertEq(core.idleReturned(), 450e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        assertEq(vault.positions().length, 2, "no position closed: only the shortfall left");
        (,, uint256 uniUsdc,,, bool uniOpen) = hubUni.position(uniKey);
        assertTrue(uniOpen);
        assertEq(uniUsdc, 50e6);
        (, uint256 aavePrincipal,,,,) = hubAave.position(aaveKey);
        assertEq(aavePrincipal, 500e6);
    }

    /// @dev DEC-137, DEC-139 (Mandate v2): with no unwind order in the Mandate the unwind walks the open positions in
    ///      registry order until the proportional unwind (WP-09). Aave opened first is visited first: 100 Unallocated
    ///      plus 350 of its 500 cover 450, and the Uniswap position, opened second, is untouched.
    function test_DEC137_interimUnwindWalksTheRegistryInOpeningOrder() public {
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        (bytes32 aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        (bytes32 uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 400e6, "");
        vm.stopPrank();
        assertEq(vault.positions()[0].adapter, address(hubAave), "Aave first in the registry");

        assertEq(core.unwind(vault, 450e6, ""), 450e6);
        (, uint256 aavePrincipal,,, bool aaveOpen) = _aave(aaveKey);
        assertTrue(aaveOpen);
        assertEq(aavePrincipal, 150e6, "the first registry entry paid the shortfall");
        (,, uint256 uniUsdc,,, bool uniOpen) = hubUni.position(uniKey);
        assertTrue(uniOpen);
        assertEq(uniUsdc, 400e6, "the second one was never visited");
    }

    function test_DEC067_exactValuePositionReadNotExitedWhenCovered() public {
        (bytes32 uniKey, bytes32 aaveKey) = _twoPositions();
        core.unwind(vault, 500e6, "");
        (,,,,, bool uniOpen) = hubUni.position(uniKey);
        assertFalse(uniOpen, "the whole Uniswap value was needed, so it closed");
        (, uint256 principal0,,,, bool open) = hubAave.position(aaveKey);
        assertTrue(open);
        assertEq(principal0, 500e6, "the Exact-Value position was only read");
    }

    function test_DEC067_exactValuePositionExitedOnlyForTheShortfall() public {
        (, bytes32 aaveKey) = _twoPositions();
        assertEq(core.unwind(vault, 800e6, ""), 800e6);
        (, uint256 principal0,,, bool open) = _aave(aaveKey);
        assertTrue(open);
        assertEq(principal0, 200e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
    }

    /// @dev Final verification (DEC-069, DEC-081): the stop condition is re-evaluated after every step. The swap of
    ///      the Uniswap step loses 4% to price impact, so 2 USDC are still missing and the next position in Mandate
    ///      order is decreased by exactly that.
    function test_DEC069_stopConditionReevaluatedAfterEveryStep() public {
        (bytes32 uniKey, bytes32 aaveKey) = _mixedPositions();
        hubUni.setSwapHaircutBps(400);
        assertEq(core.unwind(vault, 200e6, ""), 200e6);
        (, uint256 weth0, uint256 usdc1,,, bool uniOpen) = hubUni.position(uniKey);
        assertTrue(uniOpen);
        assertEq(weth0, 0.075e18, "25% of the position covered the 100 USDC shortfall at spot");
        assertEq(usdc1, 150e6);
        (, uint256 aavePrincipal,,, bool aaveOpen) = _aave(aaveKey);
        assertTrue(aaveOpen);
        assertEq(aavePrincipal, 498e6, "then only the 2 USDC the swap fell short");
    }

    /// @dev Final verification (DEC-081, DEC-097, QA3 OPEN): the swap's minimum output is at least the spot quote less
    ///      MAX_UNWIND_SLIPPAGE_BPS; a claimant hint below the floor cannot widen it, a hint above it tightens it.
    function test_QA3_unwindSwapFloorFromSpotPriceAndHintsOnlyTighten() public {
        _wethPosition();
        assertEq(vault.MAX_UNWIND_SLIPPAGE_BPS(), 500);
        hubUni.setSwapHaircutBps(600); // 400 at spot, 376 after impact; the floor is 380
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientOutput.selector, 376e6, 380e6));
        core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(_wethHint(0)));

        hubUni.setSwapHaircutBps(400); // 384 after impact, above the floor
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientOutput.selector, 384e6, 390e6));
        core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(_wethHint(390e6)));

        assertEq(core.unwind(vault, 400e6, ""), 384e6, "no hint: the vault's own floor");
    }

    /// Independent review H-04 (S-11 residual): about 145 dust positions made every report undeliverable within
    /// Arbitrum's 32M gas per transaction and about 110 exhausted an unwind; the vault now holds at most
    /// MAX_OPEN_POSITIONS open at once, and a closed position frees its slot.
    function test_REVIEW_H04_openPositionsAreBounded() public {
        uint256 cap = SpokeVaultTypes.MAX_OPEN_POSITIONS;
        assertEq(cap, 16);
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        bytes32 first;
        for (uint256 i; i < cap; ++i) {
            (bytes32 key,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 1e6, "");
            if (i == 0) first = key;
        }
        assertEq(vault.positions().length, cap);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.OpenPositionLimit.selector, cap));
        vault.openPosition(address(hubUni), HUB_POOL, 0, 1e6, "");

        vault.closePosition(address(hubUni), first, "");
        vault.openPosition(address(hubUni), HUB_POOL, 0, 1e6, "");
        vm.stopPrank();
        assertEq(vault.positions().length, cap);
    }

    function test_DEC069_illiquidStepRevertsInsteadOfSkipping() public {
        _twoPositions();
        hubUni.setRevertOnExit(true);
        vm.expectRevert(MockPositionAdapter.ExitReverted.selector);
        core.unwind(vault, 800e6, "");
    }

    function test_DEC081_unwindSwapsNonUsdcPrincipalWithMinimumOutput() public {
        bytes32 key = _wethPosition();
        SpokeUnwindTypes.UnwindHint[] memory hints = _wethHint(390e6);
        vm.expectEmit(address(vault));
        // Checklist doc 15, gap 4: the pool's spot quote, the vault's 5% bound and the hint's higher minimum.
        emit ISpokeVault.Swapped(address(hubUni), address(weth), address(usdc), 0.2e18, 400e6, 400e6, 500, 390e6);
        assertEq(core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(hints)), 400e6);
        assertEq(vault.unallocatedBalance(address(weth)), 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        (,,,,, bool open) = hubUni.position(key);
        assertFalse(open);
    }

    function test_DEC081_unwindSwapBelowMinimumReverts() public {
        _wethPosition();
        SpokeUnwindTypes.UnwindHint[] memory hints = _wethHint(401e6);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientOutput.selector, 400e6, 401e6));
        core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(hints));
    }

    /// @dev Final verification: when the position's own pool pairs the token with USDC the vault swaps there; a hint
    ///      naming another route is refused rather than followed.
    function test_DEC069_unwindSwapHintCannotChooseAnotherRoute() public {
        _wethPosition();
        SpokeUnwindTypes.UnwindHint[] memory hints = _wethHint(0);
        hints[0].swaps[0].poolKey = AAVE_USDC;
        vm.expectRevert(
            abi.encodeWithSelector(
                SpokeUnwindTypes.InvalidUnwindSwap.selector, address(hubUni), AAVE_USDC, address(weth)
            )
        );
        core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(hints));

        hints = _wethHint(0);
        hints[0].swaps[0].adapter = address(hubAave);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpokeUnwindTypes.InvalidUnwindSwap.selector, address(hubAave), HUB_POOL, address(weth)
            )
        );
        core.unwind(vault, 400e6, SpokeUnwindTypes.encodeHints(hints));
    }

    function test_DEC081_unwindSwapHintWithNothingToSwapIsSkipped() public {
        _twoPositions();
        SpokeUnwindTypes.UnwindHint[] memory hints = _wethHint(0);
        // The USDC-only Uniswap position returns no WETH, so the WETH swap has nothing to take.
        assertEq(core.unwind(vault, 500e6, SpokeUnwindTypes.encodeHints(hints)), 500e6);
    }

    function test_DEC092_unwindIncomeGoesToCollectedBucketNotProceeds() public {
        (bytes32 uniKey,) = _twoPositions();
        _earnIncome(hubUni, uniKey, 0, 7e6);
        assertEq(core.unwind(vault, 500e6, ""), 500e6);
        assertEq(vault.collectedIncome(address(usdc)), 7e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(vault)), 7e6, "only the collected income stays in the vault");
    }

    function test_DEC068_unwindReturnsWhatItHasWhenPositionsAreExhausted() public {
        _twoPositions();
        assertEq(core.unwind(vault, 5000e6, ""), 1000e6);
        assertEq(vault.positions().length, 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report reader for the Core Vault (DEC-054, DEC-070)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC054_buildReportServesTheCoreVaultOnHub() public {
        (bytes32 uniKey,) = _twoPositions();
        _earnIncome(hubUni, uniKey, 0, 2e6);
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.sequence, 1);
        assertEq(r.spokeChainId, HUB);
        assertEq(r.unallocated[0].token, address(usdc));
        assertEq(r.unallocated[0].amount, 100e6);
        assertEq(r.positions.length, 2);
        assertEq(r.positions[0].principal1, 400e6);
        assertEq(r.positions[1].principal0, 500e6);
        assertEq(r.positions[1].token1, address(0));
        assertEq(r.cumulativeIncome[0].amount, 2e6);
        assertEq(r.arrivedTransits.length, 0);
        assertEq(r.inFlightToHub.length, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev 1000 USDC allocated; 400 USDC in the Uniswap WETH/USDC pool, 500 USDC supplied to Aave, 100 Unallocated.
    function _twoPositions() internal returns (bytes32 uniKey, bytes32 aaveKey) {
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        (uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 400e6, "");
        (aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        vm.stopPrank();
    }

    /// @dev 400 USDC allocated, swapped into 0.2 WETH through the swap adapter, all of it in a WETH-only Uniswap
    ///      position.
    function _wethPosition() internal returns (bytes32 key) {
        core.allocate(vault, 400e6);
        vm.startPrank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 400e6, 0, "");
        (key,,) = vault.openPosition(address(hubUni), HUB_POOL, 0.2e18, 0, "");
        vm.stopPrank();
        _poolSellsWethAt2000();
    }

    /// @dev The automatic unwind still sells in the position's pool until WP-09 (DEC-136 item 4): USDC liquidity for
    ///      its WETH sale at 2,000.
    function _poolSellsWethAt2000() internal {
        usdc.mint(address(hubUni), 10_000e6);
        hubUni.addLiquidity(address(usdc), 10_000e6);
        hubUni.setSwapRate(2000e6, 1e18);
    }

    /// @dev 1000 USDC allocated; 200 USDC swapped into 0.1 WETH at 2,000; a Uniswap position of 0.1 WETH + 200 USDC
    ///      (400 at spot), 500 USDC supplied to Aave, 100 Unallocated.
    function _mixedPositions() internal returns (bytes32 uniKey, bytes32 aaveKey) {
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 200e6, 0, "");
        (uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0.1e18, 200e6, "");
        (aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        vm.stopPrank();
        _poolSellsWethAt2000();
    }

    function _aave(bytes32 key)
        internal
        view
        returns (bytes32 poolKey, uint256 principal0, uint256 uncollected0, uint256 uncollected1, bool open)
    {
        (poolKey, principal0,, uncollected0, uncollected1, open) = hubAave.position(key);
    }

    function _wethHint(uint256 minUsdcOut) internal view returns (SpokeUnwindTypes.UnwindHint[] memory hints) {
        hints = new SpokeUnwindTypes.UnwindHint[](1);
        hints[0].swaps = new SpokeUnwindTypes.UnwindSwap[](1);
        hints[0].swaps[0] = SpokeUnwindTypes.UnwindSwap(address(hubUni), HUB_POOL, address(weth), minUsdcOut, "");
    }
}
