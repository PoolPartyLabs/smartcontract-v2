// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {Transit, TransitState, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {Mandate, AdapterConfig, PoolConfig, BridgeAdapterConfig} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockBridgeAdapter as SpokeBridgeMock} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockBridgeNextArrive} from "../../mocks/across/MockBridgeNextArrive.sol";
import {MockAcrossSpokePool as SpokeAcrossMock} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Review port of core-a H02, consolidated finding H-01 (register S-3). On `e5c778a` a Principal transfer home
///         that was not filled left every value base between `fillDeadline + maxReportAge` (the spoke stopped listing
///         it) and its reported refund: Share Assets fell from 199,380 to 99,500 and a depositor in that window gained
///         49,783 USDC on 100,000. Since S-3 a send home stays listed until its refund is recognized or
///         `HUB_BOUND_RETENTION` (3 days) after its deadline, and `report()` recognizes a refund that has landed.
/// @dev Adaptations to main, interface only: the Core Vault is deployed from the same Mandate as the real Spoke Vault
///      (S-6 rejects a report whose `mandateHash` differs; the original fixture gave the spoke other adapter addresses),
///      the spoke's first report is delivered before the first send (S-14), and the send home names no exclusive
///      relayer (S-9). A manager can still force the no-fill without exclusivity: a quote with no relayer fee
///      (`outputAmount == amount`) is accepted and no rational relayer fills it (variant below). Every report the hub
///      receives is the payload the real Spoke Vault publishes through `report()`; only Wormhole, the receiver and
///      Across are mocks.
contract H02_ReturnLegDroppedBeforeRefund is CoreVaultFixture {
    SpokeVault internal spoke;
    MockPositionAdapter internal spokeUniReal;
    SpokeBridgeMock internal spokeBridgeReal;
    SpokeAcrossMock internal spokeAcross;
    MockWormholeCore internal wormhole;
    address internal guardian = makeAddr("guardian");
    address internal mallory = makeAddr("mallory");

    uint256 internal constant SENT_OUT = 100_000e6;
    uint256 internal constant ARRIVED = 99_940e6;

    function setUp() public override {
        super.setUp();
        vm.chainId(SPOKE);
        spokeUniReal = new MockPositionAdapter(guardian, false);
        spokeUniReal.addPool(SPOKE_POOL, address(spokeWeth), address(usdg));
        spokeAcross = new SpokeAcrossMock();
        spokeBridgeReal = new SpokeBridgeMock(guardian, address(spokeAcross));
        wormhole = new MockWormholeCore();

        Mandate memory m = _mandate(2000);
        m.adapters[1] = AdapterConfig(SPOKE, address(spokeUniReal));
        m.pools[1] = PoolConfig(SPOKE, address(spokeUniReal), SPOKE_POOL);
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeBridgeReal));
        vm.chainId(HUB);
        _deploy(m, _config(25)); // S-6: hub and spoke run the same Mandate
        vm.chainId(SPOKE);
        spoke = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            address(vault),
            address(usdg),
            address(spokeAcross),
            address(wormhole),
            address(escrowImpl),
            excess
        );
        spokeUniReal.setVault(address(spoke));
        spokeBridgeReal.setVault(address(spoke));
        vm.chainId(HUB);
        assertEq(spoke.mandateHash(), vault.mandateHash());
    }

    /// @dev Anyone: `report()` on the spoke, then the published payload delivered to the hub.
    function _publishAndDeliver() internal returns (ReportCodec.Report memory r) {
        spoke.report();
        r = ReportCodec.decode(wormhole.published(wormhole.publishedCount() - 1).payload);
        _deliver(r);
    }

    function _refreshPrices() internal {
        prices.setPrice(address(usdg), 1e18);
        prices.setPrice(address(weth), 2.5e9);
        prices.setPrice(address(spokeWeth), 2.5e9);
    }

    /// @dev Alice 200,000; 100,000 USDC sent out, 99,940 USDG arrive and are confirmed; the manager sends it all home
    ///      with `homeOutput` to arrive, and nobody fills it.
    function _sendHomeUnfilled(uint256 homeOutput) internal returns (bytes32 home, uint256 assetsBefore) {
        _deposit(alice, 200_000e6);
        _publishAndDeliver(); // S-14: the spoke's first report before the first send
        bytes32 out = _send(SENT_OUT, ARRIVED);
        usdg.mint(address(spokeAcross), ARRIVED);
        spokeAcross.fill(
            address(spoke), address(usdg), ARRIVED, TransitMessage.encode(FUND_ID, HUB, out, TransferKind.Principal)
        );
        _publishAndDeliver();
        assetsBefore = vault.shareAssets();
        assertEq(assetsBefore, 199_440e6);

        // DEC-162: the spoke's (mock) bridge adapter fixes the amount to arrive; the quote argument is ignored.
        MockBridgeNextArrive.set(address(spokeBridgeReal), homeOutput);
        BridgeQuote memory none;
        vm.prank(manager);
        home = spoke.sendToHub(ARRIVED, TransferKind.Principal, 0, none);
        _publishAndDeliver();
        assertEq(vault.shareAssets(), assetsBefore - (ARRIVED - homeOutput), "in flight home: counted");
    }

    /// @dev The review's window (`fillDeadline + maxReportAge + 1`, refund not landed): Share Assets hold, an entrant
    ///      is priced fairly, and the refund, recognized by the next `report()` without anyone calling
    ///      `recognizeRefund`, returns the bridge fee only.
    function test_REVIEW_H01_unfilledSendHomeStaysInShareAssetsUntilItsRefund() public {
        (bytes32 home, uint256 assetsBefore) = _sendHomeUnfilled(99_880e6);
        uint256 assetsInFlight = vault.shareAssets();
        assertEq(assetsInFlight, 199_380e6);

        Transit memory t = spoke.hubBoundTransit(home);
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        _refreshPrices();
        ReportCodec.Report memory r = _publishAndDeliver();
        assertEq(r.inFlightToHub.length, 1, "still listed after fillDeadline + maxReportAge");
        assertEq(r.inFlightToHub[0].amount, 99_880e6);
        assertEq(vault.shareAssets(), assetsInFlight, "Share Assets hold in the review's window");

        uint256 fairPrice = vault.sharePrice();
        (uint256 minted,) = _deposit(mallory, 100_000e6);

        vm.warp(block.timestamp + 45 minutes);
        _refreshPrices();
        spokeAcross.refund(t.escrow, address(usdg), ARRIVED);
        // Nobody calls recognizeRefund: the keeper's next report() recognizes the landed refund itself.
        r = _publishAndDeliver();
        assertEq(uint8(spoke.hubBoundTransit(home).state), uint8(TransitState.RefundRecognized));
        assertEq(r.inFlightToHub.length, 0);
        assertEq(spoke.unallocatedBalance(address(usdg)), ARRIVED, "back in Unallocated Balance");

        uint256 priceAfter = vault.sharePrice();
        uint256 malloryValue = minted * priceAfter / 1e36;
        uint256 aliceValue = shares.balanceOf(alice) * priceAfter / 1e36;
        console2.log("price before window / after refund", fairPrice, priceAfter);
        console2.log("mallory paid 100,000; worth now   ", malloryValue);
        console2.log("alice worth before / now          ", assetsBefore, aliceValue);
        // 199,380 + Mallory's 99,749.963909 charged + the 60 USDC bridge fee returned with the refund.
        assertEq(vault.shareAssets(), 299_189_963_909, "Share Assets: nothing lost, nothing gained");
        assertEq(malloryValue, 99_769_971_927, "the entrant is priced fairly (+20 USDC: her share of the fee back)");
        assertEq(aliceValue, 199_419_991_981, "the existing holder keeps her value (+40: her share of the fee back)");
    }

    /// @dev The manager forces the no-fill without exclusivity: a zero relayer fee is accepted. Same outcome.
    function test_REVIEW_H01_zeroFeeSendHomeThatNobodyFillsStaysCounted() public {
        (bytes32 home, uint256 assetsBefore) = _sendHomeUnfilled(ARRIVED);
        Transit memory t = spoke.hubBoundTransit(home);
        assertEq(t.amountToArrive, t.amountSent, "no relayer fee in the quote");

        vm.warp(uint256(t.fillDeadline) + 1 hours);
        _refreshPrices();
        _publishAndDeliver();
        assertEq(vault.shareAssets(), assetsBefore, "counted at the amount sent until the refund");
        spokeAcross.refund(t.escrow, address(usdg), ARRIVED);
        _publishAndDeliver();
        assertEq(vault.shareAssets(), assetsBefore, "and after it");
    }

    /// @dev Residual (KNOWN-LIMITATIONS S-3): an Across refund that lands after `HUB_BOUND_RETENTION` reopens the
    ///      review's gap. The sweep that dropped the entry also took it off the list `report()` walks, so a landed
    ///      refund is no longer recognized by the next report: the gap lasts until someone calls `recognizeRefund`.
    ///      Not attacker-controlled (Across refunds within hours), but nothing bounds the second half of the gap.
    function test_POC_REVIEW_H01_refundAfterTheRetentionReopensTheGap() public {
        (bytes32 home, uint256 assetsBefore) = _sendHomeUnfilled(99_880e6);
        Transit memory t = spoke.hubBoundTransit(home);

        vm.warp(uint256(t.fillDeadline) + ReportCodec.HUB_BOUND_RETENTION + 1);
        _refreshPrices();
        ReportCodec.Report memory r = _publishAndDeliver();
        assertEq(r.inFlightToHub.length, 0, "dropped after the retention");
        uint256 assetsInGap = vault.shareAssets();
        console2.log("Share Assets before / in the gap", assetsBefore, assetsInGap);
        assertEq(assetsInGap, 99_500e6, "the transfer is in no value base");

        (uint256 minted,) = _deposit(mallory, 100_000e6);
        spokeAcross.refund(t.escrow, address(usdg), ARRIVED);
        _publishAndDeliver();
        assertEq(uint8(spoke.hubBoundTransit(home).state), uint8(TransitState.Sent), "report() no longer sees it");
        assertEq(vault.shareAssets(), 199_249_872_180, "the refund is still in no base");
        spoke.recognizeRefund(home);
        _publishAndDeliver();
        uint256 malloryValue = minted * vault.sharePrice() / 1e36;
        console2.log("mallory paid 100,000; worth now", malloryValue);
        assertEq(malloryValue, 149_782_537_780, "an entrant in the gap gains 49,782 USDC on 100,000");
    }
}
