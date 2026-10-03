// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
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
    ///      `recoverUnlistedArrival` credits it to Idle as Principal once a report built after the arrival (plus one
    ///      report lifetime of clock-skew margin) no longer lists it.
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

        // Cross-check of the independent review: the latest accepted report predates the arrival and still counts
        // the transfer on the spoke, so recovery is refused whatever the delay.
        vm.warp(block.timestamp + 6 hours + 3 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.RecoveryNotReady.selector, homeId, arrivedAt + uint256(MAX_REPORT_AGE))
        );
        vault.recoverUnlistedArrival(0, homeId);

        // The spoke stopped listing it (past fillDeadline + HUB_BOUND_RETENTION): its report, built after the arrival,
        // shows the lower Unallocated Balance and an empty inFlightToHub, so recovery opens at once.
        _deliver(_spokeReport(ARRIVES - HOME, ARRIVES));
        assertEq(vault.unmatchedArrivals(), HOME_ARRIVES);
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

    /// @dev Cross-check S-64: dust bridged under the id after the transfer (a stranger holding the recovery off) does not
    ///      restart the clock; an arrival at least as large as what is held does, so holding it off costs the whole
    ///      held amount again, which the recovery then credits to the fund.
    function test_SEC_S64_dustAfterTheTransferDoesNotRestartTheRecoveryClock() public {
        bytes32 id = _send(SENT, ARRIVES);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        bytes32 homeId = keccak256("home-3");
        pool.fill(
            address(vault),
            address(usdc),
            HOME_ARRIVES,
            TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal)
        );
        vm.warp(block.timestamp + 6 hours + 3 days + 1);
        pool.fill(
            address(vault), address(usdc), 1, TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal)
        );
        _deliver(_spokeReport(ARRIVES - HOME, ARRIVES));
        assertEq(vault.recoverUnlistedArrival(0, homeId), HOME_ARRIVES + 1, "the dust did not hold it off");

        // A second id: an arrival as large as the held amount restarts the clock.
        bytes32 otherId = keccak256("home-4");
        pool.fill(
            address(vault), address(usdc), 100e6, TransitMessage.encode(FUND_ID, SPOKE, otherId, TransferKind.Principal)
        );
        vm.warp(block.timestamp + 2 * uint256(MAX_REPORT_AGE));
        pool.fill(
            address(vault), address(usdc), 100e6, TransitMessage.encode(FUND_ID, SPOKE, otherId, TransferKind.Principal)
        );
        uint256 restartedAt = block.timestamp;
        vm.warp(block.timestamp + 10);
        _deliver(_spokeReport(ARRIVES - HOME, ARRIVES));
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.RecoveryNotReady.selector, otherId, restartedAt + uint256(MAX_REPORT_AGE))
        );
        vault.recoverUnlistedArrival(0, otherId);
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
    function test_REGRESSION_SA03_managerParametersMoveAllFreeIdleIntoOperatingCashForGood() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }

    /// @dev SA-03, fixed by DEC-144 (corrects DEC-102 items 2-4): the Payout Fee of an Instant Payout used to go
    ///      whole to Operating Cash, which nothing spends; it now stays in Idle and in Share Assets.
    function test_DEC144_SA03_payoutFeeStaysInShareAssets() public {
        uint256 idleBefore = vault.idle();
        ICoreVault.PayoutReceipt memory receipt = _request(alice, 5000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertEq(receipt.payoutFee, 100e6, "2% of 5,000");
        assertEq(vault.operatingCash(), 0);
        assertEq(vault.idle(), idleBefore - receipt.usdcGross + receipt.payoutFee);
        assertEq(vault.sweepExcess(address(usdc)), 0);
        assertEq(vault.shareAssets(), vault.idle());
    }

    /// @dev Security review S-5 (open) with S-63: the sweep's interim `releaseOperatingCash` let a manager depress the
    ///      Share Price with the sink, have an ally mint at it and release the cash back, so it was removed; the sink is
    ///      one-way until the founder rules on a cap (SEC-OQ-2). Nothing returns the cash and it is never swept.
    function test_SEC_S63_operatingCashSinkHasNoReleaseVerb() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }
}
