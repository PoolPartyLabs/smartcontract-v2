# Invariants and properties

The properties the test suites hold, each named after the decision it encodes. Three kinds:

- **Stateful invariants** (`invariant_*`): Foundry invariant tests. A handler drives the real contracts through
  random call sequences (default 256 runs x 64 depth in the security suites; `FOUNDRY_INVARIANT_RUNS` and
  `FOUNDRY_INVARIANT_DEPTH` override) and the property is checked after every call.
- **Symbolic properties** (`check_*`): Halmos proofs over the pure libraries and codecs, valid for every input
  of the declared domain; the ones the solver could not close within its budget are listed as such (no
  counterexample was found; each has a fuzz twin).
- **Regression pins** (`test_SEC_S<n>_*`, `test_POC_*`): one concrete attack per finding, asserted to fail
  (fixed) or to still succeed (open). Listed in [`FINDINGS.md`](FINDINGS.md), not here.

## Whole-fund stateful invariants (`test/security/invariants/`)

The fixture (`FundSystemFixture.sol`) deploys a real Core Vault, both Spoke Vaults (hub and spoke), the receiver and
the adapters against mocks of Across, Wormhole, the pools and the price source; the handler
(`FundSystemHandler.sol`) plays Shareholders, the manager, relayers (fills, refunds, late fills), the keeper
(reports, deliveries) and strangers (donations, permissionless verbs). Two switches drop a liveness assumption:
`SEC_LATE_REFUNDS=true` lets Across refund after the report lifetime, `SEC_UNLISTED_SENDS_HOME=true` lets a send
home be filled before any report lists it. Before the S-3 and S-4 fixes each switch produced a counterexample
(`DYN-01`, `DYN-02`); on main the value invariants hold with both, as long as Across refunds within
`HUB_BOUND_RETENTION` (3 days).

| Property | Decision | Statement |
|---|---|---|
| `invariant_DEC104_shareAssetsEqualTheSumOfTheirBuckets` | DEC-104, DEC-083, DEC-085, DEC-080 | Share Assets equal Idle + the hub Spoke Vault's Unallocated Balance and position principal + In-flight Value + the spoke's principal from the latest accepted report, rebuilt from the ledgers and every transit's state |
| `invariant_DEC107_feesPlusHolderIncomeNeverExceedCollectedIncome` | DEC-080, DEC-107, DEC-109, Q60 | Every collected unit is a fee that left at collection or sits in the accumulator; holders are never owed, and never took, more than what was distributed; the Core Vault's ledger is backed by its balances |
| `invariant_DEC104_noActorEndsWithMoreThanTheyPutIn` | DEC-104 | What a Shareholder was paid plus what their shares are worth never exceeds what they paid, beyond rounding (income is paid apart, in its own tokens) |
| `invariant_DEC080_ledgerSumsNeverExceedBalances` | DEC-080 | For every ledger token of both Spoke Vaults, Unallocated Balance + collected income + Operating Cash never exceeds the balance; donations only widen the gap |
| `invariant_DEC080_principalLedgerIsConserved` | DEC-080 | Every unit of principal in a Spoke Vault's ledger is explained by arrivals, sends home, refunds, positions and Operating Cash |
| `invariant_DEC092_collectedIncomeBucketIsConserved` | DEC-092 | The collected income bucket holds exactly the income the adapters paid plus Income bridged in, less what was forwarded or sent home; it never mixes with principal |
| `invariant_DEC066_booksAreTheSumOfTheirTransits` | DEC-066, DEC-085, S-13 | The hub's transit books are the sums over its transits by state: the Spoke Cap counts every transit still Sent or whose expiry was attested by time alone; In-flight Value counts what is neither confirmed nor refunded |
| `invariant_DEC085_withAFreshReportEveryTransferIsInExactlyOneBase` | DEC-085, DEC-104 | With a fresh report and nothing else settled, every unit of principal is in exactly one base, wherever it is |
| `invariant_DEC104_atRestNothingIsCountedTwiceOrLost` | DEC-104 | Once every Across deposit is filled or refunded, every refund recognized and a fresh report delivered, the ledgers hold exactly the principal that went in less what went out, and Share Assets equal that |

## Component invariants (`test/unit/`)

| Property | File | Statement |
|---|---|---|
| `invariant_DEC072_payoutReserveWithinIdle` | `core/CoreVaultInvariant.t.sol` | Payout Reserve never exceeds Idle |
| `invariant_DEC091_supplyIsWholeShares` | `core/CoreVaultInvariant.t.sol` | `totalSupply` is a multiple of 1e18 |
| `invariant_DEC104_shareAssetsEqualBuckets` | `core/CoreVaultInvariant.t.sol` | Share Assets equal Idle + the hub Spoke Vault's Unallocated USDC + its position principal (hub-only fixture) |
| `invariant_DEC080_balanceCoversLedger` | `core/CoreVaultInvariant.t.sol` | The USDC balance covers Idle + Operating Cash + collected USDC income + unmatched arrivals |
| `invariant_DEC080_directTransferNeverMovesSharePrice` | `core/CoreVaultInvariant.t.sol` | A transfer into the vault that is not from an adapter or the bridge never changes the Share Price |
| `invariant_Q60_indexNeverDecreases` | `core/CoreVaultInvariant.t.sol`, `IncomeAccumulator.t.sol` | The per-token income index never decreases |
| `invariant_DEC107_everyCollectedUnitIsFeeOrAccumulated` | `core/CoreVaultInvariant.t.sol` | Every collected unit is a fee transferred at collection or in the accumulator (index or ownerless) |
| `invariant_Q60_owedPlusTakenNeverExceedsDistributed` | `IncomeAccumulator.t.sol` | Owed plus taken never exceeds distributed |
| `invariant_DEC080_ledgerNeverExceedsBalance` | `spoke/SpokeVaultInvariant.t.sol` | A Spoke Vault's ledger never exceeds its balance, per token |
| `invariant_Q60_cumulativeIncomeNeverDecreases` | `spoke/SpokeVaultInvariant.t.sol` | Cumulative income counters are monotonic |
| `invariant_DEC093_reportSequenceStrictlyIncreases` | `spoke/SpokeVaultInvariant.t.sol` | The report sequence strictly increases |
| `invariant_DEC091_totalSupplyIsWholeShares` | `ShareToken.t.sol` | `totalSupply` is a multiple of 1e18 |
| `invariant_DEC004_allowanceAlwaysZero` | `ShareToken.t.sol` | No allowance can ever exist (shares are non-transferable) |

## Symbolic properties (`test/security/symbolic/`, Halmos)

Proved unless marked. Solver notes and budgets: [`reports/dynamic-analysis.md`](reports/dynamic-analysis.md) and
[`TOOLING.md`](TOOLING.md).

### `CodecSymbolic.t.sol` (all proved)

| Property | Statement |
|---|---|
| `check_DEC090_transitMessageRoundTrip` | `decode(encode(x)) == x` for every fund id, origin chain, transit id and kind |
| `check_DEC090_transitMessageNeverCollides` | Two messages that differ in any field never share an encoding |
| `check_DEC090_transitMessageRejectsOtherVersions` | Any version other than the current one is rejected |
| `check_DEC092_transitMessageRejectsUnknownKind` | A kind word that is not a `TransferKind` is rejected, never read as Principal or Income |
| `check_DEC093_reportRoundTrip` | Report round-trip with every scalar symbolic and one symbolic entry per list |
| `check_DEC093_emptyReportRoundTrip` | An empty report round-trips |
| `check_Q57_reportRejectsOtherVersions` | A payload with any other version is never decoded |
| `check_Q57_reportRejectsShortPayload` | A payload shorter than one word is rejected before any read |

### `IncomeAccumulatorSymbolic.t.sol` (5 of 7 proved)

| Property | Statement | Result |
|---|---|---|
| `check_DEC014_newHolderOwesNothingOfPriorIncome` | An entrant checkpointed at zero balance owes nothing of prior income | proved |
| `check_Q60_checkpointCreditsOnceAndExactly` | A checkpoint credits exactly `shares * (index - checkpoint) / 2^128` rounded down; a second one credits nothing | proved |
| `check_LC100_takeOwedConserves` | `takeOwed` moves exactly what it returns, never above owed or the cap | proved |
| `check_Q60_advanceSourceIsMonotonic` | A source's counter never decreases; a regressed report returns zero and flags the source | proved |
| `check_Q60_distributeBooksExactlyOnce` | `distribute` never lowers the index, never reverts, books an accepted amount exactly once | proved |
| `check_Q60_remainderStaysBelowSupply` | After a distribution the carried remainder is below the supply | proved (bitwuzla) |
| `check_Q60_twoHoldersNeverOwedMoreThanDistributed` | Two holders owning the whole supply are never owed more than distributed | no counterexample, solver timeout on the 512-bit `mulDiv`; fuzz twin passes |

### `ShareMathSymbolic.t.sol` (7 of 16 proved)

| Property | Statement | Result |
|---|---|---|
| `check_DEC035_mintIsWholeAndNeverOvercharges` | A mint is whole shares and never charges above the net amount | timeout (`mulDiv`), fuzz twin |
| `check_DEC077_burnIsWholeAndNeverPaysAboveRequest` | A burn is whole shares and never pays above the request | timeout, fuzz twin |
| `check_DEC077_mintThenBurnAtOnePriceNeverProfits` | Mint then burn at one price never profits | timeout, fuzz twin |
| `check_DEC084_mintThenBurnAtVaultPriceNeverProfits` | A deposit never raises the Share Price; burning right after pays at most the cost | timeout, fuzz twin |
| `check_DEC061_usdcForMonotonicInShares` | USDC value of whole shares is monotonic in the share count | timeout, fuzz twin |
| `check_DEC061_usdcForMonotonicInPrice` | USDC value of whole shares is monotonic in the price | timeout, fuzz twin |
| `check_DEC084_supplyValueNeverExceedsShareAssets` | The whole supply at the Share Price never exceeds Share Assets | timeout, fuzz twin |
| `check_DEC110_flowFeeAtMostOnePercent` | The flow fee is at most 1% and a rate above the cap reverts | timeout, fuzz twin |
| `check_DEC106_previewDepositNeverChargesAboveAmount` | A deposit never charges above the amount offered | timeout, fuzz twin |
| `check_DEC110_flowFeeAtTheDefaultRateIsWithinTheCap` | At 25 bps the flow fee is within the 1% cap for every amount | proved |
| `check_DEC110_flowFeeAboveCapAlwaysReverts` | A rate above the cap reverts for every amount | proved |
| `check_DEC102_bpsOfAboveOneHundredPercentReverts` | A rate above 100% reverts for every amount | proved |
| `check_DEC061_noSharesMeansTheInitialPrice` | With no shares the Share Price is 1.00 USDC | proved |
| `check_DEC035_zeroSharePriceNeverPricesAShare` | At a zero Share Price nothing is minted or burned | proved |
| `check_DEC091_isWholeSharesIsTheModulo` | `isWholeShares` is exactly "a multiple of 1e18" | proved |
| `check_DEC091_fractionalSharesNeverPriced` | A fractional share amount can never be priced | proved |

Non-vacuity of every proved property was checked by running it against mutated copies of the libraries (the
proof must fail on the mutant).

## Mutation testing (`test/security/mutation/LibraryMutationKill.t.sol`)

`slither-mutate` on `ShareMath` and `IncomeAccumulator` (60 mutants each of the AOR, ROR and SBR classes):
ShareMath 45 caught by the baseline suites, 5 more by the 13 kill tests, 10 equivalent survivors;
IncomeAccumulator 47 caught, 10 more killed, 3 equivalent. The RR and CR classes were not run (mutant limit).

## What is not covered by an invariant

- Manager swap prices (S-8): no property bounds what the manager gets for a swap, by design of the current rules.
- Income attribution across time (S-15): the accumulator's properties hold for the holders at collection, which is
  the CS-OQ-1 stance under review.
- Operating Cash (S-5): the ledger properties count it; nothing bounds its size.
- Anything that depends on a live pool's depth (S-32) is a fork test, not an invariant.
