// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {AdapterGuard} from "../../../src/adapters/AdapterGuard.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {IAdapterGuard} from "../../../src/interfaces/IAdapterGuard.sol";
import {MockAaveV3Pool, MockAToken, MockAaveAsset} from "../../mocks/aave/MockAaveV3Pool.sol";

/// @notice Shared fixture: one adapter over a mock pool whose index grows.
abstract contract AaveV3AdapterFixture is Test {
    uint256 internal constant RAY = 1e27;

    MockAaveV3Pool internal pool;
    MockAaveAsset internal asset;
    MockAToken internal aToken;
    AaveV3Adapter internal adapter;
    address internal vault = makeAddr("vault");
    address internal guardian = makeAddr("guardian");
    bytes32 internal key;

    function _rounding() internal pure virtual returns (MockAaveV3Pool.Rounding);

    function setUp() public virtual {
        pool = new MockAaveV3Pool(_rounding());
        asset = new MockAaveAsset();
        aToken = pool.listReserve(address(asset));
        address[] memory assets = new address[](1);
        assets[0] = address(asset);
        adapter = new AaveV3Adapter(vault, guardian, address(pool), assets);
        key = bytes32(uint256(uint160(address(asset))));
        asset.mint(vault, 1e30);
    }

    function _fund(uint256 amount) internal {
        vm.prank(vault);
        asset.transfer(address(adapter), amount);
    }

    function _open(uint256 amount) internal {
        _fund(amount);
        vm.prank(vault);
        adapter.openPosition(key, abi.encode(amount));
    }

    /// @dev Grows the index and funds the interest in the reserve, as borrowers' repayments would.
    function _grow(uint256 index) internal {
        uint256 before = pool.toAmount(aToken.scaledTotalSupply(), pool.indexOf(address(asset)));
        pool.setIndex(address(asset), index);
        uint256 afterGrowth = pool.toAmount(aToken.scaledTotalSupply(), index);
        asset.mint(address(aToken), afterGrowth - before + 2);
    }

    function _vaultBalance() internal view returns (uint256) {
        return asset.balanceOf(vault);
    }

    function _assertAdapterHoldsNothing() internal view {
        assertEq(asset.balanceOf(address(adapter)), 0, "adapter holds asset");
        assertEq(asset.allowance(address(adapter), address(pool)), 0, "approval left");
    }
}

/// @notice Unit tests of the Aave V3 Adapter with the rounding of the live Arbitrum pool.
contract AaveV3AdapterTest is AaveV3AdapterFixture {
    function _rounding() internal pure virtual override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.Directional;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Construction and static description
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC053_constructorValidatesInputs() public {
        address[] memory assets = new address[](1);
        assets[0] = address(asset);

        vm.expectRevert(AaveV3Adapter.ZeroVault.selector);
        new AaveV3Adapter(address(0), guardian, address(pool), assets);
        vm.expectRevert(AaveV3Adapter.ZeroPool.selector);
        new AaveV3Adapter(vault, guardian, address(0), assets);
        vm.expectRevert(AdapterGuard.ZeroGuardian.selector);
        new AaveV3Adapter(vault, address(0), address(pool), assets);

        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.InvalidReserveAsset.selector, address(0)));
        new AaveV3Adapter(vault, guardian, address(pool), new address[](0));

        address[] memory withZero = new address[](1);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.InvalidReserveAsset.selector, address(0)));
        new AaveV3Adapter(vault, guardian, address(pool), withZero);

        address[] memory duplicated = new address[](2);
        duplicated[0] = address(asset);
        duplicated[1] = address(asset);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.DuplicateReserveAsset.selector, address(asset)));
        new AaveV3Adapter(vault, guardian, address(pool), duplicated);

        address[] memory unlisted = new address[](1);
        unlisted[0] = makeAddr("unlisted");
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.ReserveNotListed.selector, unlisted[0]));
        new AaveV3Adapter(vault, guardian, address(pool), unlisted);
    }

    function test_DEC058_immutableWiring() public view {
        assertEq(adapter.vault(), vault);
        assertEq(adapter.guardian(), guardian);
        assertEq(address(adapter.pool()), address(pool));
        assertEq(adapter.reserveAssets().length, 1);
        assertEq(adapter.ledger(address(asset)).aToken, address(aToken));
    }

    function test_DEC059_isExactValue() public view {
        assertTrue(adapter.isExactValue());
    }

    function test_DEC018_poolTokensSingleTokenAndUnknownPools() public {
        (address token0, address token1) = adapter.poolTokens(key);
        assertEq(token0, address(asset));
        assertEq(token1, address(0));

        bytes32 unlisted = bytes32(uint256(uint160(makeAddr("unlisted"))));
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, unlisted));
        adapter.poolTokens(unlisted);

        bytes32 dirty = key | bytes32(uint256(1) << 200);
        vm.expectRevert(abi.encodeWithSelector(IAdapter.UnknownPool.selector, dirty));
        adapter.poolTokens(dirty);
    }

    function test_DEC018_swapIsUnsupported() public {
        vm.prank(vault);
        vm.expectRevert(IAdapter.UnsupportedOperation.selector);
        adapter.swapExactInput(key, address(asset), 1, 0, "");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Access control, quarantine, deprecation
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC053_onlyVaultCallsVerbs() public {
        _open(1000e6);
        address stranger = makeAddr("stranger");
        bytes memory notVault = abi.encodeWithSelector(IAdapter.NotVault.selector, stranger);
        vm.startPrank(stranger);
        vm.expectRevert(notVault);
        adapter.openPosition(key, "");
        vm.expectRevert(notVault);
        adapter.increasePosition(key, "");
        vm.expectRevert(notVault);
        adapter.decreasePosition(key, abi.encode(uint256(1)));
        vm.expectRevert(notVault);
        adapter.closePosition(key, "");
        vm.expectRevert(notVault);
        adapter.collectIncome(key);
        vm.stopPrank();
    }

    function test_DEC056_pauseBlocksOpenAndIncreaseNeverExits() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        vm.prank(guardian);
        adapter.setPaused(true);

        _fund(10e6);
        vm.startPrank(vault);
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.increasePosition(key, "");
        adapter.collectIncome(key);
        adapter.decreasePosition(key, abi.encode(uint256(100e6)));
        adapter.closePosition(key, "");
        vm.expectRevert(IAdapterGuard.AdapterPaused.selector);
        adapter.openPosition(key, "");
        vm.stopPrank();
    }

    function test_DEC058_deprecatedIsWithdrawOnly() public {
        _open(1000e6);
        vm.prank(guardian);
        adapter.deprecate();

        _fund(10e6);
        vm.startPrank(vault);
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        adapter.increasePosition(key, "");
        adapter.decreasePosition(key, abi.encode(uint256(100e6)));
        adapter.closePosition(key, "");
        vm.expectRevert(IAdapterGuard.AdapterIsDeprecated.selector);
        adapter.openPosition(key, "");
        vm.stopPrank();
    }

    function test_DEC068_verbsOnUnknownPositionRevert() public {
        bytes memory unknown = abi.encodeWithSelector(IAdapter.UnknownPosition.selector, key);
        vm.startPrank(vault);
        vm.expectRevert(unknown);
        adapter.increasePosition(key, "");
        vm.expectRevert(unknown);
        adapter.decreasePosition(key, abi.encode(uint256(1)));
        vm.expectRevert(unknown);
        adapter.closePosition(key, "");
        vm.expectRevert(unknown);
        adapter.collectIncome(key);
        vm.stopPrank();
        vm.expectRevert(unknown);
        adapter.positionValue(key);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Open
    // ---------------------------------------------------------------------------------------------------------------

    function test_DEC068_openRecordsScaledBalancePrincipalAndIndex() public {
        _grow(RAY * 12 / 10);
        _fund(1200e6);
        vm.expectEmit(true, true, false, true, address(adapter));
        emit IAdapter.PositionOpened(key, key, 1200e6, 0);
        vm.prank(vault);
        (bytes32 positionKey, uint256 used0, uint256 used1) = adapter.openPosition(key, abi.encode(uint256(1200e6)));

        assertEq(positionKey, key);
        assertEq(used0, 1200e6);
        assertEq(used1, 0);
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertTrue(l.open);
        assertEq(l.scaledBalance, 1000e6);
        assertEq(l.scaledBalance, aToken.scaledBalanceOf(address(adapter)));
        assertEq(l.principal, 1200e6);
        assertEq(l.lastIndex, RAY * 12 / 10);

        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.poolKey, key);
        assertEq(v.poolId, key);
        assertEq(v.tickLower, 0);
        assertEq(v.tickUpper, 0);
        assertEq(uint256(v.liquidity), 1000e6);
        assertEq(v.token0, address(asset));
        assertEq(v.token1, address(0));
        assertEq(v.principal0, 1200e6);
        assertEq(v.principal1 + v.income0 + v.income1, 0);
        assertEq(adapter.positionKeys().length, 1);
        assertEq(adapter.positionKeys()[0], key);
        _assertAdapterHoldsNothing();
    }

    /// DEC-080 (final verification): the supply is never sized from the adapter's own balance; empty params revert on
    /// both entry verbs.
    function test_DEC080_emptyParamsRevertOnOpenAndIncrease() public {
        _fund(500e6);
        vm.prank(vault);
        vm.expectRevert(AaveV3Adapter.AmountRequired.selector);
        adapter.openPosition(key, "");
        vm.prank(vault);
        adapter.openPosition(key, abi.encode(uint256(500e6)));
        _fund(100e6);
        vm.prank(vault);
        vm.expectRevert(AaveV3Adapter.AmountRequired.selector);
        adapter.increasePosition(key, "");
        assertEq(adapter.ledger(address(asset)).principal, 500e6);
    }

    function test_DEC068_openReturnsUnusedToVault() public {
        uint256 before = _vaultBalance();
        _fund(500e6);
        vm.prank(vault);
        (, uint256 used0,) = adapter.openPosition(key, abi.encode(uint256(300e6)));
        assertEq(used0, 300e6);
        assertEq(before - _vaultBalance(), 300e6);
        _assertAdapterHoldsNothing();
    }

    function test_DEC068_openRejectsBadAmountsAndSecondPosition() public {
        _fund(100e6);
        vm.startPrank(vault);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.AmountAboveTransferred.selector, 101e6, 100e6));
        adapter.openPosition(key, abi.encode(uint256(101e6)));
        vm.expectRevert(AaveV3Adapter.ZeroAmount.selector);
        adapter.openPosition(key, abi.encode(uint256(0)));
        adapter.openPosition(key, abi.encode(uint256(100e6)));
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.PositionAlreadyOpen.selector, key));
        adapter.openPosition(key, abi.encode(uint256(1)));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Income
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-068: income = scaledBalance * indexNow / 1e27 - principal; principal unchanged.
    function test_DEC068_incomeIsScaledBalanceTimesIndexMinusPrincipal() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.principal0, 1000e6);
        assertEq(v.income0, 100e6);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);
        assertEq(adapter.ledger(address(asset)).lastIndex, RAY, "a read is not a measurement");
        assertEq(adapter.cumulativeIncome(makeAddr("other")), 0);
    }

    function test_DEC068_collectWithdrawsOnlyInterest() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        uint256 before = _vaultBalance();

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IAdapter.IncomeCollected(key, 100e6, 0);
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.collectIncome(key);

        assertEq(a.income0, 100e6);
        assertEq(a.principal0 + a.principal1 + a.income1, 0);
        assertEq(_vaultBalance() - before, 100e6);
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertEq(l.principal, 1000e6);
        assertEq(l.realizedIncome, 100e6);
        assertEq(l.lastIndex, RAY * 11 / 10);
        assertEq(l.scaledBalance, aToken.scaledBalanceOf(address(adapter)));
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.income0, 0);
        assertApproxEqAbs(v.principal0, 1000e6, 2);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);
        _assertAdapterHoldsNothing();
    }

    function test_DEC068_collectWithoutIncomeMakesNoPoolCall() public {
        _open(1000e6);
        uint256 calls = pool.withdrawCalls();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.collectIncome(key);
        assertEq(a.income0, 0);
        assertEq(pool.withdrawCalls(), calls);
    }

    /// DEC-068: increase pays the income out as income, then re-bases the principal.
    function test_DEC068_increaseRealizesIncomeBeforeRebase() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        uint256 before = _vaultBalance();
        _fund(550e6);

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IAdapter.PositionIncreased(key, 550e6, 0, 100e6, 0);
        vm.prank(vault);
        (uint256 used0, uint256 used1, uint256 income0, uint256 income1) =
            adapter.increasePosition(key, abi.encode(uint256(550e6)));

        assertEq(used0, 550e6);
        assertEq(used1 + income1, 0);
        assertEq(income0, 100e6);
        assertEq(before - _vaultBalance(), 450e6, "net: 550 in, 100 income out");
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertEq(l.principal, 1550e6);
        assertEq(l.realizedIncome, 100e6);
        assertEq(l.lastIndex, RAY * 11 / 10);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertApproxEqAbs(v.principal0, 1550e6, 2);
        assertLe(v.income0, 1);
        _assertAdapterHoldsNothing();
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Decrease and close
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-068, DEC-079: decrease withdraws the principal asked plus the whole income, split exactly.
    function test_DEC068_decreaseSplitsPrincipalAndIncome() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        uint256 before = _vaultBalance();

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IAdapter.PositionDecreased(key, IAdapter.Amounts(400e6, 0, 100e6, 0));
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(400e6)));

        assertEq(a.principal0, 400e6);
        assertEq(a.income0, 100e6);
        assertEq(_vaultBalance() - before, 500e6);
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertEq(l.principal, 600e6);
        assertEq(l.realizedIncome, 100e6);
        assertEq(l.scaledBalance, aToken.scaledBalanceOf(address(adapter)));
        assertApproxEqAbs(adapter.positionValue(key).principal0, 600e6, 2);
        assertEq(adapter.positionKeys().length, 1);
        _assertAdapterHoldsNothing();
    }

    function test_DEC068_decreaseRejectsBadAmounts() public {
        _open(1000e6);
        vm.startPrank(vault);
        vm.expectRevert(AaveV3Adapter.ZeroAmount.selector);
        adapter.decreasePosition(key, abi.encode(uint256(0)));
        uint256 principalNow = adapter.positionValue(key).principal0;
        vm.expectRevert(
            abi.encodeWithSelector(AaveV3Adapter.AmountAbovePrincipal.selector, principalNow + 1, principalNow)
        );
        adapter.decreasePosition(key, abi.encode(principalNow + 1));
        vm.expectRevert();
        adapter.decreasePosition(key, "");
        vm.stopPrank();
    }

    /// DEC-068: `type(uint256).max` withdraws all principal and income and leaves the key open and empty; close then
    /// pays nothing.
    function test_DEC068_decreaseMaxEmptiesPositionKeyStaysOpen() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(type(uint256).max));
        assertEq(a.principal0, 1000e6);
        assertEq(a.income0, 100e6);
        assertEq(_vaultBalance() - before, 1100e6);
        assertEq(aToken.scaledBalanceOf(address(adapter)), 0);
        assertEq(adapter.positionKeys().length, 1);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.principal0 + v.income0 + uint256(v.liquidity), 0);

        uint256 calls = pool.withdrawCalls();
        vm.prank(vault);
        a = adapter.closePosition(key, "");
        assertEq(a.principal0 + a.income0, 0);
        assertEq(pool.withdrawCalls(), calls);
        assertEq(adapter.positionKeys().length, 0);
    }

    /// DEC-068, Q60: close withdraws everything, removes the key and keeps the realized income counter; a new
    /// position can be opened afterwards and the counter keeps growing from where it was.
    function test_DEC068_closeWithdrawsEverythingAndKeepsCounter() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        uint256 before = _vaultBalance();

        vm.expectEmit(true, false, false, true, address(adapter));
        emit IAdapter.PositionClosed(key, IAdapter.Amounts(1000e6, 0, 100e6, 0));
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");

        assertEq(a.principal0, 1000e6);
        assertEq(a.income0, 100e6);
        assertEq(_vaultBalance() - before, 1100e6);
        assertEq(aToken.scaledBalanceOf(address(adapter)), 0);
        assertEq(adapter.positionKeys().length, 0);
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertFalse(l.open);
        assertEq(l.principal + l.scaledBalance, 0);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);
        _assertAdapterHoldsNothing();

        _open(1100e6);
        _grow(RAY * 121 / 100);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6 + 110e6);
    }

    /// DEC-068: a reserve without enough liquidity makes the exit revert; nothing is paid short and the ledger is
    /// intact. Partial Payout is the vault's decision.
    function test_DEC068_illiquidReserveRevertsNeverPaysLess() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        aToken.lendOut(makeAddr("borrower"), asset.balanceOf(address(aToken)) - 300e6);
        AaveV3Adapter.Ledger memory before = adapter.ledger(address(asset));
        uint256 vaultBefore = _vaultBalance();

        vm.startPrank(vault);
        vm.expectRevert();
        adapter.decreasePosition(key, abi.encode(uint256(500e6)));
        vm.expectRevert();
        adapter.closePosition(key, "");
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(200e6)));
        vm.stopPrank();

        assertEq(a.principal0, 200e6);
        assertEq(a.income0, 100e6);
        assertEq(_vaultBalance() - vaultBefore, 300e6);
        assertEq(adapter.ledger(address(asset)).principal, before.principal - 200e6);
    }

    function test_DEC068_poolPayingLessThanAskedReverts() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        pool.setPayOneLess(true);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(AaveV3Adapter.UnexpectedWithdrawnAmount.selector, 100e6, 100e6 - 1));
        adapter.collectIncome(key);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Donations (DEC-080)
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-080: aTokens sent to the adapter by anyone are not reported as principal or income and do not move the
    /// cumulative income counter; a full exit hands them to the vault unreported.
    function test_DEC080_donatedATokensNeverReported() public {
        _open(1000e6);
        address donor = makeAddr("donor");
        asset.mint(donor, 500e6);
        vm.startPrank(donor);
        asset.approve(address(pool), 500e6);
        pool.supply(address(asset), 500e6, donor, 0);
        aToken.transfer(address(adapter), aToken.balanceOf(donor));
        vm.stopPrank();

        _grow(RAY * 11 / 10);
        IAdapter.PositionValue memory v = adapter.positionValue(key);
        assertEq(v.principal0, 1000e6);
        assertEq(v.income0, 100e6);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);

        vm.prank(vault);
        IAdapter.Amounts memory c = adapter.collectIncome(key);
        assertEq(c.income0, 100e6);

        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.closePosition(key, "");
        uint256 received = _vaultBalance() - before;
        assertApproxEqAbs(a.principal0, 1000e6, 2);
        assertLe(a.income0, 1);
        assertApproxEqAbs(received - a.principal0 - a.income0, 550e6, 2, "donation paid unreported");
        assertEq(aToken.scaledBalanceOf(address(adapter)), 0);
        assertLe(adapter.cumulativeIncome(address(asset)), 100e6 + 1);
    }
}

/// @notice Same suite under the half-up rounding of Aave up to v3.4.
contract AaveV3AdapterHalfUpRoundingTest is AaveV3AdapterTest {
    function _rounding() internal pure override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.HalfUp;
    }
}
