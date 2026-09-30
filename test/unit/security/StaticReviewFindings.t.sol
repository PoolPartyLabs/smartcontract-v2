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
    // SA-02: the fund's own transfer home is locked for good when no accepted report ever listed it
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev OQ-01 stance: the hub credits a spoke-to-hub arrival only up to what an accepted report listed for its id;
    ///      anything else stays in `unmatchedArrivals`, outside every base and never swept. OQ-09 stance: the spoke
    ///      lists a send home only until `fillDeadline + maxReportAge` (SpokeCrossChainLib._stillInFlight), then presumes
    ///      it filled. If no report built in that window is accepted on the hub (keeper down, or Wormhole finality on
    ///      the spoke slower than the report lifetime for the whole window), the filled transfer is never listed again:
    ///      the USDC sits in the Core Vault, Share Assets lose it, and no verb can recover it.
    function test_POC_SA02_transferHomeNoAcceptedReportListedIsLockedForGood() public {
        // The spoke holds 999.4 USDG the hub sent and confirmed.
        bytes32 id = _send(SENT, ARRIVES);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        uint256 assetsBefore = vault.shareAssets();
        uint256 idleBefore = vault.idle();

        // The manager sends 500 USDG home. Across fills it on the hub; every report built while the spoke still listed
        // the transfer was rejected as too old or never delivered (nothing is delivered here during the window).
        bytes32 homeId = keccak256("home-1");
        pool.fill(
            address(vault),
            address(usdc),
            HOME_ARRIVES,
            TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal)
        );
        assertEq(vault.unmatchedArrivals(), HOME_ARRIVES, "held apart until a report lists it");

        // After fillDeadline + maxReportAge the spoke presumes the transfer filled and stops listing it: its next
        // report shows the lower Unallocated Balance and an empty inFlightToHub.
        vm.warp(block.timestamp + 6 hours + MAX_REPORT_AGE + 1);
        _deliver(_spokeReport(ARRIVES - HOME, ARRIVES));

        assertEq(vault.unmatchedArrivals(), HOME_ARRIVES, "still held apart: no report will ever list the id again");
        assertEq(vault.idle(), idleBefore, "the USDC never reached Idle");
        assertEq(vault.inFlightValue(), 0, "and it is not in flight either");
        assertEq(vault.shareAssets(), assetsBefore - HOME, "Share Assets lost the whole transfer");
        assertEq(vault.sweepExcess(address(usdc)), 0, "not even the garbage collector can move it");
        assertGe(usdc.balanceOf(address(vault)), idleBefore + HOME_ARRIVES, "the USDC is in the Core Vault");
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
}
