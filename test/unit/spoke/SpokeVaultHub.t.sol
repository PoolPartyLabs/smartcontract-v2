// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
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
        vm.prank(manager);
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.sendToHub(1, TransferKind.Principal, 0, _quote(1));
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
        emit ISpokeVault.IncomeForwardedToCoreVault(address(usdc), 7e6);
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
        emit ISpokeVault.UnwoundForPayout(80e6, 80e6);
        assertEq(core.unwind(vault, 80e6, ""), 80e6);
        assertEq(core.idleReturned(), 80e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 20e6);
        assertEq(vault.positions().length, 2);
        (,,,,, bool uniOpen) = hubUni.position(uniKey);
        (,,,,, bool aaveOpen) = hubAave.position(aaveKey);
        assertTrue(uniOpen && aaveOpen);
    }

    function test_DEC069_unwindFollowsMandateOrderAndStopsAtTarget() public {
        (, bytes32 aaveKey) = _twoPositions();
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](1);
        hints[0].close = true;
        // 100 Unallocated + 400 from the Uniswap position covers 450: the Aave position is not visited.
        assertEq(core.unwind(vault, 450e6, SpokeVaultTypes.encodeHints(hints)), 450e6);
        assertEq(core.idleReturned(), 450e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 50e6);
        ISpokeVault.PositionRef[] memory p = vault.positions();
        assertEq(p.length, 1);
        assertEq(p[0].positionKey, aaveKey);
    }

    function test_DEC067_exactValuePositionReadNotExitedWhenCovered() public {
        (, bytes32 aaveKey) = _twoPositions();
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0].close = true;
        hints[1].exitParams = abi.encode(uint256(10_000));
        core.unwind(vault, 500e6, SpokeVaultTypes.encodeHints(hints));
        (, uint256 principal0,,,, bool open) = hubAave.position(aaveKey);
        assertTrue(open);
        assertEq(principal0, 500e6, "the Exact-Value position was only read");
    }

    function test_DEC067_exactValuePositionExitedOnlyForTheShortfall() public {
        (, bytes32 aaveKey) = _twoPositions();
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0].close = true;
        hints[1].exitParams = abi.encode(uint256(6000));
        assertEq(core.unwind(vault, 800e6, SpokeVaultTypes.encodeHints(hints)), 800e6);
        (, uint256 principal0,,,,) = hubAave.position(aaveKey);
        assertEq(principal0, 200e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
    }

    function test_DEC069_missingHintRevertsInsteadOfSkipping() public {
        (, bytes32 aaveKey) = _twoPositions();
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](1);
        hints[0].close = true;
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.MissingUnwindHint.selector, address(hubAave), aaveKey));
        core.unwind(vault, 800e6, SpokeVaultTypes.encodeHints(hints));
    }

    function test_DEC069_illiquidStepRevertsInsteadOfSkipping() public {
        _twoPositions();
        hubUni.setRevertOnExit(true);
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0].close = true;
        hints[1].close = true;
        vm.expectRevert(MockPositionAdapter.ExitReverted.selector);
        core.unwind(vault, 800e6, SpokeVaultTypes.encodeHints(hints));
    }

    function test_DEC081_unwindSwapsNonUsdcPrincipalWithMinimumOutput() public {
        bytes32 key = _wethPosition();
        SpokeVaultTypes.UnwindHint[] memory hints = _wethHint(390e6);
        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(address(hubUni), HUB_POOL, address(weth), address(usdc), 0.2e18, 400e6);
        assertEq(core.unwind(vault, 400e6, SpokeVaultTypes.encodeHints(hints)), 400e6);
        assertEq(vault.unallocatedBalance(address(weth)), 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        (,,,,, bool open) = hubUni.position(key);
        assertFalse(open);
    }

    function test_DEC081_unwindSwapBelowMinimumReverts() public {
        _wethPosition();
        SpokeVaultTypes.UnwindHint[] memory hints = _wethHint(401e6);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.InsufficientOutput.selector, 400e6, 401e6));
        core.unwind(vault, 400e6, SpokeVaultTypes.encodeHints(hints));
    }

    function test_DEC069_unwindSwapMustTakeExitPrincipalIntoUsdc() public {
        _wethPosition();
        SpokeVaultTypes.UnwindHint[] memory hints = _wethHint(0);
        hints[0].swaps[0].tokenIn = address(usdc);
        vm.expectRevert(
            abi.encodeWithSelector(SpokeVaultTypes.InvalidUnwindSwap.selector, address(hubUni), HUB_POOL, address(usdc))
        );
        core.unwind(vault, 400e6, SpokeVaultTypes.encodeHints(hints));

        hints = _wethHint(0);
        hints[0].swaps[0].poolKey = AAVE_USDC;
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.PoolNotInMandate.selector, address(hubUni), AAVE_USDC));
        core.unwind(vault, 400e6, SpokeVaultTypes.encodeHints(hints));
    }

    function test_DEC081_unwindSwapHintWithNothingToSwapIsSkipped() public {
        _twoPositions();
        SpokeVaultTypes.UnwindHint[] memory hints = _wethHint(0);
        // The USDC-only Uniswap position returns no WETH, so the WETH swap has nothing to take.
        assertEq(core.unwind(vault, 500e6, SpokeVaultTypes.encodeHints(hints)), 500e6);
    }

    function test_DEC092_unwindIncomeGoesToCollectedBucketNotProceeds() public {
        (bytes32 uniKey,) = _twoPositions();
        _earnIncome(hubUni, uniKey, 0, 7e6);
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](1);
        hints[0].close = true;
        assertEq(core.unwind(vault, 500e6, SpokeVaultTypes.encodeHints(hints)), 500e6);
        assertEq(vault.collectedIncome(address(usdc)), 7e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(vault)), 7e6, "only the collected income stays in the vault");
    }

    function test_DEC068_unwindReturnsWhatItHasWhenPositionsAreExhausted() public {
        _twoPositions();
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0].close = true;
        hints[1].close = true;
        assertEq(core.unwind(vault, 5000e6, SpokeVaultTypes.encodeHints(hints)), 1000e6);
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

    /// @dev 400 USDC allocated, swapped into 0.2 WETH, all of it in a WETH-only Uniswap position.
    function _wethPosition() internal returns (bytes32 key) {
        core.allocate(vault, 400e6);
        weth.mint(address(hubUni), 1e18);
        hubUni.addLiquidity(address(weth), 1e18);
        hubUni.setSwapRate(1e18, 2000e6);
        vm.startPrank(manager);
        vault.swapExactInput(address(hubUni), HUB_POOL, address(usdc), 400e6, 0, "");
        (key,,) = vault.openPosition(address(hubUni), HUB_POOL, 0.2e18, 0, "");
        vm.stopPrank();
        hubUni.setSwapRate(2000e6, 1e18);
    }

    function _wethHint(uint256 minUsdcOut) internal view returns (SpokeVaultTypes.UnwindHint[] memory hints) {
        hints = new SpokeVaultTypes.UnwindHint[](1);
        hints[0].close = true;
        hints[0].swaps = new SpokeVaultTypes.UnwindSwap[](1);
        hints[0].swaps[0] = SpokeVaultTypes.UnwindSwap(address(hubUni), HUB_POOL, address(weth), minUsdcOut, "");
    }
}
