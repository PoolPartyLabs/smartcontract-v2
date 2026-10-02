// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreBridge} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {IAcrossSpokePool} from "../../../src/interfaces/external/IAcrossSpokePool.sol";
import {UniswapV4Adapter} from "../../../src/adapters/UniswapV4Adapter.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {XChainBase, LiveRelayData, BatchRelayer} from "./XChainBase.sol";

/// @notice Review port of integration-xchain `Fork_ReportBloat`: consolidated H-04 (report 05 H-01, register S-11 and
///         the `MAX_OPEN_POSITIONS` fix of H-04) on the factory-created fund. How big the manager (or a stranger) can
///         make a spoke report, and what its delivery costs on Arbitrum through the REAL Wormhole Core (13-of-19
///         guardian signatures verified by `parseAndVerifyVM`), for the three growth levers done for real on the
///         Robinhood fork:
///         - positions: dust positions of one USDG base unit through the real Uniswap V4 adapter and PositionManager;
///         - sends home: dust `sendToHub` through the real Across adapter into the live SpokePool (since DEC-162 the
///           smallest send the adapter's fee rule lets through: 0.030035 USDG, 10 base units to arrive);
///         - arrivals: a stranger's one-USDG deposits filled through the live SpokePool (the 256-id window).
///         Each measurement starts from the same stored report (one small report delivered in set-up) with the
///         receiver's and the Core Vault's storage cooled, like a keeper's new transaction. On `e5c778a`: about 145
///         positions, 391 sends home, or 225 sends once a stranger filled the window pushed delivery past Arbitrum's
///         32,000,000 gas per transaction (160 positions: 35.31M; 420 sends: 34.37M; 256 arrivals + 250 sends: 34.01M).
/// @dev Adaptation to the fix branch, interface only: the spoke's first report is delivered before the first send
///      (S-14). The gas counted is `deliver()` execution plus the transaction's intrinsic and calldata cost; Arbitrum's
///      L1 data component is not part of it.
contract Fork_ReportBloat is XChainBase {
    uint256 internal constant ARRIVES = BRIDGE_AMOUNT - BRIDGE_FEE;
    /// @dev DEC-162: a dust send home the Across adapter accepts: 0.08% (25 base units, rounded up) plus 0.03 leaves
    ///      10.
    uint256 internal constant DUST_HOME = 30_035;

    function _setUpFund() internal {
        _createForks();
        _phase1CreateFund();
        _phase2AnaDeposits();
        _report(); // S-14: the spoke's first report, before the first send
        (, LiveRelayData memory relay) = _sendToSpoke(BRIDGE_AMOUNT);
        _fillOnRobinhood(relay, relayer);
        uint256 g = _report(); // the stored report: a spoke holding 3,986.77 USDG, one arrival listed
        _log("baseline delivery gas (real Core)", g);
    }

    /// @dev Publishes now, then measures the delivery from the currently stored report, then restores the state.
    function _measure(string memory label, uint256 n) internal returns (uint256 total, bool fits) {
        (bytes memory payload, uint64 whSeq, uint256 reportGas) = _publishMeasured();
        _onArbitrum();
        _advance(FINALITY);
        uint256 snap = vm.snapshotState();
        uint256 intrinsic;
        (fits, intrinsic) = _deliverFitsOneTx(payload, whSeq);
        vm.revertToState(snap);
        snap = vm.snapshotState();
        uint256 parseGas = _parseGas(payload, whSeq);
        uint256 deliverGas = _deliver(payload, whSeq);
        uint256 depositGas = _depositGas();
        vm.revertToState(snap);
        total = deliverGas + intrinsic;
        console2.log("==", label, n);
        console2.log("   payload bytes                     ", payload.length);
        console2.log("   report() gas on Robinhood         ", reportGas);
        console2.log("   of which the Core's parseAndVerifyVM", parseGas);
        console2.log("   deliver() execution gas (real Core)", deliverGas);
        console2.log("   deliver() + intrinsic             ", total);
        console2.log("   fits in one 32M transaction       ", fits ? 1 : 0);
        console2.log("   next deposit gas (reads the report)", depositGas);
    }

    /// @dev The real Arbitrum Core alone: parse the VAA and verify its 13 guardian signatures (cold).
    function _parseGas(bytes memory payload, uint64 whSeq) internal returns (uint256 gasUsed) {
        bytes memory vaa = _vaa(payload, whSeq);
        _coolHub();
        uint256 g = gasleft();
        (, bool valid,) = ICoreBridge(ARB_WORMHOLE_CORE).parseAndVerifyVM(vaa);
        gasUsed = g - gasleft();
        assertTrue(valid, "the real Core parses and verifies the VAA");
    }

    function _depositGas() internal returns (uint256 gasUsed) {
        _refreshEthUsdFeed();
        address who = makeAddr("depositor");
        deal(ARB_USDC, who, 1000e6);
        vm.prank(who);
        IERC20(ARB_USDC).approve(address(core), 1000e6);
        vm.cool(address(receiver));
        vm.cool(address(core));
        vm.prank(who);
        uint256 g = gasleft();
        core.deposit(1000e6, 0);
        gasUsed = g - gasleft();
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Lever 1: dust positions through the real V4 adapter
    // -----------------------------------------------------------------------------------------------------------------

    function _dustParams() internal view returns (bytes memory) {
        int24 center = _center(RH_V4_STATE_VIEW, RH_WETH_USDG_POOL_ID);
        // A one-sided range just below the price holds token1 (USDG) only: one base unit gives liquidity > 0.
        return abi.encode(
            UniswapV4Adapter.OpenParams({
                tickLower: center - 3 * TICK_SPACING,
                tickUpper: center - 2 * TICK_SPACING,
                liquidity: 0,
                amount0Max: 0,
                amount1Max: 1,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );
    }

    function _dustPositions(uint256 n) internal {
        _onRobinhood();
        bytes memory params = _dustParams();
        vm.startPrank(manager);
        for (uint256 i; i < n; ++i) {
            spokeVault.openPosition(spokeUniswap, RH_WETH_USDG_POOL_ID, 0, 1, params);
        }
        vm.stopPrank();
    }

    /// @notice FIXED (MAX_OPEN_POSITIONS, 16): the position after the cap is refused, and the report at the cap delivers
    ///         in one transaction (on e5c778a 160 positions needed 35.31M).
    function test_REVIEW_H04_dustPositionsStopAtTheCapAndDeliver() public {
        _setUpFund();
        _dustPositions(SpokeVaultTypes.MAX_OPEN_POSITIONS);
        (uint256 total, bool fits) = _measure("positions", SpokeVaultTypes.MAX_OPEN_POSITIONS);
        assertTrue(fits, "positions at the cap deliver in one transaction");
        total;
        _onRobinhood();
        bytes memory params = _dustParams();
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(SpokeVaultTypes.OpenPositionLimit.selector, SpokeVaultTypes.MAX_OPEN_POSITIONS)
        );
        spokeVault.openPosition(spokeUniswap, RH_WETH_USDG_POOL_ID, 0, 1, params);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Lever 2: dust sends home through the real Across adapter and the live SpokePool
    // -----------------------------------------------------------------------------------------------------------------

    function _dustSendsHome(uint256 n, TransferKind kind) internal {
        _onRobinhood();
        uint32 before = IAcrossSpokePool(RH_ACROSS_SPOKE_POOL).numberOfDeposits();
        vm.startPrank(manager);
        for (uint256 i; i < n; ++i) {
            spokeVault.sendToHub(DUST_HOME, kind, 0);
        }
        vm.stopPrank();
        assertEq(IAcrossSpokePool(RH_ACROSS_SPOKE_POOL).numberOfDeposits() - before, n, "every deposit accepted");
    }

    /// @dev A stranger's real 2 USDC deposit on Arbitrum whose message says Income, filled on Robinhood: the spoke's
    ///      collected income bucket, which an Income send home debits (64 dust sends need 1.92).
    function _strangerIncomeArrival() internal {
        _onArbitrum();
        deal(ARB_USDC, stranger, 2e6);
        vm.startPrank(stranger);
        IERC20(ARB_USDC).approve(ARB_ACROSS_SPOKE_POOL, 2e6);
        vm.recordLogs();
        IAcrossSpokePool(ARB_ACROSS_SPOKE_POOL)
            .depositV3(
                stranger,
                address(spokeVault),
                ARB_USDC,
                RH_USDG,
                2e6,
                2e6,
                ROBINHOOD,
                address(0),
                uint32(block.timestamp),
                uint32(block.timestamp) + 21_600,
                0,
                TransitMessage.encode(fundId, ARBITRUM, _freshId(), TransferKind.Income)
            );
        vm.stopPrank();
        _fillOnRobinhood(_one(_relaysFrom(vm.getRecordedLogs(), ARB_ACROSS_SPOKE_POOL, ARBITRUM)), stranger);
        assertEq(spokeVault.collectedIncome(RH_USDG), 2e6);
    }

    /// @notice FIXED (S-11, MAX_HUB_BOUND_IN_FLIGHT = 64): the 65th listed send home is refused, and the report of 64
    ///         delivers in one transaction (on e5c778a 420 sends needed 34.37M).
    function test_REVIEW_H04_oneUnitSendsHomeStopAtTheCapAndDeliver() public {
        _setUpFund();
        _dustSendsHome(SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT, TransferKind.Principal);
        (, bool fits) = _measure("sends home", SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT);
        assertTrue(fits, "64 sends home deliver in one transaction");
        _onRobinhood();
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(
                SpokeVaultTypes.HubBoundInFlightLimit.selector, SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT
            )
        );
        spokeVault.sendToHub(DUST_HOME, TransferKind.Principal, 0);
    }

    // -----------------------------------------------------------------------------------------------------------------
    // Lever 3 and the worst case: a stranger's one-USDG arrivals (the 256-id window) plus both manager levers
    // -----------------------------------------------------------------------------------------------------------------

    function _strangerArrivals(uint256 n) internal {
        _onArbitrum();
        deal(ARB_USDC, stranger, n * 1e6);
        vm.startPrank(stranger);
        IERC20(ARB_USDC).approve(ARB_ACROSS_SPOKE_POOL, n * 1e6);
        vm.recordLogs();
        for (uint256 i; i < n; ++i) {
            IAcrossSpokePool(ARB_ACROSS_SPOKE_POOL)
                .depositV3(
                    stranger,
                    address(spokeVault),
                    ARB_USDC,
                    RH_USDG,
                    1e6,
                    1e6,
                    ROBINHOOD,
                    address(0),
                    uint32(block.timestamp),
                    uint32(block.timestamp) + 21_600,
                    0,
                    TransitMessage.encode(fundId, ARBITRUM, _freshId(), TransferKind.Principal)
                );
        }
        vm.stopPrank();
        LiveRelayData[] memory relays = _relaysFrom(vm.getRecordedLogs(), ARB_ACROSS_SPOKE_POOL, ARBITRUM);
        _onRobinhood();
        BatchRelayer batch = new BatchRelayer(stranger);
        deal(RH_USDG, address(batch), n * 1e6);
        vm.prank(stranger);
        batch.fillAll(RH_ACROSS_SPOKE_POOL, RH_USDG, relays, ARBITRUM);
    }

    /// @notice FIXED. The worst report the caps allow, built for real: a stranger fills the whole 256-id arrival window,
    ///         the manager adds 64 dust sends home and 32 dust positions. As reviewed the sends home were Income (the
    ///         hub's first listing of an Income id writes its kind to a fresh slot, about 20,000 gas more per entry);
    ///         since WP-10 the manager can send only Principal (income goes home through a collection order, DEC-122),
    ///         so the manager's worst case is Principal. Its first delivery over the small stored report goes through the
    ///         real Arbitrum Core within one 32M transaction.
    function test_REVIEW_H04_worstCaseReportDeliversThroughTheRealCores() public {
        _setUpFund();
        _strangerIncomeArrival();
        _strangerArrivals(256);
        (, bool fits) = _measure("stranger arrivals (window)", 256);
        assertTrue(fits);
        _dustSendsHome(SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT, TransferKind.Principal);
        (, fits) = _measure("256 arrivals + sends home", SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT);
        assertTrue(fits);
        _dustPositions(SpokeVaultTypes.MAX_OPEN_POSITIONS);
        uint256 total;
        (total, fits) = _measure("256 arrivals + 64 sends home + positions", SpokeVaultTypes.MAX_OPEN_POSITIONS);
        _log("worst-case delivery gas (execution + intrinsic)", total);
        assertTrue(fits, "the worst report delivers in one transaction");
        assertLt(total, MAX_TX_GAS);
    }

    /// @notice Re-attack of the caps: the same worst report, except that the 64 sends home (10 base units to arrive
    ///         each) are filled on Arbitrum before the report that first lists them. Its delivery then also credits 64
    ///         held-apart arrivals. As reviewed they were Income (each with a fee split and two USDC transfers); since
    ///         WP-10 the manager's sends home are Principal only (DEC-122).
    function test_REVIEW_H04_worstCaseWithHeldApartIncomeArrivals() public {
        _setUpFund();
        _strangerIncomeArrival();
        _strangerArrivals(256);
        _dustPositions(SpokeVaultTypes.MAX_OPEN_POSITIONS);
        _onRobinhood();
        vm.recordLogs();
        vm.startPrank(manager);
        for (uint256 i; i < SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT; ++i) {
            spokeVault.sendToHub(DUST_HOME, TransferKind.Principal, 0);
        }
        vm.stopPrank();
        LiveRelayData[] memory homes = _relaysFrom(vm.getRecordedLogs(), RH_ACROSS_SPOKE_POOL, ROBINHOOD);
        assertEq(homes.length, SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT);
        _onArbitrum();
        _advance(2 minutes);
        BatchRelayer mine = new BatchRelayer(manager);
        deal(ARB_USDC, address(mine), 10 * homes.length);
        vm.prank(manager);
        mine.fillAll(ARB_ACROSS_SPOKE_POOL, ARB_USDC, homes, ROBINHOOD);
        assertEq(core.unmatchedArrivals(), 10 * homes.length, "every send home held apart");

        (uint256 total, bool fits) =
            _measure("256 arrivals + 64 held-apart sends + positions", SpokeVaultTypes.MAX_OPEN_POSITIONS);
        _log("delivery gas with the held-apart arrivals credited (execution + intrinsic)", total);
        assertTrue(fits, "delivers in one transaction");
    }
}
