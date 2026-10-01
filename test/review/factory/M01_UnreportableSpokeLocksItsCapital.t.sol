// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {FactoryReviewFixture} from "./FactoryReviewFixture.sol";

/// @notice Review port of factory M01, consolidated finding M-04 (register S-24 and S-25, Acknowledged). The Mandate's
///         reporting parameters of a spoke (`maxReportAge`, `wormholeChainId`) are still free manager inputs on main.
///         On `e5c778a` a lifetime below Robinhood's finality, or the wrong Wormhole chain id, let the hub send to a
///         spoke whose reports could never be delivered, and the capital came back into `unmatchedArrivals` for good
///         (a full exit paid 897,499 with 99,951 outstanding). Since S-14 the hub sends nothing to a spoke it never
///         accepted a report from, so the review's lock is NOT_CONSTRUCTIBLE: the wrong value is a self-DoS (the spoke
///         is never funded) and a full exit is paid in full.
contract M01_UnreportableSpokeLocksItsCapital is FactoryReviewFixture {
    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant SEND = 100_000e6;
    uint256 internal constant ARRIVES = 99_950e6;

    struct Ctx {
        IFundFactory.FundAddresses a;
        address named;
        uint256 hubState;
        bytes payload;
        uint64 seq;
        uint256 reportAt;
    }

    /// @dev A report lifetime of 10 minutes, below Robinhood's ~925 s finality.
    function test_REVIEW_M04_reportLifetimeBelowFinalityLeavesTheSpokeUnfunded() public {
        FundPlan memory plan = _plan();
        plan.maxReportAge = 600;
        Ctx memory c;
        _arbitrumCreateAndDeposit(c, plan);
        _robinhoodCreateAndReport(c, plan);

        _enterHub(c.hubState, c.reportAt + FINALITY);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IValueReportReceiver.ReportTooOld.selector, FINALITY, uint32(600)));
        ValueReportReceiver(c.a.valueReportReceiver).deliver(_vaa(c.named, c.payload, c.seq));
        _showNothingIsLocked(c);
    }

    /// @dev The wrong Wormhole chain id (23 is Arbitrum's; Robinhood's is 72): every genuine VAA is an unknown emitter.
    function test_REVIEW_M04_wrongWormholeChainIdLeavesTheSpokeUnfunded() public {
        FundPlan memory plan = _plan();
        plan.spokeWormholeChainId = 23;
        Ctx memory c;
        _arbitrumCreateAndDeposit(c, plan);
        _robinhoodCreateAndReport(c, plan);

        _enterHub(c.hubState, c.reportAt + FINALITY);
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(
                IValueReportReceiver.UnknownEmitter.selector, WH_SPOKE, bytes32(uint256(uint160(c.named)))
            )
        );
        ValueReportReceiver(c.a.valueReportReceiver).deliver(_vaa(c.named, c.payload, c.seq));
        _showNothingIsLocked(c);
    }

    function _arbitrumCreateAndDeposit(Ctx memory c, FundPlan memory plan) internal {
        Deployment memory d = _hubChain();
        _refreshPrices();
        Mandate memory m;
        (c.a, m) = _createFund(d, plan); // still accepted by MandateLib.validate and the factory
        c.named = address(uint160(uint256(m.spokes[0].spokeVault)));
        _deposit(CoreVault(c.a.coreVault), alice, DEPOSIT);
        c.hubState = vm.snapshotState();
    }

    function _robinhoodCreateAndReport(Ctx memory c, FundPlan memory plan) internal {
        FundFactory spokeFactory = _spokeChain();
        vm.warp(T0 + 5 minutes);
        _createSpoke(spokeFactory, c.a.creationNumber, plan); // same Mandate, same hash
        c.reportAt = block.timestamp;
        (c.payload, c.seq) = _publish(SpokeVault(c.named));
    }

    function _showNothingIsLocked(Ctx memory c) internal {
        CoreVault vault = CoreVault(c.a.coreVault);
        assertFalse(ValueReportReceiver(c.a.valueReportReceiver).hasReport(0), "no report was ever accepted");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        vault.sendToSpoke(0, SEND, 0, _quote(ARRIVES));

        uint256 value = vault.shareAssets();
        assertEq(value, 997_500e6);
        vm.prank(alice);
        vault.requestPayout(value, ICoreVault.PayoutMode.Instant);
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory r = vault.claimPayout("");
        console2.log("Share Assets / paid gross / outstanding", value, r.usdcGross, r.usdcOutstanding);
        assertEq(r.usdcGross, value, "a full exit is paid in full");
        assertEq(r.usdcOutstanding, 0);
        assertEq(vault.unmatchedArrivals(), 0);
    }
}

/// @notice The other extreme of M-04 (reasoned in the review, not proven): `maxReportAge` has no upper bound
///         (S-25), and since S-4 the recovery delay of an arrival no report listed is `6 h + 3 days + 2 x maxReportAge`.
///         At `type(uint32).max` an unlisted send home (a reporting gap of more than three days after its fill) can
///         never be recovered, the time path of `attestExpiry` never opens, and mints never see a stale report.
contract M01_HugeReportLifetime is CoreVaultFixture {
    function test_POC_REVIEW_M04_hugeReportLifetimePutsTheUnlistedArrivalRecoveryOutOfReach() public {
        Mandate memory m = _mandate(2000);
        m.spokes[0].maxReportAge = type(uint32).max; // accepted: MandateLib only rejects zero
        _deploy(m, _config(25));
        _deposit(alice, 1_000_000e6);
        _ensureSpokeReport();

        // A send home lands on the hub before any accepted report lists it.
        bytes32 home = keccak256("send home");
        pool.fill(
            address(vault), address(usdc), 99_900e6, TransitMessage.encode(FUND_ID, SPOKE, home, TransferKind.Principal)
        );
        assertEq(vault.unmatchedArrivals(), 99_900e6);

        uint256 readyAt = block.timestamp + 6 hours + ReportCodec.HUB_BOUND_RETENTION + 2 * uint256(type(uint32).max);
        console2.log("recovery opens after (years)", (readyAt - block.timestamp) / 365 days);
        vm.warp(block.timestamp + 10 * 365 days);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.RecoveryNotReady.selector, home, readyAt));
        vault.recoverUnlistedArrival(0, home);
        assertEq((readyAt - 1_800_000_000) / 365 days, 272, "272 years");
    }
}
