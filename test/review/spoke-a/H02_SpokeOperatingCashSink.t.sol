// SPDX-License-Identifier: MIT
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
    function test_POC_REVIEW_H08_managerMovesAllSpokePrincipalIntoOperatingCash() public {
        _sink();

        // The next report carries no principal for the hub's Share Assets (Operating Cash is Gross Assets only).
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.unallocated[0].token, address(usdg));
        assertEq(r.unallocated[0].amount, 0);
        assertEq(r.operatingCash, 100_000e6 + 1);

        // The sweep counts it as ledger, a send home finds no Unallocated Balance, and resetting the parameters alone
        // leaves the cash where it is.
        assertEq(vault.sweepExcess(address(usdg)), 0);
        _willArrive(1e6);
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdg), 0, 1e6)
        );
        vault.sendToHub(1e6, TransferKind.Principal, 0);
        vm.prank(manager);
        vault.setOperatingCashParameters(0, 0);
        assertEq(vault.operatingCash(), 100_000e6 + 1);

        // While the parameters stay at max, every later hub-to-spoke arrival is swallowed on arrival.
        vm.prank(manager);
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        _arrive(50_000e6, keccak256("hub send 2"), TransferKind.Principal);
        assertEq(vault.unallocatedBalance(address(usdg)), 0);
        assertEq(vault.operatingCash(), 150_000e6 + 1);
        console2.log("spoke Operating Cash (USDG, 1e6)", vault.operatingCash());
    }

    /// @dev The sweep's interim release verb was removed on 2026-10-01 (S-63: a reversible sink let a manager and an
    ///      ally extract the fund). The sink is one-way again until the founder rules on a cap (SEC-OQ-2): nothing
    ///      returns the cash, and the report keeps it out of the spoke's principal.
    function test_REVIEW_H08_noVerbReturnsTheSinkSinceS63() public {
        _sink();
        uint256 cash = vault.operatingCash();
        vm.startPrank(manager);
        vault.setOperatingCashParameters(SPOKE_FLOOR, SPOKE_TOP_UP);
        (bool released,) =
            address(vault).call(abi.encodeWithSignature("releaseOperatingCash(uint256)", cash - SPOKE_FLOOR));
        vm.stopPrank();
        assertFalse(released, "no release verb");
        assertEq(vault.operatingCash(), cash);
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.unallocated[0].amount, 0, "the principal stays outside the report");
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
