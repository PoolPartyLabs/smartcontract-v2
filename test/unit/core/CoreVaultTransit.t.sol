// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ITransitEscrow} from "../../../src/interfaces/ITransitEscrow.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockAcrossSpokePool} from "../../mocks/core/MockAcrossSpokePool.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

contract CoreVaultTransitTest is CoreVaultFixture {
    uint256 internal constant SENT = 1000e6;
    uint256 internal constant ARRIVES = 999.4e6; // 6 bps route fee, fixed by the (mock) bridge adapter, DEC-162

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6); // Idle 9,975
        _ensureSpokeReport(); // S-14: the spoke has reported once before the hub funds it
    }

    function _sendDefault() internal returns (bytes32) {
        return _send(SENT, ARRIVES);
    }

    function _homeMessage(bytes32 id, TransferKind kind) internal pure returns (bytes memory) {
        return TransitMessage.encode(FUND_ID, SPOKE, id, kind);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // sendToSpoke
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC087_sendFixesRecipientTokensAndEscrowDepositor() public {
        uint256 assetsBefore = vault.shareAssets();
        bytes32 id = _sendDefault();
        Transit memory t = vault.transit(id);
        assertEq(uint8(t.state), uint8(TransitState.Sent));
        assertEq(t.amountSent, SENT);
        assertEq(t.amountToArrive, ARRIVES);
        assertEq(t.destinationChainId, SPOKE);
        assertEq(t.bridgeAdapter, address(bridge));
        assertEq(t.fillDeadline, block.timestamp + 21_600);
        assertEq(t.bridgeRef, bytes32(0));

        MockAcrossSpokePool.Deposit memory d = pool.deposit(0);
        assertEq(d.depositor, t.escrow, "DEC-066: the per-send escrow is the depositor");
        assertEq(d.recipient, spokeVaultAddress, "DEC-087: the Mandate Spoke Vault is the recipient");
        assertEq(d.inputToken, address(usdc));
        assertEq(d.outputToken, address(usdg));
        assertEq(d.inputAmount, SENT);
        assertEq(d.outputAmount, ARRIVES);
        assertEq(d.destinationChainId, SPOKE);
        (bytes32 fund, uint256 origin, bytes32 transitId, TransferKind kind) = TransitMessage.decode(d.message);
        assertEq(fund, FUND_ID);
        assertEq(origin, HUB);
        assertEq(transitId, id);
        assertEq(uint8(kind), uint8(TransferKind.Principal));

        assertEq(ITransitEscrow(t.escrow).vault(), address(vault));
        assertEq(ITransitEscrow(t.escrow).token(), address(usdc));
        assertEq(usdc.allowance(address(vault), address(pool)), 0, "approval reset");
        assertEq(vault.idle(), SEED_IDLE + 9975e6 - SENT);
        // DEC-085: In-flight Value counts at the amount that will arrive.
        assertEq(vault.inFlightValue(), ARRIVES);
        assertEq(vault.shareAssets(), assetsBefore - SENT + ARRIVES);
        (uint256 spokeValue, uint256 inFlightSent,, uint256 cap) = vault.spokeCapUsage(0);
        assertEq(spokeValue, 0);
        assertEq(inFlightSent, SENT, "DEC-066 C1: the Spoke Cap counts the amount sent");
        assertEq(cap, SPOKE_CAP);
    }

    function test_DEC037_spokeCapCountsInFlightAtAmountSent() public {
        _deposit(bob, 200_000e6);
        _send(99_500e6, 99_450e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, 99_500e6, 600e6, SPOKE_CAP));
        vault.sendToSpoke(0, 600e6, 0, _quote(599.7e6));
        _send(500e6, 499.7e6); // exactly at the cap
    }

    function test_DEC066_B1_spokeCapCountsPendingReturnLeg() public {
        _deposit(bob, 200_000e6);
        ReportCodec.Report memory r = _spokeReport(40_000e6, 0);
        _deliver(_inFlightToHub(r, keccak256("home-1"), 30_000e6));
        (uint256 spokeValue, uint256 inFlightSent, uint256 inFlightToHub,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, 40_000e6);
        assertEq(inFlightSent, 0);
        assertEq(inFlightToHub, 30_000e6, "the pending return leg, on its own line");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeCapExceeded.selector, 0, 70_000e6, 30_001e6, SPOKE_CAP));
        vault.sendToSpoke(0, 30_001e6, 0, _quote(30_000e6));
    }

    function test_DEC056_pausedOrDeprecatedBridgeAdapterRefused() public {
        bridge.setPaused(true);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeAdapterUnavailable.selector, address(bridge)));
        vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
        bridge.setPaused(false);
        bridge.deprecate();
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeAdapterUnavailable.selector, address(bridge)));
        vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
    }

    function test_DEC088_unknownBridgeRankRefused() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeAdapterUnavailable.selector, address(0)));
        vault.sendToSpoke(0, SENT, 1, _quote(ARRIVES));
    }

    /// DEC-156, DEC-162: no bridge fee cap lives in the Core Vault (nor in the Mandate since Mandate v2);
    /// the adapter's fee rule fixes the amount to arrive, and the vault takes it as given.
    function test_DEC156_vaultKeepsNoBridgeFeeCap() public {
        vm.prank(manager);
        bytes32 id = vault.sendToSpoke(0, SENT, 0, _quote(994e6));
        assertEq(vault.transit(id).amountToArrive, 994e6, "60 bps, above the old Mandate bound");
        assertEq(vault.inFlightValue(), 994e6);
    }

    /// DEC-085, DEC-162: the vault requires the adapter's amount to arrive above zero and not above the amount sent.
    function test_DEC085_amountToArriveZeroOrAboveSentRefused() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeCallMismatch.selector, address(bridge)));
        vault.sendToSpoke(0, SENT, 0, _quote(0));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeCallMismatch.selector, address(bridge)));
        vault.sendToSpoke(0, SENT, 0, _quote(SENT + 1));
        vault.sendToSpoke(0, SENT, 0, _quote(SENT)); // a send that pays no fee is a valid one
        vm.stopPrank();
    }

    /// DEC-158, DEC-162: the vault passes `bridgeData` to the adapter untouched and never reads it; without it the
    /// adapter's own rule applies (the mock's flat fee here).
    function test_DEC162_withoutBridgeDataTheAdapterPrices() public {
        bridge.setFee(0.83e6);
        vm.prank(manager);
        bytes32 id = vault.sendToSpoke(0, SENT, 0, "");
        assertEq(vault.transit(id).amountToArrive, SENT - 0.83e6);
    }

    function test_DEC087_bridgeCallWithOtherTargetRefused() public {
        bridge.setBadTarget(makeAddr("attacker"));
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeCallMismatch.selector, address(bridge)));
        vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
    }

    /// DEC-085: an adapter that reports more than was sent is refused.
    function test_DEC085_bridgeCallWithAmountToArriveAboveSentRefused() public {
        bridge.setArriveDelta(1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BridgeCallMismatch.selector, address(bridge)));
        vault.sendToSpoke(0, SENT, 0, _quote(SENT));
    }

    function test_DEC087_inexactDebitRefused() public {
        pool.setShortPull(1e6);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BalanceChangeMismatch.selector, SENT, SENT - 1e6));
        vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
    }

    function test_DEC002_sendIsManagerOnly() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotManager.selector, alice));
        vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
    }

    function test_DEC095_sendUnknownSpokeOrAboveFreeIdleRefused() public {
        vm.startPrank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnknownSpoke.selector, 1));
        vault.sendToSpoke(1, SENT, 0, _quote(ARRIVES));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InsufficientFreeIdle.selector, 20_000e6, SEED_IDLE + 9975e6));
        vault.sendToSpoke(0, 20_000e6, 0, _quote(19_990e6));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Transit outcomes (DEC-066)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC066_arrivalConfirmedByReportMovesValueToSpoke() public {
        bytes32 id = _sendDefault();
        uint256 assetsInFlight = vault.shareAssets();
        vm.expectEmit(address(vault));
        emit ICoreVault.TransitArrived(id, 0, ARRIVES, reportSequence + 1);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertEq(vault.inFlightValue(), 0);
        (uint256 spokeValue, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, ARRIVES);
        assertEq(inFlightSent, 0);
        assertEq(vault.shareAssets(), assetsInFlight, "DEC-104: the value moved base, not amount");
        // A repeated id in a later report is a no-op.
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        assertEq(vault.shareAssets(), assetsInFlight);
    }

    function test_DEC080_unknownSpokeArrivalIsDeducted() public {
        bytes32 id = _sendDefault();
        // The spoke also credited 500 USDG a stranger bridged with a fabricated id.
        _deliver(_arrived(_spokeReport(ARRIVES + 500e6, ARRIVES + 500e6), id, ARRIVES));
        (uint256 spokeValue,,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, ARRIVES);
    }

    function test_DEC066_attestExpiryNeedsDeadline() public {
        bytes32 id = _sendDefault();
        uint32 deadline = vault.transit(id).fillDeadline;
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.FillDeadlineNotReached.selector, id, deadline));
        vault.attestExpiry(id);
    }

    function test_DEC066_attestExpiryNeedsProofOfNonArrival() public {
        bytes32 id = _sendDefault();
        _deliver(_spokeReport(0, 0)); // built before the deadline
        vm.warp(vault.transit(id).fillDeadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, id));
        vault.attestExpiry(id);
    }

    function test_DEC066_attestExpiryByLaterReportReleasesCapKeepsShareAssets() public {
        bytes32 id = _sendDefault();
        vm.warp(vault.transit(id).fillDeadline + 1);
        _deliver(_spokeReport(0, 0)); // built after the deadline, does not list the id
        uint256 assets = vault.shareAssets();
        vm.expectEmit(address(vault));
        emit ICoreVault.TransitExpiryAttested(id, 0, bob);
        vm.prank(bob);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
        (, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(inFlightSent, 0, "Spoke Cap released");
        assertEq(vault.inFlightValue(), ARRIVES, "QB11 stance: still in Share Assets");
        assertEq(vault.shareAssets(), assets);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InvalidTransitState.selector, id, 3));
        vault.attestExpiry(id);
    }

    function test_OQ09_fullArrivalWindowCannotProveNonArrival() public {
        bytes32 id = _sendDefault();
        vm.warp(vault.transit(id).fillDeadline + 1);
        // A report built after the deadline whose window is full (possibly flushed by spam): silence proves nothing.
        ReportCodec.Report memory r = _spokeReport(0, 0);
        r.arrivedTransits = new ReportCodec.TransitAmount[](ReportCodec.ARRIVAL_WINDOW);
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            r.arrivedTransits[i] = ReportCodec.TransitAmount(keccak256(abi.encode("spam", i)), 1e6);
        }
        _deliver(r);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, id));
        vault.attestExpiry(id);
        // One entry fewer than the window: the report's silence is proof again.
        r = _spokeReport(0, 0);
        r.arrivedTransits = new ReportCodec.TransitAmount[](ReportCodec.ARRIVAL_WINDOW - 1);
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            r.arrivedTransits[i] = ReportCodec.TransitAmount(keccak256(abi.encode("spam", i)), 1e6);
        }
        _deliver(r);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
    }

    function test_OQ09_fullArrivalWindowFallsBackToTheReportLifetime() public {
        bytes32 id = _sendDefault();
        vm.warp(vault.transit(id).fillDeadline + 1);
        ReportCodec.Report memory r = _spokeReport(0, 0);
        r.arrivedTransits = new ReportCodec.TransitAmount[](ReportCodec.ARRIVAL_WINDOW);
        for (uint256 i; i < r.arrivedTransits.length; ++i) {
            r.arrivedTransits[i] = ReportCodec.TransitAmount(keccak256(abi.encode("spam", i)), 1e6);
        }
        _deliver(r);
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
    }

    function test_DEC066_attestExpiryByReportLifetime() public {
        bytes32 id = _sendDefault();
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
    }

    function test_DEC066_attestExpiryRefusedWhenReportListsArrival() public {
        bytes32 id = _sendDefault();
        vm.warp(vault.transit(id).fillDeadline + 1);
        ReportCodec.Report memory r = _arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES);
        receiver.store(0, r); // stored without notification: the core has not confirmed yet
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, id));
        vault.attestExpiry(id);
    }

    function test_DEC066_refundRecognizedPullsEscrowToIdle() public {
        bytes32 id = _sendDefault();
        Transit memory t = vault.transit(id);
        // DEC-066, DEC-090: no refund on a transit whose expiry was never attested, before or after the deadline.
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InvalidTransitState.selector, id, 1));
        vault.recognizeRefund(id);
        vm.warp(t.fillDeadline + 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InvalidTransitState.selector, id, 1));
        vault.recognizeRefund(id);
        _deliver(_spokeReport(0, 0)); // built after the deadline, does not list the id
        vault.attestExpiry(id);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);
        pool.refund(0);
        uint256 idleBefore = vault.idle();
        vm.expectEmit(address(vault));
        emit ICoreVault.TransitRefundRecognized(id, 0, SENT);
        assertEq(vault.recognizeRefund(id), SENT);
        assertEq(vault.idle(), idleBefore + SENT);
        assertEq(vault.inFlightValue(), 0);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.RefundRecognized));
        (, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(inFlightSent, 0);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
        // RefundRecognized is terminal for refunds.
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.InvalidTransitState.selector, id, 4));
        vault.recognizeRefund(id);
    }

    function test_DEC066_refundAfterAttestedExpiry() public {
        bytes32 id = _sendDefault();
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        pool.refund(0);
        vault.recognizeRefund(id);
        assertEq(vault.inFlightValue(), 0);
        assertEq(vault.idle(), SEED_IDLE + 9975e6);
    }

    function test_DEC063_dustInEscrowIsNoRefundAndMovesNothing() public {
        bytes32 id = _sendDefault();
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        uint256 assets = vault.shareAssets();
        usdc.mint(vault.transit(id).escrow, SENT - 1); // anything short of the full input amount is not a refund
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
        assertEq(vault.shareAssets(), assets);
        assertEq(vault.inFlightValue(), ARRIVES);
    }

    function test_QA6_donationToEscrowNeverStrandsTheRealRefund() public {
        bytes32 id = _sendDefault();
        address escrow = vault.transit(id).escrow;
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        usdc.mint(escrow, 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);
        pool.refund(0);
        // DEC-063: exactly the amount sent enters Idle; DEC-080: the donated surplus is excess, never a base.
        assertEq(vault.recognizeRefund(id), SENT);
        assertEq(vault.idle(), SEED_IDLE + 9975e6);
        assertEq(usdc.balanceOf(escrow), 0);
        assertEq(vault.sweepExcess(address(usdc)), 1);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_DEC066_arrivalAfterFullDonationRefundStillConfirms() public {
        bytes32 id = _sendDefault();
        // The transit WAS filled, but no report arrived within the lifetime, so the expiry is attestable.
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        usdc.mint(vault.transit(id).escrow, SENT); // a donation of the full amount, not an Across refund
        vault.recognizeRefund(id);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        (uint256 spokeValue,,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, ARRIVES, "the arrival is not treated as unknown");
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6 + ARRIVES, "the donor's amount stays with the fund");
    }

    function test_DEC090_onlyReceiverAppliesReports() public {
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotReportReceiver.selector, address(this)));
        vault.onReportAccepted(0);
    }

    function test_DEC090_reportOfAnotherFundRefused() public {
        ReportCodec.Report memory r = _spokeReport(0, 0);
        r.fundId = keccak256("other fund");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.WrongFund.selector, r.fundId));
        receiver.deliver(0, r);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Spoke-to-hub arrivals (DEC-080, OQ-01)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC090_arrivalOnlyFromAcrossSpokePool() public {
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotAcrossSpokePool.selector, address(this)));
        vault.handleV3AcrossMessage(address(usdc), 1, address(0), _homeMessage(bytes32(0), TransferKind.Principal));
    }

    function test_DEC090_arrivalOnlyInUsdc() public {
        bytes memory message = _homeMessage(bytes32(0), TransferKind.Principal);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnexpectedToken.selector, address(usdg)));
        pool.fill(address(vault), address(usdg), 1e6, message);
    }

    function test_DEC090_arrivalOfAnotherFundRefused() public {
        bytes32 other = keccak256("other fund");
        bytes memory message = TransitMessage.encode(other, SPOKE, bytes32(0), TransferKind.Principal);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.WrongFund.selector, other));
        pool.fill(address(vault), address(usdc), 1e6, message);
    }

    function test_OQ01_arrivalHeldApartUntilReportListsIt() public {
        bytes32 homeId = keccak256("home-1");
        uint256 assets = vault.shareAssets();
        vm.expectEmit(address(vault));
        emit ICoreVault.TransitReceived(homeId, SPOKE, TransferKind.Principal, 500e6, false);
        pool.fill(address(vault), address(usdc), 500e6, _homeMessage(homeId, TransferKind.Principal));
        assertEq(vault.unmatchedArrivals(), 500e6);
        assertEq(vault.shareAssets(), assets, "outside every base until matched");
        // The report that lists it (and no longer counts it in the spoke's balances) credits Idle.
        _deliver(_inFlightToHub(_spokeReport(0, 0), homeId, 500e6));
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.idle(), SEED_IDLE + 9975e6 + 500e6);
        assertEq(vault.inFlightValue(), 0, "credited, so no longer in flight");
    }

    function test_DEC085_listedReturnLegCountsInFlightUntilArrival() public {
        bytes32 homeId = keccak256("home-1");
        _deliver(_inFlightToHub(_spokeReport(0, 0), homeId, 500e6));
        assertEq(vault.inFlightValue(), 500e6);
        uint256 assets = vault.shareAssets();
        vm.expectEmit(address(vault));
        emit ICoreVault.TransitReceived(homeId, SPOKE, TransferKind.Principal, 500e6, true);
        pool.fill(address(vault), address(usdc), 500e6, _homeMessage(homeId, TransferKind.Principal));
        assertEq(vault.inFlightValue(), 0);
        assertEq(vault.shareAssets(), assets, "DEC-104: in flight to Idle, same value");
    }

    /// @dev DEC-161: an Income arrival is held for the collection result it carries (converted when the Hub reads
    ///      it), never Idle.
    function test_DEC161_incomeArrivalIsHeldForItsCollection() public {
        bytes32 homeId = keccak256("income-1");
        _deliver(_inFlightToHub(_spokeReport(0, 0), homeId, 100e6, TransferKind.Income));
        uint256 protocol0 = usdc.balanceOf(protocol);
        pool.fill(address(vault), address(usdc), 100e6, _homeMessage(homeId, TransferKind.Income));
        assertEq(_heldIncome(), 100e6);
        assertEq(vault.idle(), SEED_IDLE + 9975e6);
        assertEq(usdc.balanceOf(protocol), protocol0, "no fee before the conversion");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_OQ01_heldApartAndIncomeStateReadableThroughICoreVault() public {
        pool.fill(address(vault), address(usdc), 7e6, _homeMessage(keccak256("stray"), TransferKind.Principal));
        ICoreVault core = ICoreVault(address(vault));
        assertEq(core.unmatchedArrivals(), 7e6);
        _hubIncomeCollected(address(usdc), 100e6);
        assertEq(core.incomeCollection().heldDollars, 80e6);
    }

    function test_OQ01_fabricatedIdNeverReachesABase() public {
        uint256 price = vault.sharePrice();
        pool.fill(address(vault), address(usdc), 777e6, _homeMessage(keccak256("fabricated"), TransferKind.Principal));
        _deliver(_spokeReport(0, 0));
        assertEq(vault.unmatchedArrivals(), 777e6);
        assertEq(vault.sharePrice(), price);
        assertEq(vault.sweepExcess(address(usdc)), 0, "held apart, not sweepable");
    }

    function test_OQ01_arrivalAboveListedAmountHeldApart() public {
        bytes32 homeId = keccak256("home-1");
        // A stranger front-runs the real 500 with 1 under the same id.
        pool.fill(address(vault), address(usdc), 1, _homeMessage(homeId, TransferKind.Principal));
        pool.fill(address(vault), address(usdc), 500e6, _homeMessage(homeId, TransferKind.Principal));
        _deliver(_inFlightToHub(_spokeReport(0, 0), homeId, 500e6));
        assertEq(vault.idle(), SEED_IDLE + 9975e6 + 500e6);
        assertEq(vault.unmatchedArrivals(), 1);
        // A late repeat of the id is held apart too.
        pool.fill(address(vault), address(usdc), 10e6, _homeMessage(homeId, TransferKind.Principal));
        assertEq(vault.idle(), SEED_IDLE + 9975e6 + 500e6);
        assertEq(vault.unmatchedArrivals(), 10e6 + 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Garbage collector (DEC-080, DEC-096, DEC-101)
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC101_sweepExcessSendsOnlyUnledgeredBalance() public {
        usdc.mint(address(vault), 123e6);
        weth.mint(address(vault), 2e18);
        _hubIncomeCollected(address(usdc), 50e6);
        vm.expectEmit(address(vault));
        emit ICoreVault.ExcessSwept(address(usdc), excess, 123e6);
        assertEq(vault.sweepExcess(address(usdc)), 123e6);
        assertEq(vault.sweepExcess(address(weth)), 2e18);
        assertEq(usdc.balanceOf(excess), 123e6);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
        assertEq(vault.sweepExcess(address(usdc)), 0);
    }

    /// @dev Security review S-20 (DEC-080): the hub's Across callback credits nothing the SpokePool did not transfer
    ///      first; an unbacked call reverts `UnbackedCredit` and moves no base.
    function test_SEC_S20_hubAcrossCallbackRequiresTheTokensAboveTheLedger() public {
        bytes32 homeId = keccak256("home-unbacked");
        bytes memory message = TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Principal);
        uint256 idleBefore = vault.idle();
        vm.prank(address(pool));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnbackedCredit.selector, address(usdc), 500e6, 0));
        vault.handleV3AcrossMessage(address(usdc), 500e6, address(this), message);
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.idle(), idleBefore);

        // The same arrival, transferred first as the SpokePool does, is held apart as before.
        pool.fill(address(vault), address(usdc), 500e6, message);
        assertEq(vault.unmatchedArrivals(), 500e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // The bridge adapter learns proven expiries (DEC-162, DEC-056)
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-162: a report's proof of non-arrival tells the bridge adapter at the attestation, once; the refund that
    /// follows does not tell it again.
    function test_DEC162_reportProvenExpiryIsNotedOnceAtTheAttestation() public {
        bytes32 id = _sendDefault();
        bytes32 ref = vault.transit(id).bridgeRef;
        vm.warp(vault.transit(id).fillDeadline + 1);
        _deliver(_spokeReport(0, 0)); // built after the deadline, does not list the id
        vault.attestExpiry(id);
        assertEq(bridge.expiryNotes(ref), 1, "noted at the attestation");
        pool.refund(0);
        vault.recognizeRefund(id);
        assertEq(bridge.expiryNotes(ref), 1, "not noted twice");
    }

    /// DEC-162 with security review S-13: the time path proves nothing about the arrival, so the adapter is told only
    /// when the refund is recognized. Otherwise anyone could attest a filled send of a quiet fund (DEC-157) and step
    /// the next send's fee up.
    function test_DEC162_timePathExpiryIsNotedOnlyAtTheRefund() public {
        bytes32 id = _sendDefault();
        bytes32 ref = vault.transit(id).bridgeRef;
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        assertEq(bridge.expiryNotes(ref), 0, "the time path is no proof");
        pool.refund(0);
        vault.recognizeRefund(id);
        assertEq(bridge.expiryNotes(ref), 1, "the refund is");
    }

    /// DEC-162 (review round 1, L-3a): the spoke never lists an arrival below its listing minimum (1 USDG, CS-OQ-6), so
    /// a report's silence proves nothing for such a send. A filled send of 0.85 USDG attested by a later report does not
    /// step the adapter's fee; a real expiry of that size is noted when its refund is recognized.
    function test_DEC162_sendBelowTheListingMinimumIsNotedOnlyAtTheRefund() public {
        bytes32 filled = _send(0.9e6, 0.85e6);
        bytes32 expired = _send(0.9e6, 0.85e6);
        vm.warp(vault.transit(filled).fillDeadline + 1);
        _deliver(_spokeReport(0.85e6, 0.85e6)); // `filled` arrived, credited but unlisted; `expired` never did
        vault.attestExpiry(filled);
        vault.attestExpiry(expired);
        assertEq(bridge.expiryNotes(vault.transit(filled).bridgeRef), 0, "silence proves nothing below the minimum");
        assertEq(bridge.expiryNotes(vault.transit(expired).bridgeRef), 0);

        pool.refund(1);
        vault.recognizeRefund(expired);
        assertEq(bridge.expiryNotes(vault.transit(expired).bridgeRef), 1, "the refund proves the expiry");
        assertEq(bridge.expiryNotes(vault.transit(filled).bridgeRef), 0, "the filled send never steps the fee");
    }

    /// DEC-162: an arrival is never reported to the adapter as an expiry, even after a time-path attestation.
    function test_DEC162_arrivalAfterATimeAttestationIsNeverNoted() public {
        bytes32 id = _sendDefault();
        bytes32 ref = vault.transit(id).bridgeRef;
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertEq(bridge.expiryNotes(ref), 0);
    }

    /// DEC-056: an adapter that refuses `noteExpiry` never blocks an outcome; the vault reports the failure.
    function test_DEC056_failingNoteExpiryNeverBlocksTheOutcome() public {
        bytes32 id = _sendDefault();
        bridge.setNoteExpiryReverts(true);
        vm.warp(vault.transit(id).fillDeadline + 1);
        _deliver(_spokeReport(0, 0));
        vm.expectEmit(address(vault));
        emit ICoreVault.BridgeExpiryNoteFailed(id, address(bridge));
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));

        bytes32 second = _send(SENT, ARRIVES);
        vm.warp(uint256(vault.transit(second).fillDeadline) + MAX_REPORT_AGE + 1);
        vault.attestExpiry(second);
        pool.refund(1);
        vm.expectEmit(address(vault));
        emit ICoreVault.BridgeExpiryNoteFailed(second, address(bridge));
        assertEq(vault.recognizeRefund(second), SENT);
        assertEq(uint8(vault.transit(second).state), uint8(TransitState.RefundRecognized));
    }

    /// DEC-162, DEC-056: a caller cannot starve `noteExpiry` so that the fee rule silently misses an expiry: at any gas
    /// limit, the attestation either reverts or the adapter has the note.
    function test_DEC162_starvedAttestationNeverSkipsTheNote() public {
        bytes32 id = _sendDefault();
        bytes32 ref = vault.transit(id).bridgeRef;
        vm.warp(vault.transit(id).fillDeadline + 1);
        _deliver(_spokeReport(0, 0)); // a report built after the deadline proves non-arrival
        uint256 succeeded;
        for (uint256 g = 40_000; g <= 400_000; g += 4000) {
            uint256 snapshot = vm.snapshotState();
            (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(ICoreVault.attestExpiry, (id)));
            if (ok) {
                ++succeeded;
                assertEq(bridge.expiryNotes(ref), 1, "every successful attestation reached the adapter");
            }
            vm.revertToState(snapshot);
        }
        assertGt(succeeded, 0, "enough gas attests");
    }
}
