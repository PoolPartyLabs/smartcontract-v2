// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IValueReportReceiver} from "../../../src/interfaces/IValueReportReceiver.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {MandateLib, Mandate} from "../../../src/mandate/Mandate.sol";
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

    /// @dev Mandate v2 (D-15): the Mandate carries the Hub's Wormhole chain id, so the review's value (23, Arbitrum's)
    ///      is now refused for a spoke at creation.
    function test_REVIEW_M04_theHubsWormholeChainIdIsRefusedForASpoke() public {
        FundPlan memory plan = _plan();
        plan.spokeWormholeChainId = 23;
        Deployment memory d = _hubChain();
        uint256 n = d.factory.nextCreationNumber();
        Mandate memory m = _buildMandate(d.factory, d.factory.fundIdOf(HUB, n, manager), plan);
        IFundFactory.HubParams memory p = _hubParams(n, plan, _coreVaultCreationCode(d));
        _fundManagerSeed(address(usdc), manager, address(d.factory), p.seedAmount);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(MandateLib.SpokeIsHubChain.selector, SPOKE));
        d.factory.createFund(m, p);
    }

    /// @dev Another wrong Wormhole chain id (30 is Base's; Robinhood's is 72): every genuine VAA is an unknown emitter.
    function test_REVIEW_M04_wrongWormholeChainIdLeavesTheSpokeUnfunded() public {
        FundPlan memory plan = _plan();
        plan.spokeWormholeChainId = 30;
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
        vault.sendToSpoke(0, SEND, 0, "");

        uint256 value = vault.shareAssets();
        assertEq(value, SEED_IDLE + 997_500e6);
        vm.prank(alice);
        ICoreVault.PayoutReceipt memory r = vault.requestPayout(value, ICoreVaultPayouts.PayoutMode.Instant, 0);
        console2.log("Share Assets / paid gross / outstanding", value, r.usdcGross, r.usdcOutstanding);
        // Everything but the manager's seed share (DEC-127) is alice's.
        assertEq(r.usdcGross, value - SEED_IDLE, "a full exit is paid in full");
        assertEq(r.usdcOutstanding, 0);
        assertEq(vault.unmatchedArrivals(), 0);
    }
}

/// @notice The other extreme of M-04: `maxReportAge` had no upper bound (S-25). On main a lifetime of
///         `type(uint32).max` was accepted, so mints could price on reports 136 years old and (since S-4) an unlisted
///         send home could only be recovered 272 years later. Fixed on fix/pp-sc-fix-independent-review: the Mandate
///         refuses a lifetime above `MandateLib.MAX_REPORT_AGE` (one day), so such a fund cannot be created.
contract M01_HugeReportLifetime is CoreVaultFixture {
    function test_REVIEW_M04_hugeReportLifetimeIsRefusedAtCreation() public {
        Mandate memory m = _mandate(2000);
        m.spokes[0].maxReportAge = type(uint32).max;
        vm.expectRevert(abi.encodeWithSelector(MandateLib.InvalidSpoke.selector, m.spokes[0].chainId));
        this.deployFor(m);
    }

    function deployFor(Mandate memory m) external {
        _deploy(m, _config(25));
    }
}
