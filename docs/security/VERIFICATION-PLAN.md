# Test and formal verification plan: status against main

The founder commissioned, on 2026-09-30, a plan to choose for every contract which of 13 tools to run (Slither,
Aderyn, Solhint, Wake; Echidna, Foundry, Medusa; Halmos, Mythril, Manticore, hevm, Kontrol; Scribble), to reach the
highest coverage possible, and to prepare formal verification. The plan is in
[`verification-plan-2026-09-30/`](verification-plan-2026-09-30/) as written (snapshot at `e5c778a`, read-only; every
`file:line` there refers to that commit). This page records what it decides, what of it has happened since, and what
the founder still has to decide. It is not an audit, and nothing here is "proven" without a tier label.

## 1. What the plan decides

**"Formally verified" is a tier per property, never a word per contract** (plan `03` section 1.1):

| Tier | Claim | Evidence |
|---|---|---|
| V0 structural | writer, caller, selector, opcode sets, storage layout, link identity | Slither printers, `forge inspect`, scripts, diffed against baselines |
| V1 tested | no counterexample from unit, fuzz, invariant, differential or fork runs | green runs, corpora, coverage, mutation |
| V2 bounded | every path inside a recorded box (widths, array lengths, loop unrolling) is safe | Halmos plus hevm or forge symbolic agree, no bound warnings, every `cover_` reached |
| V3 step | one call keeps the property from any state satisfying the stated precondition | V3-bv (bit-vector, loop-free) or V3-k (Kontrol, no admitted lemmas) |
| V4 inductive | the property holds in every reachable state | V3 for every mutating step plus a base case and the frame gate |
| C composed | a system property argued from V3 or V4 premises | written argument per SYS row |
| Labels | FLAGGED (violation pinned), ACCEPTED (by a decision id), ASSUMED (external, fork-discharged), `conditional(A-x)` | |

Reporting rule: a label always carries its scope, engine, bounds and assumptions; TIMEOUT, `unknown`, a Halmos
`LOOP_BOUND`, an hevm partial exploration or a non-zero Kontrol `vacuous`/`stuck`/`bounded` is a failure, never a
pass. No tier proves Uniswap, Aave, Across, Wormhole or Chainlink behaviour, gas, economics (spot manipulation,
just-in-time income) or key management.

**Specification once, many engines.** A registry of 454 properties plus 8 system rows (SYS-1 base sync, SYS-2
solvency, SYS-3 third parties cannot move the Share Price, SYS-4 exit liveness, SYS-5 no replay, SYS-6 the Mandate is
never loosened, SYS-7a/7b no payment to the manager), each written once as a pure predicate and run by every engine
that can take it.

**Tool verdicts** (plan `00` section 2; Manticore SKIP everywhere: archived, no PUSH0, MCOPY or TLOAD). Mythril runs
only on the four runtimes that contain no MCOPY (`ManagerFeeVault`, `ManagerRegistry`, `TransitEscrow`,
`ChainlinkPriceSource`), because its opcode table has none; every other runtime, `ShareToken` included, is SKIP.

**Program.** 64 packages in 32 waves of two agents: phase 0 (toolchain pins, CI, baselines, registry), phase 1 (a
FLAGGED pin for every candidate defect, the 81 zero-hit branches), phase 2 (hostile stateful harnesses, fork
conformance, formal calibration), phase F (the founder's rulings applied as one fix batch, then a re-baseline),
phases 3 to 5 (proofs bottom-up, composition, release gate). Estimate: about 277 agent-days and 30 to 35 weeks for
everything; about 139 agent-days and 15 to 17 weeks for the defensive baseline (phases 0 to 2). The plan's own
strongest objection (section 9) is that proofs written before the rulings are partly thrown away; its answer is to
prove only after phase F.

## 2. What has happened since (as of 2026-10-01)

| Plan item | Status on main |
|---|---|
| Phase 0: CI that never passed | Fixed: Foundry pinned to v1.7.1, fork blocks pinned at run time, unit and fork jobs split, actions pinned by commit (independent review, process finding). Static-analysis ratchets, coverage gate and the per-tool jobs of plan section 7 are not in CI yet |
| Phase 0: baselines | Partly: Slither, Aderyn, Semgrep, Solhint baselines in [`reports/raw/`](reports/raw/) from the 2026-09-30 sweep, triaged in [`reports/static-analysis.md`](reports/static-analysis.md) and [`TOOLING.md`](TOOLING.md). No coverage baseline committed on main (the plan's 97.31% lines / 83.67% branches is at `e5c778a`) |
| Phase 1: pin every candidate defect | Done differently: the sweep and this cross-check turned each candidate into a regression test (`test_SEC_S<n>_*`, `test_REVIEW_*`) or a pin of a still-open item (`test_POC_*`); mapping in [`CROSS-CHECK-2026-10-01.md`](CROSS-CHECK-2026-10-01.md) |
| Phase 2: hostile stateful harnesses | Partly: the whole-fund suites in `test/security/invariants/` drive the real Core Vault, both Spoke Vaults and the receiver with an adversarial handler ([`INVARIANTS.md`](INVARIANTS.md)); not yet the plan's per-module harnesses, a moved spot price, deprecation, or the 32M-gas delivery bound |
| Phase 2: formal calibration | Partly: Halmos on the libraries and codecs (20 of 31 properties proved, the rest timed out on 512-bit `mulDiv`); hevm, Kontrol, Wake, Echidna and Scribble not run |
| Phase F: fix batch | In progress: the sweep fixed 16 findings and the cross-check 13 more items plus one regression of the sweep (S-45) ([`FINDINGS.md`](FINDINGS.md)); several rulings of plan section 10.3 are still open, so no freeze tag exists and phases 3 to 5 have not started |

**Correction to our own sweep's tool record.** The sweep ran Mythril on `ShareToken`, whose runtime contains one
MCOPY that Mythril 0.24.8 cannot execute; that "no issues" result is not evidence ([`TOOLING.md`](TOOLING.md)). Its
runs on `TransitEscrow`, `ManagerRegistry` and `ManagerFeeVault` stand. `ChainlinkPriceSource`, MCOPY-free and in the
plan's Mythril set, was not run.

## 3. Decisions the plan asks of the founder

Before any further wave (plan section 10.1); the research recommendation is the plan's, the decision is the founder's.

| # | Decision | Plan recommendation |
|---|---|---|
| F-1 | What "formal verification on all contracts" means | A tier per property with bounds and assumptions |
| F-2 | Scope and calendar | Commit to the defensive baseline (phases 0 to 2, about 139 agent-days, with phase F about 161) and choose the formal scope once rulings and the audit date are known |
| F-3 | Write access and branch policy for executors | Package branches, test-only, CODEOWNERS on `src/`, merged by the founder or a delegate |
| F-4 | `spec/` (registry, assumptions, status) in this repository | Yes |
| F-5 | Two test-only submodules (`a16z/halmos-cheatcodes`, the Kontrol cheatcode interface) | Yes |
| F-6 | Runner memory for Kontrol | Keep the repository public (free 16 GB runner) or budget a larger runner |
| F-7 | Archive RPC secrets for both chains | Provide; public RPCs prune state within minutes to an hour |
| F-8 | Is `ZeroSharePrice` from `requestPayout` a legal revert at truly zero Share Assets | Yes (since S-18 a claim at zero closes the request instead) |
| F-9 | Does the coordinator count toward the two-agent limit | No |
| F-10 | Refactor batch before the audit freeze | One batch, each refactor proven equivalent with `hevm equivalence` |
| F-11 | Mythril and Manticore verdicts, Scribble on the Across adapter | As scheduled (Mythril bounded on the four MCOPY-free runtimes) |
| F-12 | Script additions outside `src/` (`CheckFundPlan.s.sol`, wiring checks in `FactoryDeployment.sol`) | Allow |
| F-13 | SYS-7b: the manager chooses every swap minimum | Record an acceptance under DEC-030 or add a Mandate slippage bound (our register: S-8, open) |
| F-14 | Proof subject for phases 3 to 5, and who lands the fix batch | Rulings, one fix batch on a freeze tag, re-baseline, then proofs |

The defect rulings R-1 to R-14 of plan section 10.3 are mapped to their status in
[`CROSS-CHECK-2026-10-01.md`](CROSS-CHECK-2026-10-01.md) section 3.

## 4. Recommended order from here

The plan's leaner alternative (section 9), which this repository's state now favours: rule on the open items, land
one fix batch on a freeze tag, send that tag to an external audit, and run formal phases 3 to 5 on the audited and
fixed code. Cheap items worth doing before the audit: the static-analysis ratchets and a coverage job in CI, the
plan's 81 zero-hit branch gaps re-measured on main, the bounded Mythril run on `ChainlinkPriceSource`, and the
missing harness actions of [`INVARIANTS.md`](INVARIANTS.md) (moved spot, deprecation, delivery gas).
