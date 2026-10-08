// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {Transit, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @title Regression (security review S-3): an unfilled transfer home stays in a value base until its refund, and
///        mints are priced with it
/// @notice Was PoC `test_POC_expiredSendHomeLeavesEveryBaseAndMintsAtHalfPrice` (HIGH, accounting lens): the spoke
///         stopped listing an unfilled send home at `fillDeadline + maxReportAge` ("presumed filled"), so a fresh
///         report priced the fund without it until the Across refund (55 to 90 minutes after the deadline) was
///         recognized and reported; a 50,000 USDC entrant netted about 23,000 USDC of Alice's money.
///
/// Fix (S-3): the send is listed until its refund is recognized (by anyone, or by the next report once it landed) or
/// `ReportCodec.HUB_BOUND_RETENTION` after its deadline. The test replays the sequence and asserts the attack now
/// FAILS: Share Assets never drop, Mallory mints at the fair price and leaves with less than she paid.
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

    function test_SEC_S3_expiredSendHomeStaysInShareAssetsAndMintsAreFair() public {
        _deposit(alice, DEPOSIT);
        bytes32 outbound = _sendToSpoke(SENT_TO_SPOKE, ARRIVES_ON_SPOKE);
        _fillOnSpoke(outbound, ARRIVES_ON_SPOKE);
        _reportAndDeliver();
        uint256 idle = core.idle();

        // 1. The Manager sends the spoke balance home. No relayer fills it.
        bytes32 home = _sendHome(ARRIVES_ON_SPOKE, QUOTED_HOME, TransferKind.Principal);
        Transit memory t = spokeVault.hubBoundTransit(home);
        _reportAndDeliver();
        uint256 fairAssets = core.shareAssets();
        uint256 fairPrice = core.sharePrice();
        assertEq(fairAssets, idle + QUOTED_HOME, "DEC-085: the return leg counts while the report lists it");
        uint256 aliceFair = _valueOf(alice);

        // 2. One second after fillDeadline + maxReportAge: still listed, still counted.
        vm.warp(uint256(t.fillDeadline) + MAX_REPORT_AGE + 1);
        _reportAndDeliver();
        assertEq(core.shareAssets(), fairAssets, "S-3: the unfilled transfer is still in Share Assets");
        assertEq(core.sharePrice(), fairPrice, "S-3: the Share Price did not move");

        // 3. Mallory mints on that fresh report, at the fair price.
        (uint256 minted, uint256 charged) = _deposit(mallory, ATTACK_DEPOSIT);
        assertLt(minted, shares.balanceOf(alice), "S-3: Mallory holds fewer shares than Alice");

        // 4. The Across refund lands 60 minutes after the deadline; anyone recognizes it; the next report counts it.
        vm.warp(uint256(t.fillDeadline) + 60 minutes);
        spokeAcross.refund(t.escrow, address(usdg), ARRIVES_ON_SPOKE);
        spokeVault.recognizeRefund(home);
        _reportAndDeliver();
        assertEq(core.shareAssets(), core.idle() + ARRIVES_ON_SPOKE, "the refund replaced the return leg");

        vm.startPrank(mallory);
        ICoreVault.PayoutReceipt memory r = core.requestPayout(1_000_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        vm.stopPrank();
        assertEq(shares.balanceOf(mallory), 0, "full exit");
        assertLt(r.usdcPaid, charged, "S-3: Mallory leaves with less than she paid");
        assertGe(_valueOf(alice) + 1e6, aliceFair, "S-3: Alice lost nothing to dilution");
    }
}
