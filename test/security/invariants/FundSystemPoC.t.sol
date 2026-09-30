// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreBridgeVM, GuardianSignature} from "wormhole-sdk/interfaces/ICoreBridge.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {FundSystemFixture} from "./FundSystemFixture.sol";

/// @title Proofs of concept for the findings of the dynamic analysis
/// @notice Each `test_POC_` passes while the behaviour it shows exists. They run on the whole fund of
///         FundSystemFixture: the real Core Vault, Spoke Vaults and ValueReportReceiver.
contract FundSystemPoCTest is FundSystemFixture {
    address internal ana = makeAddr("ana");
    address internal bruno = makeAddr("bruno");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        _deploySystem();
        // Operating Cash off, so every number below is exact.
        vm.startPrank(manager);
        sys.core.setOperatingCashParameters(0, 0);
        sys.spokeVault.setOperatingCashParameters(0, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-01: an expired send home leaves Share Assets until its refund is recognized
    // ---------------------------------------------------------------------------------------------------------------

    /// OQ-09 stance ("a hub-bound transit leaves `inFlightToHub` once `fillDeadline + maxReportAge` has passed,
    /// presumed filled") against DEC-085 / DEC-104: a send home that no relayer filled is not filled, its value sits
    /// in its escrow (or still with Across), and from the first report after `fillDeadline + maxReportAge` until
    /// someone recognizes the refund on the spoke and a new report is delivered, that value is in no base at all.
    /// The Share Price is understated by the whole transfer, anyone who deposits in that window buys shares at the
    /// understated price, and the holders who were there pay for it. The manager alone can open the window (a quote
    /// no relayer takes) and every step after it is permissionless.
    function test_POC_expiredSendHomeLeavesShareAssetsAndAnEntrantTakesTheDifference() public {
        _fundWithSpokeBalance(50_000e6);
        uint256 assetsBefore = sys.core.shareAssets();
        uint256 priceBefore = sys.core.sharePrice();
        uint256 anaShares = sys.shares.balanceOf(ana);
        assertEq(assetsBefore, 99_999e6);

        // The manager sends the spoke's 50,000 USDG home with a quote no relayer fills (no fee for the relayer).
        uint256 depositIndex = sys.spokePool.numberOfDeposits();
        vm.prank(manager);
        bytes32 transitId = sys.spokeVault.sendToHub(50_000e6, TransferKind.Principal, 0, _quote(50_000e6));
        _report();
        assertEq(sys.core.shareAssets(), assetsBefore, "in flight home, still counted (DEC-085)");

        // The fill deadline and one report lifetime pass. Across has not refunded yet (refunds of expired deposits
        // are paid with a later bundle), or it has and nobody called recognizeRefund.
        Transit memory t = sys.spokeVault.hubBoundTransit(transitId);
        _warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1 - block.timestamp);
        _report();
        assertEq(sys.core.shareAssets(), assetsBefore - 50_000e6, "the transfer left every base");
        assertEq(sys.core.inFlightValue(), 0);
        assertLt(sys.core.sharePrice(), priceBefore * 5001 / 10_000, "Share Price halved with no loss");

        // Anyone deposits at the understated price.
        (uint256 attackerShares, uint256 charged) = _deposit(attacker, 50_000e6);
        assertGt(attackerShares, anaShares * 99 / 100, "the entrant gets as many shares as the whole prior supply");

        // The refund lands and is recognized (permissionless), a report is delivered: the value is back.
        sys.spokePool.refund(depositIndex);
        vm.prank(attacker);
        sys.spokeVault.recognizeRefund(transitId);
        _report();
        assertEq(sys.core.shareAssets(), assetsBefore + charged - ShareMath.flowFee(50_000e6, FLOW_FEE_BPS));

        // The entrant exits at once (Instant Payout from Idle), paying the 2% Payout Fee and the flow fee.
        uint256 worth = ShareMath.usdcFor(attackerShares, sys.core.sharePrice());
        vm.startPrank(attacker);
        sys.core.requestPayout(worth, ICoreVault.PayoutMode.Instant);
        sys.core.claimPayout("");
        vm.stopPrank();
        uint256 profit = sys.usdc.balanceOf(attacker) - 50_000e6;
        assertGt(profit, 22_000e6, "the entrant leaves with more than 22,000 USDC above the 50,000 deposited");

        // Ana's 99,999 shares, worth 99,999 USDC before, are now worth about 75,000.
        uint256 anaWorth = ShareMath.usdcFor(anaShares, sys.core.sharePrice());
        assertLt(anaWorth, 76_000e6, "the prior holder lost a quarter of her value");
        assertGt(assetsBefore - anaWorth, profit, "and the loss covers the entrant's profit and the fees");
    }

    /// The same window seen from a leaver: a holder whose payout is priced while the transfer is in no base is paid
    /// half of what the shares are worth, and the difference stays with the other holders.
    function test_POC_payoutDuringTheWindowIsPaidAtTheUnderstatedPrice() public {
        _fundWithSpokeBalance(50_000e6);
        _deposit(bruno, 10_025e6);
        uint256 brunoShares = sys.shares.balanceOf(bruno);
        uint256 fairValue = ShareMath.usdcFor(brunoShares, sys.core.sharePrice());

        vm.prank(manager);
        bytes32 transitId = sys.spokeVault.sendToHub(50_000e6, TransferKind.Principal, 0, _quote(50_000e6));
        Transit memory t = sys.spokeVault.hubBoundTransit(transitId);
        _warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1 - block.timestamp);
        _report();

        vm.startPrank(bruno);
        sys.core.requestPayout(fairValue, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = sys.core.claimPayout("");
        vm.stopPrank();
        assertEq(sys.shares.balanceOf(bruno), 0, "every share burned");
        assertLt(receipt.usdcGross, fairValue * 55 / 100, "for little more than half their value");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-02: a send home that no report lists in time is held apart for good
    // ---------------------------------------------------------------------------------------------------------------

    /// OQ-01 ("an arrival is credited only up to what an accepted report listed; anything else is held apart for good,
    /// never swept") together with the OQ-09 drop above: a send home is filled within minutes, long before a report
    /// can list it (finalized consistency), so it waits in `unmatchedArrivals`. If no report built while the transfer
    /// is still listed reaches the hub (nobody publishes or delivers for `fillDeadline + maxReportAge`, about 6.5
    /// hours: a keeper outage, a guardian pause for the spoke chain, a hub or spoke sequencer outage, or reports that
    /// keep ageing out at delivery), the spoke stops listing it and no later report ever will. The fund's own USDC
    /// then stays in the Core Vault outside every base, with no verb that credits or sweeps it.
    function test_POC_sendHomeFilledButNeverListedIsLostToTheFund() public {
        _fundWithSpokeBalance(50_000e6);
        uint256 assetsBefore = sys.core.shareAssets();

        uint256 depositIndex = sys.spokePool.numberOfDeposits();
        vm.prank(manager);
        bytes32 transitId = sys.spokeVault.sendToHub(50_000e6, TransferKind.Principal, 0, _quote(49_900e6));

        // The relayer fills on the hub within seconds; no report lists the transfer yet.
        MockAcrossSpokePool.Deposit memory d = sys.spokePool.deposit(depositIndex);
        sys.hubPool.fill(address(sys.core), address(sys.usdc), d.outputAmount, d.message);
        assertEq(sys.core.unmatchedArrivals(), 49_900e6, "held apart until a report lists it");

        // No report is delivered for fillDeadline + maxReportAge.
        Transit memory t = sys.spokeVault.hubBoundTransit(transitId);
        _warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1 - block.timestamp);
        _report();

        // The spoke no longer lists the transfer, so the hub never credits it.
        assertEq(sys.spokeVault.inFlightTransitIds().length, 0);
        assertEq(sys.core.unmatchedArrivals(), 49_900e6);
        assertEq(sys.core.idle(), assetsBefore - 50_000e6);
        assertEq(sys.core.shareAssets(), assetsBefore - 50_000e6, "half of the fund is in no base");
        assertGe(sys.usdc.balanceOf(address(sys.core)), sys.core.idle() + 49_900e6, "the USDC is in the Core Vault");

        // Nothing recovers it: it is ledger value for the sweep, no refund exists, later reports do not list it.
        assertEq(sys.core.sweepExcess(address(sys.usdc)), 0);
        vm.expectRevert();
        sys.spokeVault.recognizeRefund(transitId);
        _warp(30 days);
        _report();
        assertEq(sys.core.unmatchedArrivals(), 49_900e6);
        assertEq(sys.core.shareAssets(), assetsBefore - 50_000e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-03: the manager can move all principal into Operating Cash, which nothing ever pays out
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-096 / DEC-100 ("floor configurable by the Manager", "no protocol cap on the floor") with an uncapped top-up
    /// and no verb that spends or returns Operating Cash in the MVP: one parameter change and one 1-unit allocation
    /// move all Free Idle into Operating Cash, outside Share Assets, for good.
    function test_POC_managerMovesAllFreeIdleIntoOperatingCash() public {
        _deposit(ana, 100_250e6);
        uint256 idle = sys.core.idle();
        assertEq(idle, 99_999e6);

        vm.startPrank(manager);
        sys.core.setOperatingCashParameters(type(uint256).max, idle - 1);
        sys.core.allocateToHubSpokeVault(1);
        vm.stopPrank();

        assertEq(sys.core.idle(), 0);
        assertEq(sys.core.operatingCash(), idle - 1, "all Free Idle is Operating Cash now");
        assertEq(sys.core.shareAssets(), 1, "Share Assets: one base unit");
        assertEq(sys.core.sweepExcess(address(sys.usdc)), 0, "not sweepable: it is ledger value");

        // Ana's 99,999 shares, bought for 99,999 USDC, are worth nothing: a payout burns them all and pays zero.
        assertEq(ShareMath.usdcFor(sys.shares.balanceOf(ana), sys.core.sharePrice()), 0);
        vm.startPrank(ana);
        sys.core.requestPayout(99_999e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory receipt = sys.core.claimPayout("");
        vm.stopPrank();
        assertEq(receipt.sharesBurned, 99_999e18);
        assertEq(receipt.usdcPaid, 0);
        assertEq(sys.usdc.balanceOf(address(sys.core)), idle - 1, "while the USDC is still in the Core Vault");
    }

    /// The same on a spoke, where the top-up also runs on an arrival: after the manager's parameter change, a
    /// stranger's one-unit Across deposit is enough to move the whole Unallocated Balance into Operating Cash.
    function test_POC_managerMovesAllSpokePrincipalIntoOperatingCash() public {
        _fundWithSpokeBalance(50_000e6);
        vm.prank(manager);
        sys.spokeVault.setOperatingCashParameters(type(uint256).max, type(uint256).max);

        sys.spokePool
            .fill(
                address(sys.spokeVault),
                address(sys.usdg),
                1,
                abi.encode(uint256(1), FUND_ID, HUB, keccak256("any id"), TransferKind.Principal)
            );
        assertEq(sys.spokeVault.unallocatedBalance(address(sys.usdg)), 0);
        assertEq(sys.spokeVault.operatingCash(), 50_000e6 + 1);
        _report();
        // Half of the fund left Share Assets for good (and the stranger's unit is deducted as unknown value, DEC-080).
        assertEq(sys.core.shareAssets(), 99_999e6 - 50_000e6 - 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Finding DYN-04: with Share Assets at zero and shares outstanding, every exit verb reverts
    // ---------------------------------------------------------------------------------------------------------------

    /// Found by the deep invariant campaign on the existing Core Vault suite (ZeroSharePrice). Payout liveness
    /// (DEC-021, DEC-056) says a claim never reverts because of a valuation; with a valuation of exactly zero (the
    /// state above, a total loss in a position, or a payout fallback to a never-priced token, CS-OQ-4) an open
    /// request cannot be claimed, a new one cannot be opened and no deposit can enter, until value returns.
    function test_POC_zeroShareAssetsRevertEveryPayoutVerb() public {
        _deposit(ana, 100_250e6);
        vm.prank(ana);
        sys.core.requestPayout(1000e6, ICoreVault.PayoutMode.Instant);
        _deposit(bruno, 10_025e6);

        // Everything is allocated to the hub Spoke Vault and then lost there (a position that went to zero), modelled
        // by the hub report reading zero: Share Assets are zero with shares outstanding.
        uint256 idle = sys.core.idle();
        vm.prank(manager);
        sys.core.allocateToHubSpokeVault(idle);
        vm.mockCall(address(sys.hubVault), abi.encodeWithSignature("buildReport()"), abi.encode(_emptyReport()));
        assertEq(sys.core.shareAssets(), 0);

        vm.prank(ana);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        sys.core.claimPayout("");
        vm.prank(bruno);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        sys.core.requestPayout(1e6, ICoreVault.PayoutMode.Instant);
        sys.usdc.mint(bruno, 1000e6);
        vm.startPrank(bruno);
        sys.usdc.approve(address(sys.core), 1000e6);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        sys.core.deposit(1000e6, 0);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------------------------

    function _deposit(address who, uint256 amount) internal returns (uint256 shares, uint256 charged) {
        sys.usdc.mint(who, amount);
        vm.startPrank(who);
        sys.usdc.approve(address(sys.core), amount);
        (shares, charged) = sys.core.deposit(amount, 0);
        vm.stopPrank();
    }

    function _quote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote(outputAmount, uint32(block.timestamp), 0, address(0));
    }

    /// @dev Anyone publishes the spoke's report and delivers its VAA to the hub.
    function _report() internal {
        uint256 index = sys.wormhole.publishedCount();
        sys.spokeVault.report();
        MockWormholeCore.Published memory p = sys.wormhole.published(index);
        CoreBridgeVM memory m;
        m.version = 1;
        m.emitterChainId = WH_SPOKE;
        m.emitterAddress = bytes32(uint256(uint160(p.emitter)));
        m.sequence = p.sequence;
        m.consistencyLevel = p.consistencyLevel;
        m.payload = p.payload;
        m.signatures = new GuardianSignature[](0);
        sys.receiver.deliver(abi.encode(m));
    }

    function _emptyReport() internal view returns (ReportCodec.Report memory r) {
        r.timestamp = uint64(block.timestamp);
    }

    function _warp(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        sys.prices.setPrice(address(sys.usdg), 1e18);
    }

    /// @dev 100,000 USDC deposited by Ana, `toSpoke` of it sent to the spoke, filled and confirmed by a report.
    function _fundWithSpokeBalance(uint256 toSpoke) internal {
        _deposit(ana, 100_250e6);
        uint256 depositIndex = sys.hubPool.numberOfDeposits();
        vm.prank(manager);
        sys.core.sendToSpoke(0, toSpoke, 0, _quote(toSpoke));
        MockAcrossSpokePool.Deposit memory d = sys.hubPool.deposit(depositIndex);
        sys.spokePool.fill(address(sys.spokeVault), address(sys.usdg), d.outputAmount, d.message);
        _report();
    }
}
