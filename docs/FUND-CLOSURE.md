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

The accepted report's `unwindResults` must encode `ICoreVaultLifecycle.ClosureResult[]`. A completion entry carries
the closure request id, a published attempt, cumulative excess Market Cost across all attempts, and `complete=true`.
WP-12 owns the spoke executor and result encoding. Until that executor implements this interface, spoke completion
remains fail-closed. The Hub fork test mocks only the spoke proof and freshness interface; Aave, V4, the Hub unwind,
income collection, factory deployment and USDC payments run against real Arbitrum protocols.

Finalization restores Hub Operating Cash to Idle, pays accrued management fees in USDC (DEC-114), and splits those
fees between the Protocol Recipient and ManagerFeeVault using the current registry slice, clamped to 5–50% with
the 50% fallback. Fee transfer failures remain owed under the existing fee-payment rules. The management-fee clock
stops at `closeFund`.

Standard Payout Market Costs apply per sale: the fund absorbs up to 1%, and the excess is deducted from the
manager's share redemption, never from the protocol's management-fee slice (DEC-147/141). The redemption price
adds deductible excess back to assets so it is charged once (D-17). Excess is capped at what the manager's final
redemption can carry after the flow fee; the fund absorbs any remainder. Existing manual unwind verbs do not return
measured per-sale costs to the Core Vault; automated Hub unwind and the cumulative CLOSE result provide that cost
record. This manual-cost reporting limitation is unchanged and needs an executor/report extension if manual swaps
must receive the same automatic manager deduction.

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
