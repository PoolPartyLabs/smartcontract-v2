// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {CoreMockToken} from "../../mocks/core/CoreMockTokens.sol";
import {MockHubSpokeVault} from "../../mocks/core/MockHubSpokeVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";

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

/// @title Regression (security review S-12): a blocklisted Protocol Recipient no longer freezes deposits, payouts or
///        income collection
/// @notice Was PoC `test_POC_blocklistedProtocolRecipientFreezesDepositsPayoutsAndIncome` (medium, liveness lens): the
///         protocol's share of every flow was pushed in-line to one immutable address, so a USDC blocklist entry on it
///         froze all customer principal of every fund sharing it.
///
/// FIX (S-12, `CoreVaultLogic.payFee`): a failed fee transfer is owed to its recipient (`owedFees`) and paid by
/// `claimOwedFees`. The test asserts the freeze now FAILS: both claims, a new deposit and the hub income collection
/// complete, and the owed fees are paid once the recipient is reachable again.
contract POC_ProtocolRecipientBlocklist is CoreVaultFixture {
    BlocklistableUsdc internal blocklistUsdc;

    function setUp() public override {
        super.setUp();
        blocklistUsdc = new BlocklistableUsdc();
        usdc = CoreMockToken(address(blocklistUsdc));
        hubVault = new MockHubSpokeVault(address(usdc));
        vault = _deploy(_mandate(2000), _config(25));
    }

    function test_SEC_S12_blocklistedProtocolRecipientNoLongerFreezesTheFund() public {
        _deposit(alice, 10_000e6);
        _deposit(bob, 5000e6);
        _request(alice, 4000e6, ICoreVaultPayouts.PayoutMode.Standard);
        vm.warp(block.timestamp + 72 hours + 1);
        _request(bob, 1000e6, ICoreVaultPayouts.PayoutMode.Instant);

        blocklistUsdc.setBlocklisted(protocol, true);
        uint256 protocolBefore = usdc.balanceOf(protocol);

        // 1. Both payouts complete.
        assertEq(_claim(alice).usdcOutstanding, 0, "S-12: the Standard Payout completes");
        assertEq(_claim(bob).usdcOutstanding, 0, "S-12: the Instant Payout completes");

        // 2. A deposit enters.
        _deposit(ana, 1000e6);
        assertGt(shares.balanceOf(ana), 0, "S-12: the deposit minted");

        // 3. Hub income is collected; the protocol slice is owed.
        hubVault.forwardIncome(address(usdc), 1000e6);
        assertGt(vault.collectedIncome(address(usdc)), 0, "S-12: the holders' income reached the accumulator");

        // 4. Nothing reached the blocklisted wallet; everything it is owed waits, and is paid when it can receive.
        assertEq(usdc.balanceOf(protocol), protocolBefore);
        uint256 owed = vault.owedFees(address(usdc), protocol);
        assertGt(owed, 0);
        blocklistUsdc.setBlocklisted(protocol, false);
        vault.claimOwedFees(address(usdc), protocol);
        assertEq(usdc.balanceOf(protocol), protocolBefore + owed);
    }
}
