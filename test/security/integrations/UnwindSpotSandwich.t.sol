// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {V4SwapRouter} from "../../mocks/v4/V4SwapRouter.sol";
import {HubFundFixture} from "./HubFundFixture.sol";

/// @notice A Shareholder who sandwiches its own claim in one transaction: dump WETH into the Mandate pool, claim the
///         payout (whose automatic unwind then sells the fund's WETH at the crashed price), buy the WETH back.
contract Sandwicher {
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

    /// @param wethToDump WETH sold into the pool before the claim (a flash loan in practice).
    /// @param restoreTo sqrtPriceX96 to buy the price back up to after the claim.
    function sandwichClaim(uint256 wethToDump, uint160 restoreTo) external returns (ICoreVault.PayoutReceipt memory r) {
        router.swap(key, true, -int256(wethToDump), TickMath.MIN_SQRT_PRICE + 1);
        r = core.claimPayout(0);
        router.swap(key, false, -int256(usdc.balanceOf(address(this))), restoreTo);
    }
}

/// @title Regression (security review S-2): the automatic unwind's price floor no longer follows a spot price the
///        claimant moves first
/// @notice Was PoC `test_POC_unwindSwapFloorIsRelativeToManipulatedSpot` (high, integrations lens): the unwind swap
///         was floored at `IAdapter.spotQuote` (Uniswap V4 `slot0`) less 5%, read inside the claim after any swap the
///         claimant put in front of it; a claimant who crashed the pool with flash-loaned WETH made the unwind sell
///         51.6 WETH 29.2% under the external price (victim -31,716 USDC, attacker +28,242 USDC).
/// @dev Fix (S-2, `SpokeVault._unwindSwap`): the floor is the higher of the spot quote and the Core Vault's
///      price-source value, less 5%. The test repeats the sandwich and asserts it now FAILS: the unwind swap cannot
///      execute at the crashed price, so the unwind reverts, the claim is paid from Idle only (DEC-068), the victim
///      loses nothing to the sandwich and the attacker gains nothing over an honest claim.
contract UnwindSpotSandwichTest is HubFundFixture {
    address internal victim = makeAddr("victim");
    Sandwicher internal attacker;
    bytes32 internal positionKey;

    function setUp() public override {
        super.setUp();
        // The pool's own depth: about 2,000 WETH and 5,000,000 USDC within ±50% of the price.
        (int24 lo, int24 hi) = _rangeAround(5000);
        _provideExternalLiquidity(lo, hi, 2000e18, 5_000_000e6);

        attacker = new Sandwicher(core, router, IERC20(address(weth)), IERC20(address(usdc)), key);
        _deposit(victim, 1_000_000e6);
        usdc.mint(address(attacker), 200_000e6);
        attacker.deposit(200_000e6);

        // The manager puts 95% of Idle to work in a ±10% WETH/USDC position.
        (int24 lower, int24 upper) = _rangeAround(1000);
        (positionKey,,) = _allocateAndOpen(core.freeIdle() * 95 / 100, lower, upper);
        // The market arbitrages the manager's swap away: the pool sits at the external price again.
        _arbToExternalPrice();

        // A Standard Payout above Free Idle: the claim will unwind the shortfall.
        attacker.request(150_000e6, ICoreVaultPayouts.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours);
    }

    function test_SEC_S2_unwindSwapFloorNoLongerFollowsManipulatedSpot() public {
        uint256 victimBefore = _wealth(victim);

        // Honest claim, for reference.
        uint256 snapshot = vm.snapshotState();
        attacker.claim();
        _arbToExternalPrice();
        uint256 victimHonest = _wealth(victim);
        uint256 attackerHonest = _wealth(address(attacker));
        assertGt(victimHonest + 500e6, victimBefore, "an honest unwind costs the victim at most a few hundred USDC");
        vm.revertToState(snapshot);

        // The sandwich: 1,500 WETH of flash-loaned capital, valued at the external price and netted out below.
        uint256 dump = 1500e18;
        weth.mint(address(attacker), dump);

        vm.recordLogs();
        ICoreVault.PayoutReceipt memory r = attacker.sandwichClaim(dump, startSqrtPrice);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (uint256 wethSold,) = _unwindSwap(logs);
        assertApproxEqRel(_usdcPerWeth(_spotSqrtPrice()), WETH_PRICE * 1e6, 0.001e18, "price restored");

        // S-2: the fund's WETH was not sold at the crashed price; the unwind reverted and the claim was paid from Idle.
        assertEq(wethSold, 0, "S-2: no unwind swap at the crashed spot");
        assertEq(r.unwindProceeds, 0, "S-2: nothing unwound");
        assertTrue(_emitted(logs, ICoreVaultPayouts.UnwindForPayoutFailed.selector), "S-2: the unwind reverted");

        assertGe(_wealth(victim) + 500e6, victimHonest, "S-2: the victim loses nothing to the sandwich");
        assertLe(_wealth(address(attacker)), attackerHonest + _fair(dump), "S-2: the attacker gains nothing");
    }

    function _emitted(Vm.Log[] memory logs, bytes32 selector) internal view returns (bool) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(core) && logs[i].topics[0] == selector) return true;
        }
        return false;
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
