// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ISpokeVault} from "../../../src/interfaces/ISpokeVault.sol";
import {SpokeVaultTypes} from "../../../src/spoke/SpokeVaultTypes.sol";
import {TransferKind, BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice [H-08] (spoke-b report H-02), ported to main. The spoke Operating Cash sink seen end to end through the hub.
///         STILL_PRESENT (register S-5, Open, founder decision): `setOperatingCashParameters` is unbounded and any
///         arrival, a stranger's 1 USDG fill included, runs the top-up, so one parameter change moves the whole spoke
///         Unallocated Balance out of Share Assets and the freed Spoke Cap lets it repeat. FIXED part (S-5 interim):
///         `releaseOperatingCash` returns it above the floor and the hub re-counts it on the next report.
contract H02_SpokeOperatingCashDeadEnd is SpokeBFixture {
    function setUp() public override {
        super.setUp();
        _deposit(alice, 1_000_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        _reportNow();
    }

    function _reportNow() internal {
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
    }

    function test_POC_REVIEW_H08_oneParameterChangeSinksTheSpokeAndTheCapLetsItRepeat() public {
        uint256 assetsBefore = vault.shareAssets();
        assertEq(assetsBefore, 997_450e6);

        // 1. The manager raises the spoke's floor and top-up (DEC-096 lets it adjust them; no bound).
        vm.prank(manager);
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);

        // 2. Anyone's arrival runs the top-up: a stranger self-relays 1 USDG to the Spoke Vault.
        _dustArrival();
        assertEq(spoke.unallocatedBalance(address(usdg)), 0, "every USDG of principal left Unallocated Balance");
        assertEq(spoke.operatingCash(), 99_951e6);

        // 3. On the next report the hub drops it from Share Assets (and from the Spoke Cap).
        _reportNow();
        uint256 assetsAfter = vault.shareAssets();
        console2.log("share assets before", assetsBefore);
        console2.log("share assets after ", assetsAfter);
        assertEq(assetsBefore - assetsAfter, 99_951e6, "10% of the fund left Share Assets");

        // 4. A send home cannot debit it, the sweep never takes it, and lowering the parameters alone changes nothing.
        vm.startPrank(manager);
        vm.expectRevert(
            abi.encodeWithSelector(ISpokeVault.InsufficientUnallocatedBalance.selector, address(usdg), 0, 50_000e6)
        );
        spoke.sendToHub(
            50_000e6, TransferKind.Principal, 0, BridgeQuote(49_975e6, uint32(block.timestamp), 0, address(0))
        );
        spoke.setOperatingCashParameters(0, 0);
        vm.stopPrank();
        assertEq(spoke.sweepExcess(address(usdg)), 0, "ledger, never swept");
        assertEq(spoke.operatingCash(), 99_951e6);

        // 5. The Spoke Cap reads the spoke as empty, so the next full tranche goes out and meets the same fate.
        (uint256 spokeValue,,, uint256 cap) = vault.spokeCapUsage(0);
        assertEq(spokeValue, 0);
        vm.prank(manager);
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        bytes32 next = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(next, 99_950e6); // the arrival itself runs the top-up
        _reportNow();
        assertEq(spoke.operatingCash(), 199_901e6, "twice the Spoke Cap parked where nothing can reach it");
        assertGt(spoke.operatingCash(), cap);
        assertEq(vault.shareAssets(), 797_499e6, "a fifth of the fund gone: 99,951 + 99,950 sunk + 50 bridge fee");
    }

    /// @dev Regression (S-5 interim): the manager can bring the sunk cash back, and the hub re-counts it in Share
    ///      Assets on the next report; a stranger cannot release.
    function test_REVIEW_S5_releaseOperatingCashReturnsItAndTheHubReCountsIt() public {
        uint256 assetsBefore = vault.shareAssets();
        vm.prank(manager);
        spoke.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        _dustArrival();
        _reportNow();
        assertEq(assetsBefore - vault.shareAssets(), 99_951e6, "sunk");

        // A stranger cannot release.
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(ISpokeVault.NotManager.selector, stranger));
        spoke.releaseOperatingCash(1);

        // The manager lowers the floor and releases everything above it back to Unallocated Balance.
        uint256 cash = spoke.operatingCash();
        vm.startPrank(manager);
        spoke.setOperatingCashParameters(5e6, 10e6);
        spoke.releaseOperatingCash(cash - 5e6);
        vm.stopPrank();
        assertEq(spoke.unallocatedBalance(address(usdg)), cash - 5e6);

        // The next report carries the principal again; the hub's Share Assets recover all but the 5 USDG floor.
        _reportNow();
        assertEq(assetsBefore - vault.shareAssets(), 5e6, "only the Operating Cash floor stays out of Share Assets");
    }
}
