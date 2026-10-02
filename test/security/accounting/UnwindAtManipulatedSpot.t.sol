// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
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
        receipt = core.requestPayout(1_000_000_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        pool.setTick(poolId, fairTick);
        pool.setSwap(fairRate, 10_000);
    }
}

/// @notice DEC-136/137 regression: a manipulated position pool cannot select the unwind sale's venue or size.
/// @dev Only the share-based fraction leaves the position; the Mandate swap adapter sells its non-base principal.
contract UnwindAtManipulatedSpotPoC is AccountingPocFixture {
    int24 internal constant HALF_WIDTH = 4050;
    /// @dev 1.0001^-5110 = 0.60: the pool's WETH price is pushed 40 % below the oracle price.
    int24 internal constant TICK_MOVED = TICK_FAIR - 5110;

    function setUp() public {
        _deployFund(2000, 25);
    }

    function test_SEC_S2_claimantCanNoLongerMakeTheFundSellAtTheMovedSpot() public {
        UnwindSandwichAttacker mallory = new UnwindSandwichAttacker();
        _deposit(alice, 1_000_000e6);
        usdc.mint(address(mallory), 100_000e6);
        _refreshPrices();
        mallory.enter(core, usdc, 100_000e6);
        bytes32 positionKey = _openHubPosition(1_090_000e6, HALF_WIDTH);
        assertEq(core.freeIdle(), SEED_IDLE + 7250e6, "Free Idle is far below Mallory's share value");

        uint256 aliceFair = _valueOf(alice);
        uint128 liquidityBefore = hubV4.positionValue(positionKey).liquidity;

        uint160 sqrtMoved = TickMath.getSqrtPriceAtTick(TICK_MOVED);
        uint256 movedRate = Math.mulDiv(Math.mulDiv(sqrtMoved, sqrtMoved, 1 << 96), 1e18, 1 << 96);
        assertApproxEqRel(movedRate, wethPrice1e18 * 60 / 100, 0.01e18, "the moved spot is 60 % of the oracle price");

        ICoreVault.PayoutReceipt memory r =
            mallory.claimInsideSandwich(core, v4, hubPoolId, TICK_FAIR, wethPrice1e18, TICK_MOVED, movedRate);

        assertGt(r.unwindProceeds, 0, "DEC-136: the independent swap adapter delivers");
        assertLt(hubV4.positionValue(positionKey).liquidity, liquidityBefore, "DEC-137: only the fraction exits");
        assertGt(r.usdcGross, SEED_IDLE + 7250e6, "the unwind supplements Idle");
        assertEq(shares.balanceOf(address(mallory)), 0, "the balance cap serves the holder's entire balance");
        assertGe(_valueOf(alice) + 1e6, aliceFair, "S-2: Alice keeps her value");
    }

    /// @dev Principal of the position at the current spot, valued at the oracle price (what Share Assets count).
    function _positionFairValue(bytes32 positionKey) internal view returns (uint256) {
        IAdapter.PositionValue memory v = hubV4.positionValue(positionKey);
        return Math.mulDiv(v.principal0, wethPrice1e18, 1e18) + v.principal1;
    }
}
