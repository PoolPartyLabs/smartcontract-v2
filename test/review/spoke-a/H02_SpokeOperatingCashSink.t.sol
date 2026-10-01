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
///         Assets. What changed (S-5 interim, `releaseOperatingCash`): the manager can return Operating Cash above the
///         floor to Unallocated Balance, so the sink is no longer one-way for the manager's key; nobody else can.
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
        vm.prank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdg), 0, 1e6)
        );
        vault.sendToHub(1e6, TransferKind.Principal, 0, _quote(1e6));
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

    /// @dev Regression (FIXED part, S-5 interim): the manager can bring the sink back; a stranger cannot, and nothing
    ///      above `operatingCash - floor` is releasable.
    function test_REVIEW_H08_releaseOperatingCashReturnsTheSinkToUnallocatedBalance() public {
        _sink();
        uint256 cash = vault.operatingCash();

        // While the floor is at max nothing is releasable.
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(SpokeVaultTypes.OperatingCashNotReleasable.selector, 1, 0));
        vault.releaseOperatingCash(1);

        // A stranger can neither change the parameters nor release.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        vault.releaseOperatingCash(1);

        // The manager lowers the floor to the DEC-096 value and releases everything above it.
        vm.startPrank(manager);
        vault.setOperatingCashParameters(SPOKE_FLOOR, SPOKE_TOP_UP);
        vm.expectRevert(
            abi.encodeWithSelector(SpokeVaultTypes.OperatingCashNotReleasable.selector, cash, cash - SPOKE_FLOOR)
        );
        vault.releaseOperatingCash(cash);
        vault.releaseOperatingCash(cash - SPOKE_FLOOR);
        vm.stopPrank();

        assertEq(vault.operatingCash(), SPOKE_FLOOR);
        assertEq(vault.unallocatedBalance(address(usdg)), cash - SPOKE_FLOOR);
        ReportCodec.Report memory r = vault.buildReport();
        assertEq(r.unallocated[0].amount, 99_995e6 + 1, "the next report carries the principal again");
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
