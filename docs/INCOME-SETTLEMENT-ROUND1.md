# PR #30 round-1 settlement liveness validation

October 3, 2026. DEC-145, DEC-161. Integrated `origin/main` at `334eae6` (PR #29) with merge commit `1245247`.

## Design

One 64-token-operation budget is shared across every income source, active shares and the activated waiting lot.
Captures, payments, pending-claim merges and carried-rate conversions checkpoint individual token progress.
`settleHolderIncome(holder)` is permissionless in every fund state and needs no Income Withdrawal request.
Call until complete before a balance-changing operation; incomplete balance hooks deliberately revert.
Credits and debits accumulate separately until completion to preserve exact conservative rounding across calls.
New collections cannot invalidate a partially completed activated-lot merge.

## Maximum-configuration regressions

- 15 spoke tokens, 64 finalized collections, active shares and one activated waiting lot (the maximum per holder/source).
- Cold storage, 14M forwarded-gas cap, every incomplete call changes a persisted checkpoint; peak 2,038,401 gas.
- Adversarial nonzero entry baselines, pending collections and carried adjustments included; sampled cold peaks below 3M.
- Core Vault continuation followed by Income Withdrawal, Payout burn, manager closure finalization and closed-fund exit:
  each call below 15M, including permissionless continuation after Closed.
- Split settlement equals a single unlimited-budget reference call exactly under fuzzing, finalized or pending.
- A collection appended and finalized during a pending claim merge matches eager settlement exactly.
- Original doc 08 cases retain their exact reference totals with only existing adverse base-unit rounding tolerances.

## Final green bar

| Validation | Result |
| --- | --- |
| `forge build --sizes` | Pass |
| `forge fmt --check`, `git diff --check` | Pass |
| Size suite | 3 passed |
| Full non-fork suite | 1,567 passed, 193 suites |
| Full fork suite, archive helper sourced, `-j 4` | 228 passed, 58 suites |
| Income-focused suite, `FOUNDRY_FUZZ_RUNS=2048` | 162 passed, 12 suites |
| Harness JS tests / alpha JS tests | 12 / 17 passed |
| Harness TypeScript typecheck | Pass |
| Default harness warm-up | 56 steps, 325 assertions |
| Full scenario after warm-up rollback | 57 steps, 330 assertions |
| API probe / status | 31 concepts / pass |

The full scenario includes DEC-145 Phase 9b, the closure phase, manager finalization, both frozen holder exits,
zero-supply garbage collection and a **zero USDC base-unit conservation residual**. Keeper totals: seven real
fills, zero simulated fills, 19 deliveries, 13 orders and zero errors. Both fork nodes and in-process keepers stopped.
Run reports remain under `local-e2e/reports/2026-10-03T03-23-30Z-scenario.{md,json}` and
`local-e2e/reports/2026-10-03T03-25-24Z-api-probe.{md,json}` (ignored runtime output).

## Production sizes

| Runtime | Round-1 reviewed bytes | Final bytes | Final margin to 24,576 |
| --- | ---: | ---: | ---: |
| CoreVault | 22,358 | 22,578 | 1,998 |
| CoreVaultIncomeLogic | 17,118 | 18,118 | 6,458 |
| CoreVaultClosureLogic | 16,749 | 17,052 | 7,524 |
| CoreVaultPayoutLogic | 22,258 | 22,547 | 2,029 |
| SpokeVault | 22,905 | 22,907 | 1,669 |

Closure/Payout/Spoke changes include PR #29 integration. The size inventory passes for every production contract
and linked library; the tightest margin is 1,669 bytes. No production margin is below 1,000 bytes.

## Deviations and divergences

Persistent resumable token checkpoints, rather than lot aggregation, resolve the high finding without changing
per-lot attribution or rate rounding. Existing per-source FIFO grouping and one waiting lot per holder remain.
The founder's October 3 ruling still overrides WP-14's earlier deferral. No new specification divergence;
the existing D-42 bounded cross-chain timestamp-skew interpretation is unchanged. No remaining implementation,
test or closure-harness prerequisite for this fix round.
