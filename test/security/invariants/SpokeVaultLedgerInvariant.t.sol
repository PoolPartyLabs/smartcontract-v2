// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Transit, TransitState, TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {FundSystemFixture} from "./FundSystemFixture.sol";
import {FundSystemHandler} from "./FundSystemHandler.sol";

/// @title Ledger invariants of the Spoke Vault in both roles, inside a whole fund
/// @notice DEC-080: the internal ledger is the only source of value; it never exceeds the balances, and every unit in
///         it is explained by a movement the vault itself booked. The sweep check (`sweepExcess` takes exactly the
///         balance above the ledger and leaves every bucket untouched, DEC-101) runs inside the handler's
///         `sweepExcess` action on every call.
contract SpokeVaultLedgerInvariantTest is FundSystemFixture {
    FundSystemHandler internal handler;

    function setUp() public {
        _deploySystem();
        // The two liveness assumptions of FundSystemHandler hold unless an exploratory run drops them:
        // SEC_UNLISTED_SENDS_HOME=true and SEC_LATE_REFUNDS=true reproduce the counterexamples of the report.
        handler = new FundSystemHandler(
            sys, !vm.envOr("SEC_UNLISTED_SENDS_HOME", false), !vm.envOr("SEC_LATE_REFUNDS", false)
        );
        targetContract(address(handler));
        bytes4[] memory excluded = new bytes4[](2);
        excluded[0] = FundSystemHandler.settle.selector;
        excluded[1] = FundSystemHandler.deliverFreshReport.selector;
        excludeSelector(StdInvariant.FuzzSelector(address(handler), excluded));
    }

    /// DEC-080: for every ledger token of both Spoke Vaults, Unallocated Balance plus collected income plus Operating
    /// Cash never exceeds the balance; donations only ever widen the gap.
    function invariant_DEC080_ledgerSumsNeverExceedBalances() public view {
        _assertBacked(sys.hubVault, sys.usdc);
        _assertBacked(sys.hubVault, sys.weth);
        _assertBacked(sys.spokeVault, sys.usdg);
        _assertBacked(sys.spokeVault, sys.spokeWeth);
        // DEC-054, DEC-096: the hub role holds no Operating Cash, and principal is never WETH in this model.
        assertEq(sys.hubVault.operatingCash(), 0, "hub Spoke Vault holds Operating Cash");
        assertEq(sys.hubVault.unallocatedBalance(address(sys.weth)), 0);
        assertEq(sys.spokeVault.unallocatedBalance(address(sys.spokeWeth)), 0);
    }

    /// Every unit of principal in a Spoke Vault's ledger is explained: on the spoke, Principal arrivals less Principal
    /// sent home plus recognized Principal refunds equals Unallocated Balance plus position principal plus Operating
    /// Cash (the only thing fed from principal, DEC-096); on the hub, what the Core Vault allocated less what went
    /// back to Idle. DEC-090, DEC-093: the cross-chain counters are exact.
    function invariant_DEC080_principalLedgerIsConserved() public view {
        uint256 sentHomePrincipal;
        uint256 sentHome;
        uint256 refundedPrincipal;
        uint256 count = handler.homeSendCount();
        for (uint256 i; i < count; ++i) {
            FundSystemHandler.HomeSend memory h = handler.homeSend(i);
            sentHome += h.amountSent;
            Transit memory t = sys.spokeVault.hubBoundTransit(h.id);
            assertEq(t.amountSent, h.amountSent);
            assertEq(t.amountToArrive, h.amountToArrive);
            assertEq(
                uint8(t.state),
                uint8(h.recognized ? TransitState.RefundRecognized : TransitState.Sent),
                "DEC-066: a send home is Sent until its refund is recognized"
            );
            if (h.kind != TransferKind.Principal) continue;
            sentHomePrincipal += h.amountSent;
            if (h.recognized) refundedPrincipal += h.amountSent;
        }
        assertEq(
            handler.spokeVaultPrincipal() + sys.spokeVault.operatingCash(),
            handler.spokePrincipalArrivals() + refundedPrincipal - sentHomePrincipal,
            "spoke principal ledger"
        );
        assertEq(sys.spokeVault.cumulativeReceived(), handler.spokePrincipalArrivals(), "DEC-090: cumulativeReceived");
        assertEq(sys.spokeVault.cumulativeSentHome(), sentHome, "Q66: cumulativeSentHome");
        assertEq(sys.spokeVault.reportSequence(), handler.lastReportSequence(), "DEC-093: report sequence");
        assertEq(
            handler.hubVaultPrincipal(),
            handler.allocatedToHubVault() - handler.returnedFromHubVault(),
            "hub Spoke Vault principal ledger"
        );

        // The in-flight list holds each send home at most once and only while it is Sent.
        bytes32[] memory ids = sys.spokeVault.inFlightTransitIds();
        for (uint256 i; i < ids.length; ++i) {
            assertEq(uint8(sys.spokeVault.hubBoundTransit(ids[i]).state), uint8(TransitState.Sent));
            for (uint256 j = i + 1; j < ids.length; ++j) {
                assertTrue(ids[i] != ids[j], "DEC-104: a send home listed twice");
            }
        }
    }

    /// DEC-092: the collected income bucket holds exactly the income the adapters paid the vault, plus Income a
    /// stranger bridged in, less what was forwarded or sent home (and not refunded); it never mixes with principal.
    function invariant_DEC092_collectedIncomeBucketIsConserved() public view {
        uint256 incomeSentHome;
        uint256 count = handler.homeSendCount();
        for (uint256 i; i < count; ++i) {
            FundSystemHandler.HomeSend memory h = handler.homeSend(i);
            if (h.kind == TransferKind.Income && !h.recognized) incomeSentHome += h.amountSent;
        }
        assertEq(
            sys.spokeVault.collectedIncome(address(sys.usdg)),
            sys.spokeUni.realizedIncome(address(sys.usdg)) + handler.strangerSpokeIncome()
                + handler.spokeIncomeSwappedOut() - incomeSentHome,
            "spoke collected USDG"
        );
        assertEq(
            sys.spokeVault.collectedIncome(address(sys.spokeWeth)),
            sys.spokeUni.realizedIncome(address(sys.spokeWeth)) - handler.spokeIncomeSwappedIn(),
            "spoke collected WETH"
        );
        assertEq(
            sys.hubVault.collectedIncome(address(sys.usdc)),
            sys.hubUni.realizedIncome(address(sys.usdc)) + sys.hubAave.realizedIncome(address(sys.usdc))
                - handler.incomeForwardedFromHubVault(address(sys.usdc)),
            "hub collected USDC"
        );
        assertEq(
            sys.hubVault.collectedIncome(address(sys.weth)),
            sys.hubUni.realizedIncome(address(sys.weth)) - handler.incomeForwardedFromHubVault(address(sys.weth)),
            "hub collected WETH"
        );
    }

    function _assertBacked(SpokeVault vault, CoreMockToken token) internal view {
        assertLe(
            handler.ledgerOf(address(vault), address(token)),
            token.balanceOf(address(vault)),
            "DEC-080: ledger above balance"
        );
    }
}
