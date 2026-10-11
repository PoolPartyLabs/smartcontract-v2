// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {FundFactory} from "../../../src/factory/FundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {ValueReportReceiver} from "../../../src/report/ValueReportReceiver.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind, Transit} from "../../../src/interfaces/FundTypes.sol";
import {Mandate} from "../../../src/mandate/Mandate.sol";
import {FactoryReviewFixture} from "./FactoryReviewFixture.sol";

/// @notice Review port of factory H02, consolidated finding H-06 (register S-6, with S-9 and S-14). On `e5c778a` the
///         Manager created the Robinhood Spoke Vault at the address the hub trusts from a Mandate whose only change was
///         `maxBridgeFeeBps = 10,000`; the hub accepted its reports and arrivals, and one exclusive send home with
///         `outputAmount = 1` moved 199,899.999999 USDC to the Manager's relayer, cap free again. On main:
///         - the review's Mandate cannot be written (S-9 capped the field at 100; Mandate v2 removed it, DEC-156);
///         - a divergent Mandate inside the bounds can still be created (FF-OQ-1: the factory only checks the
///           Mandate against the hash the same caller passes), but its reports carry its own `mandateHash` and every
///           delivery reverts `WrongMandate` (S-6), so the hub never has a report of it and never funds it (S-14);
///         - the drain quote itself no longer exists: since DEC-158 / DEC-162 `sendToHub` takes no bridge parameter
///           (WP-07 C3) and the Across adapter fixes the amount to arrive, with no exclusive relayer.
contract H02_DivergentSpokeMandateAcceptedByTheHub is FactoryReviewFixture {
    uint256 internal constant DEPOSIT = 1_000_000e6;
    uint256 internal constant SEND = 200_000e6; // the whole Spoke Cap of the hub's Mandate
    uint256 internal constant ARRIVES = 199_900e6; // a stranger's fill to the divergent spoke

    struct Ctx {
        IFundFactory.FundAddresses a;
        address named;
        bytes32 hubMandateHash;
        bytes32 spokeMandateHash;
        uint256 hubState;
        bytes payload;
        uint64 seq;
        uint256 reportAt;
    }

    function _arbitrumCreateAndDeposit(Ctx memory c) internal returns (CoreVault vault) {
        Deployment memory d = _hubChain();
        _refreshPrices();
        Mandate memory m;
        (c.a, m) = _createFund(d, _plan());
        vault = CoreVault(c.a.coreVault);
        c.named = address(uint160(uint256(m.spokes[0].spokeVault)));
        assertEq(vault.mandate().spokes[0].spokeCap, 200_000e6, "what investors read on the hub");
        _deposit(vault, alice, DEPOSIT);
        c.hubMandateHash = vault.mandateHash();
        c.hubState = vm.snapshotState();
    }

    /// @dev Re-attack inside the bounds: the spoke's Mandate lifts the Spoke Cap (the hub's shows 200,000). The factory
    ///      still creates it at the trusted address, but the hub rejects every report of it and never funds it.
    function test_REVIEW_H06_divergentSpokeInsideTheBoundsIsNeverAcceptedNorFunded() public {
        Ctx memory c;
        CoreVault vault = _arbitrumCreateAndDeposit(c);

        FundFactory spokeFactory = _spokeChain();
        vm.warp(T0 + 5 minutes);
        FundPlan memory other = _plan();
        other.spokeCap = type(uint256).max; // the only change
        (SpokeVault spoke,) = _createSpoke(spokeFactory, c.a.creationNumber, other);
        assertEq(address(spoke), c.named, "still created at the address the hub trusts (FF-OQ-1)");
        c.spokeMandateHash = spoke.mandateHash();
        assertTrue(c.spokeMandateHash != c.hubMandateHash, "rules the hub never showed");
        c.reportAt = block.timestamp;
        (c.payload, c.seq) = _publish(spoke);

        _enterHub(c.hubState, c.reportAt + FINALITY);
        ValueReportReceiver receiver = ValueReportReceiver(c.a.valueReportReceiver);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.WrongMandate.selector, c.spokeMandateHash));
        receiver.deliver(_vaa(c.named, c.payload, c.seq));
        assertFalse(receiver.hasReport(0), "no report of the divergent spoke is ever stored");

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SpokeNotReporting.selector, 0));
        vault.sendToSpoke(0, SEND, 0, "");
        assertEq(vault.shareAssets(), SEED_IDLE + 997_500e6, "nothing left the hub");
        console2.log("Share Assets after the attempt", vault.shareAssets());
    }

    /// @dev The drain quote on a spoke that somehow holds capital (here a stranger's fill to the divergent spoke):
    ///      DEC-158, DEC-162: the Spoke Vault ignores the quote argument (vestigial until WP-07 C3) and the Across
    ///      adapter fixes the amount to arrive at its rule fee (0.08% plus 0.03 on a first send), with no exclusive
    ///      relayer, whatever the quote, the Mandate or the manager's relayer say (DEC-156: no Mandate bound).
    function test_REVIEW_H06_theDrainQuoteIsIgnoredOnTheSpoke() public {
        Ctx memory c;
        _arbitrumCreateAndDeposit(c);
        FundFactory spokeFactory = _spokeChain();
        vm.warp(T0 + 5 minutes);
        FundPlan memory other = _plan();
        other.spokeCap = type(uint256).max;
        (SpokeVault spoke,) = _createSpoke(spokeFactory, c.a.creationNumber, other);
        _acrossFill(
            address(spokeAcross), usdg, address(spoke), ARRIVES, _principal(c.a.fundId, HUB, keccak256("stranger"))
        );
        uint256 all = spoke.unallocatedBalance(address(usdg));
        uint256 ruleFee = (all * 8e14 + 1e18 - 1) / 1e18 + 30_000;

        vm.prank(manager);
        bytes32 id = spoke.sendToHub(all, TransferKind.Principal, 0);
        Transit memory t = spoke.hubBoundTransit(id);
        assertEq(t.amountSent, all);
        assertEq(t.amountToArrive, all - ruleFee, "the adapter's amount");
        assertEq(spokeAcross.lastRecipient(), spoke.coreVault(), "to the Core Vault");
    }
}
