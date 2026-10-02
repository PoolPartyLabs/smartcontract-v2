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

Report v4 carries up to 16 unwind results. Unresolved distinct sends cannot be evicted: redundant records of the
same send and records without a send can make room; if all slots identify distinct unresolved sends, another
execution reverts atomically with `OrderResultCapacity`. Distinct refund proofs also remain retained. There is no
Hub arrival acknowledgement in the current order encoding, so a filled send cannot be conclusively retired solely
from elapsed time. This conservative capacity limit is preferable to silently losing a transit identity.
The report hook validates their bounded static encoding and ignores
malformed result blobs rather than refusing the whole value report. Refund recognition, including the report's
automatic refund sweep, updates retained results before publication.

The `OrderResult` ABI remains exactly twelve static words (384 bytes per entry), with unchanged field order and
types, including CLOSE results adopted by WP-13. UNWIND and CLOSE order ids are consumed before executor calls,
independently of Wormhole sequence. COLLECT retains its existing round-id resend semantics (WP-10 ownership).
Sale costs are cumulative per request/spoke, consumed once on partial settlement, including refused and refunded
legs; an unincurred refunded bridge fee is excluded. A resend reports only the cumulative difference still owed.
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
