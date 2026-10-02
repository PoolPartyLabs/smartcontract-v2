pragma solidity 0.8.28;

import {CoreVaultIncomeTest} from "./CoreVaultIncome.t.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";

contract ExpiredPrincipalRecoveryTest is CoreVaultIncomeTest {
    function test_principalRecoveryMustNotStayReservedAfterUnrelatedIncomeCloses() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        bytes32 principal = keccak256("unlisted-principal");
        pool.fill(
            address(vault), address(usdc), 100e6, TransitMessage.encode(FUND_ID, SPOKE, principal, TransferKind.Income)
        );
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        uint256 idleBefore = vault.idle();
        assertEq(vault.recoverUnlistedArrival(0, principal), 100e6);
        assertEq(vault.idle(), idleBefore, "unresolved Income keeps an unknown arrival reserved");
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, principal));
        vault.recoverUnlistedArrival(0, principal);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertEq(vault.incomeCollection().openResults, 1);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, principal));
        vault.recoverUnlistedArrival(0, principal);
        _fillIncome(HOME, 265e6);
        vault.settleIncomeWithdrawal(manager);
        _withdraw(bruno);
        assertEq(vault.incomeCollection().openResults, 0);
        assertEq(vault.incomeCollection().pendingSpokes, 0);
        assertEq(vault.incomeToken(1, address(spokeWeth)).recognized, 0);
        vm.prank(caio);
        assertEq(vault.recoverUnlistedArrival(0, principal), 100e6);
        assertEq(vault.idle(), idleBefore + 100e6, "expired Principal remains reachable without its listing");
        assertLe(vault.incomeCollection().heldDollars, 2, "only Income rounding dust remains held");
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc());
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, principal));
        vault.recoverUnlistedArrival(0, principal);
        ReportCodec.Report memory late = _spokeIncomeReport(0.1e18, 0);
        late = _inFlightToHub(late, principal, 100e6, TransferKind.Principal);
        _deliver(late);
        assertEq(vault.idle(), idleBefore + 100e6, "a late authenticated listing cannot credit Principal twice");
    }

    function test_retryWaitsForRecognizedIncomeOnEverySource() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        bytes32 principal = keccak256("reserved-principal");
        pool.fill(
            address(vault),
            address(usdc),
            100e6,
            TransitMessage.encode(FUND_ID, SPOKE, principal, TransferKind.Principal)
        );
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        uint256 idleBefore = vault.idle();
        vault.recoverUnlistedArrival(0, principal);
        assertEq(vault.incomeCollection().pendingSpokes, 0);
        assertEq(vault.incomeCollection().openResults, 0);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, principal));
        vault.recoverUnlistedArrival(0, principal);
        _earnHubIncome(address(usdc), 100e6);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _fillIncome(HOME, 265e6);
        _deposit(caio, 100e6);
        assertGt(vault.incomeToken(0, address(usdc)).recognized, 0);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, principal));
        vault.recoverUnlistedArrival(0, principal);
        _collectHubIncome();
        assertEq(vault.recoverUnlistedArrival(0, principal), 100e6);
        assertEq(vault.idle(), idleBefore + 200e6);
        assertGe(usdc.balanceOf(address(vault)), _ledgerUsdc());
    }

    function test_genuineRecoveredIncomeCannotBeReleasedBeforeItsResult() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        pool.fill(
            address(vault), address(usdc), 265e6, TransitMessage.encode(FUND_ID, SPOKE, HOME, TransferKind.Principal)
        );
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        uint256 idleBefore = vault.idle();
        vault.recoverUnlistedArrival(0, HOME);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, HOME));
        vault.recoverUnlistedArrival(0, HOME);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        assertApproxEqAbs(vault.settleIncomeWithdrawal(manager), 119.25e6, 1);
        assertApproxEqAbs(_withdraw(bruno), 119.25e6, 1);
        assertEq(vault.idle(), idleBefore, "genuine Income never becomes Principal");
        assertLe(vault.incomeCollection().heldDollars, 2);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.NothingToRecover.selector, HOME));
        vault.recoverUnlistedArrival(0, HOME);
    }
}
