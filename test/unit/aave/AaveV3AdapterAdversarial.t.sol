// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {AaveV3Adapter} from "../../../src/adapters/AaveV3Adapter.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {MockAaveV3Pool, MockAToken, MockAaveAsset} from "../../mocks/aave/MockAaveV3Pool.sol";
import {AaveV3AdapterFixture} from "./AaveV3Adapter.t.sol";

/// @notice Asset whose `transfer` calls back into a contract recipient, standing in for a token with transfer hooks.
///         USDC has none; the test uses it only to exercise the adapter's reentrancy guard.
contract ReentrantAaveAsset is MockAaveAsset {
    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to.code.length != 0) ReentrantVault(to).onTokens();
        return ok;
    }
}

/// @notice Contract vault that re-enters the adapter when it receives tokens and records how the adapter answered.
contract ReentrantVault {
    AaveV3Adapter public adapter;
    bytes32 public key;
    uint8 public verb; // 0: none, 1: collectIncome, 2: decreasePosition, 3: closePosition, 4: increasePosition
    bytes4 public recordedError;
    uint256 public reentered;

    function arm(AaveV3Adapter adapter_, bytes32 key_, uint8 verb_) external {
        adapter = adapter_;
        key = key_;
        verb = verb_;
    }

    function onTokens() external {
        if (verb == 0) return;
        uint8 v = verb;
        verb = 0; // one attempt
        ++reentered;
        bytes memory data;
        if (v == 1) data = abi.encodeCall(IAdapter.collectIncome, (key));
        else if (v == 2) data = abi.encodeCall(IAdapter.decreasePosition, (key, abi.encode(uint256(1))));
        else if (v == 3) data = abi.encodeCall(IAdapter.closePosition, (key, ""));
        else data = abi.encodeCall(IAdapter.increasePosition, (key, ""));
        (bool ok, bytes memory ret) = address(adapter).call(data);
        require(!ok, "reentrant call succeeded");
        recordedError = bytes4(ret);
    }
}

/// @notice Adversarial round 1: donation ordering, reserve liquidity below pending income, reentrancy through a
///         hooked asset, extreme index and amount values, and phantom income from rounding.
contract AaveV3AdapterAdversarialTest is AaveV3AdapterFixture {
    function _rounding() internal pure override returns (MockAaveV3Pool.Rounding) {
        return MockAaveV3Pool.Rounding.Directional;
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-080: asset donated to the adapter before an entry verb
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-080: with an explicit amount, asset a stranger sent to the adapter is handed back to the vault unreported
    /// and never becomes principal.
    function test_DEC080_donatedAssetWithExplicitAmountGoesBackUnreported() public {
        asset.mint(address(adapter), 7);
        uint256 before = _vaultBalance();
        _fund(1000e6);
        vm.prank(vault);
        (, uint256 used0,) = adapter.openPosition(key, abi.encode(uint256(1000e6)));
        assertEq(used0, 1000e6);
        assertEq(adapter.ledger(address(asset)).principal, 1000e6);
        assertEq(before - _vaultBalance(), 1000e6 - 7, "donation returned with the unused amount");
        _assertAdapterHoldsNothing();
    }

    /// DEC-080 (finding, round 1): with empty params the adapter reads its own `balanceOf` to size the supply, so a
    /// stranger's 1-unit donation is reported as principal and `used0` exceeds what the vault sent. Documented here so
    /// the vault side never relies on the empty-params path; see the verifier's finding on `_supply`.
    function test_DEC080_openWithEmptyParamsReportsDonatedAssetAsPrincipal() public {
        asset.mint(address(adapter), 1);
        _fund(1000e6);
        vm.prank(vault);
        (, uint256 used0,) = adapter.openPosition(key, "");
        assertEq(used0, 1000e6 + 1, "used0 above the amount the vault transferred");
        assertEq(adapter.ledger(address(asset)).principal, 1000e6 + 1);
    }

    /// DEC-080: aTokens donated while a position is open never leak into a partial decrease, its ledger, or the
    /// income counter; the later close pays them out unreported.
    function test_DEC080_donatedATokensDoNotLeakIntoPartialDecrease() public {
        _open(1000e6);
        address donor = makeAddr("donor");
        asset.mint(donor, 300e6);
        vm.startPrank(donor);
        asset.approve(address(pool), 300e6);
        pool.supply(address(asset), 300e6, donor, 0);
        uint256 donatedScaled = aToken.scaledBalanceOf(donor);
        aToken.transfer(address(adapter), aToken.balanceOf(donor));
        vm.stopPrank();
        _grow(RAY * 11 / 10);

        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(250e6)));
        assertEq(a.principal0, 250e6);
        assertEq(a.income0, 100e6);
        assertEq(_vaultBalance() - before, 350e6);
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertEq(l.principal, 750e6);
        assertEq(aToken.scaledBalanceOf(address(adapter)) - l.scaledBalance, donatedScaled, "donation still apart");
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);

        before = _vaultBalance();
        vm.prank(vault);
        a = adapter.closePosition(key, "");
        uint256 received = _vaultBalance() - before;
        assertApproxEqAbs(a.principal0, 750e6, 2);
        assertLe(a.income0, 1);
        assertApproxEqAbs(received - a.principal0 - a.income0, 330e6, 2, "donation paid unreported");
        assertLe(adapter.cumulativeIncome(address(asset)), 100e6 + 1);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // DEC-068: reserve liquidity below the pending income
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-068 (finding, round 1): every exit verb withdraws the whole pending income on top of what was asked, so
    /// once the reserve's available liquidity drops below the pending income no principal can be served at all, not
    /// even one unit, and `collectIncome` reverts too. The "pay what is possible" reading of DEC-068 has nothing to
    /// pay with until liquidity returns. Documented behaviour of the current design.
    function test_DEC068_pendingIncomeAboveReserveLiquidityLocksEveryExit() public {
        _open(1000e6);
        _grow(RAY * 11 / 10); // 100e6 of pending income
        aToken.lendOut(makeAddr("borrower"), asset.balanceOf(address(aToken)) - 60e6);
        assertEq(asset.balanceOf(address(aToken)), 60e6, "reserve keeps 60 of liquidity");

        vm.startPrank(vault);
        vm.expectRevert();
        adapter.decreasePosition(key, abi.encode(uint256(1)));
        vm.expectRevert();
        adapter.collectIncome(key);
        vm.expectRevert();
        adapter.closePosition(key, "");
        vm.stopPrank();

        // The reserve could have served 60 of principal; the adapter has no verb that asks for it.
        assertEq(adapter.positionValue(key).principal0, 1000e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Reentrancy through a hooked asset and a contract vault
    // ---------------------------------------------------------------------------------------------------------------

    function _reentrantSetup(uint8 verb) internal returns (ReentrantVault rv, AaveV3Adapter adp, MockAToken at) {
        ReentrantAaveAsset token = new ReentrantAaveAsset();
        MockAaveV3Pool p = new MockAaveV3Pool(_rounding());
        at = p.listReserve(address(token));
        rv = new ReentrantVault();
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        adp = new AaveV3Adapter(address(rv), guardian, address(p), assets);
        bytes32 k = bytes32(uint256(uint160(address(token))));

        token.mint(address(adp), 1000e6);
        vm.prank(address(rv));
        adp.openPosition(k, abi.encode(uint256(1000e6)));
        // 10% growth, funded in the reserve.
        p.setIndex(address(token), RAY * 11 / 10);
        token.mint(address(at), 200e6);
        rv.arm(adp, k, verb);
    }

    /// Reentrancy: a token hook lets the vault re-enter every value-moving verb while a withdrawal is paying it; the
    /// guard rejects each attempt and the outer verb completes with the right amounts.
    function test_DEC053_reentrantVaultDuringWithdrawalIsRejected() public {
        for (uint8 verb = 1; verb <= 4; ++verb) {
            (ReentrantVault rv, AaveV3Adapter adp,) = _reentrantSetup(verb);
            bytes32 k = bytes32(uint256(uint160(adp.reserveAssets()[0])));
            vm.prank(address(rv));
            IAdapter.Amounts memory a = adp.collectIncome(k);
            assertEq(a.income0, 100e6);
            assertEq(rv.reentered(), 1, "hook did not fire");
            assertEq(rv.recordedError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "guard missing");
            assertEq(adp.ledger(adp.reserveAssets()[0]).principal, 1000e6);
        }
    }

    /// Reentrancy during a supply: the excess refund to the vault fires the hook inside `openPosition`; the nested
    /// verbs are rejected and the ledger is the one of a single open.
    function test_DEC053_reentrantVaultDuringSupplyRefundIsRejected() public {
        ReentrantAaveAsset token = new ReentrantAaveAsset();
        MockAaveV3Pool p = new MockAaveV3Pool(_rounding());
        p.listReserve(address(token));
        ReentrantVault rv = new ReentrantVault();
        address[] memory assets = new address[](1);
        assets[0] = address(token);
        AaveV3Adapter adp = new AaveV3Adapter(address(rv), guardian, address(p), assets);
        bytes32 k = bytes32(uint256(uint160(address(token))));
        rv.arm(adp, k, 3);

        token.mint(address(adp), 1000e6);
        vm.prank(address(rv));
        (, uint256 used0,) = adp.openPosition(k, abi.encode(uint256(900e6)));
        assertEq(used0, 900e6);
        assertEq(rv.reentered(), 1);
        assertEq(rv.recordedError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(adp.positionKeys().length, 1);
        assertEq(token.balanceOf(address(rv)), 100e6);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Extreme values and rounding
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-068, Q60: extreme starting index (up to 1000x ray), extreme amounts (up to 1e12 USDC) and a large growth
    /// step: income is exactly value minus principal, principal never grows, cumulative income never regresses and
    /// the collect pays exactly what was measured.
    function testFuzz_DEC068_Q60_extremeIndexAndAmountsKeepIncomeExact(
        uint256 amount,
        uint256 startBps,
        uint256 growBps
    ) public {
        amount = bound(amount, 1e6, 1e18); // at least one scaled unit at a 1000x index
        uint256 start = RAY + RAY * bound(startBps, 0, 9_990_000) / 10_000; // 1x to 1000x
        uint256 growth = start + start * bound(growBps, 0, 100_000) / 10_000; // up to 11x more
        _grow(start);
        _open(amount);

        IAdapter.PositionValue memory v0 = adapter.positionValue(key);
        assertLe(v0.principal0, amount, "principal grew at open");
        assertGe(v0.principal0 + 1000, amount, "principal lost beyond rounding at open");
        assertEq(v0.income0, 0, "phantom income at open");

        _grow(growth);
        IAdapter.PositionValue memory v1 = adapter.positionValue(key);
        uint256 value = adapter.ledger(address(asset)).scaledBalance * growth / RAY;
        assertEq(v1.principal0 + v1.income0, value, "value is scaled times index");
        assertLe(v1.principal0, amount);
        uint256 cumulativeBefore = adapter.cumulativeIncome(address(asset));
        assertEq(cumulativeBefore, v1.income0);

        uint256 before = _vaultBalance();
        vm.prank(vault);
        IAdapter.Amounts memory a = adapter.collectIncome(key);
        assertEq(a.income0, v1.income0);
        assertEq(_vaultBalance() - before, a.income0);
        assertGe(adapter.cumulativeIncome(address(asset)), cumulativeBefore, "Q60 regression");
        assertEq(adapter.positionValue(key).income0, 0);
        _assertAdapterHoldsNothing();
    }

    /// DEC-068: with a frozen index no sequence of verbs manufactures income out of rounding; the principal comes
    /// back within the per-operation rounding loss.
    function test_DEC068_frozenIndexNeverManufacturesIncome() public {
        _grow(RAY * 137 / 100);
        _open(1_234_567_891);
        vm.startPrank(vault);
        assertEq(adapter.collectIncome(key).income0, 0);
        IAdapter.Amounts memory a = adapter.decreasePosition(key, abi.encode(uint256(1)));
        assertEq(a.income0, 0);
        assertEq(a.principal0, 1);
        a = adapter.decreasePosition(key, abi.encode(uint256(333_333_333)));
        assertEq(a.income0, 0);
        assertEq(adapter.collectIncome(key).income0, 0);
        asset.transfer(address(adapter), 10);
        (,, uint256 income0,) = adapter.increasePosition(key, "");
        assertEq(income0, 0);
        uint256 before = _vaultBalance();
        a = adapter.closePosition(key, "");
        vm.stopPrank();
        assertEq(a.income0, 0, "phantom income at close");
        assertEq(_vaultBalance() - before, a.principal0);
        assertApproxEqAbs(a.principal0, 1_234_567_891 + 10 - 1 - 333_333_333, 12);
        assertEq(adapter.cumulativeIncome(address(asset)), 0);
    }

    /// DEC-068: `decreasePosition(type(uint256).max)` empties the position but keeps the key; a later increase
    /// re-bases it from zero with no income and no stale scaled units.
    function test_DEC068_increaseAfterDecreaseMaxRestartsFromZero() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        vm.prank(vault);
        adapter.decreasePosition(key, abi.encode(type(uint256).max));
        assertEq(adapter.positionValue(key).principal0 + adapter.positionValue(key).income0, 0);

        _grow(RAY * 12 / 10);
        _fund(600e6);
        vm.prank(vault);
        (uint256 used0,, uint256 income0,) = adapter.increasePosition(key, "");
        assertEq(used0, 600e6);
        assertEq(income0, 0);
        AaveV3Adapter.Ledger memory l = adapter.ledger(address(asset));
        assertEq(l.principal, 600e6);
        assertEq(l.scaledBalance, aToken.scaledBalanceOf(address(adapter)));
        assertEq(l.realizedIncome, 100e6);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6);
        _grow(RAY * 13 / 10);
        assertEq(adapter.cumulativeIncome(address(asset)), 100e6 + 50e6);
    }

    /// DEC-053: the guardian can quarantine or deprecate but never move a unit of value.
    function test_DEC053_guardianCannotMoveValue() public {
        _open(1000e6);
        _grow(RAY * 11 / 10);
        bytes memory notVault = abi.encodeWithSelector(IAdapter.NotVault.selector, guardian);
        vm.startPrank(guardian);
        adapter.setPaused(true);
        adapter.deprecate();
        vm.expectRevert(notVault);
        adapter.collectIncome(key);
        vm.expectRevert(notVault);
        adapter.decreasePosition(key, abi.encode(uint256(1)));
        vm.expectRevert(notVault);
        adapter.closePosition(key, "");
        vm.stopPrank();
        assertEq(asset.balanceOf(guardian), 0);
    }
}
