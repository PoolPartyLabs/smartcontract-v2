// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ShareMath} from "../../src/libraries/ShareMath.sol";

/// @dev Exposes the internal library functions as external calls so reverts can be asserted.
contract ShareMathHarness {
    function sharePrice(uint256 shareAssets, uint256 totalShares) external pure returns (uint256) {
        return ShareMath.sharePrice(shareAssets, totalShares);
    }

    function sharesForDeposit(uint256 usdcNet, uint256 price) external pure returns (uint256) {
        return ShareMath.sharesForDeposit(usdcNet, price);
    }

    function usdcFor(uint256 shares, uint256 price) external pure returns (uint256) {
        return ShareMath.usdcFor(shares, price);
    }

    function sharesToBurn(uint256 usdcRequested, uint256 price) external pure returns (uint256) {
        return ShareMath.sharesToBurn(usdcRequested, price);
    }

    function flowFee(uint256 amount, uint256 bps) external pure returns (uint256) {
        return ShareMath.flowFee(amount, bps);
    }

    function bpsOf(uint256 amount, uint256 bps) external pure returns (uint256) {
        return ShareMath.bpsOf(amount, bps);
    }

    function requireWholeShares(uint256 shares) external pure {
        ShareMath.requireWholeShares(shares);
    }

    function previewDeposit(uint256 usdcAmount, uint256 flowFeeBps, uint256 price)
        external
        pure
        returns (uint256, uint256, uint256)
    {
        return ShareMath.previewDeposit(usdcAmount, flowFeeBps, price);
    }
}

contract ShareMathTest is Test {
    ShareMathHarness internal h;

    uint256 internal constant ONE_USDC = 1e6;
    uint256 internal constant ONE_SHARE = 1e18;
    /// @dev 1.00 USDC per whole share in the library's representation.
    uint256 internal constant PRICE_1_00 = 1e24;
    uint256 internal constant PRICE_1_09 = 1.09e24;
    uint256 internal constant PRICE_1_10 = 1.1e24;

    function setUp() public {
        h = new ShareMathHarness();
    }

    // ------------------------------------------------------------------ constants

    function test_DEC061_initialSharePriceIsOneUsdcPerWholeShare() public view {
        assertEq(ShareMath.INITIAL_SHARE_PRICE, PRICE_1_00);
        assertEq(h.sharePrice(0, 0), PRICE_1_00);
        assertEq(h.sharePrice(123_456e6, 0), PRICE_1_00, "no supply: initial price regardless of assets");
        assertEq(h.usdcFor(ONE_SHARE, ShareMath.INITIAL_SHARE_PRICE), ONE_USDC);
    }

    function test_DEC091_wholeShareIs1e18AndUsdcFactorIs1e12() public view {
        assertEq(ShareMath.WHOLE_SHARE, 1e18);
        // DEC-091: USDC-to-share conversion factor 1e12 at the initial price.
        assertEq(h.sharesForDeposit(ONE_USDC, PRICE_1_00), ONE_USDC * 1e12);
    }

    function test_DEC106_flowFeeDefaultAndCapConstants() public pure {
        assertEq(ShareMath.DEFAULT_FLOW_FEE_BPS, 25);
        assertEq(ShareMath.MAX_FLOW_FEE_BPS, 100);
    }

    // ------------------------------------------------------------------ worked examples

    /// DEC-035: 200 USDC at 1.09 -> 183 shares for 199.47.
    function test_DEC035_depositWorkedExample200At109Gives183SharesFor19947() public view {
        uint256 shares = h.sharesForDeposit(200 * ONE_USDC, PRICE_1_09);
        assertEq(shares, 183 * ONE_SHARE);
        assertEq(h.usdcFor(shares, PRICE_1_09), 199_470_000);
    }

    /// DEC-077: 1,000 USDC requested at 1.1 -> burn 909 shares, pay 999.90.
    function test_DEC077_burnWorkedExample1000At110Burns909Pays99990() public view {
        uint256 shares = h.sharesToBurn(1000 * ONE_USDC, PRICE_1_10);
        assertEq(shares, 909 * ONE_SHARE);
        assertEq(h.usdcFor(shares, PRICE_1_10), 999_900_000);
    }

    /// DEC-106: deposit 100,000 at 1.00 -> 250 to the protocol, 99,750 buys 99,750 shares.
    function test_DEC106_depositWorkedExample100000PaysFlowFee250() public view {
        (uint256 shares, uint256 usdcForShares, uint256 fee) = h.previewDeposit(100_000 * ONE_USDC, 25, PRICE_1_00);
        assertEq(fee, 250 * ONE_USDC);
        assertEq(shares, 99_750 * ONE_SHARE);
        assertEq(usdcForShares, 99_750 * ONE_USDC);
    }

    function test_DEC035_previewDepositRemainderStaysWithDepositor() public view {
        (uint256 shares, uint256 usdcForShares, uint256 fee) = h.previewDeposit(200 * ONE_USDC, 25, PRICE_1_09);
        assertEq(fee, 500_000); // 0.50 USDC
        assertEq(shares, 183 * ONE_SHARE); // 199.50 / 1.09 = 183.03
        assertEq(usdcForShares, 199_470_000);
        assertEq(200 * ONE_USDC - fee - usdcForShares, 30_000, "0.03 USDC never leaves the wallet (DEC-061)");
    }

    // ------------------------------------------------------------------ rules

    function test_DEC084_sharePriceIsShareAssetsOverShares() public view {
        assertEq(h.sharePrice(1090 * ONE_USDC, 1000 * ONE_SHARE), PRICE_1_09);
        assertEq(h.sharePrice(1100 * ONE_USDC, 1000 * ONE_SHARE), PRICE_1_10);
    }

    function test_DEC035_depositBelowOneSharePriceBuysZeroShares() public view {
        assertEq(h.sharesForDeposit(1_089_999, PRICE_1_09), 0);
        assertEq(h.sharesForDeposit(1_090_000, PRICE_1_09), ONE_SHARE);
    }

    function test_DEC061_usdcValueTruncatedAtSixthDecimal() public view {
        // 1.0000009 USDC per share: one share is worth 1.000000 USDC after truncation.
        uint256 price = 1_000_000.9e18;
        assertEq(h.usdcFor(ONE_SHARE, price), 1_000_000);
        assertEq(h.usdcFor(10 * ONE_SHARE, price), 10_000_009);
    }

    function test_DEC091_fractionalSharesRevert() public {
        vm.expectRevert(abi.encodeWithSelector(ShareMath.NotWholeShares.selector, ONE_SHARE + 1));
        h.usdcFor(ONE_SHARE + 1, PRICE_1_00);
        vm.expectRevert(abi.encodeWithSelector(ShareMath.NotWholeShares.selector, 5e17));
        h.requireWholeShares(5e17);
        h.requireWholeShares(0);
        h.requireWholeShares(7 * ONE_SHARE);
    }

    function test_DEC035_zeroSharePriceReverts() public {
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        h.sharesForDeposit(ONE_USDC, 0);
        vm.expectRevert(ShareMath.ZeroSharePrice.selector);
        h.sharesToBurn(ONE_USDC, 0);
        // Shares outstanding with zero Share Assets price at zero.
        assertEq(h.sharePrice(0, ONE_SHARE), 0);
    }

    function test_DEC106_flowFeeIs25BpsRoundedDown() public view {
        assertEq(h.flowFee(100_000 * ONE_USDC, 25), 250 * ONE_USDC);
        assertEq(h.flowFee(399, 25), 0, "rounded down, never overcharges");
        assertEq(h.flowFee(400, 25), 1);
    }

    function test_DEC110_flowFeeAboveOnePercentReverts() public {
        assertEq(h.flowFee(ONE_USDC, 100), 10_000);
        vm.expectRevert(abi.encodeWithSelector(ShareMath.FlowFeeAboveCap.selector, 101));
        h.flowFee(ONE_USDC, 101);
    }

    function test_DEC102_bpsOfPayoutFeeExample() public {
        // 30,000 Instant Payout at 2% -> Payout Fee 600.
        assertEq(h.bpsOf(30_000 * ONE_USDC, 200), 600 * ONE_USDC);
        vm.expectRevert(abi.encodeWithSelector(ShareMath.BpsAboveMax.selector, 10_001));
        h.bpsOf(1, 10_001);
    }

    // ------------------------------------------------------------------ fuzz

    /// DEC-035, DEC-091: whole shares, rounded down, charge never above the net amount, one more share not affordable.
    function testFuzz_DEC035_mintIsWholeFlooredAndNeverOvercharges(uint256 usdcNet, uint256 price) public view {
        usdcNet = bound(usdcNet, 0, 1e15 * ONE_USDC);
        price = bound(price, 1e18, 1e36); // 0.000001 to 1e12 USDC per share
        uint256 shares = h.sharesForDeposit(usdcNet, price);
        assertEq(shares % ONE_SHARE, 0);
        uint256 whole = shares / ONE_SHARE;
        // Exact inequalities in the scaled domain: whole * price <= net * 1e18 < (whole + 1) * price.
        assertLe(whole * price, usdcNet * 1e18);
        assertGt((whole + 1) * price, usdcNet * 1e18);
        assertLe(h.usdcFor(shares, price), usdcNet);
    }

    /// DEC-077: burn rounds down, payout never exceeds the request.
    function testFuzz_DEC077_burnNeverPaysMoreThanRequested(uint256 usdcRequested, uint256 price) public view {
        usdcRequested = bound(usdcRequested, 0, 1e15 * ONE_USDC);
        price = bound(price, 1e18, 1e36);
        uint256 shares = h.sharesToBurn(usdcRequested, price);
        assertEq(shares % ONE_SHARE, 0);
        assertLe(h.usdcFor(shares, price), usdcRequested);
        assertGt((shares / ONE_SHARE + 1) * price, usdcRequested * 1e18);
    }

    /// DEC-061, DEC-084: at the price computed from (assets, supply), the whole supply is worth at most the assets.
    function testFuzz_DEC084_supplyValueNeverExceedsShareAssets(uint256 shareAssets, uint256 wholeShares) public view {
        shareAssets = bound(shareAssets, 0, 1e15 * ONE_USDC);
        wholeShares = bound(wholeShares, 1, 1e15);
        uint256 supply = wholeShares * ONE_SHARE;
        uint256 price = h.sharePrice(shareAssets, supply);
        uint256 value = h.usdcFor(supply, price);
        assertLe(value, shareAssets);
        // Error below one USDC base unit per whole share.
        assertLe(shareAssets - value, wholeShares);
    }

    function testFuzz_DEC110_flowFeeNeverAboveOnePercent(uint256 amount, uint256 bps) public view {
        amount = bound(amount, 0, type(uint128).max);
        bps = bound(bps, 0, 100);
        assertLe(h.flowFee(amount, bps), amount / 100);
    }

    // ------------------------------------------------------------------ adversarial (verification round 1)

    /// DEC-035, DEC-061: the Share Price is rounded down, so a mint charges at most the exact value
    /// `shares * shareAssets / totalShares` and, at a price of at least 0.01 USDC per share, undercharges the
    /// depositor by at most one USDC base unit (the 6-decimal truncation the decisions accept).
    function testFuzz_DEC035_mintUnderchargesByAtMostOneBaseUnit(
        uint256 shareAssets,
        uint256 wholeShares,
        uint256 usdcNet
    ) public view {
        shareAssets = bound(shareAssets, 1e4, 1e15 * ONE_USDC);
        wholeShares = bound(wholeShares, 1, shareAssets / 1e4); // price >= 0.01 USDC per share
        usdcNet = bound(usdcNet, 0, 1e15 * ONE_USDC);
        uint256 supply = wholeShares * ONE_SHARE;
        uint256 price = h.sharePrice(shareAssets, supply);
        uint256 shares = h.sharesForDeposit(usdcNet, price);
        uint256 charged = h.usdcFor(shares, price);
        uint256 exact = Math.mulDiv(shares, shareAssets, supply);
        assertLe(charged, exact, "never charges above the exact value");
        assertGe(charged + 1, exact, "undercharge bounded by one USDC base unit");
    }

    /// DEC-077, DEC-020: a burn priced at the rounded-down Share Price never lowers the Share Price of the holders
    /// who stay, and never pays more than requested; a request above the holder's balance burns everything.
    function testFuzz_DEC077_burnNeverLowersSharePriceForRemainingHolders(
        uint256 shareAssets,
        uint256 wholeShares,
        uint256 usdcRequested
    ) public view {
        shareAssets = bound(shareAssets, 1, 1e15 * ONE_USDC);
        wholeShares = bound(wholeShares, 1, 1e15);
        uint256 supply = wholeShares * ONE_SHARE;
        uint256 price = h.sharePrice(shareAssets, supply);
        vm.assume(price != 0);
        usdcRequested = bound(usdcRequested, 0, 2 * shareAssets);
        uint256 shares = h.sharesToBurn(usdcRequested, price);
        if (shares > supply) shares = supply; // DEC-020: insufficient shares burn all
        uint256 paid = h.usdcFor(shares, price);
        assertLe(paid, usdcRequested);
        assertLe(paid, shareAssets, "never pays more than the fund holds");
        // paid / shares <= shareAssets / supply
        assertLe(paid * supply, shares * shareAssets);
        if (shares < supply) {
            assertGe(h.sharePrice(shareAssets - paid, supply - shares), price, "price of those who stay never drops");
        }
    }

    /// Boundary no decision covers: once Share Assets fall below one USDC base unit per share, the rounded-down
    /// price lets a deposit mint whole shares for a charge of zero. The library cannot tell; the Core Vault must
    /// reject a deposit whose charge is zero (reported as an open question in verification round 1).
    function test_DEC035_subUnitSharePriceMintsSharesForZeroCharge() public view {
        uint256 price = h.sharePrice(1, 3 * ONE_SHARE);
        assertEq(price, 333_333_333_333_333_333);
        uint256 shares = h.sharesForDeposit(1, price);
        assertEq(shares, 3 * ONE_SHARE);
        assertEq(h.usdcFor(shares, price), 0);
    }

    /// DEC-091: extreme inputs revert (512-bit intermediate above 2^256) instead of wrapping; the largest realistic
    /// inputs (1e15 USDC at the lowest whole-unit price) fit.
    function test_DEC091_extremeInputsRevertInsteadOfWrapping() public {
        vm.expectRevert();
        h.sharesForDeposit(type(uint256).max, 1e18);
        vm.expectRevert();
        h.sharesToBurn(type(uint256).max, 1e18);
        uint256 maxWhole = type(uint256).max - (type(uint256).max % ONE_SHARE);
        vm.expectRevert();
        h.usdcFor(maxWhole, type(uint256).max);
        assertEq(h.sharesForDeposit(1e15 * ONE_USDC, 1e18), 1e21 * ONE_SHARE);
        assertEq(h.usdcFor(1e21 * ONE_SHARE, 1e18), 1e15 * ONE_USDC);
        assertEq(h.sharePrice(1e15 * ONE_USDC, ONE_SHARE), 1e15 * PRICE_1_00);
    }

    /// DEC-061 says "1 share = 1.00 USDC at every fund's FIRST issuance". The library returns the initial price
    /// whenever supply is zero, so if every share is burned while Share Assets remain (refund landing late, dust),
    /// the next depositor buys at 1.00 and captures the residual. Documented here; the rule is OPEN.
    function test_DEC061_zeroSupplyWithResidualAssetsPricesAtInitial() public view {
        assertEq(h.sharePrice(5000e6, 0), PRICE_1_00);
        assertEq(h.sharesForDeposit(ONE_USDC, h.sharePrice(5000e6, 0)), ONE_SHARE);
    }

    // ------------------------------------------------------------------ adversarial (verification round 2)

    /// DEC-077, DEC-061: a Shareholder who requests exactly the USDC they were charged for `s` whole shares gets
    /// `s` or `s - 1` shares burned, never more (the truncation of the USDC value can push the request below `s`
    /// full share prices). At a price of at least one USDC base unit per whole share the granularity loss is at
    /// most one share; requesting "everything I paid" therefore does not always burn everything (QA23, OPEN).
    function testFuzz_DEC077_requestingExactChargeBurnsAtMostOneShareLess(uint256 wholeShares, uint256 price)
        public
        view
    {
        wholeShares = bound(wholeShares, 1, 1e15);
        price = bound(price, 1e18, 1e36);
        uint256 shares = wholeShares * ONE_SHARE;
        uint256 charged = h.usdcFor(shares, price);
        uint256 burned = h.sharesToBurn(charged, price);
        assertLe(burned, shares, "never burns more than was bought for that amount");
        assertGe(burned + ONE_SHARE, shares, "at most one whole share of granularity loss");
        // A request one base unit above the charge never crosses to s + 1 either (floor is exact).
        assertLe(h.sharesToBurn(charged + 1, price), shares + ONE_SHARE);
        // Whatever is burned, it is paid at most what was charged for it (DEC-077).
        assertLe(h.usdcFor(burned, price), charged);
    }

    /// DEC-084, DEC-061: the Share Price computed from (Share Assets, supply) is monotonic in both arguments and
    /// the supply is never worth more than Share Assets, up to `uint128` assets and 1e15 whole shares (far beyond
    /// any realistic fund). Refutation target: an overflow or a rounding-up path in `sharePrice` / `usdcFor`.
    function testFuzz_DEC084_sharePriceMonotonicAndBoundedAtExtremes(
        uint256 shareAssets,
        uint256 deltaAssets,
        uint256 wholeShares
    ) public view {
        shareAssets = bound(shareAssets, 0, type(uint128).max);
        deltaAssets = bound(deltaAssets, 0, type(uint128).max - shareAssets);
        wholeShares = bound(wholeShares, 1, 1e15);
        uint256 supply = wholeShares * ONE_SHARE;
        uint256 price = h.sharePrice(shareAssets, supply);
        assertLe(h.usdcFor(supply, price), shareAssets, "supply never worth more than Share Assets");
        assertGe(h.sharePrice(shareAssets + deltaAssets, supply), price, "more assets never lowers the price");
        if (wholeShares > 1) {
            assertGe(h.sharePrice(shareAssets, supply - ONE_SHARE), price, "fewer shares never lowers the price");
        }
        // The price is exact when the division is exact.
        assertEq(h.sharePrice(wholeShares * ONE_USDC, supply), PRICE_1_00);
    }

    /// DEC-035, DEC-061: at every price a deposit's charge is the value of the shares minted, the shares minted are
    /// the most the net amount can buy, and one more USDC base unit changes the outcome by at most one share.
    /// Zero net amount and zero shares are handled without special cases. Refutation target: a discontinuity
    /// around a whole-share boundary.
    /// Verification round 2 finding (documented, inherent to DEC-061): because the charge is truncated at the
    /// 6th decimal, the untouched remainder `usdcNet - charged` can itself buy ONE more whole share (found at
    /// price 1e36 - 2: 999 shares charged 999e18 - 1, remainder 1e18 buys a 1000th share). Splitting a deposit
    /// therefore saves at most one USDC base unit per extra mint; never more than one share of granularity.
    function testFuzz_DEC035_depositIsContinuousAcrossShareBoundaries(uint256 usdcNet, uint256 price) public view {
        usdcNet = bound(usdcNet, 0, 1e15 * ONE_USDC);
        price = bound(price, 1e18, 1e36);
        uint256 shares = h.sharesForDeposit(usdcNet, price);
        uint256 sharesPlusOne = h.sharesForDeposit(usdcNet + 1, price);
        assertGe(sharesPlusOne, shares);
        assertLe(sharesPlusOne - shares, ONE_SHARE, "one base unit buys at most one more whole share");
        assertEq(h.sharesForDeposit(0, price), 0);
        assertEq(h.usdcFor(0, price), 0);
        assertEq(h.sharesToBurn(0, price), 0);
        // The charge for what the net amount buys is affordable, and what remains buys at most one more share.
        uint256 charged = h.usdcFor(shares, price);
        assertLe(charged, usdcNet);
        uint256 extra = h.sharesForDeposit(usdcNet - charged, price);
        assertLe(extra, ONE_SHARE, "remainder buys at most one more whole share (DEC-061 truncation)");
        // And that extra share, if any, is worth at most one base unit more than the remainder it was bought with.
        if (extra != 0) {
            assertLe(h.usdcFor(extra, price), usdcNet - charged);
            assertLe(charged + h.usdcFor(extra, price) + 1, h.usdcFor(shares + extra, price) + 1);
        }
    }

    /// DEC-106, DEC-110: at the cap the flow fee is exactly 1% rounded down for every amount up to `uint128`, and
    /// the deposit preview never charges more than the deposited amount at any fee rate within the cap.
    function testFuzz_DEC106_previewDepositNeverChargesAboveDeposit(uint256 usdcAmount, uint256 bps, uint256 price)
        public
        view
    {
        usdcAmount = bound(usdcAmount, 0, 1e15 * ONE_USDC);
        bps = bound(bps, 0, ShareMath.MAX_FLOW_FEE_BPS);
        price = bound(price, 1e18, 1e36);
        (uint256 shares, uint256 usdcForShares, uint256 fee) = h.previewDeposit(usdcAmount, bps, price);
        assertLe(fee + usdcForShares, usdcAmount, "charge never above the deposit");
        assertEq(shares % ONE_SHARE, 0);
        assertEq(fee, (usdcAmount * bps) / 10_000);
        assertEq(usdcForShares, h.usdcFor(shares, price));
    }
}
