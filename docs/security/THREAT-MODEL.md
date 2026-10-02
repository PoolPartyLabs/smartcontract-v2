# Threat model

Current scope: **`main` `1db9a9d`, 2026-10-02**, through PR #15, DEC-001..DEC-187.
Historic attack measurements retain their original subjects. Current residuals and unfinished requirements:
[KNOWN-LIMITATIONS](KNOWN-LIMITATIONS.md). WP-09/10/12/13 are **in progress**, not complete recovery flows.

What the contracts protect, from whom, and which assumptions the protection rests on. Decision ids are the
specification repository's (`DEC-nnn`); finding ids are the register's ([`FINDINGS.md`](FINDINGS.md)).

## Assets

1. **Shareholder principal**: the USDC behind the Share Price (Share Assets: Idle, the hub Spoke Vault's Unallocated
   Balance and position principal, In-flight Value, each spoke's principal from its last accepted report; DEC-104).
2. **Attributed income**: collected income owed to Shareholders through the per-token accumulator (DEC-014,
   DEC-092), and the fee portions owed to the manager's fee vault and the protocol recipient (DEC-106..DEC-110).
3. **Operating Cash** (DEC-096): a per-chain reserve for the fund's own costs, outside Share Assets.
4. **Liveness**: a Shareholder's ability to leave (Payout) and a manager's ability to move capital home.

## Actors and what they can do

| Actor | Trust | Verbs | Notes |
|---|---|---|---|
| Shareholder | Untrusted | `deposit`, `requestPayout`, `claimPayout`, `withdrawIncome` | May be a contract; may sandwich its own claim (S-1, S-2), enter just in time (S-15) |
| Manager (human or AI agent) | Trusted within the Mandate, key may be compromised or buggy | `allocateToHubSpokeVault`, `sendToSpoke`, `setOperatingCashParameters`, `decreaseManagerFee`, `closeFund`; on Spoke Vault `openPosition`, `increasePosition`, `decreasePosition`, `closePosition`, `collectIncome`, `swap`, `swapCollectedIncome`, `sendToHub` | Mandate fixes venues/endpoints, not mandatory oracle price (S-8 accepted DEC-129); fund transfers follow fixed destinations, fees and manager's shareholder payouts follow their separate rules |
| Adapter guardian | Trusted; one immutable address per factory, so one key acts on every adapter of every fund the factory created | `setPaused`, `deprecate` (irreversible) | Blocks entries only; exits and swaps into the base token always work (DEC-056, DEC-058, S-10). A lost or compromised key deprecates every fund's adapters at once; a rotatable, two-step holder with a delay on `deprecate` is the independent review's recommendation (q8; ruled "ok for now" on 2026-09-29) |
| Manager Registry owner (protocol) | Trusted, `Ownable2Step`; defaults to API signer at deployment | Protocol slice per manager, 500–5,000 bps; ownership transfer | Cannot change Mandate; live slice changes affect manager/protocol fee split; no mutable performance minimum |
| API route signer | Trusted for optional execution minima/routes; immutable per factory/adapter | EIP-712 V3 route signatures, replayable until deadline | Endpoint-only Mandate checks; intermediate hop tokens may be untrusted (DEC-173). Compromise persists for that version |
| Fund Factory deployer | Trusted at deployment | Deploys the factory and its wiring once | Wiring is immutable per factory; a fund is created by anyone as manager |
| Stranger | Untrusted | `deliver` (report VAA), `report`, `attestExpiry`, `recognizeRefund`, `recoverUnlistedArrival`, `claimOwedFees`, `forwardIncomeToCoreVault`, `returnToCoreVault`, `sweepExcess`, Across `handleV3AcrossMessage` through the SpokePool | Every permissionless verb must be safe to call at any time by anyone: it may only move value along a path the ledger already fixed |
| Keeper (off-chain) | Untrusted, needed for liveness | Delivers reports, calls `report()`, relays Across fills | A missing keeper degrades liveness, never safety: mints stop on stale reports (DEC-099), payouts continue (OQ-10) |

## What the Mandate does and does not prevent

The README says a manager acts "inside a Mandate fixed at creation". That holds for venues and destinations, not for
prices, and an investor should be told so (independent review section 9 and question 7, recommendation: disclose
now, add a per-verb band when API co-signing exists, DEC-002).

**The Mandate prevents:** calling any adapter, pool or token outside its closed lists (adapter codehashes pinned);
sending tokens anywhere but the fund's own vaults (bridge recipients fixed); mixing principal and income; entering
through a paused or deprecated adapter; a Payout Fee above 10% (DEC-155), an exclusive
relayer (S-9), a pool LP fee above 1% (M-02), a report lifetime above one day (M-04), more than 16 open positions or
64 listed sends home per Spoke Vault (S-11, H-04).

The Across adapter, not Mandate, caps the variable bridge rate at 1% and adds 0.03 input-token units (DEC-169/177).
Caller quote data is refused. The total fee can exceed 1%; this is not a Mandate total-gap invariant. API route
intermediate tokens are not Mandate-listed; guarded `buildReport` prevents mid-swap NAV minting (PR #13 M-1).

**The Mandate does not prevent** (DEC-027 and DEC-030: no loss limit), measured on `main` by the review's proofs of
concept as ported on 2026-10-01:

| Channel | What a hostile manager, or a leaked manager key, can do | Status |
|---|---|---|
| Execution price | Manager can choose no maximum or collude at manipulated spot; historical attack converted 100,000 USDC into 989-USDC value | Accepted DEC-129, S-8; optional signed API minimum is not a mandatory oracle floor |
| Own-range fees | Wash-trade principal through the fund's own range so it becomes income that pays the performance fee | Bounded by the 1% pool-fee cap; gross versus net is a founder question |
| Bridge fee | Repeated sends or expiry-induced steps consume fund value; caller cannot over-quote | Rule fixed PR #2/#12/#13; rate cap plus fixed fee, not a per-period budget |
| Operating Cash | Move Free Idle into uncapped base-token Operating Cash, outside Share Assets | DEC-130/144 cap answered but native implementation deferred; zero defaults PR #12 are not enforcement |
| Spoke rules | Create the spoke from other rules | Closed: such a spoke is never accepted nor funded (S-6, S-14) |
| Reporting | Freeze the Hub view or delay fresh valuation | Structural caps retained; old v3 26.87M gas is historical, v4 needs remeasurement; stale fallback remains |
| Unpriceable token | Source outage closes mints and can underpay leavers | PR #12 creation nonzero check, no complete reliable-source hierarchy or creation-price cache |

## External dependencies and the trust placed in each

| Dependency | Trusted for | Not trusted for | Where the code checks |
|---|---|---|---|
| Wormhole Core Bridge | Authenticity of a finalized VAA from the fund's own Spoke Vault (guardian quorum; DEC-086, DEC-093) | Ordering or timeliness | `ValueReportReceiver`: emitter chain and address from the Mandate, finalized consistency, strictly increasing sequences, age and future bounds, fund id and `mandateHash` (S-6) |
| Across SpokePool | Executing `depositV3` and calling `handleV3AcrossMessage` only for a real fill | The message content (any depositor may write any message, OQ-01) | Arrivals credited only up to what an accepted report of the origin spoke listed, never the message's claim; a backing check on the hub callback (S-20); exclusivity refused (S-9) |
| Across relayers | Nothing | Filling at all, filling in time | Every send has a 6 h fill window and a keyless per-send escrow as depositor for the refund (DEC-066); refund recognized permissionlessly |
| Chainlink ETH / USD | The price within its staleness bound for mints | Availability during a sequencer outage; payout price age (S-26, S-28, accepted OQ-10 stance) | `ChainlinkPriceSource` reverts on a zero or negative answer and never on age; it returns `updatedAt` and the consumer decides: the Core Vault reverts a mint on a price older than `maxPriceAge`, and a payout uses the answer as is or falls back to the last known valuation |
| Uniswap V4 PoolManager | Executing liquidity operations correctly | Spot composition/price | Price-source valuation for positions; swaps now through V3 adapter; legacy Hub unwind retains oracle/spot 5% floor pending WP-09 |
| V3 factory/QuoterV2/SwapRouter02 | Route execution and quotes | Honest market reference on every tier | Full-fill tier quote/gas bounds, optional maximum/API minimum; third-party manipulated reference residual PR #7 |
| Aave V3 Pool | Principal and interest of a supply position | Liquidity for a withdrawal at any moment (DEC-069 rule, S-27) | Principal and income split by scaled balance and index; an illiquid step makes the unwind revert and the claim is paid from Idle (DEC-068) |
| USDC / USDG issuer | Transfers succeeding for the fund's contracts | A blocklisted fee recipient (S-12) | Failed fee transfers booked as owed and paid later by `claimOwedFees` |

## Design rules that carry the protection

- **Custody never leaves the fund.** Adapters build calls and split principal from income; the vault approves
  exactly one amount, executes with a plain `CALL`, checks its own balance moved by exactly that amount and resets
  the approval (DEC-087, `IBridgeAdapter` NatSpec). Bridge recipients are the fund's own vaults at addresses the
  Mandate fixed.
- **Internal ledger, never `balanceOf`** (DEC-080). A donation changes nothing; it is swept to the excess recipient.
- **Closed lists** (Mandate, DEC-053): adapters, pools, chains, bridges, tokens are immutable per fund. A new version
  is a new fund (DEC-058); no upgradeability, no admin key on a live fund.
- **Whole shares rounded against the actor**, minimum first deposit, non-transferable shares (DEC-035, DEC-061,
  DEC-091).
- **Mints fail closed, payouts stay live** (DEC-099, OQ-10): a stale report or price stops deposits; a claim uses the
  last price and falls back to the last known valuation when a dependency reverts.
- **Reentrancy guards on every value-moving entry**, checks-effects-interactions, SafeERC20, custom errors, no
  `tx.origin`, no `delegatecall` except into the fund's own linked libraries.
- **Report path is permissionless and replay-safe**: anyone delivers; `(emitterChainId, emitterAddress)` from the
  Mandate; strictly increasing Wormhole and report sequences; a report older than the spoke's lifetime is rejected.

## Attack surfaces considered

| Surface | Attacks considered | Outcome |
|---|---|---|
| Share Price at a claim or a deposit | Spot manipulation, just-in-time income entry, near-zero assets, intermediate swap ledger | S-1 fixed, legacy S-2 floor retained, S-15 answered but unfinished, PR #13 M-1 fixed, S-41 dust |
| Transit state machine | Unfilled or late-filled sends, arrivals no report lists, predictable transit ids, evidence-free expiry, refund vs donation, dust sends that bloat reports | S-3, S-4, S-11, S-13, S-20 fixed; residual: a refund later than 3 days reopens the S-3 gap |
| Manager key | Colluding swaps, bridge churn, Operating Cash sink, stranded capital, rogue spoke rules | S-6/S-7/S-9/S-10 fixes retained; S-5 cap deferred, S-8 accepted DEC-129; orders currently revert |
| Fee flow | Blocklisted recipients, fee caps above 100%, transfer failures | S-12, S-17 fixed |
| Liveness | Gas limits on `report()` and VAA delivery, unclaimed reserves, Aave illiquidity, sequencer outage, report lifetime equal to worst-case finality | S-11 fixed; S-19, S-27, S-30, S-31, S-38 accepted rules |
| Deployment | CREATE3 address prediction, factory wiring, spoke creation without the hub's knowledge | S-6, S-14 fixed; S-24, S-25, S-37 acknowledged pending the DEC-089 registry |

## Out of scope for this sweep

- Governance of the protocol keys (registry owner, adapter guardian, factory deployer): assumed honest and secured
  by the operator.
- Compromise of the external protocols themselves (a Wormhole guardian quorum, an Across SpokePool upgrade, an
  Aave or Uniswap bug).
- The off-chain keeper's own security (`local-e2e/` is a development harness).
- Economic attacks on the pools the fund trades (LP-level risks are the manager's market risk, DEC-027, DEC-030).
