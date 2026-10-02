// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {Mandate, AdapterConfig, PoolConfig, BridgeAdapterConfig} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockPositionAdapter} from "../../mocks/spoke/MockPositionAdapter.sol";
import {MockBridgeAdapter as SpokeMockBridgeAdapter} from "../../mocks/spoke/MockBridgeAdapter.sol";
import {MockAcrossSpokePool as SpokeMockAcrossSpokePool} from "../../mocks/spoke/MockAcrossSpokePool.sol";
import {MockWormholeCore} from "../../mocks/spoke/MockWormholeCore.sol";
import {MockBridgeNextArrive} from "../../mocks/across/MockBridgeNextArrive.sol";

/// @title Regression (security review S-3): an expired send home no longer leaves Share Assets for a window a
///        depositor can buy into
/// @notice Was PoC `test_POC_expiredReturnLegLeavesShareAssetsForAWindowAnyDepositorCaptures` (high, raised by the
///         liveness verifier): the spoke dropped an unfilled hub-bound transit at `fillDeadline + maxReportAge`, so
///         between that report and the report after `recognizeRefund` Share Assets were understated by the transfer;
///         bob deposited 1,000,000 in the window and exited with 1,219,622 USDC (975,056 in the honest run).
///
/// FIX (S-3): the send stays in `inFlightToHub` until its refund is recognized or `ReportCodec.HUB_BOUND_RETENTION`
/// after its deadline. The test replays the sequence and asserts it now FAILS: the report past the lifetime still
/// lists the transfer, Share Assets do not move, and bob's exit equals the honest run.
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

    function test_SEC_S3_expiredReturnLegStaysInShareAssetsAndADepositorGainsNothing() public {
        _deposit(alice, 1_000_000e6); // 997,500 Idle after the flow fee
        uint256 aliceShares = shares.balanceOf(alice);

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

        // The spoke's mock bridge adapter fixes the amount to arrive (DEC-162); the manager passes no bridge parameter.
        MockBridgeNextArrive.set(address(spokeAcrossAdapter), 399_800e6);
        vm.prank(manager);
        bytes32 homebound = spoke.sendToHub(400_000e6, TransferKind.Principal, 0);
        Transit memory t = spoke.hubBoundTransit(homebound);
        _deliverSpokeReport();
        uint256 listedAssets = vault.shareAssets();
        assertEq(listedAssets, SEED_IDLE + 497_500e6 + 99_750e6 + 399_800e6);

        // Nobody fills it. Past fillDeadline + maxReportAge the spoke still lists it (S-3).
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        ReportCodec.Report memory stillListed = _deliverSpokeReport();
        assertEq(stillListed.inFlightToHub.length, 1, "S-3: not presumed filled");
        assertEq(vault.shareAssets(), listedAssets, "S-3: Share Assets did not fall");
        _repostPrices();

        // Counterfactual: bob deposits the same amount after the refund report instead.
        uint256 snapshot = vm.snapshotState();
        _closeTheGap(homebound);
        _deposit(bob, 1_000_000e6);
        uint256 honestPaid = _request(bob, 2_000_000e6, ICoreVaultPayouts.PayoutMode.Instant).usdcPaid;
        uint256 aliceValueHonest = _valueOf(aliceShares);
        vm.revertToState(snapshot);

        // Bob deposits inside what used to be the window.
        _deposit(bob, 1_000_000e6);
        _closeTheGap(homebound);
        ICoreVault.PayoutReceipt memory r = _request(bob, 2_000_000e6, ICoreVaultPayouts.PayoutMode.Instant);
        assertLt(r.usdcPaid, 1_000_000e6, "S-3: bob leaves with less than he deposited");
        // The only difference left is the 200 USDC bridge fee the refund returns on top of the 399,800 counted in
        // flight (DEC-085 counts the amount that will arrive; Across refunds the full input, DEC-063), shared pro rata.
        assertApproxEqAbs(r.usdcPaid, honestPaid, 200e6, "S-3: the honest run, within the refunded bridge fee");
        assertApproxEqAbs(_valueOf(aliceShares), aliceValueHonest, 200e6, "S-3: alice keeps her value");
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
