// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {BridgeQuote} from "../../../src/interfaces/FundTypes.sol";
import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";

/// @title Regression (security review S-9): the manager can no longer be its own exclusive Across relayer
/// @notice Was PoC `test_POC_managerSelfRelaysAtTheMaximumFeeRoundAfterRound` (high, access lens): the vaults passed
///         the quote's `exclusiveRelayer` and exclusivity window to Across untouched, so the manager named itself
///         exclusive relayer, filled its own deposits and kept the whole `maxBridgeFeeBps` bound on every leg (9.5% of
///         the fund in ten round trips).
/// @notice FIX (S-9): both vaults reject a quote with a non-zero `exclusiveRelayer` or `exclusivityDeadline`
///         (`ExclusiveRelayerNotAllowed`), so relayers compete for every fill. The test asserts the self-relay quote
///         now FAILS. Residual (docs/security/KNOWN-LIMITATIONS.md): a manager who over-quotes up to the Mandate bound
///         still hands the difference to whichever relayer fills first; a per-period bridge-fee budget is a founder
///         decision.
/// @dev Real Core Vault on the repository's unit fixture.
contract BridgeFeeChurnPoC is CoreVaultFixture {
    uint256 internal constant MAX_FEE_BPS = 50;

    function test_SEC_S9_managerCanNoLongerSelfRelayExclusively() public {
        _deposit(alice, 100_000e6);
        uint256 sent = vault.freeIdle();
        uint256 arrives = sent - sent * MAX_FEE_BPS / 10_000;

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, manager));
        vault.sendToSpoke(0, sent, 0, _selfRelayQuote(arrives));

        // An exclusivity window without a named relayer is refused too.
        BridgeQuote memory windowOnly = _selfRelayQuote(arrives);
        windowOnly.exclusiveRelayer = address(0);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ICoreVault.ExclusiveRelayerNotAllowed.selector, address(0)));
        vault.sendToSpoke(0, sent, 0, windowOnly);

        // The open quote goes through.
        vm.prank(manager);
        vault.sendToSpoke(0, sent, 0, _quote(arrives));
        assertEq(vault.freeIdle(), 0);
    }

    function _selfRelayQuote(uint256 outputAmount) internal view returns (BridgeQuote memory) {
        return BridgeQuote({
            outputAmount: outputAmount,
            quoteTimestamp: uint32(block.timestamp),
            exclusivityDeadline: 21_600,
            exclusiveRelayer: manager
        });
    }
}
