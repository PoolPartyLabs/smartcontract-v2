// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {MockBridgeAdapter} from "../../mocks/core/MockBridgeAdapter.sol";
import {ReenteringAcrossPool} from "../../mocks/core/ReenteringAcrossPool.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Adversarial verification of the Core Vault (round 2): a late arrival after an attested expiry, the
///         Standard reserve under a fuzzed claim, the Across callback re-entering a send, a fuzzed deposit/claim
///         round trip, valuation liveness and the kind-relabelling bound on hub-bound arrivals.
contract CoreVaultAdversarialRound2Test is CoreVaultFixture {
    uint256 internal constant SENT = 1000e6;
    uint256 internal constant ARRIVES = 999.4e6;

    function _homeMessage(bytes32 id, TransferKind kind) internal pure returns (bytes memory) {
        return TransitMessage.encode(FUND_ID, SPOKE, id, kind);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-066 ordering: the expiry is attested through the report-lifetime path, then the spoke's late report lists
    // the arrival. ExpiryAttested -> ArrivalConfirmed must release In-flight Value exactly once, must release the
    // Spoke Cap the time-path attestation kept (security review S-13) exactly once, and must close the refund path.
    // ---------------------------------------------------------------------------------------------------------------
    function test_DEC066_lateArrivalAfterAttestedExpiryConfirmsOnceAndClosesRefund() public {
        _deposit(alice, 10_000e6); // Idle 9,975
        bytes32 id = _send(SENT, ARRIVES);
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        prices.setPrice(address(usdg), 1e18);
        vault.attestExpiry(id);
        (, uint256 inFlightSent,,) = vault.spokeCapUsage(0);
        assertEq(inFlightSent, SENT, "S-13: a time-path attestation keeps the Spoke Cap until the outcome is known");
        assertEq(vault.inFlightValue(), ARRIVES, "Share Assets still count the transit (QB11 stance)");

        // The fill happened after all; the spoke's report lists it.
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));
        assertEq(uint8(vault.transit(id).state), uint8(TransitState.ArrivalConfirmed));
        assertEq(vault.inFlightValue(), 0, "released exactly once");
        (uint256 spokeValue, uint256 sentAfter,,) = vault.spokeCapUsage(0);
        assertEq(spokeValue, ARRIVES, "the report carries it now, nothing deducted as unknown");
        assertEq(sentAfter, 0, "the Spoke Cap is released once, at the confirmation");
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6 - SENT + ARRIVES);
        assertEq(vault.shareAssets(), _bucketSum());

        // A refund can no longer be recognized, even with the full amount sitting in the escrow.
        usdc.mint(vault.transit(id).escrow, SENT);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.InvalidTransitState.selector, id, uint8(TransitState.ArrivalConfirmed))
        );
        vault.recognizeRefund(id);
        assertEq(vault.shareAssets(), SEED_IDLE + 9975e6 - SENT + ARRIVES, "nothing moved");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-072 / DEC-095 fuzz: a Standard claim uses its own reserve and Free Idle only; another holder's Standard
    // reserve is never touched at any Share Price, with or without a Partial Payout.
    // ---------------------------------------------------------------------------------------------------------------
    function testFuzz_DEC072_standardClaimNeverTouchesAnotherHoldersReserve(
        uint256 bobRequest,
        uint256 aliceRequest,
        uint256 positionPrincipal
    ) public {
        _deposit(alice, 10_000e6);
        _deposit(bob, 10_000e6); // Idle 19,950
        vm.prank(manager);
        vault.allocateToHubSpokeVault(5000e6); // Free Idle 14,950
        hubVault.moveToPosition(5000e6);
        bobRequest = bound(bobRequest, 1e6, 20_000e6);
        _request(bob, bobRequest, ICoreVaultPayouts.PayoutMode.Standard);
        uint256 bobReserve = vault.payoutRequest(bob).reserved;
        // FV-OQ-1 reading (final verification): bounded by Bob's 9,975 shares at 1.00, below Free Idle (14,950).
        assertEq(bobReserve, bobRequest < 9975e6 ? bobRequest : 9975e6);
        aliceRequest = bound(aliceRequest, 1e6, 20_000e6);
        _request(alice, aliceRequest, ICoreVaultPayouts.PayoutMode.Standard);
        uint256 aliceReserve = vault.payoutRequest(alice).reserved;
        assertEq(aliceReserve + bobReserve, vault.payoutReserve());

        hubVault.setPosition(address(usdc), bound(positionPrincipal, 0, 20_000e6));
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts); // Idle only, DEC-068 partial if short
        vm.warp(block.timestamp + 72 hours);
        uint256 freeBefore = vault.freeIdle();
        vm.prank(alice);
        try vault.claimPayout(0) returns (ICoreVault.PayoutReceipt memory r) {
            assertLe(r.usdcGross, aliceReserve + freeBefore, "own reserve then Free Idle, nothing else");
            assertLe(r.usdcGross, r.usdcRequested);
            assertEq(r.payoutFee, 0, "Standard pays no Payout Fee");
        } catch (bytes memory err) {
            assertEq(bytes4(err), ICoreVault.InsufficientFreeIdle.selector);
        }
        assertEq(vault.payoutRequest(bob).reserved, bobReserve, "Bob's reserve is untouched");
        assertEq(vault.payoutReserve(), bobReserve + vault.payoutRequest(alice).reserved);
        assertLe(vault.payoutReserve(), vault.idle());
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
        assertEq(shares.totalSupply() % 1e18, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reentrancy through the Across callback during a send: the pinned SpokePool is also `acrossSpokePool`, so a
    // re-entrant `handleV3AcrossMessage` (or any other guarded verb) from inside `depositV3` passes the caller check
    // and must be stopped by the guard, rolling the whole send back.
    // ---------------------------------------------------------------------------------------------------------------
    function test_Reentrancy_acrossSpokePoolReenteringDuringSendIsRefused() public {
        ReenteringAcrossPool malPool = new ReenteringAcrossPool();
        bridge = new MockBridgeAdapter(address(malPool));
        CoreVaultConfig memory c = _config(25);
        c.acrossSpokePool = address(malPool);
        _deploy(_mandate(2000), c);
        _deposit(alice, 10_000e6); // Idle 9,975
        _ensureSpokeReport(); // S-14: the spoke has reported once before the hub funds it
        bytes32 fakeId = keccak256("fabricated");

        bytes[2] memory payloads = [
            abi.encodeCall(
                ICoreVault.handleV3AcrossMessage,
                (address(usdc), 1, address(0), _homeMessage(fakeId, TransferKind.Principal))
            ),
            abi.encodeCall(ICoreVault.sweepExcess, (address(usdc)))
        ];
        for (uint256 i; i < payloads.length; ++i) {
            malPool.arm(address(vault), payloads[i]);
            vm.prank(manager);
            vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
            vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
            assertEq(vault.idle(), SEED_IDLE + 9975e6, "the send was rolled back");
            assertEq(vault.inFlightValue(), 0);
            assertEq(usdc.balanceOf(address(vault)), SEED_IDLE + 9975e6);
            assertEq(usdc.allowance(address(vault), address(malPool)), 0, "no approval survives a failed send");
        }
        // Disarmed, the same send goes through and leaves no approval behind.
        malPool.disarm();
        vm.prank(manager);
        vault.sendToSpoke(0, SENT, 0, _quote(ARRIVES));
        assertEq(vault.idle(), SEED_IDLE + 9975e6 - SENT);
        assertEq(usdc.allowance(address(vault), address(malPool)), 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-035 / DEC-077 fuzz: an immediate deposit-then-full-claim round trip at any Share Price never extracts value
    // from the fund: the leaver never gets back more than it paid, and the incumbent's value never drops by more than
    // one USDC base unit of rounding.
    // ---------------------------------------------------------------------------------------------------------------
    function testFuzz_DEC077_roundTripNeverExtractsValue(uint256 principal, uint256 amount) public {
        _deployAtMinimumFees();
        _deposit(alice, 10_000e6); // 10,000 shares
        vm.prank(manager);
        vault.allocateToHubSpokeVault(4000e6);
        hubVault.moveToPosition(4000e6);
        hubVault.setPosition(address(usdc), bound(principal, 1000e6, 12_000e6)); // price 0.7x to 1.8x
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        uint256 aliceBefore = shares.balanceOf(alice) * vault.sharePrice() / 1e36;

        amount = bound(amount, 1e6, 50_000e6);
        usdc.mint(bob, amount);
        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        uint256 charged;
        try vault.deposit(amount, 0) returns (uint256, uint256 charged_) {
            charged = charged_;
        } catch {
            vm.stopPrank();
            return; // below one share: rejected (DEC-035)
        }
        // Above the balance: full burn (DEC-020).
        ICoreVault.PayoutReceipt memory r = vault.requestPayout(charged * 2, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.stopPrank();

        assertEq(shares.balanceOf(bob), 0, "everything burned");
        assertLe(r.usdcPaid, charged, "the leaver never takes out more than it paid");
        assertLe(usdc.balanceOf(bob), amount);
        uint256 aliceAfter = shares.balanceOf(alice) * vault.sharePrice() / 1e36;
        assertGe(aliceAfter + 1, aliceBefore, "the incumbent loses at most one base unit of rounding");
        assertEq(vault.shareAssets(), _bucketSum());
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Payout liveness (DEC-021 "investor exit is unblockable", DEC-056, OQ-10; Core Vault verifier major): a claim never
    // reverts because the price source or the hub Spoke Vault's `buildReport` REVERTS. It falls back to the last known
    // price / hub value kept from the last successful deposit or payout, with an event; a deposit still reverts.
    // ---------------------------------------------------------------------------------------------------------------

    /// @dev Alice holds 9,975 shares; 1,000 USDC went to the hub Spoke Vault, which now holds 1 WETH priced at 2,500.
    ///      Bob's deposit is the last successful valuation (it records the WETH price and the hub value).
    function _hubWethFund() internal {
        _deposit(alice, 10_000e6); // Idle 9,975
        vm.prank(manager);
        vault.allocateToHubSpokeVault(1000e6);
        hubVault.moveToPosition(1000e6);
        hubVault.setPosition(address(weth), 1e18); // the position is now 1 WETH
        _deposit(bob, 1000e6);
    }

    /// @dev Alice's Instant request of 100, fully payable from Free Idle, is its own claim (DEC-120 item 1).
    function _aliceClaims() internal returns (ICoreVault.PayoutReceipt memory) {
        return _request(alice, 100e6, ICoreVaultPayouts.PayoutMode.Instant);
    }

    function test_DEC021_revertingFeedFallsBackToTheLastPriceForAPayout() public {
        _hubWethFund();
        uint256 assetsBefore = vault.shareAssets();
        prices.setReverts(address(weth), true);

        vm.expectEmit(address(vault));
        emit ICoreVault.PriceFallback(address(weth), 2.5e9);
        ICoreVault.PayoutReceipt memory r = _aliceClaims();
        assertEq(r.shareAssets, assetsBefore, "valued at the last known WETH price");
        assertGt(r.usdcPaid, 0);

        // A deposit keeps reverting on the failing dependency (Q57 reading: mints need every value fresh).
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.UnsupportedToken.selector, address(weth)));
        vault.deposit(1000e6, 0);
        vm.stopPrank();
    }

    function test_DEC021_revertingHubReportFallsBackToTheLastHubValueForAPayout() public {
        _hubWethFund();
        uint256 assetsBefore = vault.shareAssets();
        hubVault.setBuildReverts(true);

        vm.expectEmit(address(vault));
        emit ICoreVault.HubValuationFallback(2500e6);
        ICoreVault.PayoutReceipt memory r = _aliceClaims();
        assertEq(r.shareAssets, assetsBefore, "the hub Spoke Vault at its last known value");
        assertEq(r.unwindProceeds, 0);
        assertGt(r.usdcPaid, 0);

        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(bytes("build reverts"));
        vault.deposit(1000e6, 0);
        vm.stopPrank();
    }

    function test_DEC021_successfulPayoutRefreshesTheLastKnownValuation() public {
        _hubWethFund();
        prices.setPrice(address(weth), 3e9); // WETH moves to 3,000; Alice's claim records it
        _aliceClaims();
        prices.setReverts(address(weth), true);
        vm.expectEmit(address(vault));
        emit ICoreVault.PriceFallback(address(weth), 3e9);
        _request(bob, 10e6, ICoreVaultPayouts.PayoutMode.Instant);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-01 / DEC-092 / CV-OQ-1: a hub-bound arrival is credited by the kind the report listed, never by the kind the
    // Across message claims. A stranger who front-runs a listed Income transfer with dust labelled Principal cannot
    // move anything into Idle: its dust is credited as income and the same amount of the real fill is held apart; the
    // bases never receive more than the listed amount and no value leaves the ledger.
    // ---------------------------------------------------------------------------------------------------------------
    function test_OQ01_reportedKindWinsOverTheMessageKind() public {
        _deposit(alice, 10_000e6);
        bytes32 id = keccak256("spoke income transfer 9");
        _deliver(_inFlightToHub(_spokeReport(0, 0), id, 400e6, TransferKind.Income)); // 400 of income in flight
        uint256 idle0 = vault.idle();
        uint256 protocol0 = usdc.balanceOf(protocol);

        pool.fill(address(vault), address(usdc), 5, _homeMessage(id, TransferKind.Principal)); // stranger's dust
        assertEq(vault.idle(), idle0, "the message cannot relabel income into Idle");
        pool.fill(address(vault), address(usdc), 400e6, _homeMessage(id, TransferKind.Income)); // the real fill
        // DEC-161: the income credited is held for its collection result; no fee leaves before the conversion.
        uint256 feesOut = usdc.balanceOf(protocol) - protocol0 + usdc.balanceOf(vault.managerFeeVault());
        assertEq(feesOut, 0);
        assertEq(_heldIncome(), 400e6, "exactly the listed amount, as income");
        assertEq(vault.unmatchedArrivals(), 5, "the same amount is held apart for good");
        assertEq(vault.idle(), idle0, "Idle never moved");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
        assertEq(vault.sweepExcess(address(usdc)), 0, "nothing sweepable: the ledger covers the balance exactly");
    }
}
