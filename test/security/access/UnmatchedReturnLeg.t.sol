// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: a send home the hub never saw listed within about 6.5 hours is frozen in `unmatchedArrivals` for good
/// @notice TRUST BOUNDARY. `CoreVault.handleV3AcrossMessage` cannot trust the Across message, so it credits a
///         spoke-to-hub arrival only against what an ACCEPTED report of the origin spoke listed in `inFlightToHub`
///         (CoreVaultLogic.sol:489-531, OQ-01). The Spoke Vault lists a send home only while it is "still in flight":
///         until `fillDeadline + maxReportAge` (SpokeCrossChainLib.sol:300-302), about 6 h 26 min after the send;
///         after that the id is pruned and never listed again (`nextReport`, SpokeCrossChainLib.sol:103-106). If the
///         hub accepts no report built inside that window, the arrival is never matched: it stays `pending` in
///         `unmatchedArrivals`, which is outside every value base, never swept and has no recovery verb
///         (CoreVaultTypes.sol:94; CV-OQ-5 discusses only fabricated ids).
/// @notice TRIGGER. No attacker is needed: a report outage longer than the window, right after a send home. Reports
///         are permissionless but in practice one keeper relays them, a report is only deliverable for about 26
///         minutes after it is built, and Wormhole finality alone takes 15 to 20 of those. A keeper out of gas on
///         one chain, a Wormhole guardian pause or a sequencer outage of 6.5 hours is enough (Arbitrum had a 7 hour
///         one). The manager keeps operating meanwhile: the manager is a different key from the keeper.
/// @notice IMPACT. The whole transfer (here 298,700 USDC, 60% of the fund) is lost to the shareholders permanently:
///         the USDC sits in the Core Vault, the spoke no longer counts it, the hub never will. The control shows the
///         same arrival is credited to Idle when one report from inside the window is accepted.
/// @notice FIX. Decouple "listed so the hub can match it" from "counted as in flight": keep every send home listed
///         (id, amount, kind) until the spoke has evidence the hub saw it, or for a long retention such as 30 days,
///         while only `_stillInFlight` entries count in Share Assets and the Spoke Cap. And give `unmatchedArrivals`
///         a recovery path (for example a time-locked sweep to the excess recipient, DEC-101), so nothing the fund
///         owns can be stranded by an infrastructure outage.
contract UnmatchedReturnLegPoC is AccessFundFixture {
    uint256 internal constant T0 = 1_800_000_000;
    uint256 internal constant SENT = 300_000e6;
    uint256 internal constant ARRIVES = 299_700e6;
    uint256 internal constant SENT_HOME = 299_000e6;
    uint256 internal constant ARRIVES_HOME = 298_700e6;

    /// @dev What the spoke chain produced, carried across the chain switch in memory.
    struct SpokeSide {
        address spokeVault;
        bytes32 homeTransitId;
        bytes reportAfterArrival;
        bytes reportInsideWindow;
        bytes reportAfterWindow;
        uint256 afterWindow;
    }

    function test_POC_sendHomeNeverListedInTimeIsFrozenForGood() public {
        // ---------------------------------------------------------------- Spoke Chain (its own state, run first)
        SpokeSide memory s = _spokeSide();

        // ---------------------------------------------------------------- Hub Chain
        _hubFactory();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        vm.prank(manager);
        assertEq(core.sendToSpoke(0, SENT, 0, _quote(ARRIVES, address(0))), _hubTransitId(a.coreVault));
        assertEq(core.idle(), 198_750e6);

        // The first report (the arrival on the spoke) is relayed normally.
        vm.warp(T0 + 900);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 0, s.reportAfterArrival);
        assertEq(core.inFlightValue(), 0, "arrival confirmed");
        assertEq(core.shareAssets(), 198_750e6 + 299_690e6);

        // The manager's send home is filled on the hub: real USDC reaches the Core Vault, held apart until a report
        // lists the transfer.
        usdc.mint(address(core), ARRIVES_HOME);
        vm.prank(address(hubAcross));
        core.handleV3AcrossMessage(
            address(usdc),
            ARRIVES_HOME,
            stranger,
            TransitMessage.encode(a.fundId, SPOKE, s.homeTransitId, TransferKind.Principal)
        );
        assertEq(core.unmatchedArrivals(), ARRIVES_HOME);

        // Control: had ONE report from inside the window been accepted, the arrival would be in Idle.
        uint256 snapshot = vm.snapshotState();
        _deliverReport(a.valueReportReceiver, s.spokeVault, 1, s.reportInsideWindow);
        assertEq(core.unmatchedArrivals(), 0);
        assertEq(core.idle(), 198_750e6 + ARRIVES_HOME);
        vm.revertToState(snapshot);

        // The outage: no report built in the 6 h 26 min after the send is accepted. The next one the hub accepts was
        // built after the window and no longer lists the transfer.
        vm.warp(s.afterWindow + 900);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 2, s.reportAfterWindow);

        assertEq(core.unmatchedArrivals(), ARRIVES_HOME, "still held apart, and no later report will ever list it");
        assertEq(core.idle(), 198_750e6, "never credited");
        assertEq(core.sweepExcess(address(usdc)), 0, "not even the garbage collector reaches it");
        assertGe(_balance(usdc, address(core)), 198_750e6 + ARRIVES_HOME, "the USDC is in the Core Vault");
        // The spoke stopped counting it when it sent it; the hub never will.
        assertEq(core.shareAssets(), 198_750e6 + 690e6, "Share Assets: 199,440 USDC for 498,750 shares");
        assertLt(core.sharePrice(), 0.4e24, "Share Price fell from 1.00 to under 0.40 with no market loss");
    }

    /// @dev Runs the spoke's half on the spoke chain: the hub's send arrives, the manager sends most of it home, and
    ///      three reports are built: after the arrival, inside the listing window, and after it.
    function _spokeSide() internal returns (SpokeSide memory s) {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);
        s.spokeVault = c.spokeVault;

        // The hub's send arrives (the hub transit id depends only on the Core Vault address and its first nonce).
        bytes memory message = TransitMessage.encode(
            fundId, HUB, _hubTransitId(spokeFactory.addressOf(fundId, "CoreVault", HUB)), TransferKind.Principal
        );
        usdg.mint(address(spoke), ARRIVES);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(address(usdg), ARRIVES, stranger, message);
        spoke.report();
        s.reportAfterArrival = spokeWormhole.published(0).payload;

        // The manager sends 299,000 USDG home (0.1% fee) and a report lists it while it is in flight.
        vm.prank(manager);
        s.homeTransitId = spoke.sendToHub(SENT_HOME, TransferKind.Principal, 0, _quote(ARRIVES_HOME, address(0)));
        spoke.report();
        s.reportInsideWindow = spokeWormhole.published(1).payload;
        assertEq(spoke.buildReport().inFlightToHub.length, 1);

        // Past the fill deadline plus the report lifetime the spoke presumes it filled and drops it for good.
        vm.warp(block.timestamp + 21_600 + MAX_REPORT_AGE + 1);
        spoke.report();
        s.reportAfterWindow = spokeWormhole.published(2).payload;
        s.afterWindow = block.timestamp;
        assertEq(spoke.buildReport().inFlightToHub.length, 0);
        assertEq(spoke.inFlightTransitIds().length, 0);
    }

    function _hubTransitId(address coreVault) internal pure returns (bytes32) {
        return keccak256(abi.encode(HUB, coreVault, uint256(1)));
    }
}
