// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {ISwapAdapter} from "../../../src/interfaces/ISwapAdapter.sol";
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

    /// @dev DEC-172: the hub collection collects every position's income and hands the USDC to the Core Vault; only the
    ///      Core Vault runs it (it recognizes the income first, DEC-138), and the destination is fixed.
    function test_DEC172_hubCollectionIsCoreVaultOnlyWithAFixedDestination() public {
        core.allocate(vault, 1000e6);
        vm.prank(manager);
        (bytes32 key,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        _earnIncome(hubAave, key, 7e6, 0);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotCoreVault.selector, stranger));
        vault.collectIncomeAll(0);

        (address[] memory tokens, uint256[] memory sold, uint256[] memory obtained) = core.collectIncome(vault, 0);
        assertEq(tokens[0], address(usdc), "USDC first");
        assertEq(sold[0], 7e6);
        assertEq(obtained[0], 7e6);
        assertEq(core.incomeReceived(address(usdc)), 7e6);
        assertEq(vault.collectedIncome(address(usdc)), 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 500e6, "principal untouched (DEC-092)");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Automatic unwind (DEC-137, DEC-140, DEC-141, DEC-148, DEC-151, DEC-118, DEC-092, DEC-136 item 4)
    // ---------------------------------------------------------------------------------------------------------------

    bytes32 internal constant REQUEST = keccak256("ana's request");

    function test_DEC054_unwindOnlyCoreVault() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotCoreVault.selector, stranger));
        vault.unwindForPayout(_unwindRequest(REQUEST, 1, 2, 0, true));
    }

    /// @dev DEC-148: the step is the vault calling itself, so that a revert undoes the step alone; nobody else may.
    function test_DEC148_unwindStepOnlyByTheVaultItself() public {
        bytes memory step = abi.encode(SpokeUnwindTypes.Step(address(hubAave), bytes32(0), 1, 1, 0, true));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SpokeUnwindTypes.UnwindStepNotSelf.selector, stranger));
        vault.unwindStep(step);
        vm.prank(address(core));
        vm.expectRevert(abi.encodeWithSelector(SpokeUnwindTypes.UnwindStepNotSelf.selector, address(core)));
        vault.unwindStep(step);
    }

    /// @dev D-11: with a zero fraction only the base token's Unallocated Balance is paid into Idle (DEC-067: Idle and
    ///      that balance cover the request, no position is touched).
    function test_D11_zeroFractionPaysOnlyTheUnallocatedUsdc() public {
        (bytes32 uniKey, bytes32 aaveKey) = _twoPositions();
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 0, 0, 0, true));
        assertEq(r.proceeds, 100e6);
        assertEq(core.idleReturned(), 100e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        assertEq(r.delivered + r.excluded, 0);
        assertEq(vault.positions().length, 2);
        (,, uint256 uniUsdc,,,) = hubUni.position(uniKey);
        (, uint256 aavePrincipal,,,) = _aave(aaveKey);
        assertEq(uniUsdc, 400e6);
        assertEq(aavePrincipal, 500e6);
    }

    /// @dev DEC-137: the same fraction of every position, sized by the vault from the fraction (never from a value or
    ///      a hint), plus the whole Unallocated USDC (D-11): 100 + 25% of 400 + 25% of 500.
    function test_DEC137_theSameFractionOfEveryPosition() public {
        (bytes32 uniKey, bytes32 aaveKey) = _twoPositions();
        vm.expectEmit(address(vault));
        emit ISpokeVaultUnwind.UnwoundForPayout(REQUEST, 1, 4, ISpokeVaultUnwind.UnwindResult(325e6, 0, 0, 0, 2, 0));
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 4, 0, true));
        assertEq(r.proceeds, 325e6);
        assertEq(core.idleReturned(), 325e6);
        (,, uint256 uniUsdc,,, bool uniOpen) = hubUni.position(uniKey);
        (, uint256 aavePrincipal,,, bool aaveOpen) = _aave(aaveKey);
        assertTrue(uniOpen && aaveOpen);
        assertEq(uniUsdc, 300e6);
        assertEq(aavePrincipal, 375e6);
        assertTrue(vault.unwindDelivered(REQUEST, address(hubUni), uniKey));
        assertTrue(vault.unwindDelivered(REQUEST, address(hubAave), aaveKey));
    }

    function test_DEC137_aWholeFractionClosesEveryPosition() public {
        _twoPositions();
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 1, 0, true));
        assertEq(r.proceeds, 1000e6);
        assertEq(vault.positions().length, 0);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
    }

    /// @dev DEC-136 item 4: the WETH an exit returns is sold through the Mandate swap adapter, never in the position's
    ///      pool, in the tier `bestDirectFee` chose (D-21); doc 15 gap 4: the sale event carries the requester's maximum
    ///      and the minimum applied. Half of 0.1 WETH + 200 USDC, half of 500 and the 100 Unallocated: 550.
    function test_DEC136_nonBasePrincipalIsSoldThroughTheSwapAdapter() public {
        (bytes32 uniKey,) = _mixedPositions();
        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(address(hubSwap), address(weth), address(usdc), 0.05e18, 100e6, 100e6, 150, 98.5e6);
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 150, true));
        assertEq(r.proceeds, 550e6);
        assertEq(r.spotOut, 100e6);
        assertEq(r.marketCost, 0);
        assertEq(hubSwap.lastFee(), hubSwap.directFee(), "the tier bestDirectFee chose");
        assertEq(vault.unallocatedBalance(address(weth)), 0, "every WETH the exit returned was sold");
        (, uint256 weth0, uint256 usdc1,,,) = hubUni.position(uniKey);
        assertEq(weth0, 0.05e18);
        assertEq(usdc1, 100e6);
    }

    /// @dev DEC-118: in an Instant Payout the requester bears the sale's whole loss against its mid value. The register's
    ///      0.3%: 100 of WETH sold for 99.70.
    function test_DEC118_instantRequesterBearsTheWholeSaleLoss() public {
        _mixedPositions();
        hubSwap.setHaircutBps(30);
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, true));
        assertEq(r.spotOut, 100e6);
        assertEq(r.marketCost, 0.3e6);
        assertEq(r.leaverCost, 0.3e6);
        assertEq(r.proceeds, 549.7e6);
    }

    /// @dev DEC-141: in a Standard Payout the fund absorbs each sale's loss up to 1% of its value; the requester bears
    ///      the rest. 4% on 100: the fund 1, the requester 3; 0.35%: all the fund's; exactly 1%: all the fund's.
    function test_DEC141_standardFundAbsorbsUpToOnePercentPerSale() public {
        _mixedPositions();
        uint256 snap = vm.snapshotState();
        hubSwap.setHaircutBps(400);
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, false));
        assertEq(r.marketCost, 4e6);
        assertEq(r.leaverCost, 3e6, "the excess over 1% of the value sold");
        assertEq(vault.STANDARD_SALE_LOSS_ABSORB_BPS(), 100);

        vm.revertToState(snap);
        hubSwap.setHaircutBps(35);
        r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, false));
        assertEq(r.marketCost, 0.35e6);
        assertEq(r.leaverCost, 0, "a normal sale is absorbed whole");

        vm.revertToState(snap);
        hubSwap.setHaircutBps(100);
        r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, false));
        assertEq(r.marketCost, 1e6);
        assertEq(r.leaverCost, 0, "exactly 1% is still the fund's");
    }

    /// @dev DEC-148: a sale above the requester's maximum leaves only that position out, with the swap adapter's
    ///      error as the reason (doc 15); the Aave position, which returns only USDC, delivers (D-24).
    function test_DEC148_aSaleAboveTheMaximumLeavesOnlyThatPositionOut() public {
        (bytes32 uniKey, bytes32 aaveKey) = _mixedPositions();
        hubSwap.setHaircutBps(600);
        vm.expectEmit(address(vault));
        emit ISpokeVaultUnwind.UnwindStepExcluded(
            REQUEST,
            address(hubUni),
            uniKey,
            abi.encodeWithSelector(ISwapAdapter.InsufficientOutput.selector, 94e6, 99e6)
        );
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 100, true));
        assertEq(r.excluded, 1);
        assertEq(r.delivered, 1);
        assertEq(r.proceeds, 350e6, "the 100 Unallocated and half of Aave");
        (, uint256 weth0, uint256 usdc1,,, bool uniOpen) = hubUni.position(uniKey);
        assertTrue(uniOpen);
        assertEq(weth0, 0.1e18, "the step was undone whole");
        assertEq(usdc1, 200e6);
        assertFalse(vault.unwindDelivered(REQUEST, address(hubUni), uniKey));
        assertTrue(vault.unwindDelivered(REQUEST, address(hubAave), aaveKey));
    }

    /// @dev DEC-151: the next attempt of the same request unwinds only what has not delivered, at the same fraction;
    ///      Aave, which delivered, is not touched again.
    function test_DEC151_theNextAttemptUnwindsOnlyWhatHasNotDelivered() public {
        (bytes32 uniKey, bytes32 aaveKey) = _mixedPositions();
        hubSwap.setHaircutBps(600);
        core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 100, true));
        (, uint256 aaveAfterFirst,,,) = _aave(aaveKey);
        assertEq(aaveAfterFirst, 250e6);

        // A higher maximum at the retry: the Uniswap position now delivers its half.
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 700, true));
        assertEq(r.delivered, 1);
        assertEq(r.excluded, 0);
        assertEq(r.proceeds, 100e6 + 94e6, "half the USDC leg and half the WETH sold at 6% below its mid");
        (, uint256 aaveAfterRetry,,,) = _aave(aaveKey);
        assertEq(aaveAfterRetry, 250e6, "Aave delivered at the first attempt");
        (, uint256 weth0,,,,) = hubUni.position(uniKey);
        assertEq(weth0, 0.05e18);
        // A third attempt finds nothing left to deliver.
        r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, true));
        assertEq(r.delivered + r.excluded, 0);
        assertEq(r.proceeds, 0);
    }

    /// @dev D-21: the tier is chosen once per token per unwind and reused for the next sale of the same token.
    function test_D21_theTierIsChosenOncePerTokenPerUnwind() public {
        _mixedPositions();
        // A second WETH/USDC position, WETH only.
        core.allocate(vault, 200e6);
        vm.startPrank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 200e6, 0, "");
        vault.openPosition(address(hubUni), HUB_POOL, 0.1e18, 0, "");
        vm.stopPrank();
        uint256 choicesBefore = hubSwap.tierChoices();
        core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, true));
        assertEq(hubSwap.tierChoices() - choicesBefore, 1, "one bestDirectFee for two WETH sales");
        // A later unwind chooses again (the choice lives in transient storage, cleared at the end).
        core.unwind(vault, _unwindRequest(keccak256("another request"), 1, 2, 0, true));
        assertEq(hubSwap.tierChoices() - choicesBefore, 2);
    }

    function test_DEC178_retryFractionUsesTheUndeliveredPositionsCurrentSize() public {
        (bytes32 uniKey, bytes32 aaveKey) = _mixedPositions();
        hubSwap.setHaircutBps(600);
        core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 100, true));
        vm.prank(manager);
        vault.decreasePosition(address(hubUni), uniKey, abi.encode(uint256(5000)));
        (, uint256 principalBefore,,,,) = hubUni.position(uniKey);
        ISpokeVaultUnwind.UnwindResult memory retry = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 700, true));
        assertEq(retry.delivered, 2, "the resized position and newly Unallocated WETH deliver");
        (, uint256 principalAfter,,,,) = hubUni.position(uniKey);
        assertEq(principalAfter, principalBefore / 2);
        (, uint256 aavePrincipal,,,) = _aave(aaveKey);
        assertEq(aavePrincipal, 250e6, "already-delivered Aave is unchanged");
    }

    /// @dev DEC-137 (D-11): a non-base Unallocated Balance is sold at the same fraction, like a position.
    function test_DEC137_nonBaseUnallocatedIsSoldAtTheFraction() public {
        core.allocate(vault, 400e6);
        vm.prank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 400e6, 0, "");
        assertEq(vault.unallocatedBalance(address(weth)), 0.2e18);
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 2, 0, true));
        assertEq(r.proceeds, 200e6);
        assertEq(vault.unallocatedBalance(address(weth)), 0.1e18);
        assertTrue(vault.unwindDelivered(REQUEST, address(0), bytes32(uint256(uint160(address(weth))))));
    }

    /// @dev DEC-148, DEC-068: an exit that reverts (a reserve without liquidity) leaves that position out; the others
    ///      deliver.
    function test_DEC148_aFailingExitLeavesThePositionOut() public {
        (bytes32 uniKey,) = _twoPositions();
        hubUni.setRevertOnExit(true);
        vm.expectEmit(address(vault));
        emit ISpokeVaultUnwind.UnwindStepExcluded(
            REQUEST, address(hubUni), uniKey, abi.encodeWithSelector(MockPositionAdapter.ExitReverted.selector)
        );
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 1, 0, true));
        assertEq(r.excluded, 1);
        assertEq(r.proceeds, 600e6);
        assertEq(vault.positions().length, 1);
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

    function test_DEC092_unwindIncomeGoesToCollectedBucketNotProceeds() public {
        (bytes32 uniKey,) = _twoPositions();
        _earnIncome(hubUni, uniKey, 0, 7e6);
        ISpokeVaultUnwind.UnwindResult memory r = core.unwind(vault, _unwindRequest(REQUEST, 1, 1, 0, true));
        assertEq(r.proceeds, 1000e6);
        assertEq(vault.collectedIncome(address(usdc)), 7e6);
        assertEq(vault.unallocatedBalance(address(usdc)), 0);
        assertEq(usdc.balanceOf(address(vault)), 7e6, "only the collected income stays in the vault");
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

    /// @dev 1000 USDC allocated; 200 USDC swapped into 0.1 WETH at 2,000; a Uniswap position of 0.1 WETH + 200 USDC
    ///      (400 at spot), 500 USDC supplied to Aave, 100 Unallocated.
    function _mixedPositions() internal returns (bytes32 uniKey, bytes32 aaveKey) {
        core.allocate(vault, 1000e6);
        vm.startPrank(manager);
        vault.swap(address(hubSwap), address(usdc), address(weth), 200e6, 0, "");
        (uniKey,,) = vault.openPosition(address(hubUni), HUB_POOL, 0.1e18, 200e6, "");
        (aaveKey,,) = vault.openPosition(address(hubAave), AAVE_USDC, 500e6, 0, "");
        vm.stopPrank();
    }

    function _aave(bytes32 key)
        internal
        view
        returns (bytes32 poolKey, uint256 principal0, uint256 uncollected0, uint256 uncollected1, bool open)
    {
        (poolKey, principal0,, uncollected0, uncollected1, open) = hubAave.position(key);
    }
}
