# Fund closure

The manager calls `closeFund` to move Open to Closing (DEC-147). Deposits, new Payout Requests and claims are
refused; existing manager verbs and Income Withdrawal remain available. The manager may call
`unwindAllAfterDeadline` immediately. Other addresses may call it strictly after `closingStartedAt + 72 hours`
(DEC-149/154). This operation applies WP-09's full Hub unwind with Standard Payout loss rules, no requester loss
maximum, and a repeatable CLOSE order broadcast through OrderCodec. One Wormhole message reaches every spoke;
the exact Wormhole message fee is supplied by the caller. Failed positions remain retryable.

## Finalization

Anyone may finalize once the Hub report is empty, every spoke has a fresh empty accepted report built after closure
started, no Hub-to-spoke transit remains, no unmatched arrival is held, and all recognized income is converted.
Each spoke must prove CLOSE completion. Empty reports alone do not authorize finalization.

The accepted report's `unwindResults` encodes WP-12's shared `SpokeUnwindTypes.OrderResult[]`. The Hub verifies the
CLOSE order id, closure request id, published attempt, no exclusions and no refund. The result's
`closureExcessCost` is cumulative across manual sales and automatic attempts, independent of the bounded history
of individual sends. Authenticated reports retain expected Principal arrivals on the Hub even after their result
entries are evicted; missing arrivals still prevent finalization. Fresh empty reports must also resolve all transits.
PR #21 includes PR #22's real executor. The two-fork closure regression publishes CLOSE on Arbitrum, executes on
Robinhood against real V4/V3 protocols, delivers the actual report and Principal, retries, finalizes and exits.

Finalization restores Hub Operating Cash to Idle, pays accrued management fees in USDC (DEC-114), and splits those
fees between the Protocol Recipient and ManagerFeeVault using the current registry slice, clamped to 5–50% with
the 50% fallback. Fee transfer failures remain owed under the existing fee-payment rules. The management-fee clock
stops at `closeFund`.

Standard Payout Market Costs apply per sale: the fund absorbs up to 1%, and the excess is deducted from the
manager's share redemption, never from the protocol's management-fee slice (DEC-147/141). The redemption price
adds deductible excess back to assets so it is charged once (D-17). Excess is capped at what the manager's final
redemption can carry after the flow fee; the fund absorbs any remainder. Manual position exits return principal
tokens to Unallocated Balance; every subsequent principal swap records its loss against the route's pool price
immediately before the swap (DEC-118). Non-base output costs convert into base units using a pre-swap pool price,
not an oracle. Hub manual costs are recorded only while Closing; automatic costs are added separately once.
Spokes cannot read the Hub's state, so they checkpoint cumulative manual excess by timestamp. CLOSE carries the
authenticated Hub `closingStartedAt`; a binary search excludes earlier sales and includes the manager's manual
sales before the first CLOSE delivery. Refunds and retries never charge the same sale again.

Manual-sale checkpoints grow only on timestamps with nonzero excess (same-timestamp entries are coalesced).
This persistent history is necessary because a spoke learns the closure start only when its first CLOSE arrives.
The order tuple adds `closingStartedAt` and OrderResult adds `closureExcessCost`; all producers and consumers ship
together for this internal alpha. Previously deployed code does not gain the new schema.

## Closed exits and late value

The manager's shares burn at finalization. The remaining `closedSupply` and `closedIdle` freeze the redemption
split: `shares * closedIdle / closedSupply`, rounded down to USDC base units (DEC-163/167, ruling 2026-10-02).
`FundClosed` records the timestamp, frozen split, closing Share Price, management fee paid, manager shares burned
and excess cost deducted. ShareToken mint/burn events reconstruct holder positions; no per-holder snapshot exists.

Anyone may call `exitClosedFund(holder)` anytime; only the holder receives principal and accrued income. No report
or Payout Fee is required, the flow fee remains, and an existing Payout Request is cleared. Late arrivals, reports,
refunds and recovered arrivals never credit Idle after Closed. The Across handler accepts late delivery without
decoding its message. New income collection requests do not collect or recognize late income after Closed.
`sweepExcess` sends unledgered balances to the garbage collector at any time, while protecting the frozen exits and
owed fees/income. After the final share burns, frozen-split rounding dust becomes sweepable too.

## Deployment

`CoreVaultClosureLogic` is a linked library deployed and linked by `FactoryDeployment`. The Core Vault remains
non-upgradeable; existing deployed funds do not acquire closure entry points. No compiler settings change.
