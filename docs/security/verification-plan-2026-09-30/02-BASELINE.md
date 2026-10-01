# 02 Baseline: what Foundry alone says about the contracts at e5c778a

Date measured: 2026-09-30. Scope: unit, fuzz and invariant tiers plus build and the built-in linter; the fork tier is listed, not run. Every number below comes from a command run on that date; raw lines are in Appendix A.

## 0. Reading notes

- Clone: `PoolPartyLabs/smartcontract-v2` at `e5c778a` ("merge: feat/pp-sc-feat-integration into main"), read-only, `git status` clean after all runs. Build artifacts, logs and lcov went to the scratchpad or to `out/` and `cache/`.
- Two Foundry builds were used, because the machine's default `forge` changed while this baseline was being measured. Runs made between 13:49 and 14:02 used `forge 1.0.0-v1.0.0` (commit `8692e926198056d0228c1e166b1b6c34a5bed66c`, built 2025-02-10), the version the coordinator found installed. At 14:06 the default became `forge 1.8.3` (commit `cae51ad458f6abb64852b7709eb784352429825d`, built 2026-09-15; the `~/.foundry/bin/forge` symlink is dated 2026-09-30 14:06 and was not changed by this task; the machine is shared with other sessions). I then re-ran everything that depends on the version. **Primary figures are forge 1.8.3**: it is what `forge` resolves to now, and CI installs `foundry-rs/foundry-toolchain@v1` with `version: stable` (`.github/workflows/test.yml`). The 1.0.0 figures are kept as a cross-check where they differ. Not verified: which version "stable" resolves to in CI today.
- Compile settings are the same in both: solc 0.8.28, `foundry.toml` default profile (evm cancun, optimizer 800 runs, `via_ir = false`, fuzz 512 runs, invariant 256 runs x depth 32, `fail_on_revert = true`). Machine: macOS arm64, 8 CPUs, 8 GB (coordinator facts), shared with other sessions, so wall times vary between runs.
- Two counts must not be mixed: "declared" (test functions in `test/unit`, by grep) and "executed" (what `forge test` ran). They differ by 27 because two suites inherit another suite (section 2). Forge 1.0.0 counts each invariant as a test (654); forge 1.8.3 counts each invariant suite as one test (644); the same 14 invariants pass under both.
- Coverage was measured with `--ir-minimum` (optimizer off, viaIR minimum), which is not the deployed compile. Forge warns this "can result in inaccurate source mappings"; section 3.1 says which zero-hit entries this made unreliable.
- A "by-name reference" count in section 5 is an upper bound on direct calls: it counts `name(`, `.name.selector` and `.name,` in `test/unit` and `test/fork`, so a name shared with a mock or an ERC20 inflates it. A count of 0 is exact; a count of 1 or 2 was checked by hand.

## 1. Commands run

All commands in the clone, all with the default profile unless the command says otherwise.

| # | Command | forge | Wall time | Result |
|---|---|---|---|---|
| 1 | `forge test --no-match-path "test/fork/**"` | 1.0.0 | 6.16 s (forge 5.34 s, 27.38 s CPU) | 53 suites, 654 passed, 0 failed, 0 skipped |
| 1 | same | 1.8.3 | 1 min 58.42 s (100.26 s of it is the solc recompile after the version change; forge 9.33 s, 44.21 s CPU) | 53 suites, 644 passed, 0 failed, 0 skipped |
| 2 | `FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/**"` | 1.0.0 | 25.07 s (forge 23.67 s) | 654 passed; fuzz 2000 runs, invariants 512 runs x 48 depth = 24,576 calls |
| 2 | same | 1.8.3 | 30.39 s (forge 26.93 s) | 644 passed; same run counts |
| 3 | `forge coverage --no-match-path "test/fork/**" --report summary` | 1.0.0 / 1.8.3 | 5.2 s / 2.47 s | both: compiler fails ("Stack too deep" in inline assembly), no numbers |
| 4 | `forge coverage --ir-minimum --no-match-path "test/fork/**" --report summary` | 1.0.0 | 2 min 33.64 s (solc 129.70 s) | 654 passed, per-file table |
| 4 | same | 1.8.3 | 5 min 41.20 s (solc 281.23 s; CPU 52%, machine busy) | 644 passed, per-file table (section 3) |
| 5 | `forge coverage --ir-minimum --no-match-path "test/fork/**" --report lcov --report-file <scratchpad>/lcov.info` | 1.0.0 | 2 min 1.95 s | LCOV parsed for BRDA, FNDA, DA of `src/` |
| 5 | same | 1.8.3 | 5 min 46.68 s | LCOV parsed; sections 4 and 5 use this one |
| 6 | `forge build --sizes` | 1.0.0 / 1.8.3 | 0.61 s (cached) / after run 7 | identical sizes in both (section 8) |
| 7 | `forge build --force` | 1.0.0 | 30.3 s (solc 29.48 s, 268 files) | success; 4 solc warnings, all in `test/` |
| 7 | same | 1.8.3 | 2 min 29.70 s (solc 143.79 s, machine busy) | success; same 4 solc warnings, plus 291 inline lint warnings (section 3.4) |
| 8 | `forge build <path> --optimize false --force --out <scratchpad>/out-noopt --cache-path <scratchpad>/cache-noopt`, once per `src/` file, then per test and mock file | 1.8.3 (an earlier pass straddled the version change and gave the same file) | several minutes in total | only `src/adapters/AcrossBridgeAdapter.sol` fails (section 3.1); adding `--via-ir` to that one makes it compile |
| 9 | `forge lint` | 1.8.3 (the 1.0.0 `--help` lists no `lint` subcommand) | 2.25 s | 291 warnings (261 in `src/`, 30 in `test/`), 0 errors (section 3.4) |

Coverage stayed far below the 20 minute limit, so nothing was cut short. `--ir-minimum` was added only after run 3 failed, on both versions.

Foundry documentation read on 2026-09-30: https://raw.githubusercontent.com/foundry-rs/foundry/master/crates/forge/src/cmd/coverage.rs (source of `forge coverage`; says `--ir-minimum` enables viaIR with minimum optimization to avoid stack too deep while keeping relatively accurate source maps, and that by default optimizer and viaIR are disabled for coverage). The book page https://book.getfoundry.sh/reference/forge/forge-coverage redirected to https://getfoundry.sh/reference/forge/forge-coverage, which returned 404. Forge 1.8.3 prints the same guidance and links https://book.getfoundry.sh/guides/best-practices/stack-too-deep (not fetched). Not verified: the lcov `BRDA` semantics used in section 4.1.

## 2. Test suite result (unit, fuzz, invariant)

- All pass, none skipped, zero `[FAIL]` or `[SKIP]` lines, under both versions. No suite needed fixing. Executed: 586 `test_` + 54 `testFuzz_` + 14 `invariant_` = 654 (forge 1.0.0 counting); forge 1.8.3 reports 644 because it counts the 4 invariant suites once each.
- Declared in `test/unit` (grep of function names): 560 `test_`, 53 `testFuzz_`, 14 `invariant_` = 627. The 27 extra executions are `AaveV3AdapterHalfUpRoundingTest is AaveV3AdapterTest` (`test/unit/aave/AaveV3Adapter.t.sol:541`, reruns 25 `test_`) and `AaveV3AdapterLifecycleHalfUpTest is AaveV3AdapterLifecycleTest` (`test/unit/aave/AaveV3AdapterLifecycle.t.sol:115`, reruns 1 `test_` and 1 `testFuzz_`). The coordinator's figure of 612 `test_` includes the 52 declared in `test/fork`.
- All 54 fuzz executions ran 512 runs in the default profile and 2000 in `ci`; all 14 invariants ran 256 runs, 8,192 calls, 0 reverts (default) and 512 runs, 24,576 calls, 0 reverts (`ci`), on both versions.
- The full `ci` profile costs about 25 to 30 s wall on this machine. The fuzz and invariant budget can grow by one to two orders of magnitude before it becomes a scheduling problem for the 2-agent limit.
- `reverts: 0` on the invariants is partly by construction: `CoreVaultHandler` bounds its inputs and wraps `deposit`, `claimPayout` and `allocateToHubSpokeVault` in `try ... catch {}` (`test/unit/core/CoreVaultInvariant.t.sol:51`, `:70`, `:103`), so a revert inside those calls is discarded rather than counted.
- Forge 1.8.3 prints a per-handler call table for each invariant suite (Appendix A.2). Every action is called with near-uniform frequency: `CoreVaultHandler` 840 to 944 calls per action over 9 actions (`allocate` 944, `claim` 898, `deposit` 916, `donate` 882, `forwardIncome` 912, `movePrice` 928, `requestPayout` 935, `warp` 937, `withdrawIncome` 840); `SpokeVaultHandler` 557 to 643 over 14 actions; `IncomeAccumulatorHandler` 1,996 to 2,081 over 4; `ShareTokenHandler` 1,614 to 1,674 over 5; all with 0 reverts and 0 discards. These count entries into the handler function, not effective state changes: several handlers return early when they have nothing to act on (`claim` without an open request, `refund` with nothing sent, `close` without a position), and no ghost counter measures the effective rate. Not verified: how many of the 8,192 calls per suite change state.

## 3. Coverage of `src/` (unit, fuzz and invariant tiers only)

### 3.1 Why `--ir-minimum`, and what it costs

- Without it, `forge coverage` aborts at compile time on both forge versions ("Stack too deep ... When compiling inline assembly: Variable value0 is 1 slot(s) too deep", run 3). Bisecting with `--optimize false` (run 8) shows the cause is production code, not test code: `src/adapters/AcrossBridgeAdapter.sol` is the only `src/` file that does not compile with the optimizer off. The construct is the 12-argument `abi.encodeCall(IAcrossSpokePool.depositV3, (...))` in `buildSend` (`AcrossBridgeAdapter.sol:107-125`). Not verified: that this exact expression is the trigger (confirm by splitting the call and recompiling). With `--via-ir` and the optimizer off the file compiles.
- Consequence 1: the deployed build depends on the optimizer (800 runs, `via_ir = false`) to fit this function. Any verification tool that recompiles with the optimizer off, or with defaults different from `foundry.toml`, will fail on this file. Every tool in the plan must be pinned to the default Foundry profile or to an explicitly tested profile.
- Consequence 2: coverage is measured on a different compile than the bytecode that ships, and forge itself warns of possible inaccurate source mappings. Under forge 1.8.3 I found three kinds of false zeros: 1 else-branch entry whose else body has non-zero line hits (`SpokeVault.sol:151`, section 4.2), 18 first-statement lines (14 `_topUpOperatingCash();`, 4 `_requireEntryAllowed();`), 15 assembly lines in functions that ran, and 3 lines at the start or end of a body that must have run (section 4.3). Forge 1.0.0 was worse: 5 else-branch false zeros, one of which (`SpokeVault.sol:883`) I first read as a real gap before the 1.8.3 lcov showed the else path running twice. Numbers below keep every entry as forge printed it; the tables mark the artifacts.
- Forge counts test and mock files in its own total (1.8.3: 88.73% lines, 87.67% statements, 72.29% branches, 91.41% functions over 4,222 lines and 4,858 statements). Those figures are not about the contracts. The figures that matter are the `src/` rows below, summed by me from the same table.

### 3.2 Per-file table (27 `src/` files with executable code), forge 1.8.3

The other 18 files under `src/` (`core/CoreVaultTypes.sol`, `interfaces/FundTypes.sol`, 11 `interfaces/I*.sol`, 5 `interfaces/external/*.sol`) hold only declarations and do not appear in forge's table. "Branches missed" is total minus hit; the last column is the forge 1.0.0 value for the same file.

| File | Lines | Statements | Branches | Functions | Branches missed (1.8.3) | Branches missed (1.0.0) |
|---|---|---|---|---|---|---|
| `src/adapters/AaveV3Adapter.sol` | 97.38% (186/191) | 95.30% (223/234) | 79.07% (34/43) | 100.00% (26/26) | 9 | 4 |
| `src/adapters/AcrossBridgeAdapter.sol` | 100.00% (25/25) | 96.97% (32/33) | 80.00% (4/5) | 100.00% (5/5) | 1 | 0 |
| `src/adapters/AdapterGuard.sol` | 100.00% (15/15) | 100.00% (12/12) | 100.00% (5/5) | 100.00% (5/5) | 0 | 0 |
| `src/adapters/UniswapV4Adapter.sol` | 99.18% (243/245) | 98.47% (322/327) | 91.89% (34/37) | 100.00% (33/33) | 3 | 3 |
| `src/core/CoreVault.sol` | 98.23% (111/113) | 96.38% (133/138) | 90.32% (28/31) | 100.00% (8/8) | 3 | 3 |
| `src/core/CoreVaultBase.sol` | 97.87% (138/141) | 97.70% (170/174) | 87.50% (14/16) | 96.55% (28/29) | 2 | 2 |
| `src/core/CoreVaultIncome.sol` | 100.00% (41/41) | 92.50% (37/40) | 62.50% (5/8) | 100.00% (12/12) | 3 | 2 |
| `src/core/CoreVaultLogic.sol` | 96.32% (288/299) | 94.40% (388/411) | 87.88% (58/66) | 93.94% (31/33) | 8 | 7 |
| `src/core/CoreVaultTransit.sol` | 95.24% (40/42) | 87.50% (42/48) | 63.64% (7/11) | 100.00% (8/8) | 4 | 4 |
| `src/core/ManagerFeeVault.sol` | 100.00% (11/11) | 85.71% (12/14) | 33.33% (1/3) | 100.00% (3/3) | 2 | 2 |
| `src/core/ManagerRegistry.sol` | 100.00% (18/18) | 100.00% (18/18) | 100.00% (3/3) | 100.00% (6/6) | 0 | 0 |
| `src/core/ShareToken.sol` | 100.00% (19/19) | 100.00% (17/17) | 100.00% (4/4) | 100.00% (8/8) | 0 | 0 |
| `src/core/TransitEscrow.sol` | 100.00% (11/11) | 100.00% (14/14) | 100.00% (4/4) | 100.00% (3/3) | 0 | 0 |
| `src/factory/CodeStore.sol` | 89.29% (25/28) | 90.24% (37/41) | 66.67% (2/3) | 100.00% (2/2) | 1 | 1 |
| `src/factory/Create3.sol` | 90.00% (18/20) | 83.33% (20/24) | 60.00% (3/5) | 100.00% (5/5) | 2 | 2 |
| `src/factory/Create3Deployer.sol` | 100.00% (7/7) | 100.00% (6/6) | 100.00% (0/0) | 100.00% (3/3) | 0 | 0 |
| `src/factory/FundFactory.sol` | 97.26% (213/219) | 96.03% (266/277) | 78.95% (30/38) | 100.00% (24/24) | 8 | 8 |
| `src/libraries/IncomeAccumulator.sol` | 100.00% (91/91) | 100.00% (95/95) | 100.00% (20/20) | 100.00% (11/11) | 0 | 0 |
| `src/libraries/ReportCodec.sol` | 100.00% (9/9) | 100.00% (11/11) | 100.00% (2/2) | 100.00% (3/3) | 0 | 0 |
| `src/libraries/ShareMath.sol` | 92.31% (24/26) | 90.00% (27/30) | 100.00% (6/6) | 88.89% (8/9) | 0 | 0 |
| `src/libraries/TransitMessage.sol` | 100.00% (6/6) | 100.00% (7/7) | 100.00% (1/1) | 100.00% (2/2) | 0 | 0 |
| `src/mandate/Mandate.sol` | 100.00% (118/118) | 99.52% (206/207) | 97.44% (38/39) | 100.00% (16/16) | 1 | 1 |
| `src/report/ChainlinkPriceSource.sol` | 100.00% (41/41) | 87.93% (51/58) | 46.15% (6/13) | 100.00% (6/6) | 7 | 2 |
| `src/report/ValueReportReceiver.sol` | 100.00% (74/74) | 98.00% (98/100) | 88.24% (15/17) | 100.00% (14/14) | 2 | 1 |
| `src/spoke/SpokeCrossChainLib.sol` | 95.81% (160/167) | 96.04% (194/202) | 86.96% (20/23) | 100.00% (16/16) | 3 | 3 |
| `src/spoke/SpokeVault.sol` | 95.30% (385/404) | 91.65% (439/479) | 76.34% (71/93) | 100.00% (72/72) | 22 | 23 |
| `src/spoke/SpokeVaultTypes.sol` | 100.00% (2/2) | 100.00% (2/2) | 100.00% (0/0) | 100.00% (1/1) | 0 | 0 |
| **src/ total (27 files with executable code)** | **97.31% (2319/2383)** | **95.36% (2879/3019)** | **83.67% (415/496)** | **98.90% (359/363)** | **81** | **68** |

### 3.3 Reading the table

Totals of the `src/` rows for both versions (the two versions count branches and statements differently; the difference is in what forge instruments, not in the tests):

| `src/` total | forge 1.0.0 | forge 1.8.3 |
|---|---|---|
| Lines | 97.27% (2313/2378) | 97.31% (2319/2383) |
| Statements | 95.75% (2836/2962) | 95.36% (2879/3019) |
| Branches | 83.57% (346/414) | 83.67% (415/496) |
| Functions | 98.89% (357/361) | 98.90% (359/363) |

- Forge 1.8.3 finds 82 more branches than 1.0.0 (496 against 414): it instruments constructor guards that 1.0.0 did not list for `AaveV3Adapter`, `AcrossBridgeAdapter`, `ChainlinkPriceSource` and `ValueReportReceiver`, and it stops reporting five else-branches as unhit. Not verified: why the branch sets differ; the test suite and the compile are the same.
- Line and function coverage is high everywhere (97.31% lines, 98.90% functions); the gap is branches: 81 missed of 496 (16.3%).
- Branch gap by weight (1.8.3, 81 in total): `SpokeVault` 22 (71 of 93 hit, 76.34%), `AaveV3Adapter` 9, `FundFactory` 8, `CoreVaultLogic` 8, `ChainlinkPriceSource` 7, `CoreVaultTransit` 4, `CoreVault` 3, `CoreVaultIncome` 3, `UniswapV4Adapter` 3, `SpokeCrossChainLib` 3, then 2 each in `CoreVaultBase`, `ManagerFeeVault`, `Create3`, `ValueReportReceiver`, and 1 each in `AcrossBridgeAdapter`, `CodeStore`, `Mandate`.
- Files with fewer than 90% of branches hit: `ChainlinkPriceSource` (46.15%), `ManagerFeeVault` (33.33%), `Create3` (60.00%), `CoreVaultIncome` (62.50%), `CoreVaultTransit` (63.64%), `CodeStore` (66.67%), `SpokeVault` (76.34%), `FundFactory` (78.95%), `AaveV3Adapter` (79.07%), `AcrossBridgeAdapter` (80.00%), `SpokeCrossChainLib` (86.96%), `CoreVaultBase` (87.50%), `CoreVaultLogic` (87.88%), `ValueReportReceiver` (88.24%).
- Files at 100% of lines, statements, branches and functions: `AdapterGuard`, `ManagerRegistry`, `ShareToken`, `TransitEscrow`, `Create3Deployer`, `IncomeAccumulator`, `ReportCodec`, `TransitMessage`, `SpokeVaultTypes`. `AcrossBridgeAdapter` is no longer at 100% under 1.8.3 (its constructor zero-address guard is unhit).
- This is coverage by mocks: `CoreVault` runs against `MockHubSpokeVault`, `MockBridgeAdapter`, `MockReportReceiver`; `SpokeVault` against `MockCoreVault` and `MockPositionAdapter`; `UniswapV4Adapter` against `MockV4`. What the real protocols do is only in the fork tier (section 9), which this table excludes.

### 3.4 Built-in linter (`forge lint`, run 9)

The installed forge 1.8.3 has a `lint` subcommand; the forge 1.0.0 binary lists none in its `--help`. It reports 291 warnings and no errors: 261 in `src/`, 30 in `test/`. Per rule in `src/`: `require-revert-in-loop` 68 (`Mandate.sol` 20, `SpokeVault.sol` 17, `ChainlinkPriceSource.sol` 7, `FundFactory.sol` 6), `reentrancy-events` 50, `calls-loop` 31, `non-reentrant-not-first` 28 (`SpokeVault.sol` 14, `UniswapV4Adapter.sol` 6, `AaveV3Adapter.sol` 5), `uninitialized-local` 18, `unused-return` 15, `block-timestamp` 13, `unsafe-typecast` 11, `reentrancy-no-eth` 11 (`SpokeVault.sol` 6, `CoreVault.sol` 5), `boolean-cst` 10, `missing-zero-check` 3 (all `SpokeVault.sol`), `encode-packed-collision` 2 (`FundFactory.sol`), `divide-before-multiply` 1 (`CoreVaultLogic.sol`). None was triaged here; many are style-level. `reentrancy-no-eth` and `non-reentrant-not-first` are the first to triage because the design carves out a reentrancy exception for the hub Spoke Vault callbacks (`CoreVaultBase.sol:176`). `forge lint` is not in the founder's tool list and does not replace Slither or Aderyn; it is a free extra data point, and CI does not run it (forge 1.8.3 also prints the same warnings inline on every `forge build`). Not verified: the lint rule set and its version in this forge build (the output links to https://getfoundry.sh/forge/linting/ pages, not fetched).

## 4. Branches with zero hits, per file (forge 1.8.3 lcov)

### 4.1 How to read forge's lcov branches

Observed in `lcov.info`, not confirmed in Foundry documentation (Not verified: confirm in the Foundry source or docs): an `if (...) revert X();` with no `else` appears as one `BRDA` record, and its hit count equals the number of times the revert body ran. Example: `ManagerFeeVault.sol:26` (`BRDA:26,0,0,0` in 1.8.3, `-` in 1.0.0: the zero-address revert, never taken), `:39` (`BRDA:39,1,0,1`, `NotManager`, taken once), `:40` (`BRDA:40,2,0,0`, zero `to`, never taken). So most zero-hit entries below are "a guard whose revert no test triggers", which is the defensive surface. An `if/else` has two records (`.0` body, `.1` else). A `require`-style guard whose passing path is the normal path has no record for that path.

### 4.2 Table (81 zero-hit branches; forge printed 496 total, 415 hit)

Class "tool artifact": the `.1` (else) record of `SpokeVault.sol:151` (`if (hub) {`) shows zero, but line 155, the first line of the else body, has 70 hits and the spoke-role constructor runs in every spoke-chain test. It is the only such entry under 1.8.3. Not verified: why forge drops it (the else body starts with a tuple declaration). Under 1.0.0 the same lcov reported five such entries (`CoreVaultLogic.sol:332`, `AaveV3Adapter.sol:482`, `SpokeVault.sol:758`, `:761`, `:883`); they are hit under 1.8.3, which is one reason 1.8.3 is the primary source. Every other entry was read against the source and the neighbouring line hits and has no contrary evidence. Constructor guards (`AaveV3Adapter.sol:125-134`, `AcrossBridgeAdapter.sol:61`, `ChainlinkPriceSource.sol:82-104`, `ValueReportReceiver.sol:96`) are new in the 1.8.3 list.

| File:line | Function | Guard or statement (source) | Class |
|---|---|---|---|
| `adapters/AaveV3Adapter.sol:125` | `constructor` | `if (pool_ == address(0)) revert ZeroPool();` | revert path never taken |
| `adapters/AaveV3Adapter.sol:126` | `constructor` | `if (assets_.length == 0) revert InvalidReserveAsset(address(0));` | revert path never taken |
| `adapters/AaveV3Adapter.sol:131` | `constructor` | `if (asset == address(0)) revert InvalidReserveAsset(asset);` | revert path never taken |
| `adapters/AaveV3Adapter.sol:132` | `constructor` | `if (_ledgers[asset].aToken != address(0)) revert DuplicateReserveAsset(asset);` | revert path never taken |
| `adapters/AaveV3Adapter.sol:134` | `constructor` | `if (aToken == address(0)) revert ReserveNotListed(asset);` | revert path never taken |
| `adapters/AaveV3Adapter.sol:405` | `_exit` | `if (attributable >= principalNow + income) {` | path never taken |
| `adapters/AaveV3Adapter.sol:429` | `_exit` | `if (emptied) l.scaledBalance = 0;` | path never taken |
| `adapters/AaveV3Adapter.sol:445` | `_takeIncome` | `if (take != 0 && !_withdraw(asset, l, take, true)) take = 0;` | path never taken |
| `adapters/AaveV3Adapter.sol:485` | `_withdraw` | `} catch {` | path never taken |
| `adapters/AcrossBridgeAdapter.sol:61` | `constructor` | `if (spokePool_ == address(0)) revert ZeroSpokePool();` | revert path never taken |
| `adapters/UniswapV4Adapter.sol:400` | `increasePosition` | `if (liquidity == 0) revert InvalidLiquidity(0, 0);` | revert path never taken |
| `adapters/UniswapV4Adapter.sol:565` | `unlockCallback` | `if (amountUsed != amountIn) revert PartialSwap(amountUsed, amountIn);` | revert path never taken |
| `adapters/UniswapV4Adapter.sol:576` | `unlockCallback` | `if (paid != amountIn) revert PartialSwap(paid, amountIn);` | revert path never taken |
| `core/CoreVault.sol:61` | `deposit` | `if (usdcAmount == 0) revert ZeroAmount();` | revert path never taken |
| `core/CoreVault.sol:99` | `requestPayout` | `if (usdcAmount == 0) revert ZeroAmount();` | revert path never taken |
| `core/CoreVault.sol:152` | `claimPayout` | `if (c.balance == 0) revert NoShares(msg.sender);` | revert path never taken |
| `core/CoreVaultBase.sol:176` | `onlyHubSpokeVaultCallback` | `if (_reentrancyGuardEntered() && !_unwinding) revert ReentrancyGuardReentrantCall();` | revert path never taken |
| `core/CoreVaultBase.sol:351` | `_spoke` | `if (spokeIndex >= _s.mandate.spokes.length) revert UnknownSpoke(spokeIndex);` | revert path never taken |
| `core/CoreVaultIncome.sol:30` | `receiveCollectedIncome` | `if (!_s.income.isRegistered(token)) revert UnknownIncomeToken(token);` | revert path never taken |
| `core/CoreVaultIncome.sol:31` | `receiveCollectedIncome` | `if (amount == 0) revert ZeroAmount();` | revert path never taken |
| `core/CoreVaultIncome.sol:87` | `attributedIncome` | `if (!_s.income.isRegistered(token)) return 0;` | path never taken |
| `core/CoreVaultLogic.sol:148` | `spokeCapUsage` | `if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);` | revert path never taken |
| `core/CoreVaultLogic.sol:346` | `_price` | `if (p.n == p.tokens.length) _grow(p);` | path never taken |
| `core/CoreVaultLogic.sol:418` | `applyReport` | `if (spokeIndex >= s.mandate.spokes.length) revert ICoreVault.UnknownSpoke(spokeIndex);` | revert path never taken |
| `core/CoreVaultLogic.sol:449` | `_confirmArrivals` | `if (s.transitSpoke[id] != spokeIndex) continue;` | path never taken |
| `core/CoreVaultLogic.sol:552` | `nonArrivalProvable` | `if (!receiver.hasReport(spokeIndex)) return false;` | path never taken |
| `core/CoreVaultLogic.sol:657` | `_checkSend` | `if (adapter.codehash != s.bridgeCodehash[adapter]) revert ICoreVault.BridgeAdapterCodehashMismatch(a` | revert path never taken |
| `core/CoreVaultLogic.sol:755` | `recognizeRefund` | `if (received != held) revert ICoreVault.BalanceChangeMismatch(held, received);` | revert path never taken |
| `core/CoreVaultLogic.sol:760` | `_knownTransit` | `if (t.state == TransitState.None) revert ICoreVault.UnknownTransit(transitId);` | revert path never taken |
| `core/CoreVaultTransit.sol:27` | `allocateToHubSpokeVault` | `if (usdcAmount == 0) revert ZeroAmount();` | revert path never taken |
| `core/CoreVaultTransit.sol:44` | `returnToIdle` | `if (usdcAmount == 0) revert ZeroAmount();` | revert path never taken |
| `core/CoreVaultTransit.sol:64` | `sendToSpoke` | `if (usdcAmount == 0) revert ZeroAmount();` | revert path never taken |
| `core/CoreVaultTransit.sol:117` | `handleV3AcrossMessage` | `if (amount == 0) revert ZeroAmount();` | revert path never taken |
| `core/ManagerFeeVault.sol:26` | `constructor` | `if (fund_ == address(0) \|\| manager_ == address(0)) revert ZeroAddress();` | revert path never taken |
| `core/ManagerFeeVault.sol:40` | `withdraw` | `if (to == address(0)) revert ZeroAddress();` | revert path never taken |
| `factory/CodeStore.sol:47` | `write` | `if (chunk == address(0)) revert ChunkWriteFailed(i);` | revert path never taken |
| `factory/Create3.sol:41` | `deploy` | `if (proxyOf(address(this), salt).code.length != 0) revert SaltAlreadyUsed(salt);` | revert path never taken |
| `factory/Create3.sol:47` | `deploy` | `if (proxy == address(0)) revert SaltAlreadyUsed(salt);` | revert path never taken |
| `factory/FundFactory.sol:93` | `constructor` | `if (w.spokeCrossChainLib.code.length == 0) revert LibraryHasNoCode(w.spokeCrossChainLib);` | revert path never taken |
| `factory/FundFactory.sol:94` | `constructor` | `if (w.coreVaultLogic != address(0) && w.coreVaultLogic.code.length == 0) {` | path never taken |
| `factory/FundFactory.sol:201` | `createSpoke` | `if (spoke.spokeToken != _baseToken) revert BaseTokenMismatch(spoke.spokeToken, _baseToken);` | revert path never taken |
| `factory/FundFactory.sol:353` | `_deployChainAdapters` | `if (m.isAdapter(chainId, c.uniswapV4Adapter)) {` | path never taken |
| `factory/FundFactory.sol:356` | `_deployChainAdapters` | `if (uniswapV4Pools.length != 0) revert PoolKeyCountMismatch(0, uniswapV4Pools.length);` | revert path never taken |
| `factory/FundFactory.sol:383` | `_deployUniswapV4Adapter` | `if (_uniswapV4PoolManager == address(0)) {` | path never taken |
| `factory/FundFactory.sol:390` | `_deployUniswapV4Adapter` | `if (matched == pools.length) revert PoolKeyCountMismatch(matched + 1, pools.length);` | revert path never taken |
| `factory/FundFactory.sol:421` | `_deployAaveV3Adapter` | `if (uint256(pc.poolKey) > type(uint160).max) revert InvalidAavePoolKey(pc.poolKey);` | revert path never taken |
| `mandate/Mandate.sol:333` | `_validateBridgeAdapters` | `if (b.adapter == address(0)) revert ZeroAdapter();` | revert path never taken |
| `report/ChainlinkPriceSource.sol:82` | `constructor` | `if (f.token == address(0) \|\| f.aggregator == address(0)) revert ZeroAddress();` | revert path never taken |
| `report/ChainlinkPriceSource.sol:83` | `constructor` | `if (f.maxPriceAge == 0) revert ZeroMaxPriceAge(f.token);` | revert path never taken |
| `report/ChainlinkPriceSource.sol:88` | `constructor` | `if (denominatorDecimals > 60) revert DecimalsTooLarge(f.token, denominatorDecimals);` | revert path never taken |
| `report/ChainlinkPriceSource.sol:100` | `constructor` | `if (token == address(0)) revert ZeroAddress();` | revert path never taken |
| `report/ChainlinkPriceSource.sol:101` | `constructor` | `if (_prices[token].kind != KIND_NONE) revert DuplicateToken(token);` | revert path never taken |
| `report/ChainlinkPriceSource.sol:104` | `constructor` | `if (decimals > USDC_DECIMALS + 18) revert DecimalsTooLarge(token, decimals);` | revert path never taken |
| `report/ChainlinkPriceSource.sol:150` | `aggregatorOf` | `if (p.kind == KIND_NONE) revert UnsupportedToken(token);` | revert path never taken |
| `report/ValueReportReceiver.sol:96` | `constructor` | `if (fundId_ == bytes32(0)) revert ZeroFundId();` | revert path never taken |
| `report/ValueReportReceiver.sol:264` | `spokeIndexOf` | `if (indexPlusOne == 0) revert UnknownEmitter(emitterChainId, emitterAddress);` | revert path never taken |
| `spoke/SpokeCrossChainLib.sol:84` | `recognizeRefund` | `if (t.kind == TransferKind.Principal) s.unallocated[baseToken] += amount;` | path never taken |
| `spoke/SpokeCrossChainLib.sol:90` | `recognizeRefund` | `if (received != held) revert SpokeVaultTypes.RefundReleaseMismatch(held, received);` | revert path never taken |
| `spoke/SpokeCrossChainLib.sol:342` | `_executeBridgeCall` | `if (!ok) {` | path never taken |
| `spoke/SpokeVault.sol:145` | `constructor` | `if (fundId_ == bytes32(0)) revert SpokeVaultTypes.ZeroFundId();` | revert path never taken |
| `spoke/SpokeVault.sol:151` | `constructor` | `if (hub) {` | tool artifact (else body line 155 has 70 hits) |
| `spoke/SpokeVault.sol:152` | `constructor` | `if (baseToken_ != mandate_.usdc) revert SpokeVaultTypes.BaseTokenMismatch(baseToken_, mandate_.usdc)` | revert path never taken |
| `spoke/SpokeVault.sol:156` | `constructor` | `if (baseToken_ != spoke.spokeToken) revert SpokeVaultTypes.BaseTokenMismatch(baseToken_, spoke.spoke` | revert path never taken |
| `spoke/SpokeVault.sol:225` | `_pinBridgeAdapters` | `if (target == address(0)) revert SpokeVaultTypes.ZeroBridgeTarget(b.adapter);` | revert path never taken |
| `spoke/SpokeVault.sol:232` | `_requireCode` | `if (adapter.code.length == 0) revert SpokeVaultTypes.AdapterHasNoCode(adapter);` | revert path never taken |
| `spoke/SpokeVault.sol:257` | `openPosition` | `if (amount0 == 0 && amount1 == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:263` | `openPosition` | `if (_s.positionSlot[adapter][positionKey] != 0) {` | path never taken |
| `spoke/SpokeVault.sol:283` | `increasePosition` | `if (amount0 == 0 && amount1 == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:448` | `handleV3AcrossMessage` | `if (amount == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:480` | `receiveFromCoreVault` | `if (amount == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:488` | `returnToCoreVault` | `if (amount == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:531` | `unwindForPayout` | `if (usdcTarget == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:710` | `_positionPool` | `if (slot == 0) revert UnknownPosition(adapter, positionKey);` | revert path never taken |
| `spoke/SpokeVault.sol:790` | `_swap` | `if (amountIn == 0) revert ZeroAmount();` | revert path never taken |
| `spoke/SpokeVault.sol:800` | `_swap` | `if (amountOut < minAmountOut) revert SpokeVaultTypes.SwapOutputBelowMinimum(amountOut, minAmountOut)` | revert path never taken |
| `spoke/SpokeVault.sol:830` | `_unwindStep` | `if (held >= usdcTarget) break;` | path never taken |
| `spoke/SpokeVault.sol:889` | `_unwindRoute` | `if (r.adapter == address(0)) revert SpokeVaultTypes.MissingUnwindSwap(token);` | revert path never taken |
| `spoke/SpokeVault.sol:929` | `_sendToAdapter` | `if (token == address(0)) revert UnexpectedToken(token);` | revert path never taken |
| `spoke/SpokeVault.sol:942` | `_creditUnused` | `if (used0 > sent0) revert SpokeVaultTypes.AdapterUsedAboveInput(adapter, p.token0, sent0, used0);` | revert path never taken |
| `spoke/SpokeVault.sol:943` | `_creditUnused` | `if (used1 > sent1) revert SpokeVaultTypes.AdapterUsedAboveInput(adapter, p.token1, sent1, used1);` | revert path never taken |
| `spoke/SpokeVault.sol:950` | `_credit` | `if (p.token1 == address(0) && (a.principal1 != 0 \|\| a.income1 != 0)) revert UnexpectedToken(addres` | revert path never taken |

### 4.3 Lines with zero hits (63 in `src/`, forge 1.8.3), triaged

The lcov lists 63 `src/` lines with zero hits (65 under 1.0.0). Triage by reading each against the source and the neighbouring line hits:

| Class | Count | Meaning |
|---|---|---|
| A. First statement after the modifiers | 18 | `_topUpOperatingCash();` at `CoreVault.sol:66,153`, `CoreVaultTransit.sol:28,67`, `SpokeVault.sol:258,284,302,314,326,343,361,389,396,468`; `_requireEntryAllowed();` at `AaveV3Adapter.sol:170,196`, `UniswapV4Adapter.sol:356,394`. False zeros: e.g. `SpokeVault.sol:389` shows 0 while line 390 (the next statement) shows 842 hits and `sendToHub` ran 842 times (1.0.0). |
| B. Assembly lines in functions that ran | 15 | `CodeStore.sol:37,45,66`, `Create3.sol:45`, `FundFactory.sol:425,493`, `SpokeCrossChainLib.sol:189,202-205`, `SpokeVault.sol:424-426,744`. Same cause; the functions have hits and the tests that use them pass. |
| E. Start or tail of a body that must have run | 3 | `SpokeVault.sol:889,890` (first statements of the `else` at `:887`: the else record `BRDA:883,63,1` has 2 hits and line 891 has 2 hits) and `SpokeVault.sol:836` (`return visited;` at the end of `_unwindStep`, a function with 24 calls). |
| C. Body of a function that never ran | 15 | `CoreVaultLogic.valuation` (`:67,72`), `CoreVaultLogic._grow` (`:358-366`), `CoreVaultBase._spoke` (`:350-352`), `ShareMath.isWholeShares` (`:50-51`). Real (section 5.2). |
| D. Real never-run lines | 9 | `AaveV3Adapter.sol:408,485,486`; `FundFactory.sol:95,356,357,384`; `SpokeCrossChainLib.sol:85`; `SpokeVault.sol:264`. Each has a matching zero branch in 4.2. |
| D1. Revert-forwarding assembly | 3 | `CoreVaultLogic.sol:629`, `Create3.sol:51`, `SpokeCrossChainLib.sol:344`: the `revert(add(ret, 0x20), mload(ret))` that bubbles a failed delegatecall or external call. Never taken. |

So 36 of the 63 lines (A, B, E) are tool artifacts and 27 (C, D, D1) are real gaps that repeat what the branch table says. Trust the branch table and section 5 over raw line counts. One new real gap appears only in the branch table: `SpokeVault.sol:830` (`if (held >= usdcTarget) break;` in `_unwindStep`), the early stop of the unwind loop once the target is reached, never taken in 23 loop iterations.

## 5. Functions and revert paths that no test reaches directly

### 5.1 Method

1. Function inventory from source: 168 external or public functions and 172 internal or private functions in the 27 non-interface `src/` files that declare functions (regex over declarations, comments stripped).
2. Executed: lcov `FNDA` hits per function (unit, fuzz and invariant tiers, forge 1.8.3; hit counts of invariant-driven functions differ between the two forge versions, for example `returnToIdle` 21 against 176, and are indications only).
3. Directly referenced: by-name grep in `test/unit` and `test/fork` (see section 0 for the counting rule), plus the ABI in `out/` for public getters that have no declaration.
4. Custom errors and events: every `error X(` and `event X(` in `src/` searched by name in `test/`.

### 5.2 Functions never executed by any unit, fuzz or invariant test (lcov `FNDA` = 0)

Four of 363 functions (forge 1.8.3; the same four under 1.0.0).

| Function | Visibility and kind | Evidence | Note |
|---|---|---|---|
| `CoreVaultLogic.valuation` (`CoreVaultLogic.sol:67`) | public view, linked library | no caller in `src/` (grep `.valuation(`), no test reference | Dead code inside the 19,215-byte library that the Core Vault delegatecalls; the library margin is 5,361 bytes. |
| `CoreVaultLogic._grow` (`CoreVaultLogic.sol:358`) | private pure | reached only from `_price` (`:346`) when a valuation prices more than 4 distinct non-USDC tokens (initial capacity 4 in `_newPrices`, `:351-356`) | Runs inside the payout valuation whose failure would block an exit; the growth copy is untested. |
| `CoreVaultBase._spoke` (`CoreVaultBase.sol:350`) | internal view | no caller in `CoreVaultBase`, `CoreVaultIncome`, `CoreVaultTransit`, `CoreVault`; `ValueReportReceiver` has its own `_spoke` (`ValueReportReceiver.sol:272`) | Dead code; its `UnknownSpoke` revert (`:351`) is one of the zero branches. |
| `ShareMath.isWholeShares` (`ShareMath.sol:50`) | internal pure | no caller in `src/` or `test/` | Dead code. |

### 5.3 External or public functions with no by-name reference in `test/unit` or `test/fork`

Exact (count 0). All are either reached only through a wrapper or are constant getters.

| Function | Executed via | lcov hits |
|---|---|---|
| `CoreVaultLogic.recordValuation` (`:89`), `applyReport` (`:417`), `receiveHubBound` (`:489`) | `CoreVault` delegatecall wrappers | 12,802 / 51 / 19 |
| `SpokeCrossChainLib.nextReport` (`:99`), `encodedReport` (`:112`) | `SpokeVault.report`, `SpokeVault.buildReport` | 593 / 24 |
| Constant getters: `CoreVault.UNWIND_MARGIN_BPS` (`CoreVault.sol:32`), `FundFactory.VARIATION_BAND_BPS` (`FundFactory.sol:44`), `ValueReportReceiver.FINALIZED`, `ChainlinkPriceSource.USDC_DECIMALS`, `UniswapV4Adapter.positionManager()` and `stateView()` (0 in unit and in fork) | used internally (for example `UNWIND_MARGIN_BPS` at `CoreVault.sol:160`) | not measured (public getters have no lcov function entry) |

`UniswapV4Adapter.poolManager()` and `permit2()` have no unit reference and one fork reference each. No other declared external or public function has a zero count, and no other function has zero lcov hits. Per contract, external or public functions declared / with a by-name count of 0: `SpokeVault` 38 / 0, `AaveV3Adapter` 15 / 0, `UniswapV4Adapter` 14 / 0, `CoreVaultBase` 16 / 0, `CoreVaultLogic` 13 / 3, `CoreVaultIncome` 10 / 0, `ValueReportReceiver` 10 / 0, `FundFactory` 8 / 0, `CoreVaultTransit` 8 / 0, `ShareToken` 6 / 0, `SpokeCrossChainLib` 5 / 2, `ManagerRegistry` 5 / 0, `ChainlinkPriceSource` 5 / 0, `AcrossBridgeAdapter` 4 / 0, `CoreVault` 3 / 0, others 2 / 0.

### 5.4 State-changing entry points whose only direct test is negative, or a single call

A by-name count of 1 or 2, each checked by hand. The positive path runs only through the other side's mock, so the real two-sided handshake is not tested offline (section 10, G1).

| Function | Direct references | What they test | Where the positive path runs (hits are of the real function) |
|---|---|---|---|
| `CoreVaultTransit.returnToIdle` (`:43`) | 2, `CoreVaultSetup.t.sol:242,244` | `UnbackedCredit` and `NotHubSpokeVault` reverts | `MockHubSpokeVault.returnToCore` (`test/mocks/core/MockHubSpokeVault.sol:89-92`), 21 hits |
| `CoreVaultIncome.receiveCollectedIncome` (`:28`) | 2, `CoreVaultIncome.t.sol:179,181` | `UnbackedCredit` and `NotHubSpokeVault` reverts | `MockHubSpokeVault.forwardIncome` (`:83`), 1,970 hits |
| `CoreVaultTransit.onReportAccepted` (`:95`) | 1, `CoreVaultTransit.t.sol:354` | `NotReportReceiver` revert | `MockReportReceiver`, 52 hits |
| `SpokeVault.unwindForPayout` (`:524`) | 2, `SpokeVaultHub.t.sol:155`, `SpokeVaultSpoke.t.sol:961` | `NotCoreVault` and `NotOnHubChain` reverts | `MockCoreVault.unwind` (`test/mocks/spoke/MockCoreVault.sol:46`), 20 hits |
| `SpokeVault.receiveFromCoreVault` (`:478`) | 2, `SpokeVaultSpoke.t.sol:955`, `SpokeVaultHub.t.sol:93` | `NotOnHubChain` and `NotCoreVault` reverts | `MockCoreVault.allocate` and `credit` (`MockCoreVault.sol:37,42`), 22 hits |
| `SpokeVault.returnToCoreVault` (`:487`) | 4, `SpokeVaultHub.t.sol:110,115,124`, `SpokeVaultSpoke.t.sol:957` | one success, two amount reverts, one role revert | the success calls `MockCoreVault.returnToIdle` (`MockCoreVault.sol:24`), never the real Core Vault; 2 hits |
| `ManagerFeeVault.withdraw` (`:38`) | 2, `CoreVaultIncome.t.sol:80,85` | one `NotManager` revert, one success | none other; the `to == address(0)` guard (`:40`) has zero hits |
| `UniswapV4Adapter.unlockCallback` (`:548`) | 1, `UniswapV4Adapter.t.sol:164` | direct call by a stranger reverts | `MockV4.unlock`, 9 hits |
| `ShareToken.transferFrom` (`:66`) | 1, `ShareToken.t.sol:88` | `ShareTransfersDisabled` | n/a |
| `ManagerRegistry.renounceOwnership` (`:61`) | 2, `ManagerRegistryAdversarial.t.sol:66,71` | reverts | n/a |

### 5.5 Custom errors, events and weak assertions

`src/` declares 169 custom errors and 54 events (names, comments stripped). Searched by name in `test/unit`, `test/fork` and `test/mocks`:

| Custom error never referenced in any test | Thrown at | lcov |
|---|---|---|
| `BridgeAdapterCodehashMismatch` | `CoreVaultLogic.sol:657` | zero branch |
| `SwapOutputBelowMinimum` | `SpokeVault.sol:800` | zero branch |
| `AdapterUsedAboveInput` | `SpokeVault.sol:942,943` | zero branches |
| `MissingUnwindSwap` | `SpokeVault.sol:889` | zero branch |
| `ZeroBridgeTarget`, `AdapterHasNoCode` | `SpokeVault.sol:225`, `:232` | zero branches |
| `PositionAlreadyRegistered` | `SpokeVault.sol:264` | zero branch and zero line |
| `RefundReleaseMismatch` | `SpokeCrossChainLib.sol:90` | zero branch |
| `InvalidAavePoolKey` | `FundFactory.sol:421` | zero branch |
| `ChunkWriteFailed` | `CodeStore.sol:47` | zero branch |
| `AmountBelowMinimum` | `UniswapV4Adapter.sol:655` | 2 hits, but only through a bare `vm.expectRevert()` (`UniswapV4Adapter.t.sol:250` or `:357`); the reason is never asserted |

Events declared and emitted in `src/` but never referenced in any test (no `expectEmit`, no log inspection): `PayoutRequested` (`CoreVault.sol:129`), `ReturnedToIdle` (`CoreVaultTransit.sol:49`), `ArrivalHeldApart` (`CoreVaultLogic.sol:529`), `SpokeCreated` (`FundFactory.sol:209`), `PoolRegistered` (`UniswapV4Adapter.sol:234`), `Deployed` (`Create3Deployer.sol:25`), `IncomeRecognized`, `IncomeDistributed`, `IncomeTokenRegistered` (`IncomeAccumulator.sol:162,219,115`). The project rule is one event at the end of every operation, so these are unasserted parts of the off-chain interface.

Assertion quality counters over `test/unit`: 402 typed `vm.expectRevert(selector or data)`, 16 bare `vm.expectRevert()` (`ShareMath.t.sol` 3, `AaveV3Adapter.t.sol` 3, `AcrossBridgeAdapter.adversarial.t.sol` 3, `UniswapV4Adapter.t.sol` 2, one each in `ReportCodec`, `TransitMessage`, `ValueReportReceiverAdversarial`, `ChainlinkPriceSourceAdversarial`, `FundFactoryVerifyRound2`), 61 `vm.expectEmit`, 0 `vm.expectCall`, 1,931 `assert*` calls.

## 6. Tests per module

### 6.1 By test directory (declared by grep / executed by `forge test`)

| Directory | Files (with tests) | Lines | `test_` | `testFuzz_` | `invariant_` | Executed total | Targets in `src/` |
|---|---|---|---|---|---|---|---|
| `unit/` (root) | 8 (8) | 2,144 | 104 | 21 | 4 | 129 | `IncomeAccumulator`, `Mandate`, `ReportCodec`, `ShareMath`, `ShareToken`, `TransitEscrow`, `TransitMessage`, `AdapterGuard` |
| `unit/core` | 14 (13) | 3,080 | 146 | 7 | 7 | 160 | `CoreVault`, `CoreVaultBase`, `CoreVaultIncome`, `CoreVaultTransit`, `CoreVaultLogic`, `ManagerFeeVault` |
| `unit/spoke` | 8 (7) | 2,321 | 91 | 1 | 3 | 95 | `SpokeVault`, `SpokeCrossChainLib` |
| `unit/receiver` | 6 (6) | 1,116 | 60 | 11 | 0 | 71 | `ValueReportReceiver`, `ChainlinkPriceSource`, `ManagerRegistry` |
| `unit/factory` | 4 (4) | 1,440 | 55 | 3 | 0 | 58 | `FundFactory`, `Create3`, `CodeStore`, `Create3Deployer` |
| `unit/v4` | 2 (2) | 1,041 | 35 | 4 | 0 | 39 | `UniswapV4Adapter` |
| `unit/aave` | 4 (4) | 1,185 | 41 | 2 | 0 | 70 | `AaveV3Adapter` |
| `unit/across` | 3 (3) | 570 | 28 | 4 | 0 | 32 | `AcrossBridgeAdapter` |
| **unit total** | 49 (47) | 12,848 | 560 | 53 | 14 | 654 | |
| `fork/` (not run) | 16 files | 3,808 | 52 | 0 | 0 | n/a | see section 9 |
| `mocks/` | 34 files | 2,356 | 0 | 0 | 0 | n/a | |

Notes: "Executed total" counts each invariant as one test (forge 1.0.0 counting, 654 in all); forge 1.8.3 counts each invariant suite once (644). `unit/core` holds the two shared files `CoreVaultFixture.sol` and `CoreVaultInvariant.t.sol` (the latter has only invariants); `unit/spoke` holds `SpokeVaultTestBase.sol` (fixture) and `SpokeVaultInvariant.t.sol`. `ManagerFeeVault` is tested inside `CoreVaultIncome.t.sol`. Total test tree: 19,012 lines against 9,044 lines of `src/`.

### 6.2 Tests against source size, by module

| Module | `src/` lines | Files | Unit `test_` + `testFuzz_` + `invariant_` aimed at it (approx.) | Tests per 100 source lines |
|---|---|---|---|---|
| core (`CoreVault*`, `ShareToken`, `ManagerRegistry`, `ManagerFeeVault`, `TransitEscrow`, `CoreVaultTypes`) | 1,999 | 10 | 160 (`unit/core`) + 15 (`ShareToken`) + 13 (`ManagerRegistry`, in `unit/receiver`) + 5 (`TransitEscrow`) = 193 | 9.7 |
| spoke (`SpokeVault`, `SpokeCrossChainLib`, `SpokeVaultTypes`) | 1,514 | 3 | 95 | 6.3 |
| adapters (`UniswapV4Adapter`, `AaveV3Adapter`, `AcrossBridgeAdapter`, `AdapterGuard`) | 1,447 | 4 | 39 + 70 + 32 + 4 = 145 | 10.0 |
| factory (`FundFactory`, `Create3`, `CodeStore`, `Create3Deployer`) | 698 | 4 | 58 | 8.3 |
| report (`ValueReportReceiver`, `ChainlinkPriceSource`) | 444 | 2 | 17 (`ChainlinkPriceSource`) + 41 (`ValueReportReceiver`) = 58 | 13.1 |
| libraries (`IncomeAccumulator`, `ReportCodec`, `ShareMath`, `TransitMessage`) | 575 | 4 | 31 + 6 + 28 + 3 = 68 | 11.8 |
| mandate (`Mandate.sol`) | 379 | 1 | 37 | 9.8 |
| interfaces | 1,988 | 18 | 0 | n/a |

`SpokeVault` is the largest contract (1,004 lines, 38 external or public functions). The spoke module has the lowest tests per 100 source lines of any module (6.3) and the largest branch gap (section 3.3).


### 6.3 Fuzz tests by module (53 declared, 54 executed; 512 runs each)

| Module (file) | Count | Properties fuzzed (decision) |
|---|---|---|
| `ShareMath.t.sol` | 10 | mint whole-floored and never overcharges, undercharge at most 1 unit, deposit continuity (DEC-035); burn never pays more than requested, never lowers the price for remaining holders (DEC-077); price monotonic and bounded at extremes, supply value never above Share Assets (DEC-084); preview never above deposit (DEC-106); flow fee never above 1% (DEC-110) |
| `IncomeAccumulator.t.sol` | 8 | never over-distributes, remainder below supply and conserved, single holder recovers all up to 1 unit, five-holder conservation at extremes, regress-then-recover, zero supply and max uint never leak (Q60); entrant owes nothing of prior income (DEC-014) |
| `unit/core` (7 files) | 7 | payout never above request (DEC-077), round trip extracts no value (DEC-077), standard claim never touches another holder's reserve (DEC-072), instant claim never touches the reserve (DEC-095), escrow below amount sent never moves Share Assets (DEC-063), every collected unit lands in exactly one place (DEC-107), deposit charges only whole shares (DEC-035) |
| `unit/receiver` (`ValueReportReceiver*`) | 5 | only strictly increasing sequences accepted, replay of any earlier report rejected, consistency other than FINALIZED rejected (DEC-093); emitter outside the Mandate rejected (DEC-086); age bound at delivery (DEC-099) |
| `unit/receiver` (`ChainlinkPriceSource*`) | 3 | value matches the direct formula, non-positive answer always reverts, whole-token value across decimals (Q57b) |
| `unit/receiver` (`ManagerRegistry*`) | 3 | slice within cap is stored, effective slice never above cap, non-owner cannot write (DEC-110, LC-142) |
| `unit/across` | 4 | build-time fill deadline (DEC-066), non-EVM recipient rejected (DEC-087), calldata layout canonical for any message (DEC-087), build never substitutes fields (DEC-087) |
| `unit/v4` | 4 | cumulative income monotonic (Q60), derived liquidity never above the maximums, close matches position value across tick space (DEC-079), collect-then-decrease equals decrease alone (Q60) |
| `unit/aave` | 3 executed (2 declared) | extreme index and amounts keep income exact, lifecycle conserves value (DEC-068, Q60) |
| `unit/factory` | 3 | salts distinct per role, chain and fund (Q59); address independent of init code (DEC-054); code store round trips (DEC-058) |
| `TransitMessage`, `ReportCodec` | 2 | encode/decode round trips (DEC-090, DEC-093) |
| `unit/spoke` | 1 | bridge fee bound exact at the boundary (QA19) |
| `Mandate.t.sol`, `TransitEscrow.t.sol`, `AdapterGuard.t.sol` | 0 | none, although `Mandate` has 37 tests and 16 internal library functions |

`ShareToken.t.sol` also has one fuzz test (`mintSucceedsIffWholeShares`, DEC-091), counted in the root directory total. No fuzz test drives `SpokeVault` state sequences except through the invariant handler, and none targets `CoreVault` deposit/claim sequences outside the invariant handler.

## 7. Invariants inventory (14, `invariant_` functions)

All 14 pass at 256 runs x 32 depth, 8,192 calls each, 0 reverts (default profile), and at 512 x 48, 24,576 calls (`ci`), under both forge versions. Decision ids are the ones in the test names.

| # | Test (`file:line`) | Property stated | Decision | Handler and limits |
|---|---|---|---|---|
| 1 | `unit/core/CoreVaultInvariant.t.sol:127` `invariant_DEC072_payoutReserveWithinIdle` | `payoutReserve() <= idle()` | DEC-072 | `CoreVaultHandler` (`:14`): deposit, requestPayout, claim, donate, forwardIncome, withdrawIncome, allocate, movePrice, warp; 3 actors; hub Spoke Vault is `MockHubSpokeVault` |
| 2 | `:131` `invariant_DEC091_supplyIsWholeShares` | `totalSupply() % 1e18 == 0` | DEC-091 | same |
| 3 | `:135` `invariant_DEC104_shareAssetsEqualBuckets` | `shareAssets()` equals the independent sum of buckets (`_bucketSum`, `CoreVaultFixture.sol:254`: idle + hub unallocated + hub position value + in-flight + spoke value) and equals `idle + hubVault.unallocatedUsdc() + hubVault.positionPrincipal()` | DEC-104 | the handler never opens a Transit and never delivers a spoke report, so the in-flight and spoke terms are always 0; the hub position token is USDC, so the price-source path is not exercised |
| 4 | `:140` `invariant_DEC080_balanceCoversLedger` | `usdc.balanceOf(vault) >= idle + operatingCash + collectedIncome + unmatchedArrivals` | DEC-080 | same |
| 5 | `:144` `invariant_DEC080_directTransferNeverMovesSharePrice` | ghost flag `donationMovedPrice` stays false after any donation | DEC-080 | `donate` mints to the vault and compares `sharePrice()` before and after |
| 6 | `:148` `invariant_Q60_indexNeverDecreases` | ghost flag `indexDecreased` stays false | Q60 | tracked by the `trackIndex` modifier |
| 7 | `:154` `invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated` | `distributed + ownerless + feesOut == forwarded` and `taken <= distributed` | DEC-107 | `forwardIncome` only, USDC only |
| 8 | `unit/spoke/SpokeVaultInvariant.t.sol:219` `invariant_DEC080_ledgerNeverExceedsBalance` | for base token and WETH: `unallocated + collectedIncome (+ operatingCash for base) <= balance` | DEC-080 | `SpokeVaultHandler` (`:16`): arrive, open, increase, decrease, close, collect, earnIncome, swap, donate, sweep, sendHome, refund, report, warp; one `MockPositionAdapter`, one pool, `spokeUni.setSwapRate(1, 1)`; `sendHome` sends only `TransferKind.Principal` (`:150`), so an Income-kind refund is never reached |
| 9 | `:224` `invariant_Q60_cumulativeIncomeNeverDecreases` | ghost flag plus `cumulativeIncome >= last seen` for both tokens | Q60 | same |
| 10 | `:230` `invariant_DEC093_reportSequenceStrictlyIncreases` | each `report()` returns previous + 1; `reportSequence()` equals the last seen | DEC-093 | same |
| 11 | `unit/IncomeAccumulator.t.sol:676` `invariant_Q60_owedPlusTakenNeverExceedsDistributed` | per token, sum of `owed` over 3 holders + `taken <= distributed` | Q60 | `IncomeAccumulatorHandler`: mint, burn, recognize (with regress), take; 3 holders, 2 tokens, 2 sources |
| 12 | `:682` `invariant_Q60_indexNeverDecreases` | ghost flag | Q60 | same |
| 13 | `unit/ShareToken.t.sol:214` `invariant_DEC091_totalSupplyIsWholeShares` | total supply and 3 holder balances are multiples of 1e18 | DEC-091 | `ShareTokenHandler`: whole and fractional mint and burn, transfer (expects revert) |
| 14 | `:222` `invariant_DEC004_allowanceAlwaysZero` | `allowance(0xA11CE, 0xB0B) == 0` | DEC-004 | checks one (owner, spender) pair only |

What is not invariant-tested today: `UniswapV4Adapter`, `AaveV3Adapter` (lifecycle is a fuzz test, not an invariant), `AcrossBridgeAdapter`, `ValueReportReceiver`, `FundFactory`, `ManagerRegistry`, `Mandate`, `ChainlinkPriceSource`, `TransitEscrow`, `ManagerFeeVault`, and every property that spans two contracts (hub plus spokes plus in-flight value, the payout unwind handshake, report acceptance against Share Assets).

## 8. Contract sizes (`forge build --sizes`, default profile)

Limits used by forge's own margin columns: runtime 24,576 bytes (EIP-170), initcode 49,152 bytes (EIP-3860). Libraries that hold only internal functions compile to 85-byte stubs (`CodeStore`, `Create3`, `IncomeAccumulator`, `MandateLib`, `ReportCodec`, `ShareMath`, `SpokeVaultTypes`, `TransitMessage`) and are not listed.

Sizes are identical under forge 1.0.0 and forge 1.8.3 (same solc and settings). The 1.8.3 table omits `SpokeCrossChainLib`; its 10,545 bytes runtime and 10,597 bytes initcode are read from `out/SpokeCrossChainLib.sol/SpokeCrossChainLib.json` and match the 1.0.0 table.

| Contract | Runtime (B) | Runtime margin to 24,576 (B) | Runtime used | Initcode (B) | Initcode margin to 49,152 (B) |
|---|---|---|---|---|---|
| `SpokeVault` | 23,644 | 932 | 96.2% | 32,630 | 16,522 |
| `CoreVault` | 20,034 | 4,542 | 81.5% | 34,084 | 15,068 |
| `CoreVaultLogic` | 19,215 | 5,361 | 78.2% | 19,267 | 29,885 |
| `UniswapV4Adapter` | 17,854 | 6,722 | 72.6% | 19,482 | 29,670 |
| `FundFactory` | 16,084 | 8,492 | 65.4% | 19,969 | 29,183 |
| `SpokeCrossChainLib` | 10,545 | 14,031 | 42.9% | 10,597 | 38,555 |
| `AaveV3Adapter` | 10,133 | 14,443 | 41.2% | 11,795 | 37,357 |
| `ValueReportReceiver` | 7,846 | 16,730 | 31.9% | 9,267 | 39,885 |
| `AcrossBridgeAdapter` | 2,347 | 22,229 | 9.5% | 2,906 | 46,246 |
| `ShareToken` | 1,822 | 22,754 | 7.4% | 2,603 | 46,549 |
| `ManagerRegistry` | 1,530 | 23,046 | 6.2% | 1,803 | 47,349 |
| `ChainlinkPriceSource` | 1,420 | 23,156 | 5.8% | 3,683 | 45,469 |
| `Create3Deployer` | 1,342 | 23,234 | 5.5% | 1,370 | 47,782 |
| `ManagerFeeVault` | 1,077 | 23,499 | 4.4% | 1,355 | 47,797 |
| `TransitEscrow` | 894 | 23,682 | 3.6% | 939 | 48,213 |

- `SpokeVault` has 932 bytes of runtime margin (96.2% of the limit). Any new guard, event or instrumentation on it can overflow the limit. Scribble annotations instrumented into the source, in-contract assertions, or ghost state cannot be added to the production build of this contract. Not verified: how each candidate tool treats the size limit (some run in an environment without the check); confirm per tool in the tooling document.
- `CoreVault` has 4,542 bytes of margin (81.5%); its logic lives in the linked `CoreVaultLogic` (19,215 bytes, 5,361 margin) run by delegatecall, and `SpokeVault` uses `SpokeCrossChainLib` (10,545 bytes) the same way. Each vault plus its library is one verification unit and must be analysed with the library linked, not as separate contracts.
- The initcode margins are comfortable (`CoreVault` 15,068, `SpokeVault` 16,522).

## 9. Fork suites (listed, not run: they need RPC endpoints)

Each suite reads `ARBITRUM_RPC_URL`, `ARBITRUM_FORK_BLOCK`, `ROBINHOOD_RPC_URL`, `ROBINHOOD_FORK_BLOCK` (`vm.envString` / `vm.envUint` in the files; `.env.example:8-9` lists the block variables empty). 52 `test_` functions in 16 files, 3,808 lines.

| Suite | Chain | Tests | What it covers (from its header comment) |
|---|---|---|---|
| `Toolchain.t.sol` | both | 2 | both forks resolve; Uniswap V3 and Wormhole dependencies compile; Wormhole guardian set can be overridden to sign VAAs locally |
| `aave/AaveV3Adapter.fork.t.sol` | Arbitrum | 7 | adapter against the real Aave V3 Pool and aArbUSDCn at the pinned block |
| `aave/AaveV3AdapterAdversarial.fork.t.sol` | Arbitrum | 3 | adversarial round 1 on the real Pool, including draining reserve liquidity through a test-only borrow entry (DEC-018, DEC-028) |
| `across/AcrossBridgeAdapter.fork.t.sol` | both | 9 | the adapter's built call executed by a vault harness against the real SpokePools (Arbitrum hub, Robinhood spoke) |
| `across/AcrossFill.fork.t.sol` | both | 4 | fill simulator compared with a real `fillRelay`; a future quote rejected by the live pool; a stranger's deposit shifting the id a stale build would carry |
| `core/CoreVaultAcross.t.sol` | Arbitrum | 2 | Core Vault custody against the live SpokePool: exact approval, exact pull with the per-send escrow as depositor, approval reset, fill callback matched by transit id |
| `e2e/EndToEnd.t.sol` (+ `EndToEndBase.sol`) | both | 1 (ten phases) | one fund created through the factory on both chains and driven across Across, Uniswap V4, Aave V3, Wormhole Cores and the Chainlink ETH/USD feed, each phase citing its decision (808 lines) |
| `e2e/EndToEndAdversarial.t.sol` | both | 3 | replays a prefix of the ten phases, then takes a path the main scenario does not walk |
| `factory/FundFactoryFork.t.sol` | both | 3 | operator deployment script and `createFund` / `createSpoke` against live protocols; same factory address on both chains; predicted addresses match (DEC-053, DEC-054) |
| `receiver/ChainlinkPriceSourceFork.t.sol` | Arbitrum | 2 | live Chainlink ETH/USD feed |
| `receiver/ValueReportReceiverFork.t.sol` | Arbitrum | 8 | real Arbitrum Wormhole Core with the guardian set overridden; VAAs crafted as if the Robinhood Spoke Vault had published them |
| `spoke/SpokeVaultArbitrumFork.t.sol` (+ `SpokeVaultForkBase.sol`) | Arbitrum | 2 | hub role with native USDC: allocation, positions, automatic unwind in Mandate order, income forwarding, same-chain report reader |
| `spoke/SpokeVaultRobinhoodFork.t.sol` | Robinhood | 2 | spoke role with real USDG, real Wormhole Core Bridge report publication and the real Across SpokePool send home |
| `v4/UniswapV4AdapterFork.t.sol` | both | 4 in an abstract base, run by two concrete contracts (8 executions) | full position lifecycle against a real hookless 0.05% pool (WETH/USDC on Arbitrum, WETH/USDG on Robinhood), fees generated by a third-party swapper through `PoolManager.unlock` |

By-name references show two flows with no fork coverage at all: `attestExpiry` and `recognizeRefund` (hub and spoke) have 24 and 32 unit references and 0 fork references, so the failed-transit and refund path is exercised only against mocks.


## 10. What the baseline says about gaps, ranked by risk

Ranking rule: first what can lock or misprice funds under the defensive posture (malicious manager, hostile third parties, failing dependencies, exits never blocked), then what limits the tools that will follow, then hygiene. Each item names the evidence and what it means for the plan.

**G1. The real stack is never tested together offline (highest).**
Evidence: no test in `test/unit` or `test/fork` other than the e2e suite drives the real `CoreVault`, `SpokeVault`, `ValueReportReceiver` and adapters together as one fund. `CoreVault` runs against `MockHubSpokeVault`, `MockBridgeAdapter`, `MockReportReceiver`; `SpokeVault` against `MockCoreVault`, `MockPositionAdapter` and `MockAcrossSpokePool`; `FundFactory` unit tests deploy the real contracts but drive no flow (no `deposit`, `report`, `deliver` in `test/unit/factory`), and `FundFactoryFork.t.sol` creates a fund without driving one either. The payout handshake (`claimPayout` to `unwindForPayout` to the `returnToIdle` callback) and the report path (`SpokeVault.report` to `ValueReportReceiver.deliver` to `onReportAccepted`) have the real contract on one side only in every offline test (section 5.4). All 14 invariants run against mocks (section 7).
Plan: the first work item for Echidna, Medusa and the symbolic tools is one offline harness that deploys a factory-created fund against mocked external protocols (SpokePool, Aave pool, PoolManager, Wormhole Core) and exposes the manager, investor and relayer entry points. Cross-contract conservation and liveness properties cannot be stated before it exists.

**G2. Exit-path defences that no test exercises (payout liveness, DEC-021, DEC-056).**
Evidence (zero-hit entries in section 4): `CoreVaultLogic._grow` (payout valuation with more than 4 priced tokens, `:346`, `:358-366`, function never ran); `SpokeVault._unwindRoute`: `MissingUnwindSwap` never taken (`:889`), and the two-step route (the `else` at `:887`) runs only in two tests that both expect `InvalidUnwindSwap` (`SpokeVaultHub.t.sol:271,280`; `BRDA:883,63,1` and `BRDA:891,66,0` have 2 hits each), so no test completes a two-step unwind; `_unwindStep` never stops early at the target (`:830`, 23 loop iterations, 0 breaks); `_creditUnused` `AdapterUsedAboveInput` twice (`:942,943`); `_credit` unexpected token (`:950`); the `onlyHubSpokeVaultCallback` reentrancy branch that lets the hub Spoke Vault call back only during an unwind (`CoreVaultBase.sol:176`); Aave best-effort income withdrawal `catch` (`AaveV3Adapter.sol:445,485,486`), full-exit ledger reset (`:429`, the `emptied` path never true) and the foreign-units rounding branch (`:405,408`); `UniswapV4Adapter.sol:565,576` `PartialSwap`.
Plan: these are the first targets for directed tests and for the liveness properties (a payout can always be served or fail without blocking), and the reason the invariant handlers need hostile adapter and token behaviours.

**G3. Trust-boundary pins with no negative test.**
Evidence: hub bridge adapter codehash pin (`CoreVaultLogic.sol:657`, `BridgeAdapterCodehashMismatch`); `SpokeVault` constructor and pinning guards `ZeroFundId` (`:145`), two `BaseTokenMismatch` (`:152`, `:156`), `ZeroBridgeTarget` (`:225`), `AdapterHasNoCode` (`:232`); `PositionAlreadyRegistered` (`:264`); `SwapOutputBelowMinimum` (`:800`); `FundFactory` guards `LibraryHasNoCode` for both linked libraries (`:93-95`), `BaseTokenMismatch` (`:201`), `PoolKeyCountMismatch` (`:356`, `:390`), `ProtocolNotOnChain` (`:383`), `InvalidAavePoolKey` (`:421`); `Create3` `SaltAlreadyUsed` twice (`:41`, `:47`); `CodeStore.ChunkWriteFailed` (`:47`); constructor guards of `AaveV3Adapter` (`:125,126,131,132,134`), `AcrossBridgeAdapter` (`:61`), `ChainlinkPriceSource` (`:82,83,88,100,101,104`) and `ValueReportReceiver` (`:96`), all visible only under forge 1.8.3. Seven of the eleven never-referenced errors are in this group (section 5.5); two more are in G2 (`AdapterUsedAboveInput`, `MissingUnwindSwap`), one in G4 (`RefundReleaseMismatch`) and one in G6 (`AmountBelowMinimum`).
Plan: each is a one-line directed test; the codehash and pin checks also become symbolic reachability properties.

**G4. Transit and refund state-machine edges.**
Evidence: Income-kind refund at the spoke (`SpokeCrossChainLib.sol:84-85`, never executed, and the spoke invariant handler sends only Principal); `RefundReleaseMismatch` (`:90`); hub `BalanceChangeMismatch` (`CoreVaultLogic.sol:755`) and `UnknownTransit` (`:760`); `UnknownSpoke` (`:148`, `:418`); `_confirmArrivals` skipping an arrival whose transit belongs to another spoke (`CoreVaultLogic.sol:449`); `nonArrivalProvable` with no report (`:552`); `attributedIncome` of an unregistered token (`CoreVaultIncome.sol:87`); `handleV3AcrossMessage` zero amount (`CoreVaultTransit.sol:117`, `SpokeVault.sol:448`); `attestExpiry` and `recognizeRefund` have no fork reference (section 9).
Plan: extend the spoke handler with Income sends and refunds, and put the transit state machine (None, Sent, ArrivalConfirmed, ExpiryAttested, RefundRecognized; `FundTypes.sol:13-19`) under an invariant across hub and spoke.

**G5. The invariant surface is thin and the handlers are narrow.**
Evidence: 14 invariants over 4 contracts (section 7); none for adapters, receiver, factory, registry, mandate, price source, escrow or fee vault; none cross-contract. `CoreVaultHandler` has 3 actors, no transit, no report delivery, no non-USDC pricing, no Mandate spokes, and swallows reverts in 3 calls; `SpokeVaultHandler` has one mock adapter, one pool, Principal sends only. Budget is 256 x 32 (8,192 calls); the whole `ci` profile at 2000 fuzz runs and 512 x 48 invariants costs 25 to 30 s wall, so depth is cheap. Forge 1.8.3 shows near-uniform call counts per handler action but no effective-action rate, and several actions return early (section 2).
Plan: the corpus invariants (INV-CONS, INV-PPS, INV-FEE, INV-EXIT, INV-MAND, INV-VAL, INV-ADP, INV-ORA, INV-NAV, INV-SIG, INV-STATE, INV-ACL) are the source for the property catalogue; runs and depth should grow by at least 10x in CI and 100x in a nightly job.

**G6. Assertions weaker than they look.**
Evidence: 16 bare `vm.expectRevert()`; `AmountBelowMinimum` reached only by a bare expectation; 9 events never referenced (including `PayoutRequested` and `ReturnedToIdle`); `vm.expectCall` used 0 times, so "this call must not happen" properties (for example no call to a paused adapter, no external call while the ledger is inconsistent) are not asserted.
Plan: tighten the 16 to typed reverts, add `expectEmit` for the 9 events, add `expectCall` (count 0) checks for the untouched-dependency properties.

**G7. Build fragility: the deployed compile is not the compile that coverage and other tools may use.**
Evidence: `AcrossBridgeAdapter.sol` does not compile with the optimizer off (section 3.1); `forge coverage` therefore needs `--ir-minimum` and is measured on a different compile than production; under forge 1.8.3, 36 of 63 zero-hit lines and 1 of 81 zero-hit branches are artifacts of that compile (forge 1.0.0 had 5 branch artifacts).
Plan: pin one compile profile per tool, record it in the tooling document, and treat a small refactor of `buildSend` (fewer live values in the 12-argument `encodeCall`) as a candidate change for the founder to approve, since it removes the optimizer dependency for tools and coverage. Not verified: which candidate tools default to optimizer off.

**G8. No headroom for instrumentation on `SpokeVault`.**
Evidence: 932 bytes of runtime margin; `CoreVault` 4,542; libraries 5,361 and 14,031 (section 8).
Plan: run source-instrumenting or assertion-adding tools on a separate build or wrapper, never on the production profile, and budget any production change to `SpokeVault` against the 932 bytes.

**G9. Dead code widens the proof scope.**
Evidence: `CoreVaultLogic.valuation` (public, no caller, 0 hits), `CoreVaultBase._spoke`, `ShareMath.isWholeShares` (section 5.2).
Plan: candidates for removal (founder approval) or a test; either way exclude them from the formal scope explicitly.

**G10. Cheap branch coverage left on the table.**
Evidence: 14 `ZeroAmount` guards (`CoreVault.sol:61,99`, `CoreVaultIncome.sol:31`, `CoreVaultTransit.sol:27,44,64,117`, `SpokeVault.sol:257,283,448,480,488,531,790`), `NoShares` (`CoreVault.sol:152`), `UnknownIncomeToken` (`CoreVaultIncome.sol:30`), `ManagerFeeVault` zero address (`:26`, `:40`), `Mandate.sol:333` `ZeroAdapter`, `ChainlinkPriceSource.sol:88,150` (plus the five constructor guards in G3), `ValueReportReceiver.sol:264`.
Plan: one parametrised test file, no design decision involved.

**G11. Static analysis is not configured; the one free signal is untriaged.**
Evidence: CI runs `forge fmt --check`, `forge build --sizes` and the tests only (`.github/workflows/test.yml`); `forge lint` gives 261 `src/` warnings (section 3.4), including 11 `reentrancy-no-eth` and 28 `non-reentrant-not-first`.
Plan: run Slither and Aderyn first (cheapest, no build changes beyond the profile), triage against this list, and add a lint or analyzer gate to CI only after the baseline is triaged.

## 11. Not verified and open points

- Forge version: figures are forge 1.8.3 unless marked; the machine's default changed from 1.0.0 to 1.8.3 during the measurement (section 0). The executors of the plan should pin the Foundry version (for example with `foundryup --install <version>` or the CI `version:` input) and record it, because branch counts, test counts and lint output differ between versions. Not verified: whether the switch was intended.
- Fork tier not run: its coverage, its pass state and the state of the pinned blocks are unknown. Confirm by running `forge test --match-path "test/fork/**"` with the four environment variables set. `.github/workflows/test.yml` sets the two RPC URLs but the fork step does not set `ARBITRUM_FORK_BLOCK` or `ROBINHOOD_FORK_BLOCK`, which the suites read with `vm.envUint`; Not verified: how CI supplies them (a `.env` is not committed).
- lcov branch semantics (section 4.1) were inferred from three `ManagerFeeVault` records; confirm in the Foundry source or docs.
- The 1 else-branch artifact and the 36 artifact lines are inferred from neighbouring line hits; confirm by rebuilding coverage after `buildSend` compiles without the optimizer, or with a different coverage tool.
- The cause of the `AcrossBridgeAdapter` stack-too-deep is localised to that file; the exact expression is Not verified (section 3.1).
- By-name reference counts above 2 are upper bounds (section 0); they were not used to claim coverage.
- No mutation testing, gas snapshot or differential test was run; none is configured in the repository.
- Corpus mapping of the 14 invariants to INV-* identifiers is left to the property catalogue.


## Appendix A. Raw output (collapsed)

Lines are verbatim from the commands in section 1, except blocks marked "derived" (computed by me from the verbatim files). Directory names: `baseline` holds forge 1.0.0 output, `baseline183` holds forge 1.8.3 output.

<details><summary>A.1 Versions and clone state</summary>

```text
$ ~/.foundry/versions/foundry-rs/foundry/v1.0.0/forge --version
forge Version: 1.0.0-v1.0.0
Commit SHA: 8692e926198056d0228c1e166b1b6c34a5bed66c
Build Timestamp: 2025-02-10T09:05:59.911807000Z (1739178359)
Build Profile: maxperf
$ forge --version (default at the end of the session)
forge Version: 1.8.3
Commit SHA: cae51ad458f6abb64852b7709eb784352429825d
Build Timestamp: 2026-09-15T10:34:23.361078000Z (1789468463)
Build Profile: dist
$ ls -la ~/.foundry/bin/forge
lrwxr-xr-x@ 1 murilovercosa staff 70 Sep 30 14:06 /Users/murilovercosa/.foundry/bin/forge -> /Users/murilovercosa/.foundry/versions/foundry-rs/foundry/v1.8.3/forge
$ git log --oneline -1 (clone)
e5c778a merge: feat/pp-sc-feat-integration into main (consolidation, fund factory, end-to-end scenario, final audit fixes)
$ git status --short (clone, after all runs)
(empty)
```

</details>

<details><summary>A.2 Test runs (runs 1 and 2, both versions)</summary>

```text
# forge 1.0.0, run 1
Ran 53 test suites in 5.34s (27.38s CPU time): 654 tests passed, 0 failed, 0 skipped (654 total tests)
forge test --no-match-path "test/fork/**" > ../baseline/test-unit.log 2>&1  22.21s user 0.70s system 372% cpu 6.156 total
[PASS] invariant_Q60_indexNeverDecreases() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_Q60_owedPlusTakenNeverExceedsDistributed() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC080_ledgerNeverExceedsBalance() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC093_reportSequenceStrictlyIncreases() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_Q60_cumulativeIncomeNeverDecreases() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC072_payoutReserveWithinIdle() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC080_balanceCoversLedger() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC080_directTransferNeverMovesSharePrice() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC091_supplyIsWholeShares() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC104_shareAssetsEqualBuckets() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_Q60_indexNeverDecreases() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC004_allowanceAlwaysZero() (runs: 256, calls: 8192, reverts: 0)
[PASS] invariant_DEC091_totalSupplyIsWholeShares() (runs: 256, calls: 8192, reverts: 0)
# forge 1.0.0, run 2 (ci)
Ran 53 test suites in 23.67s (135.89s CPU time): 654 tests passed, 0 failed, 0 skipped (654 total tests)
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/**" >  2>&1  86.54s user 2.36s system 354% cpu 25.065 total
[PASS] invariant_DEC004_allowanceAlwaysZero() (runs: 512, calls: 24576, reverts: 0)
[PASS] invariant_DEC091_totalSupplyIsWholeShares() (runs: 512, calls: 24576, reverts: 0)
[PASS] invariant_Q60_indexNeverDecreases() (runs: 512, calls: 24576, reverts: 0)
(11 more invariant lines omitted, all runs: 512, calls: 24576, reverts: 0)
# forge 1.8.3, run 1
Compiling 46 files with Solc 0.8.28
Solc 0.8.28 finished in 100.26s
Ran 53 test suites in 9.33s (44.21s CPU time): 644 tests passed, 0 failed, 0 skipped (644 total tests)
forge test --no-match-path "test/fork/**" > ../baseline183/test-unit.log 2>&1  47.02s user 4.49s system 43% cpu 1:58.42 total
# forge 1.8.3, run 1: fail or skip lines
(none)
Ran 1 test for test/unit/ShareToken.t.sol:ShareTokenInvariantTest
[PASS]
ShareTokenInvariantTest invariants:
[PASS] invariant_DEC004_allowanceAlwaysZero
[PASS] invariant_DEC091_totalSupplyIsWholeShares
 ShareTokenInvariantTest invariants (runs: 256, calls: 8192, reverts: 0)

╭-------------------+----------------+-------+---------+----------╮
| Contract          | Selector       | Calls | Reverts | Discards |
+=================================================================+
| ShareTokenHandler | burnFractional | 1627  | 0       | 0        |
|-------------------+----------------+-------+---------+----------|
| ShareTokenHandler | burnWhole      | 1674  | 0       | 0        |
|-------------------+----------------+-------+---------+----------|
| ShareTokenHandler | mintFractional | 1637  | 0       | 0        |
|-------------------+----------------+-------+---------+----------|
| ShareTokenHandler | mintWhole      | 1640  | 0       | 0        |
|-------------------+----------------+-------+---------+----------|
| ShareTokenHandler | transfer       | 1614  | 0       | 0        |
╰-------------------+----------------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 1.30s (1.29s CPU time)
Ran 1 test for test/unit/spoke/SpokeVaultInvariant.t.sol:SpokeVaultInvariantTest
[PASS]
SpokeVaultInvariantTest invariants:
[PASS] invariant_DEC080_ledgerNeverExceedsBalance
[PASS] invariant_DEC093_reportSequenceStrictlyIncreases
[PASS] invariant_Q60_cumulativeIncomeNeverDecreases
 SpokeVaultInvariantTest invariants (runs: 256, calls: 8192, reverts: 0)

╭-------------------+------------+-------+---------+----------╮
| Contract          | Selector   | Calls | Reverts | Discards |
+=============================================================+
| SpokeVaultHandler | arrive     | 574   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | close      | 592   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | collect    | 588   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | decrease   | 580   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | donate     | 643   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | earnIncome | 607   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | increase   | 588   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | open       | 599   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | refund     | 557   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | report     | 559   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | sendHome   | 569   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | swap       | 558   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | sweep      | 588   | 0       | 0        |
|-------------------+------------+-------+---------+----------|
| SpokeVaultHandler | warp       | 590   | 0       | 0        |
╰-------------------+------------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.20s (3.19s CPU time)
Ran 1 test for test/unit/IncomeAccumulator.t.sol:IncomeAccumulatorInvariantTest
[PASS]
IncomeAccumulatorInvariantTest invariants:
[PASS] invariant_Q60_indexNeverDecreases
[PASS] invariant_Q60_owedPlusTakenNeverExceedsDistributed
 IncomeAccumulatorInvariantTest invariants (runs: 256, calls: 8192, reverts: 0)

╭--------------------------+-----------+-------+---------+----------╮
| Contract                 | Selector  | Calls | Reverts | Discards |
+===================================================================+
| IncomeAccumulatorHandler | burn      | 2039  | 0       | 0        |
|--------------------------+-----------+-------+---------+----------|
| IncomeAccumulatorHandler | mint      | 2081  | 0       | 0        |
|--------------------------+-----------+-------+---------+----------|
| IncomeAccumulatorHandler | recognize | 1996  | 0       | 0        |
|--------------------------+-----------+-------+---------+----------|
| IncomeAccumulatorHandler | take      | 2076  | 0       | 0        |
╰--------------------------+-----------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 3.81s (3.81s CPU time)
Ran 1 test for test/unit/core/CoreVaultInvariant.t.sol:CoreVaultInvariantTest
[PASS]
CoreVaultInvariantTest invariants:
[PASS] invariant_DEC072_payoutReserveWithinIdle
[PASS] invariant_DEC080_balanceCoversLedger
[PASS] invariant_DEC080_directTransferNeverMovesSharePrice
[PASS] invariant_DEC091_supplyIsWholeShares
[PASS] invariant_DEC104_shareAssetsEqualBuckets
[PASS] invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated
[PASS] invariant_Q60_indexNeverDecreases
 CoreVaultInvariantTest invariants (runs: 256, calls: 8192, reverts: 0)

╭------------------+----------------+-------+---------+----------╮
| Contract         | Selector       | Calls | Reverts | Discards |
+================================================================+
| CoreVaultHandler | allocate       | 944   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | claim          | 898   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | deposit        | 916   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | donate         | 882   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | forwardIncome  | 912   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | movePrice      | 928   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | requestPayout  | 935   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | warp           | 937   | 0       | 0        |
|------------------+----------------+-------+---------+----------|
| CoreVaultHandler | withdrawIncome | 840   | 0       | 0        |
╰------------------+----------------+-------+---------+----------╯

Suite result: ok. 1 passed; 0 failed; 0 skipped; finished in 8.67s (8.62s CPU time)
# forge 1.8.3, run 2 (ci)
 ShareTokenInvariantTest invariants (runs: 512, calls: 24576, reverts: 0)
 IncomeAccumulatorInvariantTest invariants (runs: 512, calls: 24576, reverts: 0)
 SpokeVaultInvariantTest invariants (runs: 512, calls: 24576, reverts: 0)
 CoreVaultInvariantTest invariants (runs: 512, calls: 24576, reverts: 0)
Ran 53 test suites in 26.93s (153.74s CPU time): 644 tests passed, 0 failed, 0 skipped (644 total tests)
FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/**" >  2>&1  84.00s user 2.80s system 285% cpu 30.389 total
# suites that ran more tests than they declare (forge 1.0.0 log)
Ran 25 tests for test/unit/aave/AaveV3Adapter.t.sol:AaveV3AdapterHalfUpRoundingTest
Ran 25 tests for test/unit/aave/AaveV3Adapter.t.sol:AaveV3AdapterTest
Ran 2 tests for test/unit/aave/AaveV3AdapterLifecycle.t.sol:AaveV3AdapterLifecycleHalfUpTest
Ran 2 tests for test/unit/aave/AaveV3AdapterLifecycle.t.sol:AaveV3AdapterLifecycleTest
```

</details>

<details><summary>A.3 Coverage: failure without --ir-minimum, and the src/ rows with it (both versions)</summary>

```text
# run 3, forge 1.0.0
Warning: optimizer settings have been disabled for accurate coverage reports, if you encounter "stack too deep" errors, consider using `--ir-minimum` which enables viaIR with minimum optimization resolving most of the errors
Compiling 268 files with Solc 0.8.28
Solc 0.8.28 finished in 4.16s
Error: Compiler run failed:
Error: Compiler error (/solidity/libyul/backends/evm/AsmCodeGen.cpp:68):Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables. When compiling inline assembly: Variable value0 is 1 slot(s) too deep inside the stack. Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.
CompilerError: Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables. When compiling inline assembly: Variable value0 is 1 slot(s) too deep inside the stack. Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables.

forge coverage --no-match-path "test/fork/**" --report summary >  2>&1  4.24s user 0.76s system 95% cpu 5.246 total
# run 3, forge 1.8.3
Warning: optimizer settings and `viaIR` have been disabled for accurate coverage reports.
If you encounter "stack too deep" errors, consider using `--ir-minimum` which enables `viaIR` with minimum optimization resolving most of the errors.
See more: https://book.getfoundry.sh/guides/best-practices/stack-too-deep
Compiling 227 files with Solc 0.8.28
Solc 0.8.28 finished in 2.02s
Error: Compiler run failed:
Error: Compiler error (/solidity/libyul/backends/evm/AsmCodeGen.cpp:68):Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables. When compiling inline assembly: Variable value0 is 1 slot

forge coverage --no-match-path "test/fork/**" --report summary >  2>&1  1.70s user 0.42s system 85% cpu 2.473 total
# run 4, forge 1.0.0: solc time, suite line, wall time
Solc 0.8.28 finished in 129.70s
Ran 53 test suites in 20.71s (108.45s CPU time): 654 tests passed, 0 failed, 0 skipped (654 total tests)
forge coverage --ir-minimum --no-match-path "test/fork/**" --report summary >  184.10s user 7.84s system 124% cpu 2:33.64 total
# run 4, forge 1.0.0: table header, src rows, total
| File                                                     | % Lines            | % Statements       | % Branches       | % Funcs          |
| src/adapters/AaveV3Adapter.sol                           | 96.86% (185/191)   | 96.61% (228/236)   | 88.57% (31/35)   | 100.00% (26/26)  |
| src/adapters/AcrossBridgeAdapter.sol                     | 100.00% (25/25)    | 100.00% (33/33)    | 100.00% (5/5)    | 100.00% (5/5)    |
| src/adapters/AdapterGuard.sol                            | 100.00% (14/14)    | 100.00% (11/11)    | 100.00% (4/4)    | 100.00% (5/5)    |
| src/adapters/UniswapV4Adapter.sol                        | 99.18% (243/245)   | 98.45% (317/322)   | 90.62% (29/32)   | 100.00% (33/33)  |
| src/core/CoreVault.sol                                   | 98.21% (110/112)   | 96.48% (137/142)   | 89.66% (26/29)   | 100.00% (7/7)    |
| src/core/CoreVaultBase.sol                               | 97.86% (137/140)   | 97.66% (167/171)   | 84.62% (11/13)   | 96.55% (28/29)   |
| src/core/CoreVaultIncome.sol                             | 100.00% (41/41)    | 94.74% (36/38)     | 66.67% (4/6)     | 100.00% (12/12)  |
| src/core/CoreVaultLogic.sol                              | 96.31% (287/298)   | 94.75% (379/400)   | 84.09% (37/44)   | 93.94% (31/33)   |
| src/core/CoreVaultTransit.sol                            | 95.24% (40/42)     | 87.23% (41/47)     | 60.00% (6/10)    | 100.00% (8/8)    |
| src/core/ManagerFeeVault.sol                             | 100.00% (11/11)    | 85.71% (12/14)     | 33.33% (1/3)     | 100.00% (3/3)    |
| src/core/ManagerRegistry.sol                             | 100.00% (18/18)    | 100.00% (19/19)    | 100.00% (3/3)    | 100.00% (5/5)    |
| src/core/ShareToken.sol                                  | 100.00% (19/19)    | 100.00% (17/17)    | 100.00% (4/4)    | 100.00% (8/8)    |
| src/core/TransitEscrow.sol                               | 100.00% (11/11)    | 100.00% (14/14)    | 100.00% (4/4)    | 100.00% (3/3)    |
| src/factory/CodeStore.sol                                | 89.29% (25/28)     | 90.24% (37/41)     | 66.67% (2/3)     | 100.00% (2/2)    |
| src/factory/Create3.sol                                  | 90.00% (18/20)     | 83.33% (20/24)     | 60.00% (3/5)     | 100.00% (5/5)    |
| src/factory/Create3Deployer.sol                          | 100.00% (7/7)      | 100.00% (6/6)      | 100.00% (0/0)    | 100.00% (3/3)    |
| src/factory/FundFactory.sol                              | 97.24% (211/217)   | 95.94% (260/271)   | 75.00% (24/32)   | 100.00% (24/24)  |
| src/libraries/IncomeAccumulator.sol                      | 100.00% (91/91)    | 100.00% (91/91)    | 100.00% (16/16)  | 100.00% (11/11)  |
| src/libraries/ReportCodec.sol                            | 100.00% (9/9)      | 100.00% (11/11)    | 100.00% (2/2)    | 100.00% (3/3)    |
| src/libraries/ShareMath.sol                              | 92.31% (24/26)     | 89.66% (26/29)     | 100.00% (5/5)    | 88.89% (8/9)     |
| src/libraries/TransitMessage.sol                         | 100.00% (6/6)      | 100.00% (7/7)      | 100.00% (1/1)    | 100.00% (2/2)    |
| src/mandate/Mandate.sol                                  | 100.00% (118/118)  | 99.50% (198/199)   | 96.77% (30/31)   | 100.00% (16/16)  |
| src/report/ChainlinkPriceSource.sol                      | 100.00% (41/41)    | 96.49% (55/57)     | 83.33% (10/12)   | 100.00% (6/6)    |
| src/report/ValueReportReceiver.sol                       | 100.00% (74/74)    | 98.99% (98/99)     | 93.75% (15/16)   | 100.00% (14/14)  |
| src/spoke/SpokeCrossChainLib.sol                         | 95.83% (161/168)   | 96.00% (192/200)   | 86.36% (19/22)   | 100.00% (16/16)  |
| src/spoke/SpokeVault.sol                                 | 95.30% (385/404)   | 91.54% (422/461)   | 70.13% (54/77)   | 100.00% (72/72)  |
| src/spoke/SpokeVaultTypes.sol                            | 100.00% (2/2)      | 100.00% (2/2)      | 100.00% (0/0)    | 100.00% (1/1)    |
| Total                                                    | 80.06% (3777/4718) | 79.52% (4248/5342) | 69.12% (414/599) | 87.31% (695/796) |
# run 4, forge 1.8.3: solc time, suite line, wall time
Solc 0.8.28 finished in 281.23s
Ran 53 test suites in 32.02s (129.79s CPU time): 644 tests passed, 0 failed, 0 skipped (644 total tests)
forge coverage --ir-minimum --no-match-path "test/fork/**" --report summary >  166.07s user 14.75s system 52% cpu 5:41.20 total
# run 4, forge 1.8.3: table header, src rows, total
| File                                                     | % Lines            | % Statements       | % Branches       | % Funcs          |
| src/adapters/AaveV3Adapter.sol                           | 97.38% (186/191)   | 95.30% (223/234)   | 79.07% (34/43)   | 100.00% (26/26)  |
| src/adapters/AcrossBridgeAdapter.sol                     | 100.00% (25/25)    | 96.97% (32/33)     | 80.00% (4/5)     | 100.00% (5/5)    |
| src/adapters/AdapterGuard.sol                            | 100.00% (15/15)    | 100.00% (12/12)    | 100.00% (5/5)    | 100.00% (5/5)    |
| src/adapters/UniswapV4Adapter.sol                        | 99.18% (243/245)   | 98.47% (322/327)   | 91.89% (34/37)   | 100.00% (33/33)  |
| src/core/CoreVault.sol                                   | 98.23% (111/113)   | 96.38% (133/138)   | 90.32% (28/31)   | 100.00% (8/8)    |
| src/core/CoreVaultBase.sol                               | 97.87% (138/141)   | 97.70% (170/174)   | 87.50% (14/16)   | 96.55% (28/29)   |
| src/core/CoreVaultIncome.sol                             | 100.00% (41/41)    | 92.50% (37/40)     | 62.50% (5/8)     | 100.00% (12/12)  |
| src/core/CoreVaultLogic.sol                              | 96.32% (288/299)   | 94.40% (388/411)   | 87.88% (58/66)   | 93.94% (31/33)   |
| src/core/CoreVaultTransit.sol                            | 95.24% (40/42)     | 87.50% (42/48)     | 63.64% (7/11)    | 100.00% (8/8)    |
| src/core/ManagerFeeVault.sol                             | 100.00% (11/11)    | 85.71% (12/14)     | 33.33% (1/3)     | 100.00% (3/3)    |
| src/core/ManagerRegistry.sol                             | 100.00% (18/18)    | 100.00% (18/18)    | 100.00% (3/3)    | 100.00% (6/6)    |
| src/core/ShareToken.sol                                  | 100.00% (19/19)    | 100.00% (17/17)    | 100.00% (4/4)    | 100.00% (8/8)    |
| src/core/TransitEscrow.sol                               | 100.00% (11/11)    | 100.00% (14/14)    | 100.00% (4/4)    | 100.00% (3/3)    |
| src/factory/CodeStore.sol                                | 89.29% (25/28)     | 90.24% (37/41)     | 66.67% (2/3)     | 100.00% (2/2)    |
| src/factory/Create3.sol                                  | 90.00% (18/20)     | 83.33% (20/24)     | 60.00% (3/5)     | 100.00% (5/5)    |
| src/factory/Create3Deployer.sol                          | 100.00% (7/7)      | 100.00% (6/6)      | N/A (0/0)        | 100.00% (3/3)    |
| src/factory/FundFactory.sol                              | 97.26% (213/219)   | 96.03% (266/277)   | 78.95% (30/38)   | 100.00% (24/24)  |
| src/libraries/IncomeAccumulator.sol                      | 100.00% (91/91)    | 100.00% (95/95)    | 100.00% (20/20)  | 100.00% (11/11)  |
| src/libraries/ReportCodec.sol                            | 100.00% (9/9)      | 100.00% (11/11)    | 100.00% (2/2)    | 100.00% (3/3)    |
| src/libraries/ShareMath.sol                              | 92.31% (24/26)     | 90.00% (27/30)     | 100.00% (6/6)    | 88.89% (8/9)     |
| src/libraries/TransitMessage.sol                         | 100.00% (6/6)      | 100.00% (7/7)      | 100.00% (1/1)    | 100.00% (2/2)    |
| src/mandate/Mandate.sol                                  | 100.00% (118/118)  | 99.52% (206/207)   | 97.44% (38/39)   | 100.00% (16/16)  |
| src/report/ChainlinkPriceSource.sol                      | 100.00% (41/41)    | 87.93% (51/58)     | 46.15% (6/13)    | 100.00% (6/6)    |
| src/report/ValueReportReceiver.sol                       | 100.00% (74/74)    | 98.00% (98/100)    | 88.24% (15/17)   | 100.00% (14/14)  |
| src/spoke/SpokeCrossChainLib.sol                         | 95.81% (160/167)   | 96.04% (194/202)   | 86.96% (20/23)   | 100.00% (16/16)  |
| src/spoke/SpokeVault.sol                                 | 95.30% (385/404)   | 91.65% (439/479)   | 76.34% (71/93)   | 100.00% (72/72)  |
| src/spoke/SpokeVaultTypes.sol                            | 100.00% (2/2)      | 100.00% (2/2)      | N/A (0/0)        | 100.00% (1/1)    |
| Total                                                    | 88.73% (3746/4222) | 87.67% (4259/4858) | 72.29% (514/711) | 91.41% (702/768) |
```

</details>

<details><summary>A.4 lcov totals per src file (both versions)</summary>

```text
# derived from lcov.info: LF/LH lines, FNF/FNH functions, BRF/BRH branches per src file; 1.0.0 then 1.8.3
src/adapters/AaveV3Adapter.sol | 1.0.0 LF 191 LH 185 FNF 26 FNH 26 BRF 35 BRH 31 | 1.8.3 LF 191 LH 186 FNF 26 FNH 26 BRF 43 BRH 34
src/adapters/AcrossBridgeAdapter.sol | 1.0.0 LF 25 LH 25 FNF 5 FNH 5 BRF 5 BRH 5 | 1.8.3 LF 25 LH 25 FNF 5 FNH 5 BRF 5 BRH 4
src/adapters/AdapterGuard.sol | 1.0.0 LF 14 LH 14 FNF 5 FNH 5 BRF 4 BRH 4 | 1.8.3 LF 15 LH 15 FNF 5 FNH 5 BRF 5 BRH 5
src/adapters/UniswapV4Adapter.sol | 1.0.0 LF 245 LH 243 FNF 33 FNH 33 BRF 32 BRH 29 | 1.8.3 LF 245 LH 243 FNF 33 FNH 33 BRF 37 BRH 34
src/core/CoreVault.sol | 1.0.0 LF 112 LH 110 FNF 7 FNH 7 BRF 29 BRH 26 | 1.8.3 LF 113 LH 111 FNF 8 FNH 8 BRF 31 BRH 28
src/core/CoreVaultBase.sol | 1.0.0 LF 140 LH 137 FNF 29 FNH 28 BRF 13 BRH 11 | 1.8.3 LF 141 LH 138 FNF 29 FNH 28 BRF 16 BRH 14
src/core/CoreVaultIncome.sol | 1.0.0 LF 41 LH 41 FNF 12 FNH 12 BRF 6 BRH 4 | 1.8.3 LF 41 LH 41 FNF 12 FNH 12 BRF 8 BRH 5
src/core/CoreVaultLogic.sol | 1.0.0 LF 298 LH 287 FNF 33 FNH 31 BRF 44 BRH 37 | 1.8.3 LF 299 LH 288 FNF 33 FNH 31 BRF 66 BRH 58
src/core/CoreVaultTransit.sol | 1.0.0 LF 42 LH 40 FNF 8 FNH 8 BRF 10 BRH 6 | 1.8.3 LF 42 LH 40 FNF 8 FNH 8 BRF 11 BRH 7
src/core/ManagerFeeVault.sol | 1.0.0 LF 11 LH 11 FNF 3 FNH 3 BRF 3 BRH 1 | 1.8.3 LF 11 LH 11 FNF 3 FNH 3 BRF 3 BRH 1
src/core/ManagerRegistry.sol | 1.0.0 LF 18 LH 18 FNF 5 FNH 5 BRF 3 BRH 3 | 1.8.3 LF 18 LH 18 FNF 6 FNH 6 BRF 3 BRH 3
src/core/ShareToken.sol | 1.0.0 LF 19 LH 19 FNF 8 FNH 8 BRF 4 BRH 4 | 1.8.3 LF 19 LH 19 FNF 8 FNH 8 BRF 4 BRH 4
src/core/TransitEscrow.sol | 1.0.0 LF 11 LH 11 FNF 3 FNH 3 BRF 4 BRH 4 | 1.8.3 LF 11 LH 11 FNF 3 FNH 3 BRF 4 BRH 4
src/factory/CodeStore.sol | 1.0.0 LF 28 LH 25 FNF 2 FNH 2 BRF 3 BRH 2 | 1.8.3 LF 28 LH 25 FNF 2 FNH 2 BRF 3 BRH 2
src/factory/Create3.sol | 1.0.0 LF 20 LH 18 FNF 5 FNH 5 BRF 5 BRH 3 | 1.8.3 LF 20 LH 18 FNF 5 FNH 5 BRF 5 BRH 3
src/factory/Create3Deployer.sol | 1.0.0 LF 7 LH 7 FNF 3 FNH 3 BRF 0 BRH 0 | 1.8.3 LF 7 LH 7 FNF 3 FNH 3 BRF 0 BRH 0
src/factory/FundFactory.sol | 1.0.0 LF 217 LH 211 FNF 24 FNH 24 BRF 32 BRH 24 | 1.8.3 LF 219 LH 213 FNF 24 FNH 24 BRF 38 BRH 30
src/libraries/IncomeAccumulator.sol | 1.0.0 LF 91 LH 91 FNF 11 FNH 11 BRF 16 BRH 16 | 1.8.3 LF 91 LH 91 FNF 11 FNH 11 BRF 20 BRH 20
src/libraries/ReportCodec.sol | 1.0.0 LF 9 LH 9 FNF 3 FNH 3 BRF 2 BRH 2 | 1.8.3 LF 9 LH 9 FNF 3 FNH 3 BRF 2 BRH 2
src/libraries/ShareMath.sol | 1.0.0 LF 26 LH 24 FNF 9 FNH 8 BRF 5 BRH 5 | 1.8.3 LF 26 LH 24 FNF 9 FNH 8 BRF 6 BRH 6
src/libraries/TransitMessage.sol | 1.0.0 LF 6 LH 6 FNF 2 FNH 2 BRF 1 BRH 1 | 1.8.3 LF 6 LH 6 FNF 2 FNH 2 BRF 1 BRH 1
src/mandate/Mandate.sol | 1.0.0 LF 118 LH 118 FNF 16 FNH 16 BRF 31 BRH 30 | 1.8.3 LF 118 LH 118 FNF 16 FNH 16 BRF 39 BRH 38
src/report/ChainlinkPriceSource.sol | 1.0.0 LF 41 LH 41 FNF 6 FNH 6 BRF 12 BRH 10 | 1.8.3 LF 41 LH 41 FNF 6 FNH 6 BRF 13 BRH 6
src/report/ValueReportReceiver.sol | 1.0.0 LF 74 LH 74 FNF 14 FNH 14 BRF 16 BRH 15 | 1.8.3 LF 74 LH 74 FNF 14 FNH 14 BRF 17 BRH 15
src/spoke/SpokeCrossChainLib.sol | 1.0.0 LF 168 LH 161 FNF 16 FNH 16 BRF 22 BRH 19 | 1.8.3 LF 167 LH 160 FNF 16 FNH 16 BRF 23 BRH 20
src/spoke/SpokeVault.sol | 1.0.0 LF 404 LH 385 FNF 72 FNH 72 BRF 77 BRH 54 | 1.8.3 LF 404 LH 385 FNF 72 FNH 72 BRF 93 BRH 71
src/spoke/SpokeVaultTypes.sol | 1.0.0 LF 2 LH 2 FNF 1 FNH 1 BRF 0 BRH 0 | 1.8.3 LF 2 LH 2 FNF 1 FNH 1 BRF 0 BRH 0
```

</details>

<details><summary>A.5 lcov evidence used to classify artifacts (sections 4.1 to 4.3)</summary>

```text
# forge 1.8.3: SpokeVault.sol lines 143-162 (constructor if/else at 151)
DA:143,98
DA:144,98
BRDA:144,3,0,1
DA:145,97
BRDA:145,4,0,0
DA:146,97
BRDA:146,5,0,1
DA:147,1
DA:150,97
DA:151,97
BRDA:151,6,0,27
BRDA:151,6,1,0
DA:152,27
BRDA:152,7,0,0
DA:153,27
BRDA:153,8,0,1
DA:155,70
DA:156,70
BRDA:156,9,0,0
DA:157,70
BRDA:157,10,0,1
DA:158,1
DA:160,69
DA:162,69
# forge 1.8.3: SpokeVault.sol lines 826-836 (_unwindStep)
DA:827,24
DA:828,41
DA:829,23
DA:830,23
BRDA:830,58,0,0
DA:831,23
DA:832,23
BRDA:832,59,0,7
DA:833,23
DA:834,23
DA:836,0
FNDA for _unwindStep:
FNDA:24,SpokeVault._unwindStep
# forge 1.8.3: SpokeVault.sol lines 877-892 (_unwindRoute)
DA:878,44
DA:879,44
BRDA:879,61,0,26
DA:880,25
DA:881,7
BRDA:881,62,0,7
DA:883,18
BRDA:883,63,0,18
BRDA:883,63,1,2
DA:884,18
BRDA:884,64,0,2
DA:885,2
DA:887,16
DA:889,0
BRDA:889,65,0,-
DA:890,0
DA:891,2
BRDA:891,66,0,2
DA:892,2
# forge 1.0.0: SpokeVault.sol lines 756-766 (_exit) and 883
DA:756,490
DA:757,490
DA:758,490
BRDA:758,46,0,161
BRDA:758,46,1,-
DA:759,161
DA:760,161
DA:761,329
BRDA:761,47,0,166
BRDA:761,47,1,-
DA:762,166
DA:763,165
BRDA:763,48,0,2
BRDA:763,48,1,163
DA:764,2
DA:766,163
DA:883,18
BRDA:883,63,0,18
BRDA:883,63,1,-
DA:884,18
BRDA:884,64,0,2
DA:885,2
DA:887,16
DA:889,0
BRDA:889,65,0,-
DA:890,0
DA:891,0
BRDA:891,66,0,2
# forge 1.0.0: CoreVaultLogic.sol lines 328-348 (_price)
DA:328,1162
DA:329,39
DA:331,1124
DA:332,1124
BRDA:332,17,0,9
BRDA:332,17,1,-
DA:333,9
DA:334,6
DA:335,3
DA:336,3
DA:337,3
DA:340,1115
DA:341,1115
DA:342,1114
BRDA:342,18,0,1
DA:343,1
DA:346,1122
BRDA:346,19,0,-
DA:347,3
DA:348,3
# forge 1.8.3: AaveV3Adapter.sol lines 405-408, 429, 445, 482-489
DA:405,1042
BRDA:405,19,0,1042
BRDA:405,19,1,0
DA:406,1042
DA:408,0
DA:429,4164
BRDA:429,21,0,0
DA:445,3644
BRDA:445,23,0,0
DA:482,7810
BRDA:482,30,0,3641
BRDA:482,30,1,4169
DA:483,3641
BRDA:483,31,0,3641
DA:484,3641
DA:485,0
BRDA:485,31,1,-
DA:486,0
DA:489,4169
# forge 1.8.3: SpokeVault.sol line 389-390 and CoreVault.sol 66
DA:389,0
DA:390,645
DA:66,0
# forge 1.8.3: ManagerFeeVault.sol (whole record)
SF:src/core/ManagerFeeVault.sol
DA:25,691
FN:25,ManagerFeeVault.constructor
FNDA:691,ManagerFeeVault.constructor
DA:26,691
BRDA:26,0,0,0
DA:27,691
DA:28,691
DA:32,519
FN:32,ManagerFeeVault.balanceOf
FNDA:519,ManagerFeeVault.balanceOf
DA:33,519
DA:38,2
FN:38,ManagerFeeVault.withdraw
FNDA:2,ManagerFeeVault.withdraw
DA:39,2
BRDA:39,1,0,1
DA:40,1
BRDA:40,2,0,0
DA:41,1
DA:42,1
FNF:3
FNH:3
LF:11
LH:11
BRF:3
BRH:1
end_of_record
# forge 1.0.0: ManagerFeeVault.sol BRDA lines
BRDA:26,0,0,-
BRDA:39,1,0,1
BRDA:40,2,0,-
# forge 1.8.3: UniswapV4Adapter.sol line 655
DA:654,6874
DA:655,6874
BRDA:655,27,0,2
```

</details>

<details><summary>A.6 forge build --sizes rows and build times</summary>

```text
# forge 1.8.3, run 6 (runtime size, initcode size, runtime margin, initcode margin; spacing squeezed)
| Contract | Runtime Size (B) | Initcode Size (B) | Runtime Margin (B) | Initcode Margin (B) |
| AaveV3Adapter | 10,133 | 11,795 | 14,443 | 37,357 |
| AcrossBridgeAdapter | 2,347 | 2,906 | 22,229 | 46,246 |
| ChainlinkPriceSource | 1,420 | 3,683 | 23,156 | 45,469 |
| CoreVault | 20,034 | 34,084 | 4,542 | 15,068 |
| CoreVaultLogic | 19,215 | 19,267 | 5,361 | 29,885 |
| Create3Deployer | 1,342 | 1,370 | 23,234 | 47,782 |
| FundFactory | 16,084 | 19,969 | 8,492 | 29,183 |
| ManagerFeeVault | 1,077 | 1,355 | 23,499 | 47,797 |
| ManagerRegistry | 1,530 | 1,803 | 23,046 | 47,349 |
| ShareToken | 1,822 | 2,603 | 22,754 | 46,549 |
| SpokeVault | 23,644 | 32,630 | 932 | 16,522 |
| TransitEscrow | 894 | 939 | 23,682 | 48,213 |
| UniswapV4Adapter | 17,854 | 19,482 | 6,722 | 29,670 |
| ValueReportReceiver | 7,846 | 9,267 | 16,730 | 39,885 |
# forge 1.8.3: SpokeCrossChainLib is not in the table; from out/SpokeCrossChainLib.sol/SpokeCrossChainLib.json: runtime 10545 initcode 10597
# forge 1.0.0, run 6 rows
| CoreVault | 20,034 | 34,084 | 4,542 | 15,068 |
| SpokeCrossChainLib | 10,545 | 10,597 | 14,031 | 38,555 |
| SpokeVault | 23,644 | 32,630 | 932 | 16,522 |
# run 7
forge 1.0.0: forge build --force > ../baseline/build-force.log 2>&1  28.38s user 1.00s system 96% cpu 30.308 total
forge 1.8.3: forge build --force > ../baseline183/build-force.log 2>&1  57.60s user 9.29s system 44% cpu 2:29.70 total
1.0.0: Compiling 268 files with Solc 0.8.28
1.0.0: Solc 0.8.28 finished in 29.48s
1.0.0: Compiler run successful with warnings:
1.8.3: Compiling 268 files with Solc 0.8.28
1.8.3: Solc 0.8.28 finished in 143.79s
1.8.3: Compiler run successful with warnings:
```

</details>

<details><summary>A.7 Optimizer-off bisection (run 8, forge 1.8.3), verbatim</summary>

```text
$ forge build src/adapters/AcrossBridgeAdapter.sol --optimize false --force --out <scratchpad>/out-noopt --cache-path <scratchpad>/cache-noopt
Compiling 5 files with Solc 0.8.28
Solc 0.8.28 finished in 712.45ms
Error: Compiler run failed:
Error: Compiler error (/solidity/libyul/backends/evm/AsmCodeGen.cpp:68):Stack too deep. Try compiling with `--via-ir` (cli) or the equivalent `viaIR: true` (standard JSON) while enabling the optimizer. Otherwise, try removing local variables. When compiling inline assembly: Variable value0 is 1 slot(s) too deep inside the stack.
$ same command with --via-ir added
Compiling 5 files with Solc 0.8.28
Solc 0.8.28 finished in 1.70s
Compiler run successful!
warning[unsafe-typecast]: typecast can truncate values
    ╭▸ src/adapters/AcrossBridgeAdapter.sol:104:31
    │
104 │         uint32 fillDeadline = uint32(block.timestamp) + FILL_DEADLINE_SECONDS;
    │                               ━━━━━━━━━━━━━━━━━━━━━━━
    │
    ├ note: consider disabling this lint if you're certain the cast is safe
    │       
    │       // casting to 'uint32' is safe because [explain why]
    │       // forge-lint: disable-next-line(unsafe-typecast)
    │       
    │       
    ╰ help: https://getfoundry.sh/forge/linting/unsafe-typecast

$ loop: forge build <each src file> --optimize false ..., print files whose output contains "Compiler run failed"
src/adapters/AcrossBridgeAdapter.sol -> FAIL
(all other src files: Compiler run successful)

```

</details>

<details><summary>A.8 Errors and events never referenced by name</summary>

```text
# derived: custom errors (169 declared) never referenced by name in test/
AmountBelowMinimum ['src/adapters/UniswapV4Adapter.sol']
ChunkWriteFailed ['src/factory/CodeStore.sol']
BridgeAdapterCodehashMismatch ['src/interfaces/ICoreVault.sol']
InvalidAavePoolKey ['src/interfaces/IFundFactory.sol']
AdapterHasNoCode ['src/spoke/SpokeVaultTypes.sol']
ZeroBridgeTarget ['src/spoke/SpokeVaultTypes.sol']
AdapterUsedAboveInput ['src/spoke/SpokeVaultTypes.sol']
PositionAlreadyRegistered ['src/spoke/SpokeVaultTypes.sol']
SwapOutputBelowMinimum ['src/spoke/SpokeVaultTypes.sol']
MissingUnwindSwap ['src/spoke/SpokeVaultTypes.sol']
RefundReleaseMismatch ['src/spoke/SpokeVaultTypes.sol']
# derived: events (54 declared) never referenced by name in test/
PoolRegistered ['src/adapters/UniswapV4Adapter.sol']
Deployed ['src/factory/Create3Deployer.sol']
PayoutRequested ['src/interfaces/ICoreVault.sol']
ReturnedToIdle ['src/interfaces/ICoreVault.sol']
ArrivalHeldApart ['src/interfaces/ICoreVault.sol']
SpokeCreated ['src/interfaces/IFundFactory.sol']
IncomeRecognized ['src/libraries/IncomeAccumulator.sol']
IncomeDistributed ['src/libraries/IncomeAccumulator.sol']
IncomeTokenRegistered ['src/libraries/IncomeAccumulator.sol']
```

</details>

<details><summary>A.9 External and public functions: by-name references and lcov hits (168 rows)</summary>

```text
# derived: file:line contract.function visibility | by-name refs in test/unit | in test/fork | lcov hits (forge 1.8.3)
src/adapters/AaveV3Adapter.sol:146 AaveV3Adapter.isExactValue external | 2 | 0 | 2
src/adapters/AaveV3Adapter.sol:152 AaveV3Adapter.poolTokens external | 9 | 5 | 46
src/adapters/AaveV3Adapter.sol:164 AaveV3Adapter.openPosition external | 41 | 8 | 1608
src/adapters/AaveV3Adapter.sol:190 AaveV3Adapter.increasePosition external | 17 | 2 | 4019
src/adapters/AaveV3Adapter.sol:225 AaveV3Adapter.decreasePosition external | 29 | 5 | 4177
src/adapters/AaveV3Adapter.sol:250 AaveV3Adapter.closePosition external | 27 | 4 | 1046
src/adapters/AaveV3Adapter.sol:274 AaveV3Adapter.collectIncome external | 23 | 6 | 4656
src/adapters/AaveV3Adapter.sol:287 AaveV3Adapter.swapExactInput external | 16 | 2 | 2
src/adapters/AaveV3Adapter.sol:298 AaveV3Adapter.positionValue external | 45 | 38 | 5711
src/adapters/AaveV3Adapter.sol:317 AaveV3Adapter.cumulativeIncome external | 42 | 29 | 16406
src/adapters/AaveV3Adapter.sol:325 AaveV3Adapter.positionKeys external | 16 | 3 | 18
src/adapters/AaveV3Adapter.sol:340 AaveV3Adapter.unwindExitParams external | 6 | 0 | 4
src/adapters/AaveV3Adapter.sol:354 AaveV3Adapter.spotQuote external | 6 | 1 | 2
src/adapters/AaveV3Adapter.sol:359 AaveV3Adapter.ledger external | 28 | 9 | 15906
src/adapters/AaveV3Adapter.sol:364 AaveV3Adapter.reserveAssets external | 3 | 0 | 10
src/adapters/AcrossBridgeAdapter.sol:69 AcrossBridgeAdapter.protocolId external | 1 | 0 | 1
src/adapters/AcrossBridgeAdapter.sol:74 AcrossBridgeAdapter.target external | 2 | 6 | 35
src/adapters/AcrossBridgeAdapter.sol:80 AcrossBridgeAdapter.fillDeadlineSeconds external | 1 | 0 | 1
src/adapters/AcrossBridgeAdapter.sol:95 AcrossBridgeAdapter.buildSend external | 19 | 1 | 2073
src/adapters/AdapterGuard.sol:36 AdapterGuard.setPaused external | 13 | 0 | 11
src/adapters/AdapterGuard.sol:43 AdapterGuard.deprecate external | 10 | 0 | 9
src/adapters/UniswapV4Adapter.sol:251 UniswapV4Adapter.isExactValue external | 2 | 0 | 1
src/adapters/UniswapV4Adapter.sol:257 UniswapV4Adapter.poolTokens external | 9 | 5 | 53
src/adapters/UniswapV4Adapter.sol:266 UniswapV4Adapter.positionValue external | 45 | 38 | 2608
src/adapters/UniswapV4Adapter.sol:293 UniswapV4Adapter.cumulativeIncome external | 42 | 29 | 14348
src/adapters/UniswapV4Adapter.sol:308 UniswapV4Adapter.positionKeys external | 16 | 3 | 500
src/adapters/UniswapV4Adapter.sol:316 UniswapV4Adapter.unwindExitParams external | 6 | 0 | 4
src/adapters/UniswapV4Adapter.sol:333 UniswapV4Adapter.spotQuote external | 6 | 1 | 5
src/adapters/UniswapV4Adapter.sol:350 UniswapV4Adapter.openPosition external | 41 | 8 | 3097
src/adapters/UniswapV4Adapter.sol:388 UniswapV4Adapter.increasePosition external | 17 | 2 | 676
src/adapters/UniswapV4Adapter.sol:428 UniswapV4Adapter.decreasePosition external | 29 | 5 | 1603
src/adapters/UniswapV4Adapter.sol:464 UniswapV4Adapter.closePosition external | 27 | 4 | 1525
src/adapters/UniswapV4Adapter.sol:495 UniswapV4Adapter.collectIncome external | 23 | 6 | 1853
src/adapters/UniswapV4Adapter.sol:516 UniswapV4Adapter.swapExactInput external | 16 | 2 | 13
src/adapters/UniswapV4Adapter.sol:548 UniswapV4Adapter.unlockCallback external | 1 | 0 | 9
src/core/CoreVault.sol:56 CoreVault.deposit external | 18 | 6 | 7250
src/core/CoreVault.sol:98 CoreVault.requestPayout external | 6 | 5 | 3366
src/core/CoreVault.sol:144 CoreVault.claimPayout external | 9 | 6 | 2173
src/core/CoreVaultBase.sol:185 CoreVaultBase.mandate external | 1 | 0 | 1
src/core/CoreVaultBase.sol:190 CoreVaultBase.idle external | 48 | 16 | 3612
src/core/CoreVaultBase.sol:195 CoreVaultBase.payoutReserve external | 25 | 7 | 3601
src/core/CoreVaultBase.sol:200 CoreVaultBase.freeIdle public | 10 | 3 | 7883
src/core/CoreVaultBase.sol:205 CoreVaultBase.operatingCash external | 23 | 5 | 1541
src/core/CoreVaultBase.sol:210 CoreVaultBase.operatingCashFloor external | 5 | 0 | 1
src/core/CoreVaultBase.sol:215 CoreVaultBase.operatingCashTopUp external | 5 | 0 | 1
src/core/CoreVaultBase.sol:220 CoreVaultBase.unmatchedArrivals external | 12 | 2 | 1543
src/core/CoreVaultBase.sol:225 CoreVaultBase.transit external | 62 | 3 | 2103
src/core/CoreVaultBase.sol:230 CoreVaultBase.payoutRequest external | 23 | 5 | 3311
src/core/CoreVaultBase.sol:235 CoreVaultBase.shareAssets public | 72 | 20 | 5249
src/core/CoreVaultBase.sol:240 CoreVaultBase.sharePrice external | 48 | 15 | 3668
src/core/CoreVaultBase.sol:245 CoreVaultBase.inFlightValue external | 24 | 5 | 526
src/core/CoreVaultBase.sol:250 CoreVaultBase.grossAssets external | 4 | 1 | 4
src/core/CoreVaultBase.sol:255 CoreVaultBase.spokeCapUsage public | 18 | 3 | 22
src/core/CoreVaultBase.sol:269 CoreVaultBase.setOperatingCashParameters external | 12 | 1 | 7
src/core/CoreVaultIncome.sol:28 CoreVaultIncome.receiveCollectedIncome external | 2 | 0 | 1970
src/core/CoreVaultIncome.sol:38 CoreVaultIncome.withdrawIncome external | 8 | 4 | 884
src/core/CoreVaultIncome.sol:64 CoreVaultIncome.decreaseManagerFee external | 5 | 0 | 4
src/core/CoreVaultIncome.sol:81 CoreVaultIncome.incomeTokens external | 3 | 0 | 1
src/core/CoreVaultIncome.sol:86 CoreVaultIncome.attributedIncome external | 19 | 13 | 1042
src/core/CoreVaultIncome.sol:92 CoreVaultIncome.collectedIncome external | 35 | 4 | 2057
src/core/CoreVaultIncome.sol:97 CoreVaultIncome.ownerlessIncome external | 1 | 0 | 1
src/core/CoreVaultIncome.sol:102 CoreVaultIncome.incomeState external | 11 | 0 | 5036
src/core/CoreVaultIncome.sol:107 CoreVaultIncome.performanceFeeBps external | 2 | 1 | 2
src/core/CoreVaultIncome.sol:112 CoreVaultIncome.managementFeeBps external | 2 | 1 | 2
src/core/CoreVaultLogic.sol:67 CoreVaultLogic.valuation public | 1 | 0 | 0
src/core/CoreVaultLogic.sol:89 CoreVaultLogic.recordValuation public | 0 | 0 | 12802
src/core/CoreVaultLogic.sol:106 CoreVaultLogic.shareAssets public | 72 | 20 | 5775
src/core/CoreVaultLogic.sol:120 CoreVaultLogic.grossAssets public | 4 | 1 | 4
src/core/CoreVaultLogic.sol:143 CoreVaultLogic.spokeCapUsage public | 18 | 3 | 574
src/core/CoreVaultLogic.sol:382 CoreVaultLogic.collectIncome public | 23 | 6 | 1968
src/core/CoreVaultLogic.sol:401 CoreVaultLogic.protocolSliceBps public | 11 | 1 | 1975
src/core/CoreVaultLogic.sol:417 CoreVaultLogic.applyReport public | 0 | 0 | 51
src/core/CoreVaultLogic.sol:489 CoreVaultLogic.receiveHubBound public | 0 | 0 | 19
src/core/CoreVaultLogic.sol:541 CoreVaultLogic.nonArrivalProvable public | 1 | 0 | 276
src/core/CoreVaultLogic.sol:576 CoreVaultLogic.sendToSpoke public | 15 | 4 | 557
src/core/CoreVaultLogic.sol:714 CoreVaultLogic.attestExpiry public | 24 | 0 | 278
src/core/CoreVaultLogic.sol:735 CoreVaultLogic.recognizeRefund public | 32 | 0 | 529
src/core/CoreVaultTransit.sol:26 CoreVaultTransit.allocateToHubSpokeVault external | 18 | 1 | 2251
src/core/CoreVaultTransit.sol:43 CoreVaultTransit.returnToIdle external | 2 | 0 | 21
src/core/CoreVaultTransit.sol:58 CoreVaultTransit.sendToSpoke external | 15 | 4 | 558
src/core/CoreVaultTransit.sol:76 CoreVaultTransit.attestExpiry external | 24 | 0 | 278
src/core/CoreVaultTransit.sol:84 CoreVaultTransit.recognizeRefund external | 32 | 0 | 529
src/core/CoreVaultTransit.sol:95 CoreVaultTransit.onReportAccepted external | 1 | 0 | 52
src/core/CoreVaultTransit.sol:110 CoreVaultTransit.handleV3AcrossMessage external | 5 | 3 | 22
src/core/CoreVaultTransit.sol:129 CoreVaultTransit.sweepExcess external | 24 | 4 | 9
src/core/ManagerFeeVault.sol:32 ManagerFeeVault.balanceOf external | 167 | 78 | 519
src/core/ManagerFeeVault.sol:38 ManagerFeeVault.withdraw external | 2 | 0 | 2
src/core/ManagerRegistry.sol:38 ManagerRegistry.protocolSliceBps public | 11 | 1 | 13525
src/core/ManagerRegistry.sol:44 ManagerRegistry.hasEntry external | 5 | 0 | 516
src/core/ManagerRegistry.sol:50 ManagerRegistry.setProtocolSliceBps external | 17 | 0 | 4617
src/core/ManagerRegistry.sol:61 ManagerRegistry.renounceOwnership public | 2 | 0 | 1
src/core/ManagerRegistry.sol:67 ManagerRegistry.clearProtocolSliceBps external | 5 | 0 | 1361
src/core/ShareToken.sol:47 ShareToken.mint external | 141 | 0 | 11028
src/core/ShareToken.sol:55 ShareToken.burn external | 18 | 0 | 4733
src/core/ShareToken.sol:61 ShareToken.transfer public | 7 | 5 | 1667
src/core/ShareToken.sol:66 ShareToken.transferFrom public | 1 | 0 | 1
src/core/ShareToken.sol:71 ShareToken.approve public | 18 | 13 | 1
src/core/ShareToken.sol:76 ShareToken.allowance public | 17 | 11 | 2
src/core/TransitEscrow.sol:26 TransitEscrow.initialize external | 9 | 0 | 855
src/core/TransitEscrow.sol:34 TransitEscrow.release external | 3 | 0 | 59
src/factory/Create3Deployer.sol:23 Create3Deployer.deploy external | 16 | 0 | 57
src/factory/Create3Deployer.sol:29 Create3Deployer.addressOf external | 44 | 0 | 2
src/factory/FundFactory.sol:138 FundFactory.createFund external | 23 | 4 | 35
src/factory/FundFactory.sol:184 FundFactory.createSpoke external | 23 | 3 | 23
src/factory/FundFactory.sol:217 FundFactory.nextCreationNumber external | 8 | 4 | 8
src/factory/FundFactory.sol:222 FundFactory.fundIdOf external | 21 | 2 | 2090
src/factory/FundFactory.sol:227 FundFactory.saltOf public | 3 | 0 | 3011
src/factory/FundFactory.sol:232 FundFactory.addressOf external | 44 | 0 | 2324
src/factory/FundFactory.sol:237 FundFactory.predictAddresses external | 3 | 2 | 3
src/factory/FundFactory.sol:250 FundFactory.wiring external | 1 | 0 | 1
src/report/ChainlinkPriceSource.sol:118 ChainlinkPriceSource.priceInUsdc public | 14 | 5 | 2067
src/report/ChainlinkPriceSource.sol:133 ChainlinkPriceSource.usdcValue external | 10 | 3 | 1543
src/report/ChainlinkPriceSource.sol:141 ChainlinkPriceSource.maxPriceAge external | 4 | 2 | 4
src/report/ChainlinkPriceSource.sol:148 ChainlinkPriceSource.aggregatorOf external | 1 | 0 | 1
src/report/ChainlinkPriceSource.sol:155 ChainlinkPriceSource.isFixed external | 2 | 0 | 2
src/report/ValueReportReceiver.sol:144 ValueReportReceiver.deliver external | 46 | 13 | 6237
src/report/ValueReportReceiver.sol:209 ValueReportReceiver.hasReport external | 11 | 1 | 674
src/report/ValueReportReceiver.sol:214 ValueReportReceiver.latestReport external | 5 | 4 | 4054
src/report/ValueReportReceiver.sol:226 ValueReportReceiver.lastWormholeSequence external | 9 | 1 | 1541
src/report/ValueReportReceiver.sol:231 ValueReportReceiver.lastReportSequence external | 2 | 0 | 2
src/report/ValueReportReceiver.sol:236 ValueReportReceiver.maxReportAge external | 6 | 1 | 3
src/report/ValueReportReceiver.sol:244 ValueReportReceiver.isReportFresh external | 10 | 4 | 10
src/report/ValueReportReceiver.sol:252 ValueReportReceiver.spokeCount external | 2 | 0 | 2
src/report/ValueReportReceiver.sol:257 ValueReportReceiver.spoke external | 2 | 0 | 1
src/report/ValueReportReceiver.sol:262 ValueReportReceiver.spokeIndexOf external | 1 | 0 | 1
src/spoke/SpokeCrossChainLib.sol:38 SpokeCrossChainLib.sendToHub external | 27 | 1 | 645
src/spoke/SpokeCrossChainLib.sol:70 SpokeCrossChainLib.recognizeRefund external | 32 | 0 | 57
src/spoke/SpokeCrossChainLib.sol:99 SpokeCrossChainLib.nextReport external | 0 | 0 | 593
src/spoke/SpokeCrossChainLib.sol:112 SpokeCrossChainLib.encodedReport external | 0 | 0 | 24
src/spoke/SpokeCrossChainLib.sol:121 SpokeCrossChainLib.cumulativeIncome public | 42 | 29 | 7133
src/spoke/SpokeVault.sol:249 SpokeVault.openPosition external | 41 | 8 | 174
src/spoke/SpokeVault.sol:274 SpokeVault.increasePosition external | 17 | 2 | 56
src/spoke/SpokeVault.sol:296 SpokeVault.decreasePosition external | 29 | 5 | 56
src/spoke/SpokeVault.sol:308 SpokeVault.closePosition external | 27 | 4 | 44
src/spoke/SpokeVault.sol:320 SpokeVault.collectIncome external | 23 | 6 | 46
src/spoke/SpokeVault.sol:333 SpokeVault.swapExactInput external | 16 | 2 | 108
src/spoke/SpokeVault.sol:350 SpokeVault.swapCollectedIncome external | 5 | 0 | 3
src/spoke/SpokeVault.sol:368 SpokeVault.setOperatingCashParameters external | 12 | 1 | 41
src/spoke/SpokeVault.sol:382 SpokeVault.sendToHub external | 27 | 1 | 645
src/spoke/SpokeVault.sol:395 SpokeVault.recognizeRefund external | 32 | 0 | 57
src/spoke/SpokeVault.sol:404 SpokeVault.report external | 9 | 7 | 593
src/spoke/SpokeVault.sol:421 SpokeVault.buildReport external | 24 | 3 | 24
src/spoke/SpokeVault.sol:441 SpokeVault.handleV3AcrossMessage external | 5 | 3 | 2230
src/spoke/SpokeVault.sol:478 SpokeVault.receiveFromCoreVault external | 2 | 0 | 22
src/spoke/SpokeVault.sol:487 SpokeVault.returnToCoreVault external | 4 | 0 | 2
src/spoke/SpokeVault.sol:496 SpokeVault.forwardIncomeToCoreVault external | 3 | 2 | 2
src/spoke/SpokeVault.sol:524 SpokeVault.unwindForPayout external | 2 | 0 | 20
src/spoke/SpokeVault.sol:556 SpokeVault.sweepExcess external | 24 | 4 | 564
src/spoke/SpokeVault.sol:570 SpokeVault.adapters external | 2 | 0 | 2
src/spoke/SpokeVault.sol:575 SpokeVault.bridgeAdapters external | 2 | 0 | 2
src/spoke/SpokeVault.sol:580 SpokeVault.bridgeTarget external | 1 | 0 | 1
src/spoke/SpokeVault.sol:586 SpokeVault.adapterCodehash external | 3 | 0 | 3
src/spoke/SpokeVault.sol:591 SpokeVault.poolTokens external | 9 | 5 | 1
src/spoke/SpokeVault.sol:597 SpokeVault.unallocatedBalance external | 57 | 10 | 3096
src/spoke/SpokeVault.sol:603 SpokeVault.ledgerTokens external | 2 | 0 | 2
src/spoke/SpokeVault.sol:608 SpokeVault.collectedIncome external | 35 | 4 | 22
src/spoke/SpokeVault.sol:615 SpokeVault.cumulativeIncome external | 42 | 29 | 5899
src/spoke/SpokeVault.sol:620 SpokeVault.positions external | 17 | 3 | 2881
src/spoke/SpokeVault.sol:625 SpokeVault.operatingCash external | 23 | 5 | 1578
src/spoke/SpokeVault.sol:630 SpokeVault.operatingCashFloor external | 5 | 0 | 1568
src/spoke/SpokeVault.sol:635 SpokeVault.operatingCashTopUp external | 5 | 0 | 1190
src/spoke/SpokeVault.sol:640 SpokeVault.cumulativeReceived external | 8 | 3 | 2
src/spoke/SpokeVault.sol:645 SpokeVault.cumulativeSentHome external | 5 | 1 | 513
src/spoke/SpokeVault.sol:650 SpokeVault.reportSequence external | 4 | 0 | 3
src/spoke/SpokeVault.sol:655 SpokeVault.hubBoundTransit external | 19 | 1 | 400
src/spoke/SpokeVault.sol:660 SpokeVault.hasArrived external | 5 | 0 | 5
src/spoke/SpokeVault.sol:666 SpokeVault.arrivals external | 8 | 1 | 5
src/spoke/SpokeVault.sol:671 SpokeVault.inFlightTransitIds external | 6 | 0 | 6
```

</details>

<details><summary>A.10 forge lint (run 9)</summary>

```text
$ forge lint (time)
forge lint > ../baseline/lint.log 2>&1  1.05s user 0.22s system 56% cpu 2.249 total
# derived tally: directory rule count
src require-revert-in-loop 68
src reentrancy-events 50
src calls-loop 31
src non-reentrant-not-first 28
src uninitialized-local 18
src unused-return 15
src block-timestamp 13
src unsafe-typecast 11
src reentrancy-no-eth 11
src boolean-cst 10
src missing-zero-check 3
src encode-packed-collision 2
src divide-before-multiply 1
test environment-read-across-mutation 30
# first finding, verbatim
warning[boolean-cst]: misuse of a boolean constant
    ╭▸ src/core/CoreVaultLogic.sol:225:95
    │
225 │             return (_positionsPrincipal(s, w, p, ISpokeVault(w.hubSpokeVault).buildReport()), true);
    │                                                                                               ━━━━
    │
    ╰ help: https://getfoundry.sh/forge/linting/boolean-cst

```

</details>

