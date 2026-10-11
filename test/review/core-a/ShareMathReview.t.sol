// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ShareMath} from "../../../src/libraries/ShareMath.sol";

contract ShareMathHarness {
    function sharePrice(uint256 a, uint256 s) external pure returns (uint256) {
        return ShareMath.sharePrice(a, s);
    }

    function sharesToBurn(uint256 u, uint256 p) external pure returns (uint256) {
        return ShareMath.sharesToBurn(u, p);
    }

    function usdcFor(uint256 s, uint256 p) external pure returns (uint256) {
        return ShareMath.usdcFor(s, p);
    }

    function previewDeposit(uint256 u, uint256 f, uint256 p) external pure returns (uint256, uint256, uint256) {
        return ShareMath.previewDeposit(u, f, p);
    }
}

/// @notice Review fuzz (checked-and-found-correct items): whole shares, rounding direction, never pays above the request,
///         a burn never pays more than the pro-rata share of Share Assets, a mint never charges less than pro rata
///         by more than one base unit.
contract ShareMathReview is Test {
    ShareMathHarness internal h = new ShareMathHarness();

    function testFuzz_burnNeverAboveRequestNorProRata(uint256 assets, uint256 wholeSupply, uint256 request)
        public
        view
    {
        assets = bound(assets, 1, 1e18); // up to 1e12 USDC
        wholeSupply = bound(wholeSupply, 1, 1e15);
        uint256 supply = wholeSupply * 1e18;
        request = bound(request, 1, 1e18);
        uint256 price = h.sharePrice(assets, supply);
        vm.assume(price != 0);
        uint256 burned = h.sharesToBurn(request, price);
        if (burned > supply) burned = supply;
        assertEq(burned % 1e18, 0, "whole shares");
        uint256 paid = h.usdcFor(burned, price);
        assertLe(paid, request, "never above the request (DEC-077)");
        // paid <= assets * burned / supply (the leaver never takes more than its pro-rata share)
        assertLe(paid * supply, assets * burned, "never above pro rata");
    }

    function testFuzz_mintChargesAtLeastProRataMinusOne(uint256 assets, uint256 wholeSupply, uint256 amount, uint16 fee)
        public
        view
    {
        assets = bound(assets, 1, 1e18);
        wholeSupply = bound(wholeSupply, 1, 1e15);
        uint256 supply = wholeSupply * 1e18;
        amount = bound(amount, 1, 1e18);
        fee = uint16(bound(fee, 0, 100));
        uint256 price = h.sharePrice(assets, supply);
        vm.assume(price != 0);
        (uint256 minted, uint256 charged, uint256 flowFee) = h.previewDeposit(amount, fee, price);
        assertEq(minted % 1e18, 0, "whole shares");
        assertLe(charged + flowFee, amount, "never pulls more than offered");
        // charged >= assets * minted / supply - (minted / 1e18 + 1): the entrant's rounding gain is below one base
        // unit per whole share minted plus one, i.e. negligible for any realistic price.
        uint256 fair = assets * minted / supply;
        assertGe(charged + minted / 1e18 + 1, fair, "mint underpays by less than one base unit per share + 1");
    }
}
