// SPDX-License-Identifier: LicenseRef-PoolParty-Source-Available-1.0
// @implements-rules-version: v2
// Prior license grants and third-party rights remain valid. See LICENSE and LICENSING.md.
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";
import {BlocklistToken} from "./mocks/BlocklistToken.sol";
import {HubFundFixture} from "./HubFundFixture.sol";

/// @title Regression (security review S-12): a blocklisted Protocol Recipient no longer freezes deposits and payouts
/// @notice Was PoC `test_POC_blocklistedProtocolRecipientFreezesDepositsAndPayouts` (medium, integrations lens): the
///         flow fee was pushed to the immutable Protocol Recipient inside `deposit` and `claimPayout`, so one USDC
///         blocklist entry against the fee wallet froze every fund's deposits and exits.
/// @notice FIX (S-12): a fee transfer that fails is owed (`ICoreVault.owedFees`) and paid by `claimOwedFees` later. The
///         test asserts the freeze now FAILS: the deposit, the matured Standard claim and an Instant claim all complete.
contract FeeRecipientBlocklistTest is HubFundFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        _deposit(alice, 500_000e6);
        _deposit(bob, 300_000e6);
        vm.prank(alice);
        core.requestPayout(100_000e6, ICoreVaultPayouts.PayoutMode.Standard, 0);
        vm.warp(block.timestamp + 72 hours);
        // The fund goes on working until the fee wallet is blocklisted.
        prices.setPrice(address(weth), WETH_PRICE_1E18);
        _deposit(bob, 1000e6);
    }

    function test_SEC_S12_blocklistedProtocolRecipientNoLongerFreezesDepositsAndPayouts() public {
        usdc.setBlocklisted(protocol, true);
        uint256 protocolBefore = usdc.balanceOf(protocol);

        usdc.mint(bob, 1000e6);
        vm.startPrank(bob);
        usdc.approve(address(core), 1000e6);
        core.deposit(1000e6, 0);
        vm.stopPrank();

        vm.prank(alice);
        ICoreVault.PayoutReceipt memory standard = core.claimPayout(0);
        assertEq(standard.usdcOutstanding, 0, "S-12: the matured Standard Payout completes");

        vm.prank(bob);
        ICoreVault.PayoutReceipt memory instant = core.requestPayout(50_000e6, ICoreVaultPayouts.PayoutMode.Instant, 0);
        assertEq(instant.usdcOutstanding, 0, "S-12: the Instant Payout completes");

        assertEq(usdc.balanceOf(protocol), protocolBefore, "nothing reached the blocklisted wallet");
        uint256 owed = core.owedFees(address(usdc), protocol);
        assertEq(owed, 2.5e6 + standard.flowFee + instant.flowFee, "S-12: every flow fee is owed");

        usdc.setBlocklisted(protocol, false);
        core.claimOwedFees(address(usdc), protocol);
        assertEq(usdc.balanceOf(protocol), protocolBefore + owed);
    }
}
