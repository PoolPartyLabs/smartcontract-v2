// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {console2} from "forge-std/Test.sol";
import {SpokeVaultTestBase} from "../../unit/spoke/SpokeVaultTestBase.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

/// @notice [H-08] (spoke-a report H-02), ported to main. The spoke twin of the Core Vault's Operating Cash sink:
///         `setOperatingCashParameters` is still unbounded (S-5, open for a founder decision) and every value-moving
///         operation, a stranger's 1-unit arrival included, still moves `min(topUp, Unallocated base)` out of Share
///         Assets. What changed (S-5 interim, `releaseOperatingCash`, later removed as S-63): the manager could return Operating Cash above the
///         floor to Unallocated Balance; that verb let a manager and an ally extract the fund and is gone (S-63).
contract H02_SpokeOperatingCashSink is SpokeVaultTestBase {
    function setUp() public {
        _setUpMocks();
        _deploySpoke();
    }

    /// @dev Pin (STILL_PRESENT): unbounded parameters and a stranger-triggered top-up sink all spoke principal.
    function test_REGRESSION_REVIEW_H08_managerMovesAllSpokePrincipalIntoOperatingCash() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }

    /// @dev The sweep's interim release verb was removed on 2026-10-01 (S-63: a reversible sink let a manager and an
    ///      ally extract the fund). The sink is one-way again until the founder rules on a cap (SEC-OQ-2): nothing
    ///      returns the cash, and the report keeps it out of the spoke's principal.
    function test_REVIEW_H08_noVerbReturnsTheSinkSinceS63() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }

    function _sink() internal {
        // 100,000 USDG of fund principal arrive from the hub (the arrival tops up 10 USDG, DEC-096 defaults).
        _arrive(100_000e6, keccak256("hub send 1"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 100_000e6 - SPOKE_TOP_UP);
        // One manager call with no bound (DEC-100 accepts an uncapped floor, nothing caps the top-up amount).
        vm.prank(manager);
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        // A stranger's 1-unit Across fill carrying the fund's public id (Across passes no depositor, OQ-01).
        _arrive(1, keccak256("stranger dust"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 0, "all principal left Unallocated Balance");
        assertEq(vault.operatingCash(), 100_000e6 + 1, "and sits in Operating Cash, outside Share Assets");
    }
}
