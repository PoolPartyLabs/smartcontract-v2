// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CoreVaultFixture} from "../../unit/core/CoreVaultFixture.sol";
import {ICoreVault} from "../../../src/interfaces/ICoreVault.sol";
import {ICoreVaultPayouts} from "../../../src/interfaces/ICoreVaultPayouts.sol";

/// @title POC: an unbounded Operating Cash top-up moves Free Idle into a bucket nothing can ever spend or return
/// @notice SEVERITY: medium (irreversible loss of shareholder value from one manager transaction, no cap, no recovery;
///         the manager key may be an autonomous agent, DEC-003).
///
/// ATTACK / FAILURE
///   `CoreVault.setOperatingCashParameters(floor, topUp)` is manager-only and unbounded (DEC-100: "no protocol cap on
///   the floor"; CoreVaultBase.sol:269). `_topUpOperatingCash` (CoreVaultBase.sol:283) runs at the start of every
///   deposit, claim, allocation and send, and moves `min(topUp, Free Idle)` from Idle into `operatingCash` whenever
///   `operatingCash < floor`. On the hub `operatingCash` only ever grows: no verb spends it, returns it to Idle or
///   distributes it (spending is OPEN, doc 30; fund close does not exist in the MVP). It is outside Share Assets, so
///   the move is booked as an expense paid by Share Assets and the Share Price drops at once (DEC-100).
///   A manager (malicious, compromised, or an agent with a decimals bug: 3e12 instead of 3e6) sets a large top-up;
///   the next shareholder operation, anyone's, executes the transfer irreversibly. The manager cannot steal it, but
///   every holder loses that value for good, and a payout after it is priced at the reduced Share Assets.
///
/// IMPACT
///   Bounded only by Free Idle: in one call plus one routine operation the whole Free Idle can be turned into dead
///   money. Here 50,000 of a 99,750 USDC fund vanish from Share Assets; the only holder's full Instant Payout then
///   pays 48,630 USDC for a 100,000 USDC deposit. There is no verb that moves Operating Cash back, so a fat-finger
///   is as final as an attack.
///
/// FIX
///   Bound the parameters in the core (a cap on `topUp` and `floor` as a fraction of Share Assets, e.g. 1%, or an
///   absolute cap in USDC per DEC-096's "about 3 USD"), rate-limit the top-up (at most once per period), and add a
///   manager verb that returns Operating Cash above the floor to Idle (it is the fund's money). Until spending exists,
///   the top-up serves nothing and could be disabled entirely on the hub.
contract POC_OperatingCashFreeze is CoreVaultFixture {
    function test_REGRESSION_operatingCashTopUpMovesFreeIdleIntoADeadBucket() public {
        vm.prank(manager);
        vm.expectRevert(bytes4(keccak256("OperatingCashNotSupported()")));
        vault.setOperatingCashParameters(type(uint256).max, type(uint256).max);
        assertEq(vault.operatingCash(), 0);
    }
}
