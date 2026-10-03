# Architecture: merged internal-alpha baseline

Baseline: `origin/main` at **`334eae6`**, October 3, 2026, including merged PR #24/#25/#26/#28/#29. Governing register: **DEC-001..DEC-187**;
see [DECISIONS](DECISIONS.md) for implemented/partial/deferred status and
[OPEN-QUESTIONS](OPEN-QUESTIONS.md) for plan divergences. This describes code already on main, not the end-state plan.

Arbitrum One is the Hub Chain; Robinhood Chain is the Spoke Chain. Uniswap V4 holds positions on both chains,
Aave V3 is supply-only on Arbitrum, Uniswap V3 routes swaps, Across transports stablecoins, and Wormhole transports
reports and orders, **never capital** (DEC-018/028/031/086/120/136/153).

## 1. Components and immutable linked libraries

| Component | Responsibility on this baseline |
|---|---|
| Core Vault | Hub custody of USDC Idle, share pricing, Payout Requests/payments, income and fees, lifecycle guards and transits; never calls a DeFi protocol directly |
| Spoke Vault | One fund account per chain, including Hub; adapter-driven positions, internal token ledger, Unallocated Balance, collected income, base-token Operating Cash and reporting |
| ShareToken | Whole 18-decimal shares; holder transfers, delegated transfers and approvals disabled; only Core Vault mints/burns |
| ManagerFeeVault | Per-fund custody of manager fee tokens; manager can withdraw; not a share-backed bucket |
| ManagerRegistry | Shared Hub registry keyed by manager, live protocol slice 5–50%, default 50%; no adjustable performance minimum |
| ValueReportReceiver | Verifies Wormhole guardian quorum, fund, Mandate hash, emitter, chain, increasing sequence and report age; stores latest report |
| UniswapV4Adapter / AaveV3Adapter | Immutable per-fund position adapters; principal and income separately accounted; V4 Mandate pools hookless |
| UniswapV3SwapAdapter | Immutable per-fund/per-chain swap adapter with closed endpoint-token list and factory API signer |
| AcrossBridgeAdapter | Stateful, vault-only send builder; determines output/deadline/fee and records its own fee window |
| TransitEscrow | Keyless per-send clone holding Across depositor/refund identity; cannot sign deposit updates to lower output |
| FundFactory / CodeStore / Create3Deployer | Predict and deploy immutable fund contracts on each chain; CodeStore chunks store creation code, not runtime upgrades |

The Core Vault has abstract source modules `CoreVaultBase`, `CoreVaultPayout`, `CoreVaultIncome`, `CoreVaultTransit`;
the Spoke Vault has `SpokeVaultBase`, `SpokeVaultUnwind`, `SpokeVaultIncome`. They are compiled into their vault,
not separately deployed contracts.

| Runtime caller | Linked external libraries |
|---|---|
| CoreVault | CoreVaultLogic, CoreVaultTransitLogic, CoreVaultIncomeLogic, CoreVaultIncomeCollectionLogic, CoreVaultPayoutLogic, CoreVaultClosureLogic |
| CoreVaultLogic | CoreVaultIncomeLogic |
| CoreVaultTransitLogic | CoreVaultLogic, CoreVaultIncomeLogic, CoreVaultPayoutLogic, CoreVaultClosureLogic |
| CoreVaultPayoutLogic | CoreVaultLogic, CoreVaultIncomeLogic |
| CoreVaultClosureLogic | CoreVaultLogic, CoreVaultIncomeLogic, CoreVaultIncomeCollectionLogic |
| CoreVaultIncomeLogic | CoreVaultIncomeCollectionLogic |
| SpokeVault | SpokeCrossChainLib, SpokeUnwindLib, SpokeIncomeLib, SpokeCloseLib |
| SpokeUnwindLib / SpokeIncomeLib | SpokeCrossChainLib |
| SpokeCloseLib | SpokeUnwindLib |

`CoreVaultIncomeCollectionLogic` has no external linked dependency back into its callers; dependencies deploy first.
`SpokeLedger`, `OrderCodec`, `OrderVerifier`, `BridgeFeeRule`, `ReportCodec`, `IncomeAccumulator`, `ShareMath` and
**live** `DollarIncomeIndex` are internal/inlined libraries. PR #21 fixed nested library linking in deployment;
artifact `linkReferences` are authoritative, not only the vault's direct links.

`FactoryDeployment` deploys libraries once per chain and links the vault creation code and dependent libraries.
Their addresses/code are part of each immutable fund's trust surface. External library calls execute in vault storage
and emit at the vault address; adapter calls do not delegatecall untrusted adapter code. There is no proxy or upgrade
path (DEC-022/058/131/183). Changing linked code requires a new factory/fund version. Publish all library addresses
and verify links on both chains; keep each runtime <=24,576 bytes. See [current sizes](reports/2026-10-03-MVP-REPORT.md).

## 2. Mandate v2 and creation

Mandate v2 (PR #12) includes manager, Hub EVM/Wormhole chain ids, Hub USDC, closed per-chain tokens, position adapters,
swap adapters, pools, spokes, ordered bridge adapters, initial Operating Cash parameters, Payout Fee, performance fee,
management fee and minimum first deposit. Each chain needs its base token and a swap adapter; at most 16 tokens total.
Spoke pool tokens must belong to that chain's token list. Swap adapters must have code and match factory wiring.
The Hub checks its Wormhole id and refuses a spoke using the same id (DEC-178).

Removed fields: `unwindOrder`, Mandate payout term and `maxBridgeFeeBps`. **No Mandate unwind priority** remains,
but the current interim automatic Hub unwind still walks position registry order. Standard term is a protocol
constant of 72 hours (DEC-154). Spoke Cap counts sent principal including In-flight Value, checked only on send.

`FundFactory.createFund` atomically transfers manager seed and issues shares; a fund cannot be left created without
shares. Seed must meet the manager's `minFirstDeposit`; the creation script defaults to 100 USDC, but no protocol
100-USDC floor is enforced. Later deposits need only cover a whole share and the caller's minimum-share constraint. Seed pays flow fee;
the manager peak share count starts at seed and grows with deposits. The manager cannot redeem below
`ceil(managerPeakShares / 2)`; a request is checked and payment capped at that base (DEC-127/146/183).

Creation checks configured token prices exist and are nonzero; it does **not** prove price freshness, future availability,
or implement the full spoke price-source hierarchy (DEC-123). There is no fund-value ceiling (DEC-174), though structural
token/position bounds and creation gas remain limiting. Internal-alpha wallet/value restrictions are operational,
not a permissioned deposit gate (DEC-134).

## 3. Value bases and live flows

- **Idle** is USDC booked in the Core Vault; **Free Idle** is Idle less Payout Reserve. A Standard Payout earmarks
  reserve, and an Instant Payout cannot spend another request's reserve.
- **Share Assets** include Idle, position principal, Unallocated Balance and eligible In-flight Value, net of the
  management-fee liability; they exclude Attributed Income and Operating Cash.
- **Gross Assets** include the other fund buckets and the management-fee liability (PR #12's explicit reading).
  Do not infer ledger value from raw ERC-20 balances or unsolicited transfers (DEC-080/098/104).
- In-flight Value uses the amount to arrive for pricing; the Spoke Cap uses amount sent until outcome reconciliation.
  Sends, arrivals, expiry attestations, refunds and recovery are keyed so arrivals cannot be counted twice.

Deposits are synchronous USDC receipt plus whole-share mint, leaving principal in Idle; they do not open positions.
The Core Vault calls income hooks before/after share changes and on valuations/report acceptance/income arrivals,
and the live book recognizes per-token entitlement before changing balances (PR #18 via #23).

Manager sends capital through a ranked Mandate bridge adapter to the fund's fixed destination. A spoke must first
have an accepted report. Manager opens/increases/reduces/closes positions through allowed position adapters and pools.
Principal returned on Hub can move to Core Vault Idle; spoke principal returns through Across. Ledger checks enforce
actual input debit/output receipt around swaps, not merely adapter return values.

Payouts use Idle first, then proportional Hub unwind (WP-09, PR #19 via #23):
`min(1, (S - A/P) / (T - A/P) * 1.02)`, where S is served shares, T total shares, A available Idle and P Share Price.
Positions and eligible Unallocated Balance use the same fraction; sales use the Mandate swap adapter, not position
pools. The legacy mandatory 5% oracle floor and arbitrary caller pool hints are removed. Requester `maxLossBps`
uses 0 or >=10,000 as no maximum; failed/over-limit positions are isolated, exclusions include reasons, and retries
skip delivered work (DEC-137/140/148/151). Instant assigns all sale Market Costs to the leaver; Standard absorbs
up to 1% of pre-sale spot value per sale in the fund, excess to the leaver (DEC-118/141). Pending requester costs
survive proceeds-limited burns. A terminal sub-share debt may consume one whole share, retain rounding surplus
in Idle and close the request rather than trap future payouts.

Insufficient Hub liquidity publishes UNWIND to spokes (WP-12, PR #22 inside #21). Proceeds are earmarked, returned
through Across, then reserved at the Hub. `settlePayout(holder)` is permissionless and waits for reached spokes'
post-unwind reports and known transit resolution, pricing a consolidated burn at one Share Price. Expired/retried
claims use the same gate; partial fills/refunds cannot drop obligations or double-charge costs. Mint/burn freshness
is enforced; cached dependency-price fallback is distinct from report freshness. No inactivity switch exists
(DEC-157/160): a silent spoke blocks exits needing a fresh report. Standard Payout Wormhole fees are caller-funded.

The live income book uses `DollarIncomeIndex`: per-token recognition intervals, sealed sold cohorts and a Hub-dollar
index (WP-10, PR #18 via #23). Mint/burn changes do not transfer already recognized rights to entrants.
`requestIncomeWithdrawal(maxLossBps)` collects Hub income and publishes COLLECT to spokes with income; position
fees are sold through the swap adapter to local stablecoin. Authenticated collection results seal sold cohorts,
independently of dollar arrival. Partial/out-of-order arrivals and aged refunds/resends preserve token-sale identity.
Credited dollars convert at the collection's own rate; performance fees split to ManagerFeeVault and Protocol
Recipient, failed transfers become owed. `settleIncomeWithdrawal` completes a round; `withdrawIncome()` pays USDC
without burning shares or flow/Payout Fee. Collection/bridge costs are fund-borne; gas/message fees externally funded.
DEC-145 is in PR #30, landing before the deploy; current main lacks this filter. See the pending-PR section below.

`closeFund` irreversibly enters Closing and stops management accrual (WP-13, PR #21). Manager closure unwind has
72 hours; afterward anyone calls `unwindAllAfterDeadline` to unwind Hub and publish CLOSE to spokes. Manual and
automatic sale costs are recorded: Standard absorption applies, excess reduces the manager's final payment.
`finalizeClosure` requires empty Hub/spoke books, fresh post-Closing spoke reports, resolved transits, no unmatched
arrivals and completed final income collection. It returns existing base-token Operating Cash, pays management
liability and manager shares, freezes `closedSupply`/`closedIdle` and emits `FundClosed`. `exitClosedFund` pays
`shares * closedIdle / closedSupply` immediately, no report or Payout Fee; flow fee remains. Late Closed value
cannot increase frozen Idle and remains sweepable (DEC-167); native Operating Cash is not implemented.

## 4. Swap adapter and signed API routes

`SpokeVault.swap(swapAdapter, tokenIn, tokenOut, amountIn, maxLossBps, route)` is manager-only and pins adapter/endpoints
to the Mandate (PR #13). Manager swaps, income conversion and payout-unwind sales all use the Mandate swap adapter,
not a position adapter executing against the fund's own position pool (DEC-136/143/153).

With empty route, `UniswapV3SwapAdapter` discovers direct-pair tiers 100, 500, 3000, 10000 through the V3 factory.
It skips zero in-range liquidity, caps each quote at 1M gas and skips quotes that do not fill the whole input.
It chooses highest quoted output **before** applying caller maximum (PR #7); it never lets an untrusted caller name
a direct tier through the vault's public swap. The adapter's vault-only `swapDirect` is for internal reuse.

A nonempty route is an EIP-712 API-signed V3 path set: at most 4 weighted legs and 3 hops per leg, weights sum 10,000.
Signature commits endpoints, legs/weights, quoted input, minimum output and deadline under the chain/adapter domain.
Minimum scales to actual input. Routes are replayable until deadline (no single-use nonce); never describe signature
verification as one-shot replay protection. Only endpoints must be Mandate tokens (DEC-173); intermediate tokens may not be.
Unsupported V4/mixed API routes are deferred; arbitrary Universal Router calldata is not passed through.

`maxLossBps` 1..9,999 imposes `spotOut * (10,000 - maxLossBps) / 10,000`; 0 or >=10,000 means no caller maximum.
The stricter of that floor and the signed API minimum applies (DEC-142/178). There is **no contract-mandated oracle floor**
for manager swaps (accepted DEC-129, S-8). API oracle anchoring is optional policy, not a vault invariant.
`Swapped` emits spot output, maximum and enforced minimum (PR #13).

During any guarded Spoke Vault entry, `buildReport` reverts: the input may have left the ledger while output is not
credited. Mint/view valuation cannot price this intermediate NAV; PAYOUT valuation falls back to `lastHubValue`
(PR #13 M-1, integrated PR #15). Other views remain readable; internal report publishing uses `nextReport` rather
than calling the guarded external view. This guard does not make pool spot an oracle or eliminate S-8.

## 5. Across fee rule and transit

`quoteSend` previews; vault-only `buildSend` books the rate. Input/output tokens, recipient and destination are fixed
by the fund's route; the adapter supplies quote timestamp, fill deadline and a zero exclusive relayer. Nonempty quote
data is refused, including at the Core Vault's retained `bridgeData` slot. `sendToHub(amount, kind, bridgeRank)` has
no quote argument. The Across adapter has no API signer/quoter (DEC-158/162/176; PR #2/#12/#13).

Each adapter keeps its own destination-keyed last-3-send rate window, not other users' fees (deposit amounts are logs,
not readable on-chain history). Each missing slot contributes initial 0.08% to the three-slot arithmetic mean;
floor 0.03%, rate cap 1%. Fee is **ceil(inputAmount * rate / 1e18) + 0.03 input-token units**. It must be below input.
An authenticated expiry notes a step at x1.5 of expired rate, clamped to cap; latest expired send can be removed
from the reference window. Expiry can be caused by route size/downtime, so step-up is not proof market fees rose.

The 1% is a **rate cap**, not total-gap cap: the fixed component is additional, and rounding can add a base unit.
This distinction and future native-token route accounting are disclosed in KNOWN-LIMITATIONS. DEC-177's future
600-second signed quote validity is not code in this unsigned MVP.

Capital travels USDC/USDG. Per-send TransitEscrow receives origin refunds; anyone recognizes refund/outcome under
vault checks. Reports reconcile arrival totals and hub-bound ids. Refund timing research observed 57–99 minutes
after fill deadline (2026-10-02 sample), not an SLA; retention is separate from immediate deliverability.

## 6. Wormhole orders and report v5

`OrderCodec` carries UNWIND, CLOSE, COLLECT and targeted ACKNOWLEDGE in a 320-byte static payload.
CLOSE uses the closure identity in `requestId`; UNWIND/COLLECT use fund/request/attempt. Publishing uses instant
consistency 200 and a publish-time + 1-hour deadline. Guardian, Hub emitter, fund, sequence and deadline checks
precede dispatch; consumed UNWIND/CLOSE ids also block fresh-sequence replay. Successful `executeOrder` invokes
the linked executor and publishes a report. Capital travels only via Across, never Wormhole.

Spoke send-home transit identities share **64 slots**, a concurrency limit rather than lifetime-send cap.
UNWIND/CLOSE result entries have a separate capacity of **16**.
`acknowledgeSpokeTransit(spokeIndex, transitId)` is permissionless after full Principal credit or authenticated
refund proof; delivering its targeted Hub ACKNOWLEDGE to spoke `executeOrder` retires the resolved identity.
Hub credit alone does not reclaim capacity: sixty-four undelivered acknowledgements can block later sends/exits.
Anyone can republish/deliver them; the keeper must service the queue. Elapsed time alone is not the Hub publisher's
expiry proof. PR #25 resolved review L-1: retirement uses the shared
`SpokeUnwindTypes.encodeResults(records)` and its 416-byte size assertion, with a regression.

`ReportCodec.VERSION = 5` extends the quantities/principal/income/cumulative counters/Mandate hash/transit payload
with `bytes unwindResults`, `bytes collectionResults` and `bytes32[] refundedTransits`. The last field carries the
last 256 locally recognized send-home refunds, including manual sends (DEC-066/093). It is authenticated by the
same report channel; silence or elapsed time is not refund proof. Off-chain report decoders must use v5; earlier
versions are rejected. The refund ring is informational and never credits a Hub bucket.

`acknowledgeSpokeTransit` publishes an ACKNOWLEDGE order only after the Hub has fully credited the listed amount
(Principal or Income), or accepted explicit refund proof. The spoke resolves any origin, immediately removes its
In-flight Value slot, and ignores repeat acknowledgements. Only unwind/CLOSE sends update unwind result and retry
books; collection result ownership is unchanged. In the current base, the shared send-home capacity is 64 slots
and manual `sendToHub` remains Principal-only: Income is sent by COLLECT orders. Neither limit nor permission changes.
Reports use finalized consistency 202. Receiver checks the authenticated report; hooks are called for accepted reports,
and feed the implemented payout, closure and income settlement books. Rebuild off-chain decoders against v5.

Reporting is permissionless/operation-driven. The API requests reports after deposits; Core deposit does not
atomically publish a cross-chain report (DEC-159 remains partial). Freshness/post-unwind gates are live; Closed
frozen exits are the DEC-163 exception. A replacement relayer can recover keeper downtime, not a spoke that never reports.

### Final-main closure compliance and pending entry-time rule

PR #28 gates Hub exposure by Core Fund State during Closing/Closed, enforces Operating Cash floor/top-up at 0
and disables setters. Terminal spoke Principal/Income dust strictly below 0.50 base-token units is recorded and
excluded from the ledger, leaving it permissionlessly sweepable; late Principal dust needs no second CLOSE.
Closed recovery is checked before Idle credit, preserving the frozen split (B-01/B-02/B-03/G-05).
See [CLOSURE-DUST](security/CLOSURE-DUST.md) for the accepted alpha exception to literal DEC-163.

DEC-145 is **in PR #30, landing before the deploy**, not implemented on this measured main. Its waiting lots use
report/deposit timestamps and resumable capture/payment/merge checkpoints with a shared 64-token-operation budget.
Permissionless `settleHolderIncome(holder)` progresses settlement in Open/Closing/Closed; the PR reports a cold,
maximum-configuration peak of **2,038,401 gas (2.04M)**. This is PR evidence, not a main-baseline measurement.
G-02/G-03/G-04/G-06/G-07 remain accepted only for alpha; [KNOWN-LIMITATIONS](security/KNOWN-LIMITATIONS.md)
is authoritative for their scope. WP-17 is deferred by Rafael.

## 7. Fees, management accrual and Operating Cash

Performance is manager-selected 1000–9000 bps; management is 0–500 bps annually (Slack DEC-186 supersedes DEC-182/184's
10% ceiling). Both are in Mandate, may only decrease; performance cannot fall below 1000, management may fall to 0.
The registry stores only protocol slice 500–5000 bps, default 5000. Flow fee is immutable factory wiring (default
25 bps, maximum 100), on seed/deposit and both Payout modes, not Income Withdrawal. Payout Fee is immutable Mandate
0–1000 bps, Instant-only, retained in Idle (DEC-144/155).

Management liability is booked at valuations while Open:
`increment = min((gross - booked) * managementFeeBps * dt / (10,000 * 365 days), gross - booked)`, rounding down.
Here `gross` is the pre-management-fee Share Assets base used by this helper, not the aggregate Gross Assets view.
The fee never charges its booked liability; net Share Assets/Share Price exclude what is owed. `closeFund` stops
accrual; reductions book at the old rate first. PR #21 pays the liability at finalization; failed transfers remain owed.

**PR #12 L-2 rounding bound:** when a valuation books less than one base unit, the accrual clock is retained.
An entrant can therefore bear less than `(new base / old base)` USDC base units for pre-entry time; at a 100-USDC
old base and approximately 1M-USDC new base, the scale is about 0.01 USDC. This is dust, not exact entry-time isolation.
The bound assumes positive old base; it is a local accrual-rounding bound, not a global loss bound. NatSpec is
intentionally unchanged in this docs-only work package.

The legacy Operating Cash bucket remains **base token**, not native ETH. Nothing spends it in this MVP.
PR #28 enforces floor/top-up at 0 in the Mandate, disables Core/spoke setters and makes internal hooks inert;
this is enforcement, not merely creation-script/harness defaults. Native Operating Cash, refunds and gas
bridge/unwrap are deferred by ruling 2026-10-02 despite DEC-185's MVP requirement. Manager pays own gas (DEC-187);
keeper pays reporting/delivery/order gas. Bridge fees reduce delivered value.

## 8. Security and verification

Internal alpha is not an external audit or a promise of public readiness. The API signer is immutable for each swap
adapter/factory version; deployment defaults ManagerRegistry owner to that signer, but `REGISTRY_OWNER` can differ
and registry ownership can transfer. Signer compromise remains a permanent route-signing risk for those adapters.
Guardian pause/deprecation is immutable adapter wiring, not a guarantee of safe manager execution.

Accepted/unfinished risks, including manager swaps, spot-reference manipulation, stale reports and DEC-145
in PR #30, landing before the deploy, are in [KNOWN-LIMITATIONS](security/KNOWN-LIMITATIONS.md).
Public gates follow unit tests -> invariants -> formal verification -> independent audit (DEC-133/134).
Run build/sizes, format, size completeness and all non-fork tests; fork suites are required when affected.
CI runs one non-fork job and five isolated fork shards; the scenario shard exactly matches `_createForks()` callers.
Fresh counts, gas and margins: [MVP report](reports/2026-10-03-MVP-REPORT.md).
[BASELINE-2026-10-02](security/BASELINE-2026-10-02.md) remains historical evidence only.
