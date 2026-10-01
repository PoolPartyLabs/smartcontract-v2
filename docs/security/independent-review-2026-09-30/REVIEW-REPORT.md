# Pool Party v2 smart contracts: independent review of `smartcontract-v2` at `e5c778a`

Date: 2026-09-30. Repository: `github.com/PoolPartyLabs/smartcontract-v2`, branch `main`, commit
`e5c778a97c70eb07df8acbf1f1037f465a6ffb63` (45 files under `src/`, 4 under `script/`, 9,546 lines). Buildathon MVP,
nothing deployed.

The founder asked for a verification of the whole flow and of the integration between the contracts, and for a
judgement on three things: whether best practices were adopted, whether the checks in the contracts are correct, and
whether there are logic errors. This report is the consolidated answer. The nine working reports it is built from are
in `reports/`, every proof-of-concept test is in `poc/`, and the tool outputs are in `raw/`.

Nothing in this report is a decision. Where a fix involves a product rule, the report states the options and a
recommendation; the founder decides.

## 1. Verdict

**The contracts must not hold investor money as they are.** The code is careful where it was looked at module by
module: the share arithmetic, the income accumulator, the internal ledgers, the adapters against the real protocols,
CREATE3 and the report verification all hold, and they are listed in section 10. The problems are where modules meet
and where a price enters:

1. **A shareholder can take the fund's Uniswap V4 positions in one transaction.** The automatic unwind that a payout
   claim triggers values the position, sizes the exit and floors its swap at the pool's spot price, with no oracle
   comparison. On a fund created by the real factory on an Arbitrum fork, a holder of one share (a 2 USDC deposit)
   closed a 100,000 USDC position and kept 99,496 USDC; the round trip through the real pool cost about 200 USDC
   (C-01).
2. **The Share Price follows the pool's spot price.** Position principal is counted at the spot composition times
   the oracle price, which is lowest when spot equals oracle, so any swap inflates Share Assets. It costs nothing but
   the pool fee inside one Uniswap unlock, and on a spoke anyone can freeze the distortion into a report (C-02).
3. **The cross-chain books lose or double value in four reachable situations** (H-01 to H-04), and the manager can
   provoke all four.
4. **The hub sends capital to a Spoke Vault that nothing has shown to exist or to run the hub's Mandate** (H-05,
   H-06).
5. **Two controls that exist to protect investors turn against them**: deprecating an adapter strands principal
   (H-07), and the Operating Cash parameters let the manager move all free capital into a bucket with no exit
   (H-08).

Counts after merging duplicates across reports: **Critical 2, High 8, Medium 5, Low 12, Informational 17**, plus the
process findings of section 11. Every Critical and High finding has a passing proof-of-concept test, and each was
re-verified by the coordinator by reading the code and re-running the test (section 2).

Most of these findings trace back to questions the specification still lists as open (QA3, FF-OQ-1, OQ-09, spending
of Operating Cash). The repository's own rule is that an undecided case takes the conservative path and reverts
(`README.md`, contributing rule 2). In each of these cases the code took a working path instead, and the consequence
was not written down. That is the pattern to fix, beyond the individual findings.

## 2. Scope and method

**Scope.** Everything under `src/` and `script/` at the commit above, the test suite as evidence of what is covered,
the CI workflow and the repository's own documents as claims to test. Out of scope: the dependencies in `lib/` beyond
how the code uses them, off-chain components (keepers, the API), and the economics of the product.

**How the work was done.** Ten agents, never more than two at a time, coordinated by one model that did not review
modules itself but verified what came back:

| # | Agent | Model | Output |
|---|---|---|---|
| 1 | Toolchain baseline: build, tests, fork tests, Slither, Aderyn, Solhint, coverage, inventories, CI | Sonnet | `reports/01-baseline.md`, `raw/` |
| 2 | Core Vault: shares, deposit, payout, value bases, Operating Cash | Opus | `reports/02-core-vault-shares-payout.md` |
| 3 | Core Vault: income, fee split, transit state machine, report application, sweep | Opus | `reports/03-core-vault-income-transit.md` |
| 4 | Spoke Vault: ledger, positions, swaps, automatic unwind, hub-side legs | Opus | `reports/04-spoke-vault-positions-unwind.md` |
| 5 | Spoke cross-chain side, report codec, receiver, price source | Opus | `reports/05-spoke-crosschain-report-receiver.md` |
| 6 | Adapters against the real protocols: Uniswap V4, Aave V3, Across | Opus | `reports/06-adapters.md` |
| 7 | Factory, Mandate, CREATE3, deployment scripts | Opus | `reports/07-factory-mandate-deployment.md` |
| 8 | Integration, price and unwind family, on a factory-created fund on forks; fix options | Opus | `reports/08-integration-price-unwind.md` |
| 9 | Integration, cross-chain family on forks; value-conservation walk; why the tests missed it | Opus | `reports/09-integration-crosschain-tests.md` |

All reviewers worked from one brief (`reports/00-brief-common.md`): read every line in scope; every finding needs
`path:line`, a concrete scenario with actors and amounts, and a fix; every Critical, High or Medium finding needs a
Foundry test that asserts the wrong behaviour and would fail if the bug were fixed; a suspicion that was refuted goes
into a "checked and found correct" list with the reason.

**What the coordinator verified.** For every Critical and High finding, and for most Medium ones, the cited code was
read. All 121 proof-of-concept tests (64 unit, 57 fork) were re-run by the coordinator in a separate working copy,
the fork tests at fresh blocks, and all pass; the merged `poc/` tree compiles in a clean checkout of `e5c778a`. Three
facts were also checked directly on chain with read-only calls: both chains execute the Cancun opcodes the code needs
(`MCOPY`, transient storage); the per-transaction gas limit is 32,000,000 on Arbitrum One and on Robinhood Chain
(`ArbGasInfo.getGasAccountingParams()`); and the live Robinhood Across SpokePool fills to an address without code and
skips the message callback.

**How "already known" was treated.** `docs/OPEN-QUESTIONS.md` and `docs/REVIEW-LOG-2026-09-29.md` record accepted
stances. A documented stance is not a finding. It became one only when the code does not do what the stance says,
when the stance has a consequence the documents do not disclose, when two stances contradict each other in the code,
or when a decision is violated and no open question covers it. Each finding says which.

**Limits.** The reviewers and the coordinator are AI models; this is not the external manual audit of the founder's
pipeline (unit and integration, invariant fuzzing, formal verification, manual audit) and does not replace it. No
formal verification was run. Flash loans are represented by dealing WETH to the attacker and checking it back;
Across fills are simulated the way the project's own fork tests do (deal the output token, call from the SpokePool
address, or call the real `fillRelay`); Wormhole VAAs are signed with the SDK's `WormholeOverride`. Transaction
ordering by the Arbitrum sequencer was not modelled. Severities follow the scale in the brief and are the
coordinator's, not the founder's.

## 3. Findings at a glance

"Proven on" says where the passing test runs: **unit** (real fund contracts over mocks), **fork** (real protocols,
hand-wired fund), **integrated** (fund created by the real `FundFactory` with the scripts' Mandate, real protocols on
both forks).

| ID | Severity | Finding | Proven on | Documented before? |
|---|---|---|---|---|
| C-01 | Critical | The automatic unwind is valued, sized and sold at spot: a shareholder takes the fund's V4 positions | integrated | QA3 open; consequence not disclosed |
| C-02 | Critical | Share Price counts V4 principal at the spot composition: a swap moves the mint and burn price, on the hub live and on a spoke through `report()` | integrated | QA3 and Q57 (b) open; consequence not disclosed |
| H-01 | High | A transfer home that is not filled is in no value base until its refund is reported | integrated (live refund leaf) | No |
| H-02 | High | A transfer home that was filled is lost for good when no report lists it in time | integrated (live fill) | No (CV-OQ-5 covers strangers' arrivals only) |
| H-03 | High | The Spoke Cap stops counting a transit that arrived once its expiry is attested on time alone | integrated (live fills) | Partly (OQ-09 calls it a liveness cost) |
| H-04 | High | The manager can make every report of a spoke undeliverable | integrated (real Wormhole Cores) | No |
| H-05 | High | The hub sends capital to a Spoke Vault that nothing shows exists | integrated (live fill) | No |
| H-06 | High | A spoke created from a Mandate other than the hub's is accepted by the hub end to end | integrated | FF-OQ-1 names the residual, not its size |
| H-07 | High | Deprecating the V4 adapter blocks the unwind and strands non-USDC principal for good | integrated | OQ-04 stance; consequence not disclosed |
| H-08 | High | Operating Cash: unbounded parameters and no outflow, on hub and spoke | integrated | Partly (DEC-100 accepts no cap on the floor) |
| M-01 | Medium | The bridge fee bound becomes manager revenue through the exclusive relayer, and the Mandate accepts 100% | integrated (live exclusivity) | No |
| M-02 | Medium | Principal becomes performance-fee income through the fund's own range; a Mandate pool's LP fee is unbounded | integrated | FV-16 covers third-party `donate` only |
| M-03 | Medium | A Mandate token the price source cannot price closes mints and is worth 0 in every payout | unit | CS-OQ-4 understates it |
| M-04 | Medium | A spoke's report lifetime and Wormhole chain id are unchecked manager inputs | unit | No |
| M-05 | Medium | If Across shortens its fill-deadline buffer, every route stops working for good | unit | Partly |
| L-01 to L-12 | Low | Section 7 | mixed | mixed |
| I-01 to I-17 | Info | Section 8 | n/a | mixed |

## 4. Critical findings

### C-01. The automatic unwind is valued, sized and sold at the pool's spot price

- **Where.** `src/spoke/SpokeVault.sol:842-865` (`_unwindPosition`), `:898-901` (`_unwindValue`), `:905-921`
  (`_unwindSwap`, floor at 95% of `spotQuote`, constant at `:55`); `src/adapters/UniswapV4Adapter.sol:316-328`
  (`unwindExitParams`, minimums 0), `:333-340` (`spotQuote` reads `slot0`), `:621-637` (`_principal` reads `slot0`);
  entered from `src/core/CoreVault.sol:157-162` and `:204-214`.
- **Rule at stake.** DEC-067 (hub LP valued at a guarded pool price), DEC-069 and DEC-081 (unwind only what is
  missing, plus 2%), DEC-097 (the fund bears the margin's market cost, not a transfer to a third party).
- **What happens.** When a claim needs more than Free Idle, the hub Spoke Vault walks the Mandate's unwind order.
  For each position it (1) values the principal at the pool's current `slot0`, (2) exits the share of it the
  shortfall needs and closes the whole position when the spot value does not exceed the shortfall, with minimum
  amounts of zero, and (3) swaps the non-USDC proceeds in the same pool with a minimum of 95% of that same spot.
  Nothing compares spot with the oracle the Core Vault already reads. The claimant chooses the moment and can act
  before and after the claim in the same transaction: push the WETH price down (the position becomes all WETH and
  nearly worthless at spot), claim (the vault closes the position and sells the WETH into liquidity the attacker
  placed), take the liquidity back and restore the price. The loop continues to the next position while the target
  is not reached, so one claim empties every price-dependent position in pools the attacker can move.
- **Numbers, on a fund created by the real factory (Arbitrum fork, real pool).** Position 100,000 USDC, Free Idle
  25,000, attacker stake 30,000: the whole position closes whether its range is ±5%, ±10% or ±50%; the other holder
  loses about 88,900 and the attacker gains about 88,300; the round trip costs 183 to 211 USDC and about 3.3M gas.
  With Free Idle at 0, which is the state right after the manager allocates everything, **one share is enough**:
  +99,496 USDC, with an Instant or a Standard request. One claim closed positions in two Mandate pools. The attack
  does not need a thin pool: with liquidity as deep as Arbitrum's V3 WETH/USDC pool added, a 100,000 position still
  yields +60,966 (a 10,000 position loses the attacker 19,438). The earlier hand-wired fork test took a 200,000
  position with a 10,000 stake for a profit of 189,994.
- **Preconditions.** The fund holds a V4 position in its unwind order, and the attacker's claim exceeds Free Idle.
  The stake must predate the manager's allocation, because a deposit adds to Free Idle one for one. Capital to move
  the pool comes from a flash loan (V4 flash accounting cannot wrap the claim, so outside capital is needed). A
  third party can do the same around someone else's claim if it controls transaction ordering (+99,422 in the test).
- **Proof.** `poc/test/review/integration-price/UnwindAttackFork.t.sol` (16 tests),
  `poc/test/review/spoke-a/C01_UnwindAtManipulatedSpotFork.t.sol`, `poc/test/review/spoke-a/C01_UnwindAtManipulatedSpot.t.sol`.
- **Documented before?** The QA3 row says the floor "bounds execution against the price at the time of the swap, not
  against an oracle". It does not say that the claimant sets that price and takes whole positions whatever the size
  of the claim.
- **Recommendation.** Section 13, package A. No single option closes it (see C-02 and the table in section 12).

### C-02. Share Price counts V4 principal at the spot composition, so a swap moves the mint and burn price

- **Where.** `src/core/CoreVaultLogic.sol:219-248` (`_hubValue`, `_positionsPrincipal`), `:271-284`
  (`_spokePrincipal`), `:307-317` (`_usdcValue`); amounts from `src/adapters/UniswapV4Adapter.sol:266-284` and
  `:621-637` through `src/spoke/SpokeCrossChainLib.sol:160`; consumed at `src/core/CoreVault.sol:69` (deposit),
  `:105` (request) and `:185` (claim).
- **Rule at stake.** DEC-067, DEC-084 and DEC-105 (one Share Price for mint and burn), the ARCHITECTURE §7 invariant
  that a third party never moves the Share Price.
- **What happens.** The hub adds `principal0 × price(token0) + principal1 × price(token1)`, where the principals are
  what the position would return at the pool's current price and the prices are Chainlink's. For a concentrated
  position that sum has its minimum when spot equals oracle, so moving the spot in either direction raises Share
  Assets although no value entered the fund.
  - **Hub.** Every deposit, request and claim reads it live. An Idle-paid claim does not unlock the PoolManager, so
    the whole manipulation (swap, claim, swap back) runs inside one Uniswap unlock with no capital beyond the pool
    fee.
  - **Spoke.** `report()` is permissionless. A stranger moves the pool, calls `report()` and moves it back; the
    report carries the distorted composition to the hub, where mints use it until it ages out (1,588 s) and payouts
    use it until a newer report is accepted, with no age limit. A keeper cannot pre-empt it, because the attacker's
    report finalizes no later than any report published after it.
  - **Fallback.** `lastHubValue`, the value a payout falls back to when the hub read fails, is stored from the same
    spot read, so a 2 USDC deposit at a pushed price poisons it (report 08, L-01).
- **Numbers, on the factory-created fund.** Position 100,000 in a fund of 299,100: the Share Price rises 0.456%,
  0.956% and 8.487% for ±5%, ±10% and ±50% ranges. A 40,000 claim nets +48.87, +213.52 and +2,764.56 after fees
  (break-even claim about 29,100, 17,300 and 4,300). A sandwiched 100,000 deposit loses 710. Spoke variant: the
  stranger's round trip cost 230.58 USDG, the Share Price rose 0.77%, a 50,000 claim gained 381 and a 100,000 deposit
  lost 700. The gain scales with the size of the claim and with the share of the fund held in wide or one-sided
  ranges.
- **Proof.** `poc/test/review/integration-price/SharePriceSpotFork.t.sol` (5), `SpokeReportSpotFork.t.sol`,
  `FallbackPoisonFork.t.sol`; `poc/test/review/core-a/C01_SpotCompositionValuation.t.sol`.
- **Documented before?** No. The Q57 (b) stance prices report quantities with Chainlink but does not say the
  quantities are spot-derived and movable within a block.
- **Recommendation.** Value position principal at the composition implied by the oracle price
  (`getAmountsForLiquidity` at the oracle's sqrt price); the report already carries ticks and liquidity, so the hub
  can recompute spoke positions itself. Section 13, package A.

## 5. High findings

### H-01. A transfer home that is not filled is in no value base until its refund is reported

- **Where.** `src/spoke/SpokeCrossChainLib.sol:300-302` (`_stillInFlight`), `:103-106`, `:184`;
  `src/core/CoreVaultLogic.sol:292-303` (`_returnLeg` reads only the latest report).
- **What happens.** A spoke-to-hub Principal transfer counts in Share Assets only while the spoke's latest report
  lists it, and the spoke stops listing it at `fillDeadline + maxReportAge`, presumed filled. If it was not filled,
  Across refunds the escrow 55 to 90 minutes after the deadline, and the amount re-enters the books only after
  `recognizeRefund` on the spoke and a delivered report. In between it is nowhere: Share Assets drop by the whole
  amount and jump back later. Mints in the window are underpriced and payouts underpay.
- **Who can cause it.** It happens by itself whenever no relayer fills the USDG to USDC route. The manager can force
  it by naming an exclusive relayer that never fills (see M-01).
- **Numbers.** Unit: with half of a 200,000 fund in the transfer, a 100,000 deposit made in the window is worth
  149,783 after the refund; the existing holder goes from 199,440 to 149,407. Integrated, with the live refund leaf:
  Share Price 0.599 in the window against 0.749 after the refund is reported; the window depositor gains 24.7% and
  the existing holder loses 25%. Measured on chain, an expired deposit's refund lands about 53 to 107 minutes after
  the deadline (the specification says 55 to 90), so the window is roughly 25 to 85 minutes when keepers act at once,
  and open-ended if nobody calls the permissionless `recognizeRefund`.
- **Proof.** `poc/test/review/core-a/H02_ReturnLegDroppedBeforeRefund.t.sol` (reports built by the real Spoke Vault);
  `poc/test/review/integration-xchain/Fork_TransferHome.t.sol`.
- **Violates.** DEC-104 (no recognized value outside all bases). Not documented: OQ-09 describes the pruning, not
  its effect on Share Assets.
- **Recommendation.** The hub keeps its own book: it already stores `listed` and `credited` per transfer, so it can
  keep counting `listed − credited` for a Principal transfer it has seen until it is credited or the spoke reports
  its refund (package C).

### H-02. A transfer home that was filled is lost for good when no report lists it in time

- **Where.** `src/core/CoreVaultLogic.sol:497-502` (arrival before any listing goes to `pending` and
  `unmatchedArrivals`), `:463-482` (`_matchReturnLeg` releases only ids a later report lists);
  `src/core/CoreVaultBase.sol:324-327` (`unmatchedArrivals` is ledger, so never swept);
  `src/spoke/SpokeCrossChainLib.sol:298-302`.
- **What happens.** The hub credits a fill only against an accepted report that lists its id. Across fills in
  minutes and a finalized report takes 15 to 20, so the fill normally waits in `unmatchedArrivals`. The spoke lists
  the transfer for about 6 h 26 min. If no report built in that window is accepted (keeper down, Wormhole outage,
  Robinhood finality above the report lifetime, or H-04), no later report lists it and the USDC stays in
  `unmatchedArrivals` for good: outside Share Assets, outside the sweep, with no recovery path in immutable
  contracts.
- **Numbers.** 99,900 USDC stranded, Share Assets down about 10% (unit). Integrated, with a live Arbitrum fill:
  Share Assets 9,963.40 to 5,975.00, 3,986.90 in `unmatchedArrivals` through three more reports, sweep returns 0;
  the control with one report inside the window credits it to Idle.
- **Proof.** `poc/test/review/core-b/H02_ReturnTransferStrandedInUnmatched.t.sol` (real Core Vault, receiver and
  Robinhood Spoke Vault), with a control test; `poc/test/review/integration-xchain/Fork_TransferHome.t.sol`.
- **Recommendation.** Decouple matching from the in-flight window: the spoke keeps each send home in its reports for
  a long retention period, flagged "presumed filled" after the window, and the hub uses those entries only to match
  (package C).

### H-03. The Spoke Cap stops counting a transit that arrived once its expiry is attested on time alone

- **Where.** `src/core/CoreVaultLogic.sol:548-550` (time path of `nonArrivalProvable`, no report needed), `:722`
  (`attestExpiry` releases `inFlightSent`), `:271-284` (`spokeValue` deducts arrivals the hub never confirmed),
  `:664-667` (`_checkSend`).
- **What happens.** After `fillDeadline + maxReportAge` anyone can attest the expiry of a transit without a report.
  If the transit did arrive but no accepted report listed its id, its value is then in no term of the cap check:
  released from `inFlightSent`, and deducted from `spokeValue` as unknown-origin value. The manager can send a full
  cap again, and again. Two ways in: no report is delivered for that spoke in time; or, with reports flowing, the
  manager fills its own send and 256 one-USDG deposits in one transaction, so the id leaves the 256-entry window
  before any report is built.
- **Numbers.** Three times the cap on the spoke while the check reads 0 used; cost 256 USDG per cycle. Integrated,
  with live `fillRelay` calls and real Wormhole delivery: 11,985.20 USDG on a spoke capped at 4,000 (variant A) and
  12,753.20 with reports flowing and a fourth send accepted (variant B; the live pool's exclusivity makes the
  eviction deterministic).
- **Proof.** `poc/test/review/core-b/H01_SpokeCapBypass.t.sol` (2 tests);
  `poc/test/review/integration-xchain/Fork_SpokeCapBypass.t.sol` (2).
- **Violates.** DEC-037 and DEC-095. OQ-09 and CS-OQ-6 describe the time path as a liveness cost, not as a cap
  bypass.
- **Recommendation.** Use the spoke's gross principal (before the unknown-origin deduction) as `spokeValue` in the
  cap check, and release `inFlightSent` only on the report path or on a recognized refund (package C).

### H-04. The manager can make every report of a spoke undeliverable

- **Where.** `src/report/ValueReportReceiver.sol:189` (stores the whole payload) and `:201` (calls the Core Vault in
  the same transaction); no bound on what a report carries: `src/spoke/SpokeVault.sol:249-270` (positions),
  `src/spoke/SpokeCrossChainLib.sol:215-223` (a send home can be 1 unit) and `:293` (every send listed for about
  6.5 h).
- **What happens.** A delivery pays about 22,100 gas per new non-zero word. One Arbitrum transaction is capped at
  32,000,000 gas. Through the real Arbitrum Wormhole Core, about 145 dust positions (persistent; 160 cost 35.31M) or
  about 391 one-unit sends home (renewable; 420 cost 34.37M), or about 225 sends once a stranger has filled the
  256-entry arrival window, push delivery past the cap; the real Robinhood Core publishes a 62,592-byte payload
  without complaint. Then deposits revert after `maxReportAge`, payouts keep pricing the spoke on the frozen
  report, and H-02 and H-03 become available on demand. A stranger alone cannot do it: filling the window costs
  13.6M gas of delivery.
- **Proof.** `poc/test/review/spoke-b/H01_ManagerMakesReportsUndeliverable.t.sol` (3),
  `Measure_ReportBloat.t.sol` and `Measure_SteadyStateReadVsWrite.t.sol` (12 measurements);
  `poc/test/review/integration-xchain/Fork_ReportBloat.t.sol` (3, real Cores).
- **Recommendation.** Cap open positions per chain and live sends home, set a minimum send, and make delivery cost
  independent of history (store a hash and the aggregates the hub reads; pass the decoded report in memory)
  (package C).

### H-05. The hub sends capital to a Spoke Vault that nothing shows exists

- **Where.** `src/core/CoreVaultLogic.sol:638-668` (`_checkSend` asks nothing about the destination);
  `src/factory/FundFactory.sol:138-181` and `:184-210` (`createFund` and `createSpoke` are separate transactions on
  separate chains).
- **What happens.** If a send is filled before `createSpoke`, the live SpokePool transfers the tokens to the empty
  address and skips the callback. No ledger credits it. Once the vault exists the tokens are unledgered and anyone
  sweeps them to the Protocol Recipient. On the hub the transit ends in `ExpiryAttested` with no refund ever coming,
  so Share Assets count it as In-flight Value for good. Those who leave first are paid from real Idle at the
  overstated price; those who stay hold the ghost value.
- **Numbers.** 50,000 sent before the spoke existed: a holder leaves with 97,358 USDC against 49,750 of real assets,
  and 25 USDC of Idle remain behind the other holder's 49,874. Integrated: the live pool marks the relay Filled (so
  Across can never refund it), 3,998.40 USDG are swept to the Protocol Recipient, and a holder exits with 8,797.07
  against at most 5,975 of real assets.
- **Proof.** `poc/test/review/factory/H01_SendToASpokeThatDoesNotExist.t.sol`;
  `Fork_AcrossFillToCodelessSpokeVault.t.sol` on the live Robinhood pool;
  `poc/test/review/integration-xchain/Fork_SpokeCreation.t.sol`.
- **Recommendation.** Require an accepted report of that spoke before any send (`hasReport(spokeIndex)` in
  `_checkSend`): Wormhole attests the emitter, so an accepted report proves the vault exists at the Mandate address
  (package B).

### H-06. A spoke created from a Mandate other than the hub's is accepted by the hub end to end

- **Where.** `src/factory/FundFactory.sol:190-202` (the hash is only compared with the Mandate the same caller
  passes); `src/report/ValueReportReceiver.sol:144-202` and `src/libraries/ReportCodec.sol:88-103` (no Mandate hash
  anywhere in the report path).
- **What happens.** The fund id binds the manager, so only the manager can create the spoke; but the manager can
  create it from any Mandate that lists the same addresses. Pools, the unwind order, the bridge fee bound, the
  report lifetime and the Operating Cash values may all differ, and the hub accepts that spoke's reports and
  arrivals with no signal. The documented protection ("compare `mandateHash()` off-chain") fails in practice,
  because the spoke can be created after investors have deposited.
- **Numbers.** Only change: spoke `maxBridgeFeeBps` 10,000 instead of 50. One send home with an output of 1 unit
  moves 199,899.999999 USDC to the manager's relayer, the Spoke Cap is free again, and the cycle repeats every
  report delivery: all Free Idle in about two hours for the test fund.
- **Proof.** `poc/test/review/factory/H02_DivergentSpokeMandateAcceptedByTheHub.t.sol`;
  `poc/test/review/integration-xchain/Fork_SpokeCreation.t.sol` (the manager's relayer is repaid through the live
  pool's refund leaf).
- **Documented before?** FF-OQ-1 records the residual ("same addresses, other rules") and not its size.
- **Recommendation.** Put `mandateHash` in the report and have the receiver reject any other hash; together with
  the H-05 gate a divergent spoke can be created but can never receive capital. Cost: one word per payload and one
  comparison (package B).

### H-07. Deprecating the V4 adapter blocks the unwind and strands non-USDC principal for good

- **Where.** `src/adapters/UniswapV4Adapter.sol:523` (`swapExactInput` reverts when deprecated);
  `src/spoke/SpokeVault.sol:883-887` (the unwind must swap in the position's own pool);
  `src/adapters/AdapterGuard.sol:41-47` (irreversible); `src/factory/FundFactory.sol:60,110` (one immutable
  guardian for every adapter of every fund of a factory).
- **What happens.** A deprecated adapter's exit verbs work, but the WETH they return can only become USDC through
  `swapExactInput` on the same adapter, and a factory fund has one V4 adapter per chain. While a V4 position with a
  WETH leg is open, the automatic unwind reverts whole and claims are paid from Free Idle only. After the manager
  closes the positions the unwind works again, but the WETH stays in Unallocated Balance for good: no verb can move
  it, and Share Assets keep counting it, so early leavers are paid a price that includes it.
- **Numbers, integrated.** 0.551 WETH stranded on the hub (16.5% of Share Assets in the test) and 0.537 WETH on
  Robinhood; in the unit test 249,125 USDC of one holder's 997,497 stay outstanding for good.
- **Violates.** DEC-056 (the exit path stays open) and DEC-058 (withdraw-only), in the emergency deprecation exists
  for. One lost or compromised guardian key does it to every fund at once.
- **Proof.** `poc/test/review/spoke-a/H01_DeprecatedAdapterStrandsWeth.t.sol` (3),
  `poc/test/review/integration-price/DeprecatedAdapterFork.t.sol` (2).
- **Recommendation.** Never gate an exit swap into the chain's base token; put the guardian behind a rotatable,
  two-step holder with a delay on `deprecate` (package D).

### H-08. Operating Cash: unbounded parameters and no outflow, on hub and spoke

- **Where.** `src/core/CoreVaultBase.sol:269-273` and `:283-296`; `src/spoke/SpokeVault.sol:368-372`, `:988-998`
  and `:468` (every arrival runs the top-up); nothing ever debits either bucket.
- **What happens.** The manager may set any floor and any top-up. While cash is below the floor, every
  value-moving operation moves `min(topUp, free balance)` out of Share Assets into Operating Cash, which nothing can
  spend, return or sweep in the MVP. One parameter change moves all Free Idle (hub) or all Unallocated Balance
  (spoke) there for good. On a spoke a stranger's 1 USDG Across fill triggers it, and the sunk value also leaves the
  Spoke Cap, so the next tranche can follow. The manager gains nothing; holders lose the value.
- **Numbers.** Hub: 498,750 USDC moved, Share Price halved, a fully reserved Standard claimant paid 248,752 for all
  his shares. Spoke: 99,950 USDG sunk, then a second 100,000.
- **Proof.** `poc/test/review/core-a/H01_OperatingCashSink.t.sol` (2),
  `poc/test/review/spoke-a/H02_SpokeOperatingCashSink.t.sol`, `poc/test/review/spoke-b/H02_SpokeOperatingCashDeadEnd.t.sol`;
  `poc/test/review/integration-xchain/Fork_RelayerAndOperatingCash.t.sol` (the stranger's trigger is a real Across
  deposit and fill).
- **Documented before?** DEC-100 accepts no cap on the floor. Nothing says that the top-up amount is unbounded too,
  that the bucket has no exit, or that arrivals trigger it. A side effect: with Share Assets at 0 and shares
  outstanding, `requestPayout` and `claimPayout` revert `ZeroSharePrice` and open requests can never close.
- **Recommendation.** Founder decision (section 13, D-4): cap floor and top-up with core constants at the DEC-096
  scale, and give the bucket an exit (return cash above the floor, or distribute at close).

## 6. Medium findings

### M-01. The bridge fee bound becomes manager revenue, and the Mandate accepts 100%

`src/core/CoreVaultLogic.sol:659-662` and `:684-686`; `src/spoke/SpokeCrossChainLib.sol:257-259`;
`src/mandate/Mandate.sol:176`. The manager supplies `outputAmount`, `exclusiveRelayer` and `exclusivityDeadline`.
With its own relayer as exclusive relayer for the whole fill window, the fee the Mandate allows per send goes to the
manager, in both directions, as often as Free Idle and the cap allow (about 0.9% of the amount per round trip at a
50 bps bound). `MandateLib.validate` accepts a bound up to 10,000 bps, so a fund can exist where one send hands over
the whole amount. Integrated: both live pools accept the exclusive deposits, a stranger's fill reverts
`NotExclusiveRelayer` on both, and the manager's relayer keeps 3.195 USDC per 4,000 USDC round trip at the scripts'
4 bps bound; with a 10,000 bps Mandate created through the real factory, one send moves 3,999.999999 out of Share
Assets. Proof: `poc/test/review/core-b/M01_ManagerCapturesBridgeFee.t.sol` (exact `depositV3` calldata asserted);
`poc/test/review/integration-xchain/Fork_RelayerAndOperatingCash.t.sol`. Recommendation: cap `maxBridgeFeeBps`
with a protocol constant near the route fee, and force `exclusiveRelayer` and `exclusivityDeadline` to zero.

### M-02. Principal becomes performance-fee income through the fund's own range; a pool's LP fee is unbounded

`src/adapters/UniswapV4Adapter.sol:598-615`, `:516-543`, `:228-242`; `src/core/CoreVaultLogic.sol:386-397`. The
fund's swaps pay the LP fee to whoever is in range; when that is the fund's own position the fee returns as fee
growth, which the adapter reports as income, and the performance fee is charged on it. On the live pool, 6,000,000
USDC of wash volume gives the manager 288 and the protocol 288, and holders lose 1,461. Nothing bounds a Mandate
pool's fee tier, and V4 allows 100%: through the real factory, one swap of 198,000 USDC in a 1,000,000-pip pool
returned 0, the manager took 19,800 and the protocol 19,800. No accomplice and no outside capital are needed. Proof:
`poc/test/review/adapters/WashTradeIncomeFork.t.sol`, `HighFeePoolIncomeFork.t.sol`,
`poc/test/review/integration-price/FeeTierFork.t.sol`. Recommendation: bound the static LP fee of every Mandate pool
(for example 1%), and decide whether the performance fee is charged net of the swap fees the fund itself paid.

### M-03. A Mandate token the price source cannot price

`src/core/CoreVaultLogic.sol:307-317`, `:332-345`; `src/report/ChainlinkPriceSource.sol:122`;
`src/mandate/Mandate.sol:300`; `src/factory/FundFactory.sol:468-488`. Nothing checks at creation that the
factory-wide price source covers the tokens of the Mandate's pools, and the hub cannot see spoke pool tokens at all.
Once the fund holds such a token, every mint reverts `UnsupportedToken` and every payout values it at 0 for good
(CS-OQ-4 says this is reachable only for a token that "appeared after the last successful deposit or payout"; it is
permanent). In the test a full exit is paid 24,000 short and the remaining holder keeps the difference. Proof:
`poc/test/review/spoke-b/M01_UnpriceableSpokeToken.t.sol`. Recommendation: declare each chain's tokens in the
Mandate and require the price source to answer for each at creation.

### M-04. A spoke's report lifetime and Wormhole chain id are unchecked manager inputs

`src/mandate/Mandate.sol:272-276`; `src/factory/FundFactory.sol:314-335`;
`src/report/ValueReportReceiver.sol:103-111`. DEC-094 and DEC-099 make the report lifetime a property of the spoke
chain, but the Mandate takes any non-zero value. A lifetime below Robinhood's finality (about 925 s) or a wrong
Wormhole chain id makes every report undeliverable from day one; everything sent to the spoke then returns into
`unmatchedArrivals` for good (99,900 USDC in the test). An investor cannot reasonably know either number. Proof:
`poc/test/review/factory/M01_UnreportableSpokeLocksItsCapital.t.sol` (2). Recommendation: a per-chain table in the
factory wiring (DEC-089), which the Mandate must match.

### M-05. If Across shortens its fill-deadline buffer, every route stops working for good

`src/adapters/AcrossBridgeAdapter.sol:36`, `:59-66`, `:104`. The adapter always encodes `now + 21,600` and checks
the SpokePool's buffer once, at construction. The SpokePools are upgradeable proxies. If the buffer drops by one
second, every `depositV3` any fund builds reverts, a live fund cannot adopt another adapter, and spoke value has no
route home. The reviewer rated it Low; it is Medium here because the trigger is outside the project's control and
the effect is permanent. Proof: `poc/test/review/adapters/AcrossBufferReduction.t.sol`. Recommendation: encode
`min(21,600, spokePool.fillDeadlineBuffer())` at build time.

## 7. Low findings

| ID | Finding | Where | Source |
|---|---|---|---|
| L-01 | `payoutFeeBps` is accepted up to 10,000; with the flow fee every Instant claim then underflows, the request can never close and blocks a Standard one | `Mandate.sol:175`, `CoreVault.sol:223-226` | 02 L-01, PoC |
| L-02 | Every exit pushes to addresses that may refuse: the immutable Protocol Recipient (flow fee on every payout and deposit, the slice on every income credit, which also blocks report delivery when an Income arrival is pending), and every income token on a full exit | `CoreVault.sol:86,259,261`, `CoreVaultLogic.sol:395`, `CoreVaultIncome.sol:46-59` | 02 L-03, L-04; 03 |
| L-03 | A spoke that never delivered a report is never stale for mints, while its transits count at the amount sent | `CoreVaultLogic.sol:202-205` | 02 L-02 |
| L-04 | Every deposit, request and claim runs the full report builder over every hub position and every income counter; the manager controls the count (mints can be made arbitrarily expensive; a claimant can then starve the wrapped read and force the fallback) | `CoreVaultLogic.sol:225-227`, `SpokeCrossChainLib.sol:121-160` | 02 L-05 |
| L-05 | The automatic unwind cannot reach everything a complete unwind order implies: non-USDC Unallocated Balance is never unwound; about 110 small positions exhaust its gas; one step that cannot be served rolls back the steps before it; a non-USDC Aave reserve reverts it | `SpokeVault.sol:524-547`, `:811-895` | 04 L-01, L-03; 06 L-03, PoCs |
| L-06 | `buildReport` can be read while a hub verb is half done (read-only reentrancy); unreachable with USDC, WETH and hookless pools | `SpokeVault.sol:421-428` | 04 L-02 |
| L-07 | The moment income is attributed is anyone's choice: an entrant deposits and forwards income the manager had already collected (pays when unforwarded net income exceeds 0.5% of the fund with a Standard exit); a leaver's own unwind realizes income they never receive | `SpokeVault.sol:496-503`, `CoreVaultLogic.sol:386-397` | 03 L-01; 04 I-04, PoC |
| L-08 | Aave edges: with foreign aTokens in the adapter the income step of a fallback full exit reverts the whole exit (`LedgerUnderflow`, 6 of 12 sizes on the live pool); "best effort" income is bounded by the aToken's cash, not the virtual liquidity, and pays 0 in a crunch | `AaveV3Adapter.sol:399-445`, `:494` | 06 L-01, L-02, PoCs |
| L-09 | The Spoke Vault books the bridge adapter's `fillDeadline` without the check the Core Vault makes | `SpokeCrossChainLib.sol:261-266`, `:289` | 05 L-01 |
| L-10 | Mandate lists are unbounded: `createFund` passes 32M gas at about 30 extra hub pools and then EIP-3860, with no named error; the test EVM enforces neither limit | `Mandate.sol:163-182`, `FundFactory.sol:478,509` | 07 L-01, PoC |
| L-11 | The Core Vault's `handleV3AcrossMessage` credits an arrival without the backing check the Spoke Vault's handler and the two other credit paths have; it relies on the upgradeable SpokePool transferring before it calls | `CoreVaultTransit.sol:110-122`, `CoreVaultLogic.sol:489-505` | coordinator |
| L-12 | No upper bound on `standardPayoutTerm`: under a very long term a Standard request can neither be claimed nor cancelled | `Mandate.sol:163-182` | 07 I-08 |

## 8. Informational findings

| ID | Finding | Source |
|---|---|---|
| I-01 | NatSpec and documents that no longer match the code: `CoreVaultBase.sol:58-59` (callback that cannot happen), `ICoreVault.sol:336`, `:347`, `:372-373`, `:302-303`, `:325`; `ISpokeVault.sol:331`; `IAdapter.sol:100-102`, `:151-152`; `ReportCodec.sol:80-87`; `docs/INTEGRATIONS.md:77-82`; CS-OQ-6 (the cap of a sub-minimum send is released about 26 minutes earlier than the row says); `README.md:45` lists a `test/invariant/` folder that does not exist | 02 I-01 to I-05; 03 I-01, I-02; 04 I-01; 05 I-04; 06 I-06; coordinator |
| I-02 | Events do not let a server see what the founder's rule asks for: no minimum, reference price or fee in `Swapped`, `IncomeSwapped`, `UnwoundForPayout`, position events; no exclusivity fields in `SentToSpoke` and `SentToHub`; no proof path in `TransitExpiryAttested`; no payload size in `ReportPublished`; no events in `TransitEscrow`; several events emitted before the last external call; silent no-op paths | 01 §10; 03 I-06; 04 I-02; 05 I-03; 06 I-03 |
| I-03 | The arrival window never drains: after a fund's 256th listed arrival the report path of `attestExpiry` is off for good and every delivery costs about 2.7M gas instead of 0.26M | 05 I-01, PoC |
| I-04 | Two cross-chain time rules assume clock skew below one report lifetime; only the receiver's tolerance is documented (CS-OQ-5) | 05 I-02 |
| I-05 | After `decreaseManagerFee` the stored Mandate still shows the old performance fee | 03 I-03 |
| I-06 | Dead code: the source-counter machinery of `IncomeAccumulator` (`:125-163`, `:224-233`, `:273-275`), `MandateLib.bridgeAdapterFor`; `_collectIncome` ignores `distribute`'s return value | 03 I-04; 07 I-07 |
| I-07 | Cap units: the return leg counts at the amount to arrive, not the amount sent; the fee check compares raw units of two tokens, right only when the spoke token has 6 decimals, which nothing validates | 03 I-05 |
| I-08 | Every WETH/USDC V4 pool a fund can list is thin, because native-ETH pools are rejected and there is no V3 adapter: 118 USDC to crush and restore the listed Arbitrum pool, 182 USDG on Robinhood | 08 I-01 |
| I-09 | Script defaults: no hub Operating Cash entry; ETH / USD maximum age 1 h against a feed that updates on a 0.05% move with a 24 h heartbeat, so deposits revert in quiet hours; `.env.example` lists none of the variables the scripts read | 07 I-04; 08 I-02 |
| I-10 | Factory deployment trusts the operator's inputs: the libraries named in `wiring()` are not bound to the pinned code hashes; code-store chunks are not checked to be code stores; no expected hashes in the constructor; the Core Vault creation code (34 KB) travels in the calldata of every `createFund` | 07 I-01 to I-03, I-05 |
| I-11 | Token behaviours the adapters assume away (fee on transfer, rebasing, issuer freeze); the manager picks the pool tokens and nothing checks them | 06 I-07 |
| I-12 | Protocol incentives credited to an adapter address (Aave rewards, Merkl) have no claim path | 06 I-05 |
| I-13 | The V4 position key is read before external token calls (`UniswapV4Adapter.sol:366`); the NatSpec overstates what `CurrencyNotSettled` proves | 06 I-02, I-04 |
| I-14 | Gross Assets omit spoke income in flight home; the first-deposit minimum is checked before the flow fee; `lastHubValue` is refreshed under a stricter condition than documented | 02 I-02, I-04, I-07 |
| I-15 | An arrival's Operating Cash top-up is counted twice (In-flight Value on the hub and spoke Operating Cash) until the next accepted report: 10 USDG at the scripts' values, the whole arrival with H-08 | 09 I-01, walk step W4 |
| I-16 | `docs/DECISIONS.md:279` says an expired deposit is refunded from Robinhood 55 to 90 minutes after the deadline; the on-chain cadence measured on 2026-09-30 (bundle every 24 to 39 min, relayed 50 to 56 min after the proposal, leaves 3 to 13 min later) gives about 53 to 107 minutes | 09 I-02 |
| I-17 | The end-to-end scenario's DEC-104 assertion and the unit invariant's `_bucketSum` compare Share Assets with a sum built from the vault's own views, so they cannot fail on any cross-chain failure mode; the scenario also simulates fills, delivers at age 0, never sends home or refunds, and gives the unwind a Chainlink-based minimum the vault lacks | 09 I-03 |

## 9. What the Mandate does and does not prevent

The README says a manager acts "inside a Mandate fixed at creation", and ARCHITECTURE §6 says a compromised adapter
cannot redirect funds. Both statements hold for venues and destinations. They do not hold for prices, and an
investor should be told so.

**The Mandate prevents:** calling any adapter, pool or token outside its closed lists (codehashes pinned); sending
tokens anywhere but the fund's own vaults (bridge recipients fixed); mixing principal and income; entering through a
paused or deprecated adapter.

**The Mandate does not prevent** (founder's decision, DEC-027 and DEC-030: no loss limit):

| Channel | What a hostile manager, or a leaked manager key, can do | Proof |
|---|---|---|
| Execution price | Swap, open or close at any price with minimums of zero. With an accomplice who moves the pool, 100,000 USDC became 0.369 WETH (989.72 USDC); accomplice profit 98,911 | 04 M-01, fork |
| Own-range fees | Turn principal into income that pays the performance fee (M-02) | 06, fork |
| Bridge fee | Keep up to `maxBridgeFeeBps` of every send as exclusive relayer (M-01) | 03 |
| Operating Cash | Move all free capital into a bucket with no exit (H-08) | 02, 04, 05 |
| Spoke Cap | Exceed it without limit (H-03) | 03 |
| Reporting | Freeze the hub's view of a spoke (H-04) | 05 |
| Spoke rules | Create the spoke from other rules (H-06) | 07 |
| Unpriceable token | Close mints and underpay leavers (M-03) | 05 |

**Roles and what each can do to a live fund.**

| Role | Who | Powers | Worst case today |
|---|---|---|---|
| Manager | `Mandate.manager`, immutable | Position and swap verbs, allocation, sends in both directions, Operating Cash parameters, fee decrease, fee vault withdrawal, `createSpoke` | The table above |
| Shareholder | Any address with shares | Deposit, request, claim (with hints), withdraw income | C-01, C-02 |
| Anyone | Any address | `report()`, `deliver`, `attestExpiry`, `recognizeRefund`, `forwardIncomeToCoreVault`, `sweepExcess`, `createFund`; Across fills to a vault | C-02 (spoke), H-08 trigger on a spoke, L-07, I-03 |
| Adapter guardian | One immutable address per factory | `setPaused`, `deprecate` (irreversible) on every adapter of every fund | H-07 on every fund at once |
| Registry owner | `Ownable2Step` | Protocol slice per manager, at most 50% | Bounded |
| Protocol Recipient | One immutable address | Receives flow fees, slices and swept excess | If it cannot receive USDC, payouts, deposits, income credits and report deliveries revert (L-02) |
| Factory operator | Deployer key | Deploys factory, libraries, code stores, price source; no role afterwards | Wrong code at the canonical address (I-10) |
| External | Wormhole guardians, Across governance, Chainlink, Aave governance | Sign reports; upgrade SpokePools; publish prices | M-05; stale or frozen feeds close mints |

## 10. What was checked and found correct

The reviewers refuted many suspicions; the full lists are in each report's "Checked and found correct" section. The
ones that matter most:

- **Share arithmetic.** `payoutReserve <= idle` holds on every path; burn and payment are atomic, whole-share,
  rounded against the actor and never above the request; no claim twice, no payment from someone else's reserve;
  ShareToken transfers, approvals and permit are disabled (02).
- **Income accumulator.** The Q128 index with carried remainder is exact; holders are checkpointed before every
  balance change; the sum owed never exceeds what was collected; the fee split is transferred in kind in the same
  transaction; the registry read cannot be starved of gas into its default (859 gas limits swept) (03).
- **Transit books.** The three books keep their equalities through all six transitions; a report is applied exactly
  once; a stranger's fill under a real id cannot cause a net loss; a refund is credited once and only when the
  escrow holds the amount sent (03, 05).
- **Internal ledgers.** Every adapter credit is checked against the balance; adapters are only ever pushed exact
  amounts and hold no allowance; principal and income never mix; the sweep cannot take ledger value (04).
- **Adapters against the real protocols.** The V4 action plans match the live PositionManager; the principal and
  income split reproduces the PoolManager's formulas to the wei; allowances are exact and cleared; the swap callback
  is authenticated; the Aave ledger follows the live pool's rounding and nothing can borrow; the Across call matches
  the live `depositV3` argument by argument (06).
- **Report path.** Guardian quorum, emitter pair, both sequences, consistency level, fund id, chain id and age are
  all checked; no replay across funds, spokes or chains; the codec is symmetric and rejects malformed payloads; the
  arrival ring indexes correctly across wrap-around; a genuine fill cannot be made to revert on the spoke (05).
- **Across deadline.** A fill one second past `fillDeadline` reverts on the live SpokePool, so the spoke never drops
  a send that can still be filled (05, fork).
- **Factory.** The CREATE3 proxy bytes and address formulas were decoded by hand; salts are bound and cannot be
  reused or squatted; constructor reverts surface; the deployment order matches every constructor's dependencies and
  every `abi.encode` matches its constructor (07).
- **Static analysis.** Slither reports 8 High and 70 Medium results and Aderyn 21 High instances; each was opened by
  the baseline agent and then by the reviewer of its module, and all are false positives (the one real root cause
  they point at, loops over the report, is H-04).
- **Chains.** Both chains execute `MCOPY` and transient storage; the per-transaction gas limit is 32M on both.

## 11. Best practices, tests and CI

**Adopted.** One fixed compiler version in all 45 files; custom errors throughout; SafeERC20 everywhere; no
`tx.origin`, no `selfdestruct`, no ETH handling beyond the Wormhole fee; reentrancy guards on every value-moving
entry; exact approvals reset after use; no proxies, no upgrade path; every rule cites its decision in NatSpec and in
test names; two-step ownership with renounce disabled on the one owned contract.

**Not adopted, or not working.**

| Area | Fact | Source |
|---|---|---|
| CI | The only CI run on this commit failed at `forge fmt --check` (two test files), so build, unit tests and fork tests never ran in CI | 01 §3, §11 |
| Fork tests | 13 of 14 fork test files read `ARBITRUM_FORK_BLOCK` and `ROBINHOOD_FORK_BLOCK` with `vm.envUint`; `.env.example` leaves them empty ("leave empty to fork latest") and the workflow does not set them, so the documented setup and CI run 2 of 56 fork tests. With recent blocks pinned, 56 of 56 pass | 01 §5 |
| CI content | No static analysis, no coverage gate, Foundry unpinned (`version: stable`), actions pinned by major tag, fork tests fall back to public non-archive RPCs | 01 §11 |
| Dependencies | `foundry.lock` lists 6 of 7 submodules (`v4-periphery` missing, on `main` rather than a tag) | 01 §1 |
| Contract size | `SpokeVault` is at 23,644 of 24,576 bytes (932 bytes of headroom); any fix that adds code to it needs the unwind moved into a linked library first | 01 §2; 08 |
| Coverage | 97.31% of lines and 83.67% of branches in `src/` (unit tests only, `--ir-minimum`); lowest branches: `ManagerFeeVault` 33%, `ChainlinkPriceSource` 46%, `CoreVaultIncome` 62%, `CoreVaultTransit` 64%, `SpokeVault` 76% | 01 §12 |
| Lint | No Solhint configuration; 1,040 warnings with the recommended set, 717 of them NatSpec (`@param` and `@return` names) | 01 §8 |
| Events | The founder's rule is that every operation ends with an event a server can monitor. 63 of 67 state-changing entry points emit one; what is missing is the content (I-02) | 01 §10 |
| Tests versus reality | The suites that passed could not see the findings: every Core Vault unit and invariant suite values a mock hub vault with a fixed principal; every unwind unit test uses a mock adapter whose spot quote equals its swap rate; the only fork test of the unwind passes an oracle-floored hint; the DEC-104 checks are built from the vault's own views (I-17); the hub tests never receive a report the real spoke built over time; the test EVM enforces neither EIP-170 nor EIP-3860 nor the 32M gas cap | 02 I-08; 04 I-05; 08 I-03; 07 L-01; 09 |

The unit and invariant suite passes locally (644 of 644, under the default and the `ci` profile), and the fork suite
passes with pinned blocks. The numbers are real; what they measure is each module against a mock of its neighbour.

## 12. Results on the integrated system

Two agents rebuilt the findings on a fund created by the real `FundFactory` with the Mandate the scripts build, on
an Arbitrum fork and a Robinhood fork, with the real Uniswap V4, Aave V3, Across SpokePools, Wormhole Cores and
`ChainlinkPriceSource`.

**Price and unwind family** (`reports/08-integration-price-unwind.md`, 29 fork tests, 25 re-run by the coordinator):
all four findings in scope reproduce; none is refuted; C-01 is worse than first reported. The details are in C-01,
C-02, H-07 and M-02 above.

**What each fix option stops** (from report 08; "leaks" means the attack still pays inside the tolerance):

| Option | C-01 deep push | C-01 push inside the band | C-02 hub claim | C-02 deposit sandwich | C-02 spoke report | Fits in the contract? |
|---|---|---|---|---|---|---|
| (a) Value principal at the oracle-implied composition | Partly: a claim loses about its own shortfall, not the position | No | Stops | Stops | Stops, if the hub recomputes from ticks and liquidity | CoreVaultLogic +1,968 B of 5,361: yes. For unwind sizing in the Spoke Vault: no (330 B over) |
| (b) Deviation band between `slot0` and the oracle | Stops | Leaks (2% push: 1.55 to 1.74% of the value unwound) | No (payouts are never gated) | Stops beyond the band | Hub side only | Spoke Vault +719 B of 932: yes |
| (c) Unwind swap floored at the oracle price less the bound | Stops | Bounded by the bound | No | No | No | Spoke Vault +227 B: yes; (b)+(c) +605 B: yes |
| (d) Exit minimums from the oracle price | Stops for in-range and below-range positions, not above-range | Depends on tolerance | No | No | No | Spoke Vault: no (79 B over) |

The cheapest set that closes every price test fits as the code stands: (a) in `CoreVaultLogic`, plus (b) and (c) in
the Spoke Vault with a floor of about 1% that stops the unwind and keeps what was already unwound instead of
reverting. The residual is the tolerance. The feed numbers behind "about 1%": the Arbitrum ETH / USD feed updates on
a 0.05% deviation (every 29 to 810 s in the sample, largest move per update 0.49%) and the 0.05% pools stay within
0.05% of it.

**Cross-chain family** (`reports/09-integration-crosschain-tests.md`, 15 fork tests, all re-run by the coordinator).
Where the project's own scenario simulates a step, these tests do it for real: fills through the live SpokePools'
`fillRelay` with the data of the live `FundsDeposited` event; reports published on the real Robinhood Core and
delivered through the real Arbitrum Core, which verifies 13 of 19 guardian signatures, 1,000 s after publication;
refunds of expired deposits through the live pools' `executeRelayerRefundLeaf`. All ten findings tested reproduce
and none is refuted; the details are in H-01 to H-06, H-08 and M-01 above. The real stack changed the numbers in one
place, the report-bloat thresholds (H-04).

**Value-conservation walk.** A 28-step sequence on the factory-created fund covers every flow of the project's
scenario plus a send home of each kind, a refund in each direction and a donation. After every step the test
compares what the fund's contracts hold on both chains (token balances, escrows, aUSDC, V4 positions from the
PoolManager's state, unresolved Across deposits) with what the books say (Share Assets, Operating Cash, collected
and uncollected income, `unmatchedArrivals`). With a fresh report, holdings and books agree within 3 base units at
every step except: Income in flight home (known, +0.55), the bridge fee returned at a refund (+0.16, documented), the
H-01 window (+299.88 and +300.00: value in no base even with a fresh report), and a donation until swept (+1,234,
documented). With the books as they stand, three more steps diverge: an arrival's Operating Cash top-up counted
twice until the next report (new, I-15), the report lag of a spoke swap, and the documented hold-apart of a
Principal transfer home before its listing report. Income owed never exceeded income collected at any step. The
walk checks totals, not classification, so M-02 (principal relabelled as income) is invisible to it by design.

**Why the tests missed it.** Four reasons, with the closest existing test named for every Critical and High finding
in report 09:
- the hub unit tests only receive hand-written reports, never what the real spoke builds over time (H-01, H-02,
  H-03);
- fills and deliveries are simulated, at report age 0, and the fill simulation cannot model a recipient without code
  (H-05) or exclusivity (M-01);
- mock values are inputs, so the spot price equals the oracle and the unwind mock swaps at its own quote (C-01,
  C-02); the only fork test of the unwind gives the vault the oracle floor it lacks;
- the DEC-104 checks (`_sumOfBuckets` in the end-to-end scenario, `_bucketSum` in the unit invariant) rebuild Share
  Assets from the vault's own views, so they cannot fail; the walk shows both still passing while 500 USDC are
  counted twice and while 299.88 USDC are in no base (I-17).

Report 09 ends with the harness, actors and nine properties that would have caught each finding (conservation with a
ghost ledger, recoverability at quiescence, the cap against what the spoke really holds, third-party price
independence, exit under deprecation, deliverability within 32M gas, Mandate identity, no value for a fill to an
address without code, and bounded exclusivity and fee per send). They are the specification for package F below.

## 13. Recommendations and decisions for the founder

Research recommends; the founder decides. The packages are ordered by what they unblock.

**Package A, price guard (C-01, C-02, H-07 in part). Blocks everything else: no fund should hold a V4 position
before it.**
- A-1. Value V4 principal at the oracle-implied composition in Share Assets, in spoke reports as the hub reads them,
  and in `lastHubValue`.
- A-2. In the unwind: stop (do not revert) at a position whose pool deviates from the oracle beyond a band, and
  floor every unwind swap at the oracle price less the bound.
- A-3. Decide QA3's parameter: the band (recommended about 1% for 0.05% pools, about 1.5% for 0.3% pools).
- A-4. Reject Mandate pools whose tokens have no feed (M-03), since option (a) has nothing to compute for them.

**Package B, hub and spoke handshake (H-05, H-06, M-04).**
- B-1. `mandateHash` in the report; the receiver rejects any other hash.
- B-2. No send to a spoke before one accepted report from it.
- B-3. A per-chain table in the factory wiring for the Wormhole chain id and the report lifetime.

**Package C, cross-chain books (H-01, H-02, H-03, H-04).**
- C-1. The hub keeps counting a Principal transfer home it has seen listed until it is credited or its refund is
  reported; the spoke keeps sends home in its reports for a long retention period.
- C-2. The Spoke Cap counts the spoke's gross principal; the time path of `attestExpiry` does not release the cap.
- C-3. Caps on open positions per chain and on live sends home, a minimum send, and a receiver whose delivery cost
  does not grow with history.

**Package D, controls that must not hurt (H-07, H-08, M-01, M-02, M-05, L-01, L-10, L-12).**
- D-1. Exit swaps into the base token are never gated by deprecation.
- D-2. Guardian: rotatable, two-step, with a delay on `deprecate`.
- D-3. Mandate validation: bounds on `payoutFeeBps`, `maxBridgeFeeBps`, the LP fee of each pool, the list sizes and
  the Standard term.
- D-4. **Operating Cash (needs a ruling, DEC-096 and DEC-100):** a cap on floor and top-up, and an exit for the
  bucket.
- D-5. Exclusivity fields forced to zero; `min(21,600, fillDeadlineBuffer())` in the Across adapter.

**Package E, robustness (Low findings).** Pull instead of push for protocol fees and income tokens; per-step unwind
that keeps earlier proceeds; the Aave bounds; a backing check in the hub's arrival handler.

**Package F, evidence.**
- F-1. A whole-system invariant harness that wires the real Core Vault, both Spoke Vaults, the receiver and the
  adapters (the fixtures in `poc/` are a starting point), with the DEC-104 conservation property and a cap property.
- F-2. Fork tests of the unwind and of valuation at a moved price with empty hints (the PoCs can be adopted as
  regression tests once the fixes land: each must then fail).
- F-3. CI: fix formatting, set the fork blocks, pin Foundry, add Slither and a coverage gate, run the creation paths
  under mainnet limits (`code_size_limit`, a 32M gas cap).
- F-4. Add to `docs/OPEN-QUESTIONS.md`, for every open question, the consequence of the interim behaviour, and apply
  contributing rule 2 literally: revert until decided.

**A constraint on all of the above.** The Spoke Vault has 932 bytes of headroom. Packages A, C and D each add code to
it. Moving the unwind into a linked library (the existing `SpokeCrossChainLib` has about 14,000 bytes of margin)
should come first.

**What the founder is asked to decide.**

| # | Question | Options | Recommendation |
|---|---|---|---|
| 1 | QA3: how is a hub LP position valued and unwound when the pool price differs from the oracle? | (a) oracle composition; (b) band; (c) oracle floor; combinations | (a) + (b) + (c), band about 1% |
| 2 | Operating Cash: is there a cap on floor and top-up, and how does cash leave the bucket? | No cap (today); cap at the DEC-096 scale; cap as a share of Share Assets. Exit: return above the floor; distribute at close | Cap with core constants and return above the floor |
| 3 | Does the hub wait for a first report, carrying the Mandate hash, before sending to a spoke? | Yes; no (today) | Yes |
| 4 | May a manager name the exclusive relayer of a bridge send, and what is the ceiling of `maxBridgeFeeBps`? | Free (today); zero exclusivity; protocol allowlist | Zero exclusivity, ceiling near the route fee |
| 5 | Is the performance fee charged on fees the fund paid to itself, and what is the highest LP fee a Mandate pool may have? | Gross (today); net of own swap fees. Any tier (today); ceiling | Net, ceiling 1% |
| 6 | May a Mandate list a token the hub cannot price? | Yes (today); no | No |
| 7 | What does the Mandate promise an investor about prices? | Nothing (today, undisclosed); disclosure; a per-verb band a co-signer can tighten (DEC-002) | Disclosure now; the band when co-signing exists |
| 8 | Is the guardian one immutable key for every fund? | Yes (today); rotatable with a delay | Rotatable with a delay |

## 14. How to reproduce

The tests in `poc/test/review/` are written against commit `e5c778a`. Copy the folder into a checkout of
`smartcontract-v2` as `test/review/` and run:

```bash
forge test --match-path 'test/review/**' --no-match-path 'test/review/**/*Fork*.t.sol'
```

Fork tests need both RPCs and a recent block on each chain, because the public endpoints are not archive nodes:

```bash
export ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
export ARBITRUM_FORK_BLOCK=$(( $(cast block-number --rpc-url $ARBITRUM_RPC_URL) - 100 ))
export ROBINHOOD_FORK_BLOCK=$(( $(cast block-number --rpc-url $ROBINHOOD_RPC_URL) - 100 ))
forge test --match-path 'test/review/integration-price/UnwindAttackFork.t.sol' -vv
```

Run fork files one at a time. Every test asserts the wrong behaviour, so after a fix the matching test must fail;
that is how they become regression tests. `poc/gen_probes.py` regenerates the measurement copies behind the
bytecode numbers of section 12 (`REPO_ROOT=<checkout> python3 poc/gen_probes.py`).
