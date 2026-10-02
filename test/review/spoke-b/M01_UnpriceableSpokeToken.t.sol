// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {IPriceSource} from "../../../src/interfaces/IPriceSource.sol";
import {SpokeBFixture} from "./SpokeBFixture.sol";

/// @notice [M-03] (spoke-b report M-01), ported to main, STILL_PRESENT (register S-16, Acknowledged: fail-closed for
///         mints, exits keep working through the price fallback; recommended to check pool tokens at creation). A token of a Mandate pool that the protocol's price source cannot price. The factory gives every fund
///         the same factory-wide `IPriceSource` and never checks that it covers the Mandate's tokens; for spoke pools
///         the hub cannot even read the tokens at creation (a pool key is a hash, the adapter lives on the spoke). As
///         soon as the spoke holds any amount of such a token (a manager swap, or a position whose composition moves
///         into it), every mint reverts with the price source's `UnsupportedToken`, and every payout values the
///         token at `lastPrice` = 0, because it was never priced (docs/OPEN-QUESTIONS.md CS-OQ-4 says a zero price is
///         "only reachable for a token that appeared after the last successful deposit or payout"; here it is
///         permanent). Leavers are paid on Share Assets without that value; the holders who stay keep it.
/// @dev Stand-in: the Mandate's spoke pool is WETH/USDG and `spokeWeth` plays the role of a Robinhood token the
///      protocol's ChainlinkPriceSource has no entry for (the mock reverts `UnsupportedToken`, as
///      `ChainlinkPriceSource.priceInUsdc` does for an unconfigured token). The Core Vault never priced it before,
///      because the spoke never held any (a zero amount is valued without a price read).
/// @dev Mandate v2 (DEC-123 level 1, WP-07 B3) closes the creation half: every Mandate token of every chain must have
///      a price when the Core Vault is created (`TokenNotPriced`), so the fixture prices `spokeWeth` at creation and
///      the PoC turns the source off afterwards. What remains is a source that stops answering after creation.
contract M01_UnpriceableSpokeToken is SpokeBFixture {
    uint256 internal constant SWAPPED = 60_000e6; // USDG the manager turns into the unpriceable token
    uint256 internal constant TOKENS = 24e18; // what the swap returns (2,500 USDG per token)

    function setUp() public override {
        super.setUp();
        _deposit(alice, 600_000e6);
        _deposit(bob, 400_000e6);
        bytes32 out = _sendToSpoke(100_000e6, 99_950e6);
        _fillOnSpoke(out, 99_950e6);
        _reportNow();

        prices.setReverts(address(spokeWeth), true); // the price source has no entry for it

        // The manager swaps 60,000 USDG into the Mandate pool's other token on the spoke (a Mandate verb).
        spokeWeth.mint(address(spokeAdapter), TOKENS);
        spokeAdapter.addLiquidity(address(spokeWeth), TOKENS);
        spokeAdapter.setSwapRate(TOKENS, SWAPPED);
        vm.prank(manager);
        spoke.swapExactInput(address(spokeAdapter), SPOKE_POOL, address(usdg), SWAPPED, TOKENS, "");
        _reportNow();
    }

    function _reportNow() internal {
        (bytes memory payload, uint64 seq) = _publishPayload();
        vm.prank(keeper);
        receiver.deliver(_vaa(payload, seq));
    }

    function test_POC_REVIEW_M03_mintsCloseAndPayoutsValueTheSpokeTokenAtZero() public {
        // 1. Mints are closed for as long as the spoke holds any of it.
        usdc.mint(makeAddr("carol"), 50_000e6);
        vm.startPrank(makeAddr("carol"));
        usdc.approve(address(vault), 50_000e6);
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.UnsupportedToken.selector, address(spokeWeth)));
        vault.deposit(50_000e6, 0);
        vm.stopPrank();
        // So is every view of the Share Price.
        vm.expectRevert(abi.encodeWithSelector(IPriceSource.UnsupportedToken.selector, address(spokeWeth)));
        vault.shareAssets();

        // 2. Bob exits in full with an Instant Payout: his claim values the 24 tokens (60,000 USDC of value) at 0.
        uint256 bobShares = shares.balanceOf(bob);
        // The seed's 1 + 1,000,000 deposited - 2,500 flow fee - 50 bridge fee; the swap was at par.
        uint256 fairAssets = SEED_IDLE + 997_450e6;
        uint256 fairValue = bobShares * fairAssets / shares.totalSupply();
        vm.prank(bob);
        vault.requestPayout(fairValue, ICoreVaultPayouts.PayoutMode.Instant);
        vm.expectEmit(address(vault));
        emit ICoreVault.PriceFallback(address(spokeWeth), 0);
        vm.prank(bob);
        ICoreVault.PayoutReceipt memory receipt = vault.claimPayout("");

        console2.log("fair value of Bob's shares   ", fairValue);
        console2.log("gross paid for all his shares", receipt.usdcGross);
        assertEq(shares.balanceOf(bob), 0, "all of Bob's shares were burned");
        // He is paid on Share Assets without the token: his 40% of the 60,000, short, before any fee.
        assertEq(receipt.shareAssets, fairAssets - SWAPPED, "the claim priced the spoke without the token");
        assertApproxEqAbs(fairValue - receipt.usdcGross, SWAPPED * 4 / 10, 1e6, "Bob is paid 24,000 short");

        // 3. What Bob left behind accrues to the holders who stay: Alice's shares now own the 24 tokens in full.
        prices.setReverts(address(spokeWeth), false); // were the token ever priced again (it is not in production)
        uint256 aliceValue = vault.shareAssets(); // Alice is the only holder left
        console2.log("Alice's value afterwards      ", aliceValue);
        assertGt(aliceValue, 598_500e6 + 23_000e6, "Alice gained what Bob was not paid");
    }
}
