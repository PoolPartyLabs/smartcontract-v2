// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title PoC: a transfer home is lost for good when no report that lists it is accepted in time
/// @notice Finding (high). Lens: cross-chain messaging and bridging.
///
/// Attack / failure path (no attacker needed, only a report relay outage):
/// 1. The manager sends Principal home from the Robinhood Spoke Vault (`SpokeVault.sendToHub`). The Spoke Vault debits
///    Unallocated Balance at once and lists the transit in `inFlightToHub` only while
///    `block.timestamp <= fillDeadline + maxReportAge` (`SpokeCrossChainLib._stillInFlight`, 6 h + 1,588 s).
/// 2. An Across relayer fills on Arbitrum within minutes. No accepted report lists the transit yet, so the Core Vault
///    holds the USDC apart (`CoreVaultLogic.receiveHubBound`: `pending`, `unmatchedArrivals`), outside every base.
/// 3. For `fillDeadline + maxReportAge` no report listing the transit is accepted on the hub. Causes that need no
///    attacker: the report keeper or the VAA relayer is down, the Wormhole guardians lag the Robinhood chain, the
///    Robinhood batch poster or Ethereum finality stalls (every report then arrives older than `maxReportAge` and is
///    rejected with `ReportTooOld`, so the reports published during the outage are lost, not delayed).
/// 4. Reports resume. The Spoke Vault now presumes the transit filled and no longer lists it, and transit ids are
///    never reused, so `CoreVaultLogic._matchReturnLeg` can never credit the pending arrival.
///
/// Impact: the USDC sits in the Core Vault forever: not in Idle, not in Share Assets, not payable to any Shareholder,
/// and not sweepable (`unmatchedArrivals` is part of the ledger). The Share Price drops by the whole transfer for good.
/// Here 40% of the fund (39,980 of 99,725 USDC) is frozen permanently.
///
/// Fix: never drop a hub-bound transit from the report on time alone. Keep it listed until its refund is recognized
/// or the hub has acknowledged the credit (the hub already ignores a listed entry it has credited:
/// `_returnLeg` counts `amount - credited`), or list the last N sends home in a ring like `arrivedTransits` so the
/// listing survives an outage; on the hub, let a later report that carries the id credit a pending arrival at any
/// time. Until hub-to-spoke messaging exists, a guarded recovery path for `unmatchedArrivals` is the minimum.
contract SendHomeStrandedPoC is CrossChainFixture {
    function test_POC_sendHomeStrandedWithoutListingReport() public {
        // Alice is the fund's only Shareholder.
        _deposit(alice, 100_000e6);
        uint256 aliceShares = shares.balanceOf(alice);

        // The manager allocates 50,000 USDC to Robinhood; the relayer fills; a report confirms the arrival.
        (bytes32 outbound, uint256 outboundDeposit) = _sendToSpoke(50_000e6, 49_975e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);
        assertEq(uint8(core.transit(outbound).state), uint8(TransitState.ArrivalConfirmed));
        uint256 assetsBefore = core.shareAssets();
        uint256 idleBefore = core.idle();
        assertEq(assetsBefore, 99_725e6, "Idle 49,750 + spoke 49,975");

        // The manager brings 40,000 USDG home. The relayer fills on the hub two minutes later: no report has listed the
        // transit yet, so the arrival is held apart.
        (, uint256 homeDeposit) = _sendToHub(40_000e6, TransferKind.Principal, _quote(39_980e6));
        skip(120);
        _fillOnHub(homeDeposit);
        assertEq(core.unmatchedArrivals(), 39_980e6, "held apart until a report lists it");
        assertEq(core.idle(), idleBefore, "not in Idle");

        // A report published now does list the transit, but the outage keeps its VAA from the hub.
        uint256 listingReport = _publishReport();

        // The outage lasts until fillDeadline + maxReportAge has passed on the spoke.
        skip(FILL_DEADLINE + MAX_REPORT_AGE + 1);

        // The report that listed the transit can no longer be accepted: it is older than its lifetime.
        bytes memory lateVaa = _vaa(listingReport);
        vm.expectPartialRevert(IValueReportReceiver.ReportTooOld.selector);
        receiver.deliver(lateVaa);

        // Reports flow again, but the Spoke Vault presumes the transit filled and no longer lists it.
        _reportAndDeliver(900);
        skip(1 days);
        _reportAndDeliver(900);

        // The 39,980 USDC that arrived are stranded: held apart forever, outside Idle and Share Assets, not sweepable.
        assertEq(core.unmatchedArrivals(), 39_980e6, "still held apart");
        assertEq(core.idle(), idleBefore, "never credited to Idle");
        assertEq(core.sweepExcess(address(usdc)), 0, "not sweepable either");
        assertEq(usdc.balanceOf(address(core)), idleBefore + 39_980e6, "the USDC is in the vault");
        assertEq(core.shareAssets(), assetsBefore - 40_000e6, "Share Assets lost the whole transfer");

        // Alice's shares are worth 59,725 USDC instead of 99,725: a permanent 40% loss with the USDC sitting in the vault.
        uint256 aliceValue = aliceShares * core.sharePrice() / 1e36;
        assertApproxEqAbs(aliceValue, 59_725e6, 1);
    }
}
