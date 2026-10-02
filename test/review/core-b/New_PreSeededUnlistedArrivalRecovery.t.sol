// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreBCrossChainFixture} from "./CoreBCrossChainFixture.sol";

/// @notice New defect found while porting core-b H02 (H-02) onto main, in the S-4 fix; fixed on
///         fix/pp-sc-fix-independent-review (recovery needs a spoke report built after the LAST unlisted arrival, plus
///         one report lifetime, that no longer lists the id). As found on main:
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

    /// @dev On main Bob was paid 547,303.3125 (49,850.06 too much) and Alice left with 448,725. Now the early recovery
    ///      is refused and Bob's claim, after the listing report, is the honest 497,453.25.
    function test_REVIEW_NEW_S04_preSeededIdCanNoLongerStartTheRecoveryClock() public {
        _deposit(alice, 500_000e6);
        _deposit(bob, 500_000e6);
        _report(); // S-14
        bytes32 out = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(out, ARRIVES);
        _report();
        uint256 fairAssets = vault.shareAssets();
        assertEq(fairAssets, SEED_IDLE + 997_450e6);
        vm.prank(bob);
        vault.requestPayout(1_000_000e6, ICoreVault.PayoutMode.Standard);

        bytes32 predicted = keccak256(abi.encode(FUND_ID, SPOKE, uint256(1)));
        usdc.mint(address(hubAcross), 1);
        _fillOnHub(predicted, 1, TransferKind.Principal);
        uint256 seededAt = block.timestamp;

        vm.warp(seededAt + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(MAX_REPORT_AGE));
        _refreshPrices();
        _report();
        vm.prank(manager);
        bytes32 home = spoke.sendToHub(ARRIVES, TransferKind.Principal, 0, _homeQuote(HOME_OUT));
        assertEq(home, predicted, "the id Bob seeded");
        vm.warp(block.timestamp + 2 minutes);
        _fillOnHub(home, HOME_OUT, TransferKind.Principal);
        uint256 filledAt = block.timestamp;

        // The real arrival restarts the clock, and the latest report predates it: refused.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(ICoreVault.RecoveryNotReady.selector, home, filledAt + uint256(MAX_REPORT_AGE))
        );
        vault.recoverUnlistedArrival(0, home);
        assertEq(vault.shareAssets(), fairAssets, "counted once, on the spoke");

        // The listing report credits it; Bob is paid the honest amount.
        _report();
        assertEq(vault.shareAssets(), fairAssets - (ARRIVES - HOME_OUT), "only the bridge fee is gone");
        vm.prank(bob);
        ICoreVault.PayoutReceipt memory r = vault.claimPayout("");
        assertEq(r.usdcPaid, 497_453_250_050, "the honest payout");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, home));
        vault.recoverUnlistedArrival(0, home);
    }

    /// @dev On main a recovery after a long outage counted the transfer on the spoke and in Idle at once (Bob paid
    ///      547,303.31). Now it waits for a report built after the arrival, which no longer counts it on the spoke.
    function test_REVIEW_NEW_S04_recoveryDuringALongOutageNoLongerCountsTheTransferTwice() public {
        _deposit(alice, 500_000e6);
        _deposit(bob, 500_000e6);
        _report(); // S-14
        bytes32 out = _sendToSpoke(SEND, ARRIVES);
        _fillOnSpoke(out, ARRIVES);
        _report();
        uint256 fairAssets = vault.shareAssets();
        vm.prank(bob);
        vault.requestPayout(1_000_000e6, ICoreVault.PayoutMode.Standard);

        vm.prank(manager);
        bytes32 home = spoke.sendToHub(ARRIVES, TransferKind.Principal, 0, _homeQuote(HOME_OUT));
        vm.warp(block.timestamp + 2 minutes);
        _fillOnHub(home, HOME_OUT, TransferKind.Principal);

        vm.warp(block.timestamp + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(MAX_REPORT_AGE));
        _refreshPrices();
        vm.prank(bob);
        vm.expectRevert();
        vault.recoverUnlistedArrival(0, home);
        assertEq(vault.shareAssets(), fairAssets, "still counted once, on the stale report");

        // Reports resume: past its retention the spoke no longer lists the transfer nor holds it; recovery opens.
        _report();
        vault.recoverUnlistedArrival(0, home);
        assertEq(vault.shareAssets(), fairAssets - (ARRIVES - HOME_OUT), "counted once, in Idle");
        vm.prank(bob);
        ICoreVault.PayoutReceipt memory r = vault.claimPayout("");
        assertEq(r.usdcPaid, 497_453_250_050, "the honest payout");
    }

    /// @dev On main the pre-seeded Income send home was recovered as Principal at once (no fee, no income). Now the
    ///      recovery waits, the listing report arrives first and the transfer is split as Income.
    function test_REVIEW_NEW_S04_preSeededIncomeSendHomeIsSplitAsIncome() public {
        _deposit(alice, 1_000_000e6);
        _report(); // S-14
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
        bytes32 home = spoke.sendToHub(10_000e6, TransferKind.Income, 0, _homeQuote(9995e6));
        assertEq(home, predicted);
        vm.warp(block.timestamp + 2 minutes);
        _fillOnHub(home, 9995e6, TransferKind.Income);
        address feeVault = vault.managerFeeVault();

        vm.expectRevert();
        vault.recoverUnlistedArrival(0, home);
        _report();
        assertEq(usdc.balanceOf(feeVault), 999_500_000, "20% performance fee, half of it to the manager");
        assertEq(vault.collectedIncome(address(usdc)), 7_996_000_000, "7,996 attributed to holders as income");
        console2.log("seed left held apart", vault.unmatchedArrivals());
    }
}
