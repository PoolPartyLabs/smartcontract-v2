# WP-15b completion: PASS

## Round-1 fixes and authoritative rerun (October 3, 2026)

This section supersedes the earlier run's counts and conservation methodology below.
Merged `origin/main` at `2b04b28` first (`8185c85`); fixes are `d92fb60` (durable
Principal ACK recovery) and `4eba29e` (evidence-based conservation and recovery runner).

- Pending transits and published ACK payloads persist atomically in
  `.state/pending-transits.json`, scoped to the deployment. Every poll reconstructs
  candidates from `SentToHub`, independently of new/accepted reports, and retries
  with exponential backoff (500 ms to 30 s, no attempt limit). ACKs share the emitter's
  delivery sequence; failed delivery remains pending, and expired/superseded ACKs
  are republished. Confirmed arrival/expiry or the existing three-day post-deadline
  retention resolves candidates; refunds remain pending until their ACK executes.
- All boundary outflows require transaction-, token-, sender-, recipient- and
  amount-bounded evidence. Position inputs/unused returns use calldata and measured
  `used` amounts; investment exits use principal/income events and pinned protocol
  counterparties. Swap sales use vault events plus canonical V3 pool receipt events.
  Payouts, fees, closure and sweeps use their own events. Across arrivals match
  `FilledRelay` recipient, token, relayer and actual output, not transit IDs alone.
  Unmatched flows never become investment losses or Market Costs and fail the run,
  even below rounding tolerance. Physical Core Vault cash and bridge checks remain separate.
- Seven deterministic harness tests pass: report-before-fill, transient ACK send,
  transient ACK delivery, restart/backoff/no retry limit, unrelated 10 USDC outflow,
  wrong transaction/token/counterparty/amount and sub-tolerance unknown flow. The
  100 USDC deposit / 10 USDC unexplained outflow / 90 USDC cash negative control
  has **10 USDC residual and fails**.

Reproduction (source the RPC helper in this same shell before starting forks):

```sh
export LOCAL_E2E_ARBITRUM_PORT=59645 LOCAL_E2E_ROBINHOOD_PORT=59646 LOCAL_E2E_API_PORT=59687
pnpm run up --warm-up none
KEEPER_FILL_DELAY_SECONDS=5 KEEPER_VAA_DELAY_SECONDS=1 pnpm check:recovery
pnpm down
```

The committed-code run started **2026-10-03 00:44:44 UTC**, at the fixed archive pins
511007613 / 78293056, on code `4eba29e`. Raw artifacts:
`2026-10-03T00-44-44Z-scenario.{json,md}` and
`2026-10-03T00-44-01Z-api-probe.{json,md}`. The runner injects exactly one temporary
ACK-send RPC failure after a successful preflight. Reports arrive at least four
seconds before the later order-return fills; polling completes their ACKs without
another report being needed for credit/retry. The persisted pending queue is empty
after completion (four resolved Principal candidates).

| Check | Round-1 result |
|---|---|
| Full recovery scenario | PASS, 55 steps / 319 assertions, 82 seconds |
| Receipt-derived transactions / gas | 103 / 99,813,982 |
| Keeper | 6 real fills, 0 simulations, 22 report deliveries, 10 orders |
| Keeper errors | Exactly 1 intentionally injected RPC failure, recovered |
| API probe | PASS, 31 concepts |
| Conservation | 22,332.667340 = 20,983.402203 + 1,349.265129 + 0.000008 USDC |
| Unexplained flows / residual | None / 0 USDC |
| Bridge costs / event ledger | Both 6.577616 USDC |
| Remaining positions / In-flight Value | 0 / 0 |
| Frozen-split cash dust | 8 USDC base units, still ledgered |
| Foundry build / formatting | PASS / PASS |
| Size suite | 3/3, 1 suite |
| Non-fork suite | 1,433/1,433, 183 suites |
| Fork suite | 222/222, 56 suites, `-j 4` |
| Frozen pnpm install / typecheck | PASS / PASS |
| Harness regressions / alpha relay | 7/7 / 6/6 |
| Lifecycle / URL checks | 24 assertions / 8 synthetic cases |
| Cleanup | `pnpm down` PASS; no listener on 59645, 59646 or 59687 |

The main merge reduces SpokeUnwindLib from 23,473 to **23,449 bytes** (margin
**1,127 bytes**); all other production sizes in the table below are unchanged.
No margin is below 1,000 bytes. The fix commits change no Solidity or fork fixtures;
the merged main encoder regression accounts for the additional non-fork test.
No new plan deviation or spec divergence was found. Existing closure gas budget,
terminal CLOSE-after-ACK, static price-feed and positive-cost-absorption limitations
remain as disclosed below. The API probe remains a builder/probe check, not a second
HTTP-driven full lifecycle.

## Original run (historical)

Verified October 3, 2026 (Europe/Lisbon). Raw filenames use UTC: the scenario began
October 2 at 23:59:32 UTC, which is October 3 at 00:59:32 in Lisbon.
Branch `test/pp-sc-test-harness-e2e-v2`; parent `0146fb3` merged with merge commit `e65f40d`.
Executed code `eb95dd035c8196abcda76cbda382b777b6b741a4`, without uncommitted code changes.

## Evidence

- Full scenario: `2026-10-02T23-59-32Z-scenario.md` and `.json`.
- API probe: `2026-10-03T00-02-03Z-api-probe.md` and `.json`.
- Scenario: 55 steps, 319 assertions, 100 transactions, 99,288,753 total gas.
- Both archive forks: Arbitrum One block 511007613; Robinhood Chain block 78293056.
- Private local ports: 48645, 48646, 48787; RPC helper sourced before every fork invocation.
- Real Across fills: 6; simulated fills: 0. Scenario stdout's 2 counts the two original
  explicitly linked bridge steps; keeper statistics include income, unwind and closure fills.
- Keeper: 20 report deliveries, 9 executed orders, 0 unsupported orders, 0 errors.
- API: 31 concepts, 2 real fills, 0 errors; embedded HTTP server and keeper stop in `finally`.
- Every numbered step has transactions/hashes/gas, Share Price, Share Assets, Gross Assets,
  fee accrual/payments and every actor's positions. The report includes a final phase summary,
  fee ledger, complete transaction list and total gas per chain/contract/operation type.

## Lifecycle and retry assertions

Seed and fresh fund creation are included in the report, including `createFund` (24,264,276 gas)
and `createSpoke` (12,124,613 gas). Ana and Bruno deposit; the manager opens Hub Aave and V4
and spoke V4 positions, swaps through the adapter (unsigned and API-signed routes), and bridges.
Trader swings and a warp generate income; COLLECT converts and distributes dollars.

Ana's initial Standard Payout uses Idle. Bruno's Instant Payout above Free Idle unwinds Hub
and spoke positions; a stranger settles only after the fill and post-unwind report, using one
Share Price. Network Costs join the Instant requester's Market Costs; Payout Fee stays in Idle.
The later Standard Payout exceeds Idle plus Hub positions: a 1 bp maximum excludes both V4
positions, produces a Partial Payout and leaves the request open. The retry with maximum 0
retains its id and fraction, leaves delivered Aave principal unchanged and sells excluded
positions on both forks. The final successful report records zero positive Market Costs
absorbed in that Standard retry; the bounded-cost assertion passes but does not prove a
positive-cost absorption case. Foundry's full payout suite provides that independent coverage.

Manager base crossing reverts `ManagerMustCloseFund`. `closeFund` prevents deposits/requests/
claims; Income Withdrawal remains available. The manager closes remaining Aave within 72 h;
a stranger is refused before the deadline and unwinds after it. CLOSE executes on Robinhood,
its real Across fill arrives, and ACKNOWLEDGE retires Principal sends. A terminal CLOSE retry
restores completion evidence. Final collection precedes `finalizeClosure`, which pays management
fees and burns/pays the manager. A 1,589-second warp deliberately makes the spoke report stale;
Ana and Bruno still exit using the frozen split with flow fee only. Final supply is zero.

## Conservation

USDC units (6 decimals):

| Component | USDC |
|---|---:|
| External capital, including 1,234 donation | 22,233.596364 |
| Realized investment/swap cash flows and income | 99.139509 |
| Value in | 22,332.735873 |
| Investor payments, including manager closure and income | 20,983.470507 |
| External fees and garbage/excess sweeps | 1,342.687741 |
| Bridge costs | 6.577617 |
| Fees plus sweeps and bridge costs | 1,349.265358 |
| Remaining physical vault cash | 0.000008 |
| Remaining positions / transits | 0 / 0 |
| Residual | 0.000000 |

**22,332.735873 = 20,983.470507 + 1,349.265358 + 0.000008.**
The residual is exactly zero, below the explicit 20-base-unit valuation tolerance.
Independently summed bridge transfer loss equals the event ledger's 6.577617 USDC.
Internal allocations and bridge principal are not external investor payouts or market gains.
WETH uses the unchanged scenario ETH/USD feed; this is a realized, fully unwound run, not a
general live mark-to-market proof. Eight USDC base units remain as ledgered frozen-split rounding
dust; `sweepExcess` only sweeps unledgered cash. The report does not falsely claim dust was swept.

## Validation

| Check | Result |
|---|---|
| `forge build --sizes` | PASS, all production code below 24,576 bytes |
| `forge fmt --check` | PASS |
| Size suite | 3/3, 1 suite |
| Full non-fork suite | 1,432/1,432, 183 suites (includes size suite) |
| Full fork suite, `-j 4` | 222/222, 56 suites |
| `pnpm typecheck` | PASS |
| `pnpm check:lifecycle` | 24 assertions |
| `pnpm check:urls` | 8 synthetic URL cases plus logger/shell checks |
| `pnpm test:alpha` | 6/6 tests |
| Harness up/status/API/scenario | PASS |

No new Foundry fork file or shared fixture was changed; no CI suite registration is needed.

## Sizes

WP-15b changes only `local-e2e/**`; sizes before/after WP-15b are identical on parent `0146fb3`.
Margins are against 24,576 bytes. No margin is below 1,000; tightest is SpokeUnwindLib (1,103).

| Contract or linked library | Bytes before/after | Margin |
|---|---:|---:|
| AaveV3Adapter | 9,893 | 14,683 |
| AcrossBridgeAdapter | 6,713 | 17,863 |
| UniswapV3SwapAdapter | 10,586 | 13,990 |
| UniswapV4Adapter | 14,369 | 10,207 |
| CoreVault | 22,862 | 1,714 |
| CoreVaultClosureLogic | 16,085 | 8,491 |
| ManagerFeeVault | 1,077 | 23,499 |
| ManagerRegistry | 1,603 | 22,973 |
| ShareToken | 1,822 | 22,754 |
| TransitEscrow | 894 | 23,682 |
| Create3Deployer | 1,342 | 23,234 |
| FundFactory | 18,347 | 6,229 |
| ChainlinkPriceSource | 1,709 | 22,867 |
| ValueReportReceiver | 8,080 | 16,496 |
| SpokeVault | 22,887 | 1,689 |
| CoreVaultLogic | 13,684 | 10,892 |
| CoreVaultTransitLogic | 15,596 | 8,980 |
| CoreVaultIncomeLogic | 12,101 | 12,475 |
| CoreVaultIncomeCollectionLogic | 16,816 | 7,760 |
| CoreVaultPayoutLogic | 22,256 | 2,320 |
| SpokeCrossChainLib | 12,199 | 12,377 |
| SpokeUnwindLib | 23,473 | 1,103 |
| SpokeCloseLib | 5,875 | 18,701 |
| SpokeIncomeLib | 11,631 | 12,945 |

## Implementation limitations and deviations

1. Nested closure gas estimation: transaction
   `0xa48f9575e29e9561900b305fc09e377b9dd2936a1374d1d66c3fe441a5a17519`
   succeeded externally (1,591,016 gas) but emitted `ClosureUnwindFailed(0x)` after inner
   `unwindForPayout` ran out of gas. `cast run` reproduced the inner `OutOfGas`; Hub positions
   remained and `finalizeClosure` simulated `ClosureNotReady()`. The harness supplies 15M gas
   and asserts no failure event. No contract code is changed.
2. ACKNOWLEDGE removes the acknowledged send's OrderResult, including the final CLOSE result.
   After executing final CLOSE transaction
   `0xdca2c38eecd5e6a6bb5602a39781ff2c3af0b13609d00a1316557551c8c91728`,
   ACK transaction `0x4e140232f133a6bf39863ee08f4fb6b04d8e6aff64b160757e24dc3e648d63cb`
   produced an empty in-flight report but removed closure completion evidence; `finalizeClosure`
   simulated `ClosureNotReady()`. Repeat CLOSE after ACK restores a no-send terminal result;
   then final income collection and finalization pass. This extra round-trip is an inherited
   implementation limitation, not a spec interpretation or a contract fix in this WP.
3. Undelivered acknowledgements retain send capacity; 16 pending records block later sends.
   The keeper must publish/deliver acknowledgements; anyone can republish them. A report made
   stale by an intentional harness warp is skipped in favor of the next fresh report.
4. Work started stacked on `feat/pp-sc-feat-fund-closure` as requested. PR #21 merged at
   October 2, 2026 23:45:08 UTC; GitHub automatically retargeted PR #24 to main. Parent
   `0146fb3` is an ancestor of `origin/main` (`f88b25b`); this agent merged neither PR.
   HTTP tests validate builders/status; the scenario executes lifecycle verbs directly
   through JSON-RPC, not a second full lifecycle through HTTP.
5. Operating Cash, native gas refunds and spoke gas top-up remain deferred by ruling
   October 2, 2026; DEC-187 gas stays manager/keeper-paid. DEC-157/160: a permanently
   nonresponding spoke can still block open-fund exits. No new spec divergence is adopted.

## Cleanup

Both in-process keepers and embedded probe HTTP server stopped. `pnpm down` stopped both
owned anvil processes and removed deployment state. No listener remains on ports
48645/48646/48787. No `lib/` or `.env` path is staged or committed.
