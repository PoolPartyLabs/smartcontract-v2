// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {Mandate, MandateLib} from "../../../src/mandate/Mandate.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title Regression (security review S-9, S-6): a spoke created from a Mandate the hub never saw can no longer drain
///        what the hub sends there
/// @notice Was PoC `test_POC_managerDrainsTheSpokeThroughAMandateTheHubNeverSaw` (high, access lens): `createSpoke`
///         compared the Mandate only with a caller-supplied hash, so the manager created the fund's Spoke Vault, at the
///         address the hub's Mandate names, from another Mandate with `maxBridgeFeeBps = 10,000`, and sent every unit
///         the hub bridged "home" for 1 base unit of USDC with itself as exclusive relayer.
/// @notice FIX. S-9, then DEC-156 and DEC-162 (Mandate v2): the Mandate holds no bridge fee bound at all; the Across
///         adapter fixes the amount to arrive from its own fee rule, capped at 1% (`AcrossBridgeAdapter.CAP_RATE`),
///         and both vaults refuse an exclusive relayer, so the one-send drain now FAILS whatever Mandate the spoke runs
///         (this test). S-6: the report carries the Spoke Vault's
///         `mandateHash` and the Core Vault rejects a report whose hash differs from its own, and S-14: `sendToSpoke`
///         requires an accepted report from the spoke, so the hub never funds a spoke whose rules it did not verify
///         (`test_SEC_S6_*` below).
contract RogueSpokeMandatePoC is AccessFundFixture {
    /// @dev What the hub knows, carried across the chain switch in memory.
    struct Hub {
        bytes32 fundId;
        address coreVault;
        bytes32 mandateHash;
        address namedSpokeVault;
    }

    function test_SEC_S9_rogueSpokeMandateCanNoLongerAuthorizeTheOneSendDrain() public {
        Hub memory hub = _hubFund();
        FundFactory spokeFactory = _spokeFactory();
        assertEq(spokeFactory.fundIdOf(HUB, 1, manager), hub.fundId, "same factory address, same fund id");

        // The manager's spoke Mandate differs from the hub's (DEC-156: no Mandate field bounds the bridge fee any
        // more). A send of everything carries the Across adapter's terms (DEC-158, DEC-162: the manager passes no
        // bridge parameter, so no amount of 1 base unit and no exclusive relayer): the amount to arrive is the rule's,
        // whatever the Mandate says.
        FundPlan memory roguePlan = _plan();
        roguePlan.spokeCap = type(uint256).max;
        SpokeVault spoke = _createSpoke(spokeFactory, hub.fundId, roguePlan);
        _arrive(spoke, hub.fundId, 500_000e6);
        uint256 amount = spoke.unallocatedBalance(address(usdg));
        vm.prank(manager);
        bytes32 id = spoke.sendToHub(amount, TransferKind.Principal, 0);
        assertEq(spoke.hubBoundTransit(id).amountToArrive, amount - _ruleFee(amount), "the rule's amount");
        assertEq(spokeAcross.lastRecipient(), spoke.coreVault(), "to the Core Vault");
    }

    /// @notice S-6 and S-14: a Spoke Vault created from another Mandate (here a far larger Spoke Cap and another
    ///         performance fee, both within the core caps) at the fund's address reports its own `mandateHash`; the hub rejects
    ///         the report, so the spoke never counts in Share Assets and the hub never funds it. The same fund's honest
    ///         spoke is accepted.
    function test_SEC_S6_reportsOfASpokeRunningAnotherMandateAreRejected() public {
        // ---------------------------------------------------------------- Spoke Chain: both candidate spokes
        FundFactory spokeFactory = _spokeFactory();
        bytes32 fundId = spokeFactory.fundIdOf(HUB, 1, manager);
        uint256 snapshot = vm.snapshotState();
        SpokeVault honest = _createSpoke(spokeFactory, fundId, _plan());
        honest.report();
        bytes memory honestReport = spokeWormhole.published(0).payload;
        vm.revertToState(snapshot);

        FundPlan memory roguePlan = _plan();
        roguePlan.performanceFeeBps = MandateLib.MAX_PERFORMANCE_FEE_BPS;
        roguePlan.spokeCap = type(uint256).max;
        SpokeVault rogue = _createSpoke(spokeFactory, fundId, roguePlan);
        address spokeAddress = address(rogue);
        rogue.report();
        bytes memory rogueReport = spokeWormhole.published(0).payload;
        assertEq(address(honest), spokeAddress, "same address, same emitter");

        // ---------------------------------------------------------------- Hub Chain
        _hubFactory();
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        _deposit(core, alice, 500_000e6);
        bytes32 rogueHash = ReportCodec.decode(rogueReport).mandateHash;
        assertTrue(rogueHash != core.mandateHash());

        vm.expectRevert(abi.encodeWithSelector(ICoreVault.WrongMandate.selector, rogueHash));
        _deliverReport(a.valueReportReceiver, spokeAddress, 0, rogueReport);
        assertFalse(ValueReportReceiver(a.valueReportReceiver).hasReport(0), "S-6: the rogue report is not accepted");
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        core.sendToSpoke(0, 100_000e6, 0, "");

        // The honest spoke's report is accepted and the hub may fund it.
        _deliverReport(a.valueReportReceiver, spokeAddress, 0, honestReport);
        vm.prank(manager);
        core.sendToSpoke(0, 100_000e6, 0, "");
    }

    function _hubFund() internal returns (Hub memory hub) {
        (IFundFactory.FundAddresses memory a, Mandate memory m) = _createFund(_plan());
        hub.fundId = a.fundId;
        hub.coreVault = a.coreVault;
        hub.mandateHash = CoreVault(a.coreVault).mandateHash();
        hub.namedSpokeVault = address(uint160(uint256(m.spokes[0].spokeVault)));
    }

    function _createSpoke(FundFactory spokeFactory, bytes32 fundId, FundPlan memory plan)
        internal
        returns (SpokeVault)
    {
        Mandate memory m = _buildMandate(spokeFactory, fundId, plan);
        vm.prank(manager);
        IFundFactory.ChainAddresses memory c = spokeFactory.createSpoke(1, m, _spokeParams(MandateLib.hash(m), plan));
        return SpokeVault(c.spokeVault);
    }

    /// @dev A relayer fill of a hub-to-spoke send: the SpokePool transfers the base token, then calls the handler.
    function _arrive(SpokeVault spoke, bytes32 fundId, uint256 amount) internal {
        usdg.mint(address(spoke), amount);
        vm.prank(address(spokeAcross));
        spoke.handleV3AcrossMessage(
            address(usdg),
            amount,
            stranger,
            TransitMessage.encode(fundId, HUB, keccak256("hub transit 1"), TransferKind.Principal)
        );
    }
}
