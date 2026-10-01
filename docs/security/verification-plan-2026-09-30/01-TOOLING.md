# 01 - Tooling: research, repository fit and ready-to-copy configuration

Read date: 2026-09-30. Subject: the 13 tools in the founder's list, applied to `PoolPartyLabs/smartcontract-v2` at commit `e5c778a` (public repository, default branch `main`). Code references are `file:line` in that commit. Tool claims cite a source key `[Sn]` from section 12 (all read 2026-09-30; repositories read at the commit shown there). `Not verified:` marks anything not confirmed, with what would confirm it. Nothing was installed globally. The only tool executed was Foundry 1.0.0, already on the coordinator machine (measurements in section 2). Versions, digests, action SHAs and flag names below were read from the sources on 2026-09-30; where a name could not be read from a source it is marked Not verified.

## 1. Decisions this document forces

1. **Pin Foundry to v1.8.3 (2026-09-15) in CI and on every dev machine.** CI installs `version: stable` (`.github/workflows/test.yml:22`), the README says forge 1.7+ (`README.md:53`), the coordinator machine has 1.0.0. The only CI run so far (run 36713951710, `main`, 2026-09-30 12:19 UTC) failed at `forge fmt --check` on `test/mocks/across/AcrossFillSimulator.sol` and `test/fork/across/AcrossFill.fork.t.sol`, so Build, Unit tests and Fork tests never ran [S17]. Formatter output changes between Foundry versions, so the skew is the first suspect (Not verified: run `forge fmt` with v1.8.3 and compare). Foundry v1.8.0 also made `--isolate` and dynamic test linking the defaults, which can change gas snapshots, traces and CREATE-derived addresses [S8].
2. **Foundry 1.8 ships four capabilities that overlap other tools in the founder's list (Halmos, Slither and Aderyn, Solhint, mutation testing):** native symbolic testing (`forge test --symbolic`, preview), mutation testing (`forge test --mutate`), assembly hardening (`forge test --brutalize`) and a security linter (`forge lint`) [S8]. They are the first line, third-party tools are the second opinion.
3. **Formal verification is not one thing here.** Halmos is stale (last release 2025-07-31), hevm and Kontrol are active, Foundry symbolic is a preview. hevm refuses unlinked bytecode, Kontrol needs 16 GB RAM, Halmos cannot run the 445 existing `vm.expectRevert` call sites. Consequence: a separate `test/formal/` suite with one naming scheme (`check_*`), no `expectRevert`, libraries pre-linked in a `verify` profile (section 8.1). Never port the existing unit tests.
4. **Manticore: SKIP. Mythril: SKIP on every runtime that contains MCOPY, RUN (bounded) on the four that do not.** Manticore is archived (2026-06-24) and has no PUSH0, MCOPY or TLOAD in its source. Mythril has no MCOPY in its opcode table and no release since 2024-03-27, so it would mis-execute or reject the runtimes that contain MCOPY (ShareToken 1, Create3Deployer 1, AcrossBridgeAdapter 1, AaveV3Adapter 1, FundFactory 2, ValueReportReceiver 2, SpokeVault 2, UniswapV4Adapter 3, and the two libraries CoreVaultLogic 3 and SpokeCrossChainLib 4, which CoreVault, which has none of its own, and SpokeVault run by DELEGATECALL). An opcode scan of `out/` at `e5c778a` (PUSH data skipped, CBOR tail stripped; coordinator, 2026-09-30) finds 0 MCOPY in ManagerFeeVault (1,024 B), ManagerRegistry (1,477 B), TransitEscrow (841 B) and ChainlinkPriceSource (1,367 B), and section 5.9 says Mythril implements PUSH0, TLOAD and TSTORE, so a bounded run is possible there (master plan 2.1 row 5; an earlier version of this item said SKIP everywhere, which was wrong for these four).
5. **Code size is a constraint on every instrumenting tool.** `SpokeVault` runtime is 23,644 bytes, 932 bytes under the 24,576 limit (measured from `out/` artifacts). Scribble, coverage builds and some fuzz builds add bytes, so each needs the limit lifted (`code_size_limit` for forge, `codeSize` for Echidna, `codeSizeCheckDisabled` for Medusa, defaults already lifted in both).
6. **`forge coverage` needs `--ir-minimum`** (default coverage build fails with "Stack too deep", measured). Baseline with it: lines 97.3 %, branches 83.7 %, functions 98.9 % on `src/` (section 2). Branch coverage, not line coverage, is the number to drive.
7. **Fuzz and formal harnesses live outside the audited `src/` and outside `test/unit/`:** `test/fuzz/` (Medusa, Echidna, `property_` prefix) and `test/formal/` (`check_` prefix). crytic-compile skips `test/**` and `script/**` unless told otherwise, so Medusa and Echidna configs pass `--foundry-compile-all` (sections 8.6 and 8.7).

## 2. Measured baseline on the coordinator machine (macOS arm64, 8 CPUs, 8 GB, Foundry 1.0.0 except the coverage row, see its note)

| Measurement | Command | Result |
|---|---|---|
| Source size | `wc -l src/**/*.sol` | 45 files, 9,044 lines |
| Unit, fuzz, invariant, default profile | `forge test --no-match-path "test/fork/**"` | 654 tests passed, 0 failed, 53 suites, 4.6 s wall, 22 s user, max RSS 158 MB |
| Same, `FOUNDRY_PROFILE=ci` (fuzz 2000, invariant 512 x 48) | same | 15.3 s wall, max RSS 155 MB. First run 652 passed, 2 failed. Second run (persisted failures replayed) 3 invariants of `CoreVaultInvariantTest` failed (intermittent: the sibling document `02-BASELINE.md`, run 2, same profile and Foundry version, got 654 of 654, so the outcome depends on the fuzz seed): `invariant_DEC072_payoutReserveWithinIdle`, `invariant_DEC080_balanceCoversLedger`, `invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated` |
| Cause of those failures | `-vvv` replay of the persisted sequences of `invariant_DEC080_balanceCoversLedger` and `invariant_DEC107_...` (the `DEC072` failure was seen in the first run and not replayed with traces) | deposit, allocate, `movePrice(0)`, then `requestPayout` reverts `ZeroSharePrice()` (`src/libraries/ShareMath.sol:72,89`) because the handler calls `vault.requestPayout` without `try/catch` (`test/unit/core/CoreVaultInvariant.t.sol:61`) and `fail_on_revert = true`. Classification: harness defect candidate, contract behaves as written. Not verified: needs the owner of DEC-035 / the share-price-zero rule to confirm. The default profile (256 x 32) does not reach it |
| Coverage baseline | `forge coverage --ir-minimum --no-match-path "test/fork/**" --report lcov` | 70 s wall, max RSS 1.0 GB (Not verified: which forge version this timing came from, because the machine's `forge` switched from 1.0.0 to 1.8.3 at 14:06 while the baselines were being measured, `02-BASELINE.md` section 0; `02-BASELINE.md` measured 2 min 2 s with 1.0.0 and 5 min 47 s with 1.8.3 on a busy machine). `02-BASELINE.md` 3.2 and 3.3 measured both versions and shows the branch counts differ by version: **forge 1.8.3 gives `src/` lines 2,319 of 2,383 (97.3 %), branches 415 of 496 (83.7 %), functions 359 of 363 (98.9 %); forge 1.0.0 gives lines 2,313 of 2,378, branches 346 of 414 (83.6 %), functions 357 of 361.** The figures quoted in this row and used by the plan (2,319, 415 of 496, 359) are the forge 1.8.3 ones, and `02-BASELINE.md` states that its primary figures are 1.8.3 (an earlier label here said 1.0.0, which was wrong, and the "414 and 346" of B are the 1.0.0 counts). `--ir-minimum` degrades source maps, so treat branch numbers as approximate. Counts sum LCOV `BRF`/`BRH` per `src/` file |
| Coverage without `--ir-minimum` | `forge coverage` | fails: "Stack too deep" from `libyul/backends/evm/AsmCodeGen.cpp:68` (optimizer and via-IR are disabled for coverage) |
| CI, one run | GitHub Actions run 36713951710 [S17] | recursive submodule checkout 70 s, toolchain install 4 s, `forge fmt --check` failed after about 1 s, job total about 1 min 19 s |

Lowest branch coverage per file (unit tests only): `ManagerFeeVault` 33.3 % (1/3), `ChainlinkPriceSource` 46.2 % (6/13), `Create3` 60 % (3/5), `CoreVaultIncome` 62.5 % (5/8), `CoreVaultTransit` 63.6 % (7/11), `CodeStore` 66.7 % (2/3), `SpokeVault` 76.3 % (71/93), `FundFactory` 78.9 % (30/38), `AaveV3Adapter` 79.1 % (34/43). `IncomeAccumulator`, `Mandate` (97.4 %), `ShareToken`, `ManagerRegistry`, `AdapterGuard`, `TransitEscrow`, `ReportCodec`, `ShareMath` are at or near 100 % branches.

Runtime sizes from `out/` (bytes, runtime): `SpokeVault` 23,644; `CoreVault` 20,034; `CoreVaultLogic` 19,215; `UniswapV4Adapter` 17,854; `FundFactory` 16,084; `SpokeCrossChainLib` 10,545; `AaveV3Adapter` 10,133; `ValueReportReceiver` 7,846. Limit is 24,576.

## 3. What this repository demands from any tool

| Trait | Evidence | Consequence for tools |
|---|---|---|
| Solidity exactly 0.8.28, EVM cancun, optimizer 800 runs, `via_ir = false` | `foundry.toml:7-11`; 45 files `pragma solidity 0.8.28;` | Tool must accept 0.8.28 AST and Cancun opcodes. `via_ir=false` helps coverage and Kontrol, hurts nothing |
| Transient storage | `src/core/CoreVaultBase.sol:60` (`bool internal transient _unwinding`), `:22` (`ReentrancyGuardTransient`), `src/factory/FundFactory.sol:31` | Tool must parse the `transient` keyword and execute TLOAD/TSTORE |
| MCOPY | `src/spoke/SpokeCrossChainLib.sol:204`, `src/factory/CodeStore.sol:37`; solc emits MCOPY for memory copies under cancun | Tool must execute opcode 0x5E. Removes Manticore, and Mythril on every runtime that contains MCOPY; the ManagerFeeVault, ManagerRegistry, TransitEscrow and ChainlinkPriceSource runtimes contain none (scan in decision 4) |
| Two linked external libraries called by DELEGATECALL | `library CoreVaultLogic` (`src/core/CoreVaultLogic.sol:34`, public functions with `storage` parameters, e.g. `:67`); `library SpokeCrossChainLib` (`src/spoke/SpokeCrossChainLib.sol:25`, `:121`); `out/CoreVault.sol/CoreVault.json` and `out/SpokeVault.sol/SpokeVault.json` list the library in `linkReferences` of both creation and runtime bytecode (`FundFactory` has none) | Symbolic and fuzz tools must link or resolve them. hevm errors on unlinked code. No `delegatecall` token exists in `src/` (0 hits), so the Slither delegatecall detectors have nothing to find |
| Inline assembly | 13 blocks, all `assembly ("memory-safe")`: `CoreVaultLogic.sol:628`, `SpokeVault.sol:423,743`, `SpokeCrossChainLib.sol:188,201,343`, `Create3.sol:44,50`, `FundFactory.sol:424,492`, `CodeStore.sol:36,44,65` | `forge test --brutalize` tests the memory-safe claim. Slither `assembly` (informational) and Wake `invalid_memory_safe_assembly` are relevant |
| Low-level calls | `CoreVaultLogic.sol:626`, `SpokeCrossChainLib.sol:341`, `Create3.sol:48` (3 sites) | Triage each site in `spec/baseline/static/slither-triage.md` and `slither.db.json` instead of excluding the detector; an in-source `slither-disable-next-line` edits `src/` and is allowed only with the founder (master plan 2.2 row 21). Solhint's `avoid-low-level-calls` is set to `off` for the same reason (section 8.4) |
| No `require`, custom errors only | 0 `require(`, 205 `error X` declarations, 285 `revert X` | Solhint `gas-custom-errors` at `error`; `--symbolic` and Halmos treat revert paths as terminating |
| Reentrancy guards | 48 `nonReentrant` uses in 11 files | Slither reentrancy detectors may fire on guarded paths. Not verified: whether Slither 0.11.6 honours OZ `nonReentrant`; confirm on the first run |
| `block.timestamp` everywhere | 35 uses in 10 files | Slither `timestamp` is expected noise (Low). Fuzzers need `blockTimestampDelayMax` bounded so warps stay meaningful |
| Existing test cheatcode profile | 445 `expectRevert`, 331 `prank`, 61 `expectEmit`, 14 `recordLogs`, 17 `createSelectFork`, 21 `envString` | Existing unit tests are not portable to Halmos, Medusa, Echidna or Kontrol without rewrites. New harnesses avoid `expectRevert`, `expectEmit`, `recordLogs` |
| Fork tests need archive state | `docs/REVIEW-LOG-2026-09-29.md:20` (pinned blocks no longer served by public non-archive RPCs); `.env.example` | CI fork job needs an archive RPC secret and re-pinned blocks. Only forge, hevm, Echidna and Medusa can fork |
| Size margin | SpokeVault runtime 23,644 of 24,576 bytes | Instrumented builds lift the limit; never ship an instrumented build |
| Nested submodules | `.gitmodules`; CI checkout took 70 s [S17] | Cache submodules or use shallow recursive init; every tool job repeats it |

## 4. Tool matrix

### 4.1 Version, maintenance, licence (facts read 2026-09-30)

| Tool | Latest release (date) | Last commit on default branch | Status 2026 | Licence | Source |
|---|---|---|---|---|---|
| Slither | 0.11.6 (2026-07-28) | 2026-08-06 | Active | AGPL-3.0 | [S1] |
| Aderyn | v0.6.8 (2026-01-22) | 2026-05-03 (weekly dependency bump; repo pushed 2026-09-27) | Maintained, slower cadence | GPL-3.0 | [S4] |
| Solhint | v6.2.4 (2026-08-13) | 2026-09-30 | Active | MIT | [S5] |
| Wake | 4.22.1 (2026-03-02); 5.0.0rc2 pre-release (2026-04-12) | 2026-04-13 | Slow; newest solc support lags (open issue asks for 0.8.35) | ISC | [S6] |
| Echidna | v2.3.3 (2026-07-27) | 2026-09-29 | Active | AGPL-3.0 | [S7] |
| Foundry | v1.8.3 (2026-09-15); nightlies daily | 2026-09-30 | Active | Apache-2.0 | [S8] |
| Medusa | v1.5.1 (2026-03-11) | 2026-09-09 (CI and lint modernisation) | Active, slower | AGPL-3.0 | [S9] |
| Halmos | v0.3.3 (2025-07-31) | 2025-08-06; open PRs #588 to #591 (updated 2026-09-01) and open issue #583 (BLOBBASEFEE, BLOBHASH, CLZ opcodes) | Stale | AGPL-3.0 | [S10] |
| Mythril | v0.24.8 (2024-03-27) | 2025-01-31 (dependency bump) | Unmaintained | MIT | [S11] |
| Manticore | 0.3.7 (2022-02-17) | 2026-06-24 (commit marking the project archived) | Archived | AGPL-3.0 | [S12] |
| hevm | 0.58.0 (2026-06-26) | 2026-09-25 | Active | AGPL-3.0 | [S13] |
| Kontrol | v1.0.255 (2026-06-24) | 2026-09-28 | Active | BSD-3-Clause | [S14] |
| Scribble | v0.7.10 (2025-04-09) | 2025-04-29 | Dormant | Apache-2.0 | [S15] |

### 4.2 Fit with this repository

| Tool | Solc 0.8.28 | Cancun: `transient`, TLOAD/TSTORE, MCOPY | Linked libraries (DELEGATECALL) | Cheatcodes | Fork RPC | macOS arm64 |
|---|---|---|---|---|---|---|
| Slither | AST via crytic-compile | yes: transient layouts `slither/core/compilation_unit.py:76,334`, Yul TLOAD/MCOPY `slither/solc_parsing/yul/evm_functions.py:49,69` | static, n/a | n/a | n/a | pip, uv, brew |
| Aderyn | solc via solidity-ast-rs tag v0.0.1-alpha.beta.7; EVM version and via-IR read from config `aderyn_driver/src/compile.rs:83` | `StorageLocation::Transient` `aderyn_core/src/ast/ast_nodes.rs:827` | static, n/a | n/a | n/a | release asset `aderyn-aarch64-apple-darwin.tar.xz`, npm, brew |
| Solhint | parser `@solidity-parser/parser ^0.20.2` | transient parsing since parser 0.19.0 [S5] | static, n/a | n/a | n/a | npm |
| Wake | up to 0.8.34 (changelog 4.22.1) | `EvmVersionEnum.CANCUN` `wake/core/enums.py:16`, `TRANSIENT` `wake/ir/enums.py:244` | static, n/a | Python testing framework, not Foundry | anvil fork | needs Rosetta on Apple Silicon (README) |
| Echidna | via crytic-compile and hevm 0.58.0 | hevm supports MCOPY, TSTORE, TLOAD since 0.54.0 (CHANGELOG); test `tests/solidity/tstore/tstore.sol` | `solcLibs`, autolink via `crytic-export` (`lib/Echidna/Solidity.hs:87,136-144`, `lib/Echidna/Libraries.hs`); the README known-issues table lists limited library support for testing as wont fix (#651) | hevm set: prank, startPrank, stopPrank, deal, store, load, warp, roll, assume, sign, addr, ffi, createFork, selectFork, activeFork, label, setEnv, etch, expectRevert family (0.58); no expectEmit, mockCall, recordLogs | yes (`rpcUrl`, `rpcBlock`) | release `echidna-2.3.3-aarch64-macos.tar.gz`, brew |
| Foundry | native | native | linked automatically for tests (the 654 passing unit tests deploy `CoreVault` and `SpokeVault` with their libraries; `dynamic_test_linking` is default since v1.8.0) | full | yes | native |
| Medusa | via crytic-compile; go-ethereum with Shanghai, Cancun, Prague times set `chain/test_chain.go:153-161` | yes (Cancun active) | automatic, dependency graph `fuzzing/fuzzer.go:497-534`; `predeployedContracts` also available | warp, roll, fee, difficulty, prevrandao, chainId, coinbase, load, store, prank, startPrank, stopPrank, prankHere, deal, etch, label, getNonce, setNonce, addr, sign, snapshot, getCode, ffi, parse*, toString; no expectRevert | yes (`forkModeEnabled`, `rpcBlock` integer only) | release `medusa-mac-arm64.tar.gz`, brew, go install |
| Halmos | via forge artifacts | `OP_MCOPY`, `OP_TLOAD`, `OP_TSTORE` `src/halmos/sevm.py:3543,3557,3561`; BLOBHASH, BLOBBASEFEE, CLZ missing (#583), the repo uses none | `import_libs` `src/halmos/build.py:167`, `resolve_libs` `src/halmos/__main__.py:298` | warp, roll, fee, chainId, coinbase, difficulty, store, load, etch, deal, prank, startPrank, stopPrank, assume, ffi, getCode, addr, sign, label, `svm.create*`; `expectRevert` is "Unsupported cheat code" (`src/halmos/cheatcodes.py:1542`) | no (FAQ) | pip and uv; CI matrix includes macos-latest |
| Mythril | solc compile of the file | TLOAD, TSTORE, PUSH0 present; MCOPY absent (0 hits in repo at 125914a) | Not verified | n/a | `myth analyze -a` on-chain bytecode | pip (Python 3.7 to 3.10 per PyPI page) |
| Manticore | old solc only | none of PUSH0, MCOPY, TLOAD (0 hits in `manticore/`) | n/a | n/a | n/a | archived |
| hevm | reads `forge build --ast` output | MCOPY, TSTORE, TLOAD since 0.54.0; CLZ in 0.58.0 | unlinked bytecode is an error (`UnlinkedLibrary`, `src/EVM/Solidity.hs:437,725`), so link at fixed addresses first | prank, startPrank, stopPrank, deal, store, load, warp, roll, assume, sign, addr, ffi, createFork, selectFork, activeFork, label, setEnv, etch, expectRevert family, assert* family; no expectEmit, mockCall | yes (`--rpc`, `--number`, `--cache-dir`) | release `hevm-arm64-macos` (101 MB), needs z3, cvc5 or bitwuzla |
| Kontrol | KEVM v1.0.921 pinned in `deps/kevm_release`; kevm-pyk default schedule CANCUN | KEVM has CANCUN schedule and mcopy, tstore summaries | automatic (docs "linked-library-example") | broad: expectRevert, expectEmit, mockCall, prank, deal, etch, store, load, freshUInt, symbolicStorage; no fork, file or FFI | no (`kontrol load-state` from state dumps) | kup or Docker `runtimeverificationinc/kontrol`; 16 GB RAM recommended. Not verified: Apple Silicon support (docs silent) |
| Scribble | solc-typed-ast ^18.2.5 lists compilers up to 0.8.28 (`git show v18.2.5:src/compile/constants.ts`) | writer emits `transient` (`src/ast/writing/ast_mapping.ts:856` at v18.2.5); MCOPY only appears in assembly, untouched | n/a | n/a | n/a | npm `eth-scribble` (Node) |

Size, runtime and CI figures per tool are in section 5. Foundry-specific new capabilities are in section 5.6.

## 5. Tool cards

Each card answers: what it checks here, install, how it consumes this Foundry project, limits, runtime and memory, output and CI gate, false positives and triage, overlap. Runtime and memory are measured only for Foundry; for every other tool they are planning budgets (`timeout-minutes` caps), marked "Not verified: measure in Step 0".

### 5.1 Slither (static analysis, Trail of Bits) [S1] [S2] [S3]
- **Checks:** about 100 detectors (High to Optimization) plus printers (`human-summary`, `contract-summary`, `entry-points`, `vars-and-auth`, `call-graph`) and utilities (`slither-check-erc`, `slither-read-storage`, `slither-interface`, `slither-flat`, `slither-mutate`). `slither-check-upgradeability` is irrelevant: no proxy, no upgrade path (`src/core/CoreVault.sol:20`, DEC-022, DEC-058).
- **Install:** `uv tool install slither-analyzer==0.11.6` (README recommends uv; Python 3.10+), `brew install slither-analyzer`, Docker `trailofbits/eth-security-toolbox`. GitHub Action `crytic/slither-action` v0.4.2 installs its own Foundry stable inside a Docker image (`entrypoint.sh:152-167`), so it would bypass our Foundry pin: run Slither directly instead.
- **Foundry consumption:** crytic-compile runs `forge build --build-info --skip ./test/** ./script/** --force` (adds `--deny never` for forge 1.4 and later) with `FOUNDRY_DYNAMIC_TEST_LINKING=false`, then reads `out/build-info` (`crytic_compile/platform/foundry.py`). So: tests and scripts are excluded by construction, remappings come from `forge config`, and every run is a full rebuild. Isolate with `FOUNDRY_OUT=out-slither FOUNDRY_CACHE_PATH=cache-slither` so the dev `out/` is not overwritten (Not verified: env names follow Foundry's `FOUNDRY_<KEY>` convention, confirm in Step 0).
- **Limits:** already used on module branches (`docs/REVIEW-LOG-2026-09-29.md:3,28,50`), so it compiles this code. Not verified on `e5c778a`.
- **Runtime, memory:** authors claim under 1 s per contract; here Not verified (dominated by the forge rebuild, 55 s cold measured for the IR-minimum build). Budget 10 min per PR job.
- **Output, gate:** `--json`, `--sarif`, `--checklist` (markdown), `--zip`. Exit code -1 when findings reach the threshold: `--fail-high`, `--fail-medium`, `--fail-low`, `--fail-pedantic` (default), `--fail-none` (`slither/__main__.py:462-497,1034-1055`). Config key `fail_on` takes the enum value as a string.
- **False-positive classes expected here (confirm on first run):** `incorrect-equality` on `== 0` guards, `uninitialized-local` for zero-default counters, `calls-loop` over adapter and spoke arrays, `reentrancy-*` on paths guarded by `nonReentrant`, `timestamp` (35 uses), `divide-before-multiply` in bps math, `missing-zero-check` on initializers. Earlier reviews already judged instances of these classes (`docs/REVIEW-LOG-2026-09-29.md:28,50`).
- **Triage:** `// slither-disable-next-line <detector>` with a justification comment on the line above and `slither-disable-start/end` blocks exist but edit `src/`, so this plan does not use them without the founder (master plan 2.2 row 21); `--triage-mode` writes `slither.db.json` (commit it, with the reasons in `spec/baseline/static/slither-triage.md`); `@custom:security non-reentrant` on a state variable marks its external calls non-reentrant; `--show-ignored-findings` and config `warn_unused_ignores` audit stale ignores (`slither/utils/command_line.py:72-73`, wiki Usage).
- **Overlap:** Aderyn, Wake detectors, `forge lint` (the v1.8.0 notes claim near parity with Slither and Aderyn; Not verified: diff the findings on this repo).

### 5.2 Aderyn (static analysis, Cyfrin) [S4]
- **Checks:** 88 AST detectors registered in `aderyn_core/src/detect/detector.rs` (`define_detectors!`), spread over about 40 High and 50 Low source files. Notable for this repo: `unsafe-casting`, `state-change-without-event` (matches the rule "event at the end of every operation"), `reentrancy-state-change`, `unchecked-low-level-call`, `unused-error`, `centralization-risk`.
- **Install:** `npm install -g @cyfrin/aderyn@0.6.8`, `brew install cyfrin/tap/aderyn`, or release asset `aderyn-aarch64-apple-darwin.tar.xz` / `aderyn-x86_64-unknown-linux-gnu.tar.xz` (sha256 `ffd6ca658962e211a3ac821c646f69c8e14bf1b1001cbfe091bcd4535a691e46` for the Linux one, from the release digest).
- **Foundry consumption:** does not run forge. It compiles with solc directly and reads remappings from `remappings.txt` or `foundry.toml`, EVM version and via-IR from config (`aderyn_driver/src/compile.rs:58-84`). Exits 1 on any compile or AST-deserialisation error (`compile.rs:93-137`), so a parse failure is loud. Not verified: run once on `e5c778a` to confirm the `transient` state variable and `assembly ("memory-safe")` parse.
- **Runtime, memory:** Rust binary, Not verified; budget 3 min.
- **Output, gate:** `-o report.md|report.json|report.sarif` (format by extension), `--highs-only`. It does not fail on findings (only on errors), so gate on the JSON: `jq '.high_issues.issues | length'` (keys `high_issues`, `low_issues`, `issue_count`, `detectors_used` verified in `reports/highs-json-report.json`).
- **False positives, triage:** `aderyn.toml` `[detectors] exclude = [...]` (names from `aderyn registry`), `exclude = [paths]`. No inline suppression comment exists in the source read. Noise classes here: `centralization-risk` on `Ownable2Step` in `ManagerRegistry` (`src/core/ManagerRegistry.sol:17`), `literal-instead-of-constant`, `internal-function-used-once` (the code is split into layers on purpose, `src/core/CoreVaultBase.sol:18-21`), `push-zero-opcode` (both target chains run cancun bytecode in the fork tests, `docs/REVIEW-LOG-2026-09-29.md:20`).
- **Overlap:** Slither (most High classes), `forge lint`. Adds a second AST implementation, cheap.

### 5.3 Solhint (linter, Protofire) [S5]
- **Checks:** style, naming, NatSpec, best practices, a shallow security set (`avoid-tx-origin`, `avoid-low-level-calls`, `no-inline-assembly`, `reentrancy`, a lexical rule about state changes after a transfer, not a call-graph analysis), gas rules (`gas-custom-errors`, `gas-indexed-events`, `gas-struct-packing`, `gas-strict-inequalities`), Foundry test naming.
- **Install:** `npx solhint@6.2.4` or `npm i -D solhint@6.2.4` (Node 20+). No Docker or Action needed.
- **Foundry consumption:** reads `.sol` files directly, no compile. `.solhintignore` (gitignore syntax) and `.solhint.json`. Exclude `lib/`, `out/`, `cache/`.
- **Runtime, memory:** seconds, Not verified; budget 2 min.
- **Output, gate:** `-f stylish|table|tap|unix|json|compact|sarif`, `--max-warnings N`, non-zero exit when errors are reported (`solhint.js:264`). Gate: rules at `error` plus a ratchet against the committed warning count (`spec/baseline/static/solhint.json`); `--max-warnings 0` only once the config decisions of section 8.4 bring the count to 0, because 13 assembly blocks and 3 low-level calls in `src/` make zero unreachable otherwise.
- **False positives, triage:** `// solhint-disable-next-line <rule>` and `/* solhint-disable <rule> */ ... /* solhint-enable <rule> */` exist but would edit `src/`; this plan switches the two firing rules off in `.solhint.json` instead (section 8.4). Repo-specific traps: `immutable-vars-naming` defaults to `immutablesAsConstants: true` (UPPER_SNAKE) but the repo uses camelCase for immutables (`src/core/CoreVaultBase.sol:32-49`); `foundry-test-function-naming` accepts only `test...` names, so `invariant_*` and `check_*` are flagged unless test files get their own config (rule doc says to run it from a separate config).
- **Overlap:** `forge fmt --check` (layout), `forge lint`, Slither `naming-convention`. Keep Solhint for `use-natspec`, naming and the assembly and low-level-call justification rules.

### 5.4 Wake (static analysis and Python fuzzing, Ackee) [S6]
- **Checks:** 26 detector modules in `wake_detectors/` (for example `reentrancy`, `unchecked_return_value`, `unsafe_delegatecall`, `balance_relied_on`, `invalid_memory_safe_assembly`, `unused_error`, `unsafe_erc20_call`, `chainlink_deprecated_function`), printers, LSP, and a pytest-based fuzzing framework (`FuzzTest`, `@flow`, `@invariant`) that drives Anvil.
- **Install:** `pip install eth-wake==4.22.1` (Python 3.8+; Rosetta required on Apple Silicon per README); GitHub Actions "wake-setup" and "wake-detect" exist (marketplace links in README). Docker file present in repo. Not verified: image tag.
- **Foundry consumption:** `wake init` imports the Foundry profile from `forge config` and adds `test` and `script` to excluded paths (`wake/cli/init.py:200-300`). Default `compiler.solc.exclude_paths` contains `lib`, `script`, `test`; `detectors.ignore_paths` contains `test`. Not verified: that imports from `lib/` still compile when `lib` is excluded as a root path; confirm with `wake compile`.
- **Runtime, memory:** Not verified; budget 10 min.
- **Output, gate:** `wake detect all --export sarif|json|html|...` writes `wake-detections.sarif` (`wake/cli/detect.py:591-593`), exits 0 with no detections and 3 with any (`detect.py:707`), filters `--min-impact`, `--min-confidence` (env `WAKE_DETECT_MIN_IMPACT`, `WAKE_DETECT_MIN_CONFIDENCE`).
- **Python fuzzing vs forge:** no added value for this repository. It would need every mock (2,356 lines under `test/mocks/`) re-expressed as generated Python bindings, an Anvil process, and a second harness language. The only gain is a Python reference model for differential checks of `ShareMath` and `IncomeAccumulator`, which the Foundry fuzzers can do with a Solidity reference model at lower cost. Verdict: detectors only, on demand.
- **Overlap:** Slither, Aderyn. Unique: `invalid_memory_safe_assembly`.

### 5.5 Echidna (fuzzer, Trail of Bits) [S7]
- **Checks:** property-based stateful fuzzing. Modes: `property` (`echidna_` prefix by default, configurable `prefix`), `assertion`, `foundry` (Foundry naming, `invariant`-prefixed stateful), `verification` (symbolic single-transaction via hevm, `check`/`prove` prefixes), `overflow`, `optimization`, `exploration` (CHANGELOG Unreleased, README). Optional symbolic worker `symExec: true`.
- **Install:** release tarballs (macOS arm64 `echidna-2.3.3-aarch64-macos.tar.gz`, Linux x86_64 sha256 `436d26cb5af34c6c525812b857ac53f218c7f6ad07d69495ef88bc4cdc85c764`, Linux arm64 sha256 `a8853108ac57a43b550c8053dd1cd760fcc5347a9c4c389135fa0ae82a69a221`; sigstore bundles published), `brew install echidna`, Docker `ghcr.io/crytic/echidna/echidna` (Ubuntu noble with Slither, crytic-compile, solc-select, Foundry; README says x86 only, but the repo's `docker.yml` matrix builds `linux/amd64` and `linux/arm64`). Needs Slither on PATH.
- **Foundry consumption:** through crytic-compile (same `forge build --build-info --skip test script` rule; pass `cryticArgs: ["--foundry-compile-all"]` to keep a harness under `test/fuzz/`). It does not read `StdInvariant` selectors (no `targetContract` in its source), so existing `*InvariantTest` contracts do not run as they are.
- **Limits:** libraries: use `deployContracts: [["0x...", "CoreVaultLogic"]]` on a pre-linked build (format confirmed in `tests/solidity/basic/deployContract.yaml`). Code size limit defaults to `0xffffffff` (no EIP-170 problem). Not verified: the pre-linked route end to end.
- **Runtime, memory:** default workers = clamp(cores, 1, 4) (default.yaml comment); Haskell memory is unbounded by config; use 2 to 3 workers on 8 GB. Not verified, measure.
- **Output, gate:** `--format json|text`, corpus, coverage `txt`, `html`, `lcov`. Exit code 0 when all tests pass, 1 otherwise (`src/Main.hs:147`). Reproducers as Foundry tests for assertion failures (2.3.0 and 2.3.3 changelog).
- **False positives:** none in the static sense; a "failure" is a real sequence. Triage by shrinking and replay (`shrinkLimit`), and by reading revert reasons: a property that fails because the harness called a function in an impossible state is a harness defect (same class as the `ZeroSharePrice` case in section 2).
- **Overlap:** Medusa (same idea, different engine, keep both: different mutation strategies and EVMs), forge invariants.

### 5.6 Foundry / forge (test framework and now much more) [S8]
- **Install/pin:** `foundryup` (Rust foundryup since v1.8.0), `foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09` (v1.9.1) with `version: v1.8.3`, release assets `foundry_v1.8.3_darwin_arm64.tar.gz`, `linux_amd64`, `linux_arm64`, `alpine_*` with sigstore bundles. The repository has a `Dockerfile` at its root; Not verified: published image name and tag.
- **Checks and new native features (all confirmed in v1.8.0 and v1.8.3 release notes and `crates/config/src` at tag v1.8.3):**
  - Fuzz and invariant with coverage-guided corpus (`corpus_dir` inside `[fuzz]` and `[invariant]`, flattened), multi-worker stateless and invariant campaigns (`invariant.workers`), `invariant.timeout`, `invariant.max_time_delay`, `invariant.check_interval`, `failure_persist_dir`.
  - `forge test --symbolic`: preview. Prefixes `check*` and `prove*`, `invariant*` and `statefulFuzz*` become bounded symbolic call sequences. Solver Z3 by default, `[symbolic]` keys `solver`, `timeout` (30 s), `max_depth` (10,000), `max_paths` (1,024), `max_solver_queries` (10,000), `invariant_depth` (10), `storage_layout` (`solidity`, `generic`, `zero_init`), Halmos-compatible aliases `loop`, `depth`, `width`. Counterexamples are replayable JSON in `cache/symbolic/`, `--emit-regression` writes Solidity regression tests. The docs label it an MVP whose modelled EVM surface and reports may change, and state that a PASS is bounded by the recorded assumptions and search limits, not an unbounded proof. Known gaps: gas, unknown external code, cryptographic properties. v1.8.3 aligned symbolic `expectRevert`, `expectCall`, `mockCall` with concrete forge. Not verified: library linking under `--symbolic` (guide silent).
  - `forge test --mutate` (config `[mutation]`: `timeout`, `include_operators`, `exclude_operators`; operator groups `assembly`, `assignment`, `binary-op`, `delete-expression`, `elim-delegate`, `require`, `unary-op`; flags `--mutate-path`, `--mutate-contract`, `--mutation-jobs`, `--mutation-timeout`; `--json` gives score and survivors). Refuses projects with `ffi = true` or write-capable `fs_permissions` (this repo is read-only, `foundry.toml:13-14`). Baseline must pass first.
  - `forge test --brutalize`: rewrites a temporary workspace to dirty high bits and scratch memory and to misalign the free memory pointer, so it targets the 13 `memory-safe` assembly blocks (section 3).
  - `forge lint` (`[lint]`: `severity`, `exclude_lints`, `ignore`, `lint_on_build`, `lint_specific`). v1.8.0: default includes all severities; v1.8.3: default is high, medium, low.
  - `forge coverage` (lcov, `--ir-minimum`, `--include-libs`, `--exclude-tests`, `[coverage] skip_files`, `report`).
- **Runtime, memory (measured, Foundry 1.0.0):** default profile 4.6 s and 158 MB; ci profile 15 s; coverage 70 s and 1.0 GB.
- **Output, gate:** `--json`, JUnit (`--junit`, not combinable with `--mutate`), lcov, exit non-zero on failures. `forge lint` exit behaviour on findings: Not verified. Measured by the sibling document (`02-BASELINE.md` section 3.4, Foundry 1.0.0, 2.25 s): 291 lint warnings, 261 in `src/` (68 `require-revert-in-loop`, 50 `reentrancy-events`, 31 `calls-loop`, 28 `non-reentrant-not-first`, 11 `reentrancy-no-eth`), 0 errors, so `[lint] exclude_lints` needs a triage pass before `forge lint` can gate.
- **Risks:** v1.8.0 defaults changed (isolate, dynamic test linking); local 1.0.0 differs from CI; symbolic and mutation are new. Run the full suite under v1.8.3 with default and `--no-isolate` before adopting.

### 5.7 Medusa (fuzzer, Trail of Bits) [S9]
- **Checks:** parallel coverage-guided stateful fuzzing on go-ethereum, property tests (`property_` prefix), assertion tests (panic classes configurable: `failOnArithmeticUnderflow`, `failOnDivideByZero`, `failOnCompilerInsertedPanic`, ... default only `assert`), optimization tests (`optimize_`).
- **Install:** `brew install medusa`, `go install github.com/crytic/medusa@latest` (Go 1.20+; pin the tag instead), release `medusa-mac-arm64.tar.gz` and `medusa-linux-x64.tar.gz` (sha256 `ddfe1517ae9028ef9fc331b00f5a6a9d5406f3fcd11a715d60c6b6fb3e4546d3`). Docker image builds for `linux/amd64` only (`.github/workflows/docker.yml:46`). Needs crytic-compile and Slither for constants (`slither.useSlither`, cached in `slither_results.json`).
- **Foundry consumption:** `compilation.platform = "crytic-compile"`, `target = "."`, extra args via `platformConfig.args`; default rule skips `test/**`, so add `--foundry-compile-all` or keep the harness outside `test/`. Libraries deploy automatically (`fuzzing/fuzzer.go:497-534`). Deployment order equals `targetContracts` order, so a harness that deploys the whole system in its constructor needs only itself in `targetContracts`.
- **Limits:** no `expectRevert`, `expectEmit`, `mockCall`; code size check off by default; fork mode with an integer `rpcBlock` (block tags unsupported); corpus and senders tied to addresses, so changing `deployerAddress` or `senderAddresses` invalidates the corpus.
- **Runtime, memory:** 10 workers by default; `workerResetLimit` (50 sequences) bounds per-worker memory. Use 4 workers on 8 GB. Not verified, measure.
- **Output, gate:** coverage `html` and `lcov`, corpus directory, exit code `ExitCodeTestFailed` when a test failed (`cmd/fuzz.go:173-176`).
- **Overlap:** Echidna, forge invariants. Not verified: relative speed against Echidna and forge on our harness; measure in Step 0.

### 5.8 Halmos (symbolic testing, a16z) [S10]
- **Checks:** symbolic execution of Foundry-style tests. Default function filter is `(check|invariant)_` (`src/halmos/config.py`), so set it to `^check_` or the existing `invariant_*` tests get symbolically executed with `invariant_depth = 2`. Only `Panic(0x01)` (Solidity `assert`, forge-std `assert*`) fails a test by default (`panic_error_codes`); a revert does not, so revert behaviour is asserted with a low-level call and its returned `success`.
- **Install:** `uv tool install --python 3.12 halmos==0.3.3` (README); Docker `ghcr.io/a16z/halmos:latest` (contains foundry and solvers; Not verified: arm64 image, workflows in the repo declare no platforms). Solvers: yices 2.6.4 pinned (a code comment in `solvers.py` refers to Halmos issue 492 as the reason not to track the latest release), z3 4.12.6.0 wheel, optional cvc5 1.2.1 and bitwuzla 0.8.1 downloaded on demand (`HALMOS_ALLOW_DOWNLOAD=1` skips the prompt).
- **Foundry consumption:** runs forge itself, reads `out/` (`forge-build-out`), config from `halmos.toml` with a single `[global]` section and hyphenated keys, contract or function annotations `@custom:halmos --option`, symbolic cheatcodes from `a16z/halmos-cheatcodes` (`svm.createUint256`, `createAddress`, `createBytes`), installed with `forge install`.
- **Limits:** dynamic arrays and `bytes` need constant sizes (`--default-array-lengths` default `0,1,2`, `--default-bytes-lengths` default `0,65,1024`; error "symbolic CALLDATALOAD offset"); the constructor must produce a single path (error "constructor: # of paths: 2", fix `--solver-timeout-branching 0`); MCOPY size must be concrete (`sevm.py:3543-3546`); loop bound default 2 (`--loop`); no fork, no `expectRevert`, `expectEmit`, `mockCall`, `recordLogs`; results can differ between runs because solver timeouts are timing dependent (FAQ; `--solver-timeout-branching 0` removes one source).
- **Runtime, memory:** `solver-timeout-assertion` 60 s per query, `solver-timeout-branching` 1 ms, `solver-threads` = CPU count, `solver-max-memory` 0 (unlimited). Not verified: totals for this repo. Budget 90 min nightly, cap 6 h.
- **Output, gate:** `[PASS]`, `[FAIL]` with counterexample, `--json-output FILE`, `--statistics`. Exit code on failure: Not verified; gate on the JSON.
- **False positives:** over-approximated unknown calls (`uninterpreted-unknown-calls` default `0x150b7a02,0x1626ba7e,0xf23a6e61,0xbc197c81`, `return-size-of-unknown-calls` 32). Triage by replaying the counterexample in forge.
- **Status risk:** stale (section 4.1). Exit plan: every `check_*` also runs under `forge test --symbolic` and `hevm test --prefix check`, so no property depends on Halmos alone.

### 5.9 Mythril (symbolic security analysis, ConsenSys) [S11]
- **Checks:** symbolic execution and taint of EVM bytecode with SWC-classified issues. **Install:** `pip3 install mythril` (README shows Python 3.7 to 3.10), Docker `mythril/myth`.
- **Where it fails here:** the opcode table has TLOAD, TSTORE, PUSH0 (`mythril/support/opcodes.py:105-106,132`) but no MCOPY (0 hits in the repository), and solc 0.8.28 with cancun emits MCOPY for memory copies. Last release 2024-03-27. Not verified: what it does on byte `0x5E` (expected: treated as invalid, path ends), which makes results unsound. The objection applies only to runtimes that contain MCOPY: the coordinator's scan of `out/` at `e5c778a` (2026-09-30, PUSH data skipped, CBOR tail stripped) finds MCOPY 0 in ManagerFeeVault, ManagerRegistry, TransitEscrow and ChainlinkPriceSource (cards 03 and 04 measured the same), and at least 1 in every other runtime that has code except CoreVault (ShareToken 1, Create3Deployer 1, AcrossBridgeAdapter 1, AaveV3Adapter 1, FundFactory 2, ValueReportReceiver 2, SpokeVault 2, UniswapV4Adapter 3, CoreVaultLogic 3, SpokeCrossChainLib 4). CoreVault has none of its own but runs CoreVaultLogic by DELEGATECALL, so a Mythril run on it would treat the library call as an unknown external call and be unsound across it: it stays SKIP. Its exceptions module is the useful piece: it reports any reachable assert or Panic, which is how CF-R2 (`2^200` panics in `ChainlinkPriceSource`, CLPS:123-130) would be found (Not verified: whether it reports `Panic(0x11)`; read `mythril/analysis/module/modules/exceptions.py` at the pinned version).
- **Bounded run, verdict RUN on those four runtimes and on their Scribble-instrumented copies** (no registry property, no tier; a second opinion): Docker image `mythril/myth` pinned by digest (recorded at adoption; the image carries its own Python, which avoids the 3.7 to 3.10 constraint of a local install, Not verified), runtime bytecode as input (Not verified: the flag form, `--bin-runtime` with `-f <file>` as card 04 read it in `mythril/interfaces/cli.py`; confirm at the pinned version), `-t 1 --execution-timeout 600 --solver-timeout 25000 -o jsonv2` per card 04, 30 minutes per runtime, symbolic storage. The job `tools/static/mythril-run.sh` first scans the analysed runtime and fails if byte `0x5E` appears (PUSH-aware scan), so a future compile that introduces MCOPY cannot produce an unsound result silently. The earlier version of this card said SKIP for the whole repository, which was wrong for these four runtimes. Overlap: Slither, hevm.
- **Source-level spike** (`myth analyze src/libraries/ShareMath.sol --solv 0.8.28 --solc-json mythril.solc.json -t 3 --execution-timeout 120 -o jsonv2`, `mythril.solc.json` carrying the `remappings.txt` entries) stays a non-blocking data point: libraries compile to internal code and the contracts that use them contain MCOPY, so it is not part of the job.

### 5.10 Manticore (symbolic execution, Trail of Bits) [S12]
- Archived by the owner on 2026-06-24; the README says the project is no longer developed internally. It also says EVM Istanbul semantics are only partially implemented and suggests old 0.4.x compilers as a workaround. No PUSH0, MCOPY or TLOAD in `manticore/` (0 hits). Requires Python 3.7 or later. Invocation would be `manticore src/libraries/ShareMath.sol --contract ShareMath`, not worth running. **SKIP.**

### 5.11 hevm (symbolic execution, equivalence, EF formal methods team) [S13]
- **Checks:** `hevm test` (symbolic run of Foundry tests, default prefix `prove`, `--prefix check` works), `hevm equivalence` (two bytecodes return the same value, end with the same storage and the same success or failure; logs and gas are not compared), `hevm symbolic` with `--assertions` panic codes, `hevm exec`.
- **Install:** release binaries `hevm-arm64-macos` (101 MB, sha256 `4f6d5e0c8fc39b88c9f5edea05028b4d4ce31e399296da39d89c9cc68697b5d6`), `hevm-x86_64-linux` (sha256 `7d6da60cfaa5cfe326cef8e4dffc1fb66595c60a325d86921f393bbf5cea275c`), `hevm-x86_64-macos`; needs z3 (`brew install z3`, `apt install z3`) or cvc5 or bitwuzla. The docs rank bitwuzla as usually much faster than z3 and cvc5 as often faster. Nix flake exists. No Docker or Action in the docs read.
- **Foundry consumption:** `forge clean && forge build --ast` then `hevm test --root . --project-type Foundry`. Key flags: `--prefix`, `--match`, `--solver`, `--num-solvers`, `--smt-timeout` (default 300 s), `--smt-memory` (MB, Linux only), `--max-iterations` (default 5), `--max-depth`, `--max-width` (100), `--only-deployed`, `--early-abort`, `--max-dyn-size` (64), `--promise-no-reent`, `--rpc`, `--number`, `--cache-dir` (`cli/cli.hs:65-137,205-209`).
- **Limits:** unlinked bytecode is an error, so link first (section 8.1); symbolic arguments to CALL, DELEGATECALL, STATICCALL, CREATE, CREATE2, JUMP raise partial-exploration `[WARN]` (docs, limitations); Keccak is an uninterpreted function (possible `[not reproducible]` counterexamples); gas is not tracked; counterexamples are replayed and tagged `[validated]`. Symbolic `CREATE2` limits the useful scope on `FundFactory`.
- **Output, gate:** `[PASS]`, `[FAIL]`, `[WARN]`. Exit code on failure: Not verified; gate with `grep -E '\[(FAIL|WARN)\]'`.
- **Unique value:** equivalence checking. `SpokeVault` is 932 bytes under the limit, so size-driven refactors are likely; `hevm equivalence --code-a-file old.bin --code-b-file new.bin --sig 'fn(args)'` proves a refactor kept behaviour for each external function. Echidna's `verification` mode reuses this engine.

### 5.12 Kontrol (bytecode-level formal verification, Runtime Verification) [S14]
- **Checks:** KEVM-based symbolic execution of Foundry tests with compositional proofs, lemmas and loop invariants; proofs are over EVM bytecode, so the compiler is not in the trusted base for the proven paths.
- **Install:** `bash <(curl https://kframework.org/install)` then `kup install kontrol` (first run 30 min to 1 h, README); Docker `runtimeverificationinc/kontrol`; GitHub Action "install-kontrol" (docs; Not verified: repository and tag). **16 GB RAM and 16 GB swap recommended** [S14], so it does not fit the 8 GB machine; a public-repository `ubuntu-latest` runner has 16 GB [S16]. Prefer the Docker image pinned by digest over piping `curl` to `bash` in CI (record the digest at adoption; Not verified: published tags). **Capacity is itself unverified:** the runner has 16 GB RAM and 14 GB disk (section 9), the authors recommend 16 GB RAM plus 16 GB swap, and the memory, disk, image size and time of `kontrol build` and of one proof are Not verified. Step 0 (section 11, master plan 2.2 row 22) measures one build and one proof on the real runner before any package depends on Kontrol; if they do not fit (peak RSS above 14 GB, disk above 12 GB, or no proof inside the 6 h job cap), gate G1 closes on the fallback INV-SHARE-01 at V3-bv (Halmos and hevm) and every k-label waits for a larger runner.
- **Foundry consumption:** `kontrol build` (runs `forge build`, generates `foundry.k`, kompiles), `kontrol prove --match-test 'Contract.check.*'`, state in `out/proofs/`. `foundry.toml` needs `extra_output = ['storageLayout','abi','evm.methodIdentifiers','evm.deployedBytecode.object','devdoc']` (as in the tool's own test project). `kontrol.toml` uses `[build.default]`, `[prove.default]`, `[show.default]`.
- **Cheatcodes:** Foundry set including `expectRevert`, `expectEmit`, `mockCall`, `prank`, `deal`, `etch`, `warp`, `assume` (hard path constraint), plus `freshUInt`, `freshAddress`, `symbolicStorage`, `setArbitraryStorage`, `forgetBranch`. Not supported: fork management, file operations, FFI (returns a fresh symbol).
- **Libraries:** resolved and deployed automatically (docs "linked-library-example"); the prover's symbolic caller can branch, constrain it with `vm.assume`.
- **Limits and settings that bite:** chain id defaults to 1 (Foundry 31337): set `chainid`; `run-constructor` is off in the engine but on in `kontrol init` output; `max-depth` 1000 engine, 25000 in template; stuck proofs need K lemmas (keys `require` and `module-import` under `[build.default]`, section 8.9). Effort is days per module, not hours.
- **Output, gate:** `kontrol show`, `view-kcfg` TUI, counterexample output; exit codes Not verified.
- **Overlap:** Halmos, hevm, forge symbolic on the same specs. Unique: proof on bytecode with a formal EVM semantics.

### 5.13 Scribble (runtime verification by instrumentation, ConsenSys Diligence) [S15]
- **Checks:** turns `/// #invariant {:msg "P1"} expr;`, `#if_succeeds`, `#if_updated`, `#if_assigned`, `#define` (syntax confirmed in `test/samples/*.sol`) into runtime checks. A violation emits `AssertionFailed` and executes `assert(false)` unless `--no-assert`. Any tool that runs the instrumented code enforces the properties: forge tests, Echidna assertion mode, Medusa assertion testing.
- **Install:** `npm install -g eth-scribble@0.7.10` (Node; `.nvmrc` in the repo). Docs: https://docs.scribble.codes (not fetched; syntax taken from the repo's test samples).
- **Solidity 0.8.28:** `solc-typed-ast` `^18.2.5` (package.json) lists compilers up to 0.8.28 and its 2024-12-02 commit adding 0.8.28 support added the `transient` location, which the writer prints back (`ast_mapping.ts:856`). Latest solc-typed-ast is 20.0.9 but Scribble 0.7.10 stays on 18.x. Not verified: instrumenting all of `src/` end to end (OZ 5.7, Uniswap v4 imports, `assembly ("memory-safe")`, library functions with `storage` parameters). Pilot timebox: 1 day, kill criterion: any file in `src/` fails to instrument or the instrumented tree fails `forge build`.
- **Workflow:** never instrument in place. Copy the tree to `build/scribble/`, apply the annotation overlay patch there, run `scribble --output-mode files --utils-output-path <dir> --arm --compiler-version 0.8.28 --base-path . --path-remapping "<remappings joined by ;>"`, build with the lifted size limit, run forge, Echidna and Medusa on the copy (section 8.12).
- **Cost:** adds bytecode (SpokeVault has 932 bytes of room), and the last release is 2025-04-09. Unique value: per-function pre and post conditions with `old(...)` evaluated on every call of every test, without harness code.

## 6. Overlap map and where formal tools can reach

### 6.1 Which tool catches which class (cell = primary owner, "second" = redundant opinion)

| Class | Primary | Second opinion |
|---|---|---|
| Known bug patterns, reentrancy shape, unchecked returns, arbitrary send | Slither | Aderyn, Wake, `forge lint` |
| Style, naming, NatSpec, custom errors | Solhint, `forge fmt`, `forge lint` | Slither `naming-convention` |
| Stateful invariants under hostile call sequences | Medusa, `forge` invariants | Echidna |
| Exhaustive single-transaction properties (math, rounding, access) | Halmos, `forge --symbolic` | hevm, Echidna `verification`, Kontrol |
| Refactor safety (behaviour preserved) | `hevm equivalence` | none |
| Proof independent of compiler | Kontrol | none |
| Per-function pre and post conditions everywhere | Scribble | Foundry invariants |
| Test adequacy | `forge test --mutate` | `slither-mutate` |
| Assembly memory-safety claims | `forge test --brutalize` | Wake `invalid_memory_safe_assembly`, Slither `assembly` |
| Fork-only behaviour (Uniswap v4, Aave v3, Across, Wormhole, Chainlink) | forge fork tests | Medusa and Echidna fork mode with a pinned archive block |

### 6.2 Feasibility of formal tools per contract class (tool reach, not test selection)

| Class | Files (lines) | Reach |
|---|---|---|
| Pure libraries | `ShareMath` 126, `IncomeAccumulator` 276, `ReportCodec` 128, `TransitMessage` 45, `MandateLib` in `Mandate.sol` 379, `Create3` 80, `CodeStore` 71 | All FV tools; start here. Bound loops, keep array lengths constant |
| Small contracts | `ShareToken` 79, `ManagerRegistry` 73, `ManagerFeeVault` 44, `TransitEscrow` 39, `AdapterGuard` 54, `ChainlinkPriceSource` 158, `AcrossBridgeAdapter` 130 | Symbolic per function with mock dependencies; `ChainlinkPriceSource` needs a symbolic aggregator answer (round data, staleness) |
| State machines | `CoreVault` family (`CoreVault` 263, `CoreVaultBase` 354, `CoreVaultIncome` 115, `CoreVaultTransit` 135, `CoreVaultLogic` 762: about 1,630 lines, 1,764 with `CoreVaultTypes`), `SpokeVault` (1,004) + `SpokeCrossChainLib` (352), `ValueReportReceiver` 286 | Single-transaction properties per function with symbolic storage constrained by a structural precondition; multi-transaction invariants only bounded (`invariant_depth`) except Kontrol with lemmas. Both vaults call libraries by DELEGATECALL: link or resolve per tool (section 5) |
| Protocol adapters | `UniswapV4Adapter` 735, `AaveV3Adapter` 528 | Symbolic with mocks only; Halmos and Kontrol cannot fork, so the real Uniswap and Aave behaviour stays with fork tests and fuzzers. Formalise the guard and accounting arithmetic, not the protocol |
| Factory | `FundFactory` 511, `Create3Deployer` 36 | Symbolic `CREATE`/`CREATE2` arguments are a documented hevm limitation; verify hash pinning and address derivation as pure functions, leave deployment to fork tests |

## 7. Preparing the repository so every tool can run (decision-changing rules)

1. **Layout (contracts repository):** `test/unit/**` and `test/fork/**` stay as they are. New: `test/fuzz/` (Medusa and Echidna harnesses, `property_` prefix), `test/formal/` (`check_` prefix, symbolic specs), `spec/scribble/` (annotation overlay, pilot only), `tools/` (scripts in sections 8.10 and 8.12). Nothing tool-specific is added to `src/`, so the audited bytes never change.
2. **One property, one identifier, five runners.** Name functions `property_INV_<MODULE>_<nn>_<slug>` in `test/fuzz/` (Echidna `prefix: "property_"`, Medusa `testPrefixes: ["property_"]`) and `check_INV_<MODULE>_<nn>_<slug>` in `test/formal/` (Halmos `function = "check_"`, `forge test --symbolic` prefix `check*`, `hevm test --prefix check`, Kontrol `--match-test`). Existing `invariant_*` functions stay for forge. Solidity identifiers cannot contain hyphens, so `INV-CORE-03` becomes `INV_CORE_03`.
3. **Cheatcode floor for new suites:** only `prank`, `startPrank`, `stopPrank`, `deal`, `store`, `load`, `warp`, `roll`, `etch`, `addr`, `label` (the intersection of Halmos, hevm, Medusa, Echidna and Kontrol; verified against each tool's cheatcode list in section 4.2). `vm.assume` exists in Halmos, hevm, Kontrol, Echidna and forge but not in Medusa (no `assume` page under `docs/src/cheatcodes`), so `test/formal/` may use it and `test/fuzz/` must use an early `return`. No `expectRevert`, `expectEmit`, `recordLogs`, `mockCall`, `createSelectFork` in either directory. Revert behaviour is asserted with a low-level call and its `success` flag.
4. **Chain id:** the Core Vault constructor requires `block.chainid` to equal the Mandate hub chain (`src/core/CoreVaultBase.sol:50` comment on DEC-011, constructor at `:68`, check at `:77`). Kontrol defaults to 1, Foundry to 31337, hevm has no `vm.chainId`. Harnesses build the Mandate with `hubChainId = block.chainid`, and `kontrol.toml` pins `chainid`.
5. **Panic passthrough rule (defensive):** a handler may catch only the reverts that are legal in that state (for example `ZeroSharePrice`, section 2). Any `Panic(uint256)` caught from the system under test must call `assert(false)` (Echidna assertion mode, Medusa `panicCodeConfig`) so arithmetic faults in fee, share and income math cannot hide behind `try/catch`. The failing `ZeroSharePrice` sequence in section 2 is the counter-example of an unguarded handler.
6. **Actors every fuzz and symbolic harness models:** the manager (malicious: any allowed verb with any argument), at least two depositors, an attacker with direct-transfer donations to every custody address (DEC-080), hostile token behaviour (fee-on-transfer, returns false, reentrant hook) through a mock ERC-20, a hostile bridge or price source (stale, zero, reverting), and time and block jumps bounded by `blockTimestampDelayMax` and `blockNumberDelayMax`. Adapters stay pinned by codehash in the harness, as in production (`docs/REVIEW-LOG-2026-09-29.md`, Q17-4); a hostile adapter is modelled only as a mock with the same interface, never as different code at the pinned hash.
7. **Library linking, per tool:**

| Tool | Route | Status |
|---|---|---|
| forge tests | automatic (`dynamic_test_linking` default in v1.8.0) | verified by release notes |
| Medusa | automatic from compile artifacts (`fuzzing/fuzzer.go:497-534`) | verified in source, Not verified end to end |
| Echidna | `cryticArgs: ["--foundry-compile-all", "--compile-autolink"]`; crytic-compile links libraries from `0xa070` and writes `crytic-export` link info that Echidna reads (`lib/Echidna/Libraries.hs`). Fallback: `verify` profile plus `deployContracts` | Not verified with the Foundry platform |
| Halmos | automatic (`resolve_libs`) | verified in source, Not verified end to end |
| hevm | pre-link in the `verify` profile, put library runtime code at those addresses in `setUp` with `vm.etch` using a generated constant from `forge inspect <lib> deployedBytecode` (hevm has no `vm.getCode`) | Not verified: whether `type(Lib).runtimeCode` compiles for libraries |
| Kontrol | automatic | docs |
| `forge test --symbolic` | Not verified (guide silent) | Step 0 |

8. **Out directory:** hevm hard-codes `<root>/out` (`src/EVM/Solidity.hs:302,310`; `cli/cli.hs:468`), so the `verify` profile keeps the default `out`. Run verify builds in a dedicated CI job or a separate git worktree, never on top of the day-to-day `out/`.

## 8. Ready-to-copy configuration (nothing below is written to the contracts repository by this plan)

### 8.1 `foundry.toml` additions (keep the existing `[profile.default]`, `[fuzz]`, `[invariant]`, `[profile.ci]`, `[fmt]`, `[rpc_endpoints]`)

Keys confirmed in `crates/config/src` at tag v1.8.3 (`lib.rs`, `fuzz.rs`, `invariant.rs`, `symbolic.rs`, `lint.rs`) and in the guides in [S8].

```toml
# Nightly deep campaign: coverage-guided corpus, several workers, persisted failures.
[profile.deep.fuzz]
runs = 20_000
corpus_dir = "cache/corpus/fuzz"
failure_persist_dir = "cache/failures/fuzz"
[profile.deep.invariant]
runs = 2_000
depth = 128
workers = 4
timeout = 1800                    # seconds per invariant campaign
fail_on_revert = true
corpus_dir = "cache/corpus/invariant"
failure_persist_dir = "cache/failures/invariant"
max_time_delay = 604_800          # one week, matches the fuzzers
max_block_delay = 60_480

# Fully linked, AST-carrying build shared by hevm, Halmos, Kontrol, Echidna (fallback route) and forge --symbolic.
# hevm reads ./out only, so this profile keeps the default out directory: build it in its own job or worktree.
[profile.verify]
ast = true
build_info = true
extra_output = ["storageLayout", "abi", "evm.methodIdentifiers", "evm.deployedBytecode.object", "devdoc"]  # Kontrol
code_size_limit = 1_000_000       # lifts EIP-170 for instrumented builds; SpokeVault is 23,644 of 24,576 bytes
libraries = [
  "src/core/CoreVaultLogic.sol:CoreVaultLogic:0x0000000000000000000000000000000000c0de01",
  "src/spoke/SpokeCrossChainLib.sol:SpokeCrossChainLib:0x0000000000000000000000000000000000c0de02",
]
[profile.verify.symbolic]
solver = "z3"                     # add solver_portfolio = ["z3", "cvc5"] when cvc5 is installed
timeout = 120
max_depth = 20_000
max_paths = 4_096
max_solver_queries = 50_000
invariant_depth = 4
storage_layout = "solidity"       # "generic" only when a proof needs conservative storage
default_dynamic_length = 2
max_dynamic_length = 128

# Mutation testing, weekly, sharded by --mutate-path.
[profile.mutate.mutation]
timeout = 60
exclude_operators = []            # start with all seven groups on; drop "assembly" only with a written reason

# Built-in linter: complement to Solhint and Slither. Fill exclude_lints only with a justification comment.
[lint]
severity = ["high", "medium", "low"]
ignore = ["lib/**", "test/mocks/**"]
exclude_lints = []
lint_on_build = false

# Differential tests (512-bit oracles, model against contract; master plan 2.2 row 31). Values are a first setting chosen
# by this plan, to be tuned by B22 (Not verified); ffi stays off in every profile unless a differential test names it.
[profile.diff.fuzz]
runs = 10_000
max_test_rejects = 1_000_000

# Scribble instrumented copy only (section 8.12): instrumentation adds bytes, SpokeVault has 932 of margin.
[profile.scribble]
code_size_limit = 1_000_000

# forge test --brutalize rewrites sources before compiling (forge test --help, 1.8.3), so it needs the same lifted limit.
# AB needed the optimizer in B 3.1: Step 0 (B52) compiles AB under this profile and excludes it with a reason if it fails.
[profile.brutalize]
code_size_limit = 1_000_000
```

Notes: (a) `corpus_dir`, `frontier_dir` and the other corpus keys are flattened into `[fuzz]` and `[invariant]` (`#[serde(flatten)]` in `fuzz.rs`). (b) `call_override` (invariant) lets the fuzzer override an unsafe external call, useful to model reentrancy; Not verified semantics, read `forge test --help` first. (c) `forge lint` exit code on findings is Not verified. (d) The two `libraries` addresses are arbitrary and must stay identical in the harnesses' `vm.etch`, `deployContracts` and `predeployedContracts`.

### 8.2 `slither.config.json` (PR gate) and `slither.full.json` (nightly)

```json
{
  "filter_paths": "lib/,test/,script/,src/interfaces/external/",
  "exclude_dependencies": true,
  "exclude_informational": true,
  "exclude_optimization": true,
  "detectors_to_exclude": "solc-version,pragma,naming-convention",
  "fail_on": "medium",
  "compile_force_framework": "foundry",
  "sarif": "slither.sarif"
}
```

```json
{
  "filter_paths": "lib/,test/,script/,src/interfaces/external/",
  "exclude_dependencies": true,
  "fail_on": "none",
  "warn_unused_ignores": true,
  "show_ignored_findings": true,
  "compile_force_framework": "foundry",
  "json": "slither-full.json"
}
```

Exclusions and why: `solc-version` and `pragma` (the only pragma is the exact pin `0.8.28` in 45 files and `foundry.toml:7`; the solc known-bug list is a release checklist item, not per-run noise, and master plan 4.7 and package A53 (`tools/release/solc-bugs.py`) now carry it as a release-gate step, because solc is in the trusted base of every path except those Kontrol proves; Not verified: the detector's verdict on 0.8.28), `naming-convention` (owned by Solhint with repo rules, two naming linters disagree). Everything else stays on. Informational and Optimization are hidden only in the PR gate and always run in the nightly full report, where the 13 assembly blocks and 3 low-level calls are checked to have a triage entry with a reason in `spec/baseline/static/slither-triage.md` (an in-source `slither-disable-next-line` edits `src/` and waits for the founder, master plan 2.2 row 21). Until B02 commits the triage, this configuration runs as a ratchet against `spec/baseline/static/slither.json` and does not block. `filter_paths` is a comma-separated list of regexes matched against result paths (`slither/__main__.py:311-315`); `src/interfaces/external/` holds vendored interface declarations only (`README.md` toolchain section). Gate: `--fail-medium` means Medium and High fail, Low does not; raise to `low` after the first triage. Commit `slither.db.json` (triage mode output) only with each hidden result justified in the PR description.

### 8.3 `aderyn.toml`

```toml
version = 1
src = "src"
exclude = ["src/interfaces/external/"]

[detectors]
exclude = [
  "unspecific-solidity-pragma",   # exact pin 0.8.28 everywhere
  "push-zero-opcode",             # both target chains execute cancun bytecode in the fork suites
  "internal-function-used-once",  # layered split is deliberate (CoreVaultBase.sol:18-21)
  "literal-instead-of-constant",  # bps and unit literals are named at the constant level already
  "large-numeric-literal",        # same
  "empty-require-revert",         # no require() in the code base
]
```

Names are the kebab-case forms of the `IssueDetectorNamePool` variants (`aderyn_core/src/detect/detector.rs`); confirm each with `aderyn registry`. Gate in CI on the JSON, not on exit code (section 5.2). Aderyn has no inline suppression in the source read; anything else is triaged by exclusion here, with the reason in the comment.

### 8.4 `.solhint.json`, `.solhintignore`, `test/.solhint.json`

```json
{
  "extends": "solhint:recommended",
  "plugins": [],
  "rules": {
    "compiler-version": ["error", "0.8.28"],
    "func-visibility": ["error", { "ignoreConstructors": true }],
    "state-visibility": "error",
    "avoid-tx-origin": "error",
    "avoid-suicide": "error",
    "avoid-sha3": "error",
    "avoid-throw": "error",
    "avoid-call-value": "error",
    "check-send-result": "error",
    "multiple-sends": "error",
    "no-complex-fallback": "error",
    "not-rely-on-block-hash": "error",
    "reentrancy": "error",
    "no-inline-assembly": "off",
    "avoid-low-level-calls": "off",
    "not-rely-on-time": "off",
    "gas-custom-errors": "error",
    "reason-string": "off",
    "immutable-vars-naming": ["error", { "immutablesAsConstants": false }],
    "const-name-snakecase": "error",
    "private-vars-leading-underscore": ["warn", { "strict": false }],
    "func-name-mixedcase": "error",
    "contract-name-capwords": "error",
    "event-name-capwords": "error",
    "interface-starts-with-i": "error",
    "use-forbidden-name": "error",
    "named-parameters-mapping": "warn",
    "use-natspec": ["warn", {
      "title": { "enabled": true, "ignore": {} },
      "notice": { "enabled": true, "ignore": {} },
      "param": { "enabled": false, "ignore": {} },
      "return": { "enabled": false, "ignore": {} },
      "author": { "enabled": false, "ignore": {} }
    }],
    "max-line-length": ["error", 120],
    "quotes": ["error", "double"],
    "imports-on-top": "error",
    "no-global-import": "error",
    "no-unused-import": "error",
    "duplicated-imports": "error",
    "explicit-types": ["error", "explicit"],
    "no-unused-vars": ["error", { "validateParameters": true }],
    "constructor-syntax": "error",
    "payable-fallback": "error",
    "no-console": "error",
    "one-contract-per-file": "off",
    "function-max-lines": "off",
    "gas-strict-inequalities": "off",
    "gas-increment-by-one": "off",
    "gas-small-strings": "off",
    "import-path-check": "off"
  }
}
```

Why these settings: `gas-custom-errors` at `error` enforces the repo rule (0 `require(`, 205 custom errors); `immutable-vars-naming` with `immutablesAsConstants: false` because immutables are camelCase (`src/core/CoreVaultBase.sol:32-49`); `not-rely-on-time` off because 35 uses are the model (deadlines, terms), Slither `timestamp` still reports them; `one-contract-per-file` off because type files and libraries share files (`src/mandate/Mandate.sol`, `src/spoke/SpokeVaultTypes.sol`); `reentrancy` is a shallow lexical rule and never a substitute for Slither; `use-natspec` starts with title and notice only, raise `param` and `return` once the first run shows adherence (`max-line-length` and `quotes` mirror `[fmt]` at `foundry.toml`, `line_length = 120`, `quote_style = "double"`). **`no-inline-assembly` and `avoid-low-level-calls` are `off` (they were `warn` in an earlier version of this file).** `src/` has 13 assembly blocks and 3 low-level calls (section 3), so both rules fire there with certainty, a `--max-warnings 0` gate could never pass, and the only in-source remedy, a `solhint-disable` comment, edits `src/` and therefore the audited bytes (master plan 2.2 row 21, FV [F9]). Reasons for each rule being off go in `spec/baseline/static/solhint-triage.md` (13 blocks: all `assembly ("memory-safe")`, reviewed by Slither, Wake `invalid_memory_safe_assembly` and `forge test --brutalize`; 3 calls: CVL:626, SCL:341, C3:48, reviewed by Slither `low-level-calls` and the cards). No `solhint-disable` exists or is added in `src/`, so the old reason-on-disable grep is unnecessary; in `test/` it stays. The first run `npx solhint@6.2.4 'src/**/*.sol'` may still show warnings from the other `warn` rules (`use-natspec`, `private-vars-leading-underscore`, `named-parameters-mapping`; Not verified, section 11); B01 commits their count in `spec/baseline/static/solhint.json` and the CI job fails only on a new warning above it (ratchet). Zero warnings is reached by config decisions recorded in the triage file, never by editing `src/`.

`.solhintignore`: `lib/`, `out/`, `cache/`, `node_modules/`, `build/`, `script/`. `test/.solhint.json` (run as `npx solhint@6.2.4 -c test/.solhint.json 'test/**/*.sol'`): `{ "extends": "solhint:recommended", "rules": { "foundry-test-function-naming": "off", "func-name-mixedcase": "off", "gas-custom-errors": "off", "use-natspec": "off", "no-unused-vars": "warn", "no-empty-blocks": "off", "no-inline-assembly": "off", "not-rely-on-time": "off", "avoid-low-level-calls": "off", "reason-string": "off", "explicit-types": "off", "one-contract-per-file": "off", "function-max-lines": "off", "max-states-count": "off", "avoid-tx-origin": "error", "avoid-suicide": "error", "quotes": ["error", "double"], "max-line-length": ["error", 120] } }`. `foundry-test-function-naming` is off because names like `invariant_*`, `check_*` and `property_*` do not match its `test...` regex (rule documentation).

### 8.5 `wake.toml` and Wake commands

```toml
[compiler.solc]
target_version = "0.8.28"
evm_version = "cancun"
via_IR = false
include_paths = ["node_modules"]
exclude_paths = ["node_modules", "venv", ".venv", "lib", "script", "test", "out", "cache", "build"]
remappings = [
  "forge-std/=lib/forge-std/src/",
  "@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/",
  "@uniswap/v3-core/contracts/=lib/v3-core/contracts/",
  "@uniswap/v3-periphery/contracts/=lib/v3-periphery/contracts/",
  "wormhole-sdk/=lib/wormhole-solidity-sdk/src/",
  "IERC20/=lib/wormhole-solidity-sdk/src/interfaces/token/",
  "SafeERC20/=lib/wormhole-solidity-sdk/src/libraries/",
  "@uniswap/v4-core/=lib/v4-core/",
  "@uniswap/v4-periphery/=lib/v4-periphery/",
  "solmate/=lib/v4-core/lib/solmate/",
  "permit2/=lib/v4-periphery/lib/permit2/",
]
[compiler.solc.optimizer]
enabled = true
runs = 800

[detectors]
exclude = ["axelar-proxy-contract-id"]     # Axelar-specific, irrelevant here
ignore_paths = ["venv", ".venv", "test", "lib"]
exclude_paths = ["node_modules", "lib", "script"]
```

The remappings are the entries of `remappings.txt`. Detector command names are kebab-case (`wake_detectors/*.py`). Commands, on demand only (Python 3.8+, Rosetta on Apple Silicon):

```bash
python3 -m venv .venv-wake && .venv-wake/bin/pip install eth-wake==4.22.1
.venv-wake/bin/wake detect all --min-impact medium --min-confidence medium --export sarif   # writes wake-detections.sarif, exit 3 on any detection
.venv-wake/bin/wake detect reentrancy unchecked-return-value unsafe-erc20-call balance-relied-on \
  invalid-memory-safe-assembly chainlink-deprecated-function unprotected-selfdestruct msg-value-nonpayable-function
```

Wake fuzz tests in Python: not configured (section 5.4). `wake up` and `[testing]` are left at defaults.

### 8.6 `echidna.yaml` (Echidna 2.3.3)

Keys are from `tests/solidity/basic/default.yaml` in [S7]; CLI overrides `--test-mode`, `--timeout`, `--workers`, `--corpus-dir`, `--seq-len`, `--test-limit`, `--crytic-args` exist (`src/Main.hs:195-267`).

```yaml
projectName: pool-party
testMode: assertion            # second job: --test-mode property
prefix: "property_"
testLimit: 5000000
seqLen: 60
shrinkLimit: 5000
stopOnFail: false
coverage: true
corpusDir: echidna-corpus
coverageDir: echidna-coverage
coverageFormats: ["txt", "html", "lcov"]
coverageExcludes: ["lib/**/*.sol", "test/mocks/**/*", "test/fuzz/**/*"]
workers: 3                      # 8 GB machine; default is clamp(cores, 1, 4)
timeout: 3300                   # seconds; CI overrides per job
format: text
deployer: "0x30000"
sender: ["0x10000", "0x20000", "0x30000", "0x40000"]   # depositors, manager, attacker
psender: "0x10000"
balanceAddr: 0xffffffff
balanceContract: 0
codeSize: 0xffffffff
maxTimeDelay: 604800
maxBlockDelay: 60480
excludeViewPure: true
allowFFI: false
disableSlither: false
allContracts: false
cryticArgs: ["--foundry-compile-all", "--compile-autolink"]
# Fallback when autolink does not work with the Foundry platform: build with FOUNDRY_PROFILE=verify and use
# deployContracts: [["0x0000000000000000000000000000000000c0de01", "CoreVaultLogic"], ["0x0000000000000000000000000000000000c0de02", "SpokeCrossChainLib"]]
# instead of --compile-autolink (format confirmed in tests/solidity/basic/deployContract.yaml).
# Fork run (pinned archive block): --rpc-url "$ARBITRUM_RPC_URL" --rpc-block <N>; Not verified with this harness.
```

Run: `echidna . --contract CoreVaultProperties --config echidna.yaml` (harness contract in `test/fuzz/`, deploys the system in its constructor). Symbolic mode for pure functions: `--test-mode verification` on a contract whose `check_*` functions are the specs (README, CHANGELOG Unreleased). `symExec: true` adds a symbolic worker to a normal campaign: leave off until the fuzz campaign is stable (`symExecTimeout` default 30, `symExecMaxIters` 5).

### 8.7 `medusa.json` (Medusa 1.5.1)

Structure and defaults from `docs/src/static/medusa.json` and `project_configuration/*.md` [S9]. Stricter than default: every EVM panic fails a test, so a `Panic(0x11)` in fee, share or income math cannot pass (`failOnArithmeticUnderflow` and the other panic classes are `false` by default).

```json
{
  "fuzzing": {
    "workers": 4,
    "workerResetLimit": 50,
    "timeout": 3300,
    "testLimit": 0,
    "shrinkLimit": 5000,
    "callSequenceLength": 60,
    "pruneFrequency": 5,
    "corpusDirectory": "medusa-corpus",
    "coverageEnabled": true,
    "coverageFormats": ["html", "lcov"],
    "coverageExclusions": ["lib/**", "test/mocks/**", "test/fuzz/**"],
    "revertReporterEnabled": true,
    "targetContracts": ["CoreVaultProperties"],
    "predeployedContracts": {},
    "targetContractsBalances": [],
    "constructorArgs": {},
    "deployerAddress": "0x30000",
    "senderAddresses": ["0x10000", "0x20000", "0x30000", "0x40000"],
    "blockNumberDelayMax": 60480,
    "blockTimestampDelayMax": 604800,
    "transactionGasLimit": 12500000,
    "testing": {
      "stopOnFailedTest": false,
      "stopOnFailedContractMatching": false,
      "stopOnNoTests": true,
      "testAllContracts": false,
      "testViewMethods": false,
      "verbosity": 1,
      "assertionTesting": {
        "enabled": true,
        "panicCodeConfig": {
          "failOnCompilerInsertedPanic": true,
          "failOnAssertion": true,
          "failOnArithmeticUnderflow": true,
          "failOnDivideByZero": true,
          "failOnEnumTypeConversionOutOfBounds": true,
          "failOnIncorrectStorageAccess": true,
          "failOnPopEmptyArray": true,
          "failOnOutOfBoundsArrayAccess": true,
          "failOnAllocateTooMuchMemory": true,
          "failOnCallUninitializedVariable": true
        }
      },
      "propertyTesting": { "enabled": true, "testPrefixes": ["property_"] },
      "optimizationTesting": { "enabled": false, "testPrefixes": ["optimize_"] },
      "targetFunctionSignatures": [],
      "excludeFunctionSignatures": []
    },
    "chainConfig": {
      "codeSizeCheckDisabled": true,
      "cheatCodes": { "cheatCodesEnabled": true, "enableFFI": false },
      "skipAccountChecks": true,
      "forkConfig": { "forkModeEnabled": false, "rpcUrl": "", "rpcBlock": 1, "poolSize": 20 }
    }
  },
  "compilation": {
    "platform": "crytic-compile",
    "platformConfig": { "target": ".", "solcVersion": "", "exportDirectory": "", "args": ["--foundry-compile-all"] }
  },
  "slither": { "useSlither": true, "cachePath": "medusa-slither-cache.json", "args": [] },
  "logging": { "level": "info", "logDirectory": "", "noColor": false }
}
```

Notes: corpus paths change when `deployerAddress`, `senderAddresses` or the `targetContracts` order change, so keep them frozen and version the corpus cache key by harness hash. Sizing for 8 GB: `workers` 4, `workerResetLimit` 50 (lower it if memory grows). A fork variant sets `forkModeEnabled: true`, `rpcUrl` from a secret and `rpcBlock` to an integer archive block (block tags are unsupported). Panic passthrough (section 7.5) is what makes the panic switches useful: a handler that swallows a panic hides it from Medusa.

### 8.8 `halmos.toml` (Halmos 0.3.3)

Single `[global]` section, hyphenated keys (`tests/regression/halmos.toml` and `src/halmos/config.py` in [S10]). A regex `function` that does not start with `^` is used as a prefix, so `function = "check_"` matches `check_...` and never `hcheck_...`, and `match-contract = "Formal$"` never matches a contract whose name does not end in `Formal` (for example `ShareAnySelector`). The any-selector nets (`hcheck_`, FV 3.4) therefore live in contracts named `<Unit>AnySelectorFormal` and run in a second call, `halmos --config halmos.toml --function hcheck_`, added by `tools/formal/run-matrix.sh` and by the `formal-nightly` job (master plan 2.2 row 24); spec-lint rule 2 fails when a registry `hcheck_` runner is absent from a Halmos JSON result.

```toml
[global]
forge-build-out = "out"
function = "check_"                  # never "(check|invariant)_": that would run the existing invariant_* tests symbolically
match-contract = "Formal$"
loop = 4                             # set to (largest array length in the harness) + 1; each step multiplies paths
width = 0
depth = 0
invariant-depth = 2
default-array-lengths = "0,1,2"
default-bytes-lengths = "0,32,65"    # 65 = ECDSA signature size (Halmos default set is 0,65,1024)
storage-layout = "solidity"          # "generic" only for unusual storage patterns
solver = "yices"                     # default; z3, cvc5, bitwuzla also supported
solver-timeout-branching = "1ms"     # add 0 for deterministic runs (no unknown answers), slower
solver-timeout-assertion = "300s"    # default 60s; 0 disables
statistics = true
json-output = "halmos-report.json"
early-exit = false
cache-solver = false
```

`solver-threads`, `test-parallel`, `solver-parallel` exist (`config.py`); Not verified: their memory behaviour, measure before enabling. `solver-max-memory` defaults to 0 (unlimited): cap memory with the container or `ulimit` instead. Per-test overrides go in natspec: `/// @custom:halmos --loop 6 --solver-timeout-assertion 600s`.

### 8.9 `kontrol.toml` sketch (Kontrol 1.0.255)

Derived from the file `kontrol init` writes (`src/kontrol/utils.py:235-280`) and the flag notes in the tool's own skill files [S14]. Requires the `extra_output` line in `foundry.toml` (profile `verify` in 8.1).

```toml
[build.default]
foundry-project-root = '.'
require              = 'test/formal/lemmas.k'          # empty file at first; add lemmas only for stuck proofs
module-import        = 'TestBase:KONTROL-LEMMAS'
auxiliary-lemmas     = true
o2                   = true

[prove.default]
foundry-project-root       = '.'
match-test                 = ['ShareMathFormal.check_.*', 'IncomeAccumulatorFormal.check_.*']
max-depth                  = 25000
workers                    = 2                          # 16 GB machine
smt-timeout                = 1000
run-constructor            = true
no-stack-checks            = true
fail-fast                  = false
failure-information        = true
counterexample-information = true
chainid                    = 42161                      # Arbitrum One; Kontrol defaults to 1
```

Traps recorded by the tool's authors: symbolic immutables assigned in constructors need `--symbolic-immutables`; library calls make the symbolic caller branch (add `vm.assume` on `msg.sender`); rebuild after edits with `kontrol build --regen --rekompile`. Not verified: `match-test` regex semantics against `Contract.function(sig)` names, confirm with `kontrol list` after one build. Run in CI from a pinned Docker image (digest recorded at adoption).

### 8.10 hevm commands (0.58.0)

```bash
# 1. fully linked build with AST, in a dedicated job or worktree (hevm reads ./out only)
FOUNDRY_PROFILE=verify forge clean && FOUNDRY_PROFILE=verify forge build --ast
# 2. symbolic tests: prefix check, only the formal suite, all counterexamples
# z3 first; the hevm docs rank bitwuzla as usually faster (Not verified: its package name on macOS)
hevm test --root . --project-type Foundry --prefix check --match 'Formal' \
  --solver z3 --num-solvers 2 --smt-timeout 300 --smt-memory 3000 \
  --max-iterations 8 --max-dyn-size 96 --only-deployed
# 3. equivalence of a refactor: deployed bytecode of old and new, per external function
FOUNDRY_PROFILE=verify forge inspect src/core/CoreVault.sol:CoreVault deployedBytecode | sed 's/^0x//' > new.bin   # verify profile: libraries pre-linked; field name: check `forge inspect --help`
git switch --detach <old-commit> && FOUNDRY_PROFILE=verify forge build && \
  FOUNDRY_PROFILE=verify forge inspect src/core/CoreVault.sol:CoreVault deployedBytecode | sed 's/^0x//' > old.bin
hevm equivalence --code-a-file old.bin --code-b-file new.bin --sig 'deposit(uint256,uint256)' --solver z3 --smt-timeout 600
# 4. fork a pinned archive block for a fork-only property
hevm test --root . --rpc "$ARBITRUM_RPC_URL" --number <archive-block> --cache-dir .hevm-rpc-cache --prefix check --match 'Fork'
```

Flags verified in `cli/cli.hs:65-137,205-226`. Run step 3 in a separate `git worktree` so the working tree of the main checkout is never switched. `--smt-memory` works on Linux only. Equivalence ignores logs and gas, so events (the rule "event at the end of every operation") need a separate check, for example a forge test that compares logs of old and new builds. Both bytecodes must be built with the same library addresses; immutables are compared as zero placeholders. Exit codes of `hevm test` and `equivalence` are Not verified: wrap with `tee` and `grep -E '\[(FAIL|WARN)\]'`.

Pre-link helper for `vm.etch` (hevm has no `vm.getCode`), run under the `verify` profile:

```bash
#!/usr/bin/env bash
# tools/gen-linked-lib-code.sh : writes library runtime code as constants; CI fails when the file differs
set -euo pipefail
out=test/formal/generated/LinkedLibCode.sol; mkdir -p "$(dirname "$out")"
g() { printf '    bytes internal constant %s = hex"%s";\n' "$1" "$(forge inspect "$2" deployedBytecode | sed 's/^0x//')"; }
{ echo '// SPDX-License-Identifier: MIT'; echo 'pragma solidity 0.8.28;'; echo '// GENERATED by tools/gen-linked-lib-code.sh. Do not edit.'
  echo 'library LinkedLibCode {'
  g CORE_VAULT_LOGIC src/core/CoreVaultLogic.sol:CoreVaultLogic
  g SPOKE_CROSS_CHAIN_LIB src/spoke/SpokeCrossChainLib.sol:SpokeCrossChainLib
  echo '}'; } > "$out"
```

### 8.11 Mythril (bounded run on four runtimes) and Manticore (SKIP)

Manticore is SKIP: `manticore src/libraries/ShareMath.sol --contract ShareMath` is expected to fail on PUSH0, one 30 minute spike at most in an isolated virtual environment to record the failure mode, no CI job. **Mythril is RUN, bounded, on the four runtimes with no MCOPY** (section 5.9, master plan 2.1 row 5), by `tools/static/mythril-run.sh`, in the `mythril` job of the weekly workflow and of the release gate:

```bash
#!/usr/bin/env bash
# tools/static/mythril-run.sh [--ci] [--scribble]   (sketch; flag forms Not verified, read mythril/interfaces/cli.py at the pinned version)
set -euo pipefail
IMG="mythril/myth@sha256:<digest recorded at adoption>"
for c in ManagerFeeVault ManagerRegistry TransitEscrow ChainlinkPriceSource; do
  hex=$(jq -r '.deployedBytecode.object' "out/$c.sol/$c.json" | sed 's/^0x//')
  # PUSH-aware scan: skip PUSH1..PUSH32 data, strip the CBOR tail, fail if 0x5E (MCOPY) is present.
  python3 tools/static/opscan.py --runtime "$hex" --forbid 5e
  printf '%s' "$hex" > "build/mythril/$c.runtime.hex"
  timeout 1800 docker run --rm -v "$PWD/build/mythril:/w" "$IMG" \
    analyze -f "/w/$c.runtime.hex" --bin-runtime -t 1 --execution-timeout 600 --solver-timeout 25000 -o jsonv2 \
    > "build/mythril/$c.json" || true     # a timeout is recorded, not a failure; a hit is triaged in spec/baseline/static/mythril-triage.md
done
```

The `--scribble` mode runs the same loop over the runtimes built from the Scribble copy (master plan B52); a runtime that gained MCOPY through instrumentation is skipped with its reason.

### 8.12 Scribble workflow (pilot; instrument a copy, never `src/`)

Kill criterion: any `src/` file fails to instrument, or the instrumented copy fails `forge build`. Timebox one day. Add to `foundry.toml`: `[profile.scribble] code_size_limit = 1_000_000`.

```bash
#!/usr/bin/env bash
# tools/scribble-run.sh
set -euo pipefail
ROOT=$(pwd); WORK="$ROOT/build/scribble"
rm -rf "$WORK"; mkdir -p "$WORK"
rsync -a --exclude .git --exclude out --exclude cache --exclude build --exclude lib --exclude node_modules ./ "$WORK"/
ln -s "$ROOT/lib" "$WORK/lib"
patch -p1 -d "$WORK" < spec/scribble/annotations.patch          # annotations live in the overlay, not in src/
REMAP=$(grep -v '^[[:space:]]*$' remappings.txt | paste -sd';' -)
( cd "$WORK" && npx --yes eth-scribble@0.7.10 $(find src -name '*.sol' | sort) \
    --output-mode files --utils-output-path src/scribble-utils \
    --compiler-version 0.8.28 --base-path . --path-remapping "$REMAP" \
    --arm --instrumentation-metadata-file scribble-metadata.json )
( cd "$WORK" && FOUNDRY_PROFILE=scribble forge build --sizes )   # expect SpokeVault above 24,576: size limit is lifted for tests only
( cd "$WORK" && FOUNDRY_PROFILE=scribble forge test --no-match-path 'test/fork/**' )
( cd "$WORK" && medusa fuzz --config medusa.json )                # assertion testing catches the instrumented assert(false)
( cd "$WORK" && echidna . --contract CoreVaultProperties --config echidna.yaml --test-mode assertion )
```

Annotation overlay examples (syntax from `test/samples/*.sol` in [S15]; the properties are the existing `invariant_DEC091_supplyIsWholeShares` and `invariant_DEC080_directTransferNeverMovesSharePrice` ideas, identifiers illustrative until the properties document fixes them):

```solidity
/// #invariant {:msg "INV-TOKEN-01 (DEC-091) supply is whole shares"} totalSupply() % 1e18 == 0;
contract ShareToken is ERC20 { ... }
```

Every `#if_succeeds` uses `old(...)` for before-state values; keep expressions free of external calls. Not verified: the grammar over this code base, resolved by the pilot. `--arm` swaps files inside the copy only; the flags used are the ones listed in `src/bin/scribble_cli.json` (`output-mode`, `utils-output-path`, `arm`, `compiler-version`, `base-path`, `path-remapping`, `instrumentation-metadata-file`). A failure shows as an `AssertionFailed` event plus `assert(false)` unless `--no-assert` is passed.

## 9. GitHub Actions layout

Runner facts [S16]: the repository is public, so standard hosted runners are free; `ubuntu-latest` has 4 vCPU, 16 GB RAM, 14 GB disk (2 vCPU and 8 GB if the repository ever becomes private); jobs are capped at 6 hours; cache is 10 GB per repository; artifacts 500 MB on the Free plan; 20 concurrent jobs on Free. Defensive rules for every workflow: pin actions by full commit SHA (values below were resolved on 2026-09-30), `permissions: contents: read` by default, `persist-credentials: false`, no secrets on `pull_request` from forks (fork tests need an archive RPC secret, so they run on `main`, nightly and on demand only), tool binaries verified by sha256 from the release digests, tool versions pinned.

Pinned actions: `actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1` (v7.0.1), `foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09` (v1.9.1), `astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7` (v10.2.0), `actions/setup-node@820762786026740c76f36085b0efc47a31fe5020` (v7.0.0), `actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97` (v7.0.0), `actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9` (v6.1.0), `actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a` (v7.0.1), `github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2` (v4.38.2).

### 9.1 Job matrix

| Job | Trigger | Blocking | Runner | `timeout-minutes` | Expected minutes | Basis |
|---|---|---|---|---|---|---|
| `fmt-lint-build`: `forge fmt --check`, `forge build --sizes`, `forge lint` | every PR, push to main | yes | ubuntu-latest | 15 | 3 | measured: checkout 70 s, toolchain 4 s, fmt 1 s [S17]; cold compile 55 s (IR-minimum run). Estimate |
| `unit`: default profile, no fork | every PR | yes | ubuntu-latest | 15 | 1 | measured 4.6 s on 8 CPUs; runner has 4 vCPU. Estimate |
| `invariant-ci`: `FOUNDRY_PROFILE=ci` | every PR | yes, after the harness fix (section 2) | ubuntu-latest | 15 | 1 | measured 15 s on 8 CPUs. Estimate |
| `solhint` (ratchet against `spec/baseline/static/solhint.json`) | every PR | ratchet, non-blocking from B01, blocking from B02's triage | ubuntu-latest | 5 | 1 | Not verified |
| `slither` (PR config, ratchet first, then `--fail-medium`; SARIF upload) | every PR | non-blocking from B01, blocking from B02's triage | ubuntu-latest | 20 | 4 | Not verified: full forge rebuild dominates |
| `aderyn` (ratchet first, then JSON gate on High; SARIF upload) | every PR | non-blocking from B01, blocking for High from B02's triage | ubuntu-latest | 10 | 2 | Not verified |
| `medusa-smoke` (`--timeout 600`) | PRs touching `src/**` or `test/fuzz/**` | yes | ubuntu-latest | 25 | 14 | fixed by `--timeout` plus build |
| `fork` (Arbitrum and Robinhood suites, secrets) | push to main, nightly, on demand | yes on main | ubuntu-latest | 30 | 8 | Not measured; needs archive RPC |
| `coverage` (`forge coverage --ir-minimum`, ratchet) | nightly, on demand | ratchet | ubuntu-latest | 30 | 4 | measured 70 s, 1.0 GB. Estimate |
| `deep-forge` (`FOUNDRY_PROFILE=deep`, corpus cache) | nightly | no, opens an issue | ubuntu-latest | 90 | 45 | campaign `timeout = 1800` per invariant test plus build |
| `medusa` (3300 s) | nightly | no, opens an issue | ubuntu-latest | 75 | 60 | fixed by `timeout` |
| `echidna` (assertion, then property) | nightly | no, opens an issue | ubuntu-latest | 150 | 120 | 2 x 3300 s |
| `symbolic-forge` (`forge test --symbolic`, profile `verify`) | nightly | no | ubuntu-latest | 120 | 60 | preview feature; per-test `timeout = 120` |
| `halmos` | nightly | no, then blocking once stable | ubuntu-latest | 150 | 90 | Not verified: solver time dominates |
| `hevm` (`prove` on the formal suite) | nightly | no | ubuntu-latest | 120 | 60 | `--smt-timeout 300` per query |
| `slither-full`, `wake-detect` | weekly | no | ubuntu-latest | 30 | 10 | Not verified |
| `mutation` (matrix by contract group) | weekly, on demand | no; score ratchet | ubuntu-latest | 360 | 180 | Not verified: unknown mutant count; shard with `--mutate-path` |
| `brutalize` (`FOUNDRY_PROFILE=brutalize`, size limit lifted) | weekly, on demand | yes on demand | ubuntu-latest | 60 | 10 | Not verified |
| `mythril` (image pinned by digest; four runtimes, 30 min each) | weekly, release tag, on demand | no, opens an issue | ubuntu-latest | 150 | 120 | fixed by the per-runtime timeout; Not verified: the PUSH0-bearing runtime runs |
| `measure` (one `kontrol build` and one proof, `/usr/bin/time -v`, `df`) | on demand | no | ubuntu-latest | 360 | 120 | Not verified: B02 Step 0 replaces the estimate |
| `kontrol` (Docker image pinned by digest) | release tag, on demand | release gate | ubuntu-latest (16 GB) | 360 | 240 | tool docs: 30 min to 1 h first build, 16 GB RAM; hours per proof |
| `equivalence` (`hevm equivalence`, per refactor PR label) | on demand | release gate | ubuntu-latest | 120 | 30 | `--smt-timeout 600` per function |
| `scribble-pilot` | on demand | no | ubuntu-latest | 60 | 20 | Not verified |

Every non-blocking nightly job writes its artifacts (corpus, coverage, SARIF, JSON) and, on failure, opens or updates one GitHub issue per tool with the reproducer path (those jobs need `issues: write`). Blocking status is decided per tool after two clean weeks.

### 9.2 `.github/workflows/static.yml` (PR gate)

```yaml
name: static
on:
  pull_request:
  push: { branches: [main] }
permissions: { contents: read }
concurrency: { group: "static-${{ github.ref }}", cancel-in-progress: true }

jobs:
  fmt-lint-build:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: { submodules: recursive, persist-credentials: false }
      - uses: foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09 # v1.9.1
        with: { version: v1.8.3 }
      - run: forge --version && forge fmt --check
      - run: forge build --sizes
      - run: forge lint
        continue-on-error: true      # 261 warnings in src/ today (02-BASELINE.md 3.4); make blocking after the exclude_lints triage

  solhint:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: { persist-credentials: false }      # solhint reads sources only, no submodules needed
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with: { node-version: 22 }
      # ratchet (master plan 2.2 row 21): fail only when the warning count exceeds the committed baseline; after B02 the baseline
      # is the triaged count (0 once the config decisions of 8.4 are recorded). Nothing is ever added to src/ to silence a rule.
      - run: |
          n=$(npx --yes solhint@6.2.4 'src/**/*.sol' --disc --noPoster -f json | jq '[.[].reports[]?] | length')
          base=$(jq '.warnings' spec/baseline/static/solhint.json)
          echo "solhint warnings in src: $n (baseline $base)"; [ "$n" -le "$base" ]
        # Not verified: the JSON shape of `solhint -f json`; confirm on the first run and adapt the jq filter
      - run: npx --yes solhint@6.2.4 -c test/.solhint.json 'test/**/*.sol' --disc --noPoster
      - run: '! grep -rn "solhint-disable" src'                     # 2.2 row 21: the source carries no disable comment

  slither:
    runs-on: ubuntu-latest
    timeout-minutes: 20
    permissions: { contents: read, security-events: write }
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: { submodules: recursive, persist-credentials: false }
      - uses: foundry-rs/foundry-toolchain@908c540300062bd5a7e473851cdb4282204cee09 # v1.9.1
        with: { version: v1.8.3 }
      - uses: actions/setup-python@5fda3b95a4ea91299a34e894583c3862153e4b97 # v7.0.0
        with: { python-version: "3.12" }
      - run: python -m venv .venv-slither && .venv-slither/bin/pip install slither-analyzer==0.11.6
      - name: Slither (ratchet from B01, fails on Medium and High after B02's triage)
        env: { FOUNDRY_OUT: out-slither, FOUNDRY_CACHE_PATH: cache-slither }
        # B01: drop `fail_on` from the config for this job, write slither.json, compare the per-detector counts with
        # spec/baseline/static/slither.json (tools/static/ratchet.py); B02 restores fail_on "medium" with slither.db.json.
        run: .venv-slither/bin/slither . --config-file slither.config.json
      - if: always()
        uses: github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v4.38.2
        with: { sarif_file: slither.sarif, category: slither }

  aderyn:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    permissions: { contents: read, security-events: write }
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with: { submodules: recursive, persist-credentials: false }
      - uses: actions/setup-node@820762786026740c76f36085b0efc47a31fe5020 # v7.0.0
        with: { node-version: 22 }
      - run: npm install --global --ignore-scripts @cyfrin/aderyn@0.6.8
      - run: aderyn . -o aderyn.json --skip-update-check && aderyn . -o aderyn.sarif --skip-update-check
      # Aderyn exits 0 on findings; gate on the JSON. B01: compare the High count with spec/baseline/static/aderyn.json
      # (ratchet, non-blocking); B02: after the exclusions triage this line becomes the blocking gate.
      - run: jq -e '.high_issues.issues | length == 0' aderyn.json
      - if: always()
        uses: github/codeql-action/upload-sarif@2892aa5e19bbd11bc0cff5427e3b750a04d9e3c2 # v4.38.2
        with: { sarif_file: aderyn.sarif, category: aderyn }
```

Existing `test.yml` changes (not a rewrite): (1) replace `version: stable` at `.github/workflows/test.yml:22` with `v1.8.3`, and the two action refs with the SHAs above; (2) run `forge fmt` once on the tree, commit, so the first job passes; (3) split "Unit tests" into `unit` (default profile) and `invariant-ci` (`FOUNDRY_PROFILE=ci`) after the `requestPayout` handler guard of section 2; (4) keep `Fork tests` on `push` to `main` and schedule only, with `ARBITRUM_RPC_URL` and `ROBINHOOD_RPC_URL` archive secrets and re-pinned `ARBITRUM_FORK_BLOCK` and `ROBINHOOD_FORK_BLOCK` (`docs/REVIEW-LOG-2026-09-29.md:20`); (5) submodule cost: 70 s per job today, cache `.git/modules` or use `git submodule update --init --recursive --depth 1`.

### 9.3 `.github/workflows/nightly.yml` (schedule `17 2 * * *`, plus `workflow_dispatch`)

Same header as 9.2 with `on: { schedule: [{ cron: "17 2 * * *" }], workflow_dispatch: {} }`. Jobs (only the tool-specific steps are shown; each job starts with the checkout and toolchain steps of 9.2):

```yaml
  medusa:
    runs-on: ubuntu-latest
    timeout-minutes: 75
    steps:
      # checkout, foundry-toolchain v1.8.3, setup-python as in static.yml, then:
      - run: python -m venv .venv-fuzz && .venv-fuzz/bin/pip install slither-analyzer==0.11.6 && echo "$PWD/.venv-fuzz/bin" >> "$GITHUB_PATH"
      - name: Install Medusa 1.5.1 (sha256 from the release digest)
        run: |
          curl -fsSL -o medusa.tgz https://github.com/crytic/medusa/releases/download/v1.5.1/medusa-linux-x64.tar.gz
          echo "ddfe1517ae9028ef9fc331b00f5a6a9d5406f3fcd11a715d60c6b6fb3e4546d3  medusa.tgz" | sha256sum -c -
          tar -xzf medusa.tgz medusa && sudo install -m 755 medusa /usr/local/bin/medusa    # Not verified: archive layout
      - uses: actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9 # v6.1.0
        with:
          path: medusa-corpus
          key: medusa-${{ hashFiles('test/fuzz/**', 'src/**') }}-${{ github.run_id }}
          restore-keys: medusa-${{ hashFiles('test/fuzz/**', 'src/**') }}-
      - run: medusa fuzz --config medusa.json            # exit code is non-zero when a test failed (cmd/fuzz.go:173-176)
      - if: always()
        uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with: { name: medusa-report, path: "medusa-corpus/**/*.lcov\nmedusa-corpus/**/*.html\ncrytic-export/**" }

  echidna:
    runs-on: ubuntu-latest
    timeout-minutes: 150
    steps:
      # checkout, foundry, setup-python, venv with slither-analyzer==0.11.6 as above, then:
      - name: Install Echidna 2.3.3
        run: |
          curl -fsSL -o echidna.tgz https://github.com/crytic/echidna/releases/download/v2.3.3/echidna-2.3.3-x86_64-linux.tar.gz
          echo "436d26cb5af34c6c525812b857ac53f218c7f6ad07d69495ef88bc4cdc85c764  echidna.tgz" | sha256sum -c -
          tar -xzf echidna.tgz && sudo install -m 755 echidna /usr/local/bin/echidna       # Not verified: archive layout
      - run: echidna . --contract CoreVaultProperties --config echidna.yaml --test-mode assertion --timeout 3300
      - run: echidna . --contract CoreVaultProperties --config echidna.yaml --test-mode property --timeout 3300 --corpus-dir echidna-corpus-prop

  halmos:
    runs-on: ubuntu-latest
    timeout-minutes: 150
    env: { HALMOS_ALLOW_DOWNLOAD: "1", FOUNDRY_PROFILE: verify }
    steps:
      # checkout, foundry
      - uses: astral-sh/setup-uv@c18668ad3cf93ea998bef934396af7bb5c839dc7 # v10.2.0
      - run: uv tool install --python 3.12 halmos==0.3.3
      - run: forge build --ast && halmos --config halmos.toml

  hevm:
    runs-on: ubuntu-latest
    timeout-minutes: 120
    env: { FOUNDRY_PROFILE: verify }
    steps:
      # checkout, foundry
      - run: sudo apt-get install -y z3
      - run: |
          curl -fsSL -o hevm https://github.com/argotorg/hevm/releases/download/release/0.58.0/hevm-x86_64-linux
          echo "7d6da60cfaa5cfe326cef8e4dffc1fb66595c60a325d86921f393bbf5cea275c  hevm" | sha256sum -c - && chmod +x hevm && sudo mv hevm /usr/local/bin/
      - run: forge clean && forge build --ast
      - run: hevm test --root . --project-type Foundry --prefix check --match Formal --solver z3 --num-solvers 3 --smt-timeout 300 --only-deployed 2>&1 | tee hevm.log; ! grep -E '\[(FAIL|WARN)\]' hevm.log

  deep-forge:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    env: { FOUNDRY_PROFILE: deep }
    steps:
      # checkout, foundry; cache path cache/corpus and cache/failures keyed by hashFiles('test/**', 'src/**')
      - run: forge test --no-match-path 'test/fork/**' --json > deep.json

  coverage:
    runs-on: ubuntu-latest
    timeout-minutes: 30
    steps:
      # checkout, foundry
      - run: forge coverage --ir-minimum --no-match-path 'test/fork/**' --report lcov --report-file lcov.info
      - run: python3 tools/coverage_ratchet.py lcov.info ci/coverage-baseline.json   # fails when branch coverage drops below the stored baseline
```

The `hevm` job uses z3 (installed with `apt`) for the first runs; switch `--solver` to bitwuzla once a pinned binary is added (the hevm docs recommend it). `tools/coverage_ratchet.py` sums `BRF`/`BRH` for `src/` files exactly as the measurement in section 2 and starts from 83.7 % branches; the baseline file is edited only in a PR that explains the change. `forge test --symbolic` runs in a further `symbolic-forge` job with `FOUNDRY_PROFILE=verify forge test --symbolic --match-path 'test/formal/**'`.

### 9.4 `.github/workflows/release-gate.yml` (`workflow_dispatch` and tags `v*`)

Jobs and their single commands (each preceded by checkout and the Foundry pin):
- `mutation`, matrix over `src/core/**`, `src/spoke/**`, `src/libraries/**`, `src/adapters/**`, `src/factory/**`, `src/report/**`, `src/mandate/**`: `FOUNDRY_PROFILE=mutate forge test --mutate --mutate-path '<glob>' --mutation-jobs 4 --no-match-path 'test/fork/**' --json > mutation.json`; gate: no surviving mutant in `src/libraries/**` and `src/core/**` without an accepted-survivor entry (`mutation-accepted.json`, each with a reason).
- `brutalize`: `FOUNDRY_PROFILE=brutalize forge test --brutalize --no-match-path 'test/fork/**'` (size limit lifted; AB excluded if its compile check fails).
- `mythril`: `bash tools/static/mythril-run.sh --ci` (section 8.11); `solc-bugs`: `python3 tools/release/solc-bugs.py` (master plan A53).
- `kontrol`: `docker run --rm -v "$PWD:/workspace" runtimeverificationinc/kontrol@sha256:<digest> bash -lc 'kontrol build && kontrol prove --config-file kontrol.toml'` (digest recorded at adoption; flags per section 8.9).
- `equivalence`: section 8.10 step 3 against the previous release tag.
- `slither-full`, `wake-detect`: sections 8.2 and 8.5 (`slither --config-file slither.full.json`, `wake detect all --export sarif`).
- `scribble-pilot`: `bash tools/scribble-run.sh`.
- `fork-pinned`: fork suites with re-pinned archive blocks recorded in the release notes.

## 10. Verdict table and order of adoption

Verdict vocabulary: ADOPT in CI (runs on every PR), ADOPT nightly, ADOPT on demand (release gate or explicit request), SKIP.

| # (order) | Tool | Verdict | Where it runs | Why | Exit plan or kill criterion |
|---|---|---|---|---|---|
| 1 | **Foundry / forge** | ADOPT in CI, plus nightly and weekly features | PR: fmt, lint, build, unit, invariant-ci. Nightly: deep campaigns, coverage ratchet, `--symbolic`. Weekly: `--mutate`, `--brutalize` | Already the test base (654 passing unit tests, 97.3 % line and 83.7 % branch coverage measured); v1.8 adds symbolic, mutation, brutalize, lint natively | If `--symbolic` or `--mutate` proves unstable on v1.8.3, keep them non-blocking and rely on Halmos, hevm and Slither mutate |
| 2 | **Solhint** | ADOPT in CI | PR | Cheap, enforces NatSpec, naming, custom-error and justified-assembly rules that Slither does not | Drop rules that duplicate `forge lint` after one month; keep `use-natspec` and the reason-on-disable check |
| 3 | **Slither** | ADOPT in CI (PR gate at Medium and High) and weekly full run | PR, weekly | Best static coverage for known patterns; already used on the module branches; SARIF to code scanning | None; it is the anchor of the static layer |
| 4 | **Aderyn** | ADOPT in CI, gated on High only | PR | Second AST implementation in seconds; JSON gate | Slower cadence (last release 2026-01-22): if a solc or AST change breaks it, demote to nightly or drop in favour of `forge lint` |
| 5 | **Medusa** | ADOPT nightly, with a 10 minute smoke on PRs touching `src/` or `test/fuzz/` | Nightly, PR smoke | Primary stateful fuzzer: auto-links the two libraries, panic classes, corpus persisted, fork mode | Harness cost is shared with Echidna; if it cannot deploy the system, fall back to `forge` invariants with the `deep` profile |
| 6 | **Echidna** | ADOPT nightly | Nightly | Different engine and mutation strategy (hevm), assertion and property modes, `verification` mode, foundry reproducers | Library support is the risk (issue #651 wont fix): if `--compile-autolink` and `deployContracts` both fail, keep Medusa only |
| 7 | **Halmos** | ADOPT nightly (pinned 0.3.3, non-blocking until stable) | Nightly on `test/formal/**` | Mature source-level symbolic testing with Foundry syntax, `loop`, `svm` cheatcodes; runs the pure libraries and single-transaction properties | Stale (last release 2025-07-31): every `check_*` also runs under `forge test --symbolic` and hevm; drop Halmos if a 0.8.28 construct fails and no release follows |
| 8 | **hevm** | ADOPT on demand (refactor equivalence, release candidates) and nightly `prove` on the formal suite once the harness exists | On demand, nightly | Active, arm64 binary, equivalence checking is unique, shares its engine with Echidna | Symbolic `CREATE2` and unlinked libraries limit scope (`FundFactory`); fall back to Halmos |
| 9 | **Kontrol** | ADOPT on demand (release gate) | Release tags, 16 GB runner | Bytecode-level proof with formal EVM semantics for the custody core; broadest cheatcode set | Needs 16 GB RAM, lemma effort measured in days; stop at the modules where the first proof does not converge in two working days and keep the Halmos and hevm result |
| 10 | **Wake** | ADOPT on demand (detectors only); SKIP Python fuzzing | Weekly job or audit prep | Unique `invalid_memory_safe_assembly` and a fourth detector opinion | Rosetta on Apple Silicon, slower cadence, newest solc lags: drop after two runs without a unique true finding |
| 11 | **Scribble** | ADOPT on demand as a one day pilot | On demand, instrumented copy only | Per-function pre and post conditions on every fuzz and test call without harness code | Dormant (last release 2025-04-09): drop if any `src/` file fails to instrument or the copy fails to build |
| 12 | **Mythril** | ADOPT weekly and at release, bounded (30 min per runtime), on ManagerFeeVault, ManagerRegistry, TransitEscrow, ChainlinkPriceSource and their Scribble copies; SKIP on every runtime that contains MCOPY and on CoreVault (delegates to a library that has MCOPY) | Weekly job and release gate, `mythril/myth` image pinned by digest | The four runtimes contain no MCOPY (scan, decision 4) and Mythril implements PUSH0, TLOAD, TSTORE; its exceptions module reports reachable asserts and Panics, which is how CF-R2 would be found; no release since 2024-03-27, overlaps Slither and hevm, carries no registry property | Drop if the pinned image fails on the PUSH0-bearing runtime or finds nothing in two runs; the job fails closed if `0x5E` ever appears in an analysed runtime |
| 13 | **Manticore** | SKIP | none | Archived 2026-06-24, no PUSH0, MCOPY or TLOAD | none |

Order and calendar (at most two agents at a time, executors report to the coordinator):
- **Step 0 (1 to 2 days):** section 11. Pin Foundry v1.8.3, run `forge fmt`, guard the `requestPayout` handler, upgrade the local toolchain, measure every tool once.
- **Week 1:** 1 Foundry PR jobs, 2 Solhint, 3 Slither, 4 Aderyn (all four are configuration, no harness).
- **Weeks 2 and 3:** 5 Medusa and 6 Echidna on one shared `test/fuzz/` harness (two agents: one writes handlers and properties per module, one wires tools and CI), Foundry `deep`, coverage ratchet, mutation and brutalize baseline.
- **Weeks 3 to 5:** 7 Halmos and forge symbolic on the pure libraries first, then single-transaction properties of `CoreVault` and `SpokeVault` functions; 8 hevm on the same specs and the first equivalence run.
- **Week 5 onward:** 9 Kontrol on `ShareMath` and `IncomeAccumulator` first, then the custody paths (`deposit`, payout, income collection); 10 Wake and 11 Scribble on demand.

## 11. Step 0 spike: everything marked "Not verified" and how to close it

| Not verified | Confirm by | Pass criterion |
|---|---|---|
| Foundry v1.8.3 is compatible with the 654 tests and `forge fmt` output | Install v1.8.3 with `foundryup` in a separate worktree, run default profile, `--no-isolate`, `forge fmt --check` | zero failures or a listed diff |
| The `ZeroSharePrice` failures are a harness defect only | Owner of DEC-035 and the share-price-zero rule reviews `test/unit/core/CoreVaultInvariant.t.sol:55-62` and `ShareMath.sol:72,89` | agreed guard; `FOUNDRY_PROFILE=ci` green in 20 consecutive runs |
| Slither 0.11.6 runs on `e5c778a`; counts per detector; reentrancy detectors vs `nonReentrant`; env override names | `slither . --config-file slither.config.json --timing` | finding list with triage; runtime recorded |
| Aderyn parses `transient` and `assembly ("memory-safe")` | `aderyn . -o aderyn.json` | exit 0 |
| Solhint rule set on this code base (`private-vars-leading-underscore` on constants, NatSpec adherence) | `npx solhint@6.2.4 'src/**/*.sol'` | counts per rule; decide `error` or `warn` |
| `forge lint` exit code and overlap with Slither and Aderyn | run on `src/` and diff against their findings | table of unique findings |
| Wake compiles with `lib` in `exclude_paths` | `wake compile` then `wake detect all` | detections listed |
| Echidna: autolink with the Foundry platform, archive layout, exit code | 3-property harness on `ShareToken` plus one `CoreVault` deposit through the linked library | properties run, library call succeeds |
| Medusa: end-to-end library deployment, TSTORE path (`_unwinding`) | same harness | coverage shows `CoreVaultLogic` lines |
| Halmos: linking through DELEGATECALL, MCOPY concrete size, exit code | `check_` on `ShareMath` then a `deposit` check | PASS or an explained counterexample |
| hevm: `type(Lib).runtimeCode`, generated constants route, exit codes, `forge inspect ... deployedBytecode` field name | same spec via `hevm test`; `forge inspect --help` | spec passes; exit code documented |
| `forge test --symbolic`: library linking, runtime on the same spec | `FOUNDRY_PROFILE=verify forge test --symbolic --match-test check_` | same verdict as Halmos |
| Kontrol: Apple Silicon support, Docker tags, `match-test` semantics, memory | one `kontrol build` and one proof on the real `ubuntu-latest` runner (16 GB RAM, 14 GB disk) through `measure.yml` (B01 skeleton on `main`, B02 run), `/usr/bin/time -v`, `df`, image size | build time, peak RSS, disk and proof time recorded in `spec/baseline/tool-measurements.md`; peak RSS at most 14 GB, disk at most 12 GB and a proof inside 6 h, else the G1 fallback and the F-6 trigger (master plan 2.2 row 22) |
| Mythril on MFV, MR, TE, CLPS: flag form for runtime bytecode, image digest, whether its exceptions module reports `Panic(0x11)` | read `mythril/interfaces/cli.py` and `mythril/analysis/module/modules/exceptions.py` at the pinned version, run the 30-minute job once on ChainlinkPriceSource | job completes on the PUSH0-bearing runtime; CF-R2 re-found or recorded as a tool limit |
| `forge test --brutalize` compiles AB and SpokeVault under `[profile.brutalize]` (size limit lifted) | one run of `FOUNDRY_PROFILE=brutalize forge test --brutalize --match-path 'test/unit/across/**'` | compiles, or AB is excluded with the log recorded |
| `forge test --mutate` combined with `--symbolic` | one run on `src/libraries/ShareMath.sol` with a `check_` file | result recorded; if unsupported, mutation reaches the formal suites only through hand-written mutants (master plan 4.6) |
| Scribble instruments all of `src/` | `bash tools/scribble-run.sh` | instrumented copy builds and tests pass |
| Mutation cost | `forge test --mutate --mutate-path src/libraries/ShareMath.sol --mutation-jobs 4` | mutants per minute, score |
| Runtime and memory of every tool on the 8 GB machine and on `ubuntu-latest` | `/usr/bin/time -l` locally, job summaries in CI | replace the estimates in section 9.1 |

## 12. Sources (all read 2026-09-30)

Repositories were shallow-cloned or read through the GitHub API on 2026-09-30; the commit is the read point. Release data, digests and asset lists come from the GitHub Releases API on the same day.

- [S1] Slither: https://github.com/crytic/slither (commit eef5df9, 2026-08-06), wiki https://github.com/crytic/slither/wiki/Usage (commit 775a1a5), https://pypi.org/project/slither-analyzer/
- [S2] crytic-compile: https://github.com/crytic/crytic-compile (commit 3d27afa)
- [S3] slither-action: https://github.com/crytic/slither-action (commit b52cc1c, v0.4.2)
- [S4] Aderyn: https://github.com/Cyfrin/aderyn (commit de6a090), https://www.npmjs.com/package/@cyfrin/aderyn, AST library https://github.com/Cyfrin/solidity-ast-rs (tag v0.0.1-alpha.beta.7)
- [S5] Solhint: https://github.com/protofire/solhint (commit fc259bc), https://protofire.github.io/solhint/, parser changelog https://github.com/solidity-parser/parser/blob/master/CHANGELOG.md
- [S6] Wake: https://github.com/Ackee-Blockchain/wake (commit 9089173), docs under `docs/` in that repository
- [S7] Echidna: https://github.com/crytic/echidna (commit 5403657): README, CHANGELOG, `tests/solidity/basic/default.yaml`, `src/Main.hs`, `lib/Echidna/*.hs`
- [S8] Foundry: https://github.com/foundry-rs/foundry (releases v1.8.0 and v1.8.3, `crates/config/src` at tag v1.8.3, `crates/forge/src/cmd/coverage.rs` at v1.8.3), https://getfoundry.sh/forge/advanced-testing/overview/, https://getfoundry.sh/guides/symbolic-testing, https://getfoundry.sh/guides/mutation-testing, https://github.com/foundry-rs/foundry-toolchain
- [S9] Medusa: https://github.com/crytic/medusa (commit 87f65e2): `docs/src/**`, `fuzzing/fuzzer.go`, `chain/test_chain.go`, `cmd/fuzz.go`
- [S10] Halmos: https://github.com/a16z/halmos (commit 079bb42), wiki https://github.com/a16z/halmos/wiki/FAQ and https://github.com/a16z/halmos/wiki/Supported-Foundry-Cheatcodes, issues and pull requests via the GitHub API
- [S11] Mythril: https://github.com/ConsenSysDiligence/mythril (commit 125914a), https://pypi.org/project/mythril/
- [S12] Manticore: https://github.com/trailofbits/manticore (archived 2026-06-24)
- [S13] hevm: https://github.com/argotorg/hevm (commit c39757a): `CHANGELOG.md`, `doc/src/*.md`, `cli/cli.hs`, `src/EVM/Solidity.hs`; book https://hevm.dev/ (not fetched)
- [S14] Kontrol: https://github.com/runtimeverification/kontrol (commit 75bb958): `CLAUDE.md`, `deps/`, `src/kontrol/utils.py`; docs https://docs.runtimeverification.com/kontrol (overview, installations, linked-library-example, cheatcodes pages fetched); KEVM https://github.com/runtimeverification/evm-semantics (release v1.0.921)
- [S15] Scribble: https://github.com/ConsenSysDiligence/scribble (commit 8fef548), https://github.com/ConsenSysDiligence/solc-typed-ast (tags v18.2.5, v18.2.6, v20.0.9); docs https://docs.scribble.codes (not fetched)
- [S16] GitHub docs: https://docs.github.com/en/actions/reference/runners/github-hosted-runners, https://docs.github.com/en/actions/reference/limits, https://docs.github.com/en/billing/managing-billing-for-your-products/about-billing-for-github-actions
- [S17] Contracts repository CI history: https://github.com/PoolPartyLabs/smartcontract-v2 run 36713951710 (via `gh run view`), 2026-09-30

Contracts repository facts: commit `e5c778a`, clone read-only; measurements in section 2 ran there with Foundry 1.0.0 (`forge test`, `forge coverage --ir-minimum`), artifacts only (`out/`, `cache/`), the persisted invariant failure files created by the replay were removed afterwards.

