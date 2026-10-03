# WP-14 entry-time validation — October 3, 2026

## Status

DEC-145 implementation, worked cases, bounded accounting, two-chain fork regression and the late-entrant harness
phase pass. **Integration is pending PR #29 landing on main.** Do not treat this report as a complete release green
bar or a successful closure harness run.

Base: `e90e6a6`. Implementation commits: `d55072e`, `be042d6`, `e76e74e`, `858a7a5`, `9a61fca`.
The required final `origin/main` fetch and `merge --no-ff origin/main` found main unchanged and returned
`Already up to date`; it did not create the requested post-#29 merge commit. PR #29 was still open at the final check.

## Passed checks

| Check | Result |
| --- | --- |
| `forge build --sizes` | PASS |
| `forge fmt --check` | PASS |
| Size suite | 3 tests, 1 suite, PASS; every production runtime has at least 1,000 bytes spare |
| Non-fork suite | 1,515 tests, 189 suites, PASS |
| Whole fork suite, `-j 4` | 224 tests, 57 suites, PASS |
| Entry-time unit/model suite | 13 tests; two conservation fuzz properties, 512 runs each |
| Two-chain entry-time fork | PASS; real Uniswap V4 fees and authenticated report cycle |
| Harness TypeScript | PASS |
| Harness unit tests | 7/7 PASS |
| Alpha unit tests | 11/11 PASS |
| API probe | 31 concepts PASS |

Fork pins: Arbitrum One **511007613**, Robinhood Chain **78293056**, sourced with the handoff RPC helper in the
same shell command before fork/harness execution. No RPC credential is recorded here.

## Late-entrant scenario evidence

The first harness run, `2026-10-03T02-26-54Z-scenario.md` / `.json`, reached **50 steps, 305 assertions** before
the closure integration failure. Phase 9b, step 31, passed:

- A real fee-generating spoke interval began before Bruno's Hub deposit and was delivered afterwards.
- The spoke WETH counter advanced at that delivery.
- Bruno's prior-interval WETH Attributed Income was **zero**.
- Bruno's prior-interval USDG Attributed Income was **zero**.
- Existing holders retained their prior-interval entitlement.

The run failed at finalization with `ClosureNotReady()`: the final Income send remained in the spoke's report.
The harness now explicitly waits for its acknowledgement report before finalization. A second run reached the same
waiting point and was stopped at the command timeout; it did not produce a successful closure report. PR #29's
shared-slot/manual-send acknowledgement integration must land before this is rerun. This is not a DEC-145 test pass
for full harness closure; the existing Solidity closure fork/unit suites do pass.

The separate API probe `2026-10-03T02-45-06Z-api-probe.md` / `.json` passed all **31 concepts** with two real fills,
two report deliveries and zero keeper errors. All own harness forks and in-process keepers were stopped; private
ports 8745/8746/8789 were checked clear. Generated detailed artifacts remain local (ignored by Git).

## Runtime sizes

Limit: 24,576 bytes. No compiler settings changed and no new linked deployment library was added.

| Runtime | Before | After | Margin after |
| --- | ---: | ---: | ---: |
| CoreVaultIncomeLogic | 12,101 | 17,118 | 7,458 |
| CoreVaultIncomeCollectionLogic | 17,645 | 17,669 | 6,907 |
| CoreVault | 22,358 | 22,358 | 2,218 |
| SpokeVault | 22,905 | 22,905 | 1,671 |
| CoreVaultPayoutLogic | 22,258 | 22,258 | 2,318 |
| SpokeUnwindLib | 21,229 | 21,229 | 3,347 |

The tightest production runtime is SpokeVault, **1,671 bytes spare**. All other production runtime sizes are
unchanged. Activation at the 32-entry cap with 16 nonzero historical token baselines costs **14,811,046 gas**, below
32 million; zero baselines cost 4,709,746 gas.

## Deviations and remaining integration

- Founder ruling October 3 overrides the October 2 WP-14 deferral.
- Each source has its own FIFO rather than the plan's shared FIFO; activation remains independent per spoke and
  there is exactly one waiting lot per holder per spoke. This avoids cross-spoke top-ups changing eligibility.
- Bounded settlement replaces the old unlimited retry loop. An incomplete Income Withdrawal returns zero and
  persists progress; retry it before a balance change. Historical off-chain views remain history-dependent.
- Integer arithmetic conserves recognized income as holder credits plus rounding dust; the exact doc 08 rational
  expectations are checked within two base units per holder. Partial-sale/different-price tests allow four units.
- Clock skew is **D-42** in the actual plan, not the task's D-28 reference; bounded skew is documented and accepted.
- **Remaining:** merge main after PR #29 lands (merge commit), rerun all checks and the full successful harness,
  update this report and PR sizes/counts for the integrated baseline, then mark the draft PR ready for review.
