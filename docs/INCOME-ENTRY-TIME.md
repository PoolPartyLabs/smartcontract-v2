# Income entry-time eligibility (DEC-145)

Founder ruling, October 3, 2026: WP-14 ships before the mainnet alpha, overriding the October 2 deferral.

## Rule and mechanism

New deposit shares, including the manager seed, wait for each spoke independently. A report earns income only for
shares present throughout its interval: the previous accepted report's timestamp must be at least the deposit's
Hub `block.timestamp`. Delayed reports and the interval straddling entry give the entrant nothing. Hub income keeps
recognition before mint and burn (DEC-117/138). Counter advances, not collection time, determine entitlement.

Each holder has **one waiting lot per spoke**. A top-up merges a still-waiting lot at the newest timestamp. Each
source groups deposits at the same second into FIFO entries, with an independent activation cursor. A delivery
activates at most **32 entries**, before recognizing its counters; remaining entries wait for the next delivery.
There is no holder enumeration. Burns consume waiting shares first, then active shares (including Payouts and
closed-fund exits). Income Withdrawal never changes lots.

An activation stores the token indices, token collection intervals, dollar-index mark and asynchronous collection
cursor before the report's income is recognized. Holder settlement uses this historical baseline, converts at each
actual collection rate, and merges the activated lot into the active balance. Frozen collections preserve the lot's
rights while the Income transfer is in transit; moving or burning shares does not move those rights. Unsold tokens
and partial sales retain their original holders' claims. Manager/protocol performance-fee totals and split are
unchanged. Income recognized with no active shares remains unattributed, as in the model's `dust` bucket.

## Bounds and clocks

Per-source token loops are bounded by 16 tokens; activation is bounded by 32 entries; settlement phases use the
existing 64-step budget. The previous unbounded retry loop in Core Vault holder settlement is removed. An incomplete
Income Withdrawal returns zero and persists progress; repeat it before retrying a mint or burn. Historical off-chain
views still traverse collection history. FIFO and collection history storage grow over the fund lifetime, not the
number of live waiting lots per holder.

The cap measurement with 32 eligible entries and all 16 token baselines nonzero is **14,811,046 gas**, below the
32 million gas budget. Empty token baselines cost 4,709,746 gas. Frozen-collection capture also carries its per-token
adjustments within the step budget; it never calls an unlimited historical conversion loop from a state-changing
holder path.

Report timestamps come from the spoke and deposit timestamps from the Hub, never cross-chain block numbers. The
receiver's existing future-clock tolerance is the Mandate `maxReportAge` (1,588 seconds in the alpha configuration).
Deposits within that tolerated skew may be misclassified; this is the accepted bounded-clock-skew reading, **D-42**
in the supplied plan (the task calls it D-28; D-28 actually concerns fresh reports before burns). Permissionless
reports immediately after deposits shorten the excluded straddling interval (DEC-159), without time interpolation.

## Worked cases and verification

`test/unit/core/IncomeEntryTime.t.sol` ports doc 08's Python model in token units, with exact reference totals and
at most two base units of adverse integer rounding per holder:

| Case | Ana | Other holder |
| --- | ---: | ---: |
| Delayed reports, Bruno enters at 450 | 50 | Bruno 10 |
| Top-up, collection, partial withdrawal | 55 | Caio 40 |
| Waiting top-up burned before activation | 24 | Caio 20 |
| Full exit with report in transit | 10 | Caio 30 |

The conservation property checks paid holder totals never exceed recognized income and the residual is bounded
rounding dust. `test/fork/e2e/IncomeEntryTime.fork.t.sol` runs a real two-chain report cycle with Uniswap V4 fees:
late delivery and the straddling report pay zero; the first eligible report pays positive income. Harness Phase 9b
records a real fee-generating prior interval delivered after Bruno's mint, and zero prior-interval WETH/USDG income,
in the standard JSON/Markdown run report.
