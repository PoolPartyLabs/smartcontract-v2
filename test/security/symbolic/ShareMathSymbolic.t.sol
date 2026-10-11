// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";

/// @dev External surface so a revert can be observed as a failed call.
contract ShareMathSymbolicHarness {
    function flowFee(uint256 amount, uint256 bps) external pure returns (uint256) {
        return ShareMath.flowFee(amount, bps);
    }

    function usdcFor(uint256 shares, uint256 price) external pure returns (uint256) {
        return ShareMath.usdcFor(shares, price);
    }

    function bpsOf(uint256 amount, uint256 bps) external pure returns (uint256) {
        return ShareMath.bpsOf(amount, bps);
    }

    function sharesForDeposit(uint256 usdcNet, uint256 price) external pure returns (uint256) {
        return ShareMath.sharesForDeposit(usdcNet, price);
    }

    function sharesToBurn(uint256 usdcRequested, uint256 price) external pure returns (uint256) {
        return ShareMath.sharesToBurn(usdcRequested, price);
    }
}

/// @title Symbolic properties of ShareMath (Halmos `check_` functions)
/// @notice Run with `halmos --match-contract ShareMathSymbolicTest` (see docs/security/reports/dynamic-analysis.md).
///         Forge ignores `check_` functions; the same properties run as fuzz tests in
///         test/security/invariants/LibraryPropertyFuzz.t.sol.
/// @dev Domain: amounts up to 1e18 USDC base units (1e12 USDC), Share Price from 1 (1e-24 USDC per share) to 1e36
///      (1e12 USDC per share), supply up to 1e12 whole shares. Inside it no intermediate product leaves 256 bits, so
///      `Math.mulDiv` takes its single-word path; the 512-bit path is covered by the fuzz suites.
/// @dev Solver reality (docs/security/reports/dynamic-analysis.md): every property that sends two symbolic operands
///      through `Math.mulDiv` (a 256-bit product divided by a symbolic or large constant denominator, plus the
///      512-bit branch the solver must first rule out) is undecided by every solver tried: yices and z3 (the ones
///      Halmos ships) exhaust the 6 GB memory cap within seconds, bitwuzla stays within memory but times out on every
///      assertion query (60 s per query on the first property, 30 s or 10 s on the others to fit the run's wall
///      clock). The checks in the second half of this contract are the part of
///      ShareMath the solvers do decide: the fee at the rates in use, every revert condition, the initial price and
///      the whole-share test. The undecided properties are covered by their fuzz twins.
contract ShareMathSymbolicTest is Test {
    uint256 internal constant WHOLE = 1e18;
    uint256 internal constant MAX_USDC = 1e18;
    uint256 internal constant MAX_PRICE = 1e36;
    uint256 internal constant MAX_WHOLE_SHARES = 1e12;

    ShareMathSymbolicHarness internal h;

    function setUp() public {
        h = new ShareMathSymbolicHarness();
    }

    /// DEC-035, DEC-091: a mint is whole shares and the depositor is never charged more than the net amount offered
    /// (rounding against the actor: the share count is floored, then its USDC value is floored).
    function check_DEC035_mintIsWholeAndNeverOvercharges(uint256 usdcNet, uint256 price) public pure {
        vm.assume(usdcNet <= MAX_USDC);
        vm.assume(price != 0 && price <= MAX_PRICE);
        uint256 shares = ShareMath.sharesForDeposit(usdcNet, price);
        assert(shares % WHOLE == 0);
        assert(ShareMath.usdcFor(shares, price) <= usdcNet);
    }

    /// DEC-077: a burn is whole shares and its USDC value never exceeds the amount requested.
    function check_DEC077_burnIsWholeAndNeverPaysAboveRequest(uint256 usdcRequested, uint256 price) public pure {
        vm.assume(usdcRequested <= MAX_USDC);
        vm.assume(price != 0 && price <= MAX_PRICE);
        uint256 shares = ShareMath.sharesToBurn(usdcRequested, price);
        assert(shares % WHOLE == 0);
        assert(ShareMath.usdcFor(shares, price) <= usdcRequested);
    }

    /// DEC-035, DEC-077: minting and burning the same shares at one price never pays out more than was charged, and
    /// asking back exactly what was charged never burns more shares than were minted.
    function check_DEC077_mintThenBurnAtOnePriceNeverProfits(uint256 usdcNet, uint256 price) public pure {
        vm.assume(usdcNet <= MAX_USDC);
        vm.assume(price != 0 && price <= MAX_PRICE);
        uint256 shares = ShareMath.sharesForDeposit(usdcNet, price);
        uint256 charged = ShareMath.usdcFor(shares, price);
        uint256 burned = ShareMath.sharesToBurn(charged, price);
        assert(burned <= shares);
        assert(ShareMath.usdcFor(burned, price) <= charged);
    }

    /// DEC-084, DEC-104: a deposit priced from (Share Assets, supply) never raises the Share Price, so burning the
    /// minted shares right after pays at most what they cost (no round-trip profit at the vault's own price).
    function check_DEC084_mintThenBurnAtVaultPriceNeverProfits(
        uint256 shareAssets,
        uint256 wholeSupply,
        uint256 usdcNet
    ) public pure {
        vm.assume(shareAssets <= MAX_USDC);
        vm.assume(wholeSupply != 0 && wholeSupply <= MAX_WHOLE_SHARES);
        vm.assume(usdcNet <= MAX_USDC);
        uint256 supply = wholeSupply * WHOLE;
        uint256 price = ShareMath.sharePrice(shareAssets, supply);
        vm.assume(price != 0);
        uint256 shares = ShareMath.sharesForDeposit(usdcNet, price);
        vm.assume(shares <= MAX_WHOLE_SHARES * WHOLE);
        uint256 charged = ShareMath.usdcFor(shares, price);
        uint256 priceAfter = ShareMath.sharePrice(shareAssets + charged, supply + shares);
        assert(priceAfter <= price);
        assert(ShareMath.usdcFor(shares, priceAfter) <= charged);
    }

    /// DEC-061: the USDC value of whole shares never decreases when the share count grows.
    function check_DEC061_usdcForMonotonicInShares(uint256 wholeA, uint256 wholeB, uint256 price) public pure {
        vm.assume(wholeA <= wholeB && wholeB <= MAX_WHOLE_SHARES);
        vm.assume(price <= MAX_PRICE);
        assert(ShareMath.usdcFor(wholeA * WHOLE, price) <= ShareMath.usdcFor(wholeB * WHOLE, price));
    }

    /// DEC-061: the USDC value of whole shares never decreases when the Share Price grows.
    function check_DEC061_usdcForMonotonicInPrice(uint256 whole, uint256 priceA, uint256 priceB) public pure {
        vm.assume(whole <= MAX_WHOLE_SHARES);
        vm.assume(priceA <= priceB && priceB <= MAX_PRICE);
        assert(ShareMath.usdcFor(whole * WHOLE, priceA) <= ShareMath.usdcFor(whole * WHOLE, priceB));
    }

    /// DEC-084: the whole supply valued at the Share Price never exceeds Share Assets (the price rounds down).
    function check_DEC084_supplyValueNeverExceedsShareAssets(uint256 shareAssets, uint256 wholeSupply) public pure {
        vm.assume(shareAssets <= MAX_USDC);
        vm.assume(wholeSupply != 0 && wholeSupply <= MAX_WHOLE_SHARES);
        uint256 supply = wholeSupply * WHOLE;
        assert(ShareMath.usdcFor(supply, ShareMath.sharePrice(shareAssets, supply)) <= shareAssets);
    }

    /// DEC-106, DEC-110: the flow fee is at most 1% of the amount and a rate above the cap always reverts.
    function check_DEC110_flowFeeAtMostOnePercent(uint256 amount, uint256 bps) public view {
        vm.assume(amount <= MAX_USDC);
        if (bps <= ShareMath.MAX_FLOW_FEE_BPS) {
            uint256 fee = ShareMath.flowFee(amount, bps);
            assert(fee * 100 <= amount);
        } else {
            (bool ok,) = address(h).staticcall(abi.encodeCall(h.flowFee, (amount, bps)));
            assert(!ok);
        }
    }

    /// DEC-035, DEC-106: a deposit never charges more than the amount offered (fee plus the cost of the shares).
    function check_DEC106_previewDepositNeverChargesAboveAmount(uint256 usdcAmount, uint256 bps, uint256 price)
        public
        pure
    {
        vm.assume(usdcAmount <= MAX_USDC);
        vm.assume(bps <= ShareMath.MAX_FLOW_FEE_BPS);
        vm.assume(price != 0 && price <= MAX_PRICE);
        (uint256 shares, uint256 usdcForShares, uint256 fee) = ShareMath.previewDeposit(usdcAmount, bps, price);
        assert(shares % WHOLE == 0);
        assert(fee + usdcForShares <= usdcAmount);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // Properties the bundled solvers decide
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-106, DEC-110: at the default rate (25 bps) the flow fee is within the 1% cap for every amount of the domain.
    /// (The tight bounds, 0.25% at the default rate and 1% at the cap, time out: see the report.)
    function check_DEC110_flowFeeAtTheDefaultRateIsWithinTheCap(uint256 amount) public pure {
        vm.assume(amount <= MAX_USDC);
        assert(ShareMath.flowFee(amount, ShareMath.DEFAULT_FLOW_FEE_BPS) * 100 <= amount);
    }

    /// DEC-110: a flow fee rate above the 1% cap reverts for every amount, with no bound on the amount.
    function check_DEC110_flowFeeAboveCapAlwaysReverts(uint256 amount, uint256 bps) public view {
        vm.assume(bps > ShareMath.MAX_FLOW_FEE_BPS);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.flowFee, (amount, bps)));
        assert(!ok);
    }

    /// A rate above 100% reverts for every amount.
    function check_DEC102_bpsOfAboveOneHundredPercentReverts(uint256 amount, uint256 bps) public view {
        vm.assume(bps > ShareMath.BPS);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.bpsOf, (amount, bps)));
        assert(!ok);
    }

    /// DEC-061: with no shares outstanding the Share Price is 1.00 USDC per whole share whatever Share Assets hold.
    function check_DEC061_noSharesMeansTheInitialPrice(uint256 shareAssets) public pure {
        assert(ShareMath.sharePrice(shareAssets, 0) == ShareMath.INITIAL_SHARE_PRICE);
    }

    /// DEC-035, DEC-077: at a zero Share Price no share is ever minted or burned, for any amount.
    function check_DEC035_zeroSharePriceNeverPricesAShare(uint256 usdc) public view {
        (bool minted,) = address(h).staticcall(abi.encodeCall(h.sharesForDeposit, (usdc, 0)));
        (bool burned,) = address(h).staticcall(abi.encodeCall(h.sharesToBurn, (usdc, 0)));
        assert(!minted && !burned);
    }

    /// DEC-091: `isWholeShares` is exactly "a multiple of 1e18".
    function check_DEC091_isWholeSharesIsTheModulo(uint256 shares) public pure {
        assert(ShareMath.isWholeShares(shares) == (shares % WHOLE == 0));
    }

    /// DEC-091: a fractional share amount can never be priced.
    function check_DEC091_fractionalSharesNeverPriced(uint256 shares, uint256 price) public view {
        vm.assume(shares % WHOLE != 0);
        (bool ok,) = address(h).staticcall(abi.encodeCall(h.usdcFor, (shares, price)));
        assert(!ok);
    }
}
