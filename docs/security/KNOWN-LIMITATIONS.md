# Known limitations

What a deployer, an operator, a manager and a Shareholder must know about the contracts as they are on main
after the 2026-09-30 sweep. Each item points to its register entry ([`FINDINGS.md`](FINDINGS.md)) or its decision.
The contracts are **not independently audited** ([`SECURITY.md`](../../SECURITY.md)).

## 1. Open items that need a founder decision

These three are the only findings above low severity that are not fixed. Their proof-of-concept tests still pass
on main as pins.

| Id | Severity | What can happen today | Question to rule on | Recommended ruling |
|---|---|---|---|---|
| S-8 | high | A manager key (compromised, buggy, or dishonest) swaps the Unallocated Balance of any Spoke Vault in a Mandate pool at a price it sets, with a counterparty it controls, in one transaction; the Mandate fixes where the manager trades, not at what price. `test_POC_managerSwapsUnallocatedBalanceAtAPriceItSet` | Should manager swaps be bounded against a price the manager does not control (the price source on the hub; a TWAP or an accepted per-pool risk on a spoke), or does DEC-030 (no loss limit) cover a self-set price? | Bound every manager swap: on the hub, `minAmountOut` at least the price-source value less a Mandate slippage bound; on a spoke, the same where a price exists, otherwise a TWAP from the pool's own oracle with a floor. A swap at a self-set price is a transfer, not a market loss |
| S-15 | medium | An entrant deposits, forwards uncollected income (permissionless), opens a Standard Payout and leaves after 72 h with a share of income earned before it entered; profitable whenever uncollected income exceeds about 0.5% of Share Assets. `test_POC_jitEntrantCapturesIncomeEarnedBeforeEntry` | CS-OQ-1: is income generated before an entry but collected after it shared with the entrant, or must attribution be time-weighted or snapshotted? | Until a rule exists, an operational rule: collect and forward income before it reaches a small fraction of Share Assets (the keeper can do both permissionlessly). A snapshot at the last collection is the least invasive contract change |
| S-5 | medium (interim), high before `23c317a` | The manager sets an Operating Cash floor and top-up with no cap (DEC-100), moving Free Idle or a spoke's Unallocated Balance into Operating Cash, outside Share Assets. `releaseOperatingCash` (manager only) returns it above the floor, so the mistake is reversible by the same key; nothing lets anyone take it. Nine `test_POC_*` pins | Should the floor and top-up have a protocol cap, and which verb spends or returns Operating Cash before fund close (DEC-096)? | A protocol cap on the floor as a fraction of Share Assets, and keep `releaseOperatingCash` as the return path |

## 2. Residual risks after the fixes

| Id | Residual | Bound |
|---|---|---|
| S-2 | The unwind swap floor is `max(spot, oracle) - 5%` (`MAX_UNWIND_SLIPPAGE_BPS`, OPEN, SEC-OQ-12). A claimant who pushes the pool up to 4.8% under the oracle makes the fund sell under the external price: on the live Arbitrum pool, with the review's sizes, the remaining holder lost 1,041.60 (about 2.9% of the 35,515.81 unwound) and the attacker gained 932.60; a Standard claim repeats it every 72 hours for two flow fees (CROSS-CHECK §5.1) | Bounded by the band per claim; needs capital to move the pool (42 WETH at 4.8%). On the live pool an honest sale clears a 1% floor only up to about 8 WETH |
| S-3 | A send home stays listed for `HUB_BOUND_RETENTION` (3 days) after its fill deadline. An Across refund that lands later than that is no longer seen by `report()` or `sendToHub` (the entry has left the list) and the transfer stays in no value base until someone calls the permissionless `recognizeRefund` (pinned: `test_POC_REVIEW_H01_refundAfterTheRetentionReopensTheGap`) | Across refunds within about 53 to 107 minutes on chain; a keeper that calls `recognizeRefund` closes it |
| S-4, S-45 | An arrival that no report listed is recovered permissionlessly once the hub has accepted a spoke report built more than one report lifetime after the last unlisted arrival for that id that no longer lists it. Between that report's delivery and the recovery call the transfer is in no value base while mints are open: an entrant who lands in between gained 9.7% in the review's scenario (`test_POC_REVIEW_H02_entrantBetweenTheReportAndTheRecoveryIsPricedLow`). Its kind is unknowable, so an Income transfer recovered this way enters Idle as Principal | Needs a report outage longer than `fillDeadline + 3 days`; the keeper must recover in the same cycle as that delivery |
| S-1 | In the PAYOUT fallback a token the price source never priced (CS-OQ-4) keeps its position at the reported spot composition for the USDC leg | Only reachable for a fund whose mints never worked |
| S-11 with S-3 | At most 64 sends home listed at once (`MAX_HUB_BOUND_IN_FLIGHT`), each listed for `fillDeadline + 3 days`: sends home are rate-limited to 64 per about 3.25 days per spoke | Manager-only, recoverable by waiting; batch sends home |
| S-26, S-28 | Payouts never check price age or sequencer uptime (OQ-10 stance); during an outage a claimant is paid at the old price | Unforceable by an attacker; bounded by the price move during the outage. Needs an explicit founder acceptance against Q57 (b) |
| S-9 | A manager may still over-quote the bridge fee up to `MAX_BRIDGE_FEE_BPS` (100 bps) on every send; without exclusivity the fastest relayer, not the manager, earns it | Bounded by 1% per send; a per-period fee budget is a founder question |
| S-19, S-38 | A matured Standard Payout never expires; its reserve stays locked until claimed | Bounded by the requester's own value (DEC-024, DEC-060, FV-OQ-1) |
| S-27, S-32 | One illiquid step (Aave without liquidity, a thin pool that cannot meet the 5% floor) makes the automatic unwind revert; the claim is paid from Idle and the request stays open (DEC-068, DEC-069) | Order exact-value steps last; keep hub positions small against pool depth; unwinding in slices is future work |
| S-30, S-31 | A full 256-id arrival window turns off the report path of `attestExpiry`; the report lifetime (1,588 s) equals worst-case Arbitrum finality, so any delay above about 26.5 min stops mints until the next report | Payouts unaffected; the keeper's cadence is the control |
| S-24, S-53 | The factory accepts any per-spoke Wormhole chain id and, on a spoke, pool tokens the hub cannot price; a wrong chain id is a self-DoS (the spoke never reports and is never funded); an unpriceable spoke token closes mints and is valued at 0 in payouts (SEC-OQ-9) | Hub pool tokens are refused at creation (S-53); report lifetime at most one day (S-54); the DEC-089 registry is the complete fix |
| S-35 | USDG is priced 1:1 (ruling 2026-09-29); a depeg goes straight into the Share Price and the Spoke Cap | Accepted by ruling |
| S-36 | No hub-driven spoke unwind: a dead manager key traps spoke capital | MVP scope; hub-to-spoke instructions are planned to follow the report channel |
| S-17 | `MAX_PAYOUT_FEE_BPS` = 9,900 only prevents an underflow; a 99% Payout Fee is a valid, immutable Mandate value | Disclosure: read the Mandate before depositing |
| S-41 | The income index remainder can tip an entrant by one base unit | Dust |

## 3. New protocol parameters introduced by the sweep and its cross-check (all OPEN for a ruling)

| Constant | Value | Where | Purpose |
|---|---|---|---|
| `HUB_BOUND_RETENTION` | 3 days | `ReportCodec` | How long a send home stays listed after its fill deadline (S-3) |
| `MAX_HUB_BOUND_IN_FLIGHT` | 64 | `SpokeVaultTypes` | Listed sends home per spoke (S-11) |
| `MAX_BRIDGE_FEE_BPS` | 100 | `Mandate` | Cap on the Mandate's `maxBridgeFeeBps` (S-9) |
| `MAX_PAYOUT_FEE_BPS` | 9,900 | `Mandate` | `10,000 - MAX_FLOW_FEE_BPS`, arithmetic bound (S-17) |
| `MAX_UNWIND_SLIPPAGE_BPS` | 500 | `SpokeVault` | Unwind swap floor under `max(spot, oracle)` (S-2) |
| `MAX_OPEN_POSITIONS` | 16 | `SpokeVaultTypes` | Open positions per Spoke Vault (S-46): the worst report under this cap, 64 Income sends home filled before their listing and a full arrival window delivers in 26.87M gas of 32M through the real Wormhole Cores (30.28M at 32 positions) |
| `MAX_POOL_FEE` | 10,000 pips (1%) | `UniswapV4Adapter` | Highest LP fee of a registered hookless pool (S-47) |
| `MAX_REPORT_AGE` | 1 day | `MandateLib` | Upper bound on a spoke's report lifetime (S-54) |
| `MAX_PRICE` | 2^128 | `ChainlinkPriceSource` | Highest accepted `price1e18` (S-51; structural, not an economic band) |

The S-4 recovery delay (`FILL_WINDOW + HUB_BOUND_RETENTION + 2 x maxReportAge`) is gone: recovery now needs a spoke
report built after the last unlisted arrival (S-45).

## 4. Operational constraints (keeper and manager runbooks)

- **First report before the first send.** `sendToSpoke` reverts `SpokeNotReporting` until the fund's receiver has
  accepted a report from that spoke (S-14). After `createSpoke`, call `report()` on the new Spoke Vault and deliver
  the VAA on the hub.
- **No exclusive relayer.** Both vaults revert `ExclusiveRelayerNotAllowed`; quote with `exclusivityDeadline = 0`
  and `exclusiveRelayer = address(0)` (S-9).
- **Report payload is version 3** and carries `mandateHash`; the hub rejects a report from a spoke running a
  different Mandate (`WrongMandate`, S-6). Off-chain decoders must follow `ReportCodec`.
- **Collect and forward income often** (S-15) and **deliver reports within their lifetime** (S-31): both are
  permissionless.
- **Recover an unlisted arrival in the same cycle as the report that opens it** (S-45): after a report outage longer
  than a send home's retention, deliver the first report built after the arrival and call `recoverUnlistedArrival` at
  once, so no deposit is priced in between.
- **Every manager swap minimum from the oracle** (S-8 open): the vault accepts any minimum, zero included;
  `local-e2e/src/api.ts` builds swaps with the oracle value less 1%.
- **Recognize refunds and recover unlisted arrivals**: `recognizeRefund`, `attestExpiry`,
  `recoverUnlistedArrival` and `claimOwedFees` are permissionless liveness verbs a keeper should call when their
  conditions hold.
- **Sends home in batches**: at most 64 listed per spoke over about 3.25 days (S-11).
- **A blocklisted fee recipient** does not stop the fund: the fee is booked as owed and `claimOwedFees(token,
  recipient)` pays it once the transfer can succeed (S-12).

## 5. Out of scope of this review

The external protocols' own security, protocol key governance, the off-chain keeper, and LP-level market risk of
the pools the fund trades ([`THREAT-MODEL.md`](THREAT-MODEL.md), "Out of scope").
