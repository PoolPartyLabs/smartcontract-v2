# Spoke unwind orders and settlement

WP-12 is stacked on `chore/pp-sc-chore-wave3-integration` (WP-09 and WP-10).

- DEC-111/120/139: a claim above available Idle publishes one broadcast UNWIND order, with the Hub's proportional
  fraction, request id, attempt, mode and optional maximum. `OrderPublished` identifies its Wormhole sequence.
- DEC-105: Idle and Hub proceeds are earmarked in Payout Reserve; no shares burn until every reached spoke's
  post-unwind report is accepted and its reported Principal send is fully credited. Anyone settles, paying only
  the holder at one consolidated Share Price. Principal arriving before the report stays held apart.
- DEC-118/141: Instant bears all sale losses and its bridge fee; Standard bears only sale losses above 1% per sale.
  Spoke costs are converted to Hub USDC using the spoke base token's price, not assumed to be denominated in USDC.
- DEC-148/151: atomic steps exclude failing exits or sales. Delivered positions and tokens are remembered by stable
  identity. A bridge refusal retains proceeds and costs without selling again. Missing orders can be republished
  after the one-hour deadline; received legs are retained while missing legs retry. A confirmed refund permits
  Partial Payout and a resend of the refunded proceeds, not another fraction of delivered positions.
- DEC-156/158/162: the request maximum independently limits sales and the spoke bridge fee. The Mandate bridge
  adapter fixes the send terms. Failed quotes or bridge calls are reported and leave proceeds backed on the spoke.
- DEC-121/149: CLOSE unwinds 1/1 with Standard Market Costs, returns base-token Operating Cash, and disables new
  positions, increases and manager swaps. Permissionless sends can return late base-token Principal; existing
  `sweepExcess` handles unledgered dust. A failed position remains available to a later CLOSE attempt.
- DEC-157: there is no inactivity switch. Wormhole downtime delays settlement rather than bypassing order checks.

## MVP limits and readings

Report v4 carries the last 16 unwind results. The report hook validates their bounded static encoding and ignores
malformed result blobs rather than refusing the whole value report. Refund recognition, including the report's
automatic refund sweep, updates retained results before publication.

The canonical bridge adapter remains rank zero; fallback routing requires a future order payload extension.
Native Operating Cash and gas reimbursements remain deferred by the ruling of October 2, 2026. Wormhole message
fees are supplied as `msg.value` by the publisher/report executor, including Standard, following the existing MVP
order channel. Standard's bridge fee is paid by Share Assets; no native-fee reimbursement is implemented. This is
a remaining deviation from the requested fund-paid Standard Wormhole fee when the network message fee is nonzero.
The fork suite exercises real Wormhole Cores, Mandate V3 swap adapters, V4 positions and Across deposit terms;
Across destination fills and guardian signing are simulated with test overrides, not real relayer delivery.

No income source files or Core Vault lifecycle/closure files are modified. WP-13 owns Hub closure orchestration.
