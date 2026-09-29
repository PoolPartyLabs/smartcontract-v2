// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Adversarial verification of the consolidation stage (fees at collection, ReportCodec v2 kinds, payout
///         fallback, arrival window). The OQ-09 and DEC-021 fallback tests were written failing against the stage and
///         are kept as the regressions of the fixes.
contract CoreVaultConsolidateVerifyTest is CoreVaultFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6); // Idle 9,975 after the 25 bps flow fee
    }

    function _homeMessage(bytes32 id, TransferKind kind) internal pure returns (bytes memory) {
        return TransitMessage.encode(FUND_ID, SPOKE, id, kind);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-09 / DEC-080 / DEC-104: a hub-to-spoke transit the hub never confirms (its id evicted by 256 listed arrivals
    // before a report carrying it was accepted, or a send below the 1e6 listing minimum) stays in `inFlightToArrive`
    // for good while the spoke deducts it as value of unknown origin. Regression of the verifier finding: the deduction
    // was clamped per spoke, so once the spoke sent its balance home the same USDC was counted in Idle AND in In-flight
    // Value; the shortfall a spoke's principal does not cover is now deducted from the fund total.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ09_strandedHubToSpokeTransitIsCountedOnceAfterTheSpokeSendsItHome() public {
        _send(1000e6, 1000e6); // Idle 8,975; 1,000 in flight to the spoke
        assertEq(vault.shareAssets(), 9975e6, "in flight, counted once");

        // The spoke credited the 1,000 but no accepted report ever listed the id: deducted as unknown value.
        _deliver(_spokeReport(1000e6, 1000e6));
        assertEq(
            vault.shareAssets(), 9975e6, "held by the spoke and deducted there, counted once through In-flight Value"
        );

        // The manager sends the whole Unallocated Balance home as Principal; the spoke's gross principal is now 0.
        bytes32 home = keccak256("home-after-strand");
        _deliver(_inFlightToHub(_spokeReport(0, 1000e6), home, 1000e6));
        assertEq(vault.inFlightValue(), 2000e6, "hub-to-spoke leg still open plus the return leg");
        assertEq(vault.shareAssets(), 9975e6, "the clamped deduction must not resurrect the stranded 1,000");

        pool.fill(address(vault), address(usdc), 1000e6, _homeMessage(home, TransferKind.Principal));
        assertEq(vault.idle(), 9975e6, "the 1,000 is back in Idle");
        assertEq(vault.shareAssets(), 9975e6, "DEC-104: never counted twice (Idle and In-flight Value)");
    }

    /// DEC-080, OQ-09: a stranger's bridge deposit on a spoke is never Share Assets, including after the manager sends
    /// it home as Principal: the deduction its spoke principal no longer covers follows it into Idle.
    function test_DEC080_strangerDepositSentHomeFromASpokeIsNeverShareAssets() public {
        uint256 assets0 = vault.shareAssets();
        _deliver(_spokeReport(500e6, 500e6)); // 500 of unknown origin credited by the spoke
        assertEq(vault.shareAssets(), assets0, "deducted at the spoke");

        bytes32 home = keccak256("stranger-home");
        _deliver(_inFlightToHub(_spokeReport(0, 500e6), home, 500e6));
        assertEq(vault.shareAssets(), assets0, "deducted from the return leg");

        pool.fill(address(vault), address(usdc), 500e6, _homeMessage(home, TransferKind.Principal));
        assertEq(vault.idle(), 9975e6 + 500e6, "credited to Idle as the report listed it");
        assertEq(vault.shareAssets(), assets0, "deducted from Idle");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout liveness fallback (DEC-021, DEC-056; OQ-10): `lastHubValue` is refreshed by a successful deposit or
    // payout and follows the exact USDC legs between Idle and the hub Spoke Vault since (`allocateToHubSpokeVault`
    // adds, `returnToIdle` subtracts). Regression of the verifier finding: before, the fallback added the stale hub
    // value on top of the Idle the USDC had already come back to (overcount) or missed a later allocation (undercount).
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC021_hubValueFallbackFollowsAReturnToIdleSinceTheLastValuation() public {
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1000e6); // Idle 8,975; hub Unallocated 1,000
        _deposit(bob, 1000e6); // last successful valuation: lastHubValue = 1,000
        hubVault.returnToCore(1000e6); // the hub Spoke Vault hands the 1,000 back: Idle 9,972.5; hub 0
        uint256 truth = vault.shareAssets();
        assertEq(truth, vault.idle(), "everything is Idle again");

        hubVault.setBuildReverts(true);
        _request(alice, 100e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.shareAssets, truth, "the fallback must not count the returned 1,000 a second time");
    }

    function test_DEC021_hubValueFallbackFollowsAnAllocationSinceTheLastValuation() public {
        _deposit(bob, 1000e6); // last successful valuation: lastHubValue = 0
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1000e6); // Idle -1,000; hub Unallocated 1,000
        uint256 truth = vault.shareAssets();
        assertEq(truth, vault.idle() + 1000e6, "the 1,000 moved to the hub Spoke Vault");

        hubVault.setBuildReverts(true);
        _request(alice, 100e6, ICoreVault.PayoutMode.Instant);
        vm.expectEmit(address(vault));
        emit ICoreVault.HubValuationFallback(1000e6);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        assertEq(r.shareAssets, truth, "the fallback must count the allocated 1,000");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Ruling 2026-09-29, DEC-107, DEC-109, OQ-01: an Income arrival that lands before any report lists it is held
    // apart untouched (no fee, no index move); the split happens at the match, and every unit ends in exactly one
    // place: protocol, ManagerFeeVault or the net collected bucket. The ledger stays backed throughout.
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC107_pendingIncomeArrivalIsSplitOnlyWhenTheReportMatchesIt() public {
        bytes32 id = keccak256("income-listed-late");
        uint256 protocol0 = usdc.balanceOf(protocol);
        address feeVault = vault.managerFeeVault();

        pool.fill(address(vault), address(usdc), 100e6, _homeMessage(id, TransferKind.Income));
        assertEq(vault.unmatchedArrivals(), 100e6, "held apart before any report lists it");
        assertEq(vault.collectedIncome(address(usdc)), 0, "nothing collected yet");
        assertEq(usdc.balanceOf(protocol), protocol0, "no slice before the match");
        assertEq(usdc.balanceOf(feeVault), 0, "no manager fee before the match");
        assertEq(vault.incomeState(address(usdc)).distributed, 0, "the index has not moved");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());

        vm.expectEmit(address(vault));
        emit ICoreVault.CollectedIncomeReceived(address(usdc), 100e6, 10e6, 10e6, 5000);
        _deliver(_inFlightToHub(_spokeReport(0, 0), id, 100e6, TransferKind.Income));

        assertEq(vault.unmatchedArrivals(), 0, "matched in full");
        assertEq(vault.collectedIncome(address(usdc)), 80e6, "net of the 20% fee");
        assertEq(usdc.balanceOf(protocol) - protocol0, 10e6, "half of the fee to the Protocol Recipient");
        assertEq(usdc.balanceOf(feeVault), 10e6, "the other half to the ManagerFeeVault");
        assertEq(vault.incomeState(address(usdc)).distributed, 80e6, "only the net enters the accumulator");
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), 80e6, 1, "Alice holds every share");
        assertEq(vault.idle(), 9975e6, "Idle never moved");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc(), "DEC-080: balance equals the ledger");
        assertEq(vault.sweepExcess(address(usdc)), 0, "nothing sweepable");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-092 / DEC-085 / DEC-066 B1 (ReportCodec v2): Income in flight home is outside Share Assets and In-flight
    // Value, yet it occupies the Spoke Cap until credited; the arrival then lands in the collected bucket, never Idle.
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC092_incomeInFlightHomeIsOutsideShareAssetsButInsideTheSpokeCap() public {
        bytes32 id = keccak256("income-home");
        uint256 assets0 = vault.shareAssets();
        _deliver(_inFlightToHub(_spokeReport(0, 0), id, 500e6, TransferKind.Income));

        assertEq(vault.shareAssets(), assets0, "income in flight home is not Share Assets");
        assertEq(vault.inFlightValue(), 0, "nor In-flight Value");
        (,, uint256 inFlightToHub,) = vault.spokeCapUsage(0);
        assertEq(inFlightToHub, 500e6, "but it holds the Spoke Cap until credited");

        pool.fill(address(vault), address(usdc), 500e6, _homeMessage(id, TransferKind.Income));
        (,, inFlightToHub,) = vault.spokeCapUsage(0);
        assertEq(inFlightToHub, 0, "released once credited");
        assertEq(vault.shareAssets(), assets0, "still outside Share Assets once collected");
        assertEq(vault.collectedIncome(address(usdc)), 400e6);
        assertEq(vault.idle(), 9975e6);
    }
}
