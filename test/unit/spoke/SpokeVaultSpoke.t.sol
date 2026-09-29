// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {ITransitEscrow} from "../../../src/interfaces/ITransitEscrow.sol";
import {Transit, TransitState, TransferKind, ExpensePayer, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {MandateLib} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";

/// @notice Spoke Chain role of the Spoke Vault (Robinhood Chain in the MVP).
contract SpokeVaultSpokeTest is SpokeVaultTestBase {
    bytes32 internal constant ARRIVAL = keccak256("hub transit 1");

    function setUp() public {
        _setUpMocks();
        _deploySpoke();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Construction (DEC-053, DEC-058, DEC-087, DEC-088, DEC-096, Q17-4, OQ-12)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC053_constructorPinsChainLocalMandate() public view {
        assertFalse(vault.onHubChain());
        assertEq(vault.fundId(), FUND_ID);
        assertEq(vault.mandateHash(), MandateLib.hash(_mandate()));
        assertEq(vault.manager(), manager);
        assertEq(vault.hubChainId(), HUB);
        assertEq(vault.chainId(), SPOKE);
        assertEq(vault.coreVault(), address(core));
        assertEq(vault.baseToken(), address(usdg));
        assertEq(vault.hubChainUsdc(), address(usdc));
        assertEq(vault.acrossSpokePool(), address(spokePool));
        assertEq(vault.wormholeCore(), address(wormhole));
        assertEq(vault.excessRecipient(), excessRecipient);
        assertEq(vault.maxReportAge(), MAX_REPORT_AGE);
        assertEq(vault.maxBridgeFeeBps(), MAX_BRIDGE_FEE_BPS);

        address[] memory a = vault.adapters();
        assertEq(a.length, 1);
        assertEq(a[0], address(spokeUni));
        assertEq(vault.adapterCodehash(address(spokeUni)), address(spokeUni).codehash);
        assertEq(vault.adapterCodehash(address(spokeBridge)), address(spokeBridge).codehash);
        assertEq(vault.adapterCodehash(address(hubUni)), bytes32(0));

        address[] memory b = vault.bridgeAdapters();
        assertEq(b.length, 2);
        assertEq(b[0], address(spokeBridge));
        assertEq(b[1], address(spokeBridgeFallback));
        assertEq(vault.bridgeTarget(address(spokeBridge)), address(spokePool));

        address[] memory t = vault.ledgerTokens();
        assertEq(t.length, 2);
        assertEq(t[0], address(usdg));
        assertEq(t[1], address(weth));
        (address token0, address token1) = vault.poolTokens(address(spokeUni), SPOKE_POOL);
        assertEq(token0, address(weth));
        assertEq(token1, address(usdg));

        assertEq(vault.operatingCashFloor(), SPOKE_FLOOR);
        assertEq(vault.operatingCashTopUp(), SPOKE_TOP_UP);
        assertEq(vault.operatingCash(), 0);
        assertEq(vault.reportSequence(), 0);
    }

    function test_OQ12_hookedMandatePoolRejectedAtCreation() public {
        spokeUni.addHookedPool(SPOKE_POOL, address(weth), address(usdg));
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, SPOKE_POOL));
        _deploySpoke();
    }

    function test_DEC053_constructorRejectsWrongChainAndBaseToken() public {
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.WrongChain.selector, HUB, SPOKE));
        new SpokeVault(
            _mandate(),
            FUND_ID,
            HUB,
            address(core),
            address(usdc),
            address(spokePool),
            address(0),
            address(escrowImplementation),
            excessRecipient
        );

        vm.expectRevert(
            abi.encodeWithSelector(SpokeVaultTypes.BaseTokenMismatch.selector, address(usdc), address(usdg))
        );
        new SpokeVault(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdc),
            address(spokePool),
            address(wormhole),
            address(escrowImplementation),
            excessRecipient
        );
    }

    function test_DEC086_spokeRequiresWormholeCoreAndEscrow() public {
        vm.expectRevert(SpokeVaultTypes.ZeroAddress.selector);
        new SpokeVault(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(0),
            address(escrowImplementation),
            excessRecipient
        );
        vm.expectRevert(SpokeVaultTypes.ZeroAddress.selector);
        new SpokeVault(
            _mandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(wormhole),
            address(0),
            excessRecipient
        );
    }

    function test_Q17_4_positionAdapterCodehashChangeReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        bytes32 expected = address(spokeUni).codehash;
        vm.etch(address(spokeUni), address(spokeBridge).code);
        bytes32 actual = address(spokeUni).codehash;
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.AdapterCodehashMismatch.selector, address(spokeUni), expected, actual)
        );
        vm.prank(manager);
        vault.openPosition(address(spokeUni), SPOKE_POOL, 0, 10e6, "");

        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.AdapterCodehashMismatch.selector, address(spokeUni), expected, actual)
        );
        vault.cumulativeIncome(address(usdg));
    }

    function test_Q17_4_bridgeAdapterCodehashChangeReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        bytes32 expected = address(spokeBridge).codehash;
        vm.etch(address(spokeBridge), address(spokePool).code);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISpokeVault.AdapterCodehashMismatch.selector,
                address(spokeBridge),
                expected,
                address(spokeBridge).codehash
            )
        );
        vm.prank(manager);
        vault.sendToHub(10e6, TransferKind.Principal, 0, _quote(10e6));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Manager verbs (DEC-002, DEC-030, DEC-053, DEC-056, DEC-079, Q60)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC002_managerVerbsRejectStranger() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.openPosition(address(spokeUni), SPOKE_POOL, 1, 1, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.increasePosition(address(spokeUni), bytes32(0), 1, 1, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.decreasePosition(address(spokeUni), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.closePosition(address(spokeUni), bytes32(0), "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.collectIncome(address(spokeUni), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 1, 0, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.sendToHub(1, TransferKind.Principal, 0, _quote(1));
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.setOperatingCashParameters(0, 0);
        vm.stopPrank();
    }

    function test_DEC053_adapterOffChainOrOutsideMandateReverts() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.AdapterNotInMandate.selector, address(hubUni)));
        vault.openPosition(address(hubUni), HUB_POOL, 1, 1, "");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.AdapterNotInMandate.selector, address(spokeBridge)));
        vault.openPosition(address(spokeBridge), SPOKE_POOL, 1, 1, "");
        vm.stopPrank();
    }

    function test_DEC030_poolOutsideMandateReverts() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.PoolNotInMandate.selector, address(spokeUni), HUB_POOL));
        vault.openPosition(address(spokeUni), HUB_POOL, 1, 1, "");
    }

    function test_DEC079_openPositionMovesTokensAndCreditsUnused() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 8000);
        (uint256 used0, uint256 used1) = (0.16e18, 160e6);
        assertEq(vault.unallocatedBalance(address(weth)), 0.2e18 - used0);
        assertEq(vault.unallocatedBalance(address(usdg)), 600e6 - used1);
        assertEq(weth.balanceOf(address(vault)), 0.2e18 - used0);
        ISpokeVault.PositionRef[] memory p = vault.positions();
        assertEq(p.length, 1);
        assertEq(p[0].adapter, address(spokeUni));
        assertEq(p[0].positionKey, key);
        assertEq(p[0].poolKey, SPOKE_POOL);
    }

    function test_DEC080_unallocatedCheckedBeforeMovingTokens() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdg), 100e6, 101e6)
        );
        vault.openPosition(address(spokeUni), SPOKE_POOL, 0, 101e6, "");
    }

    function test_DEC079_increaseCreditsRealizedIncomeToCollectedBucket() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0, 200e6, 10_000);
        _earnIncome(spokeUni, key, 0.001e18, 3e6);
        vm.prank(manager);
        (uint256 used0, uint256 used1, uint256 income0, uint256 income1) =
            vault.increasePosition(address(spokeUni), key, 0, 100e6, "");
        assertEq(used0, 0);
        assertEq(used1, 100e6);
        assertEq(income0, 0.001e18);
        assertEq(income1, 3e6);
        assertEq(vault.collectedIncome(address(weth)), 0.001e18);
        assertEq(vault.collectedIncome(address(usdg)), 3e6);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6 - 400e6 - 200e6 - 100e6);
    }

    function test_DEC079_decreaseSplitsPrincipalAndIncome() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 10_000);
        _earnIncome(spokeUni, key, 0.002e18, 5e6);
        uint256 usdgBefore = vault.unallocatedBalance(address(usdg));
        vm.prank(manager);
        IAdapter.Amounts memory a = vault.decreasePosition(address(spokeUni), key, abi.encode(uint256(5000)));
        assertEq(a.principal0, 0.1e18);
        assertEq(a.principal1, 100e6);
        assertEq(a.income0, 0.002e18);
        assertEq(a.income1, 5e6);
        assertEq(vault.unallocatedBalance(address(weth)), 0.1e18);
        assertEq(vault.unallocatedBalance(address(usdg)), usdgBefore + 100e6);
        assertEq(vault.collectedIncome(address(weth)), 0.002e18);
        assertEq(vault.collectedIncome(address(usdg)), 5e6);
        assertEq(vault.positions().length, 1);
    }

    function test_DEC056_exitVerbsWorkWhilePausedOrDeprecated() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 10_000);
        vm.prank(guardian);
        spokeUni.setPaused(true);

        vm.startPrank(manager);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        vault.openPosition(address(spokeUni), SPOKE_POOL, 0, 1e6, "");
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        vault.increasePosition(address(spokeUni), key, 0, 1e6, "");
        vault.decreasePosition(address(spokeUni), key, abi.encode(uint256(1000)));
        vault.collectIncome(address(spokeUni), key);
        spokeUni.setSwapRate(2000e6, 1e18);
        // OQ-04: a swap serves the exit path, so pause does not block it.
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(weth), 0.01e18, 0, "");
        vm.stopPrank();

        vm.prank(guardian);
        spokeUni.deprecate();
        vm.startPrank(manager);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(weth), 0.01e18, 0, "");
        vault.closePosition(address(spokeUni), key, "");
        vm.stopPrank();
        assertEq(vault.positions().length, 0);
    }

    function test_Q60_cumulativeIncomeMonotonicAcrossCollectAndClose() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 10_000);
        _earnIncome(spokeUni, key, 0, 4e6);
        assertEq(vault.cumulativeIncome(address(usdg)), 4e6);
        vm.prank(manager);
        vault.collectIncome(address(spokeUni), key);
        assertEq(vault.cumulativeIncome(address(usdg)), 4e6);
        _earnIncome(spokeUni, key, 0, 1e6);
        assertEq(vault.cumulativeIncome(address(usdg)), 5e6);
        vm.prank(manager);
        vault.closePosition(address(spokeUni), key, "");
        assertEq(vault.cumulativeIncome(address(usdg)), 5e6);
        assertEq(vault.positions().length, 0);
        assertEq(vault.collectedIncome(address(usdg)), 5e6);
    }

    function test_DEC079_swapCreditsWhatTheAdapterReturns() public {
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        _fundSwap(address(weth), 1e18, 1e18, 2000e6);
        vm.expectEmit(address(vault));
        emit ISpokeVault.Swapped(address(spokeUni), SPOKE_POOL, address(usdg), address(weth), 400e6, 0.2e18);
        vm.prank(manager);
        uint256 out = vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 400e6, 0.2e18, "");
        assertEq(out, 0.2e18);
        assertEq(vault.unallocatedBalance(address(weth)), 0.2e18);
        assertEq(vault.unallocatedBalance(address(usdg)), 600e6);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnexpectedToken.selector, address(usdc)));
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdc), 1, 0, "");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ledger versus balance (DEC-080, DEC-096, DEC-101)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC080_overReportingAdapterReverts() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 10_000);
        spokeUni.setPrincipalOverReport(1);
        vm.prank(manager);
        vm.expectPartialRevert(SpokeVaultTypes.LedgerExceedsBalance.selector);
        vault.decreasePosition(address(spokeUni), key, abi.encode(uint256(5000)));
    }

    function test_DEC080_adapterKeepingUnusedAmountReverts() public {
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        spokeUni.setUseBps(5000);
        spokeUni.setUnusedShortfall(1);
        vm.prank(manager);
        vm.expectPartialRevert(SpokeVaultTypes.LedgerExceedsBalance.selector);
        vault.openPosition(address(spokeUni), SPOKE_POOL, 0, 100e6, "");
    }

    function test_DEC080_donationIsNeverCreditedAndIsSwept() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        usdg.mint(address(vault), 7e6);
        weth.mint(address(vault), 1e15);
        assertEq(vault.unallocatedBalance(address(usdg)), 100e6);
        assertEq(vault.buildReport().unallocated[0].amount, 100e6);

        vm.expectEmit(address(vault));
        emit ISpokeVault.ExcessSwept(address(usdg), excessRecipient, 7e6);
        assertEq(vault.sweepExcess(address(usdg)), 7e6);
        assertEq(vault.sweepExcess(address(weth)), 1e15);
        assertEq(usdg.balanceOf(excessRecipient), 7e6);
        assertEq(weth.balanceOf(excessRecipient), 1e15);
        assertEq(vault.unallocatedBalance(address(usdg)), 100e6);
        assertEq(vault.sweepExcess(address(usdg)), 0);
    }

    function test_DEC101_sweepKeepsIncomeDustAndOperatingCash() public {
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        _arrive(3, keccak256("income dust"), TransferKind.Income);
        _fundSwap(address(weth), 1e18, 1e18, 2000e6);
        vm.prank(manager);
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 10e6, 0, "");
        assertEq(vault.operatingCash(), SPOKE_TOP_UP);
        usdg.mint(address(vault), 1e6);
        assertEq(vault.sweepExcess(address(usdg)), 1e6);
        assertEq(vault.collectedIncome(address(usdg)), 3);
        assertEq(vault.operatingCash(), SPOKE_TOP_UP);
        assertEq(usdg.balanceOf(address(vault)), _ledgerTotal(address(usdg)));
        assertEq(vault.sweepExcess(address(usdg)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Operating Cash (DEC-041, DEC-096, DEC-100)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC096_arrivalIsAnOperationThatTopsUpFromUnallocated() public {
        // Spoke Vault verifier finding: an arrival moves value, so it tops up like every other operation.
        usdg.mint(address(spokePool), 100e6);
        vm.expectEmit(address(vault));
        emit ISpokeVault.OperatingCashToppedUp(SPOKE_TOP_UP, SPOKE_TOP_UP);
        vm.expectEmit(address(vault));
        emit ISpokeVault.OperatingExpensePaid(
            SPOKE, address(0), vault.OPERATING_CASH_TOP_UP(), SPOKE_TOP_UP, ExpensePayer.ShareAssets
        );
        spokePool.fill(
            address(vault), address(usdg), 100e6, TransitMessage.encode(FUND_ID, HUB, ARRIVAL, TransferKind.Principal)
        );
        assertEq(vault.operatingCash(), SPOKE_TOP_UP);

        // At the floor again: the next operation does not top up.
        _fundSwap(address(weth), 1e18, 1e18, 2000e6);
        vm.prank(manager);
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 20e6, 0, "");

        assertEq(vault.operatingCash(), SPOKE_TOP_UP);
        assertEq(vault.unallocatedBalance(address(usdg)), 100e6 - SPOKE_TOP_UP - 20e6);
        // DEC-042/DEC-104: Operating Cash is outside Share Assets, so the report's Unallocated Balance excludes it.
        assertEq(vault.buildReport().unallocated[0].amount, 70e6);
    }

    function test_DEC096_topUpLimitedToUnallocatedBalance() public {
        _arrive(4e6, ARRIVAL, TransferKind.Principal);
        _arrive(50e6, keccak256("income"), TransferKind.Income);
        vm.prank(manager);
        vault.sendToHub(50e6, TransferKind.Income, 0, _quote(50e6));
        assertEq(vault.operatingCash(), 4e6);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
    }

    function test_DEC096_noTopUpAtOrAboveFloor() public {
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        _fundSwap(address(weth), 1e18, 1e18, 2000e6);
        vm.startPrank(manager);
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 1e6, 0, "");
        assertEq(vault.operatingCash(), SPOKE_TOP_UP);
        vm.recordLogs();
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 1e6, 0, "");
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != ISpokeVault.OperatingCashToppedUp.selector);
        }
        assertEq(vault.operatingCash(), SPOKE_TOP_UP);
    }

    function test_DEC096_managerAdjustsFloorAndTopUp() public {
        vm.expectEmit(address(vault));
        emit ISpokeVault.OperatingCashParametersSet(20e6, 30e6);
        vm.prank(manager);
        vault.setOperatingCashParameters(20e6, 30e6);
        assertEq(vault.operatingCashFloor(), 20e6);
        assertEq(vault.operatingCashTopUp(), 30e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Across arrivals (DEC-080, DEC-090, DEC-092, OQ-01, OQ-09)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC080_arrivalOnlyFromAcrossSpokePool() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotAcrossSpokePool.selector, stranger));
        vault.handleV3AcrossMessage(
            address(usdg), 1, stranger, TransitMessage.encode(FUND_ID, HUB, ARRIVAL, TransferKind.Principal)
        );
    }

    function test_DEC080_arrivalOnlyInBaseToken() public {
        weth.mint(address(spokePool), 1e18);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnexpectedToken.selector, address(weth)));
        spokePool.fill(
            address(vault), address(weth), 1e18, TransitMessage.encode(FUND_ID, HUB, ARRIVAL, TransferKind.Principal)
        );
    }

    function test_DEC080_arrivalForAnotherFundReverts() public {
        usdg.mint(address(spokePool), 1e6);
        bytes32 other = keccak256("other fund");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.WrongFund.selector, other));
        spokePool.fill(
            address(vault), address(usdg), 1e6, TransitMessage.encode(other, HUB, ARRIVAL, TransferKind.Principal)
        );
    }

    function test_OQ01_arrivalFromAnotherOriginReverts() public {
        usdg.mint(address(spokePool), 1e6);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.UnexpectedOriginChain.selector, uint256(1)));
        spokePool.fill(
            address(vault), address(usdg), 1e6, TransitMessage.encode(FUND_ID, 1, ARRIVAL, TransferKind.Principal)
        );
    }

    function test_DEC090_principalArrivalCreditsUnallocatedAndRecordsId() public {
        _disableOperatingCash();
        assertFalse(vault.hasArrived(ARRIVAL));
        usdg.mint(address(spokePool), 250e6);
        vm.expectEmit(address(vault));
        emit ISpokeVault.TransitArrived(ARRIVAL, HUB, address(usdg), 250e6, TransferKind.Principal);
        spokePool.fill(
            address(vault), address(usdg), 250e6, TransitMessage.encode(FUND_ID, HUB, ARRIVAL, TransferKind.Principal)
        );
        assertEq(vault.unallocatedBalance(address(usdg)), 250e6);
        assertEq(vault.cumulativeReceived(), 250e6);
        assertEq(vault.arrivals(ARRIVAL), 250e6);
        assertTrue(vault.hasArrived(ARRIVAL));
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, 1);
        assertEq(r.arrivedTransits[0].transitId, ARRIVAL);
        assertEq(r.arrivedTransits[0].amount, 250e6);
        assertEq(r.cumulativeReceived, 250e6);
    }

    function test_DEC092_incomeArrivalCreditsCollectedBucket() public {
        _arrive(9e6, ARRIVAL, TransferKind.Income);
        assertEq(vault.collectedIncome(address(usdg)), 9e6);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
        assertEq(vault.cumulativeReceived(), 0);
        assertTrue(vault.hasArrived(ARRIVAL));
    }

    function test_OQ09_repeatedArrivalIdAddsAndIsListedOnce() public {
        _arrive(1e6, ARRIVAL, TransferKind.Principal);
        _arrive(2e6, ARRIVAL, TransferKind.Principal);
        assertEq(vault.arrivals(ARRIVAL), 3e6);
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, 1);
        assertEq(r.arrivedTransits[0].amount, 3e6);
    }

    function test_OQ09_reportCarriesLast256ArrivalsAndCumulativeReceived() public {
        for (uint256 i; i < 262; ++i) {
            _arrive(1e6, bytes32(i + 1), TransferKind.Principal);
        }
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, 256);
        assertEq(r.arrivedTransits[0].transitId, bytes32(uint256(7)));
        assertEq(r.arrivedTransits[255].transitId, bytes32(uint256(262)));
        assertEq(r.cumulativeReceived, 262e6);
        assertTrue(vault.hasArrived(bytes32(uint256(1))));
    }

    function test_OQ09_spokeWindowEqualsTheWindowTheHubReads() public pure {
        assertEq(SpokeVaultTypes.ARRIVAL_WINDOW, ReportCodec.ARRIVAL_WINDOW);
    }

    function test_OQ09_idIsListedOnceItsCreditedTotalReachesTheMinimum() public {
        _disableOperatingCash();
        _arrive(0.4e6, ARRIVAL, TransferKind.Principal);
        assertEq(vault.buildReport().arrivedTransits.length, 0, "below 1 USDG: credited, not listed");
        assertEq(vault.unallocatedBalance(address(usdg)), 0.4e6);
        _arrive(0.6e6, ARRIVAL, TransferKind.Principal);
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, 1, "listed when the total reaches 1 USDG");
        assertEq(r.arrivedTransits[0].amount, 1e6);
        _arrive(5e6, ARRIVAL, TransferKind.Principal);
        assertEq(vault.buildReport().arrivedTransits.length, 1, "and only once");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Send home (DEC-056, DEC-066, DEC-085, DEC-087, DEC-088, DEC-092, QA19)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC087_sendHomeFixesRecipientTokenPairMessageAndEscrow() public {
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.recordLogs();
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0, _quote(499e6));

        MockAcrossSpokePool.Deposit memory d = spokePool.deposit(0);
        Transit memory t = vault.hubBoundTransit(id);
        assertEq(spokePool.caller(0), address(vault), "the vault is the payer");
        assertEq(d.depositor, t.escrow, "the per-send escrow is the depositor");
        assertEq(d.recipient, address(core));
        assertEq(d.inputToken, address(usdg));
        assertEq(d.outputToken, address(usdc));
        assertEq(d.inputAmount, 500e6);
        assertEq(d.outputAmount, 499e6);
        assertEq(d.destinationChainId, HUB);
        (bytes32 fund, uint256 origin, bytes32 transitId, TransferKind kind) = TransitMessage.decode(d.message);
        assertEq(fund, FUND_ID);
        assertEq(origin, SPOKE);
        assertEq(transitId, id);
        assertEq(uint8(kind), uint8(TransferKind.Principal));

        assertEq(usdg.allowance(address(vault), address(spokePool)), 0, "approval reset");
        assertTrue(_sawSentToHub(id), "SentToHub emitted by the vault");
        assertEq(usdg.balanceOf(address(spokePool)), 500e6);
        assertEq(vault.unallocatedBalance(address(usdg)), 500e6);
        assertEq(vault.cumulativeSentHome(), 500e6);

        assertEq(uint8(t.state), uint8(TransitState.Sent));
        assertEq(t.destinationChainId, HUB);
        assertEq(t.bridgeAdapter, address(spokeBridge));
        assertEq(t.inputToken, address(usdg));
        assertEq(t.outputToken, address(usdc));
        assertEq(t.amountSent, 500e6);
        assertEq(t.amountToArrive, 499e6);
        assertEq(t.bridgeRef, bytes32(0));
        assertEq(t.fillDeadline, uint32(block.timestamp) + 21_600);
        assertEq(ITransitEscrow(t.escrow).vault(), address(vault));
        assertEq(ITransitEscrow(t.escrow).token(), address(usdg));

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.inFlightToHub.length, 1);
        assertEq(r.inFlightToHub[0].transitId, id);
        assertEq(r.inFlightToHub[0].amount, 499e6);
        assertEq(uint8(r.inFlightToHub[0].kind), uint8(TransferKind.Principal), "CV-OQ-1: the kind is reported");
        assertEq(r.cumulativeSentHome, 500e6);
    }

    function test_QA19_feeAboveMaxBridgeFeeReverts() public {
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.BridgeFeeAboveMax.selector, 5.1e6, 5e6));
        vault.sendToHub(1000e6, TransferKind.Principal, 0, _quote(994.9e6));
        vault.sendToHub(1000e6, TransferKind.Principal, 0, _quote(995e6));
        vm.stopPrank();
    }

    function test_DEC085_quoteOutputZeroOrAboveInputReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.InvalidQuoteAmount.selector, 10e6, 0));
        vault.sendToHub(10e6, TransferKind.Principal, 0, _quote(0));
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.InvalidQuoteAmount.selector, 10e6, 11e6));
        vault.sendToHub(10e6, TransferKind.Principal, 0, _quote(11e6));
        vm.expectRevert(ISpokeVault.ZeroAmount.selector);
        vault.sendToHub(0, TransferKind.Principal, 0, _quote(0));
        vm.stopPrank();
    }

    function test_DEC056_sendHomeIgnoresBridgePauseAndDeprecation() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        vm.startPrank(guardian);
        spokeBridge.setPaused(true);
        spokeBridge.deprecate();
        vm.stopPrank();
        vm.prank(manager);
        bytes32 id = vault.sendToHub(100e6, TransferKind.Principal, 0, _quote(100e6));
        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.Sent));
    }

    function test_DEC088_bridgeRankSelectsFallbackAndUnknownRankReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        vm.startPrank(manager);
        bytes32 id = vault.sendToHub(10e6, TransferKind.Principal, 1, _quote(10e6));
        assertEq(vault.hubBoundTransit(id).bridgeAdapter, address(spokeBridgeFallback));
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.UnknownBridgeRank.selector, 2));
        vault.sendToHub(10e6, TransferKind.Principal, 2, _quote(10e6));
        vm.stopPrank();
    }

    function test_DEC087_builtCallToAnotherTargetReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        spokeBridge.setBuiltTargetOverride(stranger);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpokeVaultTypes.BridgeTargetMismatch.selector, address(spokeBridge), address(spokePool), stranger
            )
        );
        vault.sendToHub(10e6, TransferKind.Principal, 0, _quote(10e6));
    }

    function test_DEC085_builtAmountToArriveMismatchReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        spokeBridge.setAmountToArriveDelta(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.BridgeAmountMismatch.selector, 9.99e6, 9.99e6 + 1));
        vault.sendToHub(10e6, TransferKind.Principal, 0, _quote(9.99e6));
    }

    function test_DEC087_inexactDebitReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        spokePool.setPullShortfall(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.BridgeDebitMismatch.selector, 10e6, 10e6 - 1));
        vault.sendToHub(10e6, TransferKind.Principal, 0, _quote(10e6));
    }

    function test_DEC092_incomeSendDebitsCollectedBucket() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        _arrive(50e6, keccak256("income"), TransferKind.Income);
        vm.startPrank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientCollectedIncome.selector, address(usdg), 50e6, 60e6)
        );
        vault.sendToHub(60e6, TransferKind.Income, 0, _quote(60e6));
        bytes32 id = vault.sendToHub(50e6, TransferKind.Income, 0, _quote(50e6));
        vm.stopPrank();
        assertEq(vault.collectedIncome(address(usdg)), 0);
        assertEq(vault.unallocatedBalance(address(usdg)), 100e6);
        (,,, TransferKind kind) = TransitMessage.decode(spokePool.deposit(0).message);
        assertEq(uint8(kind), uint8(TransferKind.Income));
        assertEq(uint8(vault.hubBoundTransit(id).kind), uint8(TransferKind.Income));
        // CV-OQ-1: the report tells the hub it is income, so the hub keeps it out of Share Assets (DEC-092).
        assertEq(uint8(vault.buildReport().inFlightToHub[0].kind), uint8(TransferKind.Income));
    }

    function test_DEC098_reportCarriesCollectedIncomeAndOperatingCash() public {
        _arrive(100e6, ARRIVAL, TransferKind.Principal); // tops Operating Cash up by 10 (DEC-096)
        _arrive(7e6, keccak256("income"), TransferKind.Income);
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.operatingCash, SPOKE_TOP_UP);
        assertEq(r.collectedIncome[0].token, address(usdg));
        assertEq(r.collectedIncome[0].amount, 7e6);
        assertEq(r.unallocated[0].amount, 90e6, "neither is in Unallocated Balance");
    }

    function test_CVOQ2_wethIncomeSwappedIntoBaseTokenThenSentHomeAsIncome() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 10_000);
        _earnIncome(spokeUni, key, 0.01e18, 0);
        vm.prank(manager);
        vault.collectIncome(address(spokeUni), key);
        assertEq(vault.collectedIncome(address(weth)), 0.01e18);
        uint256 unallocatedUsdg = vault.unallocatedBalance(address(usdg));
        uint256 unallocatedWeth = vault.unallocatedBalance(address(weth));

        _fundSwap(address(usdg), 100e6, 2000e6, 1e18); // 2,000 USDG per WETH
        vm.expectEmit(address(vault));
        emit ISpokeVault.IncomeSwapped(address(spokeUni), SPOKE_POOL, address(weth), address(usdg), 0.01e18, 20e6);
        vm.prank(manager);
        uint256 out = vault.swapCollectedIncome(address(spokeUni), SPOKE_POOL, address(weth), 0.01e18, 20e6, "");
        assertEq(out, 20e6);
        // DEC-092: the swap stays inside the collected income bucket.
        assertEq(vault.collectedIncome(address(weth)), 0);
        assertEq(vault.collectedIncome(address(usdg)), 20e6);
        assertEq(vault.unallocatedBalance(address(usdg)), unallocatedUsdg);
        assertEq(vault.unallocatedBalance(address(weth)), unallocatedWeth);

        vm.prank(manager);
        bytes32 id = vault.sendToHub(20e6, TransferKind.Income, 0, _quote(20e6));
        assertEq(uint8(vault.hubBoundTransit(id).kind), uint8(TransferKind.Income));
        assertEq(vault.hubBoundTransit(id).outputToken, address(usdc), "lands on the hub as USDC");
        assertEq(vault.collectedIncome(address(usdg)), 0);
    }

    function test_CVOQ2_swapCollectedIncomeOnlyFromIncomeIntoTheBaseToken() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        _arrive(50e6, keccak256("income"), TransferKind.Income);
        _fundSwap(address(weth), 1e18, 1e18, 2000e6);
        vm.startPrank(manager);
        // The output must be the base token: USDG income cannot be swapped into WETH.
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnexpectedToken.selector, address(usdg)));
        vault.swapCollectedIncome(address(spokeUni), SPOKE_POOL, address(usdg), 10e6, 0, "");
        // Only the collected income bucket is spent, never Unallocated Balance.
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.InsufficientCollectedIncome.selector, address(weth), 0, 1));
        vault.swapCollectedIncome(address(spokeUni), SPOKE_POOL, address(weth), 1, 0, "");
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.swapCollectedIncome(address(spokeUni), SPOKE_POOL, address(weth), 1, 0, "");
        _deployHub();
        vm.prank(manager);
        vm.expectRevert(ISpokeVault.NotOnSpokeChain.selector);
        vault.swapCollectedIncome(address(hubUni), HUB_POOL, address(weth), 1, 0, "");
    }

    function test_DEC080_sendAboveUnallocatedReverts() public {
        _disableOperatingCash();
        _arrive(100e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdg), 100e6, 101e6)
        );
        vault.sendToHub(101e6, TransferKind.Principal, 0, _quote(101e6));
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Refunds and the in-flight list (DEC-066, QA6, OQ-09)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC066_recognizeRefundAfterDeadlineCreditsTheDebitedBucket() public {
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0, _quote(499e6));
        Transit memory t = vault.hubBoundTransit(id);

        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.FillDeadlineNotReached.selector, id, t.fillDeadline));
        vault.recognizeRefund(id);

        vm.warp(uint256(t.fillDeadline) + 1);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, id));
        vault.recognizeRefund(id);

        spokePool.refund(t.escrow, address(usdg), 500e6);
        usdg.mint(t.escrow, 3e6); // a donation to the escrow is not a refund
        vm.expectEmit(address(vault));
        emit ISpokeVault.TransitRefundRecognized(id, 500e6);
        vm.prank(stranger);
        assertEq(vault.recognizeRefund(id), 500e6);

        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.RefundRecognized));
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6);
        assertEq(vault.inFlightTransitIds().length, 0);
        assertEq(vault.buildReport().inFlightToHub.length, 0);
        assertEq(vault.sweepExcess(address(usdg)), 3e6);

        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnknownTransit.selector, id));
        vault.recognizeRefund(id);
    }

    function test_DEC066_unknownTransitRefundReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.UnknownTransit.selector, bytes32(uint256(9))));
        vault.recognizeRefund(bytes32(uint256(9)));
    }

    function test_OQ09_hubBoundTransitDroppedAfterDeadlinePlusMaxReportAge() public {
        _disableOperatingCash();
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        vm.prank(manager);
        bytes32 id = vault.sendToHub(500e6, TransferKind.Principal, 0, _quote(499e6));
        uint32 deadline = vault.hubBoundTransit(id).fillDeadline;

        vm.warp(uint256(deadline) + MAX_REPORT_AGE);
        assertEq(vault.buildReport().inFlightToHub.length, 1);

        vm.warp(uint256(deadline) + MAX_REPORT_AGE + 1);
        assertEq(vault.buildReport().inFlightToHub.length, 0);
        assertEq(vault.inFlightTransitIds().length, 1, "pruned lazily");
        vault.report();
        assertEq(vault.inFlightTransitIds().length, 0);
        assertEq(uint8(vault.hubBoundTransit(id).state), uint8(TransitState.Sent));

        // A refund that shows up later is still recognized.
        spokePool.refund(vault.hubBoundTransit(id).escrow, address(usdg), 500e6);
        assertEq(vault.recognizeRefund(id), 500e6);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Report (DEC-070, DEC-079, DEC-093)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC093_reportPublishesFinalizedWithStrictlyIncreasingSequence() public {
        vm.expectEmit(address(vault));
        emit ISpokeVault.ReportPublished(1, 0, uint64(block.number));
        (uint64 seq1, uint64 wh1) = vault.report();
        vm.prank(stranger);
        (uint64 seq2, uint64 wh2) = vault.report();
        assertEq(seq1, 1);
        assertEq(seq2, 2);
        assertEq(wh1, 0);
        assertEq(wh2, 1);
        assertEq(vault.reportSequence(), 2);

        assertEq(wormhole.publishedCount(), 2);
        MockWormholeCore.Published memory p = wormhole.published(1);
        assertEq(p.emitter, address(vault));
        assertEq(p.consistencyLevel, 1, "finalized");
        ReportCodec.Report memory r = ReportCodec.decode(p.payload);
        assertEq(r.sequence, 2);
        assertEq(r.fundId, FUND_ID);
        assertEq(r.spokeChainId, SPOKE);
    }

    function test_DEC093_reportForwardsWormholeMessageFee() public {
        wormhole.setMessageFee(1);
        vm.deal(stranger, 1);
        vm.prank(stranger);
        vault.report{value: 1}();
        assertEq(wormhole.published(0).value, 1);
        vm.expectRevert(abi.encodeWithSelector(MockWormholeCore.WrongFee.selector, 0, 1));
        vault.report();
    }

    function test_DEC070_reportBuiltFromLedgerAndAdapters() public {
        _disableOperatingCash();
        bytes32 key = _openSpokePosition(0.2e18, 200e6, 10_000);
        _earnIncome(spokeUni, key, 0.001e18, 2e6);
        usdg.mint(address(vault), 123e6); // donation: never reported (DEC-080)
        vm.roll(777);
        vm.warp(1_800_000_000);

        ReportCodec.Report memory built = vault.buildReport();
        assertEq(built.fundId, FUND_ID);
        assertEq(built.sequence, 1);
        assertEq(built.spokeChainId, SPOKE);
        assertEq(built.blockNumber, 777);
        assertEq(built.timestamp, 1_800_000_000);
        assertEq(built.unallocated.length, 2);
        assertEq(built.unallocated[0].token, address(usdg));
        assertEq(built.unallocated[0].amount, 400e6);
        assertEq(built.unallocated[1].token, address(weth));
        assertEq(built.unallocated[1].amount, 0);
        assertEq(built.positions.length, 1);
        ReportCodec.PositionReport memory pr = built.positions[0];
        assertEq(pr.adapter, address(spokeUni));
        assertEq(pr.poolKey, SPOKE_POOL);
        assertEq(pr.poolId, keccak256(abi.encode(SPOKE_POOL)));
        assertEq(pr.tickLower, -600);
        assertEq(pr.tickUpper, 600);
        assertEq(pr.token0, address(weth));
        assertEq(pr.token1, address(usdg));
        assertEq(pr.principal0, 0.2e18);
        assertEq(pr.principal1, 200e6);
        assertEq(pr.income0, 0.001e18);
        assertEq(pr.income1, 2e6);
        assertEq(built.cumulativeIncome[0].amount, 2e6);
        assertEq(built.cumulativeIncome[1].amount, 0.001e18);
        assertEq(built.cumulativeReceived, 1000e6);
        assertEq(built.cumulativeSentHome, 0);

        vault.report();
        ReportCodec.Report memory published = ReportCodec.decode(wormhole.published(0).payload);
        assertEq(keccak256(abi.encode(published)), keccak256(abi.encode(built)), "buildReport equals the payload");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Role (DEC-054)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC054_hubVerbsRevertOnSpoke() public {
        vm.expectRevert(ISpokeVault.NotOnHubChain.selector);
        vault.receiveFromCoreVault(1);
        vm.expectRevert(ISpokeVault.NotOnHubChain.selector);
        vault.returnToCoreVault(1);
        vm.expectRevert(ISpokeVault.NotOnHubChain.selector);
        vault.forwardIncomeToCoreVault(address(usdg));
        vm.expectRevert(ISpokeVault.NotOnHubChain.selector);
        vault.unwindForPayout(1, "");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Arrival of 1000 USDG, a swap of 400 USDG into 0.2 WETH, then a position with `amount0` WETH and
    ///      `amount1` USDG of which the adapter uses `useBps`.
    function _openSpokePosition(uint256 amount0, uint256 amount1, uint256 useBps) internal returns (bytes32 key) {
        _arrive(1000e6, ARRIVAL, TransferKind.Principal);
        _fundSwap(address(weth), 1e18, 1e18, 2000e6);
        vm.prank(manager);
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 400e6, 0, "");
        spokeUni.setUseBps(useBps);
        vm.prank(manager);
        (key,,) = vault.openPosition(address(spokeUni), SPOKE_POOL, amount0, amount1, "");
        spokeUni.setUseBps(10_000);
    }

    function _sawSentToHub(bytes32 id) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(vault) && logs[i].topics[0] == ISpokeVault.SentToHub.selector
                    && logs[i].topics[1] == id
            ) {
                (Transit memory t, uint256 hubChainId, uint256 originChainId) =
                    abi.decode(logs[i].data, (Transit, uint256, uint256));
                return t.amountSent == 500e6 && hubChainId == HUB && originChainId == SPOKE;
            }
        }
        return false;
    }

    /// @dev Gives the spoke adapter `liquidity` of `tokenOut` and sets the swap rate to `numerator / denominator`.
    function _fundSwap(address tokenOut, uint256 liquidity, uint256 numerator, uint256 denominator) internal {
        if (tokenOut == address(weth)) weth.mint(address(spokeUni), liquidity);
        else usdg.mint(address(spokeUni), liquidity);
        spokeUni.addLiquidity(tokenOut, liquidity);
        spokeUni.setSwapRate(numerator, denominator);
    }
}
