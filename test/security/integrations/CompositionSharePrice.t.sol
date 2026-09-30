// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {Sandwicher} from "./UnwindSpotSandwich.t.sol";
import {HubFundFixture} from "./HubFundFixture.sol";

/// @title Regression (security review S-1): the hub position's composition at a manipulated spot no longer inflates
///        the Share Price of a claim
/// @notice Was PoC `test_POC_spotCompositionInflatesSharePriceForAClaim` (medium, integrations lens): Share Assets
///         valued a hub Uniswap V4 position as `principal0 * price(WETH) + principal1` with the split taken at the
///         pool's `slot0`, a convex function of the pool price with its minimum at the external price, so a claimant
///         who pushed the pool to the edge of the fund's range inside the claim transaction burned fewer shares for the
///         same USDC (measured: 27,154 USDC of inflation, victim -11,031 USDC).
/// @dev Fix (S-1, `CoreVaultLogic._oracleComposition`): the split is recomputed from the position's liquidity and
///      range at the price-source price. The test repeats the sandwiched claim and asserts it now FAILS: the claim is
///      priced at the external-price value, burns what the honest claim burns, and the other holder loses nothing.
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

    function test_SEC_S1_spotCompositionNoLongerInflatesSharePriceForAClaim() public {
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
        ICoreVault.PayoutReceipt memory gamed = attacker.sandwichClaim(dump, startSqrtPrice);
        assertApproxEqRel(_usdcPerWeth(_spotSqrtPrice()), WETH_PRICE * 1e6, 0.001e18, "price restored");
        assertEq(gamed.unwindProceeds, 0, "paid from Idle");

        // The claim is priced at the fund's value at the external price and burns what the honest claim burns.
        assertApproxEqAbs(gamed.shareAssets, assetsAtExternalPrice, 1e6, "S-1: Share Assets not inflated by the push");
        assertApproxEqAbs(gamed.usdcPaid, honest.usdcPaid, 1e6, "same USDC paid");
        assertGe(gamed.sharesBurned, honest.sharesBurned, "S-1: no fewer shares burned than the honest claim");
        assertGe(_wealth(victim) + 1e6, victimHonest, "S-1: the other holder lost nothing to the push");
        assertLe(_wealth(address(attacker)), attackerHonest + _fair(dump), "S-1: the attacker gained nothing");
    }
}
