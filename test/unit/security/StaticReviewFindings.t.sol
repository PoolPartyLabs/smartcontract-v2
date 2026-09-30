// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "../core/CoreVaultFixture.sol";

/// @notice Security proofs of concept for two findings of the static review
///         (docs/security/reports/static-analysis.md, SA-02 and SA-03). Each test passes while the code is exposed: it
///         pins the exposure, not a rule.
contract StaticReviewFindingsTest is CoreVaultFixture {
    uint256 internal constant SENT = 1000e6;
    uint256 internal constant ARRIVES = 999.4e6;
    uint256 internal constant HOME = 500e6;
    uint256 internal constant HOME_ARRIVES = 499.7e6;

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6); // Idle 9,975
    }

    // ---------------------------------------------------------------------------------------------------------------
    // SA-02 (security review S-4): the fund's own transfer home is no longer locked when no report listed it
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Was PoC `test_POC_SA02_transferHomeNoAcceptedReportListedIsLockedForGood`: an arrival no accepted report
    ///      ever listed stayed in `unmatchedArrivals` for good once the spoke stopped listing it. Fix (S-4):
    ///      `recoverUnlistedArrival` credits it to Idle as Principal once no acceptable report can list it any more
    ///      (`UNLISTED_ARRIVAL_DELAY` plus twice the report lifetime after the first unlisted arrival).
    function test_SEC_S4_SA02_transferHomeNoAcceptedReportListedIsRecovered() public {
        bytes32 id = _send(SENT, ARRIVES);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        uint256 assetsBefore = vault.shareAssets();
        uint256 idleBefore = vault.idle();

        bytes32 homeId = keccak256("home-1");
        pool.fill(
            address(vault),
            address(usdc),
            HOME_ARRIVES,
            TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal)
        );
        uint256 arrivedAt = block.timestamp;
        assertEq(vault.unmatchedArrivals(), HOME_ARRIVES, "held apart until a report lists it");

        // The spoke stopped listing it (past fillDeadline + HUB_BOUND_RETENTION): its report shows the lower
        // Unallocated Balance and an empty inFlightToHub.
        vm.warp(block.timestamp + 6 hours + 3 days + 1);
        _deliver(_spokeReport(ARRIVES - HOME, ARRIVES));
        assertEq(vault.unmatchedArrivals(), HOME_ARRIVES);

        uint256 readyAt = arrivedAt + 6 hours + 3 days + 2 * uint256(MAX_REPORT_AGE);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.RecoveryNotReady.selector, homeId, readyAt));
        vault.recoverUnlistedArrival(0, homeId);

        vm.warp(readyAt);
        assertEq(vault.recoverUnlistedArrival(0, homeId), HOME_ARRIVES, "S-4: recovered, permissionless");
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.idle(), idleBefore + HOME_ARRIVES, "S-4: in Idle");
        assertEq(vault.shareAssets(), assetsBefore - HOME + HOME_ARRIVES, "S-4: only the bridge fee is lost");
        assertEq(vault.sweepExcess(address(usdc)), 0);

        // A later listing of the same id (were one ever accepted) nets the recovered amount out: nothing twice.
        _deliver(_inFlightToHub(_spokeReport(ARRIVES - HOME, ARRIVES), homeId, HOME_ARRIVES));
        assertEq(vault.inFlightValue(), 0, "S-4: the listing counts nothing beyond what was credited");
        assertEq(vault.idle(), idleBefore + HOME_ARRIVES);
    }

    /// @dev S-4: only an arrival no accepted report listed can be recovered; a listed one is credited by the report.
    function test_SEC_S4_listedOrUnknownArrivalCannotBeRecovered() public {
        bytes32 homeId = keccak256("home-2");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, homeId));
        vault.recoverUnlistedArrival(0, homeId);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnknownSpoke.selector, 1));
        vault.recoverUnlistedArrival(1, homeId);

        _deliver(_inFlightToHub(_spokeReport(0, 0), homeId, HOME_ARRIVES));
        pool.fill(
            address(vault),
            address(usdc),
            HOME_ARRIVES,
            TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal)
        );
        assertEq(vault.unmatchedArrivals(), 0, "listed first: credited at arrival");
        vm.warp(block.timestamp + 30 days);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, homeId));
        vault.recoverUnlistedArrival(0, homeId);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // SA-03: Operating Cash only grows, and the manager sets its floor and top-up without a bound
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev DEC-096, DEC-100: the manager may change the floor and the top-up on a live fund and there is no protocol
    ///      cap. No verb ever decreases Operating Cash (spending it is OPEN, doc 30; fund closure does not exist), and
    ///      the contracts are immutable (DEC-058), so whatever enters it is locked for good. Two manager calls move all
    ///      Free Idle there.
    function test_POC_SA03_managerParametersMoveAllFreeIdleIntoOperatingCashForGood() public {
        uint256 free = vault.freeIdle();
        assertEq(free, 9975e6);
        uint256 assetsBefore = vault.shareAssets();

        vm.startPrank(manager);
        vault.setOperatingCashParameters(type(uint256).max, free - 1e6);
        vault.allocateToHubSpokeVault(1e6);
        vm.stopPrank();

        assertEq(vault.operatingCash(), free - 1e6, "all Free Idle but 1 USDC is now Operating Cash");
        assertEq(vault.idle(), 0);
        assertEq(vault.shareAssets(), 1e6, "Share Assets fell from 9,975 to 1 USDC");
        assertLt(vault.shareAssets(), assetsBefore);
        assertEq(vault.sweepExcess(address(usdc)), 0, "Operating Cash is ledger value, never swept");

        // The holder's whole balance is now worth 1 USDC, and nothing is left in Idle to pay even that.
        _request(alice, 9975e6, ICoreVault.PayoutMode.Instant);
        vm.expectPartialRevert(ICoreVault.InsufficientFreeIdle.selector);
        vm.prank(alice);
        vault.claimPayout("");
    }

    /// @dev DEC-102: the Payout Fee of every Instant Payout goes whole to Operating Cash. With no spend verb and no
    ///      closure, that USDC leaves the holders for good on the honest path too.
    function test_POC_SA03_payoutFeeIsLockedInOperatingCash() public {
        _request(alice, 5000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = _claim(alice);
        assertEq(receipt.payoutFee, 100e6, "2% of 5,000");
        assertEq(vault.operatingCash(), 100e6);
        assertEq(vault.sweepExcess(address(usdc)), 0);
        // Nothing in ICoreVault decreases `operatingCash`; it is outside Share Assets (DEC-013).
        assertEq(vault.shareAssets(), vault.idle());
    }

    /// @dev Security review S-5 (interim mitigation pending a DEC-100 ruling): the sweep of SA-03 is reversible. The
    ///      manager lowers the floor and returns Operating Cash above it to Idle; Share Assets and the holder's claim
    ///      are restored. Nobody else can call it, and it never pays anyone: it only moves value back to Share Assets.
    function test_SEC_S5_operatingCashAboveTheFloorReturnsToIdle() public {
        uint256 free = vault.freeIdle();
        uint256 assetsBefore = vault.shareAssets();
        vm.startPrank(manager);
        vault.setOperatingCashParameters(type(uint256).max, free - 1e6);
        vault.allocateToHubSpokeVault(1e6);
        vm.stopPrank();
        assertEq(vault.operatingCash(), free - 1e6);

        // Nothing is above an unbounded floor; a stranger can never call it.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.OperatingCashNotReleasable.selector, 1, 0));
        vault.releaseOperatingCash(1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotManager.selector, alice));
        vault.releaseOperatingCash(1);

        // The manager restores a sane floor and returns the rest.
        vm.startPrank(manager);
        vault.setOperatingCashParameters(3e6, 3e6);
        vault.releaseOperatingCash(free - 1e6 - 3e6);
        vm.stopPrank();
        assertEq(vault.operatingCash(), 3e6);
        assertEq(vault.shareAssets(), assetsBefore - 3e6, "S-5: Share Assets restored but for the floor");
        assertEq(vault.sweepExcess(address(usdc)), 0);

        _request(alice, 9000e6, ICoreVault.PayoutMode.Instant);
        assertEq(_claim(alice).usdcOutstanding, 0, "S-5: the holder is paid again");
    }
}
