// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ISpokeVaultIncome} from "../../../src/interfaces/ISpokeVaultIncome.sol";
import {CrossChainFixture} from "./helpers/CrossChainFixture.sol";

/// @title Final verification of security review S-4: a recovered Income transfer home enters Idle as Principal
/// @notice `CoreVault.recoverUnlistedArrival` (S-4) credits an arrival no accepted report listed to Idle once no report
///         can list it any more. It has no way to know the transfer's kind (the Across message's claim is
///         unauthenticated, OQ-01), so an Income send home that reaches the hub during a report outage longer than the
///         retention is recovered as Principal. As found, the manager's own `sendToHub(Income)` reached this path (no
///         fee split, the income spread by shares at recovery time).
/// @notice WP-10 (DEC-122, DEC-161): the manager can no longer send Income home; Income goes home only through a
///         collection order, whose result the Hub converts when its transfer is credited. The residual is that order's
///         send: recovered as Principal after a multi-day outage, its dollars raise the Share Price instead, and its
///         result on the Hub never closes (reported in the WP-10 PR; bounded by the income in flight).
contract RecoveredIncomeAsPrincipalTest is CrossChainFixture {
    function test_VF_S4_theManagersIncomeSendHomeIsRefused() public {
        _deposit(alice, 100_000e6);
        (, uint256 outboundDeposit) = _sendToSpoke(50_000e6);
        _fillOnSpoke(outboundDeposit);
        _reportAndDeliver(900);

        // Income in the spoke's collected bucket can no longer go home through the manager's send.
        _strangerFillOnSpoke(attacker, keccak256("spoke income"), 10_000e6, TransferKind.Income);
        assertEq(spoke.collectedIncome(address(usdg)), 10_000e6, "income sits in the spoke's collected bucket");
        vm.chainId(SPOKE);
        vm.prank(manager);
        vm.expectRevert(ISpokeVaultIncome.IncomeSentOnlyByCollection.selector);
        spoke.sendToHub(10_000e6, TransferKind.Income, 0);
        vm.chainId(HUB);
        assertEq(spoke.collectedIncome(address(usdg)), 10_000e6, "it waits for a collection order");
    }
}
