# Test and verification plan for `smartcontract-v2` (2026-09-30)

What the founder asked, translated from the Portuguese brief: contracts are starting to be pushed to `PoolPartyLabs/smartcontract-v2`; select, for each one, which tests to do; build a plan that reaches the maximum possible coverage and says what must be done on each contract with the 13 tools of the list (Slither, Aderyn, Solhint, Wake; Echidna, Foundry, Medusa; Halmos, Mythril, Manticore, HEVM, Kontrol; Scribble); be defensive, and do formal verification on all of them if possible, thinking first about how to prepare it. Execution constraint: Fable coordinates, other models execute, at most two agents at a time.

This folder is the answer. It is a plan, not evidence: nothing in it has been run against the contracts except the read-only scans and builds named in `02-BASELINE.md` and one opcode scan recorded in `00-MASTER-PLAN.md` 2.1 row 5.

## Subject

| Item | Value |
|---|---|
| Repository | `PoolPartyLabs/smartcontract-v2`, branch `main` |
| Commit | `e5c778a` ("merge: feat/pp-sc-feat-integration into main", committed 2026-09-29), read-only clone |
| Size | 45 Solidity files, 9,044 lines under `src/`; about 19,000 lines of tests (declared by grep: 612 `test_`, 53 `testFuzz_`, 14 `invariant_`; `02-BASELINE.md` section 2 counts what `forge test` executes) |
| Toolchain | Solidity 0.8.28, EVM cancun, optimizer 800 runs, `via_ir = false`, OpenZeppelin 5.x; two linked libraries run by DELEGATECALL (`CoreVaultLogic`, `SpokeCrossChainLib`) |
| Date of every reading | 2026-09-30 |

Every code claim in these files cites `file:line` at `e5c778a`. A later commit needs the re-baseline of package FB2 (phase F of the master plan) before any number here is reused.

## What is in the folder

| File | Purpose | Lines |
|---|---|---|
| `00-MASTER-PLAN.md` | The plan: answer in one page, the contract by tool matrix (section 2), what to do on each contract (3), coverage targets and gate values (4), defensive suites (5), execution plan with 64 packages in 32 waves of two agents, gates, review rules, calendar (6), CI target (7), findings workflow and the register of 33 reproduced candidate defects (8), risks (9), founder decisions F-1 to F-14 and rulings R-1 to R-14 (10), Not verified (11) | 744 |
| `01-TOOLING.md` | Research on the 13 tools (versions, limits, fit with this repository), measured Foundry baseline, ready-to-copy configuration (foundry, Slither, Aderyn, Solhint, Wake, Echidna, Medusa, Halmos, Kontrol, hevm, Scribble, Mythril), GitHub Actions layout, verdict per tool, Step 0 spike list | 1,036 |
| `02-BASELINE.md` | What Foundry alone says about `e5c778a`: tests, fuzz, invariants, per-file coverage, the 81 zero-hit branches, lint warnings, build sizes, gaps of the existing suite | 1,293 |
| `03-FORMAL-VERIFICATION-PREPARATION.md` | How to prepare formal verification before any proof: tier ladder V0 to V4, registry and predicates, harness architecture, library link route, proof plan per contract, solvers, stop rules, vacuity detection, code-preparation proposals, effort | 845 |
| `modules/01-core-vault.md` to `modules/09-math-and-mandate.md` | One card per module group: surface, threat model, existing tests, property catalog (INV-CORE, INV-SPOKE, INV-SHARE, INV-REPORT, INV-V4, INV-AAVE, INV-BRIDGE, INV-FACTORY, INV-MATH), tool matrix, prioritised work items, formal readiness, open questions, adversarial review | 461 to 600 each |
| `_drafts/fv-design-a-bottom-up.md`, `_drafts/fv-design-b-spec-first.md` | The two formal verification designs that `03` judges and merges; kept as provenance, superseded by `03` | 871, 818 |
| `README.md` | This file | |

## How the plan was produced

1. Fable (the coordinator) fixed the scope and the facts it measured itself (file counts, installed tools, CI state), wrote each brief and reviewed every output. Executor models did the reading and writing, never more than two at the same time; the coordinator is not counted as an executor.
2. Three inputs first: the tooling study (`01`), the Foundry baseline (`02`) and nine module cards (`modules/`), each card written from the source at `e5c778a` with probes run outside the clone. Each card then went through an adversarial reviewer, whose corrections are listed in the card's section 11 and already applied.
3. Two independent formal verification designs (`_drafts/`: bottom-up proof engineering, and specification first) were written from the cards, and a judge scored them and merged them into `03` (its section 0 gives the scores and what came from where).
4. The coordinator integrated the four documents into `00-MASTER-PLAN.md`: one matrix, one property registry of 454 rows plus 8 system rows, 60 work packages of two lanes (Opus-class lane A for design, Sonnet-class lane B for expansion; 64 after step 5 added phase F), gates, CI and the defect register.
5. A completeness critic then attacked the master plan; its findings (24 problems: 1 blocker, 9 major, 14 minor, plus 9 missing items) were applied in place on 2026-09-30. The changes: static gates become ratchets until the triage is committed; a fix batch and re-baseline phase (F) before any proof, because the rulings change the code the proofs target; a bounded Mythril run on the four runtimes with no MCOPY; a Kontrol capacity measurement and a fallback; workflow skeletons on `main`; a staged spec-lint; Halmos `hcheck_` nets that really run; where heavy acceptance runs; one module-name table; phase 4 re-paired so no lane B package waits on its own wave; deployment scripts, sequencer downtime, an events-at-end gate, mock conformance, an assumption monitor and a chain-onboarding gate. Sections 2.2, 6.1.1, 6.7.1 and 10.4 of the master plan are new, and its totals moved from about 243 to about 277 agent-days and from 27 to 30 weeks to 30 to 35 weeks (section 6.9 shows the arithmetic).

## Reading order

1. `00-MASTER-PLAN.md` section 1 (one page), then section 10 (what the founder must decide) and section 6.9 (calendar and the three cuts).
2. `00-MASTER-PLAN.md` section 2 (the matrix) and section 3 (what to do per contract).
3. `03-FORMAL-VERIFICATION-PREPARATION.md` sections 0, 1 and 2 (meaning of "formally verified" and the preparation gates), then 3 to 5 for the design.
4. `01-TOOLING.md` sections 1, 10 and 11 (decisions, verdicts, Step 0), then 8 and 9 for configuration and CI.
5. `02-BASELINE.md` sections 3 and 4 (coverage and zero-hit branches) when sizing the first packages.
6. The module card of the contract you are working on, with its section 11 (review) last.

Where documents disagree, `00-MASTER-PLAN.md` 2.1 and 2.2 decide, then `03`, then the cards.

## Warnings

- Nothing was installed and nothing in the contracts repository was changed. The clone was read-only; the only additions were build artefacts (`out/`, `cache/`). Slither, Aderyn, Solhint, Wake, Echidna, Medusa, Halmos, Mythril, Manticore, hevm, Kontrol and Scribble are not installed on the coordinator machine; every version, flag and digest for them comes from their repositories as read on 2026-09-30 and is marked "Not verified" until a Step 0 package runs it.
- The numbers in `02-BASELINE.md` come from the coordinator machine (macOS arm64, 8 CPUs, 8 GB, shared with other sessions) and from two Foundry builds, not one: forge 1.0.0 for the runs made before 14:02 and forge 1.8.3 after the machine's default changed at 14:06. `02` says which is which; its primary figures are forge 1.8.3 (coverage 97.31% lines, 83.67% branches, 644 tests counted by 1.8.3 against 654 by 1.0.0), and the forge 1.0.0 figures are the cross-check (346 of 414 branches). `01-TOOLING.md` section 2 is mostly forge 1.0.0 and says where it is not. Wall times vary with the machine's load.
- All agent-day and week figures are planning estimates. Phase F is the softest (it depends on rulings that do not exist yet). Gate G1 of the master plan recalibrates them.
- The 33 candidate defects of the register (master plan 8.4) were reproduced by probes outside the clone or read from the code; none is an auditor's verdict, and every ruling is the founder's (master plan 10.3).
- "Formal verification on all contracts" is a tier per property with bounds and assumptions (V0 to V4), never a word per contract; Uniswap, Aave, Across, Wormhole and Chainlink behaviour, gas, economics and key management are outside every tier (`03` section 1.6).
- Every edit of the completeness review was applied in `03` on 2026-09-30, and the master plan sections 2.1 and 2.2 still take precedence wherever the documents differ.
- The repository is English only; these files follow that convention. No file uses the em-dash character.
