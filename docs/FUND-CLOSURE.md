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

PR #22's then-reviewed head `d5c6678` is merged without changing its result encoding. The shared types define
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

## PR #21 round-three validation

Merged `origin/main` at `0bc666f` (WP-09/WP-10) with merge commit `9470a7f`, then PR #22's fixed head
`c16cbba` with merge commit `018489c`. Integration follow-up `f900963` reconciles closure recovery guards,
the shared 416-byte result validator in Hub acknowledgements, and CLOSE test timestamps. The existing
SpokeCloseLib split remains intact. ACK retirement and refund-aware bridge fees come from PR #22 unchanged.

Deployment fix `2d26366` links every library artifact in dependency order before deploying or predicting its
address; SpokeUnwindLib no longer passes unresolved SpokeCrossChainLib placeholders to `vm.getCode`.
The same linker covers all other nested libraries. Eight deployment regressions include the full
`DeployFactory.run()` path on both chains, matching pinned linked code hashes, nested runtime links and
rejection of a missing nested dependency. `72cde04` skips replacements for absent placeholders to avoid
script memory exhaustion without changing the linked code or addresses.

| Artifact | Round-two final size / margin | Round-three size / margin |
|---|---:|---:|
| Core Vault | 22,561 / 2,015 | 22,862 / 1,714 |
| Spoke Vault | 22,364 / 2,212 | 22,887 / 1,689 |
| SpokeUnwindLib | 21,744 / 2,832 | 23,473 / 1,103 |
| CoreVaultPayoutLogic | — | 22,256 / 2,320 |
| SpokeCloseLib | 5,875 / 18,701 | 5,875 / 18,701 |
| CoreVaultClosureLogic | 16,057 / 8,519 | 16,085 / 8,491 |

All 24 production contracts and linked libraries pass EIP-170 sizing. No margin is below 1,000 bytes;
SpokeUnwindLib is tightest at 1,103 bytes. No further extraction or compiler change is required.

Final green bar on `72cde04`: build with sizes and formatting check pass; 3/3 size tests;
1,432/1,432 non-fork tests across 183 suites; 222/222 fork tests across 56 suites at archive pins
Arbitrum 511007613 and Robinhood 78293056, including both closure fork tests and the real two-fork
CLOSE/report/arrival/retry/finalize/exit regression. No test is skipped.

The real-chain deployment rehearsal also passes: frozen-lockfile installation, `pnpm run up --warm-up none`,
`pnpm status`, `pnpm api:probe` (19/19 concepts), and `pnpm down`, using private ports 58645/58646/58787.
Both factories and their linked libraries were broadcast through the production deployment script on local
forks; Across fills used the real SpokePool. API report: `local-e2e/reports/2026-10-02T22-59-58Z-api-probe.md`
and its JSON companion (generated, git-ignored). Both anvil processes stopped, no keeper or API remains running.

No new plan deviation or spec divergence: the prior library-placement deviations remain as documented.
The existing DEC-157/160 limitation remains: an unresponsive spoke blocks exits while fresh reports are required;
Closed exits use the DEC-163/167 frozen split. PR #24's extended scenario remains separate from this requested
deployment smoke/probe and the Foundry two-fork CLOSE evidence.
