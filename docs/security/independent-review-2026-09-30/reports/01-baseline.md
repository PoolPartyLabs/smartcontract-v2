# Pool Party v2 smart contracts: toolchain baseline

## At a glance

1. **Commit** `e5c778a97c70eb07df8acbf1f1037f465a6ffb63` (`main`); OpenZeppelin 5.7.0; `foundry.lock` pins 6 of 7 direct submodules (`lib/v4-periphery` is missing).
2. **Build OK** (`forge build --sizes`, forced recompile 150 s); 0 solc warnings in `src/` or `script/` (4 in `test/`); `SpokeVault` runtime is 23,644 B, 96.2% of the 24,576 B limit (932 B margin). `forge fmt --check` **FAILS** on 2 test files.
3. **Unit and invariant tests (default profile): 644 passed, 0 failed, 0 skipped** (also 644 / 0 / 0 under the `ci` profile CI uses).
4. **Fork tests: as briefed 2 passed, 27 failed**, every failure the same config error (empty `*_FORK_BLOCK` in `.env.example` breaks `vm.envUint`; 0 RPC problems, 0 assertion failures); **with recent pinned blocks 56 passed, 0 failed**.
5. **Slither: 8 High, 70 Medium** (176 results in all); each High and Medium was opened: all look like false positives, one (#69) carries a caveat.
6. **Aderyn: 6 High categories, 21 instances** (plus 15 Low categories, 114 instances); all High instances look like false positives.
7. **Solhint** (`solhint:recommended`, no config in the repo): 0 errors, 1040 warnings (717 of them NatSpec).
8. **Coverage** (needed `--ir-minimum` after "stack too deep"): `src/` **97.31% lines, 95.36% statements, 83.67% branches, 98.90% functions**; 1 file under 90% lines, 9 under 80% branches.
9. **Events:** of 67 state-changing external or public functions in `src/`, **NO EVENT FOUND on 4** (`TransitEscrow.initialize`, `TransitEscrow.release`, `UniswapV4Adapter.unlockCallback`, `SpokeCrossChainLib.nextReport`); 4 silent no-op paths. **CI:** one run exists for this commit and it failed at `Format`; no static analysis, no coverage gate, Foundry unpinned, fork blocks unset.
10. **Working tree clean:** `git status --short` is empty, no tracked file modified (only git-ignored `.env`, `cache/`, `out/`).

## About this report

Repository `github.com/PoolPartyLabs/smartcontract-v2`, working copy at commit `e5c778a`, run on 2026-09-30 (machine clock, WEST) with
forge 1.8.3, solc 0.8.28, Slither 0.11.6, Aderyn 0.6.8 and solhint 6.2.4. Every command below was run; raw outputs are in
`raw/` next to this file and each section names its files. Where a tool failed, the command and the error are quoted. "First-pass
note" means a judgement made after opening the code, not a verdict.


## 1. Commit, submodules, dependency versions

Commands (raw: `raw/submodules.txt`):

```
git -C REPO rev-parse HEAD
git -C REPO submodule status --recursive
grep '"version"' lib/openzeppelin-contracts/package.json     # plus git describe --tags --exact-match per submodule
```

- `HEAD` = `e5c778a97c70eb07df8acbf1f1037f465a6ffb63` (`merge: feat/pp-sc-feat-integration into main ...`).
- Every submodule line in `git submodule status --recursive` starts with a blank (no `-`, `+` or `U`): each checked-out
  submodule is at the commit recorded in the superproject.
- **OpenZeppelin Contracts: 5.7.0** (`lib/openzeppelin-contracts/package.json` says `"version": "5.7.0"`; exact tag
  `v5.7.0`, commit `cab19933c33c2ad1d4c7a84864a3601dddfd16f3`). `git submodule status` prints it as
  `v4.8.0-1217-gcab19933` only because `git describe` picks the nearest reachable tag; `git describe --tags
  --exact-match` returns `v5.7.0`.
- `remappings.txt` maps `@openzeppelin/contracts/` to `lib/openzeppelin-contracts/contracts/` (5.7.0). The nested copies of
  OpenZeppelin inside `lib/v4-core` (`v5.0.0-12-gdbb6104c`) and `lib/v4-periphery/lib/permit2` (`v4.4.1-260-gd3ff81b3`)
  are not mapped.

Direct submodules (`.gitmodules`, 7 entries):

| Path | Commit | Tag or ref (from git) | Pinned in `foundry.lock` |
|---|---|---|---|
| `lib/forge-std` | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | exact tag `v1.16.2` | yes, tag `v1.16.2`, same rev |
| `lib/openzeppelin-contracts` | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | exact tag `v5.7.0` | yes, tag `v5.7.0`, same rev |
| `lib/v3-core` | `6562c52e8f75f0c10f9deaf44861847585fc8129` | no exact tag; `v1.0.0-9-g6562c52` (`.gitmodules` branch `0.8`; package version `1.0.1-solc-0.8`) | yes, branch `0.8`, same rev |
| `lib/v3-periphery` | `b325bb0905d922ae61fcc7df85ee802e8df5e96c` | no exact tag; `v1.3.0-13-gb325bb0` (branch `0.8`; package version `1.4.2-solc-0.8`) | yes, branch `0.8`, same rev |
| `lib/v4-core` | `e50237c43811bd9b526eff40f26772152a42daba` | exact tag `v4.0.0` | yes, tag `v4.0.0`, same rev |
| `lib/v4-periphery` | `9969eec44cfdf07e24b41de47f40276a58401976` | no tag; `heads/main` (package `@uniswap/v4-periphery` 1.0.4) | **no, absent from `foundry.lock`** |
| `lib/wormhole-solidity-sdk` | `a57e7d8f001f29a18463a7b7aae082e91b11aae1` | exact tag `v1.0.0` | yes, tag `v1.0.0`, same rev |

- `foundry.lock` is tracked in git and lists 6 of the 7 direct submodules; `lib/v4-periphery` is the one missing (its
  commit is still fixed by the superproject's gitlink). `lib/v3-core` and `lib/v3-periphery` are pinned as a branch plus
  rev, not a tag, and neither rev is a release tag (9 and 13 commits after the nearest tag).
- Nested submodules exist several levels deep (for example `lib/v4-periphery/lib/permit2/...`, `lib/v4-core/lib/solmate`,
  `lib/v4-core/lib/openzeppelin-contracts` v5.0.0, `lib/wormhole-solidity-sdk/lib/forge-std` v1.5.6); they are not
  listed in `foundry.lock`. The full list, with their describe strings, is in `raw/submodules.txt`.
- Toolchain used for this baseline: forge 1.8.3 (`cae51ad`, built 2026-09-15), solc 0.8.28 (`svm`), slither 0.11.6,
  aderyn 0.6.8, solhint 6.2.4, docker 29.8.0 (not used).
- Compiler settings (`foundry.toml`, default profile): `solc_version = "0.8.28"`, `evm_version = "cancun"`,
  `optimizer = true`, `optimizer_runs = 800`, `via_ir = false`.

## 2. Build and contract sizes

Commands (raw: `raw/build-sizes-cached.txt`, `raw/build-sizes.txt`, `raw/sizes-src-table.txt`, `raw/sizes-src-artifacts.txt`,
`raw/build-lint-summary.txt`):

```
forge build --sizes            # first run: "No files changed, compilation skipped"; prints the sizes table (cached build)
forge build --force --sizes    # forced full recompile, run once to surface solc warnings (cached builds print none)
```

Result: **build succeeds** (exit 0). The forced recompile compiled 268 files with solc 0.8.28 in 150.4 s (wall 164.6 s on a
loaded machine) and printed "Compiler run successful with warnings". Both runs print the same sizes.

### Sizes of every contract under `src/` (limits: 24,576 B runtime, 49,152 B initcode)

Runtime and initcode sizes are those printed by `forge build --sizes`; percentages are runtime size over the limit.

| Contract | File | Runtime (B) | Initcode (B) | Runtime margin (B) | Initcode margin (B) | Runtime % of limit |
|---|---|---:|---:|---:|---:|---:|
| SpokeVault | src/spoke/SpokeVault.sol | 23,644 | 32,630 | **932** | 16,522 | **96.2%** |
| CoreVault | src/core/CoreVault.sol | 20,034 | 34,084 | 4,542 | 15,068 | 81.5% |
| CoreVaultLogic (library) | src/core/CoreVaultLogic.sol | 19,215 | 19,267 | 5,361 | 29,885 | 78.2% |
| UniswapV4Adapter | src/adapters/UniswapV4Adapter.sol | 17,854 | 19,482 | 6,722 | 29,670 | 72.6% |
| FundFactory | src/factory/FundFactory.sol | 16,084 | 19,969 | 8,492 | 29,183 | 65.4% |
| AaveV3Adapter | src/adapters/AaveV3Adapter.sol | 10,133 | 11,795 | 14,443 | 37,357 | 41.2% |
| ValueReportReceiver | src/report/ValueReportReceiver.sol | 7,846 | 9,267 | 16,730 | 39,885 | 31.9% |
| AcrossBridgeAdapter | src/adapters/AcrossBridgeAdapter.sol | 2,347 | 2,906 | 22,229 | 46,246 | 9.5% |
| ShareToken | src/core/ShareToken.sol | 1,822 | 2,603 | 22,754 | 46,549 | 7.4% |
| ManagerRegistry | src/core/ManagerRegistry.sol | 1,530 | 1,803 | 23,046 | 47,349 | 6.2% |
| ChainlinkPriceSource | src/report/ChainlinkPriceSource.sol | 1,420 | 3,683 | 23,156 | 45,469 | 5.8% |
| Create3Deployer | src/factory/Create3Deployer.sol | 1,342 | 1,370 | 23,234 | 47,782 | 5.5% |
| ManagerFeeVault | src/core/ManagerFeeVault.sol | 1,077 | 1,355 | 23,499 | 47,797 | 4.4% |
| TransitEscrow | src/core/TransitEscrow.sol | 894 | 939 | 23,682 | 48,213 | 3.6% |
| SpokeCrossChainLib (library) * | src/spoke/SpokeCrossChainLib.sol | 10,545 | 10,597 | 14,031 | 38,555 | 42.9% |

\* `forge build --sizes` does not list `SpokeCrossChainLib`; its sizes are read from the `out/` artifact
(`raw/sizes-src-artifacts.txt`), which reproduces the tool's numbers for the other 14 rows exactly.

Also under `src/` with a non-zero artifact but not listed by the tool: `CodeStore`, `Create3`, `IncomeAccumulator`,
`ReportCodec`, `ShareMath`, `TransitMessage`, `MandateLib` (in `Mandate.sol`) and `SpokeVaultTypes`, each an 85 B runtime
and 135 B initcode stub of an internal-only library. Interfaces and abstract contracts (`AdapterGuard`, `CoreVaultBase`,
`CoreVaultIncome`, `CoreVaultTransit`, all of `src/interfaces/**`) have empty bytecode.

Facts that bear on the limits:

- **Linked libraries.** The creation code of `CoreVault` contains 13 unresolved link placeholders for `CoreVaultLogic`
  (`bytecode.linkReferences` in `out/CoreVault.sol/CoreVault.json`), and the creation code of `SpokeVault` contains 5 for
  `SpokeCrossChainLib`. Both libraries have external or public functions, so the compiler calls them through
  DELEGATECALL although `delegatecall` appears nowhere in `src/` source text (see step 9). The sizes above are of the
  unlinked code; linking substitutes 20-byte addresses in place and does not change the size.
- **Initcode margin is shared with constructor arguments.** `FundFactory` deploys `abi.encodePacked(creationCode,
  abi.encode(m, c))` for the Core Vault (`FundFactory.sol:478`) and the stored creation code plus `args` for every other
  role (`FundFactory.sol:509`), so the ABI-encoded Mandate has to fit in the initcode margin: 15,068 B for `CoreVault`,
  16,522 B for `SpokeVault`.
- `SpokeVault` has 932 B of runtime headroom. `SpokeCrossChainLib`'s own header says it was split out only to keep the vault
  under EIP-170 (`SpokeCrossChainLib.sol:23`).

### Compiler warnings (solc) that point into `src/` or `script/`

**None.** The forced recompile printed exactly four solc warnings, all in `test/`:

| Warning | Where |
|---|---|
| 2519 shadowing of state variable `last0` | `test/fork/v4/UniswapV4AdapterFork.t.sol:259` (declared at line 52) |
| 2519 shadowing of state variable `last1` | `test/fork/v4/UniswapV4AdapterFork.t.sol:259` (declared at line 53) |
| 3628 payable `fallback` without `receive` | `test/mocks/spoke/MockAcrossSpokePool.sol:11` (fallback at line 40) |
| 2018 state mutability can be restricted to `view` | `test/unit/spoke/SpokeVaultSpoke.t.sol:981` (`_sawSentToHub`) |

### `forge lint` output printed by `forge build`

Forge 1.8.3 runs its linter during `forge build`. It printed 291 items (all severity `warning`): **261 in `src/`, 30 in
`test/`, 0 in `script/`** (an extra `forge lint script/` prints nothing, exit 0, `raw/lint-script-check.txt`). Full list with
`file:line:col` in `raw/build-lint-summary.txt`. The 261 in `src/` by rule:

| Rule | Count | Rule | Count |
|---|---:|---|---:|
| require-revert-in-loop | 68 | reentrancy-no-eth | 11 |
| reentrancy-events | 50 | unsafe-typecast | 11 |
| calls-loop | 31 | boolean-cst | 10 |
| non-reentrant-not-first | 28 | missing-zero-check | 3 |
| uninitialized-local | 18 | encode-packed-collision | 2 |
| unused-return | 15 | divide-before-multiply | 1 |
| block-timestamp | 13 | | |

The 30 in `test/` are all `environment-read-across-mutation` (block.timestamp reused across `vm.warp` 25, across
`vm.revertToState` 2, block.number across `vm.roll` 2, block.timestamp across `vm.selectFork` 1).

## 3. Formatting

Command (raw: `raw/fmt.txt`): `forge fmt --check`

Result: **FAIL** (exit 1, 0.7 s). It reports diffs in exactly two files, both under `test/`, none in `src/` or `script/`:

- `test/mocks/across/AcrossFillSimulator.sol` (a chained `store.target(...).sig(...).with_key(...)` call that the
  formatter wants split over three lines);
- `test/fork/across/AcrossFill.fork.t.sol` (the struct literal passed to `fillRelay`, indentation of the fields).

The CI run for this very commit (run 36713951710 on `main`, `headSha` `e5c778a97c70`) fails at its `Format` step with
the same two-file diff (`raw/ci-run-36713951710-failed.log`); the `Build`, `Unit tests` and `Fork tests` steps were skipped
in that run (see step 11). The workflow installs `foundry-rs/foundry-toolchain@v1` with `version: stable`, so which forge
formats it is not pinned; the local forge is 1.8.3.

## 4. Unit and invariant suite (default profile)

Command (raw: `raw/unit-tests.txt`): `forge test --no-match-path "test/fork/**"` (no `FOUNDRY_PROFILE`, so the default profile).

| | Result |
|---|---|
| Suites | 53 |
| **Passed / failed / skipped** | **644 / 0 / 0** (644 total) |
| Wall time | 13.83 s reported by forge for the suites (70.48 s CPU); 18.18 s for the whole command (`No files changed, compilation skipped`) |
| Failing tests | none |

Machine state during the run: load average 72 at start, swap 10.1 GB used of 11.3 GB (other processes on the machine, not this run).

How the 644 is made up (from the run log, `raw/unit-tests.txt`): 586 plain tests, 54 fuzz tests (every one ran 512 runs),
and 4 invariant test contracts (forge counts each invariant contract as one test; together they hold 14 invariant
functions, each run 256 times at depth 32, `calls: 8192, reverts: 0` per contract). Two test contracts re-run the tests of
another contract by inheritance, which is why the run has more tests than the static inventory below: in
`test/unit/aave/AaveV3Adapter.t.sol` both `AaveV3AdapterTest` and `AaveV3AdapterHalfUpRoundingTest` run 25 tests, and in
`test/unit/aave/AaveV3AdapterLifecycle.t.sol` both `AaveV3AdapterLifecycleTest` and `AaveV3AdapterLifecycleHalfUpTest` run 2.

Invariant handlers as printed by forge (selector call counts, all with 0 reverts and 0 discards):

| Invariant contract | Invariant functions | Handler selectors exercised |
|---|---|---|
| `CoreVaultInvariantTest` | `invariant_DEC072_payoutReserveWithinIdle`, `invariant_DEC080_balanceCoversLedger`, `invariant_DEC080_directTransferNeverMovesSharePrice`, `invariant_DEC091_supplyIsWholeShares`, `invariant_DEC104_shareAssetsEqualBuckets`, `invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated`, `invariant_Q60_indexNeverDecreases` | allocate, claim, deposit, donate, forwardIncome, movePrice, requestPayout, warp, withdrawIncome |
| `SpokeVaultInvariantTest` | `invariant_DEC080_ledgerNeverExceedsBalance`, `invariant_DEC093_reportSequenceStrictlyIncreases`, `invariant_Q60_cumulativeIncomeNeverDecreases` | arrive, close, collect, decrease, donate, earnIncome, increase, open, refund, report, sendHome, swap, sweep, warp |
| `IncomeAccumulatorInvariantTest` | `invariant_Q60_indexNeverDecreases`, `invariant_Q60_owedPlusTakenNeverExceedsDistributed` | burn, mint, recognize, take |
| `ShareTokenInvariantTest` | `invariant_DEC004_allowanceAlwaysZero`, `invariant_DEC091_totalSupplyIsWholeShares` | burnFractional, burnWhole, mintFractional, mintWhole, transfer |

### Foundry settings (`foundry.toml`, effective values from `forge config --json`, raw: `raw/foundry-config-effective.txt`)

| Setting | default profile | `ci` profile |
|---|---|---|
| `[fuzz] runs` | 512 | 2000 |
| `[fuzz] fail_on_revert` | true | true (inherited) |
| `[invariant] runs` | 256 | 512 |
| `[invariant] depth` | 32 | 48 |
| `[invariant] fail_on_revert` | true | true (inherited) |
| `fuzz.seed` | unset (random per run) | unset |
| `ffi` | false | false |
| `fs_permissions` | read `./` | read `./` |

`foundry.toml` writes the `ci` profile as `fuzz = { runs = 2000 }` and `invariant = { runs = 512, depth = 48 }`; the
effective config shows `fail_on_revert` and the other fuzz keys are inherited from the default profile.

### Extra run, not in the brief: the `ci` profile that the workflow uses (raw: `raw/unit-tests-ci-profile.txt`)

`FOUNDRY_PROFILE=ci forge test --no-match-path "test/fork/**"` (this run included a full recompile of 224 files, 58.1 s,
because Slither had cleaned `out/` beforehand): **644 passed, 0 failed, 0 skipped**, 53 suites in 20.71 s (117 s CPU),
85.9 s wall. The 54 fuzz tests ran 2000 runs each; the four invariant contracts ran 512 runs, `calls: 24576, reverts: 0`.

### Inventory of test functions

Definitions (script `raw/test-inventory.py`, output `raw/test-inventory.txt`): a *plain test* is a `public` or `external`
function whose name starts with `test` and has no parameters; a *fuzz test* starts with `test` and has parameters; an
*invariant* starts with `invariant`. Comments are blanked before parsing. Static totals: **679 = 612 plain + 53 fuzz + 14
invariant functions**, of which 627 are under `test/unit` (560 + 53 + 14) and 52 under `test/fork` (52 plain, no fuzz, no
invariant). Files under `test/mocks`, plus `EndToEndBase.sol`, `SpokeVaultForkBase.sol`, `CoreVaultFixture.sol` and
`SpokeVaultTestBase.sol`, hold no tests.




### Tests whose name contains `OPEN`, `FLAGGED`, `KNOWN` or `TODO` (case-sensitive)

Two tests, both pinning the same open rule (DEC-014, CS-OQ-1: income generated before a holder enters is shared when it
is collected after entry):

- `test/unit/core/CoreVaultAdversarial.t.sol:131` `test_DEC014_OPEN_incomeGeneratedBeforeEntryIsSharedWhenCollectedAfterIt`
- `test/fork/e2e/EndToEndAdversarial.t.sol:152` `test_DEC014_OPEN_forkIncomeGeneratedBeforeBrunoIsSharedWhenCollectedAfterHim`

No test name contains `FLAGGED`, `KNOWN` or `TODO`. Other names that match case-insensitively (`raw/test-inventory.txt`, "extra"
section) are ordinary words (`unknown...`, `open...` as a verb, `lastKnown...`, `..FlaggedAndCounterKept` for the
income-source flag), not markers of a known issue.

Pins that are documented in comments rather than in names (extra, not requested; 19 lines in 13 files, full list in
`raw/test-marker-lines.txt`; most say a rule is OPEN, two only cite `docs/OPEN-QUESTIONS.md`):

- `test/unit/ShareMath.t.sol:287,298` (QA23: the next depositor captures the rounding residual; "everything I paid" does
  not always burn everything; "the rule is OPEN");
- `test/unit/factory/FundFactoryVerifyRound2.t.sol:162` (FF-OQ-1 residual: the fund id binds the Manager but not the Mandate's
  rules, "Documents the limit stated in docs/OPEN-QUESTIONS.md");
- `test/unit/v4/UniswapV4Adapter.t.sol:116` and `test/fork/v4/UniswapV4AdapterFork.t.sol:106` (DEC-079 OPEN, OQ-12, hooked
  pools rejected);
- `test/unit/v4/UniswapV4Adapter.t.sol:458,480` and `test/unit/spoke/SpokeVaultHub.t.sol:221` (QA3 OPEN, unwind price guard);
- `test/unit/core/CoreVaultFinalVerify.t.sol:19` (FV-OQ-1 reading), `test/unit/IncomeAccumulator.t.sol:157` (LC-100 OPEN),
  `test/fork/e2e/EndToEndAdversarial.t.sol:143,148` (CS-OQ-1 OPEN), `test/fork/e2e/EndToEndBase.sol:55` (QA19 OPEN),
  `test/unit/receiver/ValueReportReceiver.t.sol:19`, `test/fork/receiver/ValueReportReceiverFork.t.sol:26` and
  `test/fork/receiver/ChainlinkPriceSourceFork.t.sol:24` (Q66 / Q57 OPEN values).

### Per-file inventory (61 files with tests)


| Test file | Plain | Fuzz | Invariant | Total |
|---|---:|---:|---:|---:|
| test/fork/Toolchain.t.sol | 2 | 0 | 0 | 2 |
| test/fork/aave/AaveV3Adapter.fork.t.sol | 7 | 0 | 0 | 7 |
| test/fork/aave/AaveV3AdapterAdversarial.fork.t.sol | 3 | 0 | 0 | 3 |
| test/fork/across/AcrossBridgeAdapter.fork.t.sol | 9 | 0 | 0 | 9 |
| test/fork/across/AcrossFill.fork.t.sol | 4 | 0 | 0 | 4 |
| test/fork/core/CoreVaultAcross.t.sol | 2 | 0 | 0 | 2 |
| test/fork/e2e/EndToEnd.t.sol | 1 | 0 | 0 | 1 |
| test/fork/e2e/EndToEndAdversarial.t.sol | 3 | 0 | 0 | 3 |
| test/fork/factory/FundFactoryFork.t.sol | 3 | 0 | 0 | 3 |
| test/fork/receiver/ChainlinkPriceSourceFork.t.sol | 2 | 0 | 0 | 2 |
| test/fork/receiver/ValueReportReceiverFork.t.sol | 8 | 0 | 0 | 8 |
| test/fork/spoke/SpokeVaultArbitrumFork.t.sol | 2 | 0 | 0 | 2 |
| test/fork/spoke/SpokeVaultRobinhoodFork.t.sol | 2 | 0 | 0 | 2 |
| test/fork/v4/UniswapV4AdapterFork.t.sol | 4 | 0 | 0 | 4 |
| test/unit/AdapterGuard.t.sol | 4 | 0 | 0 | 4 |
| test/unit/IncomeAccumulator.t.sol | 21 | 8 | 2 | 31 |
| test/unit/Mandate.t.sol | 37 | 0 | 0 | 37 |
| test/unit/ReportCodec.t.sol | 5 | 1 | 0 | 6 |
| test/unit/ShareMath.t.sol | 18 | 10 | 0 | 28 |
| test/unit/ShareToken.t.sol | 12 | 1 | 2 | 15 |
| test/unit/TransitEscrow.t.sol | 5 | 0 | 0 | 5 |
| test/unit/TransitMessage.t.sol | 2 | 1 | 0 | 3 |
| test/unit/aave/AaveV3Adapter.t.sol | 25 | 0 | 0 | 25 |
| test/unit/aave/AaveV3AdapterAdversarial.t.sol | 12 | 1 | 0 | 13 |
| test/unit/aave/AaveV3AdapterFinalVerifyRound1.t.sol | 3 | 0 | 0 | 3 |
| test/unit/aave/AaveV3AdapterLifecycle.t.sol | 1 | 1 | 0 | 2 |
| test/unit/across/AcrossBridgeAdapter.adversarial.t.sol | 6 | 1 | 0 | 7 |
| test/unit/across/AcrossBridgeAdapter.t.sol | 17 | 3 | 0 | 20 |
| test/unit/across/AcrossSendFlow.t.sol | 5 | 0 | 0 | 5 |
| test/unit/core/CoreVaultAdversarial.t.sol | 9 | 2 | 0 | 11 |
| test/unit/core/CoreVaultAdversarialRound2.t.sol | 6 | 2 | 0 | 8 |
| test/unit/core/CoreVaultConsolidateVerify.t.sol | 6 | 0 | 0 | 6 |
| test/unit/core/CoreVaultConsolidateVerifyRound2.t.sol | 6 | 0 | 0 | 6 |
| test/unit/core/CoreVaultConsolidateVerifyRound3.t.sol | 5 | 0 | 0 | 5 |
| test/unit/core/CoreVaultDeposit.t.sol | 14 | 1 | 0 | 15 |
| test/unit/core/CoreVaultFinalVerify.t.sol | 1 | 0 | 0 | 1 |
| test/unit/core/CoreVaultFinalVerifyRound1.t.sol | 2 | 0 | 0 | 2 |
| test/unit/core/CoreVaultIncome.t.sol | 14 | 1 | 0 | 15 |
| test/unit/core/CoreVaultInvariant.t.sol | 0 | 0 | 7 | 7 |
| test/unit/core/CoreVaultPayout.t.sol | 26 | 1 | 0 | 27 |
| test/unit/core/CoreVaultSetup.t.sol | 20 | 0 | 0 | 20 |
| test/unit/core/CoreVaultTransit.t.sol | 37 | 0 | 0 | 37 |
| test/unit/factory/Create3.t.sol | 15 | 2 | 0 | 17 |
| test/unit/factory/FundFactory.t.sol | 33 | 1 | 0 | 34 |
| test/unit/factory/FundFactoryVerify.t.sol | 3 | 0 | 0 | 3 |
| test/unit/factory/FundFactoryVerifyRound2.t.sol | 4 | 0 | 0 | 4 |
| test/unit/receiver/ChainlinkPriceSource.t.sol | 9 | 1 | 0 | 10 |
| test/unit/receiver/ChainlinkPriceSourceAdversarial.t.sol | 5 | 2 | 0 | 7 |
| test/unit/receiver/ManagerRegistry.t.sol | 9 | 1 | 0 | 10 |
| test/unit/receiver/ManagerRegistryAdversarial.t.sol | 1 | 2 | 0 | 3 |
| test/unit/receiver/ValueReportReceiver.t.sol | 30 | 2 | 0 | 32 |
| test/unit/receiver/ValueReportReceiverAdversarial.t.sol | 6 | 3 | 0 | 9 |
| test/unit/spoke/SpokeVaultAdversarial.t.sol | 7 | 1 | 0 | 8 |
| test/unit/spoke/SpokeVaultConsolidateVerifyRound3.t.sol | 2 | 0 | 0 | 2 |
| test/unit/spoke/SpokeVaultFinalVerify.t.sol | 1 | 0 | 0 | 1 |
| test/unit/spoke/SpokeVaultFinalVerifyRound1.t.sol | 2 | 0 | 0 | 2 |
| test/unit/spoke/SpokeVaultHub.t.sol | 23 | 0 | 0 | 23 |
| test/unit/spoke/SpokeVaultInvariant.t.sol | 0 | 0 | 3 | 3 |
| test/unit/spoke/SpokeVaultSpoke.t.sol | 56 | 0 | 0 | 56 |
| test/unit/v4/UniswapV4Adapter.t.sol | 33 | 1 | 0 | 34 |
| test/unit/v4/UniswapV4AdapterAdversarial.t.sol | 2 | 3 | 0 | 5 |
| **Total (61 files)** | **612** | **53** | **14** | **679** |

## 5. Fork suite

### 5a. Run as specified in the brief (raw: `raw/fork-tests.txt`)

Setup: `.env` did not exist; `cp .env.example .env` (untracked, git-ignored; its `ARBITRUM_FORK_BLOCK=` and
`ROBINHOOD_FORK_BLOCK=` are empty). Command:

```
ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com \
  forge test --match-path "test/fork/**"
```

Both public RPCs answered (`eth_blockNumber` probe before the run; Arbitrum chain id 0xa4b1, Robinhood 0x1237).

| | Result |
|---|---|
| Suites | 15 |
| **Passed / failed** | **2 / 27** ("Encountered a total of 27 failing tests, 2 tests succeeded") |
| Wall time | 14.8 s |
| Failures caused by RPC or rate limit | **0** |
| Failures that are real assertion failures | **0** |

All 27 failures have the same cause, which is neither of the two kinds asked about but a configuration error. Verbatim,
for the Arbitrum variable (20 of the 27) and the Robinhood variable (7 of the 27):

```
[FAIL: vm.envUint: failed parsing $ARBITRUM_FORK_BLOCK as type `uint256`: missing hex prefix ("0x") for hex string]
[FAIL: vm.envUint: failed parsing $ROBINHOOD_FORK_BLOCK as type `uint256`: missing hex prefix ("0x") for hex string]
```

- 10 of the 27 are `setUp()` failures, which hide every test of their suite: `CoreVaultAcrossForkTest` (2 tests),
  `AaveV3AdapterAdversarialForkTest` (3), `AaveV3AdapterForkTest` (7), `ValueReportReceiverForkTest` (8),
  `ChainlinkPriceSourceForkTest` (2), `SpokeVaultArbitrumForkTest` (2), `SpokeVaultRobinhoodForkTest` (2),
  `UniswapV4AdapterArbitrumForkTest` (4), `UniswapV4AdapterRobinhoodForkTest` (4), `FundFactoryForkTest` (3): 37 test
  functions never ran. The other 17 are test functions that fail on their first `vm.envUint` (`EndToEndForkTest` 1,
  `AcrossFillForkTest` 4, `EndToEndAdversarialForkTest` 3, `AcrossBridgeAdapterForkTest` 9).
- The 2 that pass are `ToolchainForkTest` (`test/fork/Toolchain.t.sol`), the only fork file that calls
  `vm.createSelectFork(url)` without a block.
- Cause: every other fork test calls `vm.envUint("ARBITRUM_FORK_BLOCK")` and/or `vm.envUint("ROBINHOOD_FORK_BLOCK")`
  (for example `test/fork/aave/AaveV3Adapter.fork.t.sol:33`, `test/fork/e2e/EndToEndBase.sol:127-128`), which does not
  accept an empty value. `.env.example` lines 7-9 say "Pin fork blocks for deterministic tests (leave empty to fork latest)"
  and leave both empty, so the documented default setup cannot run the suite. `README.md:72-73` says to set both
  variables "to pin blocks for deterministic runs".
- `.github/workflows/test.yml` does not set either variable (its `env:` has only `FOUNDRY_PROFILE`, `ARBITRUM_RPC_URL`,
  `ROBINHOOD_RPC_URL`), so the same tests would read an unset variable in CI.
- `docs/REVIEW-LOG-2026-09-29.md` (item `BLOCKER-fork-pins`, section across-bridge-adapter) records a related problem: the
  blocks once pinned in the authors' `.env` (`ARBITRUM_FORK_BLOCK=510044719`, `ROBINHOOD_FORK_BLOCK=75699968`) are "no
  longer served by the public RPCs, which are non-archive"; the authors validated with 510065249 and 75753211.

### 5b. Second run with recent pinned blocks (deviation from the brief, to exercise the suite; raw: `raw/fork-tests-pinned-recent.txt`)

Reason: run 5a executed 2 of 56 tests. Before choosing blocks I probed both public RPCs with `eth_getBalance` and
`eth_getStorageAt` at `head`, `head-2`, ..., `head-5000`: every read was served on both chains (5,000 blocks is the deepest
tried). Command, with the blocks taken 100 below the head at the moment of the run:

```
ARBITRUM_FORK_BLOCK=510362584 ROBINHOOD_FORK_BLOCK=76558910 ARBITRUM_RPC_URL=... ROBINHOOD_RPC_URL=... \
  forge test --match-path "test/fork/**"
```

| | Result |
|---|---|
| Suites | 15 |
| **Passed / failed / skipped** | **56 / 0 / 0** (56 total) |
| Wall time | 36.07 s for the suites (256 s CPU), 38.8 s for the command |

56 is the 52 static test functions plus 4 (`UniswapV4AdapterArbitrumForkTest` and `UniswapV4AdapterRobinhoodForkTest` both
inherit the same 4 tests). No RPC error or rate-limit response appeared in the output. Whether the suite still passes at the blocks
the authors validated could not be tested: those blocks are no longer served (per their own log).


## 6. Slither

Command (raw: `raw/slither.txt` for stdout and stderr, `raw/slither.json`, `raw/slither-high-medium-list.txt`):

```
slither . --filter-paths "lib/|test/|script/" --json raw/slither.json
```

Slither 0.11.6. The first invocation worked; no fix was needed. Facts about the run:

- It analysed 114 contracts with 102 detectors, found 176 results, and took 27 s. Exit code 255; the log shows no tool error and
  `slither.json` has `"success": true, "error": null`, so the non-zero code is the "findings present" code, not a failure.
- The compile step is Slither's own: it ran `forge clean`, `forge config --json` and `forge build --build-info --deny never
  --skip ./test/** ./script/** --force` inside the working copy. That wiped and rebuilt `out/` and `cache/` (both
  git-ignored); later steps recompiled as needed (this is why the `ci` profile run in step 4 recompiled 224 files).

### Results by impact and detector

| Impact | Detector | Count | Confidence |
|---|---|---:|---|
| High | reentrancy-balance | 7 | Medium |
| High | encode-packed-collision | 1 | High |
| Medium | unused-return | 24 | Medium |
| Medium | reentrancy-no-eth | 20 | Medium |
| Medium | uninitialized-local | 15 | Medium |
| Medium | incorrect-equality | 10 | High |
| Medium | divide-before-multiply | 1 | Medium |
| Low | calls-loop | 58 | Medium |
| Low | timestamp | 14 | Medium |
| Low | reentrancy-events | 3 | Medium |
| Low | reentrancy-benign | 1 | Medium |
| Low | shadowing-local | 1 | High |
| Informational | assembly | 11 | High |
| Informational | naming-convention | 4 | High |
| Informational | low-level-calls | 3 | High |
| Informational | dead-code | 1 | Medium |
| Optimization | cache-array-length | 2 | High |

Totals: **High 8, Medium 70, Low 77, Informational 19, Optimization 2 = 176**.

### Every High and Medium result, with a first-pass note

The numbering is that of `raw/slither-high-medium-list.txt`. "Looks like a false positive" and "looks real" are first-pass
judgements after opening the code, not verdicts. Lines are the flagged statements (`->` separates the external call from the
later state write). Notes that repeat a rule refer back to the first row of that rule.

**High**

| # | Detector | Contract.function | file:line | First-pass note |
|---|---|---|---|---|
| 1 | encode-packed-collision | FundFactory._deployCoreVault | `src/factory/FundFactory.sol:478` | Looks like a false positive: the packed bytes are creation code followed by the ABI-encoded constructor arguments, passed to `Create3.deploy` as init code (`Create3.sol:40-56`) and never hashed; the deployed address depends only on the salt (`Create3.sol:59-71`). |
| 2 | reentrancy-balance | CoreVault.claimPayout | `src/core/CoreVault.sol:151` read, `:160` call, `:172` use | Looks like a false positive: the "balance" is the caller's Share balance; shares cannot be transferred (`ShareToken.sol:61-73`) and mint and burn come only from the vault's own `nonReentrant` entries, so it cannot change during the hub Spoke Vault call in `_unwindForPayout` (`:204-214`). |
| 3 | reentrancy-balance | CoreVaultLogic.sendToSpoke | `src/core/CoreVaultLogic.sol:624`, `:626`, `:633` | Looks like a false positive: this is the intended exact-debit check (balance before and after the plain CALL to the pinned bridge target, custody rule 3); the entry is `onlyManager nonReentrant` (`CoreVaultTransit.sol:58-62`) and the target must equal the pinned one (`:595`). |
| 4 | reentrancy-balance | CoreVaultLogic.recognizeRefund | `src/core/CoreVaultLogic.sol:743`, `:753`, `:755` | Looks like a false positive: the read is the sufficiency check and the before/after delta is compared to it on purpose (`received != held`); entry `CoreVaultTransit.recognizeRefund` is `nonReentrant` (`:84`) and the escrow is a keyless clone whose `release` can only pay the vault (`TransitEscrow.sol:34-38`). |
| 5 | reentrancy-balance | CoreVaultLogic.recognizeRefund | `src/core/CoreVaultLogic.sol:752`, `:753`, `:755` | Same as #4 (the `before` variable). |
| 6 | reentrancy-balance | SpokeCrossChainLib.recognizeRefund | `src/spoke/SpokeCrossChainLib.sol:87`, `:88`, `:90` | Same as #4; entry `SpokeVault.recognizeRefund` is `nonReentrant` (`SpokeVault.sol:395`). |
| 7 | reentrancy-balance | SpokeCrossChainLib.recognizeRefund | `src/spoke/SpokeCrossChainLib.sol:79`, `:88`, `:90` | Same as #6 (the `held` variable). |
| 8 | reentrancy-balance | SpokeCrossChainLib._executeBridgeCall | `src/spoke/SpokeCrossChainLib.sol:339`, `:341`, `:349` | Same as #3; entry `SpokeVault.sendToHub` is `nonReentrant` (`SpokeVault.sol:382-386`) and the target is pinned (`SpokeCrossChainLib.sol:262-263`). |

**Medium: divide-before-multiply and incorrect-equality**

| # | Detector | Contract.function | file:line | First-pass note |
|---|---|---|---|---|
| 9 | divide-before-multiply | CoreVaultLogic._collectIncome | `src/core/CoreVaultLogic.sol:388-389` | Looks like a false positive: the fee-then-slice rounding order is documented (`:380-381`, both round down); `managerFee -= slice` keeps fee plus slice equal to the first rounded fee, and each division loses less than one base unit of the token (the first in the holders' favour, the second in the manager's). |
| 10 | incorrect-equality | UniswapV4Adapter.swapExactInput | `src/adapters/UniswapV4Adapter.sol:533` (`limit == 0`) | Looks like a false positive: zero is the documented "no price limit" input (`:110-111`), not a balance comparison. |
| 11 | incorrect-equality | CoreVault.requestPayout | `src/core/CoreVault.sol:104` (`balance == 0`) | Looks like a false positive: guards a holder without shares; a Share balance cannot be raised by a transfer or donation. |
| 12 | incorrect-equality | CoreVault.claimPayout | `src/core/CoreVault.sol:172` (`c.shares == 0`) | Looks like a false positive: `c.shares` is a computed burn amount; zero means a partial payout would burn nothing and the call reverts `InsufficientFreeIdle`. |
| 13 | incorrect-equality | CoreVault.claimPayout | `src/core/CoreVault.sol:152` (`c.balance == 0`) | Same as #11. |
| 14 | incorrect-equality | CoreVault._executePayout | `src/core/CoreVault.sol:261` (`c.shares == c.balance`) | Looks like a false positive: full-burn detection compares the computed burn with the holder's own Share balance read at `:151`, which a third party cannot move. |
| 15 | incorrect-equality | CoreVault._executePayout | `src/core/CoreVault.sol:231` (`c.complete && c.shares == 0`) | Looks like a false positive: sets the `closedBelowOneShare` flag (DEC-077). |
| 16 | incorrect-equality | CoreVaultBase._topUpOperatingCash | `src/core/CoreVaultBase.sol:291` (`amount == 0`) | Looks like a false positive: early return when nothing can be topped up. |
| 17 | incorrect-equality | CoreVaultIncome._takeIncome | `src/core/CoreVaultIncome.sol:55` (`amount == 0`) | Looks like a false positive: nothing owed, returns 0 (note for step 10: no event on that path). |
| 18 | incorrect-equality | CoreVaultTransit.sweepExcess | `src/core/CoreVaultTransit.sol:131` (`amount == 0`) | Looks like a false positive: `amount` comes from `balanceOf` (`_unledgered`), so a donation makes it non-zero, but the only effect is that the garbage collector sweeps it to `excessRecipient` (DEC-101); zero is the no-op path (no event). |
| 19 | incorrect-equality | ValueReportReceiver.latestReport | `src/report/ValueReportReceiver.sol:220` (`state.acceptedAt == 0`) | Looks like a false positive: the documented sentinel for "no report accepted yet" (`SpokeState` NatSpec, `:37`). |

**Medium: reentrancy-no-eth**

| # | Detector | Contract.function | file:line | First-pass note |
|---|---|---|---|---|
| 20 | reentrancy-no-eth | AaveV3Adapter.openPosition | `src/adapters/AaveV3Adapter.sol:178` -> `:179` | Looks like a false positive: every verb is `onlyVault nonReentrant` (`:166-167`, `:192-193`, `:227-228`, `:252-253`, `:274`) and the calls go to the constructor-fixed Aave Pool and its aToken; the writes after the call record the scaled delta Aave produced (NatSpec `:246-249` accepts them, "Aave verifier finding"). |
| 21 | reentrancy-no-eth | AaveV3Adapter.increasePosition | `:203` -> `:204` (`l.principal += used0`) | Same as #20. |
| 22 | reentrancy-no-eth | AaveV3Adapter.increasePosition | `:203`, `:205` -> `:446`, `:450`, `:495` | Same as #20. |
| 23 | reentrancy-no-eth | AaveV3Adapter.closePosition | `:260` -> `:264` (`l.open = true`) | Same as #20; `open` is cleared before the call (`:258`) and restored only if income stays pending. |
| 24 | reentrancy-no-eth | AaveV3Adapter._exit | `:399`, `:424`, `:427` -> `:446`, `:450`, `:495` | Same as #20 (internal helper of the guarded verbs). |
| 25 | reentrancy-no-eth | AaveV3Adapter._exit | `:399`, `:424` -> `:495` | Same as #20. |
| 26 | reentrancy-no-eth | AaveV3Adapter._exit | `:399` -> `:411` (`l.realizedIncome += amounts.income0`) | Same as #20. |
| 27 | reentrancy-no-eth | AaveV3Adapter._takeIncome | `:445` -> `:446` | Same as #20. |
| 28 | reentrancy-no-eth | AaveV3Adapter._supply | `:468` -> `:470` (`l.scaledBalance += ...`) | Same as #20. |
| 29 | reentrancy-no-eth | AaveV3Adapter._withdraw | `:483`, `:489` -> `:495` | Same as #20. |
| 30 | reentrancy-no-eth | CoreVault.claimPayout | `src/core/CoreVault.sol:160`, `:174` -> `:239`, `:243`, `:246-248`, `CoreVaultIncome.sol:56` | Looks like a false positive: `nonReentrant`; the callees are the vault's own hub Spoke Vault (`:207`) and ShareToken (`:258`); the request is closed before the burn (`:246-248`) and `_takeIncome` debits `collectedIncome` before its transfer (`CoreVaultIncome.sol:56-57`). |
| 31 | reentrancy-no-eth | CoreVault._executePayout | `src/core/CoreVault.sol:258` -> `CoreVaultIncome.sol:56` (via `:261`) | Same as #30. |
| 32 | reentrancy-no-eth | SpokeVault.openPosition | `src/spoke/SpokeVault.sol:261` -> `:944-945` | Looks like a false positive under the adapter-trust model: `onlyManager nonReentrant` (`:250-252`), the callee is a Mandate adapter whose codehash is pinned and re-checked (`_positionAdapter`, `:694-700`), and `_requireBacked` (`:268`) reverts when the ledger exceeds the token balance. Not caught by that check: an adapter that misreports the principal/income split. |
| 33 | reentrancy-no-eth | SpokeVault.increasePosition | `:287` -> `:944-945` | Same as #32 (`:290`). |
| 34 | reentrancy-no-eth | SpokeVault.unwindForPayout | `:538` -> `:543` | Same as #32; entry is `nonReentrant` and Core-Vault-only (`:524-530`). |
| 35 | reentrancy-no-eth | SpokeVault._exit | `:762` -> `:719-723` | Same as #32 (`_requireBacked` at `:774`). |
| 36 | reentrancy-no-eth | SpokeVault._exit | `:759`, `:762`, `:770` -> `:951-955` | Same as #32. |
| 37 | reentrancy-no-eth | SpokeVault._swap | `:799` -> `:802` | Same as #32 (`_requireBacked` at `:808`); the output is also bounded below by `minAmountOut` (`:800`). |
| 38 | reentrancy-no-eth | SpokeVault._unwindPosition | `:860-864` -> ledger writes in `_exit` and `_swap` | Same as #32. |
| 39 | reentrancy-no-eth | SpokeVault._unwindPosition | `:860-864` -> ledger writes in `_exit` and `_swap` | Same as #32. |

**Medium: uninitialized-local** (Solidity zero-initialises locals; each was checked for a read before assignment)

| # | Detector | Variable | file:line | First-pass note |
|---|---|---|---|---|
| 40 | uninitialized-local | AaveV3Adapter.positionKeys `count` | `src/adapters/AaveV3Adapter.sol:326` | Looks like a false positive: a counter that starts at zero on purpose. |
| 41 | uninitialized-local | AaveV3Adapter._withdraw `withdrawn` | `src/adapters/AaveV3Adapter.sol:481` | Looks like a false positive: assigned in both branches before use (`:484`, `:489`). |
| 42 | uninitialized-local | CoreVault.requestPayout `reserved` | `src/core/CoreVault.sol:109` | Looks like a false positive: 0 is the value for an Instant request; set only in the Standard branch (`:115`). |
| 43 | uninitialized-local | CoreVault.claimPayout `c` | `src/core/CoreVault.sol:150` | Looks like a false positive: a memory struct filled field by field before use (`:151`, `_priceClaim`, `:166-167`); `proceeds` stays 0 unless an unwind runs. |
| 44 | uninitialized-local | CoreVaultLogic._valuation `shortfall` | `src/core/CoreVaultLogic.sol:181` | Looks like a false positive: accumulator (`:184`). |
| 45 | uninitialized-local | CoreVaultLogic._price `fellBack` | `src/core/CoreVaultLogic.sol:331` | Looks like a false positive: false unless the PAYOUT `catch` sets it (`:336`). |
| 46 | uninitialized-local | CoreVaultLogic._hubBridgeAdapter `seen` | `src/core/CoreVaultLogic.sol:698` | Looks like a false positive: counter (`:702`). |
| 47 | uninitialized-local | FundFactory._deployUniswapV4Adapter `matched` | `src/factory/FundFactory.sol:386` | Looks like a false positive: counter (`:393`), compared to the pool count at `:395`. |
| 48 | uninitialized-local | FundFactory._deployCoreVault `c` | `src/factory/FundFactory.sol:462` | Looks like a false positive: all 14 `CoreVaultConfig` fields are assigned at `:463-477`. |
| 49 | uninitialized-local | IncomeAccumulator.distribute `newRemainder` | `src/libraries/IncomeAccumulator.sol:200` | Looks like a false positive: written on the `ok` branch, read only after the `!ok` return (`:212-216`). |
| 50 | uninitialized-local | IncomeAccumulator.distribute `newIndex` | `src/libraries/IncomeAccumulator.sol:210` | Looks like a false positive: assigned by `tryAdd` (`:211`), read only when `ok`. |
| 51 | uninitialized-local | MandateLib.bridgeAdapterFor `seen` | `src/mandate/Mandate.sol:246` | Looks like a false positive: counter (`:251`). |
| 52 | uninitialized-local | SpokeCrossChainLib._buildCall `req` | `src/spoke/SpokeCrossChainLib.sol:250` | Looks like a false positive: all 10 `SendRequest` fields are assigned at `:251-260`. |
| 53 | uninitialized-local | SpokeVault.unwindForPayout `visited` | `src/spoke/SpokeVault.sol:536` | Looks like a false positive: counter threaded through `_unwindStep` (`:538`). |
| 54 | uninitialized-local | SpokeVault._unwindStep `swaps` | `src/spoke/SpokeVault.sol:831` | Looks like a false positive: an empty array unless a claimant hint exists (`:832`). |

**Medium: unused-return**

| # | Detector | Contract.function | file:line | First-pass note |
|---|---|---|---|---|
| 55 | unused-return | UniswapV4Adapter.unwindExitParams | `src/adapters/UniswapV4Adapter.sol:322-324` | Looks like a false positive: only `liquidity` of the `getPositionInfo` tuple is used. |
| 56 | unused-return | UniswapV4Adapter.spotQuote | `:335` | Looks like a false positive: only `sqrtPriceX96` of `getSlot0` is used. |
| 57 | unused-return | UniswapV4Adapter.openPosition | `:369` (`_openPositions.add`) | Looks like a false positive: the key is the PositionManager's next token id, unique per mint, in a `nonReentrant` call. |
| 58 | unused-return | UniswapV4Adapter.closePosition | `:480` (`_openPositions.remove`) | Looks like a false positive: membership was checked by `_openPosition` (`:470`). |
| 59 | unused-return | UniswapV4Adapter._principal | `:626` | Looks like a false positive: tuple fields not needed. |
| 60 | unused-return | UniswapV4Adapter._liquidityForAmounts | `:644` | Looks like a false positive: tuple fields not needed. |
| 61 | unused-return | CoreVault.requestPayout | `src/core/CoreVault.sol:105` | Looks like a false positive: the second return (`consolidation`) is not needed for a request. |
| 62 | unused-return | CoreVault._unwindForPayout | `src/core/CoreVault.sol:207-212` | Looks like a false positive: by design the reported proceeds are informational and Idle is credited only through `returnToIdle` (NatSpec `:199-203`, DEC-080). |
| 63 | unused-return | CoreVaultBase.shareAssets | `src/core/CoreVaultBase.sol:236` | Looks like a false positive: tuple field not needed. |
| 64 | unused-return | CoreVaultBase.inFlightValue | `src/core/CoreVaultBase.sol:246` | Looks like a false positive: tuple field not needed. |
| 65 | unused-return | CoreVaultLogic.grossAssets | `src/core/CoreVaultLogic.sol:132` | Looks like a false positive: only the report of `latestReport` is used. |
| 66 | unused-return | CoreVaultLogic.spokeCapUsage | `:153` | Looks like a false positive: same. |
| 67 | unused-return | CoreVaultLogic._spokeValue | `:206` | Looks like a false positive: same. |
| 68 | unused-return | CoreVaultLogic._price | `:333-338` | Looks like a false positive: in PAYOUT mode `updatedAt` is ignored on purpose (age never blocks a payout, OQ-10; NatSpec `:319-322`). |
| 69 | unused-return | CoreVaultLogic._collectIncome | `:393` (`s.income.distribute(...)`) | Looks like a false positive in practice, but noted: `distribute` returns false only for an unregistered token, an amount above 2^128 - 1 or an index overflow, while `collectedIncome[token] += net` is written first (`:392`), so in that case the value would sit in the collected bucket with no owner. Reaching it needs more than 2^128 units of an income token. Expert to confirm if `MAX_STEP` is questioned. |
| 70 | unused-return | CoreVaultLogic.applyReport | `:419` | Looks like a false positive: only the report is used. |
| 71 | unused-return | CoreVaultLogic.nonArrivalProvable | `:553` | Looks like a false positive: only the report is used. |
| 72 | unused-return | CoreVaultLogic.recognizeRefund | `:753` (`escrow.release`) | Looks like a false positive: the released amount is verified by the balance delta (`:754-755`). |
| 73 | unused-return | FundFactory.createSpoke | `src/factory/FundFactory.sol:200` | Looks like a false positive: the spoke index is not needed; the call reverts `UnknownSpokeChain` for a non-spoke chain. |
| 74 | unused-return | FundFactory._deployCoreVault | `:478` (`Create3.deploy`) | Looks like a false positive: the address is predicted beforehand and `Create3.deploy` reverts `DeploymentWithoutCode` (`Create3.sol:55`). |
| 75 | unused-return | FundFactory._deploy | `:509` | Same as #74. |
| 76 | unused-return | ChainlinkPriceSource.priceInUsdc | `src/report/ChainlinkPriceSource.sol:124` | Looks like a false positive for the detector (`roundId`, `startedAt`, `answeredInRound` unused). Separately, the NatSpec states there is no L2 sequencer-uptime check and no min/max-answer awareness (`:75-78`); that is a documented stance, not a Slither result. |
| 77 | unused-return | SpokeCrossChainLib.recognizeRefund | `src/spoke/SpokeCrossChainLib.sol:88` | Same as #72 (`:89-90`). |
| 78 | unused-return | SpokeVault.constructor | `src/spoke/SpokeVault.sol:155` | Looks like a false positive: the index is not needed. |

No result got "needs expert" as a plain classification; the closest is #69, flagged in its row. None looked real as
Slither reports it. Several notes rest on trust assumptions (adapter code pinned by codehash, the Aave Pool and the Across
SpokePool being the intended contracts, ShareToken being non-transferable); those assumptions, not the detectors, are what
the coordinator should re-verify.

## 7. Aderyn

Command (raw: `raw/aderyn-stdout.txt`, `raw/aderyn-report.md`): `aderyn .` in the repository root.

Aderyn 0.6.8 ran 88 detectors on the 45 `.sol` files under `src/` (5,246 nSLOC; its default scope is `src/`) and wrote `report.md` in
the repository root. That untracked file was moved to `raw/aderyn-report.md`. Run time 4.5 s, exit 0. Its Issue Summary has only two severity
rows:

| Severity | Categories | Instances |
|---|---:|---:|
| High | 6 | 21 |
| Low | 15 | 114 |

Low categories (instances): L-1 Centralization Risk (4), L-2 Costly operations inside loop (4), L-3 Internal Function Used Only
Once (11), L-4 Large Numeric Literal (5), L-5 Literal Instead of Constant (11), L-6 Modifier Invoked Only Once (1), L-7
`nonReentrant` is Not the First Modifier (28), L-8 Loop Contains `require`/`revert` (10), L-9 State Change Without Event (1, it is
`TransitEscrow.initialize`, `src/core/TransitEscrow.sol:26`, see step 10), L-10 State Variable Could Be Immutable (1,
`AaveV3Adapter._assets`, an array), L-11 Storage Array Length not Cached (2), L-12 Unchecked Return (12), L-13 Uninitialized Local
Variable (12), L-14 Unsafe ERC20 Operation (2, both `permit2.approve` in `UniswapV4Adapter.sol:684,690`), L-15 Public Function Not
Used Internally (10).

### High results, with a first-pass note

| Issue | file:line | First-pass note |
|---|---|---|
| H-1 `abi.encodePacked()` hash collision (3) | `src/factory/CodeStore.sol:42` | Looks like a false positive: builds the data-contract init code from constants plus one dynamic `part`; it is a CREATE payload, not a hash input. |
| | `src/factory/FundFactory.sol:478` | Looks like a false positive: same as Slither #1 (creation code plus ABI-encoded arguments, never hashed). |
| | `src/factory/FundFactory.sol:509` | Looks like a false positive: stored creation code plus `args` concatenated into init code; `creationCodeHash[role]` is a hash of the code alone, computed once in the constructor (`:129`). |
| H-2 Contract locks Ether without a withdraw function (1) | `src/spoke/SpokeVault.sol:37` | Looks like a false positive for the payable path: `report()` (`:404-416`) forwards all of `msg.value` to `ICoreBridge.publishMessage{value: msg.value}` (`:414`), and the Wormhole SDK notes that call needs a `msg.value` equal to the message fee (`lib/wormhole-solidity-sdk/src/interfaces/ICoreBridge.sol:58`). Ether can otherwise arrive only by a forced send, and `sweepExcess` handles ERC-20 only, so forced-sent ETH would be stuck; nothing values it. |
| H-3 Reentrancy: state change after external call (13) | `src/adapters/AaveV3Adapter.sol:133` | Looks like a false positive: constructor, external call to the Aave Pool before writing the ledger; nothing can re-enter a contract that does not exist yet. |
| | `src/adapters/AaveV3Adapter.sol:174`, `:199`, `:277` | Looks like a false positive: `getReserveNormalizedIncome` is a view on the fixed Pool inside `onlyVault nonReentrant` verbs. |
| | `src/adapters/AcrossBridgeAdapter.sol:62` | Looks like a false positive: constructor call to `fillDeadlineBuffer()` before the immutables are set. |
| | `src/adapters/UniswapV4Adapter.sol:366` | Looks like a false positive: `positionManager.nextTokenId()` is a view read inside an `onlyVault nonReentrant` verb. |
| | `src/core/CoreVaultLogic.sol:590`, `:592` | Looks like a false positive: the callees are the fresh escrow clone (`initialize`) and the Mandate bridge adapter's view `buildSend`; the entry is `nonReentrant` and the effects are written before the only value-moving call (`:626`). |
| | `src/core/CoreVaultLogic.sol:743` and `src/spoke/SpokeCrossChainLib.sol:79` | Looks like a false positive: `token.balanceOf(escrow)` is a view on USDC used as the refund sufficiency check; same as Slither #4 and #6. |
| | `src/report/ChainlinkPriceSource.sol:85` | Looks like a false positive: constructor reading `decimals()` from the aggregator before storing the config. |
| | `src/report/ValueReportReceiver.sol:145` | Looks like a false positive: `deliver` is `nonReentrant`; the Core Bridge call is `parseAndVerifyVM`, a view, and the state is written before the only state-changing external call, the callback `onReportAccepted` (`:201`). |
| | `src/spoke/SpokeVault.sol:261` | Same as Slither #32 (Mandate adapter, codehash pinned, `nonReentrant`, `_requireBacked` after). |
| H-4 Storage Array Edited with Memory (1) | `src/spoke/SpokeVault.sol:538` | Looks like a false positive: `_unwindStep` takes the `UnwindStep` element as a memory copy and only reads `step.adapter` and `step.poolKey` (`:821-837`); nothing is written back, so no edit is lost. |
| H-5 Unsafe Casting of integers (2) | `src/adapters/UniswapV4Adapter.sol:707` | Looks like a false positive: `bytes1(uint8(action))` where every `Actions.*` constant is below 0x20 (comment at `:705`). |
| | `src/core/CoreVaultLogic.sol:404` | Looks like a false positive: `uint16(BPS)` with `BPS = 10_000`, guarded by `value > BPS ?` (a `uint16` holds up to 65,535). |
| H-6 Yul block contains `return` (1) | `src/spoke/SpokeVault.sol:426` | Looks like a false positive: `buildReport()` is a `view` with no modifier; the assembly `return` is its last statement and returns the ABI-encoded tail of the library payload after overwriting the offset word in place inside the already-allocated `payload` (NatSpec `:418-420`, code `:423-427`), so no epilogue is skipped and only allocated memory is written. |

The 21 High instances are 3 + 1 + 13 + 1 + 2 + 1. None looks real as reported.

## 8. Solhint

The repository has **no solhint configuration**: no `.solhint.json`, `.solhintignore` or `package.json` outside `lib/` (checked with
`find . -maxdepth 3 ...`). A config was created outside the repo at `raw/solhint.json` containing exactly
`{"extends": "solhint:recommended"}`.

Command (raw: `raw/solhint.txt`, parsed counts in `raw/solhint-summary.txt`), run from the repository root with solhint 6.2.4:

```
solhint -c raw/solhint.json 'src/**/*.sol'
```

Result: solhint reports **1040 problems: 0 errors, 1040 warnings**, spread over all 45 files. Exit code 0. Counts per rule (every
one is a warning; the parsed total equals solhint's own total):

| Rule | Severity | Count |
|---|---|---:|
| use-natspec | warning | 717 |
| gas-indexed-events | warning | 91 |
| immutable-vars-naming | warning | 69 |
| import-path-check | warning | 64 |
| gas-strict-inequalities | warning | 33 |
| func-visibility | warning | 14 |
| no-inline-assembly | warning | 13 |
| use-forbidden-name | warning | 12 |
| gas-struct-packing | warning | 8 |
| gas-calldata-parameters | warning | 7 |
| gas-increment-by-one | warning | 5 |
| function-max-lines | warning | 4 |
| avoid-low-level-calls | warning | 3 |
| **Total** | | **1040** |

Errors: none. Warnings: 1040, of which 144 are `gas-*` rules and 896 are not.

Facts about the counts:

- The three most affected files are `src/interfaces/ICoreVault.sol` (143), `src/interfaces/ISpokeVault.sol` (139) and
  `src/core/CoreVaultLogic.sol` (105). The 717 `use-natspec` items are: `@param` name mismatch or missing on functions (180 + 178),
  the same on events (66 + 66), `@return` mismatch or missing (65 + 65), missing `@author` on contracts (43), missing `@notice` on
  functions, variables and events (25 + 23 + 6).
- `import-path-check` (64) reports imports such as `@openzeppelin/contracts/token/ERC20/IERC20.sol` as not existing. Solhint
  does not read `remappings.txt`, and the same imports compile under forge, so these 64 come from the tool setup, not the code.
- `func-visibility` (14) is the message "Explicitly mark visibility in function (Set ignoreConstructors to true if using solidity
  >=0.7.0)", i.e. constructors.
- `no-inline-assembly` (13) and `avoid-low-level-calls` (3) match the 13 `assembly` blocks and the 3 low-level `.call(` sites of the grep
  inventory in step 9. `immutable-vars-naming` (69) and `use-forbidden-name` (12, single-letter names such as `l`) are naming
  style.

## 9. Grep inventory over `src/`

Command: `python3 raw/grep-inventory.py REPO > raw/grep-inventory.txt`. The script reads all 45 `.sol` files under `src/`
(interfaces included), blanks comments before matching, and writes every hit as `path:line: code`, code hits first and
comment-only hits (the pattern appears only inside a comment) second. The full lists are in `raw/grep-inventory.txt`; this
section has the counts and the facts worth reading first.

| Pattern | Total hits | Code hits | Comment-only hits |
|---|---:|---:|---:|
| `tx.origin` | 0 | 0 | 0 |
| `selfdestruct` | 5 | 0 | 5 |
| `delegatecall` | 0 | 0 | 0 |
| `assembly` | 13 | 13 | 0 |
| `unchecked` | 1 | 1 | 0 |
| `block.timestamp` | 32 | 25 | 7 |
| `block.number` | 2 | 2 | 0 |
| low-level `.call(`, `.call{`, `.staticcall(` | 3 | 3 | 0 |
| `balanceOf(` | 26 | 22 | 4 |
| `approve(`, `forceApprove(`, `safeIncreaseAllowance`, `safeApprove` | 11 | 11 | 0 |
| `try ` | 7 | 6 | 1 |
| `catch` | 7 | 6 | 1 |
| `abi.encodePacked` | 5 | 5 | 0 |
| `ecrecover` | 0 | 0 | 0 |
| `payable` | 7 | 3 | 4 |
| `receive()` | 0 | 0 | 0 |
| `fallback()` | 0 | 0 | 0 |
| `TODO`, `FIXME`, `XXX`, `HACK` | 0 | 0 | 0 |
| `pragma solidity` | 45 | 45 | 0 |
| `using ... for` | 18 | 18 | 0 |
| extra, not requested: `.transfer(` or `.send(` | 0 | 0 | 0 |
| extra, not requested: `nonReentrant` | 48 | 44 | 4 |

What the hits are (code hits only):

- **`selfdestruct` and `delegatecall`: no code hits.** The 5 `selfdestruct` hits are NatSpec sentences saying there is none
  (`CoreVault.sol:20`, `ManagerFeeVault.sol:13`, `Create3Deployer.sol:17`, `FundFactory.sol:29`, `SpokeVault.sol:26`). There is no
  `delegatecall` in source text, but the compiler emits DELEGATECALL for the two linked libraries with external functions
  (`CoreVaultLogic` from `CoreVault`, `SpokeCrossChainLib` from `SpokeVault`; step 2). The NatSpec of both vaults says
  so and calls it the only DELEGATECALL of the vault, into the fund's own linked library, never an adapter (`SpokeVault.sol:28-33`,
  `CoreVault.sol:21-24`).
- **`tx.origin`, `ecrecover`, `receive()`, `fallback()`, `.transfer(`, `.send(`, TODO-style markers: none.**
- **`assembly` (13), all `assembly ("memory-safe")`:** `CoreVaultLogic.sol:628` (revert bubbling), `CodeStore.sol:36,44,65`,
  `Create3.sol:44,50`, `FundFactory.sol:424,492`, `SpokeCrossChainLib.sol:188,201,343`, `SpokeVault.sol:423,743`. Two use `mcopy`
  (`SpokeCrossChainLib.sol:204`, `CodeStore.sol:37`) and the Core Vault uses transient storage (`ReentrancyGuardTransient`,
  `bool internal transient _unwinding` at `CoreVaultBase.sol:60`), so the code needs the Cancun opcodes (`evm_version = "cancun"`).
  Fork tests run in Foundry's local EVM, so they do not show that the target chains execute those opcodes.
- **`unchecked` (1):** `UniswapV4Adapter.sol:611`, the wrapping fee-growth subtraction copied from the PoolManager's own formula.
- **Low-level calls (3):** `CoreVaultLogic.sol:626` and `SpokeCrossChainLib.sol:341` (the bridge call to the pinned target, with balance
  checks around it), `Create3.sol:48` (the CREATE3 proxy). All bubble the revert data.
- **Approvals (11):** the pattern is `forceApprove(spender, amount)` then reset to 0 at `CoreVaultLogic.sol:625,634`,
  `SpokeCrossChainLib.sol:340,350`, `AaveV3Adapter.sol:467,469`, `UniswapV4Adapter.sol:683,691` plus Permit2 `approve` at
  `UniswapV4Adapter.sol:684,690`; `ShareToken.sol:71` is the `approve` override that always reverts. No `safeApprove` or
  `safeIncreaseAllowance`.
- **`try`/`catch` (6 each):** `AaveV3Adapter.sol:399/413` and `:483/485` (Aave withdraw), `CoreVault.sol:207/209` (hub unwind),
  `CoreVaultLogic.sol:227/229` (hub `buildReport`), `:333/335` (price source), `:402/405` (manager registry).
- **`abi.encodePacked` (5):** `CodeStore.sol:42`, `Create3.sol:65,78` (address derivation, fixed-size arguments),
  `FundFactory.sol:478,509` (init code).
- **`payable` (3):** `ISpokeVault.sol:273` and `SpokeVault.sol:406` (`report()`), `IAcrossSpokePool.sol:54` (`depositV3`). No
  `address payable`, no `receive`, no `fallback`.
- **`block.timestamp` (25 code hits) and `block.number` (2):** listed in the raw file; `block.number` is only written into the report
  (`SpokeCrossChainLib.sol:137`) and an event (`SpokeVault.sol:415`).
- **`pragma solidity`: yes, all the same fixed version.** 45 of 45 files have `pragma solidity 0.8.28;` (exact, not a range), the
  same as `solc_version` in `foundry.toml`.
- **`using ... for` (18):** `SafeERC20 for IERC20` in 10 files (`AaveV3Adapter:41`, `UniswapV4Adapter:52`, `CoreVault:28`,
  `CoreVaultIncome:22`, `CoreVaultLogic:35`, `CoreVaultTransit:17`, `ManagerFeeVault:15`, `TransitEscrow:13`,
  `SpokeCrossChainLib:26`, `SpokeVault:38`), `IncomeAccumulator for IncomeAccumulator.State` (`CoreVault:29`, `CoreVaultBase:23`,
  `CoreVaultIncome:23`, `CoreVaultLogic:36`), `MandateLib for Mandate` (`FundFactory:32`, `SpokeVault:39`),
  `EnumerableSet for EnumerableSet.Bytes32Set` and `SafeCast for uint256` (`UniswapV4Adapter:53,54`).

### Contracts that inherit `ReentrancyGuard`, `Ownable`, `Ownable2Step` or `Pausable`

Parsed from the declarations (a contract is listed once, with its direct base and, for the Core Vault chain, the base it reaches):

| Contract | Declaration | Guard or owner base |
|---|---|---|
| AaveV3Adapter | `AaveV3Adapter.sol:40` | `ReentrancyGuard` (OpenZeppelin, storage based), direct |
| UniswapV4Adapter | `UniswapV4Adapter.sol:51` | `ReentrancyGuard`, direct |
| ManagerFeeVault | `ManagerFeeVault.sol:14` | `ReentrancyGuard`, direct |
| SpokeVault | `SpokeVault.sol:37` | `ReentrancyGuard`, direct |
| ValueReportReceiver | `ValueReportReceiver.sol:22` | `ReentrancyGuard`, direct |
| CoreVaultBase | `CoreVaultBase.sol:22` | `ReentrancyGuardTransient`, direct |
| CoreVaultIncome | `CoreVaultIncome.sol:21` | `ReentrancyGuardTransient`, through `CoreVaultBase` |
| CoreVaultTransit | `CoreVaultTransit.sol:16` | `ReentrancyGuardTransient`, through `CoreVaultBase` |
| CoreVault | `CoreVault.sol:27` | `ReentrancyGuardTransient`, through `CoreVaultBase` |
| FundFactory | `FundFactory.sol:31` | `ReentrancyGuardTransient`, direct |
| ManagerRegistry | `ManagerRegistry.sol:17` | `Ownable2Step` (constructor calls `Ownable(initialOwner)`, `:34`), direct |

No contract inherits `Pausable` or `AccessControl`; the adapters carry their own `paused` and `deprecated` flags in
`AdapterGuard` (`src/adapters/AdapterGuard.sol`). `CoreVaultBase.sol:176` reads the transient guard by hand in the
`onlyHubSpokeVaultCallback` modifier: `if (_reentrancyGuardEntered() && !_unwinding) revert ReentrancyGuardReentrantCall();`.

## 10. Event inventory

Rule under test: every operation ends with an event a server can monitor. This step is a reading task: every function below was
opened, and calls were followed through internal functions, `CoreVaultLogic`, `SpokeCrossChainLib`, `IncomeAccumulator` and the
OpenZeppelin base classes. A mechanical first pass (`raw/event-scan.py`, output `raw/event-scan-auto.txt`) listed the candidates; the
table below was built from the reading (`raw/event-table-data.py`), and every function declaration line and every emit line it cites
(153 references, the two OpenZeppelin rows included) was machine-checked against the source.

Scope and completeness: all `external` or `public` functions in `src/` that are not `view` or `pure`, `src/interfaces/` skipped:
**67 functions** in 17 contracts, abstract contracts and libraries, plus the 2 state-changing functions `ManagerRegistry` inherits from OpenZeppelin
(`renounceOwnership` is overridden as a reverting `view`, `ShareToken.transfer`, `transferFrom` and `approve` are `pure` reverting
overrides, so those are not state-changing). Cross-checks: the mechanical scan finds the same 67 declarations (name, file, line), and
for the 13 deployable contracts the state-changing entries of their compiled ABIs (`out/*.json`) equal this list exactly (for
example `CoreVault` 15, `SpokeVault` 17, `AaveV3Adapter` 7 with the two `AdapterGuard` functions). `CoreVaultLogic` and
`SpokeCrossChainLib` are libraries reached by DELEGATECALL, so their events are emitted from the vault's address; their
entry points are listed as rows of their own and also inside the vault verb that calls them. `Create3`, `CodeStore`, `MandateLib`,
`IncomeAccumulator`, `ShareMath`, `ReportCodec`, `TransitMessage` and `SpokeVaultTypes` have only internal functions and are not
entry points.

Result in short:

- **NO EVENT FOUND: 4 functions.** `TransitEscrow.initialize` and `TransitEscrow.release` (no `emit` in the body, nothing to follow);
  `UniswapV4Adapter.unlockCallback` (the callback of `swapExactInput`, which emits `Swapped` after it); `SpokeCrossChainLib.nextReport`
  (library helper of `SpokeVault.report`, which emits `ReportPublished`). Only the two escrow functions emit nothing of their own and
  rely entirely on the calling verb's event and the token's `Transfer`.
- **ERC-20 `Transfer` only: 2.** `ShareToken.mint` and `burn` emit no vault-specific event; the Core Vault verbs that call them emit `Deposited`,
  `PayoutExecuted` or `PartialPayoutExecuted` in the same transaction.
- **Silent no-op paths (the call succeeds and emits nothing): 4.** A repeated `AdapterGuard.deprecate()` (`AdapterGuard.sol:44`);
  `withdrawIncome` when nothing is owed (`CoreVaultIncome.sol:55`); `CoreVaultTransit.sweepExcess` and `SpokeVault.sweepExcess` when
  there is nothing to sweep (`CoreVaultTransit.sol:131`, `SpokeVault.sol:559`).
- **Emit before the last external interaction** (the event is not the last statement; everything is atomic, so a revert undoes it):
  `CoreVault.deposit` (before `safeTransferFrom` and `mint`), `receiveCollectedIncome` (before the fee transfers),
  `allocateToHubSpokeVault` (before the transfer and the spoke call), `CoreVaultLogic.sendToSpoke` (before the bridge CALL), both
  `recognizeRefund` (before `escrow.release`), `ManagerFeeVault.withdraw` (before the transfer), `ValueReportReceiver.deliver`
  (before the Core Vault callback). Forge's `reentrancy-events` lint (step 2) flags the opposite pattern (event after an external call) 50
  times in `src/`.
- **Conditional extra events.** `_topUpOperatingCash` emits `OperatingCashToppedUp` and `OperatingExpensePaid` (and
  `OperatingCashInsufficient` on the hub) only when Operating Cash is below its floor, and almost every value-moving verb on both vaults calls it;
  `recordValuation` emits `HubValuationFallback` or `PriceFallback` only when a read falls back.

Key for the "Caller and modifiers" column: modifiers are as declared; a caller check written inside the body is shown as "in body";
"permissionless" means no caller check at all.


| # | Contract | Function | file:line | Caller and modifiers | Event reached on the success path | Where the emit sits | Result |
|---:|---|---|---|---|---|---|---|
| 1 | AaveV3Adapter | `openPosition` | `src/adapters/AaveV3Adapter.sol:164` | onlyVault, nonReentrant; `_requireEntryAllowed()` in body | `PositionOpened` (`:181`) | last statement | event on success path |
| 2 | AaveV3Adapter | `increasePosition` | `src/adapters/AaveV3Adapter.sol:190` | onlyVault, nonReentrant; `_requireEntryAllowed()` in body | `PositionIncreased` (`:207`) | last statement | event on success path |
| 3 | AaveV3Adapter | `decreasePosition` | `src/adapters/AaveV3Adapter.sol:225` | onlyVault, nonReentrant | `PositionDecreased` (`:235`) | last statement | event on success path |
| 4 | AaveV3Adapter | `closePosition` | `src/adapters/AaveV3Adapter.sol:250` | onlyVault, nonReentrant | `PositionClosed` (`:262`) or, when income stays pending, `PositionDecreased` (`:265`) | last statement | event on success path |
| 5 | AaveV3Adapter | `collectIncome` | `src/adapters/AaveV3Adapter.sol:274` | onlyVault, nonReentrant | `IncomeCollected` (`:282`), also with 0 income | last statement | event on success path |
| 6 | AdapterGuard (in AaveV3Adapter, UniswapV4Adapter, AcrossBridgeAdapter) | `setPaused` | `src/adapters/AdapterGuard.sol:36` | onlyGuardian | `PausedSet` (`:38`) | last statement | event on success path |
| 7 | AdapterGuard (same three) | `deprecate` | `src/adapters/AdapterGuard.sol:43` | onlyGuardian | `AdapterDeprecated` (`:46`) on the first call only | last statement | event on the first call; **a repeat call returns at `:44` with no event** (documented at `:42`) |
| 8 | UniswapV4Adapter | `openPosition` | `src/adapters/UniswapV4Adapter.sol:350` | onlyVault, nonReentrant; `_requireEntryAllowed()` | `PositionOpened` (`:381`) | last statement | event on success path |
| 9 | UniswapV4Adapter | `increasePosition` | `src/adapters/UniswapV4Adapter.sol:388` | onlyVault, nonReentrant; `_requireEntryAllowed()` | `PositionIncreased` (`:418`) | last statement | event on success path |
| 10 | UniswapV4Adapter | `decreasePosition` | `src/adapters/UniswapV4Adapter.sol:428` | onlyVault, nonReentrant | `PositionDecreased` (`:458`) | last statement | event on success path |
| 11 | UniswapV4Adapter | `closePosition` | `src/adapters/UniswapV4Adapter.sol:464` | onlyVault, nonReentrant | `PositionClosed` (`:489`) | last statement | event on success path |
| 12 | UniswapV4Adapter | `collectIncome` | `src/adapters/UniswapV4Adapter.sol:495` | onlyVault, nonReentrant | `IncomeCollected` (`:509`), also with 0 income | last statement | event on success path |
| 13 | UniswapV4Adapter | `swapExactInput` | `src/adapters/UniswapV4Adapter.sol:516` | onlyVault, nonReentrant; reverts if deprecated | `Swapped` (`:542`: pool, tokens, amountIn, amountOut) | last statement, after `unlock` and `_returnUnused` | event on success path |
| 14 | UniswapV4Adapter | `unlockCallback` | `src/adapters/UniswapV4Adapter.sol:548` | none; `msg.sender == poolManager` in body (`:549`) | **NO EVENT FOUND** in the function. Followed: it only calls `poolManager.swap`, `sync`, `settle`, `take` (external). The one caller, `swapExactInput`, emits `Swapped` (`:542`) after `poolManager.unlock` returns | - | no event in the callback; the calling verb emits |
| 15 | CoreVault | `deposit` | `src/core/CoreVault.sol:56` | nonReentrant (any depositor) | `Deposited` (`:82`); plus `OperatingCashToppedUp`, `OperatingExpensePaid` (and `OperatingCashInsufficient`) when the top-up runs (`CoreVaultBase.sol:290-297`) | **before** the two `safeTransferFrom` calls and the `mint` (`:84-87`); state (`_s.idle`) is already updated | event on success path |
| 16 | CoreVault | `requestPayout` | `src/core/CoreVault.sol:98` | nonReentrant (any holder) | `PayoutRequested` (`:129`); `HubValuationFallback` / `PriceFallback` from `recordValuation` (`CoreVaultLogic.sol:97,100`) only when a read falls back | last statement | event on success path |
| 17 | CoreVault | `claimPayout` | `src/core/CoreVault.sol:144` | nonReentrant (any holder) | `PayoutExecuted` (`:175`) or `PartialPayoutExecuted` (`:176`); also `UnwindForPayoutFailed` (`:211`), `IncomeWithdrawn` for a full burn (`CoreVaultIncome.sol:58`), top-up and fallback events | last statement, after the burn and every transfer | event on success path |
| 18 | CoreVaultBase (in CoreVault) | `setOperatingCashParameters` | `src/core/CoreVaultBase.sol:269` | onlyManager | `OperatingCashParametersSet` (`:272`) | last statement | event on success path |
| 19 | CoreVaultIncome (in CoreVault) | `receiveCollectedIncome` | `src/core/CoreVaultIncome.sol:28` | nonReentrant; `msg.sender == hubSpokeVault` in body (`:29`) | via `CoreVaultLogic.collectIncome` (`CoreVaultLogic.sol:382`) -> `_collectIncome`: `CollectedIncomeReceived` (`CoreVaultLogic.sol:394`: amount, manager fee, protocol slice, slice bps); plus `IncomeDistributed` / `OwnerlessIncome` / `UnknownIncomeToken` / `DistributionSkipped` from `IncomeAccumulator.distribute` | **before** the two fee `safeTransfer` calls (`CoreVaultLogic.sol:395-396`) | event on success path |
| 20 | CoreVaultIncome (in CoreVault) | `withdrawIncome` | `src/core/CoreVaultIncome.sol:38` | nonReentrant (any holder) | `IncomeWithdrawn` (`CoreVaultIncome.sol:58`, inside `_takeIncome`) | after the transfer | event when `amount != 0`; **no event when nothing is owed**: `_takeIncome` returns 0 at `:55` |
| 21 | CoreVaultIncome (in CoreVault) | `decreaseManagerFee` | `src/core/CoreVaultIncome.sol:64` | onlyManager, nonReentrant | `ManagerFeeDecreased` (`:73`) | last statement | event on success path |
| 22 | CoreVaultTransit (in CoreVault) | `allocateToHubSpokeVault` | `src/core/CoreVaultTransit.sol:26` | onlyManager, nonReentrant | `AllocatedToHubSpokeVault` (`:33`); top-up events | **before** the `safeTransfer` and `receiveFromCoreVault` call (`:34-35`) | event on success path |
| 23 | CoreVaultTransit (in CoreVault) | `returnToIdle` | `src/core/CoreVaultTransit.sol:43` | onlyHubSpokeVaultCallback (no `nonReentrant`) | `ReturnedToIdle` (`:49`) | last statement | event on success path |
| 24 | CoreVaultTransit (in CoreVault) | `sendToSpoke` | `src/core/CoreVaultTransit.sol:58` | onlyManager, nonReentrant | via `CoreVaultLogic.sendToSpoke`: `SentToSpoke` (`CoreVaultLogic.sol:620`: transit struct, spoke, hub chain); top-up events | **before** the bridge CALL (`CoreVaultLogic.sol:626`) | event on success path |
| 25 | CoreVaultTransit (in CoreVault) | `attestExpiry` | `src/core/CoreVaultTransit.sol:76` | nonReentrant (permissionless) | via `CoreVaultLogic.attestExpiry`: `TransitExpiryAttested` (`CoreVaultLogic.sol:723`) | last statement | event on success path |
| 26 | CoreVaultTransit (in CoreVault) | `recognizeRefund` | `src/core/CoreVaultTransit.sol:84` | nonReentrant (permissionless) | via `CoreVaultLogic.recognizeRefund`: `TransitRefundRecognized` (`CoreVaultLogic.sol:751`) | **before** `escrow.release` (`CoreVaultLogic.sol:753`) | event on success path |
| 27 | CoreVaultTransit (in CoreVault) | `onReportAccepted` | `src/core/CoreVaultTransit.sol:95` | nonReentrant; `msg.sender == reportReceiver` in body (`:96`) | via `CoreVaultLogic.applyReport`: `ReportAccepted` (`CoreVaultLogic.sol:423`), after `TransitArrived` (`CoreVaultLogic.sol:456`, one per confirmed id), `TransitReceived` (`CoreVaultLogic.sol:523`) and `ArrivalHeldApart` (`CoreVaultLogic.sol:529`) from the return leg | `ReportAccepted` is the last statement | event on success path |
| 28 | CoreVaultTransit (in CoreVault) | `handleV3AcrossMessage` | `src/core/CoreVaultTransit.sol:110` | nonReentrant; `msg.sender == acrossSpokePool` in body (`:115`) | via `CoreVaultLogic.receiveHubBound`: `TransitReceived` (`CoreVaultLogic.sol:501` when not yet listed, `CoreVaultLogic.sol:523` when credited) and/or `ArrivalHeldApart` (`CoreVaultLogic.sol:529`); at least one for any non-zero amount | last statement of the branch | event on success path |
| 29 | CoreVaultTransit (in CoreVault) | `sweepExcess` | `src/core/CoreVaultTransit.sol:129` | nonReentrant (permissionless) | `ExcessSwept` (`:133`) | after the transfer | event when there is excess; **no event when nothing to sweep**: returns 0 at `:131` |
| 30 | CoreVaultLogic (library, public) | `recordValuation` | `src/core/CoreVaultLogic.sol:89` | none (reached from `deposit`, `requestPayout`, `claimPayout`) | `HubValuationFallback` (`:97`) / `PriceFallback` (`:100`) only on a fallback | - | conditional: no event on a normal read; the calling verbs emit their own |
| 31 | CoreVaultLogic (library, public) | `collectIncome` | `src/core/CoreVaultLogic.sol:382` | none | `CollectedIncomeReceived` (`:394`) via `_collectIncome` | before the fee transfers | event on success path |
| 32 | CoreVaultLogic (library, public) | `applyReport` | `src/core/CoreVaultLogic.sol:417` | none | `ReportAccepted` (`:423`), `TransitArrived` (`:456`), return-leg events | `ReportAccepted` last | event on success path |
| 33 | CoreVaultLogic (library, public) | `receiveHubBound` | `src/core/CoreVaultLogic.sol:489` | none | `TransitReceived` (`:501`) or, via `_creditHubBound`, `TransitReceived` (`:523`) / `ArrivalHeldApart` (`:529`) | last statement of each branch | event on success path |
| 34 | CoreVaultLogic (library, public) | `sendToSpoke` | `src/core/CoreVaultLogic.sol:576` | none | `SentToSpoke` (`:620`) | **before** the bridge CALL (`:626`) | event on success path |
| 35 | CoreVaultLogic (library, public) | `attestExpiry` | `src/core/CoreVaultLogic.sol:714` | none | `TransitExpiryAttested` (`:723`) | last statement | event on success path |
| 36 | CoreVaultLogic (library, public) | `recognizeRefund` | `src/core/CoreVaultLogic.sol:735` | none | `TransitRefundRecognized` (`:751`) | **before** `escrow.release` (`:753`) | event on success path |
| 37 | ManagerFeeVault | `withdraw` | `src/core/ManagerFeeVault.sol:38` | nonReentrant; `msg.sender == manager` in body (`:39`) | `ManagerFeeWithdrawn` (`:41`: token, to, amount) | **before** the `safeTransfer` (`:42`) | event on success path |
| 38 | ManagerRegistry | `setProtocolSliceBps` | `src/core/ManagerRegistry.sol:50` | onlyOwner | `ProtocolSliceSet` (`:55`) | last statement | event on success path |
| 39 | ManagerRegistry | `clearProtocolSliceBps` | `src/core/ManagerRegistry.sol:67` | onlyOwner | `ProtocolSliceSet` (`:71`) | last statement | event on success path |
| 40 | ManagerRegistry (inherited, OpenZeppelin Ownable2Step) | `transferOwnership` | `lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol:43` | onlyOwner | `OwnershipTransferStarted` (`Ownable2Step.sol:45`) | last statement | event on success path (not in `src/`) |
| 41 | ManagerRegistry (inherited, OpenZeppelin Ownable2Step) | `acceptOwnership` | `lib/openzeppelin-contracts/contracts/access/Ownable2Step.sol:60` | pending owner only (checked in body) | `OwnershipTransferred` (`Ownable.sol:98`, reached through `_transferOwnership`, `Ownable2Step.sol:52`) | last statement | event on success path (not in `src/`) |
| 42 | ShareToken | `mint` | `src/core/ShareToken.sol:47` | onlyCoreVault | no vault-specific event; OpenZeppelin `_mint` -> `_update` emits ERC-20 `Transfer(0, to, amount)` (`ERC20.sol:203`) | inside `_mint` | ERC-20 `Transfer` only (the Core Vault's `Deposited` is emitted in the same transaction) |
| 43 | ShareToken | `burn` | `src/core/ShareToken.sol:55` | onlyCoreVault | no vault-specific event; `_burn` emits ERC-20 `Transfer(from, 0, amount)` | inside `_burn` | ERC-20 `Transfer` only (the Core Vault's `PayoutExecuted` / `PartialPayoutExecuted` in the same transaction) |
| 44 | TransitEscrow | `initialize` | `src/core/TransitEscrow.sol:26` | none; one-shot guard `vault != address(0)` in body (`:27`) | **NO EVENT FOUND.** The body (`:26-31`) has no `emit` and calls no function. The creating verb (`CoreVaultLogic.sendToSpoke` or `SpokeCrossChainLib.sendToHub`) emits `SentToSpoke` / `SentToHub` with the escrow address in the `Transit` struct. Aderyn L-9 flags it | - | **NO EVENT FOUND** |
| 45 | TransitEscrow | `release` | `src/core/TransitEscrow.sol:34` | none; `msg.sender == vault` in body (`:35`) | **NO EVENT FOUND.** The body (`:34-38`) is `balanceOf` plus `safeTransfer`; the token emits its own `Transfer`. The calling verb emits `TransitRefundRecognized` (`CoreVaultLogic.sol:751`, `SpokeCrossChainLib.sol:86`) just before calling `release` | - | **NO EVENT FOUND** |
| 46 | Create3Deployer | `deploy` | `src/factory/Create3Deployer.sol:23` | none (permissionless, salt bound to `msg.sender`) | `Deployed` (`:25`: deployer, salt, address) | last statement | event on success path |
| 47 | FundFactory | `createFund` | `src/factory/FundFactory.sol:138` | nonReentrant; `msg.sender == m.manager` in body (`:150`) | `FundCreated` (`:180`: number, fund id, manager, mandate hash, all addresses) | last statement, after every deployment | event on success path |
| 48 | FundFactory | `createSpoke` | `src/factory/FundFactory.sol:184` | nonReentrant; `msg.sender == m.manager` in body (`:190`) | `SpokeCreated` (`:209`) | last statement | event on success path |
| 49 | ValueReportReceiver | `deliver` | `src/report/ValueReportReceiver.sol:144` | nonReentrant (permissionless; the VAA is verified inside) | `ReportAccepted` (`:191`: spoke, emitter, both sequences, block, timestamp); then the callback emits the Core Vault's own `ReportAccepted` | **before** the callback `onReportAccepted` (`:201`) | event on success path |
| 50 | SpokeCrossChainLib (library, external) | `sendToHub` | `src/spoke/SpokeCrossChainLib.sol:38` | none (reached from `SpokeVault.sendToHub`) | `ISpokeVault.SentToHub` (`:57`: transit struct, hub chain, this chain) | last statement, after the bridge call | event on success path |
| 51 | SpokeCrossChainLib (library, external) | `recognizeRefund` | `src/spoke/SpokeCrossChainLib.sol:70` | none (reached from `SpokeVault.recognizeRefund`) | `ISpokeVault.TransitRefundRecognized` (`:86`) | **before** `escrow.release` (`:88`) | event on success path |
| 52 | SpokeCrossChainLib (library, external) | `nextReport` | `src/spoke/SpokeCrossChainLib.sol:99` | none (reached from `SpokeVault.report`) | **NO EVENT FOUND** in the library. Followed: `_removeInFlight`, `_stillInFlight`, `_build`, `ReportCodec.encode`, none emits. The caller `SpokeVault.report` emits `ReportPublished` (`SpokeVault.sol:415`) after publishing | - | no event in the library; the caller emits |
| 53 | SpokeVault | `openPosition` | `src/spoke/SpokeVault.sol:249` | onlyManager, nonReentrant | `PositionOpened` (`:269`) | last statement | event on success path |
| 54 | SpokeVault | `increasePosition` | `src/spoke/SpokeVault.sol:274` | onlyManager, nonReentrant | `PositionIncreased` (`:291`) | last statement | event on success path |
| 55 | SpokeVault | `decreasePosition` | `src/spoke/SpokeVault.sol:296` | onlyManager, nonReentrant | `PositionDecreased` (`:760`, in `_exit`) | right after the adapter call, before `_credit` and `_requireBacked` | event on success path |
| 56 | SpokeVault | `closePosition` | `src/spoke/SpokeVault.sol:308` | onlyManager, nonReentrant | `PositionDecreased` (`:764`) or `PositionClosed` (`:767`), in `_exit` | right after the adapter call | event on success path |
| 57 | SpokeVault | `collectIncome` | `src/spoke/SpokeVault.sol:320` | onlyManager, nonReentrant | `IncomeCollected` (`:771`, in `_exit`) | right after the adapter call | event on success path |
| 58 | SpokeVault | `swapExactInput` | `src/spoke/SpokeVault.sol:333` | onlyManager, nonReentrant | `Swapped` (`:806`, in `_swap`: adapter, pool, tokens, amounts) | before the final `_requireBacked` | event on success path |
| 59 | SpokeVault | `swapCollectedIncome` | `src/spoke/SpokeVault.sol:350` | onlyOnSpokeChain, onlyManager, nonReentrant | `IncomeSwapped` (`:803`, in `_swap`) | before the final `_requireBacked` | event on success path |
| 60 | SpokeVault | `setOperatingCashParameters` | `src/spoke/SpokeVault.sol:368` | onlyOnSpokeChain, onlyManager | `OperatingCashParametersSet` (`:371`) | last statement | event on success path |
| 61 | SpokeVault | `sendToHub` | `src/spoke/SpokeVault.sol:382` | onlyOnSpokeChain, onlyManager, nonReentrant | `SentToHub` (`SpokeCrossChainLib.sol:57`); top-up events (`SpokeVault.sol:996-997`) | last statement of the library, after the bridge call | event on success path |
| 62 | SpokeVault | `recognizeRefund` | `src/spoke/SpokeVault.sol:395` | onlyOnSpokeChain, nonReentrant (permissionless) | `TransitRefundRecognized` (`SpokeCrossChainLib.sol:86`) | **before** `escrow.release` | event on success path |
| 63 | SpokeVault | `report` | `src/spoke/SpokeVault.sol:404` | payable, onlyOnSpokeChain, nonReentrant (permissionless) | `ReportPublished` (`:415`: sequence, Wormhole sequence, block) | last statement, after the Wormhole call | event on success path |
| 64 | SpokeVault | `handleV3AcrossMessage` | `src/spoke/SpokeVault.sol:441` | nonReentrant; `msg.sender == acrossSpokePool` in body (`:445`) | `TransitArrived` (`:467`), both kinds; top-up events may follow (`:468`) | before the final `_topUpOperatingCash` | event on success path |
| 65 | SpokeVault | `receiveFromCoreVault` | `src/spoke/SpokeVault.sol:478` | onlyOnHubChain, nonReentrant; `msg.sender == coreVault` in body (`:479`) | `ReceivedFromCoreVault` (`:483`) | last statement | event on success path |
| 66 | SpokeVault | `returnToCoreVault` | `src/spoke/SpokeVault.sol:487` | onlyOnHubChain, onlyManager, nonReentrant | `ReturnedToCoreVault` (`:491`) | last statement, after the transfer and the Core Vault call | event on success path |
| 67 | SpokeVault | `forwardIncomeToCoreVault` | `src/spoke/SpokeVault.sol:496` | onlyOnHubChain, nonReentrant (permissionless) | `IncomeForwardedToCoreVault` (`:502`) | last statement, after the transfer and the Core Vault call | event on success path |
| 68 | SpokeVault | `unwindForPayout` | `src/spoke/SpokeVault.sol:524` | onlyOnHubChain, nonReentrant; `msg.sender == coreVault` in body (`:530`) | `UnwoundForPayout` (`:546`), always, also with 0 proceeds; per-step `PositionDecreased`, `PositionClosed`, `Swapped` | last statement | event on success path |
| 69 | SpokeVault | `sweepExcess` | `src/spoke/SpokeVault.sol:556` | nonReentrant (permissionless) | `ExcessSwept` (`:562`) | after the transfer | event when there is excess; **no event when nothing to sweep**: returns 0 at `:559` |

<!-- rows: 69 (in src/: 67) -->

## 11. CI (`.github/workflows/test.yml`)

The whole workflow (read in full; it is the only file under `.github/workflows/`):

```
name: test
on: push to main; pull_request
env: FOUNDRY_PROFILE=ci
     ARBITRUM_RPC_URL  = secrets.ARBITRUM_RPC_URL  || 'https://arb1.arbitrum.io/rpc'
     ROBINHOOD_RPC_URL = secrets.ROBINHOOD_RPC_URL || 'https://rpc.mainnet.chain.robinhood.com'
job check (ubuntu-latest):
  actions/checkout@v4 (submodules: recursive)
  foundry-rs/foundry-toolchain@v1 (version: stable)
  forge fmt --check
  forge build --sizes
  forge test --no-match-path "test/fork/**" -vvv
  forge test --match-path "test/fork/**" -vvv
```

What it runs: format check, build with the size table, the unit and invariant suite under the `ci` profile (fuzz 2000 runs,
invariants 512 runs at depth 48; step 4 shows that profile passes locally), then the fork suite, all in one job and in that order.

What it does not do:

- **No static analysis.** No Slither, Aderyn, Mythril, Halmos or solhint step.
- **No coverage step and no coverage gate.** `forge coverage` is not run (and step 12 shows the default coverage compile fails with "stack too deep"
  here, so a gate would need `--ir-minimum`).
- **Toolchain not pinned.** Foundry is `version: stable` (whatever stable is on the day); solc is pinned to 0.8.28 by `foundry.toml`, and
  the two actions are pinned by major tag (`@v4`, `@v1`), not by commit.
- **Fork blocks not pinned, and not even set.** The workflow sets neither `ARBITRUM_FORK_BLOCK` nor `ROBINHOOD_FORK_BLOCK`, which 13 of
  the 14 fork test files (all but `Toolchain.t.sol`) read with `vm.envUint` (step 5), so those tests cannot start in CI as written.
- **The fork tests fall back to public RPCs.** Each URL is `secrets.X || <public endpoint>`, so a run without secrets forks the public,
  rate-limited, non-archive endpoints (`.env.example` calls them rate-limited; `docs/REVIEW-LOG-2026-09-29.md` calls them non-archive).
- No `timeout-minutes`, no `permissions:` block (default token permissions), no caching of solc or dependencies, no gas report or snapshot
  check, no `forge script` dry run of the deployment scripts (`script/` is compiled by `forge build`; parts of it run inside tests).
- The fork tests would run last, so they never run when an earlier step fails (a failed step stops the job).

Observed run history (read-only, `gh run list --repo PoolPartyLabs/smartcontract-v2`): exactly **one** run exists, run 36713951710 for
`e5c778a97c70` (push to `main`, 2026-09-30, 1 min 26 s): **conclusion `failure` at the `Format` step**, with the same two-file diff as step 3;
`Build`, `Unit tests` and `Fork tests` were skipped. There is no CI evidence yet that the build, the unit suite or the fork suite pass on this
commit; the passing results in this report are from the local runs of steps 2, 4 and 5b. Log: `raw/ci-run-36713951710-failed.log`.

## 12. Coverage (run last)

Commands (raw: `raw/coverage.txt` for the first attempt, `raw/coverage-ir-minimum.txt` for the retry, `raw/coverage-src-summary.txt`
for the parsed table):

1. `forge coverage --no-match-path "test/fork/**" --report summary` **failed** after 6 s at compile time (exit 1). Verbatim:

   ```
   Warning: optimizer settings and `viaIR` have been disabled for accurate coverage reports.
   If you encounter "stack too deep" errors, consider using `--ir-minimum` ...
   Compiling 227 files with Solc 0.8.28
   Error: Compiler run failed:
   Error: Compiler error (/solidity/libyul/backends/evm/AsmCodeGen.cpp:68):Stack too deep. Try compiling with `--via-ir` ...
   When compiling inline assembly: Variable value0 is 1 slot(s) too deep inside the stack. ...
   ```

2. Retried once, as the brief says: `forge coverage --ir-minimum --no-match-path "test/fork/**" --report summary`. It **succeeded** (exit 0):
   solc compile 201.6 s, then 53 suites, **644 passed, 0 failed, 0 skipped** in 35.9 s, 270 s wall for the command, well inside the
   25-minute box. Machine state during the retry: load average 50, swap 11.8 GB used of 12.3 GB at the start (other processes;
   the run finished normally and no throttling was observed).

Caveat printed by forge itself: "`--ir-minimum` enables `viaIR` with minimum optimization, which can result in inaccurate
source mappings". The default coverage compile (optimizer off, no viaIR) cannot build this code base (the failing contract is not
named in the error), so these are the only numbers obtainable with this tool version. The report also contains the
unrelated test-mock warning 3628 (`test/mocks/spoke/MockAcrossSpokePool.sol:11`).

### Totals

| Scope | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| **`src/` (27 files)** | **97.31% (2319/2383)** | **95.36% (2879/3019)** | **83.67% (415/496)** | **98.90% (359/363)** |
| `script/` (4 files) | 44.10% (86/195) | 43.72% (94/215) | 26.67% (4/15) | 64.71% (11/17) |
| `test/` (53 files) | 81.57% (1341/1644) | 79.19% (1286/1624) | 47.50% (95/200) | 85.57% (332/388) |
| Tool's "Total" row (all 84 files) | 88.73% (3746/4222) | 87.67% (4259/4858) | 72.29% (514/711) | 91.41% (702/768) |

`script/` per file: `CreateFund.s.sol` 0% lines (0/51), `DeployFactory.s.sol` 0% (0/17), `FactoryDeployment.sol` 48.10% (38/79),
`FundMandate.sol` 100% (48/48). Fork tests are excluded from this run.

### Per-file table for `src/`

| File | % Lines | % Statements | % Branches | % Funcs |
|---|---|---|---|---|
| src/adapters/AaveV3Adapter.sol | 97.38% (186/191) | 95.30% (223/234) | 79.07% (34/43) | 100.00% (26/26) |
| src/adapters/AcrossBridgeAdapter.sol | 100.00% (25/25) | 96.97% (32/33) | 80.00% (4/5) | 100.00% (5/5) |
| src/adapters/AdapterGuard.sol | 100.00% (15/15) | 100.00% (12/12) | 100.00% (5/5) | 100.00% (5/5) |
| src/adapters/UniswapV4Adapter.sol | 99.18% (243/245) | 98.47% (322/327) | 91.89% (34/37) | 100.00% (33/33) |
| src/core/CoreVault.sol | 98.23% (111/113) | 96.38% (133/138) | 90.32% (28/31) | 100.00% (8/8) |
| src/core/CoreVaultBase.sol | 97.87% (138/141) | 97.70% (170/174) | 87.50% (14/16) | 96.55% (28/29) |
| src/core/CoreVaultIncome.sol | 100.00% (41/41) | 92.50% (37/40) | 62.50% (5/8) | 100.00% (12/12) |
| src/core/CoreVaultLogic.sol | 96.32% (288/299) | 94.40% (388/411) | 87.88% (58/66) | 93.94% (31/33) |
| src/core/CoreVaultTransit.sol | 95.24% (40/42) | 87.50% (42/48) | 63.64% (7/11) | 100.00% (8/8) |
| src/core/ManagerFeeVault.sol | 100.00% (11/11) | 85.71% (12/14) | 33.33% (1/3) | 100.00% (3/3) |
| src/core/ManagerRegistry.sol | 100.00% (18/18) | 100.00% (18/18) | 100.00% (3/3) | 100.00% (6/6) |
| src/core/ShareToken.sol | 100.00% (19/19) | 100.00% (17/17) | 100.00% (4/4) | 100.00% (8/8) |
| src/core/TransitEscrow.sol | 100.00% (11/11) | 100.00% (14/14) | 100.00% (4/4) | 100.00% (3/3) |
| src/factory/CodeStore.sol | 89.29% (25/28) | 90.24% (37/41) | 66.67% (2/3) | 100.00% (2/2) |
| src/factory/Create3.sol | 90.00% (18/20) | 83.33% (20/24) | 60.00% (3/5) | 100.00% (5/5) |
| src/factory/Create3Deployer.sol | 100.00% (7/7) | 100.00% (6/6) | n/a (0/0) | 100.00% (3/3) |
| src/factory/FundFactory.sol | 97.26% (213/219) | 96.03% (266/277) | 78.95% (30/38) | 100.00% (24/24) |
| src/libraries/IncomeAccumulator.sol | 100.00% (91/91) | 100.00% (95/95) | 100.00% (20/20) | 100.00% (11/11) |
| src/libraries/ReportCodec.sol | 100.00% (9/9) | 100.00% (11/11) | 100.00% (2/2) | 100.00% (3/3) |
| src/libraries/ShareMath.sol | 92.31% (24/26) | 90.00% (27/30) | 100.00% (6/6) | 88.89% (8/9) |
| src/libraries/TransitMessage.sol | 100.00% (6/6) | 100.00% (7/7) | 100.00% (1/1) | 100.00% (2/2) |
| src/mandate/Mandate.sol | 100.00% (118/118) | 99.52% (206/207) | 97.44% (38/39) | 100.00% (16/16) |
| src/report/ChainlinkPriceSource.sol | 100.00% (41/41) | 87.93% (51/58) | 46.15% (6/13) | 100.00% (6/6) |
| src/report/ValueReportReceiver.sol | 100.00% (74/74) | 98.00% (98/100) | 88.24% (15/17) | 100.00% (14/14) |
| src/spoke/SpokeCrossChainLib.sol | 95.81% (160/167) | 96.04% (194/202) | 86.96% (20/23) | 100.00% (16/16) |
| src/spoke/SpokeVault.sol | 95.30% (385/404) | 91.65% (439/479) | 76.34% (71/93) | 100.00% (72/72) |
| src/spoke/SpokeVaultTypes.sol | 100.00% (2/2) | 100.00% (2/2) | n/a (0/0) | 100.00% (1/1) |
| **src/ subtotal (27 files)** | **97.31% (2319/2383)** | **95.36% (2879/3019)** | **83.67% (415/496)** | **98.90% (359/363)** |

### Files under the thresholds

- **Under 90% line coverage: 1 file.** `src/factory/CodeStore.sol` 89.29% (25/28). (`Create3.sol` is exactly 90.00%, not under.)
- **Under 80% branch coverage: 9 files**, lowest first:

| File | Branches |
|---|---|
| src/core/ManagerFeeVault.sol | 33.33% (1/3) |
| src/report/ChainlinkPriceSource.sol | 46.15% (6/13) |
| src/factory/Create3.sol | 60.00% (3/5) |
| src/core/CoreVaultIncome.sol | 62.50% (5/8) |
| src/core/CoreVaultTransit.sol | 63.64% (7/11) |
| src/factory/CodeStore.sol | 66.67% (2/3) |
| src/spoke/SpokeVault.sol | 76.34% (71/93) |
| src/factory/FundFactory.sol | 78.95% (30/38) |
| src/adapters/AaveV3Adapter.sol | 79.07% (34/43) |

`src/adapters/AcrossBridgeAdapter.sol` is at exactly 80.00% (4/5) and is not listed. Every `src/` file that has code is in
the table; the interfaces and `CoreVaultTypes.sol`/`FundTypes.sol` have no executable lines and do not appear.

## 13. Working tree at the end, deviations from the brief, raw files

### Working tree (raw: `raw/final-git-status.txt`)

`git -C REPO status --short` at the end of the run:

```
(empty)
```

No tracked file is modified, staged or untracked-and-not-ignored (`git diff --stat` is empty). `git status --short --ignored` shows only
`.env` (copied from `.env.example`, as the brief says), `cache/` and `out/` (build artifacts). `HEAD` is still
`e5c778a97c70eb07df8acbf1f1037f465a6ffb63` on branch `main`; every submodule is at the same commit as at the start. Aderyn's `report.md`
was moved out of the repository to `raw/aderyn-report.md`.

### Where this run went beyond or away from the brief

- **Step 2:** besides `forge build --sizes` (cached, prints no compiler warnings), one `forge build --force --sizes` was run to surface the solc warnings.
- **Step 4:** an extra run of the unit suite under `FOUNDRY_PROFILE=ci`, the profile the workflow uses. Effective fuzz and invariant settings printed with `forge config --json`.
- **Step 5:** the run as briefed (5a) executes 2 of 56 tests because of the empty fork-block variables; a second run (5b) with blocks 100 below the current head is reported next to it.
- **Step 5 and 2, small extras:** read-only JSON-RPC probes of the two public endpoints (`eth_blockNumber`, and `eth_getBalance` /
  `eth_getStorageAt` at `head` down to `head-5000`) and `cast block-number` to choose the pinned blocks; an extra `forge lint script/`.
- **Step 6:** Slither's own `forge clean` and `forge build --build-info ... --force` wiped and rebuilt `out/` and `cache/` (git-ignored) in the working copy.
- **Step 11:** read-only `gh run list` and `gh run view` calls to `PoolPartyLabs/smartcontract-v2` to see the CI history of this commit (no writes).
- **Step 12:** the first `forge coverage` failed at compile time ("stack too deep", 6 s); the single retry with `--ir-minimum` succeeded.
- **Machine conditions:** the machine was shared with other work (load average 30 to 170, swap 10 to 12 GB in use before this run started its heavy steps).
  Wall times in this report include that contention; the counts do not depend on it.
- Helper scripts written for this baseline live in `raw/`: `grep-inventory.py`, `test-inventory.py`, `event-scan.py`, `event-table-data.py`, `solhint.json`.
  They read the repository and write only under `raw/`.

### Raw files (`raw/`)

| File | Content |
|---|---|
| `submodules.txt` | HEAD, `git submodule status --recursive`, `.gitmodules`, `foundry.lock`, versions per submodule, `remappings.txt` |
| `build-sizes-cached.txt`, `build-sizes.txt` | `forge build --sizes` (cached) and the forced recompile with the solc warnings and the size table |
| `sizes-src-table.txt`, `sizes-src-artifacts.txt`, `build-lint-summary.txt`, `lint-script-check.txt` | sizes of `src/` contracts, every `src/` artifact with link references, the forge-lint items by rule and file, the extra `forge lint script/` check |
| `fmt.txt` | `forge fmt --check` |
| `unit-tests.txt`, `unit-tests-ci-profile.txt`, `foundry-config-effective.txt` | unit and invariant runs (default and `ci` profile), effective fuzz and invariant settings |
| `test-inventory.py`, `test-inventory.txt`, `test-marker-lines.txt` | the test inventory, its script, and the comment markers found in tests |
| `fork-tests.txt`, `fork-tests-pinned-recent.txt` | fork run as briefed and the second run with recent pinned blocks |
| `slither.txt`, `slither.json`, `slither-high-medium-list.txt` | Slither output, its JSON, the 78 High and Medium results with details |
| `aderyn-stdout.txt`, `aderyn-report.md` | Aderyn console output and its report |
| `solhint.json`, `solhint.txt`, `solhint-summary.txt` | the config created outside the repo, solhint output, counts per rule |
| `grep-inventory.py`, `grep-inventory.txt` | the grep inventory over `src/` |
| `event-scan.py`, `event-scan-auto.txt`, `event-table-data.py` | mechanical first pass and the curated data behind the step-10 table |
| `ci-run-36713951710-failed.log` | log of the failing step of the one CI run on this commit |
| `coverage.txt`, `coverage-ir-minimum.txt`, `coverage-src-summary.txt` | the failed first coverage attempt, the successful retry, the parsed `src/` table |
| `final-git-status.txt` | `git status`, `git diff --stat`, submodule status at the end |
| `parts/` | the report's sections as separate files, and `parts/04b-test-inventory-table.md`, `parts/10b-event-table.md` (generated tables) |

