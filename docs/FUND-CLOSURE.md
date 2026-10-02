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

`CoreVaultClosureLogic` contains the Core Vault's seed and closure bodies, leaving access control and reentrancy
wrappers on the vault. `SpokeCloseLib` contains CLOSE preparation and manual-sale cost measurement/checkpoints;
it delegates proportional execution and retained-send reporting to `SpokeUnwindLib`. Manual-sale measurement lives
in the Hub Spoke Vault, not the Core Vault. Both closure libraries are deployed and linked by `FactoryDeployment`.
The local-e2e parser reads deployment return fields by ABI name, so the appended `spokeCloseLib` field needs no
positional parsing change. The Core Vault remains non-upgradeable; existing deployed funds do not acquire closure
entry points. No compiler settings change.

## PR #21 round-two validation

PR #22's final head `d5c6678` is merged without changing its result encoding. The shared types define
`ENCODED_RESULT_SIZE` as 13 ABI words (416 bytes). The spoke encoder asserts that the actual ABI length matches;
the payout, closure and spoke refund validators use the same size and check every record's narrow fields. This
fixes the former payout decoder's 384-byte stride, which ignored valid multi-result reports. Regressions cover
the complete 16-result payout history, retries, multiple closure results with a refunded send, actual ABI size
agreement for every supported history length, and malformed fields in a later record.

| Artifact | Round-two review size / margin | Final size / margin |
|---|---:|---:|
| Core Vault | 23,753 / 823 | 22,561 / 2,015 |
| SpokeUnwindLib | 24,265 / 311 | 21,744 / 2,832 |
| SpokeCloseLib | — | 5,875 / 18,701 |
| CoreVaultClosureLogic | 13,825 / 10,751 | 16,057 / 8,519 |
| Spoke Vault | 22,329 / 2,247 | 22,364 / 2,212 |

All production contracts and linked libraries fit 24,576 bytes; none has less than 1,000 bytes headroom.
The final green bar is 1,295 non-fork tests across 175 suites, 221 fork tests across 55 suites, 3 size tests,
and 2 focused closure fork tests including the real two-fork CLOSE scenario. Build and formatting checks pass.
The Core Vault pure move has the complete unit/fork suites green before and after. Before the spoke extraction,
all behavioral tests passed, but merging the final PR #22 grew SpokeUnwindLib beyond the size limit; extraction
restored the complete green bar. The fork retry assertion now checks the prior retained send identity and amounts,
not zero amounts: no new send is created merely by retrying an already-sent closure.

Placement deviations: moving `closeFund` alone left only 1,069 bytes margin, so the unchanged seed body also moved
into the existing lifecycle library. The requested `test/utils/LinkedCode.sol` does not exist on this branch;
`test/unit/factory/FactoryDeploymentLinking.t.sol` verifies the actual factory linking, including the new library's
link to SpokeUnwindLib. No new spec divergences were found. No local-e2e harness processes were started.
