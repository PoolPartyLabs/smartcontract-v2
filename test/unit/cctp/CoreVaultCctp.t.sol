pragma solidity 0.8.28;

import {CoreVaultFixture} from "../core/CoreVaultFixture.sol";
import {CoreVaultCctp} from "../../../src/core/CoreVaultCctp.sol";
import {CoreVaultCctpLogic} from "../../../src/core/CoreVaultCctpLogic.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ShareToken} from "../../../src/core/ShareToken.sol";
import {CctpBridgeAdapter} from "../../../src/adapters/CctpBridgeAdapter.sol";
import {CctpReceiveConnector} from "../../../src/core/CctpReceiveConnector.sol";
import {CctpRoute} from "../../../src/interfaces/ICctpCoreVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {Mandate, SpokeConfig, BridgeAdapterConfig} from "../../../src/mandate/Mandate.sol";
import {MandateFixture} from "../../utils/MandateFixture.sol";
import {MockCctpV2, CctpTestMessage} from "../../mocks/cctp/CctpHarness.sol";

contract CoreVaultCctpTest is CoreVaultFixture {
    using MandateFixture for Mandate;
    CoreVaultCctp internal cctpCore;
    CctpBridgeAdapter internal adapter;
    CctpReceiveConnector internal connector;
    MockCctpV2 internal circle;
    CctpRoute internal route;
    uint256 internal constant AMOUNT = 1000e6;
    uint256 internal constant MAX_FEE = 140_000;
    uint256 internal constant FEE = 100_000;
    bytes32 internal constant ID = keccak256("return-transit");
    bytes32 internal constant NONCE = keccak256("circle-nonce");
    uint256 internal constant SOLANA = 777;
    uint256 internal constant SOLANA_INDEX = 1;

    function setUp() public override {
        super.setUp();
        route = CctpRoute(
            FUND_ID,
            SOLANA,
            bytes32(type(uint256).max - 1),
            bytes32(type(uint256).max - 2),
            keccak256("circle-solana-messenger"),
            keccak256("solana-usdc-mint"),
            keccak256("fund-custody-pda")
        );
        circle = new MockCctpV2(address(usdc));
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        adapter = new CctpBridgeAdapter(address(this), predicted, address(circle), address(usdc), route, 20_000);
        connector = new CctpReceiveConnector(predicted, address(usdc), address(circle), address(circle), route);
        Mandate memory mandate = _mandate(1000);
        prices.setPrice(address(usdc), 1e18);
        mandate.addToken(SOLANA, address(usdc));
        mandate.addSwapAdapter(SOLANA, makeAddr("solanaSwapPlaceholder"));
        SpokeConfig memory robinhood = mandate.spokes[0];
        mandate.spokes = new SpokeConfig[](2);
        mandate.spokes[0] = robinhood;
        mandate.spokes[1] = SpokeConfig(SOLANA, 1, route.remoteVaultAuthority, address(usdc), SPOKE_CAP, MAX_REPORT_AGE);
        BridgeAdapterConfig memory hubAcross = mandate.bridgeAdapters[0];
        BridgeAdapterConfig memory spokeAcross = mandate.bridgeAdapters[1];
        mandate.bridgeAdapters = new BridgeAdapterConfig[](4);
        mandate.bridgeAdapters[0] = hubAcross;
        mandate.bridgeAdapters[1] = spokeAcross;
        mandate.bridgeAdapters[2] = BridgeAdapterConfig(SOLANA, HUB, address(adapter));
        mandate.bridgeAdapters[3] = BridgeAdapterConfig(SOLANA, SOLANA, makeAddr("solanaBridgePlaceholder"));
        cctpCore = new CoreVaultCctp(mandate, _config(0), route, SOLANA_INDEX, adapter, connector);
        assertEq(address(cctpCore), predicted);
        vault = CoreVault(address(cctpCore));
        shares = ShareToken(vault.shareToken());
        hubVault.setCoreVault(address(vault));
        receiver.setCoreVault(address(vault));
        bridge.setVault(address(vault));
        _seedFund(address(vault), address(usdc), 0);
        _deposit(alice, 10_000e6);
        _ensureSpokeReport();
        receiver.setMaxReportAge(SOLANA_INDEX, MAX_REPORT_AGE);
        _deliverSolana(_solanaReport());
    }

    function _message() internal view returns (bytes memory) {
        return CctpTestMessage.encode(
            route,
            address(vault),
            address(connector),
            address(circle),
            ID,
            NONCE,
            TransferKind.Principal,
            AMOUNT,
            MAX_FEE,
            FEE
        );
    }

    function _list(TransferKind kind) internal {
        ReportCodec.Report memory report = _solanaReport();
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        report.inFlightToHub[0] = ReportCodec.HubBoundAmount(ID, AMOUNT - MAX_FEE, kind);
        _deliverSolana(report);
    }

    function _solanaReport() internal returns (ReportCodec.Report memory report) {
        report = _spokeReport(0, 0);
        report.spokeChainId = SOLANA;
        report.unallocated[0] = ReportCodec.TokenAmount(address(usdc), 0);
    }

    function _deliverSolana(ReportCodec.Report memory report) internal {
        receiver.deliver(SOLANA_INDEX, report);
    }

    function _sendCctp() internal returns (bytes32 id) {
        vm.prank(manager);
        id = cctpCore.sendToSolana(AMOUNT, abi.encode(uint256(14_000)));
    }

    function test_DEC191_sendBooksMinimumWithoutEscrowDeadlineOrApproval() public {
        uint256 assets = vault.shareAssets();
        bytes32 id = _sendCctp();
        Transit memory transit = vault.transit(id);
        assertEq(transit.amountSent, AMOUNT);
        assertEq(transit.amountToArrive, AMOUNT - MAX_FEE);
        assertEq(transit.fillDeadline, 0);
        assertEq(transit.escrow, address(0));
        assertEq(transit.bridgeRef, id);
        assertEq(usdc.allowance(address(vault), address(circle)), 0);
        assertEq(circle.lastMaxFee(), MAX_FEE);
        assertEq(circle.lastRecipient(), route.mintRecipient);
        assertEq(circle.lastCaller(), route.destinationCaller);
        assertEq(vault.shareAssets(), assets - MAX_FEE);
        (, uint256 sent,,) = vault.spokeCapUsage(SOLANA_INDEX);
        assertEq(sent, AMOUNT);
    }

    function test_DEC191_pendingNeverExpiresOrRefundsAfterYears() public {
        bytes32 id = _sendCctp();
        vm.warp(block.timestamp + 10 * 365 days);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExpiryNotProvable.selector, id));
        vault.attestExpiry(id);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NoRefund.selector, id));
        vault.recognizeRefund(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.Sent));
        (, uint256 sent,,) = vault.spokeCapUsage(SOLANA_INDEX);
        assertEq(sent, AMOUNT);
        assertEq(vault.inFlightValue(), AMOUNT - MAX_FEE);
    }

    function test_DEC191_reportFirstCreditsActualMintIncludingUnusedFee() public {
        _list(TransferKind.Principal);
        uint256 idleBefore = vault.idle();
        uint256 assetsBefore = vault.shareAssets();
        vm.prank(makeAddr("manual-API-caller"));
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertEq(vault.idle(), idleBefore + AMOUNT - FEE);
        assertEq(vault.unmatchedArrivals(), 0);
        assertEq(vault.shareAssets(), assetsBefore + MAX_FEE - FEE);
        _list(TransferKind.Principal);
        assertEq(vault.idle(), idleBefore + AMOUNT - FEE);
    }

    function test_DEC191_receiptFirstHoldsEverythingUntilFinalizedListing() public {
        uint256 beforeIdle = vault.idle();
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertEq(vault.idle(), beforeIdle);
        assertEq(vault.unmatchedArrivals(), AMOUNT - FEE);
        vm.warp(block.timestamp + 30 days);
        _deliverSolana(_solanaReport());
        vm.expectRevert(CoreVaultCctp.CctpRecoveryRequiresReport.selector);
        vault.recoverUnlistedArrival(SOLANA_INDEX, ID);
        _list(TransferKind.Principal);
        assertEq(vault.idle(), beforeIdle + AMOUNT - FEE);
        assertEq(vault.unmatchedArrivals(), 0);
    }

    function test_DEC191_lateArrivalRemainsCreditable() public {
        _list(TransferKind.Principal);
        vm.warp(block.timestamp + 3 * 365 days);
        uint256 beforeIdle = vault.idle();
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertEq(vault.idle(), beforeIdle + AMOUNT - FEE);
    }

    function test_DEC191_replayAndAlternateNonceCannotDoubleCredit() public {
        _list(TransferKind.Principal);
        bytes memory message = _message();
        connector.receiveCctpAndCredit(message, hex"1234");
        uint256 beforeIdle = vault.idle();
        vm.expectRevert(abi.encodeWithSelector(CctpReceiveConnector.AlreadyReceived.selector, ID));
        connector.receiveCctpAndCredit(message, hex"1234");
        bytes memory alternative = CctpTestMessage.encode(
            route,
            address(vault),
            address(connector),
            address(circle),
            ID,
            keccak256("other-nonce"),
            TransferKind.Principal,
            AMOUNT,
            MAX_FEE,
            FEE
        );
        vm.expectRevert(abi.encodeWithSelector(CctpReceiveConnector.AlreadyReceived.selector, ID));
        connector.receiveCctpAndCredit(alternative, hex"1234");
        assertEq(vault.idle(), beforeIdle);
    }

    function test_DEC191_mintMismatchRollsBackNonceAndBusinessReceipt() public {
        circle.configure(1, false, false);
        uint256 balance = usdc.balanceOf(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(CctpReceiveConnector.MintMismatch.selector, AMOUNT - FEE, AMOUNT - FEE - 1)
        );
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertFalse(circle.used(NONCE));
        assertFalse(connector.received(ID));
        assertEq(usdc.balanceOf(address(vault)), balance);
    }

    function test_DEC191_failedReportMatchRollsBackEntireReceiveThenRetries() public {
        ReportCodec.Report memory report = _solanaReport();
        report.inFlightToHub = new ReportCodec.HubBoundAmount[](1);
        report.inFlightToHub[0] = ReportCodec.HubBoundAmount(ID, AMOUNT - MAX_FEE - 1, TransferKind.Principal);
        _deliverSolana(report);
        uint256 balance = usdc.balanceOf(address(vault));
        vm.expectRevert(abi.encodeWithSelector(CoreVaultCctpLogic.ReceiptReportMismatch.selector, ID));
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertEq(usdc.balanceOf(address(vault)), balance);
        assertFalse(circle.used(NONCE));
        assertFalse(connector.received(ID));
    }

    function test_DEC191_incomeFeeSurplusIsPrincipalNotIncome() public {
        _list(TransferKind.Income);
        uint256 idleBefore = vault.idle();
        bytes memory message = CctpTestMessage.encode(
            route,
            address(vault),
            address(connector),
            address(circle),
            ID,
            NONCE,
            TransferKind.Income,
            AMOUNT,
            MAX_FEE,
            FEE
        );
        connector.receiveCctpAndCredit(message, hex"1234");
        assertEq(vault.idle(), idleBefore + MAX_FEE - FEE);
        assertEq(vault.unmatchedArrivals(), 0);
    }

    function test_DEC191_falseReceiveAndInvalidAttestationAreAtomic() public {
        circle.configure(0, true, false);
        vm.expectRevert(bytes("invalid attestation"));
        connector.receiveCctpAndCredit(_message(), hex"1234");
        circle.configure(0, false, true);
        vm.expectRevert(CctpReceiveConnector.ReceiveFailed.selector);
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertFalse(circle.used(NONCE));
        assertFalse(connector.received(ID));
    }

    function test_DEC191_rejectWrongRouteBeforeMint() public {
        route.remoteVaultAuthority = keccak256("attacker-authority");
        vm.expectRevert(CctpReceiveConnector.InvalidRoute.selector);
        connector.receiveCctpAndCredit(_message(), hex"1234");
        assertFalse(circle.used(NONCE));
    }

    function test_DEC188_existingAcrossSendStillHasEscrowAndExpiry() public {
        bytes32 id = _send(AMOUNT, AMOUNT - 600_000);
        Transit memory transit = vault.transit(id);
        assertEq(transit.fillDeadline, block.timestamp + 21_600);
        assertTrue(transit.escrow != address(0));
        vm.warp(block.timestamp + 21_600 + MAX_REPORT_AGE + 1);
        vault.attestExpiry(id);
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ExpiryAttested));
    }

    function test_DEC191_coreEntryRejectsUntrustedCaller() public {
        vm.expectRevert(CoreVaultCctp.NotCctpConnector.selector);
        cctpCore.creditCctp(SOLANA, ID, TransferKind.Principal, AMOUNT, MAX_FEE, FEE);
    }

    function testFuzz_DEC191_principalTrueUpForEitherArrivalOrder(uint256 executedFee, bool receiptFirst) public {
        executedFee = bound(executedFee, 0, MAX_FEE);
        uint256 idleBefore = vault.idle();
        bytes memory message = CctpTestMessage.encode(
            route,
            address(vault),
            address(connector),
            address(circle),
            ID,
            NONCE,
            TransferKind.Principal,
            AMOUNT,
            MAX_FEE,
            executedFee
        );
        if (!receiptFirst) _list(TransferKind.Principal);
        connector.receiveCctpAndCredit(message, hex"1234");
        if (receiptFirst) _list(TransferKind.Principal);
        assertEq(vault.idle(), idleBefore + AMOUNT - executedFee);
        assertEq(vault.unmatchedArrivals(), 0);
        _list(TransferKind.Principal);
        assertEq(vault.idle(), idleBefore + AMOUNT - executedFee);
    }

    function test_DEC188_newCoreFitsRuntimeLimit() public view {
        assertLe(address(cctpCore).code.length, 24_576);
    }
}
