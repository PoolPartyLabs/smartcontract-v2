// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

contract CoreVaultDepositTest is CoreVaultFixture {
    function test_DEC061_firstDepositMintsAtOneUsdcPerShare() public {
        (uint256 minted, uint256 charged) = _deposit(alice, 1000e6);
        // DEC-106: 25 bps flow fee from the amount; 997.50 buys 997 whole shares at 1.00.
        assertEq(minted, 997e18);
        assertEq(charged, 997e6 + 2.5e6);
        assertEq(vault.idle(), 997e6);
        assertEq(usdc.balanceOf(protocol), 2.5e6);
        assertEq(usdc.balanceOf(alice), 0.5e6, "the remainder never leaves the wallet");
        assertEq(vault.sharePrice(), ONE);
    }

    function test_DEC061_firstDepositBelowMandateMinimumReverts() public {
        usdc.mint(alice, 99e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 99e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.BelowMinFirstDeposit.selector, 99e6, 100e6));
        vault.deposit(99e6, 0);
        vm.stopPrank();
    }

    function test_DEC035_workedExample200At109Mints183For19947() public {
        _deployFeeless();
        _deposit(alice, 1000e6);
        hubVault.setPosition(address(usdc), 90e6); // Share Assets 1,090 over 1,000 shares
        assertEq(vault.sharePrice(), 1.09e24);
        (uint256 minted, uint256 charged) = _deposit(bob, 200e6);
        assertEq(minted, 183e18);
        assertEq(charged, 199.47e6);
        assertEq(usdc.balanceOf(bob), 0.53e6);
        assertEq(minted % 1e18, 0);
    }

    function test_DEC035_depositBelowOneShareReverts() public {
        _deposit(alice, 1000e6);
        usdc.mint(bob, 1e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.DepositBelowOneShare.selector, 997_500, ONE));
        vault.deposit(1e6, 0);
        vm.stopPrank();
    }

    function test_DEC035_depositBelowMinSharesReverts() public {
        usdc.mint(alice, 1000e6);
        vm.startPrank(alice);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.SharesBelowMinimum.selector, 997e18, 998e18));
        vault.deposit(1000e6, 998e18);
        vm.stopPrank();
    }

    function test_DEC106_flowFeeWorkedExample100000() public {
        (uint256 minted,) = _deposit(alice, 100_000e6);
        assertEq(usdc.balanceOf(protocol), 250e6);
        assertEq(minted, 99_750e18);
        assertEq(vault.idle(), 99_750e6);
    }

    function test_Q57_depositRevertsOnStaleSpokeReport() public {
        _deposit(alice, 1000e6);
        _deliver(_spokeReport(0, 0));
        vm.warp(block.timestamp + MAX_REPORT_AGE + 1);
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StaleSpokeReport.selector, 0));
        vault.deposit(1000e6, 0);
        vm.stopPrank();
    }

    function test_Q57_depositRevertsOnStalePrice() public {
        _deposit(alice, 1000e6);
        _deliver(_spokeReport(10e6, 0));
        uint256 old = block.timestamp - 2 hours;
        prices.setPriceAt(address(usdg), 1e18, old);
        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 1000e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.StalePrice.selector, address(usdg), old));
        vault.deposit(1000e6, 0);
        vm.stopPrank();
    }

    function test_OQ10_mintJudgesEachPriceByItsOwnMaxAge() public {
        _deposit(alice, 1000e6);
        _deliver(_spokeReport(10e6, 0));
        prices.setPriceAt(address(usdg), 1e18, block.timestamp - 2 hours); // default bound 1 h: stale
        prices.setMaxPriceAge(address(usdg), 3 hours); // this token's feed has a longer heartbeat
        (uint256 minted,) = _deposit(bob, 1000e6);
        assertGt(minted, 0, "fresh under its own bound");
    }

    function test_DEC083_depositEventCarriesConsolidation() public {
        _deposit(alice, 1000e6);
        ReportCodec.Report memory r = _spokeReport(0, 0);
        _deliver(r);
        vm.warp(block.timestamp + 100);
        usdc.mint(bob, 500e6);
        vm.startPrank(bob);
        usdc.approve(address(vault), 500e6);
        ICoreVault.NavConsolidation memory expected;
        expected.chainsSummed = 2;
        expected.reportBlockNumbers = new uint64[](1);
        expected.reportBlockNumbers[0] = r.blockNumber;
        expected.reportSequences = new uint64[](1);
        expected.reportSequences[0] = r.sequence;
        expected.oldestReportAge = 100;
        vm.expectEmit(address(vault));
        emit ICoreVault.Deposited(bob, 498e6, 1.25e6, 498e18, ONE, 997e6, 997e18, expected);
        vault.deposit(500e6, 0);
        vm.stopPrank();
    }

    function test_DEC080_directTransferNeverChangesSharePrice() public {
        _deposit(alice, 1000e6);
        uint256 price = vault.sharePrice();
        usdc.mint(address(vault), 12_345e6);
        weth.mint(address(vault), 1e18);
        assertEq(vault.sharePrice(), price);
        (uint256 minted,) = _deposit(bob, 1000e6);
        assertEq(minted, 997e18);
    }

    function test_DEC014_anaBrunoWorkedExampleEntrantGetsNoPriorIncome() public {
        _deployFeeless();
        _deposit(ana, 10_000e6);
        assertEq(shares.balanceOf(ana), 10_000e18);
        // 1,000 USDC of income generated and collected before Bruno enters (ruling 2026-09-29: attributed at
        // collection, to the holders of that moment).
        hubVault.forwardIncome(address(usdc), 1000e6);
        (uint256 minted, uint256 charged) = _deposit(bruno, 11_000e6);
        assertEq(minted, 11_000e18, "income is outside Share Assets (DEC-092)");
        assertEq(charged, 11_000e6);
        // Q60: the Q128 index rounds down; at most one base unit of dust stays in the bucket.
        assertApproxEqAbs(vault.attributedIncome(ana, address(usdc)), 1000e6, 1);
        assertEq(vault.attributedIncome(bruno, address(usdc)), 0);
        // Ana takes it all, Bruno nothing.
        vm.prank(ana);
        assertApproxEqAbs(vault.withdrawIncome(address(usdc)), 1000e6, 1);
        vm.prank(bruno);
        assertEq(vault.withdrawIncome(address(usdc)), 0);
    }

    function test_DEC014_incomeAfterEntryIsSharedProRata() public {
        _deployFeeless();
        _deposit(ana, 10_000e6);
        _deposit(bruno, 11_000e6);
        hubVault.forwardIncome(address(usdc), 2100e6);
        assertApproxEqAbs(vault.attributedIncome(ana, address(usdc)), 1000e6, 1);
        assertApproxEqAbs(vault.attributedIncome(bruno, address(usdc)), 1100e6, 1);
    }

    function test_DEC091_supplyAlwaysWholeShares() public {
        _deposit(alice, 1234.567891e6);
        _deposit(bob, 999.999999e6);
        assertEq(shares.totalSupply() % ShareMath.WHOLE_SHARE, 0);
    }

    function testFuzz_DEC035_depositChargesOnlyWholeShares(uint256 amount, uint256 gain) public {
        amount = bound(amount, 100e6, 10_000_000e6);
        gain = bound(gain, 0, 5_000_000e6);
        _deposit(alice, 100_000e6);
        hubVault.setPosition(address(usdc), gain);
        uint256 price = vault.sharePrice();
        usdc.mint(bob, amount);
        vm.startPrank(bob);
        usdc.approve(address(vault), amount);
        (uint256 minted, uint256 charged) = vault.deposit(amount, 0);
        vm.stopPrank();
        assertEq(minted % 1e18, 0);
        assertLe(charged, amount);
        uint256 fee = amount * 25 / 10_000;
        assertEq(charged, ShareMath.usdcFor(minted, price) + fee);
        // One more share would not have been affordable (its exact price is above the net; truncated it is at least the net).
        assertGe(ShareMath.usdcFor(minted + 1e18, price), amount - fee);
    }
}
