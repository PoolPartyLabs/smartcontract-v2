// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    Mandate,
    AdapterConfig,
    PoolConfig,
    UnwindStep,
    SpokeConfig,
    BridgeAdapterConfig
} from "../../../src/mandate/Mandate.sol";
import {SpokeVaultTestBase} from "./SpokeVaultTestBase.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ReentrantSpokeToken} from "../../mocks/spoke/ReentrantSpokeToken.sol";
import {ReentrantPositionAdapter} from "../../mocks/spoke/ReentrantPositionAdapter.sol";

/// @notice Adversarial suite (verification round 1): re-entrancy through a hooked pool token and through a Mandate
///         adapter, the bridge fee bound at its exact boundary, and the ordering attacks the OQ-09 arrival window and
///         the unwind hint list are exposed to.
contract SpokeVaultAdversarialSpokeTest is SpokeVaultTestBase {
    bytes32 internal constant GENUINE = keccak256("hub transit genuine");

    ReentrantSpokeToken internal rtk;

    function setUp() public {
        _setUpMocks();
        // The reentrant token replaces WETH as token0 of the spoke Mandate pool, so the vault lists it in its ledger.
        rtk = new ReentrantSpokeToken();
        spokeUni.addPool(SPOKE_POOL, address(rtk), address(usdg));
        _deploySpoke();
        _disableOperatingCash();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Re-entrancy (ISpokeVault: every value-moving entry point is nonReentrant)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev A hooked Mandate pool token tries to re-enter `sweepExcess` while the vault moves it: on the swap output
    ///      the adapter pays and on the position input the vault sends. Both re-entries fail and the ledger is exact.
    function test_DEC080_hookedPoolTokenCannotReenterSweepWhileTheVaultMovesIt() public {
        _arrive(1000e6, GENUINE, TransferKind.Principal);
        rtk.mint(address(spokeUni), 500e6);
        spokeUni.addLiquidity(address(rtk), 500e6);
        spokeUni.setSwapRate(1, 1);
        rtk.setHook(address(vault), abi.encodeCall(ISpokeVault.sweepExcess, (address(rtk))));

        vm.prank(manager);
        vault.swapExactInput(address(spokeUni), SPOKE_POOL, address(usdg), 300e6, 0, "");
        assertEq(rtk.hookCalls(), 1, "hook ran on the adapter's payment to the vault");
        assertEq(rtk.reentrySucceeded(), 0, "re-entry blocked");
        assertEq(vault.unallocatedBalance(address(rtk)), 300e6);
        assertEq(rtk.balanceOf(address(vault)), 300e6, "nothing swept out from under the ledger");

        vm.prank(manager);
        vault.openPosition(address(spokeUni), SPOKE_POOL, 300e6, 0, "");
        assertEq(rtk.hookCalls(), 2, "hook ran on the vault's transfer to the adapter");
        assertEq(rtk.reentrySucceeded(), 0, "re-entry blocked");
        assertEq(vault.unallocatedBalance(address(rtk)), 0);
        assertEq(rtk.balanceOf(address(vault)), 0);
        assertEq(rtk.balanceOf(address(spokeUni)), 500e6, "the adapter holds what the ledger says it used");
    }

    /// @dev `sweepExcess` is permissionless and takes any token: a stranger's hooked token cannot use its own sweep
    ///      to re-enter the vault; the sweep still completes.
    function test_DEC101_strangerHookedTokenCannotReenterThroughItsOwnSweep() public {
        ReentrantSpokeToken junk = new ReentrantSpokeToken();
        junk.mint(address(vault), 77e6);
        junk.setHook(address(vault), abi.encodeCall(ISpokeVault.sweepExcess, (address(junk))));

        vm.prank(stranger);
        assertEq(vault.sweepExcess(address(junk)), 77e6);
        assertEq(junk.hookCalls(), 1);
        assertEq(junk.reentrySucceeded(), 0);
        assertEq(junk.balanceOf(excessRecipient), 77e6);
        assertEq(junk.balanceOf(address(vault)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Bridge fee bound (QA19), fuzzed to the exact boundary
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzz_QA19_bridgeFeeBoundIsExactAtTheBoundary(uint256 amount, uint256 fee) public {
        amount = bound(amount, 1, 1e30);
        fee = bound(fee, 0, amount - 1);
        _arrive(amount, GENUINE, TransferKind.Principal);
        uint256 maxFee = amount * MAX_BRIDGE_FEE_BPS / 10_000;

        vm.prank(manager);
        if (fee > maxFee) {
            vm.expectRevert(abi.encodeWithSelector(ISpokeVault.BridgeFeeAboveMax.selector, fee, maxFee));
            vault.sendToHub(amount, TransferKind.Principal, 0, _quote(amount - fee));
            assertEq(vault.unallocatedBalance(address(usdg)), amount, "nothing left the ledger");
            assertEq(vault.cumulativeSentHome(), 0);
        } else {
            bytes32 id = vault.sendToHub(amount, TransferKind.Principal, 0, _quote(amount - fee));
            assertEq(vault.hubBoundTransit(id).amountSent, amount);
            assertEq(vault.hubBoundTransit(id).amountToArrive, amount - fee);
            assertEq(vault.unallocatedBalance(address(usdg)), 0);
            assertEq(vault.cumulativeSentHome(), amount);
            assertEq(usdg.balanceOf(address(vault)), 0, "exact debit");
        }
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ordering attacks on the OQ-09 arrival window (Across passes no depositor: any deposit reaches the callback)
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Sixty-four dust deposits from a stranger, each with a fresh id, push a genuine arrival out of the window
    ///      the report carries before any report was published. The hub can no longer confirm that id from a report,
    ///      while the spoke keeps counting the money. Documents the griefing vector of the 64-id window.
    function test_OQ09_dustSpamEvictsAGenuineArrivalFromTheReportWindow() public {
        _arrive(1000e6, GENUINE, TransferKind.Principal);
        for (uint256 i; i < SpokeVaultTypes.ARRIVAL_WINDOW; ++i) {
            _arrive(1, keccak256(abi.encode("dust", i)), TransferKind.Principal);
        }

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, SpokeVaultTypes.ARRIVAL_WINDOW);
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            assertTrue(r.arrivedTransits[i].transitId != GENUINE, "the genuine id was evicted");
        }
        assertTrue(vault.hasArrived(GENUINE), "still credited locally");
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6 + SpokeVaultTypes.ARRIVAL_WINDOW);
        assertEq(r.cumulativeReceived, 1000e6 + SpokeVaultTypes.ARRIVAL_WINDOW);
    }

    /// @dev A stranger front-runs the real fill with one unit under the same transit id: the report then lists the id
    ///      with more than the hub sent. The hub must tolerate `amount >= amountToArrive` when it confirms.
    function test_OQ01_strangerDepositWithTheGenuineIdInflatesTheReportedArrival() public {
        _arrive(1, GENUINE, TransferKind.Principal);
        _arrive(1000e6, GENUINE, TransferKind.Principal);

        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.arrivedTransits.length, 1);
        assertEq(r.arrivedTransits[0].transitId, GENUINE);
        assertEq(r.arrivedTransits[0].amount, 1000e6 + 1);
        assertEq(vault.unallocatedBalance(address(usdg)), 1000e6 + 1);
    }
}

/// @notice A Mandate position adapter that re-enters the vault from inside an exit verb, after it has transferred the
///         principal back and before the ledger is credited: the window a malicious or buggy adapter would use to
///         sweep or publish a report over an unbacked ledger.
contract SpokeVaultAdversarialAdapterTest is SpokeVaultTestBase {
    bytes32 internal constant GENUINE = keccak256("hub transit genuine");

    ReentrantPositionAdapter internal evil;

    function setUp() public {
        _setUpMocks();
        evil = new ReentrantPositionAdapter(guardian, address(usdg));
        vm.chainId(SPOKE);
        vault = new SpokeVault(
            _evilMandate(),
            FUND_ID,
            SPOKE,
            address(core),
            address(usdg),
            address(spokePool),
            address(wormhole),
            address(escrowImplementation),
            excessRecipient
        );
        evil.setVault(address(vault));
        spokeBridge.setVault(address(vault));
    }

    function test_DEC079_mandateAdapterCannotReenterSweepOrReportFromAnExitVerb() public {
        _arrive(100e6, GENUINE, TransferKind.Principal);
        bytes32 pool = evil.POOL();
        vm.prank(manager);
        (bytes32 key,,) = vault.openPosition(address(evil), pool, 100e6, 0, "");
        assertEq(vault.unallocatedBalance(address(usdg)), 0);

        evil.queueReentry(abi.encodeCall(ISpokeVault.sweepExcess, (address(usdg))));
        evil.queueReentry(abi.encodeCall(ISpokeVault.report, ()));
        evil.queueReentry(abi.encodeCall(ISpokeVault.recognizeRefund, (bytes32(0))));

        vm.prank(manager);
        vault.closePosition(address(evil), key, "");

        assertEq(evil.reentriesAttempted(), 3);
        assertEq(evil.reentriesSucceeded(), 0, "every re-entry blocked");
        assertEq(vault.unallocatedBalance(address(usdg)), 100e6, "principal credited");
        assertEq(usdg.balanceOf(address(vault)), 100e6, "nothing swept out from under the ledger");
        assertEq(vault.positions().length, 0);
        assertEq(vault.reportSequence(), 0, "no report published from inside the exit");
        assertEq(wormhole.publishedCount(), 0);
    }

    function _evilMandate() internal view returns (Mandate memory m) {
        m.manager = manager;
        m.hubChainId = HUB;
        m.usdc = address(usdc);
        m.adapters = new AdapterConfig[](1);
        m.adapters[0] = AdapterConfig(SPOKE, address(evil));
        m.pools = new PoolConfig[](1);
        m.pools[0] = PoolConfig(SPOKE, address(evil), evil.POOL());
        m.unwindOrder = new UnwindStep[](1);
        m.unwindOrder[0] = UnwindStep(SPOKE, address(evil), evil.POOL());
        m.spokes = new SpokeConfig[](1);
        m.spokes[0] = SpokeConfig(
            SPOKE, WH_SPOKE, bytes32(uint256(uint160(spokeVaultInMandate))), address(usdg), 1_000_000e6, MAX_REPORT_AGE
        );
        m.bridgeAdapters = new BridgeAdapterConfig[](2);
        m.bridgeAdapters[0] = BridgeAdapterConfig(SPOKE, HUB, hubBridge);
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridge));
        m.payoutFeeBps = 200;
        m.standardPayoutTerm = 72 hours;
        m.minFirstDeposit = 100e6;
        m.maxBridgeFeeBps = MAX_BRIDGE_FEE_BPS;
    }
}

/// @notice Hub role: the unwind hint list is consumed in registry order, and the registry is swap-and-pop, so a manual
///         close reorders later positions. The caller must read `positions()` in the same block it builds hints.
contract SpokeVaultAdversarialHubTest is SpokeVaultTestBase {
    function setUp() public {
        _setUpMocks();
        _deployHub();
        usdc.mint(address(core), 10_000e6);
    }

    function test_DEC069_unwindHintsFollowTheRegistryOrderAfterASwapAndPopClose() public {
        core.allocate(vault, 900e6);
        vm.startPrank(manager);
        (bytes32 a,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 300e6, "");
        (bytes32 b,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 300e6, "");
        (bytes32 c,,) = vault.openPosition(address(hubUni), HUB_POOL, 0, 300e6, "");
        vault.closePosition(address(hubUni), b, "");
        vm.stopPrank();

        ISpokeVault.PositionRef[] memory p = vault.positions();
        assertEq(p.length, 2);
        assertEq(p[0].positionKey, a);
        assertEq(p[1].positionKey, c, "c moved into b's slot");

        // Unallocated 300 (from b) + a closed (300) = 600 < 650: the second hint is applied to c, a 50% decrease.
        SpokeVaultTypes.UnwindHint[] memory hints = new SpokeVaultTypes.UnwindHint[](2);
        hints[0].close = true;
        hints[1].exitParams = abi.encode(uint256(5000));
        assertEq(core.unwind(vault, 650e6, SpokeVaultTypes.encodeHints(hints)), 650e6);

        (,, uint256 principalA,,, bool openA) = hubUni.position(a);
        (,, uint256 principalC,,, bool openC) = hubUni.position(c);
        assertFalse(openA);
        assertEq(principalA, 0);
        assertTrue(openC);
        assertEq(principalC, 150e6, "the decrease hint landed on c, not on the closed b");
        assertEq(vault.unallocatedBalance(address(usdc)), 100e6);
        assertEq(core.idleReturned(), 650e6);
    }
}
