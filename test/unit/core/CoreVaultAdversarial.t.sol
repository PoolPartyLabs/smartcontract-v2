// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CoreVaultConfig} from "../../../src/core/CoreVaultTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {ReenteringIncomeToken} from "../../mocks/core/ReenteringIncomeToken.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Adversarial verification of the Core Vault (round 1): ordering attacks, reentrancy through an income
///         token, fuzzed reserve protection, a transit-state shortcut and Standard reserve accounting.
contract CoreVaultAdversarialTest is CoreVaultFixture {
    uint256 internal constant SENT = 1000e6;
    uint256 internal constant ARRIVES = 999.4e6;

    function _homeMessage(bytes32 id, TransferKind kind) internal pure returns (bytes memory) {
        return TransitMessage.encode(FUND_ID, SPOKE, id, kind);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-066 / DEC-090: a refund may only be recognized on an attested expiry, and DEC-063 only for the full amount
    // sent. Without both, one wei donated to the escrow of a transit that WAS filled (report not yet delivered) would
    // drop Share Assets by `amountToArrive`, and an entrant who deposits in that window would capture value from every
    // existing holder when the report confirms the arrival.
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC066_refundOnSentTransitWithDustMustNotReleaseShareAssets() public {
        _deposit(alice, 10_000e6); // Idle 9,975
        bytes32 id = _send(SENT, ARRIVES);
        uint256 assetsBefore = vault.shareAssets();
        assertEq(assetsBefore, 9975e6 - SENT + ARRIVES);

        // The fill happened before the deadline; the confirming report has not been delivered yet.
        vm.warp(uint256(vault.transit(id).fillDeadline) + 1);
        usdc.mint(vault.transit(id).escrow, 1); // attacker's dust, not an Across refund

        // Expected per the ICoreVault state machine: Sent -> ExpiryAttested -> RefundRecognized, so a refund on a
        // transit whose expiry was never attested is refused and Share Assets keep counting the transit.
        try vault.recognizeRefund(id) {
            assertEq(uint8(vault.transit(id).state), uint8(TransitState.Sent), "no shortcut from Sent");
        } catch {}
        assertEq(vault.shareAssets(), assetsBefore, "a dust donation must not move Share Assets");
    }

    function test_DEC066_entrantCapturesValueThroughDustRefundWindow() public {
        _deployFeeless();
        _deposit(alice, 10_000e6); // 10,000 shares, Idle 10,000
        bytes32 id = _send(SENT, ARRIVES);
        vm.warp(uint256(vault.transit(id).fillDeadline) + 1);
        usdc.mint(vault.transit(id).escrow, 1);
        try vault.recognizeRefund(id) {} catch {}
        prices.setPrice(address(usdg), 1e18); // the feed kept updating; only the value capture is under test

        // Bob enters at whatever price the vault shows now.
        (uint256 bobShares, uint256 bobCharged) = _deposit(bob, 9000e6);
        // The report confirming the arrival lands afterwards.
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), id, ARRIVES));

        uint256 bobValue = bobShares * vault.sharePrice() / 1e36;
        assertLe(bobValue, bobCharged + 1, "an entrant never captures value that predates entry");
    }

    function testFuzz_DEC063_escrowBelowAmountSentNeverMovesShareAssets(uint256 donation, bool attested) public {
        _deposit(alice, 10_000e6);
        bytes32 id = _send(SENT, ARRIVES);
        vm.warp(uint256(vault.transit(id).fillDeadline) + MAX_REPORT_AGE + 1);
        prices.setPrice(address(usdg), 1e18);
        if (attested) vault.attestExpiry(id);
        TransitState state = vault.transit(id).state;
        uint256 assets = vault.shareAssets();
        usdc.mint(vault.transit(id).escrow, bound(donation, 0, SENT - 1));
        try vault.recognizeRefund(id) {
            fail();
        } catch {}
        assertEq(uint8(vault.transit(id).state), uint8(state));
        assertEq(vault.shareAssets(), assets);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Return leg. DEC-085 / DEC-104: a Principal transfer home counts in Share Assets while in flight, so Share Price
    // holds through the send and the fill. DEC-092: an Income transfer home stays out of Share Assets while in flight
    // (the report carries the kind since ReportCodec version 2, CV-OQ-1) and both kinds count toward the Spoke Cap.
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC104_principalReturnLegKeepsSharePriceThroughTheFill() public {
        _deposit(alice, 10_000e6); // Idle 9,975
        bytes32 out = _send(SENT, ARRIVES);
        _deliver(_arrived(_spokeReport(ARRIVES, ARRIVES), out, ARRIVES));
        uint256 priceBefore = vault.sharePrice();

        bytes32 id = keccak256("spoke principal transfer 1");
        // The spoke sent 400 home: its Unallocated Balance fell by 400 and the transfer is reported in flight.
        _deliver(_inFlightToHub(_spokeReport(ARRIVES - 400e6, ARRIVES), id, 400e6));
        assertEq(vault.sharePrice(), priceBefore, "principal in flight stays in Share Assets (DEC-085)");
        (,, uint256 inFlight,) = vault.spokeCapUsage(0);
        assertEq(inFlight, 400e6, "the pending return leg counts toward the Spoke Cap (DEC-066 B1)");

        pool.fill(address(vault), address(usdc), 400e6, _homeMessage(id, TransferKind.Principal));
        assertEq(vault.sharePrice(), priceBefore, "the fill moves it between bases, not out (DEC-104)");
        assertEq(vault.shareAssets(), _bucketSum());
    }

    function test_DEC092_incomeReturnLegStaysOutOfShareAssetsWhileInFlight() public {
        _deposit(alice, 10_000e6); // 9,975 shares
        uint256 priceBefore = vault.sharePrice();
        bytes32 id = keccak256("spoke income transfer 1");
        // 400 USDC of collected income sent home, reported as Income.
        _deliver(_inFlightToHub(_spokeReport(0, 0), id, 400e6, TransferKind.Income));
        assertEq(vault.shareAssets(), 9975e6, "income in flight is outside Share Assets (DEC-092)");
        assertEq(vault.inFlightValue(), 0);
        assertEq(vault.sharePrice(), priceBefore);
        (,, uint256 capInFlight,) = vault.spokeCapUsage(0);
        assertEq(capInFlight, 400e6, "but it counts toward the Spoke Cap (DEC-066 B1)");
        pool.fill(address(vault), address(usdc), 400e6, _homeMessage(id, TransferKind.Income));
        // Split at collection (ruling 2026-09-29): 80 of fees leave, 320 net stays for holders; never Idle.
        assertEq(vault.collectedIncome(address(usdc)), 320e6, "credited to collected income, never Idle");
        assertEq(vault.sharePrice(), priceBefore, "the arrival does not move the Share Price either");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-014 vs ruling 2026-09-29: income is attributed when it is collected, to the holders of that moment. Income
    // generated in a hub position before an entrant's deposit but collected after it is therefore shared with the
    // entrant (reported as an open question); income collected before the entry is not.
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC014_OPEN_incomeGeneratedBeforeEntryIsSharedWhenCollectedAfterIt() public {
        _deployFeeless();
        _deposit(ana, 10_000e6); // 10,000 shares
        hubVault.forwardIncome(address(usdc), 1000e6); // collected before Bruno: all Ana's
        hubVault.setCumulativeIncome(address(usdc), 1000e6 + 2100e6); // generated, not yet collected
        _deposit(bruno, 11_000e6); // 11,000 shares
        assertEq(vault.attributedIncome(bruno, address(usdc)), 0, "nothing collected since Bruno entered");
        assertApproxEqAbs(vault.attributedIncome(ana, address(usdc)), 1000e6, 1, "all of it is Ana's");
        // The 2,100 generated before Bruno's entry is collected after it: shared pro rata (10,000 / 11,000).
        hubVault.forwardIncome(address(usdc), 2100e6);
        assertApproxEqAbs(vault.attributedIncome(ana, address(usdc)), 2000e6, 2);
        assertApproxEqAbs(vault.attributedIncome(bruno, address(usdc)), 1100e6, 2);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // OQ-01 ordering: a stranger front-runs a real hub-bound transit id with dust before any report lists it.
    // ---------------------------------------------------------------------------------------------------------------

    function test_OQ01_strangerDustOnRealIdNeverAddsToWhatTheReportListed() public {
        _deposit(alice, 10_000e6);
        bytes32 id = keccak256("spoke transit 7");
        uint256 idleBefore = vault.idle();

        pool.fill(address(vault), address(usdc), 3, _homeMessage(id, TransferKind.Principal)); // stranger's dust
        assertEq(vault.idle(), idleBefore, "dust before the listing stays out of Idle");
        assertEq(vault.unmatchedArrivals(), 3);

        _deliver(_inFlightToHub(_spokeReport(0, 0), id, 500e6)); // the spoke reports 500 in flight
        assertEq(vault.idle(), idleBefore + 3, "the dust is credited against the listed amount");

        pool.fill(address(vault), address(usdc), 500e6, _homeMessage(id, TransferKind.Principal)); // the real fill
        assertEq(vault.idle(), idleBefore + 500e6, "Idle grows by exactly the listed amount");
        assertEq(vault.unmatchedArrivals(), 3, "the surplus is held apart for good");
        assertEq(vault.shareAssets(), idleBefore + 500e6);
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
        assertEq(vault.sweepExcess(address(usdc)), 0, "held-apart value is never swept");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reentrancy through a hook-bearing income token: Income Withdrawal and the full-burn income payment.
    // ---------------------------------------------------------------------------------------------------------------

    function _deployWithReenteringToken() internal returns (ReenteringIncomeToken mal) {
        mal = new ReenteringIncomeToken();
        CoreVaultConfig memory c = _config(25);
        c.incomeTokens = new address[](2);
        c.incomeTokens[0] = address(weth);
        c.incomeTokens[1] = address(mal);
        _deploy(_mandate(2000), c);
        _deposit(alice, 10_000e6);
        hubVault.forwardIncome(address(mal), 100e18); // 80 to Alice, 20 of fees transferred out at once
        assertApproxEqAbs(vault.attributedIncome(alice, address(mal)), 80e18, 1);
    }

    function test_Reentrancy_incomeTokenReenteringWithdrawIncomeIsRefused() public {
        ReenteringIncomeToken mal = _deployWithReenteringToken();
        mal.arm(address(vault), abi.encodeCall(ICoreVault.withdrawIncome, (address(mal))));
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.withdrawIncome(address(mal));
        assertApproxEqAbs(vault.attributedIncome(alice, address(mal)), 80e18, 1, "nothing was taken");
        assertEq(vault.collectedIncome(address(mal)), 80e18);
    }

    function test_Reentrancy_incomeTokenReenteringDepositDuringFullBurnIsRefused() public {
        ReenteringIncomeToken mal = _deployWithReenteringToken();
        usdc.mint(alice, 1000e6);
        vm.prank(alice);
        usdc.approve(address(vault), 1000e6);
        mal.arm(address(vault), abi.encodeCall(ICoreVault.deposit, (1000e6, 0)));
        _request(alice, 20_000e6, ICoreVault.PayoutMode.Instant); // more than the balance: full burn (DEC-020)
        vm.prank(alice);
        vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
        vault.claimPayout("");
        assertEq(shares.balanceOf(alice), 9975e18, "the burn was rolled back with the payment");
        assertEq(vault.idle(), 9975e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-095 fuzz: an Instant claim never touches another holder's Standard reserve, at any Share Price.
    // ---------------------------------------------------------------------------------------------------------------

    function testFuzz_DEC095_instantClaimNeverTouchesReserveAtAnyPrice(
        uint256 bobRequest,
        uint256 aliceRequest,
        uint256 positionPrincipal
    ) public {
        _deposit(alice, 10_000e6);
        _deposit(bob, 10_000e6);
        vm.prank(manager);
        vault.allocateToHubSpokeVault(5000e6);
        hubVault.moveToPosition(5000e6);
        bobRequest = bound(bobRequest, 1e6, 20_000e6);
        _request(bob, bobRequest, ICoreVault.PayoutMode.Standard);
        uint256 reserve = vault.payoutReserve();
        assertEq(reserve, bobRequest < 14_950e6 ? bobRequest : 14_950e6);

        // The hub position moves the Share Price anywhere between 0.5x and 2x before Alice claims.
        hubVault.setPosition(address(usdc), bound(positionPrincipal, 0, 20_000e6));
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts); // Idle only, DEC-068 partial if short
        aliceRequest = bound(aliceRequest, 1e6, 20_000e6);
        _request(alice, aliceRequest, ICoreVault.PayoutMode.Instant);
        vm.prank(alice);
        try vault.claimPayout("") returns (ICoreVault.PayoutReceipt memory r) {
            assertLe(r.usdcGross, 14_950e6 - reserve, "Instant paid from Free Idle only");
            assertLe(r.usdcGross, r.usdcRequested);
            assertEq(r.payoutFee, r.usdcGross * 200 / 10_000);
        } catch (bytes memory err) {
            assertEq(bytes4(err), ICoreVault.InsufficientFreeIdle.selector);
        }
        assertEq(vault.payoutReserve(), reserve, "Bob's reserve is untouched");
        assertLe(vault.payoutReserve(), vault.idle());
        assertEq(shares.totalSupply() % 1e18, 0);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-068 / DEC-072: Standard reserve accounting across a Partial Payout.
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC068_partialStandardPayoutKeepsReserveConsistent() public {
        _deposit(alice, 10_000e6); // 9,975 shares, Idle 9,975
        vm.prank(manager);
        vault.allocateToHubSpokeVault(9000e6); // Free Idle 975
        hubVault.moveToPosition(9000e6);
        hubVault.setPosition(address(usdc), 9100e6); // the position gained: Share Assets 10,075 on 9,975 shares
        _request(alice, 5000e6, ICoreVault.PayoutMode.Standard);
        assertEq(vault.payoutReserve(), 975e6);
        hubVault.setUnwindMode(MockHubSpokeVault.UnwindMode.Reverts);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(alice);
        // Price 1.010025...: 965 whole shares pay 974.674..., below the 975 reserve; the request stays open.
        assertEq(r.sharesBurned, 965e18);
        assertEq(r.usdcGross, 965e18 * r.sharePrice / 1e36);
        assertLt(r.usdcGross, 975e6);
        assertGt(r.usdcGross, 974e6);
        assertEq(r.usdcOutstanding, 5000e6 - r.usdcGross);
        ICoreVault.PayoutRequest memory req = vault.payoutRequest(alice);
        assertTrue(req.open);
        assertEq(req.reserved, 975e6 - r.usdcGross, "the unused part of the reserve stays reserved");
        assertEq(vault.payoutReserve(), req.reserved);
        assertLe(vault.payoutReserve(), vault.idle());
        assertEq(vault.freeIdle(), 0, "nothing else was released to the manager");
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }
}
