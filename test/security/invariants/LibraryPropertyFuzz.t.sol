// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";
import {IncomeAccumulator} from "../../../src/libraries/IncomeAccumulator.sol";

/// @dev The accumulator with a share book, so holders can be checkpointed the way the Core Vault does it.
contract AccumulatorPropertyHarness {
    using IncomeAccumulator for IncomeAccumulator.State;

    IncomeAccumulator.State internal s;

    function registerToken(address token) external {
        s.registerToken(token);
    }

    function distribute(address token, uint256 amount, uint256 totalShares) external returns (bool) {
        return s.distribute(token, amount, totalShares);
    }

    function checkpoint(address holder, uint256 shares) external {
        s.checkpoint(holder, shares);
    }

    function owed(address holder, address token, uint256 shares) external view returns (uint256) {
        return s.owed(holder, token, shares);
    }

    function tokenIncome(address token) external view returns (IncomeAccumulator.TokenIncome memory) {
        return s.tokenIncome[token];
    }
}

/// @title Fuzz twins of the symbolic library properties
/// @notice The properties of test/security/symbolic/ over the whole realistic domain, 512-bit `mulDiv` paths included.
///         Halmos proves them only where its solver finishes (docs/security/reports/dynamic-analysis.md); these run
///         under `forge test` on every build.
contract LibraryPropertyFuzzTest is Test {
    uint256 internal constant WHOLE = 1e18;
    /// @dev 1e24 USDC base units: far above any supply of USDC.
    uint256 internal constant MAX_USDC = 1e24;
    /// @dev 1e18 USDC per share.
    uint256 internal constant MAX_PRICE = 1e42;
    uint256 internal constant MAX_WHOLE_SHARES = 1e18;
    address internal constant TOKEN = address(0xA11CE);

    AccumulatorPropertyHarness internal acc;

    function setUp() public {
        acc = new AccumulatorPropertyHarness();
        acc.registerToken(TOKEN);
    }

    // ---------------------------------------------------------------------------------------------------------------
    // ShareMath: rounding always against the actor
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-035, DEC-077: mint then burn at one price never pays out more than was charged.
    function testFuzz_DEC077_mintThenBurnAtOnePriceNeverProfits(uint256 usdcNet, uint256 price) public pure {
        usdcNet = bound(usdcNet, 0, MAX_USDC);
        price = bound(price, 1, MAX_PRICE);
        uint256 shares = ShareMath.sharesForDeposit(usdcNet, price);
        uint256 charged = ShareMath.usdcFor(shares, price);
        assertEq(shares % WHOLE, 0);
        assertLe(charged, usdcNet, "the depositor is never charged above the amount offered");
        uint256 burned = ShareMath.sharesToBurn(charged, price);
        assertLe(burned, shares, "asking the charge back never burns more than was minted");
        assertLe(ShareMath.usdcFor(burned, price), charged, "and never pays more than was charged");
    }

    /// DEC-084, DEC-104: a deposit at the vault's own price never raises the Share Price, so a depositor who exits
    /// right away gets at most what the shares cost and the holders who stay lose nothing.
    function testFuzz_DEC084_mintThenBurnAtVaultPriceNeverProfits(
        uint256 shareAssets,
        uint256 wholeSupply,
        uint256 usdcNet
    ) public pure {
        shareAssets = bound(shareAssets, 0, MAX_USDC);
        wholeSupply = bound(wholeSupply, 1, MAX_WHOLE_SHARES);
        usdcNet = bound(usdcNet, 0, MAX_USDC);
        uint256 supply = wholeSupply * WHOLE;
        uint256 price = ShareMath.sharePrice(shareAssets, supply);
        vm.assume(price != 0);
        uint256 shares = ShareMath.sharesForDeposit(usdcNet, price);
        vm.assume(shares <= type(uint256).max / 1e36 - supply);
        uint256 charged = ShareMath.usdcFor(shares, price);
        uint256 priceAfter = ShareMath.sharePrice(shareAssets + charged, supply + shares);
        assertLe(priceAfter, price, "a mint never raises the Share Price");
        assertLe(ShareMath.usdcFor(shares, priceAfter), charged, "no round-trip profit");
        // The holders who stayed lose at most rounding: the depositor is charged under one USDC base unit less than
        // the shares are worth (the charge is truncated), the new price is rounded down by under one price unit per
        // whole share (under one USDC base unit per 1e18 whole shares of supply), and the valuation truncates once
        // more. Strictly: before - afterward < 2 + wholeSupply / 1e18.
        uint256 before = ShareMath.usdcFor(supply, price);
        uint256 afterward = ShareMath.usdcFor(supply, priceAfter);
        assertLe(before - afterward, wholeSupply / 1e18 + 2, "remaining holders are not diluted beyond rounding");
    }

    /// DEC-077: a burn priced from (Share Assets, supply) never raises what the leaver gets above their pro-rata part
    /// and never lowers the Share Price for the holders who stay.
    function testFuzz_DEC077_burnNeverTakesMoreThanProRata(uint256 shareAssets, uint256 wholeSupply, uint256 wholeBurn)
        public
        pure
    {
        shareAssets = bound(shareAssets, 0, MAX_USDC);
        wholeSupply = bound(wholeSupply, 1, MAX_WHOLE_SHARES);
        wholeBurn = bound(wholeBurn, 0, wholeSupply);
        uint256 supply = wholeSupply * WHOLE;
        uint256 burn = wholeBurn * WHOLE;
        uint256 price = ShareMath.sharePrice(shareAssets, supply);
        uint256 paid = ShareMath.usdcFor(burn, price);
        // paid <= shareAssets * burn / supply (pro rata, rounded down at both steps).
        assertLe(paid * wholeSupply, shareAssets * wholeBurn);
        if (wholeBurn < wholeSupply) {
            uint256 priceAfter = ShareMath.sharePrice(shareAssets - paid, supply - burn);
            assertGe(priceAfter, price, "a burn never lowers the Share Price of those who stay");
        } else {
            assertLe(paid, shareAssets, "the last holder never takes more than Share Assets");
        }
    }

    /// DEC-061: `usdcFor` is monotonic in both arguments.
    function testFuzz_DEC061_usdcForIsMonotonic(uint256 wholeA, uint256 wholeB, uint256 priceA, uint256 priceB)
        public
        pure
    {
        wholeB = bound(wholeB, 0, MAX_WHOLE_SHARES);
        wholeA = bound(wholeA, 0, wholeB);
        priceB = bound(priceB, 0, MAX_PRICE);
        priceA = bound(priceA, 0, priceB);
        assertLe(ShareMath.usdcFor(wholeA * WHOLE, priceB), ShareMath.usdcFor(wholeB * WHOLE, priceB));
        assertLe(ShareMath.usdcFor(wholeB * WHOLE, priceA), ShareMath.usdcFor(wholeB * WHOLE, priceB));
    }

    /// DEC-035: splitting a deposit into two never mints more shares than the single deposit (no gain from
    /// fragmenting, the rounding is against the actor each time).
    function testFuzz_DEC035_splittingADepositNeverMintsMore(uint256 usdcNet, uint256 split, uint256 price)
        public
        pure
    {
        usdcNet = bound(usdcNet, 0, MAX_USDC);
        split = bound(split, 0, usdcNet);
        price = bound(price, 1, MAX_PRICE);
        uint256 whole = ShareMath.sharesForDeposit(usdcNet, price);
        uint256 parts = ShareMath.sharesForDeposit(split, price) + ShareMath.sharesForDeposit(usdcNet - split, price);
        assertLe(parts, whole);
    }

    /// DEC-077: splitting a payout request into two never burns fewer shares per USDC paid: the two payouts together
    /// never pay more than the single request would.
    function testFuzz_DEC077_splittingAPayoutNeverPaysMore(uint256 usdc, uint256 split, uint256 price) public pure {
        usdc = bound(usdc, 0, MAX_USDC);
        split = bound(split, 0, usdc);
        price = bound(price, 1, MAX_PRICE);
        uint256 single = ShareMath.usdcFor(ShareMath.sharesToBurn(usdc, price), price);
        uint256 a = ShareMath.usdcFor(ShareMath.sharesToBurn(split, price), price);
        uint256 b = ShareMath.usdcFor(ShareMath.sharesToBurn(usdc - split, price), price);
        assertLe(a + b, usdc);
        assertLe(a + b, single + 1, "splitting gains at most the truncation of one base unit");
    }

    // ---------------------------------------------------------------------------------------------------------------
    // IncomeAccumulator: conservation
    // ---------------------------------------------------------------------------------------------------------------

    /// DEC-014, Q60: the holders of the whole supply are never owed more than what was distributed, over several
    /// distributions with a holder entering in between; the entrant owes nothing of the earlier income.
    function testFuzz_Q60_owedNeverExceedsDistributedWithAnEntrant(
        uint256[3] memory wholeShares,
        uint256[2] memory amounts
    ) public {
        address[3] memory holders = [address(0xA), address(0xB), address(0xC)];
        uint256[3] memory shares;
        for (uint256 i; i < 3; ++i) {
            shares[i] = bound(wholeShares[i], 1, 1e12) * WHOLE;
        }
        amounts[0] = bound(amounts[0], 0, type(uint128).max);
        amounts[1] = bound(amounts[1], 0, type(uint128).max);

        // A and B hold; income 0 is distributed; C enters; income 1 is distributed.
        acc.checkpoint(holders[0], 0);
        acc.checkpoint(holders[1], 0);
        acc.distribute(TOKEN, amounts[0], shares[0] + shares[1]);
        acc.checkpoint(holders[2], 0);
        assertEq(acc.owed(holders[2], TOKEN, shares[2]), 0, "DEC-014: the entrant owes nothing of prior income");
        acc.distribute(TOKEN, amounts[1], shares[0] + shares[1] + shares[2]);

        uint256 owedA = acc.owed(holders[0], TOKEN, shares[0]);
        uint256 owedB = acc.owed(holders[1], TOKEN, shares[1]);
        uint256 owedC = acc.owed(holders[2], TOKEN, shares[2]);
        assertLe(owedA + owedB + owedC, amounts[0] + amounts[1], "owed never exceeds distributed");
        // The entrant's part comes from the second distribution, pro rata, plus at most one base unit: the index
        // remainder of the first distribution (under 2^-128 of a base unit per share base unit) is carried into the
        // second one and divided over the new supply, which can tip the entrant's rounded-down part by one unit
        // (docs/security/reports/dynamic-analysis.md; pinned by test_DEC014_carriedRemainderTipsAnEntrantByOneUnit).
        uint256 totalWhole = (shares[0] + shares[1] + shares[2]) / WHOLE;
        assertLe(owedC, amounts[1] * (shares[2] / WHOLE) / totalWhole + 1);
        assertEq(acc.tokenIncome(TOKEN).distributed, amounts[0] + amounts[1]);
    }

    /// DEC-014 (dust-level deviation found by the 20,000-run campaign): the remainder of an earlier distribution is
    /// carried into the next one, so a holder who entered in between is attributed a part of it. Here the entrant
    /// holds 1e12 of 2e12 + 200 whole shares when 2 base units are distributed: its exact part is 0.9999999999 of a
    /// unit, which rounds down to 0, yet it is owed 1 because the carried remainder of the 5,000 distributed before
    /// its entry lifts the index. The sum owed still never exceeds what was distributed.
    function test_DEC014_carriedRemainderTipsAnEntrantByOneUnit() public {
        (address a, address b, address c) = (address(0xA), address(0xB), address(0xC));
        (uint256 sharesA, uint256 sharesB, uint256 sharesC) = (200 * WHOLE, 1e12 * WHOLE, 1e12 * WHOLE);
        acc.checkpoint(a, 0);
        acc.checkpoint(b, 0);
        acc.distribute(TOKEN, 5000, sharesA + sharesB);
        assertGt(acc.tokenIncome(TOKEN).remainder, 0, "a remainder is carried");
        acc.checkpoint(c, 0);
        acc.distribute(TOKEN, 2, sharesA + sharesB + sharesC);

        uint256 owedC = acc.owed(c, TOKEN, sharesC);
        uint256 exactPartRoundedDown = 2 * uint256(1e12) / (2e12 + 200);
        assertEq(exactPartRoundedDown, 0);
        assertEq(owedC, 1, "one base unit above the entrant's rounded-down part of the income recognized after entry");
        assertLe(acc.owed(a, TOKEN, sharesA) + acc.owed(b, TOKEN, sharesB) + owedC, 5002, "conservation still holds");
    }
}
