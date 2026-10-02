// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IManagerFeeVault} from "../../../src/interfaces/IManagerFeeVault.sol";
import {ManagerFeeVault} from "../../../src/core/ManagerFeeVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice Ruling 2026-09-29: the income index advances only when collected income reaches the Core Vault, and the
///         performance fee is split right there (protocol slice to the Protocol Recipient, the rest to the fund's
///         ManagerFeeVault, the net into the shareholders' accumulator).
contract CoreVaultIncomeTest is CoreVaultFixture {
    ManagerFeeVault internal feeVault;
    /// @dev Protocol Recipient balance after the setUp deposit (its 25 USDC flow fee, DEC-106).
    uint256 internal protocolUsdc0;

    /// @dev Alice's 9,975 shares out of 9,976: the manager's seed share takes the rest of every distribution (DEC-127).
    function _alicePart(uint256 distributed) internal pure returns (uint256) {
        return distributed * 9975 / 9976;
    }

    function setUp() public override {
        super.setUp();
        _deposit(alice, 10_000e6);
        feeVault = ManagerFeeVault(vault.managerFeeVault());
        protocolUsdc0 = usdc.balanceOf(protocol);
    }

    function test_DEC107_threeWaySplitAtCollectionWorkedExample() public {
        // docs/OPEN-QUESTIONS.md (DEC-109 payment form): 1,000 USDC + 0.5 WETH at 20% performance and a 50% slice.
        vm.expectEmit(address(vault));
        emit ICoreVault.CollectedIncomeReceived(address(usdc), 1000e6, 100e6, 100e6, 5000);
        hubVault.forwardIncome(address(usdc), 1000e6);
        vm.expectEmit(address(vault));
        emit ICoreVault.CollectedIncomeReceived(address(weth), 0.5e18, 0.05e18, 0.05e18, 5000);
        hubVault.forwardIncome(address(weth), 0.5e18);

        // Protocol: 100 USDC + 0.05 WETH, transferred at once (on top of the deposit flow fee).
        assertEq(usdc.balanceOf(protocol) - protocolUsdc0, 100e6);
        assertEq(weth.balanceOf(protocol), 0.05e18);
        // Manager: 100 USDC + 0.05 WETH in the fund's ManagerFeeVault.
        assertEq(feeVault.balanceOf(address(usdc)), 100e6);
        assertEq(feeVault.balanceOf(address(weth)), 0.05e18);
        // Shareholders: 800 USDC + 0.4 WETH into the accumulator.
        assertEq(vault.incomeState(address(usdc)).distributed, 800e6);
        assertEq(vault.incomeState(address(weth)).distributed, 0.4e18);
        assertEq(vault.collectedIncome(address(usdc)), 800e6);
        assertEq(vault.collectedIncome(address(weth)), 0.4e18);
        assertApproxEqAbs(vault.attributedIncome(alice, address(usdc)), _alicePart(800e6), 2);
        assertApproxEqAbs(vault.attributedIncome(alice, address(weth)), _alicePart(0.4e18), 2);
        assertApproxEqAbs(
            vault.attributedIncome(alice, address(usdc)) + vault.attributedIncome(manager, address(usdc)), 800e6, 2
        );
    }

    function test_DEC109_noFeeWaitsInTheCoreVault() public {
        hubVault.forwardIncome(address(usdc), 1000e6);
        hubVault.forwardIncome(address(weth), 0.5e18);
        // Everything the Core Vault holds is Idle, cash or holders' income: no fee is owed or kept here.
        assertEq(usdc.balanceOf(address(vault)), _ledgerUsdc());
        assertEq(weth.balanceOf(address(vault)), vault.collectedIncome(address(weth)));
    }

    function test_DEC092_uncollectedIncomeNeverAdvancesTheIndex() public {
        // Hub counters and position income, and a spoke report's counters, are informational only.
        hubVault.setCumulativeIncome(address(usdc), 1000e6);
        hubVault.setPositionIncome(50e6);
        _deliver(_spokeIncome(_spokeReport(0, 0), address(usdg), 300e6));
        _deposit(bob, 1000e6);
        _request(bob, 10e6, ICoreVault.PayoutMode.Instant);
        _claim(bob);
        assertEq(vault.incomeState(address(usdc)).index, 0);
        assertEq(vault.incomeState(address(usdc)).distributed, 0);
        assertEq(vault.attributedIncome(alice, address(usdc)), 0);
        assertEq(feeVault.balanceOf(address(usdc)), 0);
    }

    function test_DEC107_managerFeeVaultWithdrawIsManagerOnly() public {
        hubVault.forwardIncome(address(weth), 0.5e18);
        assertEq(feeVault.fund(), address(vault));
        assertEq(feeVault.manager(), manager);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IManagerFeeVault.NotManager.selector, alice));
        feeVault.withdraw(address(weth), alice, 1);
        address payee = makeAddr("managerWallet");
        vm.expectEmit(address(feeVault));
        emit IManagerFeeVault.ManagerFeeWithdrawn(address(weth), payee, 0.05e18);
        vm.prank(manager);
        feeVault.withdraw(address(weth), payee, 0.05e18);
        assertEq(weth.balanceOf(payee), 0.05e18);
        assertEq(feeVault.balanceOf(address(weth)), 0);
    }

    function test_LC100_incomeWithdrawalPaysNetCollectedIncome() public {
        hubVault.forwardIncome(address(usdc), 300e6);
        vm.prank(alice);
        assertApproxEqAbs(vault.withdrawIncome(address(usdc)), _alicePart(240e6), 2);
        // What stays collected is the manager's seed share part (DEC-127), plus rounding dust.
        assertApproxEqAbs(vault.collectedIncome(address(usdc)), vault.attributedIncome(manager, address(usdc)), 2);
        // No flow fee and no Payout Fee on an Income Withdrawal (DEC-113).
        assertApproxEqAbs(usdc.balanceOf(alice), _alicePart(240e6), 2);
    }

    function test_DEC073_withdrawIncomeUnknownTokenReverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnknownIncomeToken.selector, address(usdg)));
        vault.withdrawIncome(address(usdg));
    }

    function test_DEC110_protocolSliceReadAtEveryCharge() public {
        hubVault.forwardIncome(address(usdc), 1000e6);
        registry.setSlice(2000);
        hubVault.forwardIncome(address(usdc), 1000e6);
        // First charge: 200 fee at 50%; second: 200 fee at 20%.
        assertEq(usdc.balanceOf(protocol) - protocolUsdc0, 100e6 + 40e6);
        assertEq(feeVault.balanceOf(address(usdc)), 100e6 + 160e6);
    }

    function test_DEC052_registryFailureUsesDefaultSlice() public {
        registry.setReverts(true);
        hubVault.forwardIncome(address(usdc), 1000e6);
        assertEq(usdc.balanceOf(protocol) - protocolUsdc0, 100e6);
    }

    function test_DEC110_decreasedManagerFeeAppliesFromTheNextCollection() public {
        hubVault.forwardIncome(address(usdc), 1000e6); // 200 at 20%
        vm.expectEmit(address(vault));
        emit ICoreVault.ManagerFeeDecreased(2000, 1000, 0, 0);
        vm.prank(manager);
        vault.decreaseManagerFee(1000, 0);
        assertEq(vault.performanceFeeBps(), 1000);
        hubVault.forwardIncome(address(usdc), 1000e6); // 100 at 10%
        uint256 fees = feeVault.balanceOf(address(usdc)) + usdc.balanceOf(protocol) - protocolUsdc0;
        assertEq(fees, 200e6 + 100e6);
        assertEq(vault.collectedIncome(address(usdc)), 800e6 + 900e6);
    }

    function test_DEC110_managerFeeNeverIncreases() public {
        vm.startPrank(manager);
        vm.expectRevert(ICoreVault.ManagerFeeNotDecreasing.selector);
        vault.decreaseManagerFee(2500, 0);
        vm.expectRevert(ICoreVault.ManagerFeeNotDecreasing.selector);
        vault.decreaseManagerFee(2000, 0);
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotManager.selector, alice));
        vault.decreaseManagerFee(0, 0);
    }

    function test_DEC108_managementFeeMustStayZero() public {
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ManagementFeeNotSupported.selector, 10));
        vault.decreaseManagerFee(1000, 10);
        assertEq(vault.managementFeeBps(), 0);
    }

    function test_DEC107_spokeIncomeArrivalSplitAtCollection() public {
        bytes32 homeId = keccak256("income-home");
        _deliver(
            _inFlightToHub(_spokeIncome(_spokeReport(0, 0), address(usdg), 100e6), homeId, 100e6, TransferKind.Income)
        );
        assertEq(vault.incomeState(address(usdc)).distributed, 0, "the report alone attributes nothing");
        vm.expectEmit(address(vault));
        emit ICoreVault.CollectedIncomeReceived(address(usdc), 100e6, 10e6, 10e6, 5000);
        pool.fill(
            address(vault), address(usdc), 100e6, TransitMessage.encode(FUND_ID, SPOKE, homeId, TransferKind.Income)
        );
        vm.prank(alice);
        assertApproxEqAbs(vault.withdrawIncome(address(usdc)), _alicePart(80e6), 2);
        assertEq(feeVault.balanceOf(address(usdc)), 10e6);
        assertEq(usdc.balanceOf(protocol) - protocolUsdc0, 10e6);
    }

    /// @dev A supply-0 fund exists only before the seed (inside `createFund`) or after closure (DEC-121, DEC-127).
    function test_LC32_incomeWithNoSharesIsOwnerless() public {
        _deployUnseeded(_mandate(0), _config(0));
        hubVault.forwardIncome(address(usdc), 5e6);
        assertEq(vault.ownerlessIncome(address(usdc)), 5e6);
        assertEq(vault.collectedIncome(address(usdc)), 5e6);
    }

    function test_DEC080_unbackedCollectedIncomeRefused() public {
        vm.prank(address(hubVault));
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.UnbackedCredit.selector, address(usdc), 1e6, 0));
        vault.receiveCollectedIncome(address(usdc), 1e6);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NotHubSpokeVault.selector, address(this)));
        vault.receiveCollectedIncome(address(usdc), 1e6);
    }

    function testFuzz_DEC107_everyCollectedUnitLandsInExactlyOnePlace(uint128 a, uint128 b, uint16 slice) public {
        slice = uint16(bound(slice, 0, 5000));
        registry.setSlice(slice);
        uint256 first = bound(a, 1, 1e30);
        uint256 second = bound(b, 1, 1e30);
        hubVault.forwardIncome(address(usdc), first);
        _deposit(bob, 1000e6);
        uint256 protocolBefore = usdc.balanceOf(protocol);
        hubVault.forwardIncome(address(usdc), second);
        IncomeAccumulator.TokenIncome memory t = vault.incomeState(address(usdc));
        uint256 protocolSlices = usdc.balanceOf(protocol) - protocolBefore + (protocolBefore - protocolUsdc0 - 2.5e6);
        uint256 placed = t.distributed + t.ownerless + feeVault.balanceOf(address(usdc)) + protocolSlices;
        assertEq(placed, first + second, "fee vault + protocol + accumulator = collected");
        assertEq(vault.collectedIncome(address(usdc)), t.distributed + t.ownerless);
        uint256 holders = vault.attributedIncome(alice, address(usdc)) + vault.attributedIncome(bob, address(usdc));
        assertLe(holders, t.distributed);
    }
}
