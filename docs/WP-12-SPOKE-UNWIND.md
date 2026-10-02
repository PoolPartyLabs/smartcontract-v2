# Spoke unwind orders and settlement

WP-12 is stacked on `chore/pp-sc-chore-wave3-integration` (WP-09 and WP-10).

- DEC-111/120/139: a claim above available Idle publishes one broadcast UNWIND order, with the Hub's proportional
  fraction, request id, attempt, mode and optional maximum. `OrderPublished` identifies its Wormhole sequence.
- DEC-105: Idle, Hub proceeds and credited spoke Principal are earmarked in Payout Reserve; no shares burn until
  every reached spoke's post-unwind report is accepted and its reported Principal send is fully credited. Anyone settles, paying only
  the holder at one consolidated Share Price. Principal arriving before the report stays held apart.
- DEC-118/141: Instant bears all sale losses and its bridge fee; Standard bears only sale losses above 1% per sale.
  Spoke costs are converted to Hub USDC using the spoke base token's price, not assumed to be denominated in USDC.
- DEC-148/151: atomic steps exclude failing exits or sales. Delivered positions and tokens are remembered by stable
  identity. A bridge refusal retains proceeds and costs without selling again. Missing orders can be republished
  after the one-hour deadline, subject to fresh reports; every unresolved transit is retained while missing legs
  retry. A confirmed refund permits Partial Payout and a resend, not another fraction of delivered positions.
- DEC-156/158/162: the request maximum independently limits sales and the spoke bridge fee. The Mandate bridge
  adapter fixes the send terms. Failed quotes or bridge calls are reported and leave proceeds backed on the spoke.
- DEC-121/149: CLOSE unwinds 1/1 with Standard Market Costs, returns base-token Operating Cash, and disables new
  positions, increases and manager swaps. Permissionless sends can return late base-token Principal; existing
  `sweepExcess` handles unledgered dust. A failed position remains available to a later CLOSE attempt.
- DEC-157/160: there is no inactivity switch. A spoke that never answers blocks exits requiring its fresh report;
  expiry is not proof of Principal delivery and never bypasses settlement checks.

## MVP limits and readings

Report v4 carries up to 16 unresolved unwind results. Unresolved distinct sends cannot be evicted: redundant records
of the same send and records without a send can make room; if all slots identify distinct unresolved sends, another
execution reverts atomically with `OrderResultCapacity`. This is a concurrency bound, not a lifetime-send bound.
Anyone calls `CoreVault.acknowledgeSpokeTransit(spokeIndex, transitId)` after the Hub has fully credited Principal or
accepted its refund proof, then delivers the resulting Wormhole VAA to `SpokeVault.executeOrder`. The targeted
`ACKNOWLEDGE` order (kind 4) uses the unchanged order layout: `requestId` names the transit, `fracNum` names the EVM
spoke chain, and `fracDen` names its resolved `TransitState`. Only the authenticated Core Vault can retire a transit.
The spoke removes every report record naming it and its request's active transit identity; recovered refunds remain
earmarked for retries. A refund proof remains publishable until the Hub acknowledges it, so an unseen proof is never
silently dropped. Filled sends never retire just because their deadline passed. The spoke also handles an explicit
authenticated `ExpiryAttested` outcome and permits a late refund afterward; the current Hub publisher chooses only
full Principal credit or accepted refund proof, never a time-only expiry.
The report hook validates their bounded static encoding and ignores
malformed result blobs rather than refusing the whole value report. Refund recognition, including the report's
automatic refund sweep, updates retained results before publication.

The `OrderResult` ABI remains exactly twelve static words (384 bytes per entry), with unchanged field order and
types, including CLOSE results adopted by WP-13. UNWIND and CLOSE order ids are consumed before executor calls,
independently of Wormhole sequence. COLLECT retains its existing round-id resend semantics (WP-10 ownership).
Sale costs are cumulative per request/spoke, consumed once on partial settlement, including refused and refunded
legs; an unincurred refunded bridge fee is excluded. A resend reports only the cumulative difference still owed.
Refund recognition reduces each send's fee once in every newer retained cumulative result and in pending costs.
Hub Instant Payout accounting uses cumulative Market Costs plus each distinct non-refunded transit's bridge fee,
rather than trusting a later result's cumulative fee total. Repeated reports and partial settlements reuse the
existing paid-cost cursors; Standard Payout sale-cost accounting is unchanged.
Instant's temporary reserve releases after partial settlement; Standard's outstanding reservation remains intact.
Hub base-token cash that fully covers a new request skips spoke publication entirely.

The canonical bridge adapter remains rank zero; fallback routing requires a future order payload extension.
Native Operating Cash and gas reimbursements remain deferred by the ruling of October 2, 2026. Wormhole message
fees are supplied as `msg.value` by the publisher/report executor, including Standard, following the existing MVP
order channel. Standard's bridge fee is paid by Share Assets; no native-fee reimbursement is implemented. This is
a remaining deviation from the requested fund-paid Standard Wormhole fee when the network message fee is nonzero.
The fork suite exercises real Wormhole Cores, Mandate V3 swap adapters, V4 positions and Across deposit terms;
Across destination fills and guardian signing are simulated with test overrides, not real relayer delivery.

No income source files or Core Vault lifecycle/closure files are modified. WP-13 owns Hub closure orchestration.

## Round-1 validation

The six findings have 15 failing-before regressions plus one passing cost-conservation guard; all 16 pass after
the fixes. Build sizes, formatting and size tests pass. Non-fork: 1,254 tests in 173 suites. Fork: 219 tests in
53 suites, including the two-fork order/execution/Principal-credit/settlement scenario. No new fork file was added.

| Artifact | Before bytes / margin | After bytes / margin |
| --- | ---: | ---: |
| CoreVault | 22,745 / 1,831 | 22,745 / 1,831 |
| CoreVaultPayoutLogic | 17,950 / 6,626 | 20,447 / 4,129 |
| CoreVaultTransitLogic | 14,227 / 10,349 | 14,448 / 10,128 |
| SpokeVault | 23,444 / 1,132 | 23,444 / 1,132 |
| SpokeUnwindLib | 20,858 / 3,718 | 21,446 / 3,130 |

Every production contract and linked library remains below 24,576 bytes; no production margin is below 1,000.
Test-only SpokeVaultOrderHarness remains 24,556 bytes, margin 20 (flagged).

## Round-2 validation

Commits `907d96d` (regressions), `5cf8982` (authenticated retirement), and `374ab85` (refund-aware costs) address
H1-R2 and M2-R2. Nine focused regressions cover older refunds with a newer send, repeated reports and resend,
17 refunded historical sends, 20 credited historical sends ending in CLOSE, a full 16-send unresolved window,
rejected seventeenth concurrent send, retirement followed by another UNWIND and CLOSE, authenticated expiry with a
late refund, untrusted emitters, and Hub acknowledgements gated on full credit or accepted refund proof.
The original Hub and spoke fee probes fail before the fixes (120 versus 110 USDC and 6 versus 5 USDG); the new
retirement-protocol regression fails before the fix with `UnknownOrderKind(4)`. All nine pass afterward and the
round-1 regressions remain green. The report ABI remains twelve words / 384 bytes per OrderResult.

Full green bar: build sizes and formatting pass; size suite 3/3; non-fork 1,286 tests in 175 suites; fork 219 tests
in 53 suites with `-j 4`; the two-fork settlement scenario also passes separately (1/1). No new fork file or shared
fork fixture change. Destination fills and guardian signing retain the documented simulations.

| Artifact | Round-1 bytes / margin | Round-2 bytes / margin |
| --- | ---: | ---: |
| CoreVault | 22,745 / 1,831 | 23,013 / 1,563 |
| CoreVaultPayoutLogic | 20,447 / 4,129 | 21,501 / 3,075 |
| CoreVaultTransitLogic | 14,448 / 10,128 | 14,448 / 10,128 |
| SpokeVault | 23,444 / 1,132 | 23,572 / 1,004 |
| SpokeUnwindLib | 21,446 / 3,130 | 23,175 / 1,401 |
| SpokeCrossChainLib | Not recorded | 11,991 / 12,585 |
| SpokeVaultOrderHarness (test only) | 24,556 / 20 | 24,320 / 256 |

Every production contract and linked library fits EIP-170; none has a margin below 1,000 bytes. SpokeVault's
1,004-byte margin is tight. The test-only harness's 256-byte margin is flagged; its recorder helpers move into its
existing linked library without changing tested dispatch behavior.

Plan deviation: add an authenticated retirement instruction instead of retaining sixteen historical results forever.
Executors must deliver acknowledgements to reclaim capacity; an undelivered acknowledgement can be republished,
and an unseen refund proof remains retained. No new spec divergence; the DEC-157/160 responsive-report limitation
and deferred Standard native-fee reimbursement still apply. PR #21 must incorporate these commits and revalidate
its combined closure sizes; OrderResult encoding is unchanged.
