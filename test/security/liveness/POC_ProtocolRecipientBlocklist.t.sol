// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";

/// @notice USDC as Circle ships it: `transfer` and `transferFrom` revert when `from` or `to` is blocklisted
///         (FiatTokenV2 `notBlacklisted`). Everything else is the fixture's mock token.
contract BlocklistableUsdc is CoreMockToken {
    mapping(address => bool) public blocklisted;

    constructor() CoreMockToken("USD Coin", "USDC", 6) {}

    function setBlocklisted(address account, bool value) external {
        blocklisted[account] = value;
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!blocklisted[from] && !blocklisted[to], "Blacklistable: account is blacklisted");
        super._update(from, to, value);
    }
}

/// @title POC: a blocklisted Protocol Recipient freezes every deposit, every payout and every income collection
/// @notice SEVERITY: medium (permanent freeze of customer principal under an external, low-probability condition).
///
/// ATTACK / FAILURE
///   The Core Vault pushes the protocol's share of every flow to one immutable address, `protocolRecipient`, inside
///   the same transaction as the user's action:
///     - `CoreVault.deposit`        -> `safeTransferFrom(depositor, protocolRecipient, fee)`      (CoreVault.sol:86)
///     - `CoreVault._executePayout` -> `safeTransfer(protocolRecipient, flowFee)`                 (CoreVault.sol:259)
///     - `CoreVaultLogic._collectIncome` -> `safeTransfer(protocolRecipient, slice)`              (CoreVaultLogic.sol:395)
///       (reached from `receiveCollectedIncome`, i.e. `SpokeVault.forwardIncomeToCoreVault`, and from every matched
///       spoke-to-hub Income arrival inside the Across fill and inside `ValueReportReceiver.deliver`).
///   USDC is a blocklistable token: Circle can add any address to its blocklist, after which every transfer to it
///   reverts. `protocolRecipient` is an immutable of the Core Vault (CoreVaultBase.sol:42), `flowFeeBps` is immutable
///   (25 bps), and no verb changes either. So the day the Protocol Recipient is blocklisted:
///     - every `deposit` reverts (the fee leg),
///     - every `claimPayout` reverts, Instant and Standard alike (the flow-fee leg), so no share can ever be burned and
///       no principal leaves the fund,
///     - every hub income collection reverts (the protocol slice leg), and every report delivery that would credit a
///       pending spoke Income arrival reverts too.
///   The only verb left is `withdrawIncome`, which pays nothing when nothing was ever collected.
///
/// IMPACT
///   Permanent freeze of all customer principal held by every fund that shares that Protocol Recipient. There is no
///   admin, no upgrade path (DEC-058) and no fund close in the MVP, so the state is unrecoverable on-chain. A
///   USDC *pause* has the same effect on every fund but is systemic; a *blocklist* entry on one address is the
///   protocol's own operational risk, concentrated in one immutable hot-path dependency shared by all funds.
///
/// FIX
///   Never make a shareholder's exit depend on a third party's ability to receive tokens: accrue protocol fees in a
///   ledger inside the Core Vault (`protocolFeesOwed[token]`, outside every value base like Operating Cash) and let the
///   Protocol Recipient pull them (`claimProtocolFees(token, to)`), or wrap the fee push in a try/catch that falls
///   back to accrual. The same applies to the ManagerFeeVault leg for completeness. Independently, the Protocol
///   Recipient should be a contract the protocol controls (a plain pull vault), not an EOA.
contract POC_ProtocolRecipientBlocklist is CoreVaultFixture {
    BlocklistableUsdc internal blocklistUsdc;

    function setUp() public override {
        super.setUp();
        blocklistUsdc = new BlocklistableUsdc();
        usdc = CoreMockToken(address(blocklistUsdc));
        hubVault = new MockHubSpokeVault(address(usdc));
        vault = _deploy(_mandate(2000), _config(25));
    }

    function test_POC_blocklistedProtocolRecipientFreezesDepositsPayoutsAndIncome() public {
        // Two shareholders, one Standard request already past its term and one Instant request.
        _deposit(alice, 10_000e6);
        _deposit(bob, 5_000e6);
        _request(alice, 4_000e6, ICoreVault.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours + 1);
        _request(bob, 1_000e6, ICoreVault.PayoutMode.Instant);
        uint256 idleBefore = vault.idle();
        assertGt(idleBefore, 0);

        // Circle blocklists the (immutable) Protocol Recipient.
        blocklistUsdc.setBlocklisted(protocol, true);

        // 1. No payout can ever complete again: Standard (reserve funded, term over) and Instant alike.
        vm.prank(alice);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        vault.claimPayout("");
        vm.prank(bob);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        vault.claimPayout("");

        // 2. No deposit can enter either.
        usdc.mint(ana, 1_000e6);
        vm.startPrank(ana);
        usdc.approve(address(vault), 1_000e6);
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        vault.deposit(1_000e6, 0);
        vm.stopPrank();

        // 3. Hub income can no longer be collected (the protocol slice of the performance fee is pushed in-line).
        vm.expectRevert(bytes("Blacklistable: account is blacklisted"));
        hubVault.forwardIncome(address(usdc), 1_000e6);

        // 4. Nothing moved, nothing can move: the principal is frozen with no verb able to change the recipient.
        assertEq(vault.idle(), idleBefore);
        assertEq(shares.balanceOf(alice), 10_000e18 - 25e18);
        assertEq(shares.balanceOf(bob), 5_000e18 - 12e18 - 1e18); // 4,987.5 rounds down to 4,987 whole shares
        assertEq(vault.protocolRecipient(), protocol);
        // The only verb that still runs pays nothing: no income was ever collected.
        vm.prank(alice);
        assertEq(vault.withdrawIncome(address(usdc)), 0);
    }
}
