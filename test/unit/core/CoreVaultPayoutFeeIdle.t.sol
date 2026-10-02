// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {CoreVaultFixture} from "./CoreVaultFixture.sol";

/// @notice DEC-144 items 4-5 (corrects DEC-102 items 2-4, DEC-130 closure item 3): the Instant Payout's Payout Fee stays
///         in Idle, in USDC, and raises the Share Price of those who stay; it never enters Operating Cash.
contract CoreVaultPayoutFeeIdleTest is CoreVaultFixture {
    /// @dev DEC-144 example: a fund of 1,000,000 with 1,000,000 shares; Ana exits 30,000 Instant and receives
    ///      30,000 - 600 - 75 = 29,325; the fund keeps 970,600 for 970,000 shares and the Share Price goes from
    ///      1.000000 to 1.000619.
    function test_DEC144_registerExampleSharePriceRises() public {
        _deposit(alice, _grossFor(969_999)); // with the manager's seed share: 970,000
        _deposit(ana, _grossFor(30_000));
        assertEq(shares.totalSupply(), 1_000_000e18);
        assertEq(vault.idle(), 1_000_000e6);
        assertEq(vault.sharePrice(), ONE);

        uint256 anaBefore = usdc.balanceOf(ana); // the sub-share remainder of her deposit never left her wallet
        _request(ana, 30_000e6, ICoreVault.PayoutMode.Instant);
        ICoreVault.PayoutReceipt memory r = _claim(ana);
        assertEq(r.usdcGross, 30_000e6);
        assertEq(r.payoutFee, 600e6, "2% Payout Fee");
        assertEq(r.flowFee, 75e6, "25 bps flow fee");
        assertEq(r.usdcPaid, 29_325e6);
        assertEq(usdc.balanceOf(ana) - anaBefore, 29_325e6);

        assertEq(vault.operatingCash(), 0, "never Operating Cash");
        assertEq(vault.idle(), 970_600e6, "Idle drops by usdcGross - payoutFee");
        assertEq(shares.totalSupply(), 970_000e18);
        assertEq(vault.sharePrice(), Math.mulDiv(970_600e6, 1e36, 970_000e18));
        assertApproxEqAbs(vault.sharePrice(), 1.000619e24, 0.0000005e24, "1.000619 at six decimals");
    }

    /// @dev A Standard Payout has no Payout Fee: Idle drops by the whole gross and the Share Price stays.
    function test_DEC144_standardPayoutLeavesTheSharePriceUnchanged() public {
        _deposit(alice, _grossFor(969_999)); // with the manager's seed share: 970,000
        _deposit(ana, _grossFor(30_000));
        _request(ana, 30_000e6, ICoreVault.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours);
        ICoreVault.PayoutReceipt memory r = _claim(ana);
        assertEq(r.payoutFee, 0);
        assertEq(r.usdcPaid, 29_925e6, "DEC-113: Standard 30,000 pays 75 and receives 29,925");
        assertEq(vault.idle(), 970_000e6);
        assertEq(vault.sharePrice(), ONE);
        assertEq(vault.operatingCash(), 0);
    }

    /// @dev The gross deposit that buys exactly `wholeShares` at 1.00 after the 25 bps flow fee.
    function _grossFor(uint256 wholeShares) internal pure returns (uint256) {
        return Math.mulDiv(wholeShares * 1e6, 10_000, 9975, Math.Rounding.Ceil);
    }
}
