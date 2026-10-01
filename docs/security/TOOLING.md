# Security tooling

Every tool the sweep ran, its version, the command, the result at the last run, and the resource limits that keep a
laptop alive. The full pre-fix reports with per-result triage are [`reports/static-analysis.md`](reports/static-analysis.md)
and [`reports/dynamic-analysis.md`](reports/dynamic-analysis.md); raw outputs are under [`reports/raw/`](reports/raw/).

Toolchain: forge 1.7.1, solc 0.8.28, evm cancun, optimizer 800, `via_ir = false`.

## Resource limits

The first run of the sweep was killed by memory pressure (seven agents, each with its own forge and solver
processes). The limits that then worked, and that CI or a re-run should keep:

- One heavy tool at a time; `forge test -j 2`; `FOUNDRY_FUZZ_RUNS` at most 5,000 for a full-suite campaign,
  20,000 only one contract at a time; invariants at most 256 runs x 64 depth.
- Halmos: one contract and one property per invocation, `--solver-threads 1`, per-assertion timeout 60 s, a 6 GB
  memory guard over the process tree (yices and z3 ignore `--solver-max-memory` on 512-bit `mulDiv` queries).
- Medusa: 2 workers.
- Mythril: excluded from resumed runs (slowest and heaviest; four small contracts were covered once).
- Fork tests: `-j 1`, with fresh block pins (public RPCs prune state after minutes to an hour; see below).

## Test suites (Foundry)

| Suite | Command | Result on main (2026-09-30) |
|---|---|---|
| Unit, fuzz, invariants, security (no network) | `forge test -j 2 --no-match-path "test/fork/**"` | 750 tests, 0 failed |
| Security suites only | `forge test -j 2 --match-path "test/security/**"` and `--match-path "test/unit/security/**"` | all pass (54 `test_SEC_*`, 11 `test_POC_*` pins, 9 invariants, 31 `check_*` run as concrete tests) |
| Deep campaign | `FOUNDRY_FUZZ_RUNS=5000 FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64 FOUNDRY_FUZZ_SEED=<seed> forge test -j 2 --no-match-path "test/fork/**"` with seeds `0x1`, `0xdeadbeef`, `0x2a2a2a2a2a`, and `0xbeef` in the final verification | all pass |
| Whole-fund invariants without the liveness assumptions | `SEC_LATE_REFUNDS=true forge test --match-path "test/security/invariants/**"`; likewise `SEC_UNLISTED_SENDS_HOME=true` | pass since S-3 and S-4 (before: `DYN-01`, `DYN-02` counterexamples) |
| Fork suites | `ARBITRUM_FORK_BLOCK=$((latest-600)) ROBINHOOD_FORK_BLOCK=$((latest-600)) forge test -j 1 --match-path "test/fork/**"` | 57 tests, 0 failed (pins 510469880 / 76852461) |
| Local two-fork harness | `cd local-e2e && pnpm run up && pnpm scenario --keeper inprocess; pnpm run down` | PASS, 35 steps, 213 assertions |
| Sizes | `forge build --sizes` | every contract under 24,576 bytes; `SpokeVault` 24,017 (559 to spare), `CoreVaultLogic` 22,560, `CoreVault` 21,293 |

Fork pins: the public Arbitrum and Robinhood RPCs serve recent state only (about one hour and about ten minutes).
Compute the pins from the latest block at run time, as above, or use archive endpoints in `.env`
(`ARBITRUM_RPC_URL`, `ROBINHOOD_RPC_URL`).

## Static analysis

| Tool | Version | Command | Last result |
|---|---|---|---|
| Slither | 0.11.6 | `slither . --filter-paths "lib\|test\|script"` (`--json <file>` for the machine-readable form) | Pre-fix 174 results (8 high, 68 medium, 77 low, 19 info, 2 optimization), one low true positive (S-21's `distribute` result ignored) and hygiene (S-44). After the fixes 191 results (8 / 70 / 91 / 20 / 2); the 32 added instances are moved code and the same false-positive classes (escrow release in a bounded loop, zero-price sentinel, timestamp windows, cyclomatic complexity of `swapExactInput`); no new true positive |
| Slither printers | 0.11.6 | `--print human-summary`, `--print contract-summary` | `reports/raw/slither-*.txt` |
| slither-check-erc | 0.11.6 | `slither-check-erc . ShareToken --erc ERC20` | Signatures, return types and events pass; `transfer`, `transferFrom`, `approve` never emit because they always revert (DEC-004) |
| Aderyn | 0.6.8 | `npx --yes @cyfrin/aderyn . -s src -o docs/security/reports/raw/aderyn.md` | 6 high-classified (21 instances), all false positives; 15 low-classified (114 instances), one is S-21, two hygiene |
| Semgrep, registry pack | 1.178.0 | `semgrep scan --metrics=off --config p/smart-contracts --json --output <file> src` | 228 results, all performance category, none security |
| Semgrep, Decurity rules | 1.178.0, rules at `2e878a8` | clone `Decurity/semgrep-smart-contracts` outside the repo, `semgrep scan --metrics=off --config <clone>/solidity src` | 16 security-category hits: 1 arbitrary low-level call accepted by design (the vault executes the adapter-built bridge call), 15 false positives |
| Solhint | 6.2.4 | `npx --yes solhint -c docs/security/reports/raw/solhint.config.json --noPoster -f unix 'src/**/*.sol'` | 0 errors; 43 security-rule warnings all accepted by design (`not-rely-on-time`, `no-inline-assembly`, `avoid-low-level-calls`); 1,010 style |
| Mythril | 0.24.8 | `uv tool install mythril --with "setuptools<81"`; solc 0.8.28 on `PATH`; `myth analyze <file>:<Contract> --solc-json docs/security/reports/raw/mythril-solc.json --execution-timeout 300 -t 3` | `TransitEscrow`, `ManagerRegistry`: no issues; `ShareToken`: no issues, but **not evidence**: its runtime contains one MCOPY, which Mythril 0.24.8 cannot execute (verification plan 2.1 row 5), so paths through it were not explored; `ManagerFeeVault`: 2 SWC-107 results, one false positive (the `ReentrancyGuard` flag write after the transfer), one accepted by design (`withdraw` is manager-only and names its own token) |
| forge lint | 1.7.1 | part of `forge build` | Warnings only in test mocks (`unsafe-typecast`, `erc20-unchecked-transfer`); `src/` clean since `8e97994` |

Install notes: Slither, Semgrep, Mythril and Halmos through `uv tool install` (`~/.local/bin`); Aderyn and Solhint
through `npx --yes`; Medusa through Homebrew.

## Dynamic and symbolic analysis

| Tool | Version | Command | Last result |
|---|---|---|---|
| Halmos | 0.3.3 (yices 2.6.5, z3; bitwuzla 0.8.1 with `HALMOS_ALLOW_DOWNLOAD=1`) | From a sandbox holding `src/libraries`, `src/interfaces/FundTypes.sol`, `foundry.toml`, `remappings.txt`, the `lib` symlink and `test/security/symbolic/`: `halmos --match-contract '^<Contract>$' --match-test '^<check_name>\(' --solver-threads 1 --solver-timeout-assertion 60000 --solver-max-memory 3000 --loop 3 --no-status --statistics [--solver bitwuzla]` | 20 of 31 properties proved; 11 undecided (timeouts on 512-bit `mulDiv`, no counterexample; each has a fuzz twin). Non-vacuity checked on mutated library copies. Detail: [`INVARIANTS.md`](INVARIANTS.md) |
| Medusa | 1.5.1 | From a sandbox with `src/libraries`, `src/interfaces/FundTypes.sol` and `test/security/medusa/`: `medusa fuzz --config test/security/medusa/medusa.json --workers 2 --test-limit 50000 --timeout 480` | 18 tests pass (72,287 calls, 347 branches); with the `firstMint` guard removed it finds the known DEC-061 residual in 5 calls |
| slither-mutate | 0.11.6 | `slither-mutate . --test-cmd "true" --contract-names <Lib> --comprehensive --output-dir enum_<Lib>` to enumerate, then run selected mutants against `FOUNDRY_FUZZ_RUNS=256 forge test -j 2` | `ShareMath` 45/60 caught at baseline, 5 more by `LibraryMutationKill`, 10 equivalent; `IncomeAccumulator` 47/60, 10 more, 3 equivalent |
| Echidna | not installed | | not run (Medusa used instead) |
| Gambit | not installed | | not run |

## Re-running the whole sweep

1. `forge build --sizes` and the three Foundry rows above, in that order, one at a time.
2. Slither with `--json`, diffed against `reports/raw/slither.json` ignoring line numbers; triage only what the diff
   adds.
3. Aderyn, Semgrep (both rule sets) and Solhint; compare counts with the table.
4. Halmos one property at a time from the sandbox; Medusa; mutation only when `ShareMath` or `IncomeAccumulator`
   changed.
5. Fork suites with fresh pins, then the local two-fork harness.
6. Record the numbers in this file and any new finding in [`FINDINGS.md`](FINDINGS.md).

CI (`.github/workflows/test.yml`) runs, with Foundry pinned to v1.7.1, `forge fmt --check`, `forge build --sizes` and the
non-fork suite in one job, and the fork suites (including the ported review PoCs whose file names contain `Fork`) in
another, with the fork blocks pinned to the latest block minus 300 at run time. Until 2026-10-01 every CI run failed
at `forge fmt --check` (an unpinned `stable` forge formatted two test files differently) and the fork suites could not
start (no block pins); the independent review found both. The analysis tools above are run by hand; the verification
plan's CI target (static-analysis ratchets, coverage, nightly fuzz and formal jobs) is in
[`VERIFICATION-PLAN.md`](VERIFICATION-PLAN.md).

## The independent review and the verification plan (2026-09-30)

The independent review ([`independent-review-2026-09-30/`](independent-review-2026-09-30/)) ran Slither, Aderyn,
Solhint and `forge coverage --ir-minimum` at `e5c778a` (coverage 97.31% lines, 83.67% branches; raw outputs in its
`raw/`) and 121 proof-of-concept tests, all ported onto main in `test/review/` on 2026-10-01 (see
[`CROSS-CHECK-2026-10-01.md`](CROSS-CHECK-2026-10-01.md)). The verification plan
([`verification-plan-2026-09-30/`](verification-plan-2026-09-30/)) assigns each of the 13 tools the founder listed to
each contract; Wake, Echidna, hevm, Kontrol and Scribble have not been run on this repository yet, and Manticore is
excluded (archived, no PUSH0, MCOPY or TLOAD support).
