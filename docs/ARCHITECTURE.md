# Architecture: merged internal-alpha baseline

Baseline: `main` at **`1db9a9d`**, 2026-10-02, through PR #15. Governing register: **DEC-001..DEC-187**;
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
| CoreVault | CoreVaultLogic, CoreVaultTransitLogic, CoreVaultIncomeLogic, CoreVaultPayoutLogic |
| CoreVaultLogic | CoreVaultIncomeLogic |
| CoreVaultTransitLogic | CoreVaultLogic, CoreVaultIncomeLogic, CoreVaultPayoutLogic |
| CoreVaultPayoutLogic | CoreVaultLogic, CoreVaultIncomeLogic |
| SpokeVault | SpokeCrossChainLib, SpokeUnwindLib, SpokeIncomeLib |

`CoreVaultIncomeLogic` has no linked-library dependency back into callers (`CoreVaultLogic.payFee` is internal/inlined).
The dependency order avoids a circular CREATE2 address dependency. `SpokeLedger`, `OrderCodec`, `OrderVerifier`,
`BridgeFeeRule`, `ReportCodec`, `IncomeAccumulator`, `ShareMath` and `DollarIncomeIndex` are internal/inlined libraries,
not linked runtime deployments. **DollarIncomeIndex is not used by the live income book yet.**

`FactoryDeployment` deploys libraries once per chain and links the vault creation code and dependent libraries.
Their addresses/code are part of each immutable fund's trust surface. External library calls execute in vault storage
and emit at the vault address; adapter calls do not delegatecall untrusted adapter code. There is no proxy or upgrade
path (DEC-022/058/131/183). Changing linked code requires a new factory/fund version. Publish all library addresses
and verify links on both chains; keep each runtime <=24,576 bytes. See [size baseline](security/BASELINE-2026-10-02.md).

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
but the new hooks preserve collection-time behavior where no recognition previously existed (PR #15).

Manager sends capital through a ranked Mandate bridge adapter to the fund's fixed destination. A spoke must first
have an accepted report. Manager opens/increases/reduces/closes positions through allowed position adapters and pools.
Principal returned on Hub can move to Core Vault Idle; spoke principal returns through Across. Ledger checks enforce
actual input debit/output receipt around swaps, not merely adapter return values.

Existing Payout Requests and payments remain in `CoreVaultPayout`/`CoreVaultPayoutLogic`; Idle is used first, then
the interim Hub unwind in `SpokeUnwindLib`, with a 2% target buffer and legacy 5% floor against the higher of spot/oracle.
Its payout sale still uses the position's own pool when paired with USDC, otherwise a caller-hinted Mandate pool,
through `SpokeLedger.poolSwap` and the position adapter's `swapExactInput`, not the Mandate swap adapter.
Migration to that swap adapter is pending WP-09, PR #19 (DEC-136/143/153).
The legacy PAYOUT valuation fallback still uses cached values when a dependency fails. These are **not** the new
DEC-137/140/141/148/160 behavior. **WP-09 proportional unwind — in progress.**

Current income uses `CoreVaultIncomeTypes.Book.index: IncomeAccumulator.State`, a per-token Q128 collection-time index.
Collected income reaching Hub is split: performance fee, protocol slice of that fee, and net holder income. Protocol
fees pay Protocol Recipient, manager portion pays ManagerFeeVault, failed fee transfers become owed. Hub collection can
still pay the collected token; the manager's `swapCollectedIncome` verb remains. This does not yet implement all-USDC
cross-chain collection or recognition-time entitlement. **WP-10 income dollar index — in progress.**

`closeFund` exists: it books management accrual, moves Open -> Closing and records timestamp. Closing refuses deposits,
new requests and claims; income remains accessible. Finalization, Closed exits and a frozen record do not exist on this
baseline. **WP-13 closure — in progress.**

## 4. Swap adapter and signed API routes

`SpokeVault.swap(swapAdapter, tokenIn, tokenOut, amountIn, maxLossBps, route)` is manager-only and pins adapter/endpoints
to the Mandate (PR #13). This manager entry point and `swapCollectedIncome` use the Mandate swap adapter,
not a position adapter executing against the fund's own position pool. The interim payout-unwind sale is the
exception described above; its migration remains pending WP-09, PR #19.

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

`OrderCodec` v1 encodes UNWIND, CLOSE or COLLECT, fund id, request id, attempt, deadline, fraction, maximum and Payout
mode (320-byte static payload). Order id hashes kind/fund/request/attempt. Publishing uses instant consistency 200
and overwrites deadline to publish time + 1 hour (engineering default). Destination is never a caller-selected wallet.
`OrderVerifier` checks guardian validity, Hub emitter chain/address, fund id, newer sequence and deadline; gaps accepted,
older/replayed orders rejected. Retry completion is not implemented merely because `attempt` is encoded.

`SpokeVault.executeOrder` exists and verifies through linked `SpokeUnwindLib.acceptOrder`, then dispatches the kind.
**All three executors currently revert `OrderKindNotSupported`**, including linked `SpokeIncomeLib` COLLECT stub;
the transaction rolls back its cursor. It cannot unwind, collect, or close today. The successful-dispatch report/event
path and `OrderPublished` declaration are foundations only. **WP-12 spoke orders — in progress.**

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
but they do not implement result settlement or the dollar index. Rebuild off-chain decoders against v5.

Reporting is permissionless and the API helper requests reports after deposits; Core deposit itself does not atomically
publish a new report. Burn-wide DEC-160 freshness is unfinished. No inactivity switch exists (DEC-157).

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
accrual; reductions book at the old rate first. Closure payment remains WP-13 in progress.

**PR #12 L-2 rounding bound:** when a valuation books less than one base unit, the accrual clock is retained.
An entrant can therefore bear less than `(new base / old base)` USDC base units for pre-entry time; at a 100-USDC
old base and approximately 1M-USDC new base, the scale is about 0.01 USDC. This is dust, not exact entry-time isolation.
The bound assumes positive old base; it is a local accrual-rounding bound, not a global loss bound. NatSpec is
intentionally unchanged in this docs-only work package.

The existing Operating Cash bucket remains **base token**, not native ETH, and has no native 0.5-ETH cap. Nothing
spends it in this MVP. `CreateFund.s.sol` and the harness default floor/top-up to 0 (PR #12); this is not an enforced
factory-wide zero setting, since managers can change existing parameters. Native Operating Cash, refunds and gas
bridge/unwrap are deferred by ruling 2026-10-02 despite DEC-185's MVP requirement. Manager pays own gas (DEC-187);
keeper pays reporting/delivery/order gas. Bridge fees reduce delivered value.

## 8. Security and verification

Internal alpha is not an external audit or a promise of public readiness. The API signer is immutable for each swap
adapter/factory version; deployment defaults ManagerRegistry owner to that signer, but `REGISTRY_OWNER` can differ
and registry ownership can transfer. Signer compromise remains a permanent route-signing risk for those adapters.
Guardian pause/deprecation is immutable adapter wiring, not a guarantee of safe manager execution.

Accepted/unfinished risks, including manager swaps, spot-reference manipulation, stale reports, missing dollar
attribution/closure and zero-default Operating Cash, are in [KNOWN-LIMITATIONS](security/KNOWN-LIMITATIONS.md).
Public gates follow unit tests -> invariants -> formal verification -> independent audit (DEC-133/134).
Run build/sizes, format, size completeness and all non-fork tests; fork suites are required when affected.
Baseline evidence and exact measured runtime margins are in [BASELINE-2026-10-02](security/BASELINE-2026-10-02.md).
