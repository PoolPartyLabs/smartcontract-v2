# Cross-check of the independent review and the verification plan (2026-10-01)

On 2026-09-30 two documents were produced outside this repository against commit `e5c778a`, the main branch before
the security sweep landed: an independent review with 121 proof-of-concept tests
([`independent-review-2026-09-30/`](independent-review-2026-09-30/)) and a test and formal verification plan
([`verification-plan-2026-09-30/`](verification-plan-2026-09-30/), status in [`VERIFICATION-PLAN.md`](VERIFICATION-PLAN.md)).
This page records how every finding of both stands against `main` (the security sweep, `85d48bd`) and against the
cross-check branch `fix/pp-sc-fix-independent-review`, with the evidence. The contracts remain **not audited by a third
party**.

## 1. Method and result

- Every proof of concept of the review was copied into `test/review/<group>/` and run against the current code, then
  re-attacked with the variants a real attacker would try against each new guard. A test that no longer shows the
  defect was rewritten to assert the corrected behaviour (`test_REVIEW_<id>_*`); a defect that still shows is pinned
  with its numbers (`test_POC_REVIEW_<id>_*`). Groups `core-a`, `core-b`, `factory`, `spoke-a`, `spoke-b` were ported
  onto `main` and their pins flipped as the fixes landed; `adapters`, `integration-price` and `integration-xchain`
  were ported onto the fix branch.
- The verification plan's 33 candidate defects were reproduced on the plan's own description or checked by reading the
  current code; each fix carries a test that failed on `main` first.
- Fixes needing no product ruling were made on the fix branch, one commit each with its regression test. Questions that
  are the founder's are in `docs/OPEN-QUESTIONS.md` (SEC-OQ-7 to SEC-OQ-14) and [`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md).

Result: of the review's 2 critical and 8 high findings, the sweep had fixed all but H-08 (Operating Cash, interim) and
the dust-positions half of H-04; the fix branch closes H-04. Porting H-02 found a **new high-severity defect in the
sweep's own S-4 fix** (a pre-seeded or outage-delayed recovery counted a transfer twice; a claimant was overpaid 49,850
USDC on a 1M fund), fixed on the branch. Twelve further items are fixed on the branch (section 4).

## 2. The review's findings

"Main" is the state after the security sweep; "branch" adds the cross-check fixes. Evidence names the ported tests.

| Id | Finding (short) | Main | Branch | Evidence |
|---|---|---|---|---|
| C-01 | Unwind valued, sized and sold at spot: a shareholder takes the fund's V4 positions | Fixed (S-2): a crushed spot makes the unwind revert, the claim is paid from Idle | Unchanged; the 5% band is SEC-OQ-12 | `test_REVIEW_C01_crushedSpotUnwindRevertsAndTheClaimIsPaidFromIdleOnly`; fork: attacker +189,994 on `e5c778a`, −626 now (`C01_UnwindAtManipulatedSpotFork`); residual inside the band: see §5 |
| C-02 | Share Price counts V4 principal at the spot composition | Fixed (S-1) | Unchanged | `test_REVIEW_C02_*` (3): Share Assets 997,496.999987 at six pushes; a claim and a sandwiched deposit get the fair shares |
| H-01 | Unfilled transfer home in no value base until its refund is reported | Fixed (S-3) | Unchanged | `test_REVIEW_H01_*` (2); residual pinned: a refund after the 3-day retention reopens the gap until `recognizeRefund` |
| H-02 | Filled transfer home lost when no report lists it in time | Fixed (S-4), but the fix itself had a defect (S-45) | Fixed again: recovery needs a report built after the last arrival | `test_REVIEW_H02_*` (3), `test_REVIEW_NEW_S04_*` (3); residual: an entrant between that report's delivery and the recovery call |
| H-03 | Spoke Cap stops counting a transit that arrived after a time-only expiry | Fixed (S-13) | Unchanged | `test_REVIEW_H03_*` (3), including the re-attack that releasing a held cap costs the whole amount sent |
| H-04 | The manager can make every report undeliverable | Half fixed (S-11, sends home); dust positions still froze delivery (200 positions: 35.98M gas) | Fixed: at most 16 open positions; the worst report under both caps (256 arrivals, 64 Income sends home filled before their listing, 16 positions) delivers in 26.87M gas through the real Wormhole Cores | `test_REVIEW_H04_*` (unit and real Cores), `test_REVIEW_S11_sendsHomeAreCappedAtSixtyFour`; on `e5c778a` 160 positions needed 35.31M |
| H-05 | The hub sends capital to a Spoke Vault that nothing shows exists | Fixed (S-14) | Unchanged | `test_REVIEW_H05_*` (3), including a report from another emitter chain that cannot open the gate |
| H-06 | A spoke built from another Mandate is accepted end to end | Fixed (S-6, S-9) | Unchanged | `test_REVIEW_H06_*` (3) |
| H-07 | Deprecating the V4 adapter blocks the unwind and strands WETH | Fixed (S-10) | Unchanged; the guardian's holder is SEC-OQ-8 | `test_REVIEW_H07_*` (3) |
| H-08 | Operating Cash: unbounded parameters, no outflow | Interim (S-5): `releaseOperatingCash` reverses it | Unchanged; the cap is the founder's (SEC-OQ-2) | `test_POC_REVIEW_H08_*` pins, `test_REVIEW_H08/S5_*` |
| M-01 | Bridge fee becomes manager revenue through the exclusive relayer; the Mandate accepted 100% | Fixed (S-9) | Unchanged | `test_REVIEW_M01_*` (2); residual pinned: an over-quote at the 1% cap is paid to the fastest relayer |
| M-02 | Principal becomes performance-fee income through the fund's own range; a pool's fee was unbounded | Open | Fixed in part: a hookless pool above a 1% LP fee is refused; gross versus net is SEC-OQ-7 | `test_REVIEW_M02_constructorRejectsAPoolFeeAboveOnePercent`; wash-trade numbers: §5 |
| M-03 | A Mandate token the price source cannot price | Open (S-16, acknowledged) | Hub half fixed (refused at creation); spoke half is SEC-OQ-9 | `test_REVIEW_M03_hubPoolTokenWithoutAPriceIsRefusedAtCreation`; `test_POC_REVIEW_M03_*` (spoke) |
| M-04 | Report lifetime and Wormhole chain id unchecked | Self-DoS only since S-14 (never funded) | Upper bound added (one day); the lower bound needs the DEC-089 registry | `test_REVIEW_M04_*` (3) |
| M-05 | A shortened Across buffer stops every route | Fixed (S-23) | Unchanged | sweep regression |
| L-01 | Payout Fee plus flow fee above 100% | Fixed (S-17) | Unchanged | `test_REVIEW_L01_*` (2) |
| L-02 | Pushes to addresses that may refuse | Fees fixed (S-12) | Income on a full exit fixed too (owed to the holder) | `test_REVIEW_CF2_incomeTokenThatRefusesTheHolderNeverBlocksTheExit` |
| L-03 | A spoke that never reported is never stale | Unreachable since S-14 | Unchanged | |
| L-04 | Valuation reads every position; a claimant could starve the wrapped read | Measured: starving the hub read needs a `buildReport` above about 9.6M gas | Bounded: 16 positions per Spoke Vault; a claim reading the largest report the caps allow costs 2.54M | `GasFallbackMeasure`, `Measure_SteadyStateReadVsWrite` |
| L-05 | The unwind cannot reach everything | Open | Single-asset non-USDC step fixed (T14); non-USDC Unallocated Balance and the roll-back of a failing step remain (DEC-069) | `test_REVIEW_L05_singleAssetWethStepUnwindsThroughTheHintedRoute`; `test_POC_REVIEW_L05_*` pins |
| L-06 | `buildReport` readable mid-verb (read-only reentrancy) | Unreachable with USDC, WETH and hookless pools | Acknowledged | review report 04 |
| L-07 | Income attribution timing (just-in-time entrant) | Open (S-15) | Unchanged | `test_POC_REVIEW_L07_*` |
| L-08 | Aave: foreign aTokens revert a fallback full exit | Open | Fixed: a one-unit rounding over-burn empties the ledger | `test_REVIEW_F1_*` (2), failing on main with `LedgerUnderflow(90909091, 90909090)` |
| L-09 | Spoke books the adapter's fill deadline unchecked | Open | Fixed (parity with the Core Vault) | `test_REVIEW_L09_builtFillDeadlineNotInTheFutureReverts` |
| L-10 | Large Mandates: `createFund` above 32M gas, then above EIP-3860 | Open | Acknowledged; the wall is at 59 extra hub pools or fewer as the Core Vault grows | `test_POC_REVIEW_L10_*` |
| L-11 | Hub Across callback credits without a backing check | Fixed (S-20) | Unchanged | sweep regression |
| L-12 | No upper bound on the Standard term | Open | SEC-OQ-11 | |
| I-01 | NatSpec and documents that drifted | Partly | Corrected (Core Vault base, `claimPayout`, `deposit`, CS-OQ-6, S-3 sweep) | |
| I-02 | Events lack content a server needs (minimums, reference prices, exclusivity, proof path) | Open | Acknowledged; every operation does emit an event (API probe) | plan ruling R-14 |
| I-03 | The arrival window never drains | Acknowledged (S-30) | Unchanged | `test_POC_REVIEW_I03_*` |
| I-04 | Clock-skew assumptions | Documented (CS-OQ-5) | The S-4 recovery margin uses the same bound | |
| I-05 | The stored Mandate keeps the old performance fee | Open | Documented on `mandate()` | |
| I-06 | Dead code | Acknowledged (S-43, S-44) | Unchanged | |
| I-07 | Cap units and 6-decimal assumptions | Acknowledged (S-24) | Unchanged | |
| I-08 | Every listed WETH/USDC V4 pool is thin | Acknowledged (S-32) | Measured: 34.5 WETH moves the Arbitrum pool 10% | `test_REVIEW_I08_measure_probeDepth` |
| I-09 | Script defaults (`.env.example`, ETH / USD age) | Open | `.env.example` lists every variable; the price age is SEC-OQ-13 | |
| I-10 | Factory deployment trusts the operator | Acknowledged (S-37) | The deployment script now checks code presence and the V4 wiring (plan F-12) | `test/fork/factory/FactoryWiringCheckFork.t.sol` |
| I-11 | Token behaviours assumed away | Acknowledged | An income token that refuses a holder no longer blocks the exit | |
| I-12 | Protocol incentives have no claim path | Acknowledged | Unchanged | |
| I-13 | V4 position key read before token calls | Unreachable with USDC, WETH and USDG | Acknowledged | |
| I-14 | Gross Assets, first-deposit minimum, `lastHubValue` refresh | Acknowledged | Unchanged | |
| I-15 | An arrival's Operating Cash top-up counted twice until the next report | Open | See the conservation walk, §5 | |
| I-16 | Documented Robinhood refund delay too short | Open | `docs/DECISIONS.md` carries the measured 53 to 107 min | |
| I-17 | DEC-104 assertions cannot fail on cross-chain defects | Open | Documented in [`INVARIANTS.md`](INVARIANTS.md); the review's conservation walk is ported | |

Process findings: CI had never passed (unpinned forge, fork blocks unset) and is fixed; Foundry is pinned; `foundry.lock`
lists `v4-periphery`; static analysis and coverage are not in CI yet (checklist).

## 3. The verification plan's candidate defects (master plan §8.4) and rulings (§10.3)

| Id | Defect | Status | Where |
|---|---|---|---|
| CF-1, MM-2 | Instant claim panics when `payoutFeeBps + flowFeeBps > 10,000` | Fixed | S-17 |
| CF-2, MM-9 | A paused income token reverts every full-burn claim | Fixed on the branch | `CoreVaultIncome._payAllIncome` |
| CF-3, SF-2 | A recipient that cannot receive stops payouts, deposits, collections, delivery | Fixed | S-12 |
| CF-5, AB-12 | Unbacked hub Across callback | Fixed | S-20 |
| CF-12 | A garbage-high price answer pays out | Open | SEC-OQ-10 (bands) |
| CF-13 | Unlisted return leg stranded | Fixed | S-4, corrected by S-45 |
| CF-14 | Two full-cap sends after a time-only expiry | Fixed | S-13 |
| T13 | `buildReport` gas grows with dust sends | Fixed | S-11 |
| T14 | A single-asset non-USDC step reverts every unwind | Fixed on the branch | `SpokeVault._unwindRoute` |
| SF-1 | Codeless or malformed registry | Fixed on the branch (deployment script) | `FactoryDeployment._checkWiring` |
| SF-8 | Clone of a codeless escrow implementation | Not applicable | the factory deploys its own `TransitEscrow` implementation |
| CF-R2 | Answer `2^200` panics a payout | Fixed on the branch | `ChainlinkPriceSource.MAX_PRICE` |
| CF-R3 | Feed decimals switched misprice silently | Fixed on the branch | decimals checked on every read |
| CF-R4 | A full arrival window makes deliveries expensive | Acknowledged | S-30 |
| CF-V4-1 | An approve-hook token desynchronises the position key | Acknowledged (unreachable with the MVP tokens) | SEC-OQ-9 (token lists) |
| CF-V4-3 | An uninitialized registered pool quotes 0 or panics | Acknowledged (the unwind reverts, the claim is paid from Idle) | |
| CF-V4-10 | A PoolManager of another deployment | Fixed on the branch (deployment script) | `FactoryDeployment._checkWiring` |
| CF-V4-11 | A transfer fee switched on after open blocks every exit of that pool | Acknowledged (fails closed, liveness) | |
| F1 | Donated aTokens revert an Aave close | Fixed on the branch | `AaveV3Adapter._withdraw` |
| F2, F9, F10, F11 | Aave answering outside its published behaviour | Acknowledged (dependency failure; the vault's backing checks fail closed) | |
| AB-1 | A lowered buffer or a reverting counter stops every send home; one route per chain | Buffer fixed (S-23); the single route is SEC-OQ-14 | |
| FF-1, FF-2, FF-3 | Factory construction inputs | Acknowledged (operator trust, release gate); creation code hashes pin the linked code | |
| FF-4 | 61 hub pools fail creation | Acknowledged | L-10 |
| MM-1 | `validate` accepts exit-unsafe Mandates | Payout Fee (S-17), bridge fee (S-9), lifetime (branch) fixed; the rest is SEC-OQ-11 | |
| MM-3 | One-unit deposits take the supply at a sub-unit Share Price | Fixed on the branch | `SharePriceBelowOneUnit` |
| MM-8 | Flow fee on the offered amount | Acknowledged (OQ-05 stance) | S-42 |

Rulings R-1 to R-14: R-4 (backing check) and the parts of R-1, R-3, R-5, R-7, R-8, R-9, R-10 and R-12 listed above are
done; R-2 is done by the "exit wins" reading (CF-2); the remaining parts are in `docs/OPEN-QUESTIONS.md`
(SEC-OQ-7 to SEC-OQ-14) and the plan's own F decisions in [`VERIFICATION-PLAN.md`](VERIFICATION-PLAN.md).

## 4. What the fix branch changed

| Commit subject (short) | Closes |
|---|---|
| CI pinned, fork blocks pinned at run time, jobs split | process findings |
| V4 adapter refuses a hookless pool above a 1% LP fee | M-02 (part) |
| A full exit's income transfer never blocks the exit | CF-2, L-02 (income) |
| Price source refuses absurd prices, changed decimals, future rounds | CF-R2, CF-R3 |
| A single-asset non-USDC unwind step takes the hinted route | T14, L-05 (part) |
| A one-unit rounding over-burn no longer blocks an Aave exit | F1, L-08 |
| No deposit below one base unit per whole share | MM-3 |
| Deployment script refuses an unusable wiring | SF-1, CF-V4-10, plan F-12 |
| Spoke refuses a built fill deadline not in the future | L-09 |
| At most 16 open positions per Spoke Vault (first 32, lowered after the real-Core measurement) | H-04 (positions) |
| Recovery of an unlisted arrival only against a report built after it | S-45 (new), H-02 |
| A spoke report lifetime of at most one day | M-04, S-25 |
| A hub pool token without a price is refused at creation | M-03 (hub half) |

Runtime sizes after the branch: SpokeVault 24,080 bytes (496 to spare), CoreVault 21,573, CoreVaultLogic 22,812, all
under EIP-170.

## 5. Residuals measured on the branch

### 5.1 C-01 inside the unwind band (S-2 residual, live Arbitrum pool)

`test/review/integration-price/UnwindAttackFork.t.sol`, Arbitrum block 510,517,128, oracle about 2,688 USDC per WETH.
The review's sizes: a holder of 250,000, an attacker stake of 60,000 claiming its whole value, Free Idle 25,000, one
±5% V4 position of 100,000; the unwind sells 35,515.81 in every row, with empty hints. "Narrow": the attacker leaves
liquidity two tick spacings under the pushed price; "native": the vault sells into the pool's own liquidity. Gains and
losses are against an honest claim from the same state (which itself costs the holder 63.95).

| Push under the oracle | WETH to push | Narrow: sale vs oracle | Narrow: attacker | Narrow: holder | Native: attacker | Native: holder |
|---|---|---|---|---|---|---|
| 1% | 9.00 | 98.83% | +110.96 | −121.86 | +165.88 | −197.34 |
| 2% | 17.65 | 97.84% | +276.71 | −313.41 | +362.20 | −423.54 |
| 3% | 26.35 | 96.86% | +473.38 | −535.46 | +599.95 | −691.05 |
| 4% | 35.11 | 95.90% | +701.70 | −788.85 | floor reverts | 0 |
| 4.8% | 42.22 | 95.04% | +932.60 | −1,041.60 | floor reverts | 0 |
| 4.9% | 43.12 | floor reverts | | 0 | | 0 |

At 4.8% the holder loses about 2.9% of the value unwound. A Standard claim (no Payout Fee) leaves the claimant 820.41
above its share value and can repeat every 72 hours for two flow fees. Unwinding the whole position (stake 100,000,
Free Idle 0): at 4.5% the holder loses 1,791.03 and the attacker gains 1,750.82, still +113.37 after the 2% Instant
Payout Fee. Before the sweep the same attacker took the whole position: +88,337 with one position, +99,496 with one
share; now −791 and a reverted transaction. Tightening the band is SEC-OQ-12; on the live pool an honest sale clears a
1% floor up to 8 WETH but not 10 WETH, before the fund's own liquidity leaves the pool, and the review's deviation-band
option (+719 bytes) no longer fits in the Spoke Vault (496 bytes left) unless it moves into `SpokeCrossChainLib`.

### 5.2 M-02 wash trading under the pool-fee cap

| Pool | Volume | Income | Manager | Protocol | Holders |
|---|---|---|---|---|---|
| Live Arbitrum 0.05% (`WashTradeIncomeFork`), 20% performance fee | 6,000,000 | 2,834.13 | 283.41 | 283.41 | −1,479.33 |
| 1% pool, fund the only LP, through the real factory (`FeeTierFork`), 20% | 2,000,000 (50 round trips) | 19,611.62 | 1,961.16 | 1,961.16 | −4,014.25 |
| 100% pool (one swap of 198,000) | | | refused (`PoolFeeTooHigh`) | | |

The cap bounds the fee per swap, not the volume: about 50 calls in a 1% pool reproduce what the refused 100% pool
did in one. Charging the performance fee net of the fund's own swap fees (SEC-OQ-7) closes the channel.

### 5.3 Other measurements

- Aave on the live pool (`AaveLiveReserveFork`): foreign aTokens made 6 of 12 closes revert on `main`; 0 of 12 on the
  branch. The best-effort income bound still reads the aToken's cash, not the virtual liquidity (S-34, acknowledged).
- The Aave adapter accepts any reserve and reports it as exact value; a non-USDC reserve in the unwind order needs a
  claimant route hint (S-49), and without one the step is refused by name.
- With Free Idle at 0, an unwind that fails makes `claimPayout` revert `InsufficientFreeIdle` rather than pay nothing:
  a third party who orders transactions and pushes the pool past the floor can make someone else's claim revert
  (griefing only, reasoned, not tested).
- Pool depth on the live Arbitrum WETH/USDC 0.05% pool: 46.79 WETH to the bottom of the full downside, a round trip of
  150.64 USDC; the 0.3% pool is still empty; Robinhood WETH/USDG 0.05%: 55.05 WETH, 177.20 USDG.
- Bytecode: UniswapV4Adapter 18,079 bytes, SpokeVault 24,080 (496 to spare), CoreVaultLogic 22,812 (1,764 to spare),
  SpokeCrossChainLib 12,121 (12,455 to spare).

### 5.4 Conservation walk

(Filled in from `test/review/integration-xchain/Fork_ConservationWalk.t.sol`.)
