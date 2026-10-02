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

/// @title Regression (security review S-4): a send home the hub did not see listed within about 6.5 hours is no longer
///        frozen in `unmatchedArrivals`
/// @notice Was PoC `test_POC_sendHomeNeverListedInTimeIsFrozenForGood` (high, access lens): the Spoke Vault stopped
///         listing a send home at `fillDeadline + maxReportAge`, so if no report built in that window was accepted the
///         filled arrival (298,700 USDC, 60% of the fund) stayed held apart for good.
/// @notice FIX: the spoke lists the send home for `ReportCodec.HUB_BOUND_RETENTION` past its deadline (S-3), so the
///         report built after the old window still lists it and the hub credits the arrival; past the retention,
///         `CoreVault.recoverUnlistedArrival` (S-4) credits it (test/security/crosschain/SendHomeStranded.t.sol).
contract UnmatchedReturnLegPoC is AccessFundFixture {
    uint256 internal constant T0 = 1_800_000_000;
    /// @dev DEC-162: the Across adapters fix the amounts to arrive at 0.08% plus 0.03 (first sends on each route).
    uint256 internal constant SENT = 300_000e6;
    uint256 internal constant ARRIVES = SENT - 240e6 - 30_000; // 299,759.97
    uint256 internal constant SENT_HOME = 299_000e6;
    uint256 internal constant ARRIVES_HOME = SENT_HOME - 239.2e6 - 30_000; // 298,760.77

    /// @dev What the spoke chain produced, carried across the chain switch in memory.
    struct SpokeSide {
        address spokeVault;
        bytes reportFirst;
        bytes32 homeTransitId;
        bytes reportAfterArrival;
        bytes reportInsideWindow;
        bytes reportAfterWindow;
        uint256 afterWindow;
    }

    function test_SEC_S4_sendHomeNotListedInTheOldWindowIsStillCredited() public {
        // ---------------------------------------------------------------- Spoke Chain (its own state, run first)
        SpokeSide memory s = _spokeSide();

        // ---------------------------------------------------------------- Hub Chain
        _hubFactory();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 0, s.reportFirst);
        vm.prank(manager);
        assertEq(core.sendToSpoke(0, SENT, 0, ""), _hubTransitId(a.coreVault));
        assertEq(core.transit(_hubTransitId(a.coreVault)).amountToArrive, ARRIVES);

        vm.warp(T0 + 900);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 1, s.reportAfterArrival);
        assertEq(core.inFlightValue(), 0, "arrival confirmed");

        // The manager's send home is filled on the hub: held apart until a report lists the transfer.
        usdc.mint(address(core), ARRIVES_HOME);
        vm.prank(address(hubAcross));
        core.handleV3AcrossMessage(
            address(usdc),
            ARRIVES_HOME,
            stranger,
            TransitMessage.encode(a.fundId, SPOKE, s.homeTransitId, TransferKind.Principal)
        );
        assertEq(core.unmatchedArrivals(), ARRIVES_HOME);

        // The outage: no report built in the 6 h 26 min after the send is accepted. The next one the hub accepts was
        // built after that window and still lists the transfer, so the arrival is credited.
        vm.warp(s.afterWindow + 900);
        _deliverReport(a.valueReportReceiver, s.spokeVault, 3, s.reportAfterWindow);

        assertEq(core.unmatchedArrivals(), 0, "S-4: credited on the report after the outage");
        assertEq(core.idle(), SEED_IDLE + 198_750e6 + ARRIVES_HOME, "S-4: in Idle");
        // The spoke keeps the arrival less its 10 USDG Operating Cash top-up and the send home.
        uint256 spokeLeft = ARRIVES - 10e6 - SENT_HOME;
        assertEq(
            core.shareAssets(),
            SEED_IDLE + 198_750e6 + spokeLeft + ARRIVES_HOME,
            "S-4: Share Assets whole but for the fees"
        );
    }

    /// @dev Runs the spoke's half on the spoke chain: the hub's send arrives, the manager sends most of it home, and
    ///      three reports are built: after the arrival, inside the old listing window, and after it.
    function _spokeSide() internal returns (SpokeSide memory s) {
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        Mandate memory m = _buildMandate(spokeFactory, fundId, _plan());
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), _plan()));
        SpokeVault spoke = SpokeVault(c.spokeVault);
        s.spokeVault = c.spokeVault;
        // Security review S-14: the new Spoke Vault reports once, so the hub may fund it.
        spoke.report();
        s.reportFirst = spokeWormhole.published(0).payload;

        // The hub's send arrives (the hub transit id depends only on the Core Vault address and its first nonce).
        bytes memory message = TransitMessage.encode(
            fundId, HUB, _hubTransitId(spokeFactory.addressOf(fundId, "CoreVault", HUB)), TransferKind.Principal
        );
        usdg.mint(address(spoke), ARRIVES);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(address(usdg), ARRIVES, stranger, message);
        spoke.report();
        s.reportAfterArrival = spokeWormhole.published(1).payload;

        // The manager sends 299,000 USDG home (the Across adapter's fee) and a report lists it while it is in flight.
        vm.prank(manager);
        s.homeTransitId = spoke.sendToHub(SENT_HOME, TransferKind.Principal, 0);
        assertEq(spoke.hubBoundTransit(s.homeTransitId).amountToArrive, ARRIVES_HOME);
        spoke.report();
        s.reportInsideWindow = spokeWormhole.published(2).payload;
        assertEq(spoke.buildReport().inFlightToHub.length, 1);

        // Past the fill deadline plus the report lifetime the spoke still lists it (security review S-3).
        vm.warp(block.timestamp + 21_600 + MAX_REPORT_AGE + 1);
        spoke.report();
        s.reportAfterWindow = spokeWormhole.published(3).payload;
        s.afterWindow = block.timestamp;
        assertEq(spoke.buildReport().inFlightToHub.length, 1);
    }

    function _hubTransitId(address coreVault) internal pure returns (bytes32) {
        return keccak256(abi.encode(HUB, coreVault, uint256(1)));
    }
}
