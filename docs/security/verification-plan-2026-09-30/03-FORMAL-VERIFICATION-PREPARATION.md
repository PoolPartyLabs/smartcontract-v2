# 03 - Formal verification preparation

Read date 2026-09-30. Subject: every Solidity file under `src/` of `PoolPartyLabs/smartcontract-v2` at commit `e5c778a` (read-only clone, committed 2026-09-29 20:56 +0100). Inputs judged and merged: `_drafts/fv-design-a-bottom-up.md` (design A) and `_drafts/fv-design-b-spec-first.md` (design B), the nine module cards `modules/01` to `modules/09` (cited "card nn") and `01-TOOLING.md` (cited "T" plus its section). Code claims cite `file:line` at `e5c778a` with the keys below. Tool claims cite "T" with its section (sources [S1] to [S17] there) or a source [Fn] of Appendix B, with its read date. "Not verified:" marks anything unconfirmed, with what would confirm it. Property ids are the card ids (INV-CORE, INV-SPOKE, INV-SHARE, INV-REPORT, INV-V4, INV-AAVE, INV-BRIDGE, INV-FACTORY, INV-MATH); this document adds only system ids SYS-1 to SYS-7b, bundle ids `B-<MOD>-<NAME>` and well-formedness ids `WF-<MOD>`, each defined as a conjunction of card ids. Nothing was written to the clone; `out/` artifacts were read once (section 4.5).

| Key | File | Key | File |
|---|---|---|---|
| SM, IA, TM, RC | `src/libraries/ShareMath.sol`, `IncomeAccumulator.sol`, `TransitMessage.sol`, `ReportCodec.sol` | MD, FT | `src/mandate/Mandate.sol`, `src/interfaces/FundTypes.sol` |
| ST, MFV, MR, TE | `src/core/ShareToken.sol`, `ManagerFeeVault.sol`, `ManagerRegistry.sol`, `TransitEscrow.sol` | AG, AB | `src/adapters/AdapterGuard.sol`, `AcrossBridgeAdapter.sol` |
| CV, CVB, CVI, CVT, CVL, CVTy | `src/core/CoreVault.sol`, `CoreVaultBase.sol`, `CoreVaultIncome.sol`, `CoreVaultTransit.sol`, `CoreVaultLogic.sol`, `CoreVaultTypes.sol` | V4A, AA | `src/adapters/UniswapV4Adapter.sol`, `AaveV3Adapter.sol` |
| SV, SCL, SVT | `src/spoke/SpokeVault.sol`, `SpokeCrossChainLib.sol`, `SpokeVaultTypes.sol` | VRR, CLPS | `src/report/ValueReportReceiver.sol`, `ChainlinkPriceSource.sol` |
| FF, C3, CS, C3D | `src/factory/FundFactory.sol`, `Create3.sol`, `CodeStore.sol`, `Create3Deployer.sol` | OZM | `lib/openzeppelin-contracts/contracts/utils/math/Math.sol` (OZ 5.7.0) |

**Precedence and amendments (2026-09-30, after the completeness review).** `00-MASTER-PLAN.md` sections 2.1 and 2.2 override this document wherever they differ; a package brief must require the executor to read them first. Edits already applied here, each marked "Edit 2.1 row n" or "Edit 2.2 row n" at the line: registry as one file per module (2.1 rows 3 and 4: P-04, section 3.1, decision 3), price width `2^128` (2.1 row 9: section 5.14), `SymReceiver` conforming mode (2.1 row 12: section 4.6), the two-check link route (2.2 row 27: P-07, section 5.1, G0 row of section 9), Mythril (2.1 row 5: section 3.5, Appendix A), the lint stages (2.2 row 25: section 3.7), the Halmos net names and second invocation (2.2 row 24: section 3.4) and the K capacity fallback (2.2 row 22: section 10.1 item 9), and, applied on 2026-09-30 in a later pass, the WF bundles (2.1 row 10: section 5.2, where the WF-IA width conjuncts became assumption A-IA-CALLS, WF-ST reads ST slot 1 raw and WF-MFV was added), the tier rows (2.1 row 11: section 1.4, rows MFV, MR, VRR, AA, V4A, FF, SV and IA), refactor R-B1 read as R1b (2.1 row 13: section 6, rank 3) and the assumption names (2.1 row 17: P-05 and the register additions after the table of section 4.8). Phase order: this document's section 5 ladder is unchanged, but the master plan inserts a fix batch and re-baseline (phase F) before any proof of layers L0b to L6, because the rulings change those footprints (master plan 6.7.1, 10.4).

## 0. Judgment of the two designs, and what this document decides

Scores from 1 (weak) to 5 (strong), with the evidence that decided each.

| Criterion | A bottom-up | B spec-first | Decisive evidence |
|---|---|---|---|
| Soundness of what is claimed | 5 | 4 | A mechanises induction closure (`check_closure.py`: the step checks must equal the selectors whose writer set touches the property's reads), lints every `vm.assume` against a registered id, labels INV-CORE-03 "V4 modulo the INV-CORE-04 closure". B's T3 relies on a frame gate diffed against baselines but never compares writer sets with the step set; its summary-by-etch mode adds a trusted component (capped at T2 until proven, which is correct) |
| Feasibility on 8 GB and in CI | 4 | 3 | Both keep Kontrol on a 16 GB runner (T 5.12, T 9). A counts about 500 `check_` and 90 `prove_` obligations and estimates 136 agent-days; B estimates 85 agent-days for a larger scope (it adds a reference model, system composition and host harnesses) without an obligation count, so its figure is not reconciled |
| Reuse of properties across tools | 4 | 5 | Both: one registry, one predicate, thin drivers. B adds scalar-only predicates, bundles for mutual induction, the "expected-outcome" form (soundness and completeness in one check), runner paths in the registry and a generated Scribble overlay |
| Coverage of all contracts | 5 | 4 | A gives every unit its obligations with symbolic inputs, difficulty and fallback (A section 6); B gives spec functions and tiers per unit but no difficulty or fallback |
| DELEGATECALL libraries and protocol models | 4 | 5 | A: one link route for every engine plus a link-identity gate. B: four modes (real link, library in a host, summary by etch with an over-approximation obligation, confinement tests), a hub-pair harness for the one nested callback, conformance tests that cap any model-dependent status |
| Vacuity detection | 4 | 5 | A: reachability twins per asserted branch, a satisfiability witness for each WF, hand-written mutants. B: tool-native signals (Halmos REVERT_ALL and LOOP_BOUND, hevm partial and all-revert, `kontrol list` fields), cover checks, assumptions re-checked as fuzz properties, `forge test --mutate` against the formal suite, proven predicate totality, model-switch coverage |
| Maintainability | 4 | 4.5 | A: committed status ratchet, closure check, generated slot maps. B: statuses keyed by bytecode hash (auto-invalidated on change), impact analysis from registry footprints, `test/regression/` for every counterexample |
| **Total (of 35)** | **30** | **30.5** | |

**Backbone: design A.** The totals are a tie within noise; the choice follows the two criteria that cannot be retrofitted. A's tier semantics (closure checked by machine, two-engine agreement, assumption lint, proof classes derived from card 09's measured probe) and its per-contract obligation lists are the load-bearing structure of every later section; importing them into B would be a rewrite. B's winning ideas are layers that attach to A without changing its semantics: the specification layer, the system invariants, two library modes, the model conformance cap, four vacuity mechanisms and the bytecode-keyed status. Appendix A lists what came from where and what was discarded.

What this document decides:
1. "Formal verification on all contracts" means a **tier per property with its bounds and assumptions**, computed by CI from tool output, never a word per contract (section 1). Every contract reaches at least V2 on access control, guards and frames; V3 and V4 targets are listed per contract in section 1.4.
2. **Nothing is proven before the preparation gates of section 2 are green**: pinned toolchain, reviewed registry, validated link route, generated and proven slot maps, vacuity machinery, the Kontrol go or no-go.
3. **Single source of truth**: the registry, one file per module under `spec/registry/properties/` plus `system.yaml` and `assumptions.yaml` (Edit 2.1 row 3), and total pure Solidity predicates in `test/spec/`; every tool is a thin consumer (section 3).
4. **Proof class decides the engine** (section 1.2): control and linear accounting go to the bit-vector engines first; nonlinear rounding goes to Kontrol with one proven lemma file, because 11 of 17 bounded probes timed out or returned unknown on floor division (card 09 section 9.5).
5. **Linked libraries** run by the same pre-linked bytes under every engine, with a per-PR link-identity gate; per-function steps run in a host contract, whole-vault properties through the real vault (section 4.5).
6. **External protocols are havoc models for safety and conforming models for function**, each conforming model tied to a fork or real-code conformance test, and a consumer's status is capped by its discharger's (sections 4.6, 4.8).
7. **Execution order is bottom-up** (section 5): calibration, pure libraries, small contracts, scalar cores, adapters, factory, library hosts, vaults, composition.
8. **No `src/` change is needed to start.** Refactors that make proofs cheaper are one founder decision, one batch before the audit freeze, each proven equivalent with `hevm equivalence` (section 6).
9. Effort: about 148 agent-days for the full plan (18 to 20 weeks with two executor agents), about 110 for a credible minimum (13 to 14 weeks); both Not verified until gate G1 (section 9).

## 1. What "formally verified" means here

### 1.1 Tier ladder

Two axes: **scope** (how much of the state space the result covers) and **engine evidence** (which engines closed it). Every label carries both, plus its bounds and assumption ids.

| Tier | Claim | Evidence (machine-read by `tools/props/spec-status.py`) | What it does not say |
|---|---|---|---|
| V0 structural | A fact about all code: writer set, caller set, selector set, opcode set, storage layout, call order, link identity | Slither printers and scripts, `forge inspect`, opcode scan, diffed against committed baselines | anything about values |
| V1 tested | No counterexample from unit, fuzz, stateful invariant (forge, Echidna, Medusa), differential or fork runs | green runs, corpora, coverage and mutation score on the footprint | absence of bugs |
| V2 bounded | Every path inside a recorded box (widths, array lengths, loop unrolling, concrete parameter rows, model modes) is safe | PASS in Halmos and in hevm or `forge test --symbolic`; no Halmos `LOOP_BOUND` warning and no `REVERT_ALL` error [F6]; no hevm partial exploration, unknown or "all branches reverted" [F7]; every `cover_` twin reached | behaviour outside the box; a width bound narrows the claim itself |
| V3 step | For every pre-state satisfying the stated precondition (a WF bundle plus type widths only), every caller and argument, one call keeps the property | **V3-bv**: V2 evidence with an empty bound list on a loop-free class A or B check (section 1.2). **V3-k**: `kontrol list` shows `status: PASSED`, `admitted: False` and zero `pending`, `failing`, `vacuous`, `stuck`, `bounded` [F8]; every lemma used is proven or registered | that the precondition holds in reachable states |
| V4 inductive | The property holds in every reachable state | V3 for every step selected by `check_closure.py` (the mutating selectors whose V0 writer set touches a variable in the property's `reads`), a base-case unit test on the real constructor, the V0 frame gate, and every precondition conjunct itself V4. **V4-k** when every step is V3-k | anything carried by its assumptions A-* |
| C composed | A system property (SYS-n, section 1.5) closed by a written argument whose premises are V3 or V4 properties or registered assumptions | `spec/composition/SYS-n.md` reviewed by the coordinator; status = minimum over premises, capped at C | premises that are assumptions |
| Labels | FLAGGED (expected violation pinned, `cover_` must stay reached), ACCEPTED (violation accepted by a decision id), ASSUMED (external behaviour, fork-discharged), `conditional(A-x)` (holds only under a false or unchecked internal assumption) | pin green; decision id; fork test id | |

Trusted base, stated once. Halmos, hevm and Kontrol all execute the forge-compiled bytecode (T 5.8, 5.11, 5.12), so the compiler's translation is checked on every explored path by each of them; they differ in completeness (bounded exploration for Halmos, hevm and forge symbolic) and in the executed semantics (KEVM is a formal semantics, Halmos and hevm are interpreters, so their agreement is two opinions, not a proof of either). The proven artefact is the `verify` build (libraries linked at fixed addresses, T 8.1), so assumption **A-BUILD** (deployed runtime equals the verify runtime except at link offsets, immutable offsets and the CBOR tail) is discharged by the link-identity gate on every PR and the masked byte diff of the release gate (section 7). Solvers and the Kontrol lemma file are in the trusted base; every lemma is proven once or registered as `A-LEM-n`.

A unit is **FV-complete** (B's definition, computed by the registry, never declared) when: every mutating selector has a caller-set property at V3 or above; every storage variable has a V0 writer set and a V3 step property; every value-moving function has a V3 conservation step; every liveness property is V2 per failure cell or FLAGGED; every external behaviour is a registered assumption with a fork discharge.

### 1.2 Proof classes (why the tools are split the way they are)

| Class | What the solver must decide | Example | Measured or expected behaviour | Primary engine | Secondary |
|---|---|---|---|---|---|
| A control | comparisons of callers, flags, states, small integers; storage equal before and after | `onlyHubSpokeVaultCallback` CVB:174-178; `_checkQuote` guards SCL:216-218 | no arithmetic in the assertion; expected to close in seconds | Halmos, hevm (V3-bv when loop-free) | Kontrol at release |
| B linear accounting | equalities between ledger fields and balance deltas where the moved amount is an opaque term | `_s.unallocated[baseToken] -= amount; _s.operatingCash = cash + amount` SV:994-995 | the assertion is linear; `mulDiv` branch conditions only multiply paths (Halmos explores both sides of an unknown branch at a 1 ms branching timeout, T 5.8) | Halmos, hevm | Kontrol |
| C nonlinear rounding | floor or ceil facts with a symbolic or large non-power-of-two divisor, 512-bit `mulDiv`, Q128 identities | `Math.mulDiv(usdcNet, PRICE_SCALE, price) * WHOLE_SHARE` SM:73; `Math.mulDiv(amount, Q128, totalShares)` and `mulmod` IA:194-195 | 11 of 17 probes timed out or returned unknown at 60 to 120 s down to 32-bit inputs; power-of-two divisors closed in 0.08 s, a constant 25 bps rate in 4.85 s with bitwuzla; a false statement was refuted (card 09 section 9.5) | Kontrol over unbounded integers with the lemma file (section 5.15) | bit-vector engines for counterexample search, concrete-rate rows and power-of-two smoke; full-range differential against the reference model as fallback evidence |

Consequence: every class C property is written twice, as a portable `check_` restricted to what the bit-vector engines close (concrete rates, power-of-two supplies, quotient-witness form) and as a `prove_` over full ranges; the registry records which one delivered the tier. Not verified: that Kontrol closes class C at all; the go or no-go of gate G0 (section 2, item P-10) decides it in one agent-day by reproducing probe checks 4 and 10.

### 1.3 Reporting rules

1. The word "proven" without a tier label is never used in docs, PRs, the README or messages to the founder or an auditor; badges and summaries are generated from the status file.
2. Every label shows scope, engine, bounds and assumptions, for example "INV-CORE-03: V4 (steps V3-bv) on 15 selectors, modulo the INV-CORE-04 closure, conditional(A-USDC); `handleV3AcrossMessage` step conditional(A-ACROSS-1) (CF-5)" or "INV-REPORT-17: V2 [arrays <= 2]".
3. A V4 closure in which some steps are only V2 is reported with those steps and their bounds listed, for example "INV-SPOKE-01: V4 [steps V2: `closePosition` keys <= 3; `sendToHub` concrete nonce; `report` arrays <= 3; `unwindForPayout` 2 steps, 3 positions]". It is never shortened to "V4".
4. TIMEOUT, solver `unknown`, Halmos `LOOP_BOUND` or `REVERT_ALL`, hevm partial exploration, and any non-zero `vacuous`, `stuck`, `bounded`, `pending` or `failing` in Kontrol are failures, never passes.
5. A counterexample becomes a finding only after concrete replay in forge (hevm treats keccak as uninterpreted and can print non-reproducible counterexamples, T 5.11); the replay lands in `test/regression/` (section 7.3).
6. FLAGGED properties are carried as `cover_` obligations whose counterexample is the pinned defect plus a forge pin `test_<DEC>_FLAGGED_<slug>`; the specification is never bent to match the code. A founder ruling that fixes the code flips the `cover_` into a `check_` in the same PR.

### 1.4 Per contract: tier targets, what is proven unbounded, bounded (with the bound), and what stays out

"Out" gives the tier actually reached and the reason. Property numbers are card ids of that module. Bounds are defined in section 5.14. The headline is the sentence the founder may use once every row of the unit reaches its target.

| Unit (lines) | Headline | Unbounded (V3 or V4) | Bounded V2 (bound) | Out: tier and reason | Assumptions |
|---|---|---|---|---|---|
| TM (45) | codec proven for every message the vaults build | INV-BRIDGE-24, 25, 27 at length 160 (every vault message is 160 bytes, TM:31) | INV-BRIDGE-26 at lengths {0, 1, 31, 32, 33, 159, 160, 161, 192, 1024} | trailing bytes accepted: `cover_` FLAGGED (AB-5, card 07) | none |
| RC (128) | codec round trip proven per shape | INV-REPORT-17 per fixed shape S0 to S2 (V3-k) | INV-REPORT-17, 18 with every array of length 0 to 2 | INV-REPORT-36 V0; trailing bytes `cover_` (CF-R8) | A-SOLC outside the shapes |
| MD (379), FT (82) | validator sound and complete for Mandates up to 2 elements per array (3 bridge adapters) | INV-MATH-37, 38, 42 only with Kontrol loop invariants (optional) | INV-MATH-37, 38, 42 (lengths 0 to 2, bridge adapters 3), 44; 40 as encoding injectivity | 39 `cover_` until MM-1 ruling; 41 V1 plus V0 writer set; 43 V1 differential; 45 gas V1; 19, 20, 34, 35, 46, 47 V0 (pure, call graph, ABI diff); 48 economic (1.6) | A-KECCAK, A-ABI |
| SM (126) | on GO: rounding lemmas proven (V3-k); on NO-GO: proven per fund configuration, tested at full range | INV-MATH-01 to 12, 16, 18 (05 restricted to price `>= 1e18`) with lemmas L0 to L6 | 13, 14, 15 per concrete rate row; 01, 08, 17 at power-of-two prices (smoke, never counted as V3) | 19 V0; 05 below `1e18` `cover_` (MM-3); 15 above cap `cover_` (CF-1, MM-2); 17 zero price `cover_` (MM-4) | A-MULDIV outside the single-word domain |
| IA (276) | accumulator step proven; sums composed | V3-bv: INV-MATH-21, 23a (never reverts, class B), 24, 26, 30, 31, 32; V3-k: 22, 23b (the exact `false` condition, class C), 25, 27, 33 and the delta lemmas of 28, 29 (Edit 2.1 row 11: 23 split) | 22, 23, 24 at power-of-two supply (smoke); 25 with 2 tokens (exact by 32) | 20, 34, 35 V0; literal sums 28, 29 V1; 36 `cover_` at the Core Vault (MM-5) | A-DISCIPLINE, A-WHOLE, A-LEDGER |
| C3 (80), CS (71), C3D (36) | address derivations proven | INV-FACTORY-03, 05, 06, 07, 37 | INV-FACTORY-18 at lengths 1, 32, 64 symbolic; 24,575, 24,576, 49,151 concrete | none | A-KEC, A-161 |
| AG (54) | guard proven once, re-checked on each adapter's bytecode | INV-V4-03, 07, 08 (V4), re-run on V4A, AA, AB, which discharges INV-AAVE-02, 08 and INV-BRIDGE-12, 13 | none | none | none |
| ST (79) | fully proven | INV-SHARE-01 to 06, 10 to 12 (V4) | none | 07, 09 V0; 08 events V1 (bit-vector engines do not assert logs) | none |
| MR (73) | fully proven (discharges A-REG for the MR runtime) | INV-SHARE-21 to 27 (V4) | none | 28 events V1; 31 V1 regression on the real hub Spoke Vault, not a pin (SF-3 is refuted; Edit 2.1 row 11); 30 and 32 fund side: unit pins FLAGGED (SF-1, SF-4) | none |
| MFV (44) | proven except token behaviour | INV-SHARE-13 (a), the token-independent form: no CALL unless the caller is the manager (V4, no token model; Edit 2.1 row 11) | 13 (b), the balance form under the standard token model, V2 until the `SymToken` standard-mode conformance test is green (Edit 2.1 row 11); 14, 15, 19 per token mode | 16 to 18 V0; 20 FLAGGED (SF-2) | A-TOKENS |
| TE (39) | proven except Across and token | INV-SHARE-33 to 36 (V4) | 38 with concrete salts | 37, 42 V0; 39 to 41 V1 and unit (SF-5) | A-ACROSS-2 |
| AB (130) | builder proven; Across assumed | INV-BRIDGE-01 to 09 (build side of 09), 11 to 13, 30 (adapter half) at message length 160 | 02 and 04 at other lengths; 16, 18 (one call, 6 pool modes), 23 (sequences up to 4), 29 | 10, 14, 15, 28 V0; 17, 19, 22 fork; 20 (AB-2) and 21 ASSUMED; 31, 32, 34, 35 unit; 33 differential (V1) | A-ACROSS-1 to 9, A-ACROSS-GOV |
| CLPS (158) | proven per feed configuration row in the single-word range; A-PRICE FLAGGED | INV-REPORT-19 (with the V0 "no SSTORE, no CALL" scan), 20, 21 per row in the single-word range, 23, 24; 22 V3-k | 22 per row with `x * p < 2^256`; 25; 28 with `(fd, td)` in `[0, 60]` | 26 `cover_` (CF-R2); 27 FLAGGED (CF-R3), fork; 29 unit (CF-R6) | A-CL1, A-CL2, A-USD |
| VRR (286) | acceptance and replay proven; gas tested | INV-REPORT-01, 02, 04, 10, 11, 13, 34 on the scalar core plus lemma L-SHAPE; 03 V4 by induction | 06, 08, 09, 12 (non-gas half), 18, 32 at shapes 0 to 2 and up to 3 spokes | 05, 07, 14, 15, 35 V0 (07 is structural: VRR has no `try`, no low-level call and exactly one `CALL`, so a failing callback reverts the delivery by EVM revert semantics and a symbolic proof of the value statement would be vacuous; Edit 2.1 row 11); 16, 30 V1 (system); 31 gas V1; 33 `cover_` (CF-R5, `block.timestamp == 0`) | A-WH1 to A-WH3, A-SPOKE, A-TIME |
| AA (528) | ledger steps proven; Aave assumed | 22 targets at V3 or V4: class A and B (17): INV-AAVE-01, 02, 03, 05, 07, 08, 13, 15, 18, 24, 26, 29, 32, 33, 36, 37, 38; class C (5; V3-k with lemmas L7, L9): 14, 16, 21, 27, 31 | 14 targets at V2: 04 with a recording token; 09 to 12, 17, 22, 28, 34, 35, 47 to 50 (index set, values `< 2^96`, params lengths {0, 32, 64}, prefix of at most 2 calls; 09, 28 and 50 are carried as `cover_` until the F1, F2 and F11 rulings; 48 to 50 were added by the card review) | 1 target at V0: 06 (opcode scan; the counts 22, 14 and 1 are the tier split of card 06, Edit 2.1 row 11); 19, 20, 23, 25, 30 V1; 44, 45 fork; 39 to 43, 46 unit; 09, 23 (F1), 28 (F2) `cover_` | AS1 to AS7 |
| V4A (735) | guards, plan and sizing proven; Uniswap equivalence tested | INV-V4-01, 02 (first part), 03, 07, 08, 09, 11 step (V3-bv, conditional(A-V4-3): `openPosition` must not overwrite an open id), 12, 31, 44; 45 V3-k only with `getSqrtPriceAtTick` uninterpreted, else V2 per tick window (Edit 2.1 row 11); 05, 06 at plan level; 14 under the Permit2 summary; 18 per step; 25, 38 V3-k (lemmas L7, L8) | 13, 17, 20, 27, 28, 37 at concrete tick windows; 15, 16, 30, 32, 33, 35, 46 bounded by the `SymV4` model; 11, 19 at depth | 10, 19, 21, 22, 29, 34, 39, 40 V1 (local real-V4 tier, fork); 04, 23, 36, 43 V0; 24, 26, 41 unit (24, 26 FLAGGED); 10 `cover_` (CF-V4-1); 42 FLAGGED (CF-V4-2) | A-V4-1 to A-V4-4, A-TOKEN, A-SV |
| FF (511) | derivations and guard prefixes proven; deployment bounded on stubs | INV-FACTORY-01, 02, 16 and the `createFund` halves of 24 and 38 (guard prefixes); 12 and 13 steps on the stub factory (13 is the write-once step: slots 1 and 2 written for exactly one key each per `createFund`, nothing else); 23 only after R-FF1 (Edit 2.1 row 11) | 09, 10, 14, 19, 21, 22, 25 and the `createSpoke` halves of 24 and 38 (stub factory, Mandate arrays 0 to 3, one prior creation; 25: wiring passed verbatim to the children; the `createSpoke` halves follow `m.hash()` and the `spokeByChainId` loop, so they are V2 [arrays 0 to 3]; Edit 2.1 row 11) | 04, 28, 31, 39 V0; 29 release gate W8 plus fork; 15, 17 `cover_` (FF-1, FF-2) plus release gate; 33 FLAGGED (FF-6); 34 (FF-5, owned by the core card), 35 (FF-1 to FF-3), 36 (owned by INV-REPORT-29) unit pins; 08, 11, 20, 26, 27, 30, 32 V1, unit, fork (13 moved to the unbounded column as a V3 step, Edit 2.1 row 11) | A-KEC, A-161, A-6780, A-SIZE, A-OP, A-VIEW, A-CORE |
| SV (1,004), SCL (352), SVT (158) | backing proven for the loop-free verbs; report and unwind bounded | B-SPOKE-BACKING = INV-SPOKE-01, 05, 06, 47: V3 steps on the 13 loop-free writers, closure V4 with the 4 bounded steps listed (rule 1.3-3); 03, 07, 19, 20, 22, 42, 46 V3; 02 conforming form V3 per value-moving loop-free selector (`delta L(t) == delta B(t)` with the moved amount an opaque term, class B, section 5.15 item 8; Edit 2.1 row 11); 10 V3-bv per concrete `maxBridgeFeeBps`, V3-k general; 23 ring formula V3; 38 optional V3-k | 01 steps of `closePosition`, `sendToHub`, `report`, `unwindForPayout` (structure bounds of 5.14); 05, 08, 09, 11 to 14, 16 to 18, 21, 24, 26 (MCOPY layout), 29 to 31, 33, 36, 40, 44, 45 | 15 V0 writer set; 04, 25, 27, 28, 32, 34, 37, 41 V1; 35 gas; 39 unit; 43 system harness; 48 FLAGGED (T2); 49 fork; 02 hostile form `cover_` | A-SPK-1 to A-SPK-6 (card 02 A1 to A6) |
| CV, CVB, CVI, CVT (867), CVL (762), CVTy (135) | "no reachable state breaks the ledger bundle"; sums composed; exit matrix bounded per cell | B-CORE-LEDGER = INV-CORE-01, 02, 03, 05 (V4, 03 modulo the 04 closure; 01 conditional(A-USDC), its `handleV3AcrossMessage` step conditional(A-ACROSS-1); 02 under A-TOKENS); 12, 32, 33, 38 per writer, 40, 55 V4; 08 donation step (symbolic `deal`), 29, 30 V3; 14 to 17, 50 V3-k through the ShareMath lemmas | 06; 07, 47 (2 spokes, arrays of 2, up to 5 priced tokens); 09, 10, 11 (recording token), 21 and 27, 48 per exit-matrix cell, 22, 23, 25, 26, 34 to 37, 41 to 43, 49, 53, 54 | delta lemmas V3 plus literal sums V1 for 04, 39, 44, 51, 52; 18, 24, 28, 46, 59 V1; 19 fork; 13, 56, 58 V0; 31, 57 unit; 20, 45 `cover_` (CF-1, CF-5) | A-USDC, A-TOKENS, A-ACROSS-1, A-ACROSS-2, A-RECV, A-PRICE (false: conditional), A-REG, A-HUBSV (liveness only), A-LIB, A-TIME, A-KECCAK |
| Interfaces and type files | structural only | none | none | V0: selector sets, ABI and storage layout diffs (INV-MATH-46, INV-CORE-58, slot maps of section 4.3) | none |

Rows not in the table: INV-SHARE-29 is proven as INV-CORE-50 on the real code (card 03 section 10.3 item 2); the cross-cutting INV-SHARE-43, 45 are V0 gates and INV-SHARE-44 (events, SF-6) is a FLAGGED unit pin.

### 1.5 System invariants (tier C)

Each SYS row is stated over a whole fund and closed in `spec/composition/SYS-n.md` from the premises listed (B section 3). The last column is the truth at `e5c778a` per the cards' executed probes.

| Id | Statement | Premises (card ids) | Truth today |
|---|---|---|---|
| SYS-1 base sync (DEC-104, DEC-080, DEC-092, DEC-085) | every unit of recognised value is in exactly one base and moves between bases in the block of its share | INV-CORE-06, 39, 44, 47, 51; INV-SPOKE-05, 26, 27; INV-V4-46; INV-AAVE-22; INV-SHARE-39; INV-REPORT-06 | conditional: slow fills pay `updatedOutputAmount` (AB-2); NAV gap between pruning and refund (card 02 T6) |
| SYS-2 solvency (DEC-080) | for every fund contract and token, balance covers ledger; income owed never exceeds the bucket | INV-CORE-01, 02, 52; INV-SPOKE-01; INV-AAVE-14; INV-V4-15; INV-BRIDGE-15; INV-MATH-28 | conditional(A-ACROSS-1) on the hub: `handleV3AcrossMessage` credits without a backing check (CF-5) |
| SYS-3 third parties cannot move the Share Price (DEC-080, DEC-035) | with valuation inputs frozen, no call by a non-shareholder changes `sharePrice()`; own deposits and exits move it by at most the rounding bound | INV-CORE-08, 13, 15, 16; INV-SPOKE-04, 21; INV-REPORT-13; INV-SHARE-16; INV-FACTORY-30 | FLAGGED: sub-unit price mints for free (MM-3); in-transaction spot moves (CF-6, card 02 T4, CF-R7) stay fork-measured |
| SYS-4 exit liveness (DEC-021, DEC-056, DEC-068) | for every subset of failing dependencies, `requestPayout` opens and `claimPayout` pays the payable part or reverts only with the named "nothing payable" errors | INV-CORE-21 to 27; INV-SPOKE-07, 29, 30, 40; INV-V4-09, 21; INV-AAVE-07, 09, 10, 47; INV-BRIDGE-11, 23; INV-SHARE-12, 20; INV-REPORT-12, 24, 25; INV-MATH-15, 17 | FLAGGED cells: CF-1, CF-2, CF-3, CF-4, CF-R2, CF-9, card 02 T2 and T5, F1, AB-1, CF-V4-2 |
| SYS-5 no replay (DEC-093, DEC-066, DEC-090) | no VAA, transit id, escrow, fill, salt or report application takes effect twice | INV-REPORT-03, 04, 33; INV-CORE-40, 44, 46; INV-SPOKE-12, 45; INV-SHARE-33, 38; INV-FACTORY-09 | holds with `block.timestamp >= 1` made explicit (CF-R5) |
| SYS-6 the Mandate is never loosened (DEC-053, DEC-058, DEC-110) | after creation no call widens the manager's authority, targets, codehashes or fees | INV-CORE-32, 33, 57, 58; INV-SPOKE-15, 16; INV-V4-04, 07; INV-AAVE-03, 08; INV-BRIDGE-13, 14; INV-FACTORY-04; INV-REPORT-19; INV-MATH-41, 44 | ACCEPTED: Operating Cash floor and top-up are unbounded live parameters (DEC-100; CF-7, card 02 T1); FLAGGED: a spoke may run under another Mandate (FF-6) |
| SYS-7a no direct payment to the manager (DEC-087, DEC-107, DEC-109) | every token leaving a fund contract goes to a destination fixed by code or immutables; the manager's only inflow is the fee vault's `fee - slice` | INV-CORE-11, 50; INV-SPOKE-17; INV-V4-06; INV-AAVE-04; INV-BRIDGE-04, 07, 08; INV-SHARE-13, 17 | holds, except the bridge fee paid to a manager-named exclusive relayer, bounded per send by `maxBridgeFeeBps` (CF-10) |
| SYS-7b no indirect payment through the market (corpus MGR-1) | value lost to manager-routed trades is bounded by a Mandate policy | none exists: `minAmountOut` is manager-chosen (SV:333-345, check at SV:800) and the Mandate has no slippage field (MD:87-103) | ACCEPTED under DEC-030 per card 02; kept in the registry so the gap stays visible (founder decision 10.1 item 5) |

### 1.6 What no tier in this plan proves

- Uniswap V4 and Aave V3 semantics: bit-exact equality of the adapter's arithmetic with Uniswap's (INV-V4-20) and Aave's rounding (AS2) stay V1 (local real-V4 tier, forks); a one-wei divergence would block exits (card 05 item 3).
- Across and Wormhole behaviour (A-ACROSS-1 to 9, A-WH1 to 3), upgradeable under their governance.
- Gas budgets (INV-CORE-28, INV-SPOKE-35, INV-REPORT-31, INV-FACTORY-27): hevm does not track gas (T 5.11).
- Economics: spot manipulation (INV-CORE-19, INV-SPOKE-49, CF-R7), just-in-time income (INV-MATH-48), SYS-7b.
- keccak injectivity (A-KECCAK), per-chain timestamp monotonicity (A-TIME), EIP-6780 and EIP-161 behaviour per chain (A-6780, A-161).
- Multi-transaction properties no bundle implies (INV-CORE-18, INV-SPOKE-27, INV-AAVE-19, 23): V1 with the reference model as oracle.

## 2. Preparation checklist (before any proof is written)

Gate G0 closes items P-01 to P-12; gate G1 closes P-13 to P-18 with the first V4 result. No `check_` or `prove_` counts toward a tier before its gate is green. "Lane" is the executor slot of section 9 (A stronger model, B smaller model); the coordinator (Fable) reviews every item.

| # | Item | Done when (evidence) | Why, and the risk if skipped | Lane | Gate |
|---|---|---|---|---|---|
| P-01 | Freeze the subject | commit or audit-freeze tag recorded in `spec/baseline/`; per contract: `forge inspect` method identifiers, storage layout, runtime hash with link slots zeroed and CBOR tail stripped; library runtime hashes | any edit to a source file, whitespace included, changes the metadata and the bytecode [F9]; the Spoke Vault pins adapter codehashes at construction (SV:188-195) and the factory pins the Core Vault creation-code hash (FF:115, FF:154-157), so a proof about unrecorded bytes may be about a different artefact | B | G0 |
| P-02 | Freeze interfaces and type files | ABI and layout diff gate (V0) on `src/interfaces/*`, FT, CVTy, SVT is blocking; a diff needs a registry edit in the same PR | predicates read views and struct shapes; a silent interface change invalidates observers without failing a proof | B | G0 |
| P-03 | Fix layout and naming | section 3.1 tree and section 3.4 prefixes adopted; card work items renamed from `test/symbolic`, `test/invariant`, `test/echidna`, `test/medusa` to this layout (every card lists this as an open point, e.g. card 01 section 10.3) | two layouts would split drivers of one property across directories, and the lint of section 3.7 could not find orphans | coordinator | G0 |
| P-04 | Extract and review the property catalog | `spec/registry/properties/<module>.yaml` (one file per module, plus `system.yaml`; Edit 2.1 rows 3 and 4) holds the 454 rows of the reviewed cards (66 core, 55 spoke, 52 share, 42 report, 51 V4, 51 Aave, 39 bridge, 44 factory, 54 math; the 404 of the first card versions grew by INV-CORE-60..66, INV-SPOKE-50..55, INV-SHARE-46..52, INV-REPORT-37..42, INV-V4-47..51, INV-AAVE-48..51, INV-BRIDGE-36..39, INV-FACTORY-40..44, INV-MATH-49..54) plus 8 SYS rows; each row has statement, DEC ids, corpus id, class, reads, expected, target tier; duplicates resolved: INV-SHARE-29 is proven as INV-CORE-50 on the real code (card 03 section 10.3 item 2), INV-FACTORY-34 is owned by the core card and INV-FACTORY-36 by INV-REPORT-29 (card 08 section 10.3 item 5), MM-2 is CF-1 and MM-4 is CF-9 (card 09 section 10.3 item 5) | a predicate written twice drifts; double-counted findings mislead the founder | A writes, coordinator reviews against decision text | G0 |
| P-05 | Build the assumption register | `spec/registry/assumptions.yaml` with every A-* of the cards, its consumers, discharger and model; name collisions removed (card 02's A1 to A6 become A-SPK-1 to A-SPK-6; A-KEC merges into A-KECCAK; A-TOKEN stays per-pool, A-TOKENS per income token; Edit 2.1 row 17: card 07 is the single list of A-ACROSS-*, with A-ACROSS-2 split into 2a and 2b and 1c and 10 to 12 added, and its token assumption, called A-TOKEN there, renamed A-BRIDGE-TOKEN so that A-TOKEN stays the per-pool name; names added to the register: A-WIRING (card 05), A-IA-CALLS (card 09), A-KEEPER (card 01), A-WH4 (card 04), A-ADDR, A-7702, A-OPKEY, A-MGR-ADDR (card 08), each with its one-line meaning in section 4.8, so that every consumer cites one row); the three internal assumptions already known false or unchecked marked: A-PRICE (INV-REPORT-26, CF-R2), A-REG for a non-MR address (SF-1), A-SPK-1 adapter conformance (Aave F1 and F6, CF-V4-1; INV-SPOKE-25 takes the epsilon `2 * ceil(I / 1e27)` per Aave call, card 06 section 10.3 item 1) | without it a consumer silently relies on a false premise (section 4.8 caps it) | A | G0 |
| P-06 | Pin the toolchain in isolated environments | versions and digests recorded in `spec/toolchain.lock` and printed into every status entry: Foundry v1.8.3 (T 1 item 1); Halmos 0.3.3 through `uv tool install --python 3.12 halmos==0.3.3` with yices 2.6.4, z3 and bitwuzla 0.8.1 (T 5.8); hevm 0.58.0 release binary with its sha256 (T 5.11) plus z3 and a bitwuzla binary (Not verified: bitwuzla binary packaging for macOS and the CI image, card 09 section 10.1); Kontrol 1.0.255 from the `runtimeverificationinc/kontrol` image pinned by digest (T 5.12; Not verified: published tags); Slither 0.11.6, Echidna 2.3.3, Medusa 1.5.1, Scribble 0.7.10 (T 4.1). Nothing global: Docker or `uv`/venv only | Halmos is stale since 2025-07-31 and forge symbolic is a preview (T 4.1, 5.6); Halmos results already differ between runs when solver timeouts fire (T 5.8), so every other source of variation must be removed | B | G0 |
| P-07 | Validate the library link route | `[profile.verify]` of T 8.1 builds; `tools/gen-linked-lib-code.sh` output patched as in section 4.5; one Core Vault `deposit` check and one Spoke Vault check (both kept in `F0SmokeFormal`, package A02; Edit 2.2 row 27: the Spoke route with its patched etch and the `CREATE2` escrow at SCL:51 must not surface first in phase 4) give the same verdict under Halmos, hevm and forge symbolic, and under Kontrol on the real runner (A03's dispatch; if Kontrol cannot run there, B02's measurement says so before G1 and the fallback of master plan 2.2 row 22 applies); `tools/formal/link-identity.sh` green | hevm rejects unlinked code (T 5.11); forge symbolic linking is Not verified (T 7 item 7); the etched library runtime differs from a deployed one (section 4.5), which would make INV-CORE-31 and INV-SPOKE-39 pass or fail for the wrong reason | B | G0 |
| P-08 | Generate and prove the slot maps | `tools/gen-slots.sh` writes `test/harness/slots/Slots<Contract>.sol` from `forge inspect ... storageLayout`; each map is proven by a unit test that performs one real operation and compares `vm.load` at the mapped slot with the public view; anchors measured by the cards: Core Vault `_s` slot 0, 35 slots (card 01 header); Spoke Vault `_s` slot 0, 8,992 bytes = 281 slots (card 02 header, INV-SPOKE-38); ShareToken slots 0, 1, 2; MR slots 0, 1, 2 with packed entries; VRR `_state` packed at slot 1 (card 04 section 9.5); AA slots 0 to 2; FF slots 0 to 4; AB slot 0 | injection into a wrong slot proves a property about garbage; a layout change must stop every injection-based proof loudly | B | G0 |
| P-09 | Draft the WF bundles and test them first | `WF-<MOD>` predicates of section 5.2 exist and run as `property_` in the new stateful harnesses for two clean nightly campaigns; one unit test per WF shows a concrete reachable state that satisfies it | a WF that a reachable state violates makes every step proven under it unsound; an unsatisfiable WF makes them vacuous | A | G0 |
| P-10 | Kontrol go or no-go on class C | probe checks 4 (`flowFee(x, 25) <= x / 100`) and 10 (first distribution identity with symbolic supply) of card 09 section 9.5 close in Kontrol within one agent-day using lemmas L0 to L6 | the outcome fixes the tier of every rounding property in six modules; on NO-GO those targets become V2 per configuration plus V1 full-range differential and about 20 agent-days leave the plan | A | G0 |
| P-11 | Put the vacuity machinery in place | status generator reads the tool-native fields [F6] [F7] [F8]; `cover_` twins generated per `check_`; `check_TOTAL_` per predicate; model-switch covers; `forge test --mutate` baseline measured on `src/libraries/ShareMath.sol` (T 11) | a proof pipeline without vacuity detection produces green results that assert nothing (section 8) | B | G0 |
| P-12 | Write the reference model from the decisions only | `spec/model/` (Python 3, `fractions.Fraction`, no dependency) reproduces the decision examples as tests (200 USDC at 1.09 buys 183 shares for 199.47, DEC-035; 1,000 USDC at 1.1 burns 909 shares and pays 999.90, DEC-077; `docs/DECISIONS.md:42` and `:84` of the clone, per B section 9.2); authored in a fresh agent session whose context excludes `src/` | it is the oracle for class C fallback and for multi-transaction properties; the spike models in the specification repository encode superseded rules (DEC-033 settlement, 1e18 index, B section 9.1) | B, fresh session | G0 |
| P-13 | FLAGGED pins exist | every candidate finding of the cards (CF-1 to CF-11, CF-R1 to CF-R9, SF-1 to SF-9, F1 to F7, CF-V4-1 to CF-V4-6, AB-1 to AB-10, FF-1 to FF-9, MM-1 to MM-7, card 02 T1 to T12) has its forge pin from the cards' W01-class items | a formal `cover_` must agree with an executed pin, or the model hides the defect | B | G1 |
| P-14 | Replace the defective handler | the new core handler catches only reverts legal in that state and turns any caught `Panic` into `assert(false)` (T 7 item 5); it does not inherit `test/unit/core/CoreVaultInvariant.t.sol`, whose bare `requestPayout` call (`:61`) produces the intermittent `ZeroSharePrice` failures of T 2 | assumption soundness (P-09) depends on a handler that does not swallow violations | B | G1 |
| P-15 | Plan model conformance | every conforming model of section 4.6 has a named conformance test (fork or real-code tier) in the registry before any status above V2 depends on it | a conforming model that allows less than the real protocol hides real paths | A | G1 |
| P-16 | Ask the founder the blocking questions | section 10 questions sent; defaults recorded per question (FLAGGED meanwhile) | properties waiting on a ruling would otherwise be proven against a guessed specification | coordinator | G1 |
| P-17 | Stand up CI | jobs of section 7.1 exist, non-blocking; the Kontrol job runs on a 16 GB runner (public repository, `ubuntu-latest`, T 9) | without CI the status file is hand-written, which rule 1.3-1 forbids | B | G1 |
| P-18 | Calibrate on the cheapest code (F0) | one check each on TM, AG, ST gives the same verdict under Halmos, hevm, forge symbolic and Kontrol; INV-SHARE-01 reaches V4-k with complete vacuity evidence; effort of section 9 recalibrated | every failure on this code is a harness or tool failure, so conventions are debugged where they are cheap | A and B | G1 |

## 3. Specification layer (single source of truth)

### 3.1 Where the specification lives

```
spec/                                  # contracts repository, outside src/; never compiled into production
  registry/properties/<module>.yaml    # every INV-*, B-*, WF-* of one module (core, spoke, share, report, v4, aave, bridge, factory, math); Edit 2.1 row 3
  registry/system.yaml                 # SYS-1 to SYS-7b
  registry/assumptions.yaml            # every A-*: consumers, discharger, model, fork check
  registry/modules.json                # GENERATED module-name table and runner paths (master plan 2.2 row 26)
  baseline/                            # P-01: ABI, layouts, masked runtime hashes at the frozen commit
  toolchain.lock                       # P-06
  composition/SYS-<n>.md               # closure arguments of section 1.5
  lemmas/lemmas.k                      # Kontrol lemmas L0 to L10 (section 5.15), each also a registry row of kind lemma
  model/                               # reference model (P-12) and replay.py
  scribble/<module>.patch              # GENERATED overlay (pilot), applied only to build/scribble/
  status/                              # CI output only, keyed by commit
test/spec/                             # Solidity side of the specification, compiled by every Foundry-based runner
  SpecMath.sol                         # total helpers: sumLe, absDiffLe, isFloorMulDiv, isCeilMulDiv, safe add
  props/Prop<Module>.sol               # pure predicates: PropCore, PropSpoke, PropShare, PropReport, PropV4, PropAave, PropBridge, PropFactory, PropMath, PropGuard
```

The predicates live under `test/` (not `spec/`, as B proposed) so that forge, Halmos, hevm, Kontrol, Echidna (`--foundry-compile-all`) and Medusa compile them with no extra configuration (T 1 item 7, T 5.5, T 5.7), and the test-side Solhint configuration lints them (T 8.4). Annotations inside `src/` (Scribble, `@custom:halmos`) are forbidden: they change the metadata and the bytecode [F9], which makes them an audit-path change.

### 3.2 Registry schema (every field is read by a CI script; none is prose-only)

```yaml
- id: INV-CORE-03
  statement: "payoutReserve <= idle in every reachable state"
  decisions: [DEC-072]
  corpus: [INV-CONS-2]
  system: [SYS-2]
  module: core
  kind: safety            # safety | liveness | conservation | access | state-machine | rounding | structural | lemma
  class: B                # A | B | C (section 1.2)
  form: state             # state | step | exp | pure | struct | sequence (section 3.3)
  bundle: B-CORE-LEDGER   # proven together with the other members (mutual induction)
  reads: [CoreVaultState.idle, CoreVaultState.payoutReserve]    # drives check_closure.py and impact analysis
  footprint: [src/core/CoreVault.sol, src/core/CoreVaultBase.sol, src/core/CoreVaultTransit.sol, src/core/CoreVaultLogic.sol]
  predicate: PropCore.inv03
  wf: WF-CORE
  expected: holds         # holds | flagged(CF-n) | accepted(DEC-n) | conditional(A-x)
  assumes: [A-USDC]
  target_tier: V4
  bounds: {}              # empty = type widths only
  closure: {base: test_INV_CORE_57_DEC011_constructorEstablishesWF, frame: tools/gates/core_writers.py, steps: derived}
  runners:
    fuzz: test/fuzz/core/CoreProperties.sol:property_INV_CORE_03_DEC072_reserveWithinIdle
    symbolic: test/formal/core/CoreLedgerFormal.t.sol:check_B_CORE_LEDGER_step_*
    kontrol: test/formal/kontrol/CoreLedgerProve.t.sol:prove_B_CORE_LEDGER_step_*
    scribble: spec/scribble/core.patch#INV-CORE-03
  conformance: []         # model conformance tests this status depends on (section 4.6)
```

The status of a row is never written by hand: `tools/props/spec-status.py` writes `spec/status/<commit>.json` from tool output (section 7.2).

### 3.3 Predicate rules and forms

Rules (each closes a known failure mode):
1. **Written from the decisions and the card statement, never from the code.** A predicate imports only types and interfaces (`src/interfaces/*`, CVTy and SVT for struct shapes) and never calls a helper that encodes the rule (for example `_ledger` CVB:324-327); it recomputes from public views and observed words.
2. **Total.** A predicate never reverts: sums and products go through `SpecMath` and return `false` out of domain. A revert inside a Halmos check is not a failure (only `Panic(0x01)` is, T 5.8), and a reverting predicate inside `vm.assume` silently prunes paths; totality is proven by `check_TOTAL_<predicate>` (section 8.2 item V5).
3. **Multiplicative rounding, never a second `mulDiv`.** Floors and ceilings are stated as `q * d <= x * y < (q + 1) * d` (card 04 section 9.5), so the specification shares no arithmetic code with the implementation and the solver sees products, not a 512-bit division.
4. **Defensive quantifiers.** Any caller, any token mode, any subset of failing dependencies and any donation are inputs of the check, never fixed values; the manager is hostile inside the Mandate; adapter code is trusted only at its pinned codehash (Q17-4, T 7 item 6).
5. **Scalars or snapshot structs in, `bool` out, `internal pure`.** Observers (`test/harness/observe/<Module>Obs.sol`, views and `vm.load` only) build the snapshot; predicates never touch storage.
6. **Bundles.** `bundleLedger(o)` is the conjunction of its members; step checks assume the whole bundle before and assert the whole bundle after, which is what makes mutual induction sound.
7. **Revert expectations are predicates on `(bool ok, bytes4 selector)`** from a low-level call (T 7 item 3), so one predicate serves a fuzzer and a prover.

| Form | Meaning | Typical runners |
|---|---|---|
| state | one-state invariant over a snapshot | forge invariant, Echidna, Medusa, Scribble `#invariant`, and as a step check under the symbolic engines |
| step | `(pre, post, call)` relation for one mutating function, incl. delta lemmas with one untouched symbolic key (frame) | symbolic engines; the same predicate as a handler post-condition in fuzzing |
| exp | an executable function of the decisions computes the expected outcome (accept or which revert, and the values); the check asserts equality with the actual outcome, so soundness and completeness are one check (B's `rr_expected`, `ps_expected`, `ab_expected`, `exitExpected`) | symbolic engines; fuzz differential |
| pure | a lemma over a pure library function or over integers | symbolic engines; Kontrol for class C |
| struct | a fact about code, not values | Slither scripts, `forge inspect`, opcode scan (V0) |
| sequence | a property over call sequences no bundle implies | forge invariant, Echidna, Medusa with the reference model (V1) |

### 3.4 Naming (one id, many runners)

| Pattern | Meaning | Filter |
|---|---|---|
| `property_INV_<MOD>_<nn>_<DEC>_<slug>()` | fuzz property (no arguments; early `return true` instead of `vm.assume`, which Medusa lacks, T 7 item 3) | Echidna `prefix`, Medusa `testPrefixes` |
| `invariant_INV_<MOD>_<nn>_<DEC>_<slug>()` | forge wrapper asserting the matching `property_`; existing `invariant_DEC*` tests stay | forge |
| `check_INV_<MOD>_<nn>_<DEC>_<slug>(...)` | portable proof obligation: every symbolic input is a parameter; cheatcode floor of T 7 item 3 plus `vm.assume` | Halmos `function = "^check_"`, hevm `--prefix check`, forge `--symbolic`, Kontrol `--match-test` |
| `check_INV_..._step_<selector>[_<mode>]`, `check_B_<MOD>_<BUNDLE>_step_<selector>_<mode>` | inductive step of one selector in one mode, for one property or a bundle | same |
| `check_INV_..._frame_<selector>` | delta lemma frame: a second symbolic key keeps its value | same |
| `check_LEM_<name>`, `check_TOTAL_<predicate>` | lemma without code under test; predicate totality | same |
| `cover_<stem>_<outcome>` | reachability twin: identical body, asserts the outcome cannot happen; CI requires a counterexample | own job, `^cover_` |
| `hcheck_...` | Halmos only (`svm.createCalldata`, `svm.enableSymbolicStorage`, `svm.snapshotStorage` [F5]); lives in a contract named `<Unit>AnySelectorFormal` (or another name ending in `Formal`) | Halmos second call `--function hcheck_` (Halmos reads `function` as a prefix, so `check_` never matches it; Edit 2.2 row 24) |
| `prove_...` | Kontrol only (`kevm.symbolicStorage`, `freshUInt`, lemmas, loop invariants, T 5.12) | Kontrol |
| `test_<DEC>_FLAGGED_<slug>`, `test_CEX_<property>_<yyyymmdd>` | forge pin of an expected violation; replayed counterexample | forge |
| `tools/gates/<MOD>-<nn>.sh` | V0 gate | exit code |

Hyphens become underscores (T 7 item 2). Files: `test/formal/<module>/<Unit><Topic>Formal.t.sol`, contracts ending in `Formal` (Halmos `match-contract = "Formal$"`, T 8.8).

### 3.5 How each tool of the founder's list consumes the specification

| Tool | Consumes | Contributes to | Cannot consume |
|---|---|---|---|
| Slither 0.11.6 | registry `struct` rows through Python scripts in `tools/gates/` (writer sets, `vars-and-auth`, call graph, data dependency for L-SHAPE and the checkpoint-before-balance order of INV-CORE-53) | V0; the writer sets feed `check_closure.py` | values |
| Aderyn 0.6.8, Wake 4.22.1 | nothing from the registry; detectors only (Wake adds `invalid_memory_safe_assembly`, T 5.4) | findings triage, no tier | properties |
| Solhint 6.2.4 | `test/spec/` and harness files through the test config (T 8.4) | style gate on the specification code | properties |
| forge fuzz and invariant (Foundry 1.8.3) | `invariant_` wrappers over `property_`; `testFuzz_..._matchesModel` differential under `[profile.diff]` with `ffi` only there | V1 | proofs |
| Echidna 2.3.3, Medusa 1.5.1 | the same `property_` functions in `test/fuzz/`; assertion mode on the Scribble copy | V1, and assumption soundness of every WF (section 8.2 item V3) | `vm.assume` (Medusa) |
| `forge test --symbolic` (preview) | the portable `check_` files | second engine for V2 and V3-bv; never alone (preview, T 5.6) | Halmos-only and Kontrol-only cheatcodes |
| Halmos 0.3.3 | `check_` and `hcheck_` | V2, V3-bv | `expectRevert` (T 5.8), symbolic `bytes` lengths, logs |
| hevm 0.58.0 | `check_` (pre-linked build only); `hevm equivalence` for refactors | V2, V3-bv; equivalence evidence of section 6 | unlinked code, logs, gas (T 5.11) |
| Kontrol 1.0.255 | `check_` and `prove_`, `spec/lemmas/lemmas.k` | V3-k, V4-k | fork, FFI (T 5.12) |
| Scribble 0.7.10 | generated overlay from the registry `runners.scribble` field for state rows without external calls (pilot: INV-SHARE-01, 13, 22, INV-CORE-03, INV-SPOKE-47) | runtime checks during every forge, Echidna and Medusa run of the copy; no tier | AB (optimizer-only compile trap, card 07 item 5) |
| Mythril | nothing from the registry. Bounded 30-minute runs on the four runtimes with no MCOPY (MFV, MR, TE, CLPS) and on their Scribble copies; SKIP on every runtime with MCOPY and on CoreVault (Edit 2.1 row 5; T 5.9, 8.11) | hit triage only, no tier; expected to re-find CF-R2 | runtimes with MCOPY, delegated libraries, properties |
| Manticore | nothing: SKIP (archived, no PUSH0, MCOPY or TLOAD; T 1 item 4) | none | cancun bytecode |
| `forge test --mutate`, `--brutalize` | the whole unit, fuzz and formal suites | sensitivity evidence (section 8.2 item V4); memory-safety of the 13 assembly blocks (T 3) | none |

### 3.6 One property through every runner (INV-CORE-03)

```solidity
// test/spec/props/PropCore.sol  (from DEC-072; imports no src/ logic)
function inv03(uint256 payoutReserve, uint256 idle) internal pure returns (bool) { return payoutReserve <= idle; }
// test/fuzz/core/CoreProperties.sol   (Echidna, Medusa; forge wraps it as invariant_INV_CORE_03_DEC072_reserveWithinIdle)
function property_INV_CORE_03_DEC072_reserveWithinIdle() public view returns (bool) { return PropCore.inv03(vault.payoutReserve(), vault.idle()); }
// test/formal/core/CoreLedgerFormal.t.sol   (Halmos, hevm, forge --symbolic, Kontrol, unchanged)
function check_B_CORE_LEDGER_step_claimPayout_standardIdle(uint256 idle, uint256 reserve, uint256 req, address holder) public {
    _injectLedger(idle, reserve, req, holder);                                    // vm.store at generated slots
    vm.assume(PropCore.bundleLedger(obs.ledger(holder)));                          // ASSUME: WF-CORE
    (bool ok,) = _callAs(holder, address(vault), abi.encodeCall(ICoreVault.claimPayout, (""))); // empty unwindHints (CV:144)
    assert(!ok || PropCore.bundleLedger(obs.ledger(holder)));                      // a revert leaves the state unchanged
}
function cover_B_CORE_LEDGER_step_claimPayout_standardIdle_succeeds(...) public { /* same body */ assert(!ok); }  // must FAIL
```

Not verified: that Kontrol and forge `--symbolic` make a `calldata` struct argument symbolic (B section 4.4); the portable rule of flat scalar arguments avoids the question, at the cost of splitting large pre-states across two checks under `via_ir = false` (`foundry.toml:11`).

### 3.7 Consistency lint (`tools/props/spec-lint.py`, every PR touching `spec/`, `test/spec/`, `test/formal/`, `test/fuzz/`)

**Stages (Edit 2.2 row 25):** `spec-lint.py --stage N` runs the rules below in the strength the wave allows. Stage 0 checks ids and predicates only for rule 1 and everything in rules 2, 3, 4 and 6 on the files that exist. From stage 1, rule 1 also requires a driver, but only for the runners the row's *claimed* tier needs (a row claimed at V1 needs a fuzz driver and nothing else), not for every runner of its target tier, which would fail for almost all 454 rows until phase 4. Rules 2, 3 and 6 belong to package A04 (A01 has only rules 1 and 4 with `--registry-only`).
1. Ids unique; every row has a predicate in `test/spec/props/` and a driver for each runner its claimed tier needs (its target tier at the final stage).
2. No orphan: every `invariant_INV_`, `property_INV_`, `check_`, `cover_`, `hcheck_`, `prove_` name parses to a registry, `LEM` or `TOTAL` id; every `check_` has at least one `cover_` twin per asserted outcome; every registry `hcheck_` runner appears in a Halmos JSON result (the any-selector nets cannot silently stop running).
3. Every `vm.assume` in `test/formal/` carries `// ASSUME: <id>` naming a WF conjunct, a bound or an A-* id that exists.
4. Every `assumes` id exists; every internal assumption has a discharger; the assumption graph is acyclic except declared bundles; every `flagged` row names its forge pin and its `cover_`.
5. `check_closure.py`: for each V4 row, the mutating selectors whose Slither writer set touches a variable in `reads` equal the set of `step_` checks; a new external function in `src/` fails the closure until it gets a step check or a writer-set proof that it touches none of those variables.
6. `footprint` files exist; `conformance` tests exist for every conforming model the row's harness uses.

## 4. Harness architecture

### 4.1 Directory tree (contracts repository; `src/`, `test/unit/`, `test/fork/`, `test/mocks/` unchanged)

```
test/
  spec/                      SpecMath.sol, props/Prop<Module>.sol                       (section 3.1)
  harness/
    FormalBase.sol           cheatcode floor, _callAs, _sel, library etch, chain id rule, actors, time bounds
    FuzzBase.sol             actor set, bounded warps, legal-revert tables, panic passthrough
    slots/                   Slots<Contract>.sol GENERATED by tools/gen-slots.sh; SlotMap.t.sol proves each map
    observe/                 <Module>Obs.sol: snapshots from views and vm.load only
    models/                  models of section 4.6, SymToken
    hosts/                   CoreLogicHost.sol, SpokeLibHost.sol                         (mode M2)
    summaries/               CoreVaultLogicSummary.sol + selector-equality test           (mode M3)
    exposed/                 SpokeVaultExposed, CoreVaultExposed, AdapterGuardHarness     (internal helpers)
    inliners/                ShareMathHarness, IAFormalHarness, MandateHarness + MandateSpec, ReportCodecHarness,
                             TransitMessageHarness, CodeStoreHarness (test/mocks/factory/Create3Harness.sol reused)
    factory/                 stub children of card 08 section 9.5
    generated/               LinkedLibCode.sol GENERATED and patched (section 4.5)
  formal/<module>/           <Unit><Topic>Formal.t.sol: check_, cover_, check_LEM_, check_TOTAL_
  formal/system/             HubPairFormal.t.sol (section 4.5)
  formal/halmos/             hcheck_ files (imports halmos-cheatcodes)
  formal/kontrol/            prove_ files (imports the Kontrol cheatcode interface)
  fuzz/<module>/             <Module>Properties.sol (property_), <Module>Invariant.t.sol (invariant_)
  differential/<module>/     model versus contract, [profile.diff] only
  regression/                test_CEX_<property>_<yyyymmdd>
tools/
  props/                     spec-lint.py, check_closure.py, spec-status.py, spec-impact.py, gen-runners.py, gen-scribble.py
  gates/                     V0 gates (Slither scripts, opcode scans, layout and ABI diffs)
  gen-slots.sh, gen-linked-lib-code.sh, formal/link-identity.sh, formal/run-matrix.sh
```

Test-only dependencies: `a16z/halmos-cheatcodes` for `hcheck_` and the Kontrol cheatcode interface for `prove_`, kept out of portable files so hevm and forge never meet an unknown cheatcode address (Not verified: the Kontrol package name and pin; confirm at P-06). Both change `.gitmodules` (founder decision 10.1 item 8).

### 4.2 Base contracts

| Element | Content | Why |
|---|---|---|
| `_callAs(who, target, data) returns (bool ok, bytes ret)`, `_sel(ret)` | `vm.prank` then low-level `call`; revert selector | the only revert assertion every tool accepts: Halmos rejects `expectRevert` (T 5.8), Medusa has none (T 4.2) |
| cheatcode floor | `prank`, `startPrank`, `stopPrank`, `deal`, `store`, `load`, `warp`, `roll`, `etch`, `addr`, `label`, plus `assume` in `test/formal/` only | intersection of Halmos, hevm, Medusa, Echidna and Kontrol (T 7 item 3); forbidden: `expectRevert`, `expectEmit`, `recordLogs`, `mockCall`, `createSelectFork`, `ffi` |
| chain id | every Mandate sets `hubChainId = block.chainid` (hub role) or lists `block.chainid` as a spoke (spoke role); Kontrol pins `chainid = 42161` | the Core Vault constructor reverts off the hub chain (CVB:77); hevm has no chain-id cheatcode (T 7 item 4) |
| time | every check assumes `1 <= block.timestamp < 2^64` (`// ASSUME: A-TIME`) except the one `cover_` that exhibits CF-R5 | the receiver's `acceptedAt != 0` sentinel (VRR:157, VRR:187) and `uint64` casts |
| actors | fixed `MANAGER`, `HOLDER_A`, `HOLDER_B`, `ATTACKER`, `GUARDIAN`, `PROTOCOL_RECIPIENT`, plus one symbolic `caller` parameter constrained only by the role the property quantifies over | a symbolic caller covers every stranger; fixed actors keep constructors single-path (Halmos needs it, T 5.8) |
| logs | never asserted by the bit-vector engines; event properties stay V1 (forge) or Kontrol `expectEmit` | Halmos and hevm do not assert logs; `hevm equivalence` ignores them (T 8.10) |
| `FuzzBase` | hostile manager, two or more depositors, donor, keeper, guardian, registry owner (T 7 item 6); warps bounded to one week; per-action legal-revert lists; any caught `Panic` becomes `assert(false)` (T 7 item 5); effective-action counters so a campaign where everything reverts fails | assumption soundness (P-09) and fuzz evidence depend on a handler that does not swallow violations |

### 4.3 Symbolic inputs, symbolic storage, ghosts

- **Parameters, not cheatcodes.** Every symbolic value is a `check_` parameter (all four engines treat test arguments as symbolic). `svm.create*` and `kevm.freshUInt` appear only in `hcheck_` and `prove_` files.
- **Arrays and `bytes` are built in the test body at concrete lengths from scalar parameters**; payloads with `abi.encode` of symbolic words (TM, RC, adapter `params`). Halmos needs concrete lengths and cannot follow symbolic calldata offsets, and MCOPY sizes must be concrete (T 5.8).
- **Identifier pools**: where equality matters (duplicate adapters, the same transit id twice, the same token in two pools), identifiers come from 2 or 3 symbolic addresses so equal and distinct cases both occur (card 09 section 9.2).
- **Modes**: model failure modes are concrete per check, plus one check per property with a symbolic `uint8 mode`, keeping branch counts linear (card 01 section 9.5, try/catch doubling).
- **Storage routes**: (1) injection with `vm.store` at generated slots, portable, used by default; only the variables a property reads become symbolic, the Mandate region and immutables stay as the constructor wrote them; (2) `svm.enableSymbolicStorage` and `svm.snapshotStorage` [F5] in `hcheck_` for frame nets over arbitrary storage; (3) `kevm.symbolicStorage` in `prove_` (T 5.12).
- **Never injected**: arrays (positions, in-flight ids, spokes, unwind order, Mandate arrays) are built by calls or the constructor with symbolic contents, because an inconsistent length-and-elements injection yields unreachable states that look like counterexamples (card 06 section 9.4); transient storage (`_unwinding` CVB:60 and the transient guard) starts at zero in every transaction (EIP-1153; Not verified today, Appendix B); packed words go through helpers that pack and range-constrain (MR entries `(bps << 8) | exists`, card 03 section 9.4; VRR `_state[i]` as four `uint64`, card 04 section 9.5; AG slot 0 as two bits).
- **Guard slot**: the persistent OpenZeppelin guard used by SV, MFV, VRR, V4A and AA stores its status at `0x9b779b17422d0df92223018b32b4d1fa46e071723d6817e2486d003becc55f00` (`ReentrancyGuard.sol:36-37`; `ENTERED = 2`, `ReentrancyGuard.sol:51`). Routes (2) and (3) must constrain it `!= 2` in the WF, or every guarded entry reverts on every path and the proof is vacuous.
- **Ghosts**: none in storage for proofs; pre and post snapshots inside one check. Sums become **delta lemmas** (the aggregate changes by exactly the change of the touched element and a second symbolic element keeps its value), closed by induction over the V0 writer set: INV-CORE-04, 39, 44, 51, 52, INV-SHARE-03, INV-MATH-28, 29, INV-SPOKE-23 (card 01 section 9.1). **Hyperproperties** (flags never change an exit: INV-V4-09, INV-AAVE-07; caller independence: INV-REPORT-13, INV-SPOKE-21; shape independence: INV-REPORT-18) use twin instances deployed in `setUp`, no snapshot cheatcode. **Recording models** append every transfer destination to a bounded array for INV-CORE-11, INV-SPOKE-17, INV-V4-06, INV-AAVE-04 (SYS-7a).

### 4.4 Slot maps

`tools/gen-slots.sh` writes base slots, struct member offsets, packing offsets and mapping-key helpers (`keccak256(abi.encode(key, slot))`) from `forge inspect <contract> storageLayout`; CI regenerates and fails on any diff; `SlotMap.t.sol` proves each map by one real operation read back with `vm.load` against the view (P-08). Not verified: the transient slot of `_unwinding`, because forge 1.8.3 printed no transient layout (card 01 section 10.1); the harness never injects it, so only INV-CORE-58's non-overlap claim depends on it.

### 4.5 The two DELEGATECALL libraries

Facts. `library CoreVaultLogic` (CVL:34) and `library SpokeCrossChainLib` (SCL:25) expose public functions taking the vault's state struct by storage reference (for example `recordValuation(CoreVaultState storage s, CoreVaultWiring memory w, bool mint)` CVL:89, `sendToHub` SCL:38); the struct is the first state variable of each vault (`CoreVaultState internal _s;` CVB:56; `SpokeVaultTypes.State internal _s;` SV:93). The Core Vault reaches its library from 13 call sites (12 DELEGATECALL opcodes, card 01 section 9.5); the Spoke Vault from SV:390, 397, 412, 422, 616 (card 02 section 9.4). Measured for this document on `out/` at `e5c778a`: both library runtimes (19,215 and 10,545 bytes) begin with `0x73` followed by 20 zero bytes and `0x30 0x14` (PUSH20 0, ADDRESS, EQ), and the same 23-byte pattern appears inside each creation code: the call-protection constant is a zero placeholder in the artifact that the library's deployment fills with its own address. Consequence: a runtime etched unpatched behaves like the deployed library under DELEGATECALL (the vault's address differs from the constant in both cases) but **does not reject direct calls**, so it would make INV-CORE-31 and INV-SPOKE-39 pass or fail for the wrong reason. Not verified: the exact use of the equality flag by each function; the bytes are confirmed, the dispatch is not read.

Route for every engine (A's single route, B's four modes):
1. Build with `[profile.verify]` (T 8.1): `CoreVaultLogic` pre-linked at `0x...c0de01`, `SpokeCrossChainLib` at `0x...c0de02`, optimizer kept (AB does not compile without it, card 07 item 5).
2. `tools/gen-linked-lib-code.sh` (T 8.10) emits the runtimes as constants **after writing the etch address into bytes 1 to 20**; `FormalBase` places them with `vm.etch` (in the cheatcode sets of Halmos, hevm, Kontrol and forge, T 4.2), so no engine-specific linking is relied on.
3. **Link-identity gate (V0, every PR)**: build default and `verify` profiles; zero the 20 bytes at every `linkReferences` offset of CoreVault and SpokeVault and strip the CBOR tail; require equal hashes; require each patched library constant to equal, modulo those 20 bytes, the runtime its own creation code leaves when deployed by CREATE in a unit test. This is what lets a proof about the verify bytes be quoted for the production bytes (A-BUILD). The production library addresses are pinned by the release gate (INV-FACTORY-17, card 08 W8), because the factory's library fields are informational only (FF-2).

| Mode | Use | Construction | Soundness obligation |
|---|---|---|---|
| M1 real link through the vault | default for every vault property (access, reentrancy, callbacks, composition) | route above | A-BUILD via the link-identity gate |
| M2 library in a host | per-function steps of CVL and SCL without vault noise (transit books, hub-bound ledger, income, fee split, `sendToHub`, `recognizeRefund`) | `CoreLogicHost` declares `CoreVaultState internal _s;` as its only state variable, fills the Mandate region as `_copyMandate` does (CVB:119-148) and exposes one function per library entry forwarding `(_s, w, args)`; `w` is a check argument constrained to a superset of what `_wiring()` (CVB:302-318) can produce; `SpokeLibHost` likewise with `SpokeVaultTypes.State` | unit test: host and vault storage layouts are identical; the host runs the same library bytes by DELEGATECALL, so a step proven for every well-formed `w` holds in the vault; reentrancy and `_unwinding` properties are not proven here (they live in the vault, CVB:60, CVB:174-178) |
| M3 summary by etch | vault steps whose assertion does not depend on the library's arithmetic (deposit ledger conservation, reserve bound, top-up, access), to keep valuation loops and 512-bit division out of the query | `CoreVaultLogicSummary`: identical selectors (checked on `forge inspect methodIdentifiers`), etched at `0x...c0de01`; each body returns values read from a reserved high slot the check injected, and writes symbolic values only to the slots the real function may write (for `recordValuation`: `lastHubValue` and `lastPrice[t]`, CVL:98, CVL:101) | prove in M2 that the real function writes nothing outside the summary's set and returns values within its constraints; until then any status obtained in M3 is capped at V2. Not verified: Halmos honours `vm.etch` over an address the build already links (it should: compile-time linking has no resolution step) |
| M4 confinement and call protection | INV-CORE-31, INV-CORE-58 (library part), INV-SPOKE-38, 39 | direct CALL of each non-view entry on a forge-deployed library must revert (unit); `vm.record` and `vm.accesses` around library calls: every written slot lies in the `_s` region (below 35 or 281, or keccak-derived from a root of `_s`) or is the guard slot | V1 by construction; INV-SPOKE-38 optionally V3-k with `symbolicStorage` |

**Hub pair.** `claimPayout` calls `unwindForPayout` on the hub Spoke Vault, which calls back `returnToIdle` in the same transaction (CVB:174-178, SV:524-547). Safety needs no pairing: each side is proven against a havoc model of the other (section 4.6), and the Core Vault's own backing check (`_requireUnledgered` at CVT:45) carries it. Liveness needs both: `test/formal/system/HubPairFormal.t.sol` runs the real Core Vault with the real hub Spoke Vault (adapters modelled, arrays of 1 or 2) and proves INV-CORE-25 and INV-SPOKE-31 together at V2.

### 4.6 Models of external protocols and of sibling contracts

Kinds. **H (havoc)**: any behaviour the ABI allows; sound for safety, may raise false alarms; needs no conformance evidence. **C (conforming)**: the documented behaviour; used only for functional and liveness properties; every C model names the assumption it encodes and a conformance test against real code (fork or local real-code tier), and **a status that depends on a C model without a green conformance test is capped at V2** (B section 5.6). Real code is preferred to any model whenever the callee is loop-free and cheap, so no summary has to be trusted.

| Model (`test/harness/models/`) | Plays | Kind | Symbolic surface and switches | Encodes | Conformance and discharge |
|---|---|---|---|---|---|
| `SymToken` | USDC, USDG, WETH, pool and income tokens | H with the modes of 4.7; standard mode is C | balances by `deal` or injection; transfer and approval log | A-USDC, A-TOKENS, A-TOKEN (standard mode only) | fork suites with real tokens (cards 01, 05, 06) |
| `SymHubSpokeVault` | hub Spoke Vault seen by the Core Vault | H: `unwindForPayout` transfers any `x` and calls `returnToIdle(y)` with any `y`, reverts or re-enters; `buildReport` returns fixed-length symbolic fields or reverts | `x`, `y`, report fields, revert flag | nothing for safety (the backing checks CVT:45 and CVI:32 carry it); A-HUBSV only for liveness rows | INV-SPOKE-31, 42, 43 and HubPairFormal |
| `SymReceiver` | receiver seen by the Core Vault | C mode (never reverts for a Mandate index with `hasReport`: the real `latestReport` reverts `NoReport` without a report, VRR:220; Edit 2.1 row 12) plus H mode (reverts, malformed) | one report per spoke: unallocated 1, positions up to 1, arrived up to 2, in-flight up to 2 | A-RECV in C mode | INV-REPORT-01, 06, 12 (V2 to V4) |
| `SymPriceSource` | price source seen by the Core Vault (CVL:333, 341-342) | H: any `(price, updatedAt)`, revert, short return | both words, flags | A-PRICE is **not** assumed: it is false (INV-REPORT-26, CF-R2) | consumers labelled conditional(A-PRICE) until the CF-R2 ruling |
| real `ManagerRegistry`, `SymRegistry` | registry read (CVL:402) | real MR for the conforming case; H for codeless, oversized and short answers | slice word, flags | A-REG | INV-SHARE-21 (V4); SF-1 as `cover_INV_SHARE_30_...` |
| `AcrossSpokePoolModel`, `HostileAcrossSpokePool`, `SymBridgeTarget` | SpokePool views and `depositV3` seen by AB and the vaults (AB:62, AB:126; CVL:626; SCL:341) | views C with failure modes (value, revert, empty, oversized word); `depositV3` H: pulls exact, less, more, none, reverts, re-enters | counter, buffer, pull amount | A-ACROSS-4, 5 for views | fork FB, FL of card 07 |
| arrival driver | `handleV3AcrossMessage` caller (CVT:110, SV:441) | H: the check pranks as the pool and deals the amount or not | amount, message words | A-ACROSS-1 only where the label names it (CF-5) | fork FL:119 (card 07) |
| `SymCoreBridge` | Wormhole `parseAndVerifyVM` (VRR:145) | H on every returned field (`valid`, consistency, emitter pair, sequence); payload set by the test | 5 VM fields | A-WH1 only for the authenticity half of INV-REPORT-01 | real Arbitrum Core in the receiver fork suite (card 04 VRRF:159-164) |
| `ModelWormhole` | `publishMessage` (SV:414) | C | returned sequence, `messageFee` | A-WH3 | spoke fork suite |
| `SymAggregator` | Chainlink proxy (CLPS:85, CLPS:124) | H on `answer` and `updatedAt`, revert, short return; `decimals` concrete per configuration row | answer, age | A-CL1 through the row choice | fork read of the live feed (card 04 RW13) |
| `SymCoreVault`, `ModelCoreVault` | Core Vault seen by the receiver and the Spoke Vault | H: callback revert flag, re-entry switch that tries every selector, reads `latestReport` inside the callback | flags | A-CV, A-SPK-4 | INV-CORE-25, 29 |
| `ModelAdapter` | position adapters seen by the Spoke Vault | C default plus flags: over-report, keep-unused, revert, and the known non-conformances (CF-V4-1 key shift, Aave F1 exit revert, F6 counter epsilon) | returned amounts, flags | A-SPK-1 | INV-V4-15, 16, 21, 22, 25; INV-AAVE-03, 13, 17, 25, 31 |
| `AaveV3PoolModel` | Aave Pool and aToken in one contract | C arithmetic (floor mint, ceil burn) with H failure modes `withdrawReverts`, `payDelta`, `extraBurn`, `viewReverts`; liquidity kept apart from balance | index, liquidity, modes | AS1 to AS3 | fork conformance INV-AAVE-45 (card 06 W11) |
| `SymV4` | StateView, PositionManager, Permit2, PoolManager in one contract | C reads constrained to V4's domain (tick consistent with `sqrtP`, `L < 2^127`); at `modifyLiquidities` and `unlock` a checker recomputes the implied deltas with the real v4-core libraries and asserts they net to zero; H switches for hostile tokens | `sqrtP`, tick, `L`, fee growth | A-V4-1 to A-V4-4 | local real-V4 tier (card 05 V4-W03), fork V4-W10; A-V4-2 by V4-W14 |
| stub children | factory deployments (card 08 section 9.5) | C: exact constructor signatures, `abi.decode` of the arguments, hash stored | none | A-VIEW, A-CORE | real-children unit and fork tests |
| real code | `TransitEscrow`, `ShareToken`, `ManagerFeeVault`, `AcrossBridgeAdapter` inside vault harnesses | real | n/a | their own V4 properties enter as lemmas | this plan, layers L1 and L2 |

### 4.7 Hostile token modes of `SymToken`

| Mode | Behaviour | Properties that must run it |
|---|---|---|
| standard | exact amounts, returns `true` | every C check |
| returnsFalse, returnsNothing | `transfer` returns `false` or no data | INV-SHARE-14 (SafeERC20 branches) |
| revertsFor(address) | pause or blacklist of a configured address | INV-CORE-21 cells CF-2, CF-3; SF-2; CF-V4-6; INV-SPOKE-41 |
| feeOnTransfer(bps) | recipient receives less | INV-CORE-02, INV-SPOKE-02 hostile form, INV-SHARE-40 |
| reenter(target, data) | calls a configured selector inside `transfer` | INV-CORE-26, INV-SPOKE-36, INV-SHARE-19, INV-V4-32, 34, INV-AAVE-41 |
| approveHook(target, data) | runs code on `approve` | CF-V4-1 (`cover_INV_V4_10_...`), INV-V4-35 |
| slash(holder, x) | negative rebase of one balance | INV-CORE-02 (A-TOKENS boundary), INV-SPOKE-41 |
| donate | third-party transfer to any address between calls | INV-CORE-08, INV-SPOKE-04, INV-AAVE-23, INV-FACTORY-30 |

Every model switch must be exercised with both values on a non-reverting path by a `cover_` (section 8.2 item V6): a check that never sets the `catch` flag proves nothing about AA:399-416 or AA:482-487 (card 06 section 9.4).

### 4.8 Assume-guarantee graph (how lower modules become summaries for upper ones)

A conforming model is a sound summary of a sibling only if every behaviour the sibling can show, given its proven properties and its FLAGGED failures, is a behaviour the model can show. `spec-status.py` caps a consumer's status at the minimum status of the dischargers of its internal assumptions and prints the chain.

| Assumption (consumer) | Discharged by (target tier) | Status of the discharge at `e5c778a` | Consequence |
|---|---|---|---|
| A-RECV (INV-CORE-21, 41, 42, 47) | INV-REPORT-12 (V2 shapes), 01, 06 (V3) | holds for liveness; gas caveat CF-R4 left to V1 | `SymReceiver` in C mode, plus one H-mode check per exit property |
| A-PRICE (INV-CORE-21, 27, 48) | INV-REPORT-26 | **false** (CF-R2) | `SymPriceSource` stays H; the rows are conditional(A-PRICE) |
| A-REG (INV-CORE-50, INV-SHARE-30) | INV-SHARE-21 for the MR runtime; deployment gate INV-SHARE-30 | false for a non-MR address (SF-1) | real MR in C checks; `cover_` pins SF-1 |
| A-HUBSV (INV-CORE-21, 25, 49 liveness) | INV-SPOKE-31, 42, 43 (V2, V3), HubPairFormal (V2) | provable | not needed for Core Vault safety |
| A-SPK-4, Core Vault accepts exactly what was delivered (INV-SPOKE-43) | INV-CORE-25, 29 | provable | `ModelCoreVault` stays H |
| A-SPK-1, adapters conform (INV-SPOKE-01, 25, 30, 31, 34) | INV-V4-15, 16, 19, 21, 22, 25; INV-AAVE-03, 13, 17, 25, 31 | partly false: F6 (Aave counter regresses by rounding), F1 (exit revert), CF-V4-1 | INV-SPOKE-25 in epsilon form; INV-SPOKE-30 carries the F1 caveat |
| A-LIB (every vault property) | link-identity gate (V0) and INV-FACTORY-17 release gate | unchecked on chain (FF-2) | holds per deployment by the release gate |
| A-SPOKE (INV-REPORT-04, 32) | INV-SPOKE-24, 26 | provable (26 by differential) | |
| A-DISCIPLINE (INV-MATH-22 to 33) | INV-CORE-53 (V0 call order plus V2), INV-MATH-35 (V0) | provable | IA identities hold at the vault |
| A-WHOLE (INV-MATH-04, 10, 22) | INV-SHARE-01, INV-CORE-12 (V4) | provable | |
| A-LEDGER (INV-MATH-28) | CVI:32 backing check; INV-CORE-45 on the Across path | false on the Across path (CF-5) | income conservation conditional(A-ACROSS-1) |
| A-SV, `n, d > 0` (INV-V4-25, 26; INV-AAVE-31) | the sizing call site SV:853-859 checked inside the Spoke Vault harness | provable at V2 (unwind is bounded) | adapter sizing proven for `n, d > 0` only |
| AS7 (INV-AAVE-17) | INV-SPOKE-08 | provable | Aave entry sizing assumes a pre-funded call |
| A-CORE (INV-FACTORY-07) | INV-CORE-57 unit, INV-SHARE-45 | V1 | factory address predictions |
| A-WIRING (V4A swap liveness, CF-V4-10; card 05 section 9.4; Edit 2.1 row 17) | INV-V4-48 (V0 gate plus fork, V4-W19; card 05 R6 would make it a constructor V3) | unchecked on chain: INV-V4-41 covers only the StateView and Permit2 halves, and the `poolManager` half does not fail closed | a V4A status that needs swaps to work carries A-WIRING |
| A-ACROSS-* (card 07 list, below), A-WH1 to 4, A-CL1, A-CL2, AS1 to AS6, A-V4-*, A-TIME, A-KECCAK, A-6780, A-161, A-OP, A-MULDIV, A-BRIDGE-TOKEN, A-IA-CALLS, A-KEEPER, A-ADDR, A-7702, A-OPKEY, A-MGR-ADDR (Edit 2.1 row 17) | external: no in-repo provider | ASSUMED; fork checks and monitoring named in the cards | they stay in every label that uses them |

**Register names settled by Edit 2.1 row 17** (FV P-05 collision rule: every consumer cites one row; the full rows, with consumers, live in `spec/registry/assumptions.yaml`). Card 07 section 9.3 is the single list of A-ACROSS-*: wherever this file writes A-ACROSS-2 it means the pair 2a and 2b, and "A-ACROSS-1 to 9" in the AB row of section 1.4 reads as the card 07 list (1, 1c, 2a, 2b, 3 to 12, A-ACROSS-GOV, A-DEC). A-TOKEN stays the per-pool token assumption of card 05; the token assumption of card 07 is A-BRIDGE-TOKEN.

| Name | One-line meaning | Source | Discharged by, or status |
|---|---|---|---|
| A-ACROSS-1c | the Across callback runs only when the recipient has code; a codeless recipient receives the tokens and no callback (consumers INV-BRIDGE-37, 38) | card 07 section 9.3 | fork test W20 |
| A-ACROSS-2a | an expired deposit refunds exactly `inputAmount` to the depositor on the origin chain | card 07 section 9.3 | no fork discharge possible; monitoring |
| A-ACROSS-2b | the refund transfer succeeds when the leaf executes, otherwise it is deferred to `relayerRefund[token][escrow]`, claimable only by the escrow; known false for a keyless escrow while the token pauses or blacklists (AB-11) | card 07 section 9.3 | W18 (transcribed Across code); no fork discharge possible |
| A-ACROSS-10 | fills are not paused on the destination chain (`pausedFills`; consumer INV-BRIDGE-22) | card 07 section 9.3 | fork read next to FB:217, FB:265 (Not verified: the getter name on the live pools) |
| A-ACROSS-11 | each chain's SpokePool keeps its proxy address for the fund's lifetime (consumer INV-BRIDGE-22) | card 07 section 9.3 | Not verified: deployment history; monitoring |
| A-ACROSS-12 | refunds arrive within `maxReportAge` after `fillDeadline`, so the spoke does not prune a transit whose refund is still coming | card 07 section 9.3 | monitoring; the Mandate's `maxReportAge` must exceed the refund latency |
| A-BRIDGE-TOKEN | USDC and USDG, the bridge tokens, have no transfer hook and no fee; their issuers can pause, blacklist and upgrade them (feeds AB-11, CF-3, INV-BRIDGE-29); renamed from card 07's A-TOKEN | card 07 section 9.3 | fork suites with the real tokens; `SymToken` modes `revertsFor` and `slash` |
| A-SPK-1 | adapters (pinned code) conform: they transfer exactly what they return, `positionValue` does not revert for a listed key, `cumulativeIncome` is monotonic; partly false today (Aave F1 and F6, CF-V4-1) | card 02 section 9.3 (A1) | adapter cards; section 4.6 `ModelAdapter` |
| A-SPK-2 | the Across SpokePool and Wormhole Core behave as documented: exact pull, tokens delivered before the callback, refund of the full input after expiry, `outputAmount` delivered; Wormhole returns a sequence and charges `messageFee` | card 02 section 9.3 (A2) | card 07 and fork suites |
| A-SPK-3 | USDC, USDG and WETH are standard ERC-20 (no fee, no rebase, no callback); issuer pause or blacklist is a matrix row, not assumed away | card 02 section 9.3 (A3) | fork suites |
| A-SPK-4 | the Core Vault transfers before `receiveFromCoreVault`, and `returnToIdle` and `receiveCollectedIncome` accept exactly what was delivered | card 02 section 9.3 (A4) | INV-CORE-25, 29 (table above) |
| A-SPK-5 | EVM: EIP-6780 keeps the codehash stable, `block.timestamp` is monotonic per chain, and Robinhood `block.number` is an L1 estimate | card 02 section 9.3 (A5) | external |
| A-SPK-6 | prices: a Uniswap V4 `slot0` can be moved inside a block, so no proof bounds INV-SPOKE-49 | card 02 section 9.3 (A6) | none; stated in the label |
| A-WIRING | the factory's four Uniswap addresses belong together | card 05 section 9.4 | INV-V4-48 (table above) |
| A-IA-CALLS | per token, fewer than `2^127` accepted distributions, checkpoints and takes over the fund's life, so `distributed`, `ownerless`, `taken` and every `owed` stay `<= 2^255` (replaces the WF-IA width conjuncts of section 5.2) | card 09 section 9.3 | none in code: a physical bound, carried in every label that uses it |
| A-KEEPER | some party publishes a spoke report and delivers it on the hub between each send home and `fillDeadline + maxReportAge` (consumer INV-CORE-64) | card 01 section 9.4 | none in code (delivery is permissionless and unpaid); monitoring |
| A-WH4 | a finalized VAA of spoke `k` reaches the hub within `L_k` seconds of the report's spoke timestamp (consumers INV-REPORT-38, 40) | card 04 section 9.4 | fork measurement per chain |
| A-ADDR | distinct salts give distinct proxy and child addresses; an address keeps 160 bits of a hash, so a collision costs about `2^80` work, below keccak's own bound | card 08 section 9.3 | none possible; recorded so no label says "distinct addresses" under A-KECCAK alone |
| A-7702 | on a chain with EIP-7702, an EOA's code is a mutable 23-byte designator that EXTCODESIZE and EXTCODECOPY read; no code-store chunk may be such an account | card 08 section 9.3 | W8 first-byte check; C1 on chain |
| A-OPKEY | after release the operator key never calls `Create3Deployer.deploy(FACTORY_SALT, ...)` with anything but the release factory, and every chain a live Mandate names already has it; fails if the key is compromised | card 08 section 9.3 | nothing on chain; W8 per release chain, W21 per fund |
| A-MGR-ADDR | the Manager address is controlled by the same principal on every chain the Mandate names; fails for nonce-deployed or replayable contract wallets | card 08 section 9.3 | W21 (code-hash comparison across chains) |

## 5. Proof plan per contract, in execution order

### 5.1 Order of attack

| Layer | Units | Why here | Entry criterion |
|---|---|---|---|
| F0 calibration | TM, AG, ST (one check each), one Core Vault `deposit` check, one Spoke Vault check | exercises every convention (parameters as inputs, `_callAs`, `cover_`, slot map, patched library etch, chain id) and every engine on the cheapest code | G0 green (P-01 to P-12) |
| L0a pure, no arithmetic | TM, RC, MD, C3, CS, C3D | control and encoding only; no linking; closes with bit-vector engines | F0: the same verdict in three engines |
| L0b pure arithmetic | SM, IA | class C: the lemma file born here serves every later layer (vault rounding, CLPS, Aave index, V4 Q128) | P-10 go or no-go recorded |
| L1 small contracts | AG, ST, MR, MFV, TE | loop-free, no library, at most one external call; they are the lemmas the vault layers consume (card 03 item 3) | L0a |
| L2 scalar cores | AB, CLPS, VRR | loop-free decision cores with encoding at the edges; they discharge A-RECV, record A-PRICE as false, and replace models in vault harnesses | L1 |
| L3 adapters | AA, V4A | first protocol models; conformance tests run before any status above V2 | L2; models reviewed (P-15) |
| L4 factory | FF on stub children | derivations from L0a plus guard prefixes | L0a |
| L5a library hosts | CVL in `CoreLogicHost`, SCL in `SpokeLibHost` (mode M2) | per-function steps without vault noise; they prove the M3 summary contracts | L1, L2 |
| L5b vaults | SV, then CV (modes M1 and M3) | compose everything; the Spoke Vault first because it has no share arithmetic, so its harness debugs linking and injection before the Core Vault's class C load, and the Core Vault's liveness rows cite INV-SPOKE-31, 42, 43 | L3 at V2; every summary contract proven; WF bundles reviewed |
| L6 composition | HubPairFormal, `spec/composition/SYS-*.md`, two-chain stateful harness with the reference model | closes SYS-1 to SYS-7a | L5b |

### 5.2 Inductive invariants: the WF bundles

Method per machine: (1) `WF-<MOD>` is the conjunction below; (2) base case: a unit test that the real constructor (or the factory for a fund) leaves WF true; (3) step: for every mutating selector and mode, WF(pre) plus the call implies WF(post), as one combined `check_B_<MOD>_..._step_` per (selector, mode), split per conjunct only on timeout; (4) frame: the V0 writer set; (5) a counterexample to induction from an unreachable injected state means WF is too weak: a new conjunct is registered as `WF-<MOD>-<nn>` with its rationale, fuzzed as a property (P-09) and proven by the same steps. Sampled keys are symbolic parameters, so per-element conjuncts are the full statement; sums need delta lemmas.

| Machine | WF conjuncts | Source |
|---|---|---|
| ST | `supply % 1e18 == 0`; two sampled balances multiples of 1e18; `h1 != h2` implies `bal(h1) + bal(h2) <= supply`; for sampled `o`, `s` the raw storage word at `keccak256(abi.encode(s, keccak256(abi.encode(o, 1))))` (ST slot 1, `_allowances`) is 0, read with `vm.load` or the slot map and never through `allowance()`, because that view is `pure` and always returns 0 (ST:76-78), so a conjunct over it would be true of every state and vacuous (Edit 2.1 row 10) | INV-SHARE-01, 03, 06 |
| MR | `owner != 0`; a sampled entry word has `bps <= 5000`, `exists` in {0, 1}, no other bit | INV-SHARE-22, 26 |
| MFV | the `ReentrancyGuard` status word (storage slot `0x9b779b17...c55f00`, card 03 section 9.5) equals 1, not entered, between calls; this is the only conjunct, because `fund` and `manager` are immutables that the constructor checks non-zero (MFV:26) and MFV has no other state; without it every `withdraw` path reverts on the symbolic-storage routes (`hcheck_`, `prove_`) and the proof is vacuous (section 4.3, section 8.2 item V7; Edit 2.1 row 10) | INV-SHARE-19 |
| TE (clone) | `vault` and `token` both zero or both non-zero; implementation bound to itself (TE:19-21) | INV-SHARE-33, 34 |
| AG | none (every flag pair is legal); steps are the transitions of INV-V4-07 | INV-V4-07 |
| VRR spoke `i` | `acceptedAt_i == 0` implies all fields zero and an empty payload; `ts_i <= acceptedAt_i + maxAge_i`; accepted states only through one real `deliver` in the check | INV-REPORT-04, 11, 33 |
| IA per token, holder | `indexCheckpoint(h, t) <= index(t)`; registered tokens as in the constructor; no width conjunct: the bounds `distributed`, `ownerless`, `taken`, `owed <= 2^255` are not inductive (a step from `distributed = 2^255` with `a = MAX_STEP` leaves them false, card 09 review row 15), so they are carried by the registered assumption A-IA-CALLS (section 4.8, P-05) and named in every label that uses them (Edit 2.1 row 10) | INV-MATH-26, 20; card 09 section 9.6; A-IA-CALLS |
| AA per asset | `s <= H`; `!open` implies `s == 0`; index `>= 1e27` (AS1); allowance to the pool 0; guard slot `!= 2` | INV-AAVE-14, 15, 05 |
| V4A | EnumerableSet index map consistent with its values array; `_positions[k]` non-default iff `k` is in the set; guard slot `!= 2` | INV-V4-11 |
| FF | `_fundCount < 2^64`; slots 1 and 2 written once per creation | INV-FACTORY-12, 13 |
| SV (`WF-SPOKE` = B-SPOKE-BACKING plus structure) | per ledger token `B(t) >= L(t)`; hub role `operatingCash == 0`; built `inFlightIds` and `positions` arrays satisfy INV-SPOKE-13, 14; transit states in {None, Sent, RefundRecognized}; every allowance granted by the vault is 0; guard slot `!= 2` | INV-SPOKE-01, 05, 06, 12, 13, 14, 18, 47 |
| CV (`WF-CORE` = B-CORE-LEDGER plus structure) | INV-CORE-01 (USDC), 02 (other tokens), 03; for sampled holders `h1, h2`: INV-CORE-05, `requests[h].reserved <= payoutReserve`, `balanceOf(h) <= totalSupply`, whole shares (12); `performanceFeeBps <= 2_500`, `managementFeeBps == 0` (32); a sampled transit id in a legal state (38) with its book element `<=` the aggregate; a sampled hub-bound key `credited <= listed` (44); the IA WF | card 01 sections 6 and 9.5 |

Honest limit: `requests[h].reserved <= payoutReserve` follows from the sum identity INV-CORE-04, which closes only by the induction over delta lemmas, so INV-CORE-03 is labelled "V4 modulo the INV-CORE-04 closure" (card 01 states "P, with INV-CORE-04 as axiom").

### 5.3 Legend for the per-contract tables

Engines: every `check_` and `cover_` runs under H (Halmos), V (hevm), F (forge symbolic) and K (Kontrol) unless the row says otherwise; `hcheck_` is H only; `prove_` is K only. "Symbolic" lists the parameters; everything else is concrete. Difficulty: **D1** closes in seconds on every engine; **D2** minutes, or needs bitwuzla, splitting or a concrete table; **D3** not expected to close at full range on the bit-vector engines. Fallback codes are the ladder steps of section 5.17 (S2 solver, S3 split, S4 concretise, S5 quotient witness, S6 narrow, S7 Kontrol, S8 refactor proposal, S9 stop rule). Every `check_` implies its `cover_` twins (success path and each asserted outcome), not listed. FLAGGED `cover_` rows keep their defect id.

### 5.4 Layer L0a: TransitMessage, ReportCodec, MandateLib, Create3, CodeStore, Create3Deployer

| Unit and harness | Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|---|
| TM; `TransitMessageHarness` wrapping `encode`, `decode` (TM:26-44) | round trip (INV-BRIDGE-24); 160-byte word layout and injectivity, words compared, never keccak (25); decode at lengths {0, 1, 31, 32, 33, 159, 160, 161, 192, 1024} and kind word above 1 reverts (26); version word is not the V5 prefix (27); `prove_` of 24 and 25 unbounded; `cover_` trailing bytes accepted (26, AB-5) | `fundId`, `originChainId`, `transitId`, `kind`, content words at each length | A, D1 (length 1024: D2) | length 1024 to a unit test |
| RC; `ReportCodecHarness` (RC:112-128) | round trip per shape S0 to S9 (all arrays empty, all 1, all 2, each of the 7 arrays at 2 with the rest empty) (INV-REPORT-17); `versionOf == 2`; rejects short, wrong version, kind above 1; `prove_` shapes S0 to S2; `cover_` trailing bytes (CF-R8) | every scalar and element field | A, D2 (12-field structs, MCOPY at concrete sizes) | S3 per array |
| MD, FT; `MandateHarness` and `MandateSpec.wf` written from the MD:148-162 NatSpec and the decisions, never from `validate` | `validate` succeeds iff `wf(m)` per sub-validator: adapters, pools, unwind, spokes, bridges, cash, fees (INV-MATH-37 sound, 38 complete, exp form); lookups `isAdapter`, `isBridgeAdapter`, `isAllowedPool`, `isFundChain`, `spokeByChainId`, `operatingCashFor`, `bridgeAdapterFor` (42); creation caps (44); encoding changes with each of the 15 fields, bytes compared by words (40); `cover_` exit-unsafe Mandates accepted: payout fee, term, unwind without hub, bridge fee, Operating Cash, non-EVM spoke word (39, MM-1); optional `prove_` 37, 38 with loop invariants | identifiers from pools of 2 or 3 symbolic addresses, chain ids, pool keys; lengths 0 to 2 (bridge adapters 3) | A, D2 (`prove_`: D3) | S3 per sub-validator; fuzz to length 4 (card 09 W02) |
| C3, CS, C3D; `test/mocks/factory/Create3Harness.sol`, `CodeStoreHarness` | `addressOf` formula (INV-FACTORY-05); salt preimage injectivity and pairwise distinct roles over 96-byte preimages compared by words (06); CREATE address for nonce 1 to 127 and reverts at 0 and 128 (07); used proxy creates only at nonce 2 or above (37); C3D salt bound to the caller (03, under A-KEC); CodeStore round trip at lengths 1, 32, 64 symbolic (18); `prove_` of 03, 05, 06, 07 | deployer, salt, creator, nonce, content words | A, D1 to D2 (07 RLP branches: D2) | S3 per nonce range; CREATE with symbolic init code is Not verified under H and K and partial under V (T 5.11): S4 concrete content, boundary lengths 24,575, 24,576, 49,151 as unit tests |

### 5.5 Layer L0b: ShareMath and IncomeAccumulator (the class C layer)

| Unit and harness | Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|---|
| SM; `ShareMathHarness` (SM:50-125) | initial price at zero supply (INV-MATH-08), zero price reverts in `sharesForDeposit` and `sharesToBurn` (17): A, D1 | amounts | A, D1 | none |
| SM, concrete-rate rows | flow-fee cap per `bps` in {0, 1, 25, 50, 100} and above-cap revert (13); `bpsOf` per {0, 200, 9_900, 10_000} (14); fees within gross per `(pf, ff)` in {(200, 25), (200, 100), (9_900, 100), (10_000, 0)} (15); `cover_` fees exceed gross at `(10_000, 25)` (15, CF-1, MM-2) | amount `<= 2^128`, gross | C with a constant divisor, D2 (25 bps closed in 4.85 s with bitwuzla, card 09 probe 4) | S6, S7 |
| SM, power-of-two smoke | whole shares at prices `2^80`, `2^100` (01): regression guard only, never counted toward V3 | `net <= 2^96` | C, D1 (a division by a power of two closed in 0.08 s, probe 15) | none |
| SM, quotient-witness lemmas | `check_LEM_mintFloorWitness` assumes `k * p <= net * 1e18 < (k + 1) * p` and asserts `floor(k * p / 1e18) <= net` with no symbolic division; burn floor; `usdcFor` monotone (02, 03, 06, 09 with L0); `cover_` sub-unit price mints for free (05, MM-3); `cover_LEM_solverSanity` (the false statement of probe 17 must stay refuted) | `k`, `p`, `net` at `uint128` and `uint96` | C, D3 (Not verified: whether bitwuzla closes the 128-bit products; one-day experiment in L0b) | S7 |
| SM, Kontrol | `prove_` INV-MATH-01 to 12, 16, 18 at full range (05 restricted to `p >= 1e18`) with lemmas L0 to L6; `prove_LEM_L0_mulDivFloor` and `prove_LEM_L0c_mulDivCeil` on OZ `Math.mulDiv` inside a harness (OZM:208-215 single-word branch per card 01 section 9.3) | full ranges | C, D3 | S9, then the full-range differential against the reference model (card 09 W03); outside the single-word domain A-MULDIV |
| IA; `IAFormalHarness` with one `State`, USDC and WETH registered in its constructor, pre-state injected at slots pinned by `test_INV_MATH_harnessSlotMap` | zero supply goes ownerless (INV-MATH-24): D1; `distribute` never reverts from a WF state, `false` iff unregistered, above `MAX_STEP` or overflow (23, exp form; the `mul512(a, 2^128)` high word being 0 closed in 0.12 s, probe 9): D2; skipped means no write (23): D2; index monotone (21): D2; token isolation for `distribute` and `takeOwed` (32): D1; `takeOwed` exact (30): D1; checkpoint below index, steps of `distribute` and `checkpoint` (26): D1; checkpoint exact for two tokens (25, divisor `2^128` is a shift): D2; fresh holder owes zero, zero shares accrue nothing (27, 31): D1; identity at supplies `2^60`, `2^70`, `2^100` (22, smoke): D1 | `amount`, supply `T`, `index`, `remainder`, `distributed`, checkpoints, `shares` | B, C | S3 per branch (`amount > MAX_STEP`, `T == 0`, `tryAdd` fails); S7 |
| IA, Kontrol | `prove_` INV-MATH-22 exact identity and 33 remainder leak bound with symbolic `T` (lemmas L6, L10); `prove_` delta lemmas of 28 (pending plus owed over two symbolic holders) and 29 (dust) for `distribute`, `checkpoint`, `takeOwed` | full ranges | C, D3 | S9; V1 by card 09 W04 |

### 5.6 Layer L1: AdapterGuard, ShareToken, ManagerRegistry, ManagerFeeVault, TransitEscrow

Every row: class A or B, D1, loop-free, no library; `prove_` twins of every row reach V4-k; fallback none expected (a failure here is a harness defect, section 5.18).

| Unit and harness | Obligations (property ids) | Symbolic |
|---|---|---|
| AG; `AdapterGuardHarness is AdapterGuard` exposing `_requireEntryAllowed` (AG:50-53); the same checks re-run on V4A, AA and AB instances | only the guardian calls `setPaused` and `deprecate` (INV-V4-03); deprecation one-way, step of both writers (07); entry gate (08); discharges INV-AAVE-02, 08 and INV-BRIDGE-12, 13 | caller, bool argument, slot 0 bits |
| ST; ShareToken with `coreVault` a fixed pranked address; WF-ST | whole shares, steps of `mint` and `burn` (INV-SHARE-01); strangers cannot mint or burn, plus `hcheck_` any selector by a stranger keeps slots 0 to 4 (02); supply delta and frame (03, 11); mint iff, burn iff, burn never blocks (04, 05, 12); `transfer`, `transferFrom`, `approve` disabled, allowance always 0 (06); metadata frame (10) | holder, amount, supply, two sampled balances, caller |
| MR; fixed owner | registry read never reverts and fits 16 bits (INV-SHARE-21); slice cap steps of set and clear (22); effective slice (23); non-owner cannot write, plus `hcheck_` any selector (24); frame over a second manager (25); ownership machine over `transferOwnership`, `acceptOwnership`, `renounceOwnership` (26, 27) | manager, `bps`, caller, injected entry word |
| MFV; `SymToken` modes | a stranger cannot lower the vault's balance, plus `hcheck_` any selector (INV-SHARE-13); withdraw exact per mode standard, returns false, returns nothing, reverts, fee on transfer (14, V2 per mode); manager can withdraw all (15); re-entrant token reverts (19) | `to`, amount, balance, caller, mode |
| TE; implementation plus a clone from `Clones.clone` | initialise once (INV-SHARE-33); implementation inert for `initialize` and `release` (34); only the bound vault releases (35); release exact (36); escrow uniqueness with concrete salts (38, V2) | caller, arguments, escrow balance |

### 5.7 Layer L2: AcrossBridgeAdapter, ChainlinkPriceSource, ValueReportReceiver

| Unit and harness | Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|---|
| AB; real AB built with the optimizer, `AcrossSpokePoolModel`, `vault` and `guardian` fixed | `buildSend` writes nothing: AB slot 0 and model slots equal before and after (INV-BRIDGE-01); `ab_expected` exp form at length 160 covering acceptance domain, target, `amountToArrive`, recipient and depositor words, `transitRef` equals the counter (02, 03, 05, 07, 08, 09); calldata head words compared by word loads, never keccak (04); `fillDeadline` in the regions normal, wrap zone, after `2^32` (06); flags never change the build, twins (11); `prove_` of all the above at length 160 with `--symbolic-immutables` (Not verified: its semantics, T 8.9) | every scalar of `SendRequest`, depositor, both flag bits, pool counter, `block.timestamp` per region, message words | A, D1 (04: D2) | S3 per word group |
| AB, bounded | 02 and 04 at lengths {0, 1, 31, 32, 33, 159, 161, 192, 1024}; constructor with buffer value, revert, empty return, oversized word (16); exact debit with pool modes honest, less, more, none, reverts, re-enters inside the harness vault MHV (18); guardian sequences of length 1 to 4 (23); wiring predicate under the factory's shape (29) | as above, amounts | A, B, D2 | S4 fewer lengths |
| CLPS; one real instance per configuration row `(fd, td)` in {(8, 18), (8, 6), (18, 18), (8, 8)} plus fixed tokens of 6 and 18 decimals; `SymAggregator`; reference is the multiplicative floor `p * 10^D <= a * 10^24 < (p + 1) * 10^D`, never a second `mulDiv` | kind dispatch unsupported, fixed, feed (INV-REPORT-20); `ps_expected` exp form per row in the single-word range (answer `< 2^176` at (8, 18)) (21); non-positive answer reverts (21); fixed prices for 6 and 18 decimals (23); age never reverts (24); revert set on aggregator revert and short return (25); constructor with `(fd, td)` in `[0, 60]` (28); frame folded into each row with the V0 "no SSTORE, no CALL" scan (19); `cover_` answer `2^150` at `fd + td = 0` gives a price above `2^128` (26, CF-R2) | token, answer, `updatedAt`, amount | A; 21 is C with a constant divisor: D2; 28: D2 with `--solver-timeout-branching 0` | S6, S7 |
| CLPS, value | `usdcValue` never overstates, per row, `x * p < 2^256` (22) | amount, answer | C, D3 | S7 (`prove_` per row) |
| VRR; `ReceiverSymbolicBase`: real receiver with the two spokes of `test/unit/receiver/ValueReportReceiver.t.sol:41-59`, `SymCoreBridge`, `SymCoreVault` (revert flag, re-entry switch, reads `latestReport` in the callback); payload from `ReportCodec.encode` of symbolic scalars at a concrete shape; an accepted pre-state is reached by one real prior `deliver`, never by injecting `bytes` | `rr_expected` exp form over the 13-word scalar decision: accept implies every check and every check implies accept, caller independence on twins, band ignored (INV-REPORT-01, 02, 13, 34); sequences strictly increase (04); replay rejected, step of the induction (03); a revert writes nothing (07); freshness definition and age bound (10, 11); callback after the writes and nested `deliver` reverts (15); supersession over two deliveries (32); read liveness per shape and `latestReport` equals the delivered report (12, 06); constructor with 0 to 3 spokes and duplicates from a pool of 2 emitters (08, 09); `cover_` replay accepted at `block.timestamp == 0` (33, CF-R5); `prove_` of the scalar core at shape S0 | 5 VM fields, report scalars, `now`, injected `_state[0]` word, caller | A, D1 to D2 | S3 per check group; S4 for constructors |
| VRR, shape lemma | L-SHAPE: shape S0 against S1 and S0 against S2 on twin receivers give the same decision (18); lifts 01 and 02 from one shape to all | same scalars, two shapes | A, D2 | the V0 Slither data-dependency check (nothing after VRR:164 branches on array content) carries it alone |

### 5.8 Layer L3: AaveV3Adapter and UniswapV4Adapter

| Unit and harness | Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|---|
| AA; `AaveV3PoolModel` plus two `MockAaveAsset`; `vault` is the harness; index from {1e27, 1.1e27, 1.37e27, 1.6e27, 1.0980000012e27} (the last an F1 seed, card 06 section 9.2) plus one symbolic-index check per property | only the vault calls each verb (INV-AAVE-01); exits ignore flags on twins (07); entry hygiene: allowance 0, refund (05, 18); asset isolation (37); decrease domain, key decoding, entry sizing with params lengths {0, 32, 64} (32, 33, 38); open-state and realized-income steps per verb (15, 24); views live and no over-burn (13, 29); collect never reverts per pool mode (10) | caller, verb, amounts, liquidity, donation, flags, pool modes | A, B; D1 to D2 | S3 |
| AA, rounding | backing step `s <= H` per verb and index (14); rounding direction (16, 21, 27); unwind sizing with ceil `mulDiv` (31); close and illiquid exit (11, 12) | amounts `< 2^96`, index | C; D2 at a concrete index, D3 symbolic | S4, then S7 with lemmas L0 to L9 and the model's floor-mint and ceil-burn rules |
| AA, exit matrix | `aa_exitExpected` over 4 flag states times 8 pool modes times 3 verbs (47, with 10, 11, 12, 17, 22, 35); `cover_` foreign aTokens revert the close (09, 23, F1) and short full withdrawal accepted (28, F2) | amounts, donation, pay delta | A, B; D2 | S3 per cell |
| V4A; `SymV4` with its conformance checker built on the real v4-core libraries; ticks concrete per window (around 0, `lower`, `upper - 1`, `upper`, the extremes +-887,270); `L < 2^127`; fee growth any 256-bit value; `TickMath.getSqrtPriceAtTick` as an uninterpreted strictly increasing function with concrete values at the window ticks | guard prefix per verb: only the vault (INV-V4-01), only the PoolManager calls back (02), swap gate when deprecated (08), registry gate on `poolTokens`, `spotQuote`, `open`, `swap` (12), hookless pools only (44), swap parameters (31): no protocol model needed because the revert precedes every call | caller, id, deadline, amount, token | A, D1 | none |
| V4A, plan and custody | exits ignore flags on twins (09); plan vocabulary and destinations recorded by `SymV4`: action bytes, `payerIsUser`, `TAKE` recipient (05, 06); Permit2 approval hygiene under the Permit2 summary (14); custody zero after open, increase, swap (15); realized-income step (18); minimums per verb (45); swap full fill, settle race, fail closed (30, 32, 33) | amounts, fee growth, minimums, hostile token switch | B, D2 | S3 |
| V4A, arithmetic | entry cost and "the plan nets to zero at the PoolManager" per tick window (17, 20); spot quote per `sqrtP` (28); unwind sizing with ceil `mulDiv` (25); fee-growth wrap equals V4's `Position.update` expression (38, V4A:612-613 against the v4-core `Position.sol:93-96` per card 05 section 9.1); `cover_` approve hook shifts the recorded key (10, CF-V4-1) and read-only window in `increasePosition` (35, CF-V4-5) | `L`, `n`, `d`, amounts, `inside`, `last` | C; 17, 20 D3; 28 D2 to D3; 25 D3; 38 D2 | 17, 20: S4 fewer windows, then card 05 V4-W04 differential and the local real-V4 tier (V1); 25, 38: S7 with L7 and the OZ-versus-FullMath lemma L8 |

### 5.9 Layer L4: FundFactory

Harness: the stub-code factory of card 08 section 9.5 (the real FF bytecode with code stores holding stubs that have the exact constructor signatures, decode their arguments and store their hash; `coreVaultCreationCodeHash = keccak256(type(StubCoreVault).creationCode)`); Kontrol pins `chainid = 42161`.

| Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|
| `createFund` guard prefix: caller, manager, `m.hubChainId`, pinned Core Vault hash, with Mandate arrays at fixed lengths (sound because no check before FF:159 reads an array element, card 08 section 9) (INV-FACTORY-01); `createSpoke` guard prefix (02); pinned code hash, base-token and chain gates (16, 24, 38) | caller, manager, chain ids, hash | A, D1 to D2 | S3 per guard |
| creation counter step with `_fundCount` injected below `2^64` at slot 0 (12) | counter | A, B, D2 | none |
| predicted addresses enforced for Mandate arrays of length 0 to 3 (19); Uniswap pools match (21); Aave assets (22); no salt reuse after one creation, manager binding, atomicity with a reverting stub (09, 10, 14) | one address per array (prediction or free), pool ids, stub tokens, one prior creation | A, D2 to D3 | S4; V1 fuzz of card 08 W6 |
| `cover_` non-inert chunk accepted (15, FF-1) and linked library unbound (17, FF-2); income-token list (23) only after refactor R-FF1 | chunk byte 0, library word | A, D2 | release gate W8 of card 08 |

Kill criterion (card 08 section 10.1): if CREATE2 with the stub init code does not execute under Halmos or KEVM within one agent-day, rows 3 and 4 fall back to concrete Mandates on the success path (V1 plus fork), and the guard-prefix and derivation rows keep their tiers.

### 5.10 Layer L5a: the linked libraries in their hosts (mode M2)

| Host and entries | Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|---|
| `CoreLogicHost`: `sendToSpoke` path, `attestExpiry`, `recognizeRefund`, `applyReport` (CVL:417) | B-CORE-TRANSIT: legal transitions per writer (INV-CORE-38; writers CVL:454, 616-618, 721, 749), books as delta lemmas with an untouched second transit (39), fresh ids (`++s.transitNonce`, CVL:587) (40); confirm only on the own spoke's listing (41); attest conditions (42, window-full branch as a unit test); refund exact (43) | transit fields, report listing at arrays of 1 to 2, time, wiring `w` | A, B; D2 | S3 per transition |
| `CoreLogicHost`: `applyReport`, `receiveHubBound` | hub-bound ledger: `credited <= listed`, kind by listing, `unmatchedArrivals` identity as a delta lemma (44); `cover_` zero listing keeps the kind mutable (CF-11) | key, listed and credited amounts, kind | B, D2 | S3 |
| `CoreLogicHost`: `collectIncome` (CVL:382), `protocolSliceBps` (CVL:401) | fee split `fee + slice + net == x` per `perf` row {0, 1_000, 2_500} under H, V, F and symbolic under K (INV-CORE-50, INV-SHARE-29); income delta (51); only collection and matched Income arrivals advance the index (56, with the V0 caller gate) | `x`, slice `<= 10_000`, registry mode | C with constant or 16-bit factors (card 01 section 9.2), D2 | S4 |
| `CoreLogicHost`: `recordValuation` (CVL:89), `shareAssets` (CVL:106) | last values refreshed only on a successful read (INV-CORE-49, CVL:98, CVL:101); counted once and matches the model at 2 spokes and arrays of 2 (47, 07); **summary obligation** for `CoreVaultLogicSummary`: the real function writes only `lastHubValue` and `lastPrice[t]` and its outputs satisfy the summary's constraints | report scalars, one priced leg, flags | C, D3 (valuation), B for the summary frame | 07, 47: full-size differential against the reference model (V1); summary: S3 per output |
| `SpokeLibHost`: `sendToHub` (SCL:38), `recognizeRefund` (SCL:70), `nextReport` (SCL:99) with a concrete vault address and nonce (so the CREATE2 escrow address is concrete) | send exact per bridge-target mode (INV-SPOKE-09); refund exact (11); transit states legal (12); fresh escrow per transit (45); quote bound per `maxBridgeFeeBps` row {0, 5, 30, 100, 10_000}, V3-k general (10, `_checkQuote` SCL:215-223); in-flight list at length up to 3 (13); ring index formula (23); MCOPY layout of the report (26) | amount, quote, rank in {0, 1, 2 unknown}, escrow balance | A, B; D2; 10 C constant D2; 26 D3 | 26: card 02 W10 differential |

### 5.11 Layer L5b: SpokeVault (hub-role and spoke-role instances)

Harness `SpokeVaultFormalBase` (card 02 section 9.5): concrete Mandates with 2 position adapters, 3 pools including a single-asset pool, 2 unwind steps, 2 spoke-side bridge adapters and an Operating Cash entry; `ModelAdapter`, `SymToken`, the real AB with the pool model, the real TE, `ModelCoreVault`, `ModelWormhole`; `SpokeVaultExposed is SpokeVault` for internal helpers (Not verified: that it deploys under each engine's size switch, card 02 section 10 item 9); library through mode M1. Decomposition cuts (A section 5.3): selector (17 mutating selectors), role (hub, spoke), mode (branch conditions assumed, with a `check_..._modesExhaustive` proving the modes cover every input and a `cover_` per mode), dependency flags (concrete per check plus one symbolic-flag check per liveness property), nesting (callbacks from `ModelCoreVault` and re-entrant tokens try every selector). Expected size: about 45 combined steps.

| Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|
| `check_B_SPOKE_BACKING_step_<selector>_<role>_<mode>` for the 13 loop-free writers `openPosition`, `increasePosition`, `decreasePosition`, `collectIncome`, `swapExactInput`, `swapCollectedIncome`, `setOperatingCashParameters`, `recognizeRefund`, `handleV3AcrossMessage`, `receiveFromCoreVault`, `returnToCoreVault`, `forwardIncomeToCoreVault`, `sweepExcess` as listed by card 02 section 9.1 (INV-SPOKE-01, 05, 06, 12, 13, 14, 18, 47) | caller, arguments, injected ledger fields and balances, adapter returns | B, D2 | S3 per conjunct |
| the same bundle for `closePosition` (key scan up to 3), `sendToHub` (concrete vault address and nonce, so the escrow CREATE2 address is concrete; its per-function step is proven in `SpokeLibHost`, 5.10), `report` (arrays at the bounds of 5.14) and `unwindForPayout` (2 steps, 3 positions, hints of up to 2 swaps) | as above | B, D3 | S3; V1 (card 02 W3, W4) |
| top-up through `SpokeVaultExposed._topUpOperatingCash` (SV:988-998): never decreases, bounded growth, never reverts (06, 07, 47) | floor, top-up, cash, unallocated base | B, D1 (V3-k) | none |
| role gate per selector (19) plus `hcheck_` any selector by a stranger; chain-role gate (20); permissionless calls independent of the caller on twins (21) | caller, arguments | A, D1 to D2 | none |
| arrival credit from a 160-byte message (22); forward exact and Core Vault legs (42, 43); sweep exact for any token address (03); swap output and token (46); buckets never mix per verb (05); entry usage (08); send exact per target mode (09); refund exact (11); call targets and recipients through recording models (16, 17); counters monotone (24) | message words, amount, balances, returns, pull amount | A, B; D1 to D2 | S3 |
| exits ignore adapter flags and succeed with a conforming adapter (29, 30); report liveness per shape (40); no re-entry per callback source (36); constructor for Mandate arrays of 0 to 2 (44); distinct transit ids and escrows (45) | flags, shapes, re-entry selector | A, B; D2 | S3, S4 |
| unwind proceeds bounded and swap floor (31, 33), also inside HubPairFormal | target, values, quotes | B, C; D3 | S3, S4 |
| `cover_` prior excess masks a short transfer (02 hostile form); `cover_` Aave F1 blocks close (30 with the F1 flag) | adapter over-report, donation | B, D2 | pinned until the rulings |
| `prove_` of the loop-free bundle steps and of 03, 06, 07, 10, 19, 20, 22, 42, 46, 47; optional `prove_` that library writes stay under `_s` (38) | K, `symbolicStorage` constrained by WF-SPOKE | A, B; D2 to D3 | keep V3-bv or V2 |

### 5.12 Layer L5b: CoreVault family with CoreVaultLogic

Harness `CoreVaultFormalBase` (card 01 section 9.5): the real Core Vault, `ShareToken`, `ManagerFeeVault`, `TransitEscrow`, the real `ManagerRegistry` or `SymRegistry`, `SymHubSpokeVault`, `SymReceiver`, `SymPriceSource`, the real AB with the pool model, a one-spoke Mandate, income tokens USDC and WETH; ledger injected at the generated slots (idle 12, payoutReserve 13, operatingCash 14, floor 15, top-up 16, fee bps 17, unmatchedArrivals 18, transitNonce 19, collectedIncome 25, requests 26, transits 27, spokeBooks 29, hubBound 30, lastHubValue 33, lastPrice 34, per card 01 section 9.5); library through M1, or M3 for ledger-only steps; `CoreVaultExposed` for `_topUpOperatingCash` (CVB:283). Decomposition cuts as in 5.11 plus valuation shape (accounting steps run at the smallest shape; valuation properties get their own shapes). Modes follow card 01 section 2.1 (for example `claimPayout`: Instant or Standard, Idle covers or unwind, unwind succeeds, partly succeeds or reverts, full burn, partial, closed below one share). Expected size: about 70 combined steps.

| Obligations (property ids) | Symbolic | Class, difficulty | Fallback |
|---|---|---|---|
| `check_B_CORE_LEDGER_step_<selector>_<mode>` for `deposit` (first, later), `requestPayout` (Instant, Standard, fallback), `claimPayout` (modes above), `withdrawIncome`, `receiveCollectedIncome` (ok, registry fallback, zero supply), `decreaseManagerFee`, `setOperatingCashParameters`, `allocateToHubSpokeVault`, `returnToIdle` (direct, nested inside `claimPayout` through `SymHubSpokeVault`), `sendToSpoke` (per target mode), `attestExpiry`, `recognizeRefund`, `onReportAccepted` (arrival lists 0 to 2), `handleV3AcrossMessage` (listed, unlisted), `sweepExcess`, asserting WF-CORE (INV-CORE-01, 02, 03, 05, 12, 32, 38, 44 and the IA WF) | caller, arguments, injected scalars, two sampled holders, one sampled transit and hub-bound key, dependency flags | B, D2 to D3 | S3 per conjunct, then per mode; M3 summary for valuation |
| reserve delta for `requestPayout`, `claimPayout` plus frame twins (04); books delta (39); hub-bound delta (44); income delta for `receiveCollectedIncome`, `withdrawIncome`, full-burn `claimPayout`, `deposit` (51, 52) | touched and untouched keys | B; 04, 39, 44 D2; 51, 52 D3 | 51, 52: V1 with card 01 W04 ghosts |
| role gate per restricted selector (29) plus `hcheck_` any selector by a stranger; caller scope of `requestPayout`, `claimPayout`, `withdrawIncome` (30); Operating Cash bound, sweep exact, allocate (09, 10, 34); flows to allowed destinations only through the recording token (11, SYS-7a) | caller, floor, top-up, token, amount | A, B; D1 to D2 | none |
| deposit arithmetic per flow row {0, 25, 100} (14); dilution bound, payout bound, round trip at the widths of 5.14 (15, 16, 17); flow-fee cap and fee split per rate row (33, 50); partial payout (22, 23): the step checks stay linear and the call site feeds the ShareMath lemmas the price the valuation returned (M3 with a symbolic price) | amount `<= 2^96`, price, supply, Share Assets | C; 14 to 17, 22, 23 D3; 33, 50 D2 | S5 quotient witness, S7; card 01 W05 |
| unwind credit and `_unwinding` reset with the havoc hub (25, 26); `requestPayout` revert set per receiver and price flags (27); send guards, exact debit, value lowered (35, 36, 37); nonce strict, arrival needs listing, attest rule, refund exact (40 to 43); valuation modes MINT, PAYOUT, VIEW per flag (48, 49); checkpoint before balance change, full-burn income, index monotone (53, 54, 55) | unwind `x`, callback `y`, flags, transit fields, time | A, B; D2 | S3 |
| exit matrix `exitExpected(flags, state)` per cell with every model's revert flag symbolic (21, 27, 48); `cover_` FLAGGED cells: fees above gross panic (20, CF-1), paused income token blocks a full burn (21, CF-2), blocked Protocol Recipient (21, CF-3), zero fallback price blocks a request (27, CF-9), Across credit without backing (45, CF-5), skipped distribution still credited (INV-MATH-36, MM-5), zero listing keeps kind mutable (44, CF-11), codeless registry blocks collection (INV-SHARE-30, SF-1) | flags, amounts | A, B; D1 to D2 | pinned until the rulings |
| Share Assets against the reference model and counted-once at shapes up to 2 and one priced leg, plus a 5-token `_grow` check (07, 47) | report scalars | C, D3 | card 01 W11 differential (V1) |
| `prove_` of INV-CORE-03, 05, 12, 32, 33, 40, 50, 55 and of the WF steps whose valuation has no priced leg | K with lemmas, `symbolicStorage` on `_s` | B, C; D3 | stop rule; keep V3-bv or V2 |

### 5.13 Layer L6: composition

- `HubPairFormal` (section 4.5): INV-CORE-25 and INV-SPOKE-31 together at V2, real Core Vault and real hub Spoke Vault, adapters modelled, arrays of 1 or 2.
- `spec/composition/SYS-1.md` to `SYS-7.md`: premises resolved to registry ids and statuses; the status of each SYS row is the minimum over its premises, capped at C.
- Two-chain stateful harness (V1) with `CoreModel` (a Solidity transliteration of the reference model by the same author) asserting every ledger variable after every successful action, and nightly corpus replay through `spec/model/replay.py` (B section 9.3).

### 5.14 Loop bounds and value widths

Rule: every array in a check has a concrete length and the unrolling bound is the longest length plus one, so no path is cut; a Halmos `LOOP_BOUND` warning [F6] or a hevm partial exploration [F7] fails the check. A bound is acceptable only with the reason in the last column, and it is printed in the label.

| Loop site | Bound | Why the bound loses nothing that matters | Settings |
|---|---|---|---|
| IA:241 checkpoint over income tokens (`MAX_TOKENS` = 16, IA:25); full-burn payment CVI:47-50 | 2 registered tokens | exact generalisation by INV-MATH-32 (token isolation) | Halmos `--loop 3`; hevm `--max-iterations 3` |
| MD validation, 14 loops (card 09 section 9.4) | lengths 0 to 2, bridge adapters 3 | small-scope argument: every predicate is unary, pairwise within one array, or an existence check (card 09 section 9.2); argued, cross-checked by fuzz to length 4 | `loop = 4` |
| CVL valuation and report loops (CVL:182, 241-247, 256, 297, 328, 363, 444, 469, 556, 699) | arrays 0 to 2; one check with 5 priced tokens so `_grow` (CVL:358) runs once | per-element bodies; two elements show accumulation and pairwise interaction (card 01 section 9.3) | `loop = 3` (6 for `_grow`) |
| CVL:554 arrival window of 256 | not symbolic | one comparison; a 256-entry symbolic array exceeds hevm's `--max-dyn-size` default of 64 (T 5.11) | unit test |
| SCL:103-106, 122, 146, 156, 171, 181; SV:537, 729, 739, 828, 880 | in-flight ids 3, ledger tokens 3, adapters 2, positions 3, arrival count 3, unwind steps 2, hints 2 of up to 2 swaps | three elements cover the three swap-and-pop cases of the backward pruning loop (card 02 section 9.2) | `loop = 4` |
| constructors CVB:108, 124-141, 153; SV:189, 200, 212, 220; VRR:103; CLPS:80, 97; V4A:228-242; AA:129-137 | concrete configurations in step checks; separate constructor checks at lengths 0 to 3 | Halmos needs a single constructor path (T 5.8) | `--solver-timeout-branching 0` for constructor checks |
| V4A:296-304 `cumulativeIncome`; V4A:730 plan copy | 3 positions; plan of at most 5 actions (static) | per-position terms; the plan bound is exact | `loop = 6` |
| AA:327-334 | 1 or 2 assets | per-asset isolation (INV-AAVE-37) | `loop = 3` |
| FF:244, 315, 323, 330, 387, 418, 485, 499 | Mandate arrays 0 to 3 | each iteration checks one element; the counters' three outcomes occur by length 3 (card 08 section 9.2) | `loop = 4` |
| CS:27-50 chunk loop | 1 to 3 chunks | per-chunk body | symbolic content at lengths 1, 32, 64 only |
| Kontrol | `--bmc-depth` at the same bounds [F1]; unbounded only with a loop invariant, attempted for MD (INV-MATH-37, 38) and nowhere else | | |

Widths when a class C check is bounded (card 01 section 9.3, card 09 section 9.2): USDC amounts and Share Assets `<= 2^96` (USDC supply is about `2^56` base units), share amounts and supply `<= 2^128`, prices in `[1, 2^128)` and share amounts `<= 2^128` (Edit 2.1 row 9: card 09 probe R3 shows `usdcFor` leaves the single-word `mulDiv` branch inside `2^136`; the earlier bound of `2^136` came from card 09 probe P6), Aave values `< 2^96` with the index in `[1e27, 1024e27]`, V4 liquidity `< 2^127` at concrete ticks. A narrowed width is recorded in the label and never widened silently.

### 5.15 Nonlinear arithmetic: the lemma file and how each fact is proven once

1. **L0 `mulDiv` summary**: for `x * y < 2^256` and `d > 0`, OZ `Math.mulDiv(x, y, d)` returns `floor(x * y / d)` (single-word branch, OZM:208-215 per card 01 section 9.3; derivation in card 09 section 9.1); **L0c** the ceil variant used at V4A:325 and AA:347. Proven as `prove_LEM_L0_mulDivFloor`, `prove_LEM_L0c_mulDivCeil` on the compiled OZ code; outside the single-word domain it stays A-MULDIV, backed by OZ's own fuzz tests and card 09 W03's 512-bit oracle.
2. **L1 to L6** (card 09 section 9.6): `(a / b) * b <= a`; `a < (a / b + 1) * b`; monotonicity in the numerator and in the denominator; `(a * c) / (b * c) == a / b` for `c > 0`; `a == (a / b) * b + a % b`. **L7** ceil bounds `c * ceil(a * b / c) >= a * b` and `< a * b + c` (INV-V4-25, INV-AAVE-31). **L8** OZ `mulDiv` and v4-core `FullMath.mulDiv` agree whenever the result fits (both equal L0), which with the literal repetition of `Position.update`'s expression gives INV-V4-38. **L9** Aave scaled rounding `floor(amount * 1e27 / I)` and `ceil(...)` (card 06 section 9.1). **L10** for `a < 2^128` (guaranteed by the `MAX_STEP` guard at IA:183): `mulmod(a, 2^128, T) == a * 2^128 - T * mulDiv(a, 2^128, T)` (IA:194-195); with L6 it gives INV-MATH-22, and the bit-vector half (`mul512(a, 2^128)` has a zero high word) already closed in 0.12 s (card 09 probe 9), so only the division identity needs Kontrol.
3. All lemmas live in `spec/lemmas/lemmas.k` as K rules with the `simplification` attribute, loaded through `require` and `module-import` in `kontrol.toml` and rebuilt with `--rekompile` [F2]; this overrides the `require = 'test/formal/lemmas.k'` path of the T 8.9 sketch. Each lemma is a registry row of kind `lemma`, proven once by a Kontrol claim or by K's built-in simplifications (Not verified which, card 09 section 9.6), or registered as `A-LEM-n`; an admitted lemma makes every dependent proof fail the V3-k evidence rule (`admitted: False` is required [F8]).
4. **Quotient-witness form** for the bit-vector engines: a symbolic divisor is replaced by its defining inequalities (section 5.5, SM rows), so the solver multiplies and never divides by a symbolic value. Not verified: that bitwuzla closes the 128-bit products (one-day experiment in L0b).
5. **Concrete-rate rows**: rates and decimals are per-fund or per-source immutables (`flowFeeBps`, `payoutFeeBps` CVB:47-48; `maxBridgeFeeBps` per spoke; feed decimals CLPS:85-95), so a proof per concrete row is a proof for every fund with that row. The fund's own rows are re-run by the deployment script at `createFund` ("fund certificate", V2 even under NO-GO).
6. **Power-of-two smoke** (0.08 s, probe 15) guards control flow around the arithmetic and never counts toward V3.
7. **V4 math**: `TickMath.getSqrtPriceAtTick` is an uninterpreted strictly increasing function with concrete values at the window ticks; `SqrtPriceMath` runs as is with concrete ticks and symbolic amounts (card 05 section 9.5).
8. **Keep values out of step assertions**: vault steps assert that the ledger and the balance moved by the same symbolic amount; the amount's value, produced by `mulDiv`, appears only in path conditions (class B), so B-CORE-LEDGER, B-SPOKE-BACKING and the delta lemmas stay linear (card 01 section 9.2 last row).

### 5.16 Solvers and timeouts

| Engine | Solver order | Timeouts: PR / nightly / release | Other settings |
|---|---|---|---|
| Halmos 0.3.3 | yices (default) for class A; bitwuzla for class B and C checks (the only solver that closed probes 4, 8, 15); z3 and cvc5 as a third opinion | `solver-timeout-assertion` 60 s / 300 s / 600 s with `solver-timeout-branching 0` for deterministic release runs (T 5.8, T 8.8) | `function = "^check_"` (never the default that also runs `invariant_`), `match-contract = "Formal$"`, `--loop` per 5.14, `storage-layout = "solidity"`, memory capped by the container (`solver-max-memory` defaults to unlimited, T 8.8) |
| hevm 0.58.0 | z3 first; bitwuzla once a pinned binary exists (T 8.10, T 9.3) | `--smt-timeout` 60 / 300 / 600 | `--prefix check`, `--max-iterations` = bound + 1, `--num-solvers 2` on 8 GB, `--only-deployed`, `--smt-memory` (Linux only) |
| forge `--symbolic` (preview) | z3; `solver_portfolio` with cvc5 when installed | `timeout` 60 / 120 (the `verify` profile, T 8.1) | never carries a status alone (preview; no documented vacuity signal, B section 14) |
| Kontrol 1.0.255 | Z3 through KEVM (Not verified: default options) | `--smt-timeout` in ms with `--smt-retry-limit` [F1]; start at 1,000 ms (T 8.9) | `--use-booster`, `--workers 2` on 16 GB, `max-depth 25000`, `--no-break-on-calls` for long proofs [F1]; runs only on the 16 GB runner (T 5.12) |

### 5.17 When a proof does not terminate (ladder)

Each step is recorded in the registry row's history so nobody retries a dead end:
1. (S1) Read the statistics (Halmos `--statistics`, hevm warnings, Kontrol pending nodes) to tell path explosion from a hard query.
2. (S2) Swap solver, then a portfolio.
3. (S3) Split per conjunct of a combined step, per mode (assume the branch condition), per dependency flag; each split is a registered sub-obligation, and the parent is proven only when all are.
4. (S4) Concretise a per-deployment parameter into a table (rates, decimals, the Aave index set).
5. (S5) Replace a symbolic divisor by its quotient witness, or move arithmetic out through an M3 summary and cite the lemma.
6. (S6) Narrow a width; the label records it (the result is V2, never V3).
7. (S7) Move the obligation to Kontrol with the lemma file; a stuck proof gets a new lemma only if that lemma is proven or registered.
8. (S8) Propose a behaviour-preserving refactor (section 6), founder decision.
9. (S9) Stop rule: one agent-day per property for V2 and V3-bv, two for V3-k (T 10 row 9 sets two working days for Kontrol); then the status stays at the best tier reached, Halmos's saved timeout queries are archived, and the coordinator chooses between a refactor proposal, a lemma, or acceptance at the lower tier.

Never: raise a timeout without bound, add an unregistered `vm.assume`, or keep a PASS obtained with a `LOOP_BOUND` warning.

### 5.18 Counterexample triage

1. Replay concretely: a generated `test_CEX_<property>_<yyyymmdd>` in `test/regression/` with the counterexample's values, the same models and the same injected state (forge `--symbolic` can emit it with `--emit-regression`, T 5.6; Halmos and hevm counterexamples are converted by a script).
2. Classify: **real** (a call sequence from the constructor reaches the state: search it with the stateful handler seeded by the counterexample, then write a unit test); **CTI** (unreachable injected state: strengthen WF, section 5.2); **model artefact** (the model allowed a behaviour its discharger's proven guarantee excludes: restrict the model and cite the guarantee, section 4.8); **harness defect** (wrong slot, wrong wiring, swallowed revert: fix the harness, record it); **tool artefact** (keccak uninterpreted, `[not reproducible]`, T 5.11).
3. A real counterexample becomes a FLAGGED pin and a finding for the coordinator with the property id, the decision it breaks and the replay; the `check_` becomes a `cover_` until the founder rules.

## 6. Code preparation proposals that need the founder

The contracts are on the audit path, and any edit under `src/`, a comment included, changes the metadata hash and the bytecode [F9]: a new factory would pin a new Core Vault creation-code hash (FF:115) and new funds would pin new adapter codehashes (SV:188-195). **No proposal below is needed to start**, and only two targets of section 1.4 depend on one (INV-FACTORY-23 on R-FF1; a V3 instead of V2 label for the valuation properties INV-CORE-07 and 47 would need R-C3, which is not proposed). Everything that can be done on the test side is done there (section 4: verify profile, inliners, hosts, exposed subclasses, stub children, generated constants).

Recommendation: decide the rows below **as one batch before the audit freeze, or none**. Each accepted row lands with `hevm equivalence` per external selector of the changed contract on the `verify` build against the last audited tag in a separate worktree (T 8.10), the full existing suite, a gas snapshot diff and a forge log comparison (hevm ignores logs). Piecemeal refactors after the audit re-open it for little proof gain.

| Rank | Id (card) | Change | Proof gain (reason) | Risk of not doing it | Equivalence caveat |
|---|---|---|---|---|---|
| 1 | R-M2 (card 09 section 9.7) | `(amount << 128) / totalShares` instead of `Math.mulDiv(amount, Q128, totalShares)` at IA:194 | removes `mul512` and the 512-bit branch from every income proof; INV-MATH-22, 23 may close on the bit-vector engines | on Kontrol NO-GO the income identity stays V2 smoke plus V1 differential; on GO lemma L10 covers it and the gain is small | identical because `amount <= MAX_STEP < 2^128` (guard at IA:183) |
| 2 | R-C1 (card 01 R1 = card 09 R-M3) | pure `ShareMath.payoutAmounts(gross, mode, payoutFeeBps, flowFeeBps)` from CV:221-226 | INV-CORE-20 and INV-MATH-15 become one lemma on a pure function | CF-1 arithmetic is proven only through the vault harness (D3) | preserves the CF-1 panic; it is not the CF-1 fix |
| 3 | R-B1 read as R1b, R-B2 (card 07 section 9.6; Edit 2.1 row 13) | R-B1 is R1b, the two-part encoder: in a `private pure` function build `call.data` of AB:107-125 as `bytes.concat(IAcrossSpokePool.depositV3.selector, abi.encode(...), abi.encode(...), abi.encodePacked(message.length, message, padding))`, the first `abi.encode` taking depositor, recipient, inputToken, outputToken, inputAmount, outputAmount and the second taking destinationChainId, exclusiveRelayer, quoteTimestamp, fillDeadline, exclusivityDeadline and the `message` offset `12 * 32`; the first-written R1 (the same 12-value `abi.encodeCall` moved into a `private pure` function) is refuted by probe P13, which shows it still fails to compile with the optimizer off because the 12-value ABI encoder is itself too deep; R-B2: the checks of AB:96-102 into an `internal pure` one with the same revert order | removes the optimizer-only compile trap: R1b compiles with `--optimize false` (probe P13) and was byte-identical to AB in return and revert data on 5,000 fuzzed requests (messages up to 2,048 bytes) and on 9 edge lengths (card 07 section 9.6), so coverage runs without `--ir-minimum`, Scribble on AB becomes possible, and every tool that recompiles can build the file | AB stays outside Scribble and outside any tool that compiles with solc defaults; coverage attribution stays approximate | bytecode diff to re-audit: runtime 2,642 B against 2,347 B (10.7% of EIP-170); build gas not measured (Not verified: re-measure); `hevm equivalence` on `buildSend` and every getter plus a forge log twin |
| 4 | R-R1 (card 04 R1) | VRR checks (VRR:149-181) into two internal pure functions called at the same points | the scalar decision becomes a pure function, provable without storage, bridge or decode | the L-SHAPE twins carry it (D2); nothing blocks | none expected |
| 5 | R-U2 (card 05 R2), R-A1 (card 06 R1) | `V4AdapterMath` and an Aave arithmetic library of pure functions taking the protocol answers as arguments | adapter lemmas (INV-V4-25, 38; INV-AAVE-14, 16, 21, 27, 31) with no protocol model | those proofs run through `SymV4` and `AaveV3PoolModel` (D3) | bytecode diff to re-audit |
| 6 | R-M1 (card 09), R-S1 (card 02 R1) | IA `_step` pure; `_checkQuote` (SCL:215-223) and the ring index (SCL:172) as internal functions of SVT | INV-MATH-22, 23 storage-free; INV-SPOKE-10, 23 as pure specs | reachable only through vault or library entries (the SCL helpers are `private`) | library bytecode only |
| 7 | R-S2 (card 02 R2) | field-by-field copy instead of the MCOPY at SCL:201-206 | removes a silent layout coupling between `IAdapter.PositionValue` and `ReportCodec.PositionReport` and one assembly block | INV-SPOKE-26 stays V1 differential plus a V2 layout check | a few hundred library bytes, more gas per position |
| 8 | R-FF1 (card 08 R1) | FF private helpers (FF:275-335, 345-510) to `internal` | direct targets for INV-FACTORY-05 to 07, 19, 23 | INV-FACTORY-23 stays V1 or V2 through `createFund` | runtime expected unchanged apart from metadata (Not verified: compare `deployedBytecode` without the CBOR tail) |
| 9 | R-C2 (card 01 R2), R-M4 functions only (card 09) | delete dead `CoreVaultLogic.valuation` (CVL:67-73), `CoreVaultBase._spoke` (CVB:350-353) and the unused library functions | smaller audited surface | none for proofs | deleting the storage fields `sourceCumulative` and `flaggedSources` (IA:70-71) would move every later `CoreVaultState` slot and is excluded |
| 10 | R-S3 (card 02 R3), R-FF2 (card 08 R2), view additions R-C4, R-R2, R-P3 (cards 01, 04) | unwind sizing as an internal view; factory pure library; views `ledgerOf`, `unledgeredOf`, `acceptedAt`, `reportTimestamp`, `scaleOf` | cheaper per-position specs and monitors | none for proofs (and predicates must not call rule-encoding views anyway, rule 3.3-1) | vault bytes against the 932-byte margin (T 1 item 5) |
| not proposed | R-C3 (card 01 R3), R-R4 (card 04 R4) | valuation snapshot split; explicit seen flag in VRR | would lift INV-CORE-07, 47 to pure proofs; would remove CF-R5 | V2 labels stay | not equivalent: revert order changes when two dependencies fail in MINT mode; the seen flag differs at `block.timestamp == 0` and costs a slot |

**Behaviour changes that flip specifications** (rulings, not refactors). Each fix flips a registry row from `flagged` to `holds`, and its pin must fail in the fix's PR so pin and status change together: CF-1 (INV-CORE-20, INV-MATH-15, 39); CF-2 and CF-3 (INV-CORE-21 cells, INV-REPORT-30); CF-5 (INV-CORE-01 unconditional, 45; A-LEDGER); CF-7 and card 02 T1 (INV-CORE-59, SYS-6); CF-9 and MM-4 (INV-MATH-17); CF-R2 (INV-REPORT-26, which discharges A-PRICE and lifts the conditional core liveness rows); CF-R3 (INV-REPORT-27); SF-1 (A-REG); SF-2 (INV-SHARE-20); CF-V4-1 (INV-V4-10, 19); CF-V4-2 (INV-V4-42); F1 (INV-AAVE-09, 23); F2 (INV-AAVE-28); MM-1 (INV-MATH-39); MM-3 (INV-MATH-05); MM-5 (INV-MATH-36); FF-1 and FF-2 (INV-FACTORY-15, 17); FF-6 (INV-FACTORY-33); AB-1 (INV-BRIDGE-22); card 02 T5 (INV-SPOKE-41).

## 7. CI and regression

### 7.1 Jobs (added to the layout of T 9; public `ubuntu-latest`: 4 vCPU, 16 GB, 6 h per job, T 9)

Edit 2.2 row 23 (applied 2026-09-30): the `kontrol` and `measure` workflows land on `main` as skeletons with `workflow_dispatch` inputs `ref` and `target` in package B01, before any package that needs them, because GitHub lists a dispatchable workflow only from the default branch (Not verified against the Actions documentation); a package branch then runs them with `gh workflow run <workflow> --ref verify/<pkg>`. Any condition that needs time or a merge to `main` (two clean nightly campaigns, a green job on `main`, two green weeks) is gate evidence for G1, G2F or G6, never the acceptance criterion of a package.

| Job | Trigger | Content | Budget | Fails when |
|---|---|---|---|---|
| `spec-lint` | every PR | section 3.7 rules including `check_closure.py` | 3 min | any lint error |
| `structural` | every PR | V0 gates: writer and caller sets against baselines, selector and ABI sets, opcode scans, storage-layout diff, slot-map regeneration and `SlotMap.t.sol`, link-identity gate (section 4.5) | 10 min | a diff without a registry edit in the same PR |
| `spec-totality` | PR touching `test/spec/` | `check_TOTAL_<predicate>` under Halmos | 10 min | a predicate can revert |
| `formal-fast` | PR touching `src/**`, `test/spec/**`, `test/formal/**` | Halmos and forge `--symbolic` on the checks whose footprint intersects the diff (`spec-impact.py`), plus the F0 set, `solver-timeout-branching 0` | 30 min | FAIL, TIMEOUT, `REVERT_ALL`, `LOOP_BOUND`, a `cover_` that passes; non-blocking for the first two green weeks, then blocking |
| `fuzz-fast` | PR | new harnesses at the default profile with panic passthrough; Medusa smoke of T 9.1 | 15 min | any failure |
| `formal-nightly` | nightly | every `check_` and `cover_` under Halmos and hevm (the verify build in its own job, since hevm reads `./out` only, T 7 item 8) and forge `--symbolic`, sharded per module | 6 h per shard | as `formal-fast`, plus any hevm partial exploration or all-revert |
| `fuzz-nightly` | nightly | Echidna and Medusa campaigns with corpora keyed by harness hash; forge `deep` profile; corpus replay against the reference model | 6 h | a failure or a model disagreement |
| `kontrol` | weekly and every tag | every `prove_` and the Kontrol run of the portable files, image pinned by digest, `out/proofs` cached per bytecode hash; Kontrol itself discards proofs whose contract digest changed [F4] | 6 h per module shard | any proof without `status: PASSED`, `admitted: False` and zero `pending`, `failing`, `vacuous`, `stuck`, `bounded` [F8] |
| `sensitivity-weekly` | weekly | `forge test --mutate` per source file against the unit, fuzz and forge-run formal suites (T 5.6); plus `tools/formal/mutant-smoke.sh`: one hand-written mutant per V3 or V4 property in a scratch worktree, run under Halmos and Kontrol | sharded | a surviving mutant on a line inside the footprint of a V3 or V4 property (Not verified: whether `--mutate` can drive `--symbolic`; the hand-written mutants cover Halmos and Kontrol either way) |
| `equivalence` | PR labelled as a refactor, and before merging any row of section 6 | `hevm equivalence` per external selector against the last audited tag in a separate worktree, plus a forge log comparison | on demand | any difference |
| `release-gate` | before any deployment | masked byte diff between verify and deployment runtimes (A-BUILD); library runtime hashes (A-LIB); factory wiring checks (A-REG, card 03 W10; card 08 W8); status report archived with the release | 30 min | any mismatch |

### 7.2 Status and ratchet

`spec-status.py` writes `spec/status/<commit>.json` (CI artefact) from tool output only: per property the tier, engine, tool and solver versions, bounds, bytecode hash of every footprint file on the verify build, wall time and the vacuity evidence. A tier is valid only for the bytecode hashes it was obtained on; any footprint change invalidates it back to the best tier still valid. The committed `spec/status/ratchet.json` holds the last accepted tier per property and per `cover_`: CI fails when a PASS becomes anything else, when a REACHED `cover_` is no longer reached (either a fix that must flip its FLAGGED row, or a harness regression), or when a tier drops; a PR that improves a tier updates the ratchet; a downgrade needs a registry edit with a reason and coordinator approval (branch protection on `spec/registry/` and `spec/status/ratchet.json`).

### 7.3 Change protocol

1. The build compares runtime bytecode per contract with link slots and the CBOR tail masked and lists the changed contracts.
2. Affected properties are those whose footprint includes a changed file or whose harness deploys a changed contract (import graph of `test/formal/`); `formal-fast` runs them on the PR, the rest nightly.
3. A storage-layout change fails the slot-map gate first, so no proof injects into a stale slot; injection helpers touching moved fields are reviewed before any proof is trusted again.
4. A new or renamed external function fails `check_closure.py` until it has step checks for every V4 property whose variables it can write, or a writer-set proof that it writes none.
5. A PR claiming "no behaviour change" must pass `equivalence`; otherwise the affected properties are re-proven, and the `kontrol` job runs before tagging.
6. A change that touches a decision updates the registry row with the founder's sign-off; FLAGGED `cover_` rows flip to `check_` in the fix PR.
7. Tool upgrades (Foundry, Halmos, hevm, Kontrol image, solvers) land only in dedicated PRs that run the nightly and Kontrol jobs and diff the status. Halmos is stale (last release 2025-07-31, T 4.1): every portable check also runs under hevm and forge `--symbolic`, so dropping Halmos loses only the `hcheck_` nets.
8. External assumptions decay: fork suites are re-pinned quarterly and whenever monitoring sees a new Across, Aave, Wormhole or USDC implementation (A-ACROSS-GOV, AS4, A-WH2); every consumer of a re-pinned assumption is re-labelled from the new fork result.

## 8. Risks and how each is detected

### 8.1 Risk register

| Risk | How it shows | Detection | Mitigation |
|---|---|---|---|
| False confidence | "verified" read as "safe", or a bounded or conditional result read as a proof | labels are generated (rules 1.3); SYS rows capped by premises; the report template prints tier, bounds and assumptions next to every claim | only the registry and the status file may be quoted to the founder or an auditor; a proof is about the model and the verify build, not the deployment (study 13, `docs/estudos/13-testes-verificacao-processo.md:1090-1093` in the specification repository, per A) |
| Vacuous proof | PASS with no reachable success path, contradictory assumptions, or a reverting predicate or model | section 8.2 (all eight mechanisms) | a status needs its vacuity evidence; totality and satisfiability are proven, not hoped |
| Unsound pre-state assumption | a step proven under a WF conjunct some reachable state violates | 8.2 item V3: every WF is also a fuzz property | status revoked when a fuzzer breaks an assumed predicate |
| Over-constrained pre-state | a reachable state excluded by an extra assume hides a real bug | lint: every assume maps to a WF conjunct, a bound or an A-* id (3.7 rule 3); WF itself proven inductive | only registered assumptions; bounds printed in labels |
| Specification error | a predicate states something other than the decision, or something stronger | independent authorship from decision text (rule 3.3-1); coordinator adversarial review at every gate; the same predicate runs in the fuzzers, which fail fast on a too-strong statement; disagreement with the reference model; surviving mutants | FLAGGED instead of silently corrected; founder question when the decision is ambiguous |
| Model mismatch | a conforming model allows less than the real protocol | conformance tests per model (4.6); local real-V4 tier; fork suites | havoc models wherever the property allows; statuses depending on a non-conformant model capped at V2 |
| Assumption drift | an upgraded Across SpokePool, Aave Pool, Wormhole Core or USDC implementation | implementation-address monitoring; quarterly fork re-pin (7.3 item 8) | re-run the fork discharges; re-label consumers |
| Build mismatch or link drift | proofs about bytes production does not have | link-identity gate per PR; masked byte diff in `release-gate` (A-BUILD); library runtime hashes (A-LIB) | both gates block |
| Library etch artefact | the unpatched etched runtime accepts direct calls (section 4.5) | the patched-constant equality check of the link-identity gate | direct-call properties only on a CREATE-deployed library |
| Slot-map drift | injection into the wrong slot proves a property about garbage | generated maps diffed in CI; `SlotMap.t.sol` before every formal job | none needed beyond the gate |
| Engine or solver defect | PASS in one engine, FAIL or WARN in another | two engines per V2 and V3-bv result (8.2 item V8); V3-k on KEVM; every counterexample replayed in forge | disagreement is a failure until explained |
| Nondeterminism | a check flips between runs because a solver timeout fired | nightly history per check | `solver-timeout-branching 0` in PR and release runs (T 5.8); one retry, then TIMEOUT |
| Stale or preview tools | Halmos without a release since 2025-07-31; forge `--symbolic` a preview; Scribble dormant (T 4.1) | version pins and dedicated upgrade PRs | no status rests on one engine; Scribble optional |
| Kontrol capacity or class C failure | 16 GB needed, 8 GB locally; rounding lemmas do not close | P-10 go or no-go; first `prove_` of INV-CORE-12 on the Core Vault (20,034 B runtime plus 19,215 B library, T 2) | CI-only Kontrol from a pinned image; NO-GO path of section 1.2; stop rule 5.17 |
| Harness defects mistaken for findings | failures like the `ZeroSharePrice` replay of the old handler (T 2) | triage class "harness defect" before any finding is reported (5.18) | legal-revert tables and panic passthrough (4.2) |
| Scope creep | about 600 obligations never finish | weekly burn-down against section 9 | per-contract targets of 1.4 fixed with the founder; the credible-minimum cut |
| FLAGGED defect hidden by a friendly model | a conforming token or registry makes a known defect disappear | the defect's `cover_` must stay REACHED (ratchet, 7.2) | hostile modes mandatory in the covers (4.7) |

### 8.2 Vacuity and sensitivity detection (all eight are required for a V3 or V4 status)

- **V1 tool-native signals.** Halmos reports `[ERROR]` with `REVERT_ALL` ("all paths have been reverted") when every path reverts, and a `LOOP_BOUND` warning when paths were cut by the unrolling bound [F6]. hevm fails a test that has no counterexample but whose branches all reverted ("No reachable assertion violations, but all branches reverted"), and fails on errors, unknowns and partial explorations [F7]. `kontrol list` prints per proof `status`, `admitted`, `nodes`, `pending`, `failing`, `vacuous`, `stuck`, `terminal`, `refuted`, `bounded` [F8]. The status generator reads all of them; forge `--symbolic` has no documented equivalent (Not verified), so it never carries a status alone.
- **V2 reachability twins.** Every `check_` has `cover_` twins under the same assumptions, one per asserted outcome class (the success path, each allowed revert selector) and one per mode of the decomposition; each must produce a counterexample. `cover_WF_<MOD>_satisfiable` assumes WF and asserts false; it must fail.
- **V3 assumption soundness by execution.** Every assumed predicate (WF conjuncts, bundle members) is a `property_` of the stateful harness; a reachable violation revokes every status proven under it. A unit test shows a concrete reachable state (after the constructor and after a scripted sequence) satisfying each WF.
- **V4 sensitivity.** `forge test --mutate` weekly against unit, fuzz and forge-run formal suites; one hand-written mutant per V3 or V4 property run under Halmos and Kontrol (`tools/formal/mutant-smoke.sh`); a property whose checks survive a mutant of a line in its footprint is a specification gap or a vacuity signal, triaged before the next release.
- **V5 predicate totality.** `check_TOTAL_<predicate>` proves each predicate never reverts on any input (rule 3.3-2).
- **V6 model-switch coverage.** Every switch of every model is exercised with both values on a non-reverting path by a `cover_`, which catches the "try/catch branch never explored" trap (card 06 section 9.4).
- **V7 guard and transient discipline.** WF constrains the persistent guard slot to `!= 2` on symbolic-storage routes and never injects transient storage (4.3), so no proof passes because every guarded entry reverts.
- **V8 engine agreement.** V2 and V3-bv need Halmos plus hevm or forge `--symbolic`; any disagreement is a failure until explained.

## 9. Effort and schedule under the two-agent limit

Roles: Fable coordinates and reviews every gate (adversarial review of predicates against decision text, vacuity report, tier claims) and does not count as an executor. At most two executor lanes run at once: **lane A** (stronger model: WF design, harness architecture, models, Kontrol lemmas, CTI triage, composition) and **lane B** (smaller model: expansion across selectors and engines, `cover_` twins, CI wiring, first-level triage, and the reference model in a fresh session without `src/` in context). Figures are agent-days, estimates to be recalibrated at G1 (Not verified: no check of this plan has run yet; card 09's probe is the only measurement).

| Unit | V2 | V3, V4 | Lead |
|---|---|---|---|
| preparation and infrastructure: G0 and G1 items, registry extraction and review, vacuity machinery, CI, ratchet upkeep, sensitivity runs | 19 | | A 9, B 10 |
| reference model and in-harness mirror | 5 | | B (fresh session) |
| TM; RC; C3, CS, C3D; AG | 3.5 | 3.5 | B |
| MD | 3 | 5 (optional loop invariants, excluded from totals) | A |
| SM; IA | 4.5 | 10 | A (includes the go or no-go and the lemma file) |
| ST; MR, MFV, TE | 3 | 3.5 | B |
| VRR; CLPS; AB | 7 | 7 | A for VRR, B for CLPS and AB |
| AA | 5 | 5 | A (pool model) |
| V4A | 8 | 5 | A (`SymV4` and its conformance checker) |
| FF | 4 | 2.5 | B, A reviews |
| CVL and SCL in hosts, summary proofs | 5 | 3 | A designs, B expands |
| SV | 8 | 7 | A designs, B expands |
| CV family | 12 | 9 | A designs, B expands |
| composition (HubPairFormal, SYS files, two-chain harness) | 5 | | A |
| **Total** | **92** | **55.5** | **about 148 agent-days** |

Calendar: two lanes give at most 10 agent-days per week; with gate waits and review cycles about 8 are realistic, so the full plan takes **18 to 20 weeks**. A **credible minimum** (V2 on every contract, plus V3 and V4 on the custody core: ST, MR, MFV, TE, AG, TM, SM, IA, WF-CORE members INV-CORE-03, 05, 12, 32, 33, 40, 50, 55, and the Spoke Vault backing and access subset INV-SPOKE-01, 06, 07, 19, 20, 22, 42, 47; Kontrol ports of adapters, receiver, price source, bridge and factory deferred; SYS files deferred) is about **110 agent-days, 13 to 14 weeks**. This workstream competes with the fuzz and unit work items of the cards for the same two slots; with one slot the calendar doubles.

| Weeks | Lane A | Lane B | Gate at the end (coordinator) |
|---|---|---|---|
| 1 to 2 | registry extraction and review, assumption register, WF drafts (P-04, P-05, P-09); Kontrol go or no-go on the 16 GB runner (P-10); `FormalBase`, observers, `SymToken` | freeze and baselines, toolchain pins, verify profile, patched library constants, link-identity gate, slot maps, CI skeleton, vacuity machinery (P-01 to P-03, P-06 to P-08, P-11, P-17); reference model in a fresh session (P-12) | **G0**: lint green; go or no-go recorded; one Core Vault `deposit` check and one Spoke Vault check agree in three engines (Edit 2.2 row 27, as P-07 requires) and build under Kontrol; Kontrol capacity measured on the runner |
| 3 | F0: INV-SHARE-01 to V4-k with full vacuity evidence; ST, AG | L0a: TM, RC, C3, CS, C3D; FLAGGED pin inventory; new handler (P-13, P-14) | **G1**: effort recalibrated; two engines agree on L0a and L1 |
| 4 | MD specification and checks; lemma file | MR, MFV, TE; SM concrete-rate rows and covers | |
| 5 | SM and IA `prove_` | IA bounded checks; CLPS | |
| 6 | VRR with `rr_expected` and L-SHAPE | AB; Kontrol ports of L1 | **G2**: math tiers fixed; A-RECV discharged; A-PRICE recorded false |
| 7 to 8 | `AaveV3PoolModel`, conformance, AA bounded | VRR, CLPS, AB `prove_`; FF stub children | |
| 9 to 10 | `SymV4`, conformance checker, V4A bounded | FF bounded; AA exit matrix and covers | |
| 11 | V4A class C in Kontrol | AA `prove_` | **G3**: A-SPK-1 discharged or its false parts registered |
| 12 to 13 | `CoreLogicHost`: transit books, hub-bound, income, fee split, `recordValuation` summary proof | `SpokeLibHost`; V4A remaining rows | **G4**: every summary contract proven |
| 14 to 15 | WF-SPOKE, combined steps, models | SV expansion, role gates, `hcheck_` nets | mid-check: SV combined steps close; if not, split per conjunct and re-estimate CV |
| 16 to 18 | WF-CORE, call-site arithmetic, delta lemmas, exit matrix | CV expansion, FLAGGED covers | **G5**: bundles closed per `check_closure.py` |
| 19 to 20 | HubPairFormal, SYS composition files, vault `prove_`, CTI triage | ratchet, sensitivity runs, release-gate dry run, CI hardening | **G6**: SYS rows at C or with FLAGGED premises named |

Go or no-go points: G0 (Kontrol on class C: NO-GO moves every class C target to V2 per configuration plus V1 differential and removes about 20 agent-days, so the full plan drops to about 128); G1 (engine agreement on the cheapest code: if not, fix conventions before L2); weeks 14 to 15 mid-check (Spoke Vault steps).

## 10. Open decisions

### 10.1 For the founder (each changes a tier or the calendar, not the method)

| # | Decision | Research recommendation (the founder decides) | Blocks |
|---|---|---|---|
| 1 | Accept the tier vocabulary and the per-contract targets and headlines of section 1.4 as the meaning of "formal verification on all contracts" | accept; no stronger honest claim exists for protocol adapters and valuation loops | the wording of every report |
| 2 | Full plan (about 148 agent-days, 18 to 20 weeks) or credible minimum (about 110, 13 to 14 weeks), and the share of the two executor slots between this workstream and the cards' fuzz and unit items | credible minimum first, full plan after the audit feedback | the calendar of section 9 |
| 3 | The refactor batch of section 6 before the audit freeze, or none | R-C1, R-B1 and R-B2, R-R1 in one batch; R-M2 only on Kontrol NO-GO; the rest optional | the labels noted in section 6 |
| 4 | Rulings on the FLAGGED list: CF-1, CF-2, CF-3, CF-5, CF-7, CF-9, CF-11 (card 01 section 10.2); SF-1, SF-2 (card 03); CF-R2, CF-R3 (card 04); F1, F2 (card 06); CF-V4-1, CF-V4-2 (card 05); FF-1, FF-2, FF-6 (card 08); MM-1, MM-3, MM-5 (card 09); AB-1, AB-2 (card 07); T1, T2, T5 (card 02) | the cards give a reading per item; until a ruling each stays pinned FLAGGED and the rows of section 6 "behaviour changes" wait | SYS-2, SYS-4, SYS-6 closure |
| 5 | SYS-7b: accept the manager-chosen swap minimum (the DEC-030 reading of card 02) or add a Mandate slippage bound | record the acceptance in a decision so the ACCEPTED label cites it | SYS-7b label |
| 6 | Is `ZeroSharePrice` from `requestPayout` a legal revert while Share Assets are truly 0 (card 01 Q9)? | yes | the legal-revert tables of P-14 |
| 7 | `spec/` in the contracts repository, with the coordinator approving registry and ratchet changes and the founder signing any row that changes a decision's reading | yes: CI needs the registry next to the code | P-03, P-04 |
| 8 | Add `a16z/halmos-cheatcodes` and the Kontrol cheatcode interface as test-only submodules (changes `.gitmodules`) | yes; they never enter `src/` | `hcheck_` and `prove_` files |
| 9 | Keep the contracts repository public (free `ubuntu-latest` has 16 GB RAM and 14 GB disk) or pay for a larger runner (a private repository gets 8 GB, T 9); Kontrol's authors recommend 16 GB RAM plus 16 GB swap (T 5.12) and its real peak memory, disk and time are measured in B02 Step 0 (Edit 2.2 row 22) | keep public or budget a larger runner when the measurement exceeds the trigger (14 GB RSS, 12 GB disk, or a proof that misses the 6 h cap) | every V3-k and V4-k label; on "Kontrol cannot run", gate G1 closes on INV-SHARE-01 at V3-bv and every k-label is deferred, it does not block the plan |

### 10.2 For the coordinator

1. Confirm the layout and prefixes of sections 3.1 and 3.4 (`test/formal`, `test/fuzz`, `test/harness`, `test/spec`, `spec/`) and rename the cards' work items, which use `test/symbolic`, `test/invariant`, `test/echidna`, `test/medusa`.
2. Confirm lane assignment and the rule that the reference model is written in a fresh session whose context excludes `src/`.
3. Fix lemma and assumption ownership in the registry: INV-CORE-50 carries INV-SHARE-29; card 07 is the single list of A-ACROSS-*; card 04 answers A-RECV (holds) and A-PRICE (false); the spoke card cites the adapter ids for A-SPK-1 with the F1, F6 and CF-V4-1 exceptions.
4. Decide that forge `--symbolic` counts as the second engine for V2 only after it has agreed with Halmos on the F0 set (recommended: from G1).

## Appendix A. Provenance of the ideas, and what was discarded

From design A (the backbone): the V0 to V4 scope ladder with machine-checked closure (`check_closure.py`); proof classes A, B, C derived from card 09's probe; the portability rule (`check_` portable, `hcheck_` Halmos-only, `prove_` Kontrol-only); `cover_` twins per outcome and the WF satisfiability cover; the `// ASSUME:` lint; generated slot maps; the single etch route and the link-identity gate; the havoc and conforming model split with the assume-guarantee soundness condition; hostile token modes; transient storage never injected and the guard-slot constraint; hyperproperties by twins; recording models; the WF table and CTI handling; the five decomposition cuts with `modesExhaustive`; the loop-bound table; the quotient-witness form; concrete-rate rows and the fund certificate; the non-termination ladder with a stop rule; counterexample triage classes; per-contract obligation tables with difficulty and fallback; the ratchet on REACHED covers; the per-unit effort and the credible minimum; the go or no-go points.

From design B: the registry fields `form`, `bundle`, `runners`, `footprint`; total scalar predicates with `check_TOTAL_`; the multiplicative rounding and defensive-quantifier principles; the expected-outcome form; SYS-1 to SYS-7b with composition files and tier C, including the SYS-7 split; the metadata-tail argument that bans annotations in `src/`; library modes M2 (host), M3 (summary with an over-approximation obligation) and M4 (confinement); HubPairFormal; the V2 cap for conforming models without conformance tests; the CI cap of a consumer's status by its dischargers; tool-native vacuity signals; assumption soundness by fuzzing; `forge test --mutate` against the formal suite; model-switch coverage; statuses keyed by bytecode hash; `spec-impact.py`; `test/regression/`; the independent reference model; lemmas L7 to L10; the exit matrix as an expected-outcome function; Scribble as a generated consumer; the FV-complete definition; A-BUILD in the release gate.

New in this merge: the measured library call-protection placeholder and the patched etch (section 4.5; A left the prologue Not verified, B did not raise it); the guard-slot constant and `ENTERED = 2` read in the OZ source; the labelling rule for a V4 closure with bounded steps (rule 1.3-3); tool-native vacuity signals re-read at the pinned commits ([F5] to [F8]); the loop-free Spoke Vault writer list corrected to card 02's (`sendToHub` is not among the 13); the effort reconciled at about 148 agent-days.

Discarded, with the reason:
- B's 85 agent-day estimate: no obligation count behind it and a larger scope than A's 136; replaced by section 9.
- B's T0 to T4 names: B's T3 has no machine-checked closure and T4 mixes scope with engine; replaced by V0 to V4 with `-bv` and `-k`.
- B's `check_COVER_` prefix: it matches the `^check_` filters, so covers would run inside proof jobs and their required counterexamples would read as failures; A's `cover_` prefix runs in its own job.
- B's `spec/props/` location for Solidity predicates: every Foundry-based runner compiles `test/` without extra configuration; `spec/` keeps only non-Solidity artefacts.
- B's `SymPriceSource` bounded to `[1, 2^128]`: an under-approximation of an assumption known to be false (CF-R2) would hide it from Core Vault safety checks; the havoc model is kept.
- A's committed full status file: replaced by per-commit CI artefacts keyed by bytecode hash plus a committed ratchet, so a code change can never leave a stale PASS.
- Manticore in any role (archived, no PUSH0, MCOPY or TLOAD, T 1 item 4), and Mythril on any runtime that contains MCOPY or on CoreVault (which delegates to a library that does): SKIP. **Reversed by the completeness review (master plan 2.1 row 5):** the earlier line discarded Mythril everywhere, including the cards' 30-minute runs, on the ground that "no property can be expressed". That ground is not a reason to skip a bounded second opinion, and the MCOPY ground is false for ManagerFeeVault, ManagerRegistry, TransitEscrow and ChainlinkPriceSource (0 MCOPY in the `e5c778a` runtimes), so those four and their Scribble copies get the bounded run, with no registry property and no tier.
- Porting the existing unit tests into the formal suite: 445 `expectRevert` sites are unsupported by Halmos (T 1 item 3).
- The existing spike Python models as an oracle: they encode superseded rules (B section 9.1).

## Appendix B. Sources (read 2026-09-30)

- Contracts repository `PoolPartyLabs/smartcontract-v2` at `e5c778a`, read-only clone: every `file:line` above. Lines re-read for this document: CVB:56, 60, 77, 119-121, 174-178, 283-285, 302-304; CV:221-226; CVL:34, 67-417 function heads, 89, 95-102, 587-590; CVT:43-47, 110-124; CVI:28-34; SV:93, 188-195, 988-998; SCL:25, 38, 215-223; IA:25, 183, 192-199; SM:70-74; FF:115, 154-157; VRR:157, 187; AB:104-107; `foundry.toml:7-11`; `lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol:36-37, 50-51` and `ReentrancyGuardTransient.sol:21-22`. Measurement: `out/CoreVaultLogic.sol/CoreVaultLogic.json` and `out/SpokeCrossChainLib.sol/SpokeCrossChainLib.json` (runtime head `0x73` + 20 zero bytes + `0x30 0x14`; the same pattern inside each creation code).
- This plan: `01-TOOLING.md` (cited "T" with its section; its sources [S1] to [S17]), `modules/01` to `modules/09`, `_drafts/fv-design-a-bottom-up.md`, `_drafts/fv-design-b-spec-first.md`.
- Specification repository: `docs/estudos/13-testes-verificacao-processo.md` (cited through design A).
- [F1] Kontrol cheatsheet, https://docs.runtimeverification.com/kontrol/cheatsheets/kontrol-cheatsheet (flags `--bmc-depth`, `--smt-timeout`, `--smt-retry-limit`, `--use-booster`, `--workers`, `--no-break-on-calls`; read 2026-09-30 by design A, not re-read here).
- [F2] Kontrol guide "advancing proofs", https://docs.runtimeverification.com/kontrol/guides/advancing-proofs (lemmas as K `simplification` rules, `--require`, `--module-import`, `--rekompile`; read 2026-09-30 by design A, not re-read here).
- [F3] pyk reachability proof summary, https://github.com/runtimeverification/k/blob/4a46d12/pyk/src/pyk/proof/reachability.py lines 560-572 (read 2026-09-30 by design A; corroborates [F8]).
- [F4] Kontrol proof invalidation by contract digest, https://github.com/runtimeverification/kontrol/blob/75bb958/src/kontrol/foundry.py lines 1015-1031 (read 2026-09-30 by designs A and B, not re-read here).
- [F5] halmos-cheatcodes `src/SVM.sol`, https://github.com/a16z/halmos-cheatcodes/blob/main/src/SVM.sol (re-read 2026-09-30: `createCalldata` overloads, `enableSymbolicStorage(address)`, `snapshotStorage(address)`).
- [F6] Halmos `src/halmos/__main__.py` at commit 079bb42, https://github.com/a16z/halmos/blob/079bb42/src/halmos/__main__.py (re-read 2026-09-30: `[ERROR]` with `REVERT_ALL`, "all paths have been reverted"; `LOOP_BOUND` warning, "paths have not been fully explored due to the loop unrolling bound").
- [F7] hevm `src/EVM/UnitTest.hs` at commit c39757a, https://github.com/argotorg/hevm/blob/c39757a/src/EVM/UnitTest.hs (re-read 2026-09-30: "No reachable assertion violations, but all branches reverted"; errors, unknowns and partial paths fail).
- [F8] Kontrol `src/tests/unit/test-data/foundry-list/foundry-list.expected` at commit 75bb958, https://github.com/runtimeverification/kontrol/blob/75bb958/src/tests/unit/test-data/foundry-list/foundry-list.expected (re-read 2026-09-30: fields `status`, `admitted`, `nodes`, `pending`, `failing`, `vacuous`, `stuck`, `terminal`, `refuted`, `bounded`).
- [F9] Solidity 0.8.28 documentation, "Contract Metadata", https://docs.soliditylang.org/en/v0.8.28/metadata.html (re-read 2026-09-30: "a single whitespace change results in different metadata, and different bytecode"; the metadata hash is appended CBOR-encoded).
- Not re-read: EIP-1153 (https://eips.ethereum.org/EIPS/eip-1153) for "transient storage is zero at the start of every transaction" (section 4.3); Not verified today, confirm there. The Solidity page on library call protection could not be retrieved (the fetch returned no such section); the placeholder behaviour of section 4.5 rests on the measured bytes only.
