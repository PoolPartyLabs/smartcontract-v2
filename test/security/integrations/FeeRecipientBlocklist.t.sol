// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BlocklistToken} from "./mocks/BlocklistToken.sol";
import {HubFundFixture} from "./HubFundFixture.sol";

/// @title Proof of concept: a USDC-blocklisted Protocol Recipient freezes every deposit and every payout for good
/// @notice The flow fee is pushed to `protocolRecipient` inside `CoreVault.deposit` (`safeTransferFrom` to it) and
///         inside `_executePayout` (`safeTransfer` to it), and the protocol slice of every income collection is pushed
///         to the same address inside `CoreVaultLogic._collectIncome` (which also runs inside Across fills and report
///         delivery). `protocolRecipient` is immutable and the fee is never zero for a real amount, so the moment USDC's
///         issuer blocklists that one address (a compliance action against the protocol's fee wallet, outside the
///         fund's control), no Shareholder of any fund created with it can deposit or claim a payout again, while the
///         fund's positions and Idle stay in place. The same holds for a blocklisted `ManagerFeeVault` on the income
///         paths (hub income forwarding, spoke Income arrivals and report delivery revert).
/// @dev Attack (or accident): a fund with holders and an open Standard Payout Request; USDC blocklists the Protocol
///      Recipient; every deposit and every claim reverts with the token's blocklist error, and so does forwarding
///      hub income (its protocol slice); only Income Withdrawal, which pays no fee, still works.
/// @dev Impact: a permanent freeze of customer exits behind an external, low-probability trigger; no verb of the fund
///      (manager or protocol) can route around it, since the recipient and the fee are fixed at creation.
/// @dev Fix: never put a third-party transfer on the Shareholder's critical path. Book protocol fees in a ledger of
///      the Core Vault (`owedToProtocol[token]`) and let the recipient pull them; or push with `try/catch` and accrue
///      on failure. The ManagerFeeVault push on collection deserves the same treatment.
contract FeeRecipientBlocklistTest is HubFundFixture {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        _deposit(alice, 500_000e6);
        _deposit(bob, 300_000e6);
        vm.prank(alice);
        core.requestPayout(100_000e6, ICoreVault.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours);
        // The fund goes on working until the fee wallet is blocklisted.
        prices.setPrice(address(weth), WETH_PRICE_1E18);
        _deposit(bob, 1_000e6);
    }

    function test_POC_blocklistedProtocolRecipientFreezesDepositsAndPayouts() public {
        usdc.setBlocklisted(protocol, true);
        bytes memory blocked = abi.encodeWithSelector(BlocklistToken.Blocklisted.selector, protocol);

        // No deposit: the flow fee push reverts.
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(core), 1_000e6);
        vm.expectRevert(blocked);
        core.deposit(1_000e6, 0);
        vm.stopPrank();

        // No payout, although Idle covers the whole claim and the term has ended: the flow fee push reverts.
        assertGe(core.freeIdle() + core.payoutRequest(alice).reserved, 100_000e6, "Idle covers the claim");
        vm.prank(alice);
        vm.expectRevert(blocked);
        core.claimPayout("");

        // An Instant Payout Request by another holder cannot be paid either.
        vm.prank(bob);
        core.requestPayout(50_000e6, ICoreVault.PayoutMode.Instant);
        vm.prank(bob);
        vm.expectRevert(blocked);
        core.claimPayout("");

        // Nothing the manager can do restores exits: the recipient and the fee are immutable.
        assertEq(core.protocolRecipient(), protocol);
        assertEq(core.flowFeeBps(), 25);

        // Income Withdrawal, which pays no fee, is the only value-moving Shareholder verb left.
        vm.prank(alice);
        assertEq(core.withdrawIncome(address(usdc)), 0);
    }
}
