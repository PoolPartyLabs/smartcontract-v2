# Dynamic and symbolic analysis, 2026-09-30

Scope: the Pool Party v2 buildathon MVP at `e5c778a` (main), reviewed with the dynamic tools: a deep fuzz and invariant
campaign over the existing suites, new whole-fund stateful invariant suites, Halmos symbolic checks of the libraries,
Medusa property fuzzing of a library model, and mutation testing of `ShareMath` and `IncomeAccumulator`. Every
command below ran on one machine under the resource limits of the campaign (at most two forge threads, one heavy
process at a time, a 6 GB memory guard, a 15-minute wall clock per command); the limits are stated where they cut a
run short.

Toolchain: forge 1.7.1 (solc 0.8.28, evm cancun, optimizer 800, `via_ir = false`), halmos 0.3.3 (yices 2.6.5 and z3
as shipped; bitwuzla 0.8.1 fetched by Halmos with `HALMOS_ALLOW_DOWNLOAD=1`), medusa 1.5.1, slither 0.11.6
(`slither-mutate`). Echidna and Gambit are not installed and were not run.

Findings are numbered `DYN-nn`; each has a proof of concept in `test/security/invariants/FundSystemPoC.t.sol` that
passes while the behaviour exists. Severity uses the campaign rubric (critical, high, medium, low, info).

## 1. Summary

| Id | Severity | Finding | Proof of concept |
|---|---|---|---|
| DYN-01 | high | An expired send home leaves every value base for the window between `fillDeadline + maxReportAge` and the recognition of its refund plus the next delivered report; Share Price drops by the whole transfer, an entrant buys at that price and leaves with the difference (DEC-085, DEC-104 broken by the OQ-09 "presumed filled" stance) | `test_POC_expiredSendHomeLeavesShareAssetsAndAnEntrantTakesTheDifference`, `test_POC_payoutDuringTheWindowIsPaidAtTheUnderstatedPrice` |
| DYN-02 | high | A send home that is filled on the hub before any report lists it, and that no report built within `fillDeadline + maxReportAge` reaches the hub for, is held in `unmatchedArrivals` for good: the fund's own USDC sits in the Core Vault outside every base, with no verb that credits or sweeps it (OQ-01 with the OQ-09 drop) | `test_POC_sendHomeFilledButNeverListedIsLostToTheFund` |
| DYN-03 | high | The manager can move all Free Idle (hub) or the whole Unallocated Balance (spoke, where a stranger's one-unit arrival triggers the top-up) into Operating Cash with one parameter change; nothing in the MVP spends or returns Operating Cash, so the shares are worth nothing while the USDC stays in the vault (DEC-096, DEC-100: the "no cap on the floor" rule creates the risk) | `test_POC_managerMovesAllFreeIdleIntoOperatingCash`, `test_POC_managerMovesAllSpokePrincipalIntoOperatingCash` |
| DYN-04 | low | With Share Assets exactly zero and shares outstanding, `claimPayout`, `requestPayout` and `deposit` all revert with `ZeroSharePrice`, against the payout liveness rule (DEC-021, DEC-056); reachable through DYN-01 (everything in flight home), DYN-03, a total loss or the CS-OQ-4 fallback | `test_POC_zeroShareAssetsRevertEveryPayoutVerb` |
| DYN-05 | info | The index remainder of a distribution is carried into the next one, so a holder who entered in between can be owed one base unit of income generated before entry (DEC-014, dust) | `test_DEC014_carriedRemainderTipsAnEntrantByOneUnit` (LibraryPropertyFuzz) |

Already known and not re-reported: the DEC-061 residual (the first mint after every share was burned prices at 1.00
and captures whatever Share Assets remain), flagged in docs/OPEN-QUESTIONS.md; Medusa finds it in five calls (§5).

## 2. Deep fuzz and invariant campaign over the existing suites

Configuration through environment variables only; fork tests excluded (`--no-match-path 'test/fork/**'`, the public
RPCs serve only recent state).

```
FOUNDRY_FUZZ_RUNS=5000 FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64 FOUNDRY_FUZZ_SEED=<seed> \
  forge test -j 2 --no-match-path 'test/fork/**'
```

| Seed | Suites | Tests | Result | Wall clock |
|---|---|---|---|---|
| `0x1` | 59 | 694 | all pass | 88 s |
| `0xdeadbeef` | 59 | 694 | all pass | 88 s |
| `0x2a2a2a2a2a` | 59 | 694 | all pass | 87 s |

Every invariant ran 256 sequences of depth 64 (16,384 calls each, zero reverts under `fail_on_revert`):
`CoreVaultInvariantTest` (7), `SpokeVaultInvariantTest` (3), `IncomeAccumulatorInvariantTest` (2),
`ShareTokenInvariantTest` (2) and the new suites of §3 (10).

Per-contract runs at 20,000 fuzz runs (`FOUNDRY_FUZZ_RUNS=20000 FOUNDRY_FUZZ_SEED=0x7 forge test -j 2
--match-contract '^<Name>$'` or `--match-path`): `ShareMathTest` (28 tests, 10 fuzz), `IncomeAccumulatorTest` (29,
8 fuzz), `ReportCodecTest`, `TransitMessageTest`, `LibraryPropertyFuzzTest` (8, 7 fuzz), `LibraryMutationKillTest`
(16, 3 fuzz), `UniswapV4AdapterAdversarial`, `ValueReportReceiverAdversarial`, `AcrossBridgeAdapter`,
`CoreVaultAdversarialRound2`, `ChainlinkPriceSourceAdversarial`: all pass.

### 2.1 Failures found and how each was decided

| Where | Counterexample | Verdict |
|---|---|---|
| `CoreVaultInvariantTest` (interrupted first run of this campaign, `FOUNDRY_INVARIANT_RUNS=1500 FOUNDRY_INVARIANT_DEPTH=120`) | five calls: every Idle unit allocated to the hub position (`allocate`), `movePrice(0)`, then `requestPayout` reverts `ZeroSharePrice`; `fail_on_revert` failed all seven invariants | Contract behaviour, not a bug of the handler's target: at a zero Share Price no share can be priced (`ShareMath.sharesToBurn`). The handler now skips the request at a zero price (`3c7aba4`). The behaviour itself is DYN-04. Not reproduced at 256 x 64 with three seeds on the unpatched handler. |
| `LibraryPropertyFuzzTest.testFuzz_DEC084_mintThenBurnAtVaultPriceNeverProfits` (development of the twin, 5,000 runs) | `(shareAssets, wholeSupply, usdcNet) = (650000000, 4e17, 24517)` | Test-harness artifact: the dilution bound of the property was too tight for a supply of 4e17 whole shares (the rounded-down price loses under one USDC base unit per 1e18 whole shares); the bound is now `wholeSupply / 1e18 + 2` and the input is a persisted regression (`cache/fuzz/failures`). |
| `LibraryPropertyFuzzTest.testFuzz_Q60_owedNeverExceedsDistributedWithAnEntrant` (20,000 runs) | `wholeShares = [200, 1e18, 1e12]`, `amounts = [5000, 2]` | Library behaviour, dust: the carried remainder of the first distribution lifts the entrant's part of the second by one base unit (DYN-05). The twin now allows one unit and `test_DEC014_carriedRemainderTipsAnEntrantByOneUnit` pins it; conservation (owed plus taken never above distributed) holds. |

## 3. Stateful invariant suites (`test/security/invariants/`)

One fund in one EVM (`FundSystemFixture`): the real `CoreVault` (linked `CoreVaultLogic`), the real `SpokeVault` in
both roles (linked `SpokeCrossChainLib`), `ShareToken`, `ManagerFeeVault`, `TransitEscrow` clones and the real
`ValueReportReceiver`, wired as the factory wires them, with mocks only at the protocol edges (Across SpokePools,
Wormhole Core, position adapters, price source, manager registry). `FundSystemHandler` drives four shareholders, the
manager and a stranger through deposits, payout requests and claims (both modes), income withdrawal, allocation to the
hub Spoke Vault and back, positions on both vaults with income, income forwarding and swaps, sends in both directions
with fills, expiries and refunds, attestations and refund recognition on both sides, report publication and delivery,
Operating Cash parameter changes, donations to every contract and escrow, forged Across arrivals on both vaults and
`sweepExcess`. Inside every action the handler asserts that a donation, a fabricated arrival or a sweep never moves
the Share Price and that a transit only moves along the edges of its state machine.

| Suite | Invariants |
|---|---|
| `CoreVaultValueInvariant.t.sol` | DEC-104 Share Assets equal the sum of their buckets (Idle, hub Spoke Vault principal, In-flight Value, spoke report less unknown-origin value); DEC-072 Payout Reserve within Idle and equal to the open requests' reserves; DEC-091 supply and balances are whole shares; DEC-004 shares only sit with depositors; DEC-107/DEC-109/Q60 fees plus holder income never exceed collected income, every collected unit is a fee that left or sits in the accumulator, the fee never exceeds the Mandate's rate; DEC-080 ledger backed by balances; no actor ends with more than they put in (live and at rest) |
| `SpokeVaultLedgerInvariant.t.sol` | DEC-080 ledger sums (Unallocated, collected income, Operating Cash) never exceed balances on either vault; the principal ledger of each vault is explained by arrivals, sends home, refunds and allocations; DEC-090/Q66/DEC-093 `cumulativeReceived`, `cumulativeSentHome` and the report sequence are exact; DEC-092 the collected income bucket is exactly what adapters paid plus stranger Income less what left; the in-flight list holds each send home once and only while Sent |
| `TransitStateMachineInvariant.t.sol` | DEC-066/DEC-085 the hub's books are the sums over its transits by state (Spoke Cap in flight, In-flight Value, return leg); no refund is recognized that Across never paid and none twice; no expiry attested before the deadline; an unfilled transit is confirmed only by a stranger who brought the whole amount; with a fresh report every transfer is in exactly one base; at rest nothing is counted twice or lost and only fabricated arrivals are held apart; a scripted walk asserts the handler exercises every path |

Results at `FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64`, three seeds: all 10 invariants pass, 16,384 calls
each, zero reverts.

### 3.1 The two liveness assumptions and the counterexamples behind DYN-01 and DYN-02

The value invariants hold only under two assumptions the handler enforces by default: every send home is listed by a
delivered report at once (`listSendsHomeAtOnce`), and an expired send home is refunded and its refund recognized on
the spoke before the next report is built (`recognizeRefundsBeforeReports`). Dropping either reproduces the findings:

```
SEC_LATE_REFUNDS=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64 FOUNDRY_FUZZ_SEED=0x1 \
  forge test -j 2 --match-path 'test/security/invariants/*Invariant.t.sol'
```

`invariant_DEC085_withAFreshReportEveryTransferIsInExactlyOneBase` fails (`176415331370 != 178969377388`, shrunk to
four calls: `strangerArrivalOnSpoke`, `deposit`, `sendHome(5, Principal, ...)`, `payout` whose Standard term warps
past `fillDeadline + maxReportAge`): the spoke dropped the unfilled send home from `inFlightToHub`, so 2,554 USDC of
principal sit in no base (DYN-01). The scripted walk also fails under this flag because no refund is ever recognized
on the spoke; that is the flag, not a defect.

```
SEC_UNLISTED_SENDS_HOME=true FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=64 FOUNDRY_FUZZ_SEED=0x1 \
  forge test -j 2 --match-path 'test/security/invariants/*Invariant.t.sol'
```

`invariant_DEC104_atRestNothingIsCountedTwiceOrLost` fails ("OQ-01: only fabricated arrivals are held apart:
4516134883 != 4516127364", shrunk to `strangerArrivalOnSpoke(Income)`, `sendHome(100, Income, ...)`, `fillOnHub`,
`warp`): a send home filled before any report listed it stays in `unmatchedArrivals` once the spoke stops listing it
(DYN-02). Under the same flag `invariant_DEC107_feesPlusHolderIncomeNeverExceedCollectedIncome` reports
`9743887008 != 9743886910` (98 units): a handler artifact of the exploratory mode, not a contract defect. The handler
books an Income arrival's gross at the fill; when the fill precedes the listing the Core Vault credits it later, in
`_matchReturnLeg` of the report that lists it (`CoreVaultLogic.sol:463`), and the ghost misses that late credit. The
scripted walk's failure under this flag is the same artifact.

## 4. Symbolic checks with Halmos (`test/security/symbolic/`)

Halmos runs from a sandbox project holding only `src/libraries`, `src/interfaces/FundTypes.sol` and the three test
files (the full tree has 26 test suites Halmos would otherwise load): copy `foundry.toml`, `remappings.txt`, the
`lib` symlink and those files into a directory and run there. One contract and one property at a time:

```
halmos --match-contract '^<Contract>$' --match-test '^<check_name>\(' --solver-threads 1 \
  --solver-timeout-assertion 60000 --solver-max-memory 3000 --loop 3 --no-status --statistics [--solver bitwuzla]
```

Memory guard 6 GB over the process tree, wall clock per property as stated. `--solver-max-memory` is not honoured by
yices or z3 in this version (both grew past 6 GB within 10 to 26 seconds on the 512-bit `mulDiv` queries and were
killed by the guard). Non-vacuity was checked by mutating the sandbox copies of the libraries (encode with two fields
swapped; checkpoint that does not move the holder's index): `check_DEC090_transitMessageRoundTrip`,
`check_DEC014_newHolderOwesNothingOfPriorIncome` and `check_Q60_checkpointCreditsOnceAndExactly` then fail with a
counterexample.

### 4.1 `IncomeAccumulatorSymbolicTest`

| Property | Solver | Result |
|---|---|---|
| `check_DEC014_newHolderOwesNothingOfPriorIncome` | yices | PASS (6 paths, 0.05 s) |
| `check_Q60_checkpointCreditsOnceAndExactly` | yices | PASS (21 paths, 0.21 s) |
| `check_LC100_takeOwedConserves` | yices | PASS (8 paths, 0.06 s) |
| `check_Q60_advanceSourceIsMonotonic` | yices | PASS (5 paths, 0.05 s) |
| `check_Q60_distributeBooksExactlyOnce` | yices | PASS (31 paths, 0.35 s) |
| `check_Q60_remainderStaysBelowSupply` | yices, z3 | aborted by the memory guard (6.0 GB after 10 s; 6.7 GB after 26 s) |
| `check_Q60_remainderStaysBelowSupply` | bitwuzla | PASS (19 paths, 2.7 s) |
| `check_Q60_twoHoldersNeverOwedMoreThanDistributed` | yices | no verdict within a 131 s wall clock (killed) |
| `check_Q60_twoHoldersNeverOwedMoreThanDistributed` | z3 | aborted by the memory guard (6.2 GB after 10 s) |
| `check_Q60_twoHoldersNeverOwedMoreThanDistributed` | bitwuzla, 30 s per assertion | TIMEOUT (71 paths, every assertion query timed out, 123 s) |

### 4.2 `ShareMathSymbolicTest`

| Property | Solver | Result |
|---|---|---|
| `check_DEC110_flowFeeAtTheDefaultRateIsWithinTheCap` | yices | PASS (7 paths, 0.26 s) |
| `check_DEC110_flowFeeAboveCapAlwaysReverts` | yices | PASS |
| `check_DEC102_bpsOfAboveOneHundredPercentReverts` | yices | PASS |
| `check_DEC061_noSharesMeansTheInitialPrice` | yices | PASS |
| `check_DEC035_zeroSharePriceNeverPricesAShare` | yices | PASS |
| `check_DEC091_isWholeSharesIsTheModulo` | yices | PASS |
| `check_DEC091_fractionalSharesNeverPriced` | yices | PASS |
| `check_DEC035_mintIsWholeAndNeverOvercharges` | yices | no verdict within a 131 s wall clock (killed) |
| `check_DEC035_mintIsWholeAndNeverOvercharges` | bitwuzla, 60 s per assertion | TIMEOUT (15 paths, six assertion queries, 360 s, peak 5.7 GB) |
| `check_DEC077_burnIsWholeAndNeverPaysAboveRequest` | yices | no verdict within 131 s (killed) |
| `check_DEC077_burnIsWholeAndNeverPaysAboveRequest` | bitwuzla, 30 s | TIMEOUT (15 paths, 180 s, peak 4.1 GB) |
| `check_DEC077_mintThenBurnAtOnePriceNeverProfits` | yices | no verdict within 131 s (killed) |
| `check_DEC077_mintThenBurnAtOnePriceNeverProfits` | bitwuzla, 30 s | no verdict within a 571 s wall clock (killed) |
| `check_DEC077_mintThenBurnAtOnePriceNeverProfits` | bitwuzla, 10 s | TIMEOUT (75 paths, 277 s) |
| `check_DEC084_mintThenBurnAtVaultPriceNeverProfits` | yices | no verdict within 131 s (killed) |
| `check_DEC084_mintThenBurnAtVaultPriceNeverProfits` | bitwuzla, 10 s | no verdict within a 281 s wall clock (killed) |
| `check_DEC061_usdcForMonotonicInShares` | bitwuzla, 30 s | TIMEOUT (17 paths, 121 s) |
| `check_DEC061_usdcForMonotonicInPrice` | bitwuzla, 30 s | TIMEOUT (13 paths, 121 s) |
| `check_DEC084_supplyValueNeverExceedsShareAssets` | bitwuzla, 30 s | TIMEOUT (14 paths, 120 s, peak 2.9 GB) |
| `check_DEC110_flowFeeAtMostOnePercent` | bitwuzla, 30 s | TIMEOUT (8 paths, 48 s) |
| `check_DEC106_previewDepositNeverChargesAboveAmount` | bitwuzla, 30 s | TIMEOUT (41 paths, 256 s, peak 4.5 GB) |

Reading: every property that routes two symbolic operands through `Math.mulDiv` (256-bit product, 512-bit branch to
rule out, division by a symbolic or 1e36 denominator) is undecided by all three solvers within the limits. No
counterexample was produced by any of them. These nine properties are covered over the whole realistic domain by
their fuzz twins in `test/security/invariants/LibraryPropertyFuzz.t.sol` (20,000 runs, §2) and by the unit fuzz
suites; the seven light properties (fee at the rates in use, every revert condition, initial price, whole-share test)
are proved.

### 4.3 `CodecSymbolicTest`

| Property | Solver | Result |
|---|---|---|
| `check_DEC090_transitMessageRoundTrip` | yices | PASS (3 paths) |
| `check_DEC090_transitMessageNeverCollides` | yices | PASS (32 paths, 0.08 s) |
| `check_DEC090_transitMessageRejectsOtherVersions` | yices | PASS |
| `check_DEC092_transitMessageRejectsUnknownKind` | yices | PASS |
| `check_DEC093_reportRoundTrip` (every scalar symbolic, one symbolic entry per list) | yices | PASS (10 paths, 0.05 s) |
| `check_DEC093_emptyReportRoundTrip` | yices | PASS (3 paths) |
| `check_Q57_reportRejectsOtherVersions` | yices | PASS (2 paths) |
| `check_Q57_reportRejectsShortPayload` | yices | PASS (2 paths) |

`decode(encode(x)) == x` for symbolic `x` also proves that two distinct inputs never share an encoding (a collision
would decode to two values); `check_DEC090_transitMessageNeverCollides` states it directly for the transit message.

## 5. Property fuzzing with Medusa (`test/security/medusa/`)

`LibraryPropertiesMedusa.sol` is a model fund with no tokens: four holders deposit, take payouts and withdraw income
against one Share Assets number that only losses lower, composed from `ShareMath` and `IncomeAccumulator` the way the
Core Vault composes them; `property_` functions are checked after every call and the actions carry `assert`s. Run from
a sandbox holding `src/libraries`, `src/interfaces/FundTypes.sol` and the harness (Medusa compiles the whole target
with crytic-compile):

```
medusa fuzz --config test/security/medusa/medusa.json --workers 2 --test-limit 50000 --timeout 480
```

Result: 18 tests pass (4 property tests, 14 assertion targets), 72,287 calls in 6 s (the limit stops the run after
50,000 calls per worker batch), 347 branches covered, no failure. Echidna is not installed and was not run.

Known behaviour reproduced by design: with the `firstMint` guard removed from `deposit`, Medusa finds the DEC-061
residual in five calls (`deposit(251, ...)`, `lose`, `lose`, `payout(119, ...)` burning every share,
`deposit(0, ...)`): the first mint after every share was burned prices at 1.00 and the Share Price rises above the
price before the call. This is the residual docs/OPEN-QUESTIONS.md flags for a ruling, not a new finding.

## 6. Mutation testing (`slither-mutate`, `ShareMath` and `IncomeAccumulator`)

Sandbox: `src/libraries`, `src/interfaces/FundTypes.sol`, the four library unit suites, `LibraryPropertyFuzz.t.sol`
and `LibraryMutationKill.t.sol`. Mutants were enumerated with a no-op test command, then a selection of at most 60
per library (the campaign's limit) was run one after the other against `FOUNDRY_FUZZ_RUNS=256 forge test -j 2`,
first without `test/security/mutation/` (baseline) and then with it.

```
slither-mutate . --test-cmd "true" --contract-names ShareMath --comprehensive --output-dir enum_ShareMath
slither-mutate . --test-cmd "true" --contract-names IncomeAccumulator --comprehensive --output-dir enum_IncomeAccumulator
```

Enumerated: `ShareMath` 107 mutants (AOR 24, ROR 30, SBR 6, MIA 18, CR 17, RR 12); `IncomeAccumulator` 363 (AOR 52,
ASOR 60, ROR 65, MIA 56, SBR 12, BOR 4, MVIE 8, UOR 3, MWA 1, CR 51, RR 51).

### 6.1 `ShareMath`: all 60 AOR, ROR and SBR mutants

Baseline: 45 caught, 15 survived. With `LibraryMutationKillTest`: 5 more caught, 10 survive, all equivalent.

| Mutant | Line | Change | Baseline | With kill tests |
|---|---|---|---|---|
| AOR_4..7 | 51 | `shares % WHOLE_SHARE` to `+`, `/`, `*`, `-` (`isWholeShares` had no test) | survived | killed by `test_DEC091_isWholeSharesAcceptsOnlyMultiplesOf1e18`, `testFuzz_DEC091_isWholeSharesMatchesModulo` |
| ROR_22 | 95 | `bps > BPS` to `bps >= BPS` | survived | killed by `test_DEC102_bpsOfAcceptsExactlyOneHundredPercent` |
| ROR_1 | 56 | `!= 0` to `> 0` | survived | equivalent (unsigned) |
| ROR_7, ROR_12, ROR_17 | 64, 72, 89 | `== 0` to `<= 0` | survived | equivalent (unsigned) |
| SBR_0..5 | 17, 20, 26, 29, 32, 35 | constant type narrowed (`uint256` to `uint128`, `uint16` to `uint8`), values unchanged | survived | equivalent: every value fits the narrower type and every use widens it back to `uint256` |

### 6.2 `IncomeAccumulator`: 60 selected mutants

Selection: every arithmetic and assignment operator of `advanceSource`, `distribute`, `checkpoint`, `owed` and
`takeOwed` (AOR 12, ASOR 13), the guards of every `if` (MIA 20, ROR 8), the `Q128`, `MAX_STEP` and `mulmod`
constants and the `memory`-for-`storage` swaps (BOR 1, SBR 5), the loop step (UOR 1). Baseline: 47 caught, 13
survived. With `LibraryMutationKillTest`: 10 more caught, 3 survive, all equivalent.

| Mutant | Line | Change | Baseline | With kill tests |
|---|---|---|---|---|
| ASOR_31, 32, 33 | 247 | `h.owed +=` to `=`, `\|=`, `^=` | survived | killed by `test_DEC014_checkpointAccumulatesOwedAcrossCheckpoints`, `testFuzz_DEC014_checkpointAddsExactlyThePendingIncome` |
| ASOR_51, 52, 53 | 269 | `taken +=` to `=`, `\|=`, `^=` | survived | killed by `test_LC100_takenIsARunningTotal` |
| MIA_15 | 155 | `if (delta == 0) return 0` never taken (an empty `IncomeRecognized` is emitted) | survived | killed by `test_Q60_zeroDeltaAndZeroAmountEmitNothing` |
| ROR_6 | 149 | `cumulativeReported < previous` to `<=` (an unchanged counter is flagged as regressed) | survived | killed by `test_Q60_unchangedCounterIsNotARegression` |
| MIA_37 | 211 | `if (ok)` to `if (true)` (an overflowing increment is retried and truncated) | survived | killed by `test_Q60_overflowingIncrementIsSkippedNotTruncated` |
| SBR_11 | 274 | uncapped `takeOwed` capped at `uint128` max | survived | killed by `test_LC100_uncappedTakeTakesEverythingOwed` |
| MIA_31 | 201 | `if (ok)` to `if (true)` | survived | equivalent: the first `tryAdd` can only overflow with `totalShares == 1`, where `fresh == 0` and `carried == 0`, so the carry branch inside the block never fires and `ok` stays false |
| MIA_46 | 246 | `if (index == last) continue` never taken | survived | equivalent: with `index == last` the credit is `mulDiv(shares, 0, Q128) == 0` and the checkpoint is rewritten with its own value (gas only) |
| MIA_54 | 267 | `if (amount == 0) return 0` never taken | survived | equivalent: `owed -= 0`, `taken += 0` (gas only) |

RR, CR and the remaining MIA, AOR, ASOR and ROR mutants were not run in this pass (limit of 60 per library). The
kill-test NatSpec entries that name RR and CR mutants (`ShareMath.sol:51`, the accumulator's five event sites) come
from the earlier, interrupted campaign and were not re-verified here.

## 7. Findings

### DYN-01 (high): an expired send home leaves every base until its refund is recognized and reported

`SpokeCrossChainLib._stillInFlight` (`src/spoke/SpokeCrossChainLib.sol:300`) keeps a hub-bound transit in
`inFlightToHub` only while `state == Sent && block.timestamp <= fillDeadline + maxReportAge`; `nextReport` drops it
afterwards ("presumed filled", OQ-09). On the hub, In-flight Value is the report's `inFlightToHub` list
(`CoreVaultLogic`), so a send home no relayer filled leaves Share Assets at the first report built after
`fillDeadline + maxReportAge`, while its USDG sits with Across or in its `TransitEscrow` until someone calls
`recognizeRefund` on the spoke and a later report is delivered. Across pays refunds of expired deposits in a later
root bundle (typically hours after expiry), well after `maxReportAge` (about 26 minutes), so the window opens on
every unfilled send home. The manager alone can open it (a quote with no relayer fee is never filled; `maxBridgeFeeBps`
bounds the fee from above only); a route outage opens it for an honest fund.

PoC: 100,000 USDC fund, 50,000 on the spoke, sent home unfilled. After the window opens Share Assets read 49,999 USDC
for 99,999 shares; an entrant deposits 50,000 USDC and receives about 99,999 shares; the refund is recognized, a
report delivered, and the entrant leaves through an Instant Payout with more than 22,000 USDC above the deposit after
the 2% Payout Fee and the flow fee; the prior holder's 99,999 USDC are worth under 76,000. The second PoC shows a
leaver paid about half of the shares' value during the window. DEC-104 ("no recognized value is outside all bases")
and DEC-085 are broken for the length of the window.

Suggested fix: keep an unfilled send home in flight until its refund is recognized (the earlier "until the hub
confirms" wording of OQ-09), or let the hub keep counting a hub-bound transit it has not credited as In-flight Value
until either the arrival is credited or the refund is recognized on the spoke and reported; at minimum block mints
while any hub-bound transit is past its deadline and neither credited nor refunded.

### DYN-02 (high): a send home filled before any report lists it can be held apart for good

`CoreVaultLogic.receiveHubBound` (`src/core/CoreVaultLogic.sol:489`) holds an arrival whose id no accepted report
has listed in `unmatchedArrivals`, and `_matchReturnLeg` (`:463`) credits it only when a report lists the id. The
spoke lists a send home only while `_stillInFlight` holds (DYN-01), so an arrival filled within minutes (the usual
Across latency) waits for a report built inside `fillDeadline + maxReportAge` and delivered within `maxReportAge` of
its timestamp (`ValueReportReceiver`). If no such report reaches the hub (keeper outage, guardian pause, sequencer or
L1 finality incident, reports that keep ageing out at delivery), no later report lists the id and the USDC stays in the
Core Vault outside every base: `sweepExcess` returns 0 (it is ledger value), `recognizeRefund` reverts (nothing was
refunded), reports 30 days later change nothing. PoC: 49,900 USDC of a 100,000 USDC fund lost this way.

Suggested fix: never drop a hub-bound transit from the report on a timer (list it until the hub acknowledges it, or
until its refund is recognized), and add a recovery verb for `unmatchedArrivals` keyed by a later listing or by the
manager with a delay, so a liveness lapse costs time, not principal.

### DYN-03 (high): the manager can move all principal into Operating Cash, which nothing pays out in the MVP

`setOperatingCashParameters(floor, topUp)` has no cap on either value (DEC-096: floor configurable by the manager;
DEC-100: no protocol cap on the floor), and the top-up takes `min(topUp, Free Idle)` on the next operation
(`CoreVaultBase`) or `min(topUp, Unallocated Balance)` on the spoke, where an arrival triggers it, so a stranger's
one-unit Across deposit completes the move after the manager's parameter change. Operating Cash is outside Share
Assets and no MVP verb spends, returns or distributes it (spending is OPEN, doc 30; the DEC-096 distribution at fund
close has no verb yet). PoC: after `setOperatingCashParameters(max, idle - 1)` and `allocateToHubSpokeVault(1)`,
Share Assets are 1 base unit, a payout burns all 99,999 shares for 0 USDC while 99,999 USDC stay in the vault; on the
spoke, half of the fund leaves Share Assets on one forged one-unit arrival. The rule itself creates the risk: DEC-100
accepts the Share Price effect of a floor sized for gas (about 1 to 10 USD), not an unbounded one.

Suggested fix: a protocol cap on floor and top-up (absolute, or a small share of Share Assets), a cooldown or timelock
on the parameter change, and a verb that returns Operating Cash above the floor to Idle.

### DYN-04 (low): every payout verb reverts at a zero Share Price with shares outstanding

`ShareMath.sharesToBurn` and `sharesForDeposit` revert `ZeroSharePrice` when Share Assets are zero and shares exist,
so `claimPayout`, `requestPayout` and `deposit` revert (PoC). DEC-021 and DEC-056 say a claim never reverts because
of a valuation. At exactly zero there is nothing to pay from Share Assets, so the loss is liveness only: an open
request cannot be closed, and the fund cannot restart through a deposit until value returns. Reachable through DYN-01
(the whole fund sent home and unfilled), DYN-03, a total loss in a position, or the CS-OQ-4 fallback that values a
never-priced token at 0. Suggested: let a claim at a zero price close the request with nothing burned (as
`closedBelowOneShare` does), and let a deposit at zero price with shares outstanding revert with a dedicated error.

### DYN-05 (info): a carried remainder tips an entrant's income by one base unit

`IncomeAccumulator.distribute` carries the division remainder of a distribution into the next one, divided over the
supply of that moment; a holder who entered in between can be owed one base unit of the earlier income
(`test_DEC014_carriedRemainderTipsAnEntrantByOneUnit`: 200 and 1e12 whole shares hold, 5,000 units are distributed,
1e12 whole shares enter, 2 units are distributed, the entrant is owed 1 instead of 0). Conservation holds. Dust-level
DEC-014 deviation; no change suggested beyond the NatSpec.

## 8. Tools

| Tool | Version | Ran | Note |
|---|---|---|---|
| forge test (fuzz, invariant) | 1.7.1 | yes | §2, §3 |
| halmos | 0.3.3 (yices 2.6.5, z3, bitwuzla 0.8.1) | yes | §4; nine `ShareMath` properties and one accumulator property undecided (timeouts or memory) |
| medusa | 1.5.1 | yes | §5 |
| echidna | not installed | no | not run |
| slither-mutate | 0.11.6 | yes | §6, 60 mutants per library |
| gambit | not installed | no | not run |
| mythril | not run | no | excluded by the campaign's limits |
