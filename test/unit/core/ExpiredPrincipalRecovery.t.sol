// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {CoreVaultIncomeTest} from "./CoreVaultIncome.t.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {TransferKind} from "../../../src/interfaces/FundTypes.sol";
import {TransitMessage} from "../../../src/libraries/TransitMessage.sol";
import {ReportCodec} from "../../../src/libraries/ReportCodec.sol";
import {ICoreVaultLifecycle} from "../../../src/interfaces/ICoreVaultLifecycle.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {SpokeUnwindTypes} from "../../../src/spoke/SpokeUnwindTypes.sol";
import {OrderCodec} from "../../../src/libraries/OrderCodec.sol";

contract ExpiredPrincipalRecoveryTest is CoreVaultIncomeTest {
    using stdStorage for StdStorage;

    function test_G05_finalizeWaitsForReservedPrincipalRecovery() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        bytes32 principal = keccak256("closing-reservation");
        pool.fill(
            address(vault),
            address(usdc),
            100e6,
            TransitMessage.encode(FUND_ID, SPOKE, principal, TransferKind.Principal)
        );
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        vault.recoverUnlistedArrival(0, principal);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _fillIncome(HOME, 265e6);
        vault.settleIncomeWithdrawal(manager);
        _withdraw(bruno);
        vm.prank(manager);
        vault.closeFund();
        vm.prank(manager);
        vault.unwindAllAfterDeadline();
        ReportCodec.Report memory report = _spokeIncomeReport(0.1e18, 0);
        SpokeUnwindTypes.OrderResult[] memory results = new SpokeUnwindTypes.OrderResult[](1);
        results[0].requestId = vault.closureRequestId();
        results[0].attempt = 1;
        results[0].orderId = keccak256(abi.encode(OrderCodec.CLOSE, FUND_ID, results[0].requestId, uint32(1)));
        report.unwindResults = abi.encode(results);
        _deliver(report);
        vm.expectRevert(ICoreVaultLifecycle.ClosureNotReady.selector);
        vault.finalizeClosure();
        assertEq(vault.recoverUnlistedArrival(0, principal), 100e6);
        vault.finalizeClosure();
        assertEq(uint256(vault.fundState()), uint256(ICoreVaultLifecycle.FundState.Closed));
    }

    function test_G05_reservedRecoveryCannotCreditIdleAfterClosed() public {
        _deliver(_spokeIncomeReport(0.1e18, 0.1e18));
        _request(manager);
        bytes32 principal = keccak256("closed-reservation");
        pool.fill(
            address(vault),
            address(usdc),
            100e6,
            TransitMessage.encode(FUND_ID, SPOKE, principal, TransferKind.Principal)
        );
        vm.warp(block.timestamp + 5 days);
        _deliver(_spokeIncomeReport(0.1e18, 0));
        vault.recoverUnlistedArrival(0, principal);
        _deliver(_collectionReport(0.1e18, 1, 1, HOME, 0.1e18, 266e6, 265e6));
        _fillIncome(HOME, 265e6);
        vault.settleIncomeWithdrawal(manager);
        _withdraw(bruno);
        stdstore.target(address(vault)).sig("fundState()").checked_write(uint256(ICoreVaultLifecycle.FundState.Closed));
        uint256 before = vault.idle();
        uint256 held = vault.incomeCollection().heldDollars;
        assertEq(vault.recoverUnlistedArrival(0, principal), 100e6);
        assertEq(vault.idle(), before);
        assertEq(vault.incomeCollection().heldDollars, held - 100e6);
    }

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
