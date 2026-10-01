# Core Vault income side and cross-chain side review (core-b)

## Summary
The income accumulator, the fee split, report application and refund recognition are arithmetically sound and their
checks hold. The weak points are where the transit books meet the Spoke Cap, and how long the hub can wait for a report
before a transfer home is lost. Both leads from the previous round are confirmed with PoCs on the real CoreVault,
ValueReportReceiver and Robinhood SpokeVault. Counts: Critical 0, High 2, Medium 1, Low 1, Info 6.

## Findings

### [H-01] The manager can exceed the Spoke Cap without limit: once its expiry is attested, a transit that did arrive drops out of every term of the cap check
- Status: CONFIRMED (PoC passes)
- Where: `src/core/CoreVaultLogic.sol:548-550` (time path of `nonArrivalProvable`: no report needed), `:722`
  (`attestExpiry` subtracts `amountSent` from `inFlightSent`), `:154` and `:271-284` (`spokeCapUsage` takes `spokeValue`
  net of the unknown-origin deduction `cumulativeReceived - confirmedArrived`), `:664-667` (`_checkSend`);
  `src/spoke/SpokeVault.sol:457-462` (only the last 256 listed ids travel in a report).
- Rule: DEC-037 and DEC-095 (Spoke Cap = spoke value + in flight, checked on send); DEC-066 (the cap is released by
  confirmed arrival, attested expiry or recognized refund); DEC-104.
- What: Anyone may call `attestExpiry` once `fillDeadline + maxReportAge` has passed, with no report. The call releases
  the transit's `inFlightSent`. If the transit did arrive, its USDG sits in the spoke's ledger and in
  `cumulativeReceived`. But no accepted report listed its id, so it never reached `confirmedArrived`. `_spokePrincipal`
  then deducts it as unknown-origin value, and `spokeCapUsage` returns a `spokeValue` without it. After the attestation
  the arrived value is in no term of `spokeValue + inFlightSent + inFlightToHub`, and the manager can send a full cap
  again. There are two ways in:
  - (A), the lead as stated: no report listing the arrival is accepted within `fillDeadline + maxReportAge`. When no
    report was ever accepted for the spoke, deposits keep working too, because MINT mode skips a spoke without a report
    (`CoreVaultLogic.sol:204`).
  - (B), which works while reports flow normally: the manager names itself exclusive relayer (a quote field it controls,
    see M-01). It then fills its own send and 256 one-USDG deposits with fresh ids in one Robinhood transaction, so the
    genuine id leaves the 256-id window before any report is built. The full window disables the report path, and the
    time path releases the cap 6 h 26 min later.

  Share Assets stay correct: the transit remains in In-flight Value and the spoke's copy is deducted, so the price shows
  nothing. The manager can move any share of the fund to a spoke. Automatic unwinds reach hub positions only (feedback
  q2), so exits then depend on the manager bringing the money home.
- Scenario (B, from the PoC):
  1. Alice deposits 1,000,000 USDC. Spoke Cap is 100,000, `maxBridgeFeeBps` 50, `maxReportAge` 1,588 s. A keeper
     publishes and delivers a report every cycle.
  2. The manager calls `sendToSpoke(0, 100,000 USDC, 0, quote 99,950 USDG)`. This creates transit T1 and uses the whole
     cap.
  3. In one Robinhood transaction the manager, as relayer, fills T1 and then 256 deposits of 1 USDG each to the Spoke
     Vault with fresh ids. The 256 USDG are its own.
  4. The next report lists only the 256 dust ids, so T1 stays `Sent`. A deposit by Bob succeeds.
  5. At `T1.fillDeadline + 1,589 s` anyone calls `attestExpiry(T1)` through the time path. `spokeCapUsage(0)` returns
     `(0, 0, 0, 100,000)`, although the spoke holds 100,206 USDG.
  6. Steps 2 to 5 run twice more. The spoke now holds 300,618 USDG, three times its cap. The cap check still reads 0
     used and accepts a fourth 100,000 send. The cost to the manager is 256 USDG per 6.5 h cycle, which the fund keeps
     as uncounted value.
- Scenario (A): no report has ever been accepted for the spoke. The manager sends 100,000, the send is filled, and
  nobody delivers a report. At `fillDeadline + 1,589 s` anyone attests, the cap used drops to 0, and Bob's deposit
  still succeeds. After two more cycles, the first report confirms all three transits: `spokeValue` = 299,850, three
  times the cap.
- PoC: `test/review/core-b/H01_SpokeCapBypass.t.sol` (fixture `test/review/core-b/CoreBCrossChainFixture.sol`)
  - Setup: the real CoreVault, ValueReportReceiver (over a Core Bridge stand-in) and ManagerRegistry. Every report comes
    from the real Robinhood SpokeVault through `report()`.
  - Command: `forge test --match-path 'test/review/core-b/H01_SpokeCapBypass.t.sol' -vv`.
  - Result: 2 passed (`test_H01_evictedArrivalLeavesTheCapForGood_managerSendsThreeTimesTheCap`,
    `test_H01_withheldReports_capReleasedForArrivedTransits`).
- Fix: Count what the spoke actually holds. In the cap check, use the spoke's gross principal (`_positionsPrincipal` of
  the report, before the unknown-origin deduction) as `spokeValue`. An arrived but unconfirmed transit is then counted
  in any state, and a donation consumes cap only at the donor's expense. In addition, or instead, do not release
  `inFlightSent` on the time path: release it only on the report path or on a recognized refund (an Across refund in the
  escrow proves non-arrival). Add an invariant test: the cap terms never sum below the spoke's reported holdings.
- Known?: Partly.
  - REVIEW-LOG core-vault verifier finding `[minor] CoreVaultLogic.sol:417` noted that a filled transit pushed out of
    the window "releases the Spoke Cap for a transit that arrived". The fix ("no proof from a full window") closed only
    the report path.
  - OQ-09 and CS-OQ-6 describe the time-path release as a liveness cost.
  - None of them says that the released value then stays outside the cap for good (netted out of `spokeValue`), that
    the manager can trigger this at will and repeat it, or that withholding reports achieves the same for free. This
    meets criteria (b) and (d): DEC-037 and DEC-095 are violated with material effect.

### [H-02] A filled spoke-to-hub transfer is held apart for good when no report lists it before the spoke stops listing it
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/core/CoreVaultLogic.sol:497-502`: an arrival before any listing goes to `h.pending` and `unmatchedArrivals`.
  - `src/core/CoreVaultLogic.sol:463-482`: `_matchReturnLeg` releases `pending` only for ids a later report lists.
  - `src/core/CoreVaultBase.sol:324-327`: `unmatchedArrivals` is ledger, so `sweepExcess` never takes it.
  - `src/spoke/SpokeCrossChainLib.sol:103-106` and `:298-302`: the spoke drops a hub-bound transit from every report at
    `fillDeadline + maxReportAge`, "presumed filled".
- Rule: DEC-104 (no recognized value outside all bases); DEC-080 and OQ-01 (credit only what a report listed); OQ-09.
- What: The hub credits a spoke-to-hub arrival only against an accepted report that lists its id. Across fills in
  minutes, while a finalized report takes 15 to 20 minutes, so the fill normally lands first and waits in
  `unmatchedArrivals`. The spoke lists the transfer only until `fillDeadline + maxReportAge`, about 6 h 26 min. If no
  report built in that window is accepted, every later report omits the id and `_matchReturnLeg` never sees it again.
  The arrival then stays in `unmatchedArrivals` for good: outside Share Assets, not sweepable, with no recovery path.
  Meanwhile the spoke's report no longer shows that principal. Holders lose the whole transfer, Principal or Income.
- Scenario:
  1. The fund holds 1,000,000 USDC (Share Assets 997,450). 100,000 was sent to Robinhood, filled and confirmed; the
     spoke holds 99,950 USDG.
  2. The manager calls `sendToHub(99,950, Principal, 0, quote 99,900)`. Two minutes later a relayer fills it on
     Arbitrum: 99,900 USDC reach the Core Vault, and `unmatchedArrivals` = 99,900 because no report lists it yet.
  3. No report is accepted until `fillDeadline + maxReportAge`. Any of these causes it:
     - the keeper is down;
     - Robinhood finality exceeds the 1,588 s lifetime, so every report fails with `ReportTooOld`;
     - Wormhole has an outage;
     - the manager is the only keeper and stops;
     - every delivery reverts because a pending Income arrival pushes fees to a Protocol Recipient that cannot receive
       USDC (the known push issue, which here also halts report delivery).
  4. Reporting resumes. The report shows no `inFlightToHub` entry and 0 unallocated.
  5. Share Assets fall from 997,450 to 897,500 (-99,950, about 10% of the Share Price). `unmatchedArrivals` stays at
     99,900 through every later report, and `sweepExcess(usdc)` returns 0. The USDC sits in the Core Vault with no way
     out.
- PoC: `test/review/core-b/H02_ReturnTransferStrandedInUnmatched.t.sol` (same real-contract fixture).
  - Command: `forge test --match-path 'test/review/core-b/H02_ReturnTransferStrandedInUnmatched.t.sol' -vv`.
  - Result: 2 passed. The control test shows that one report inside the window credits the same arrival to Idle.
- Fix: Decouple matching from the in-flight window.
  - The spoke keeps each send home in every report for a long retention period (for example 7 days, or a separate list
    of its last N sends home with id, `amountToArrive` and kind), flagged "presumed filled" after `fillDeadline +
    maxReportAge`.
  - The hub uses these entries only to set `listed`/`kind` and release `pending`. Share Assets keep reading only the
    unflagged `inFlightToHub` entries, so nothing is counted twice.
- Known?: No.
  - OQ-09 records the spoke's "presumed filled" pruning.
  - CV-OQ-5 says held-apart arrivals have no recovery, but only for strangers' arrivals.
  - core-a's H02 covers the unfilled transfer, a temporary drop.
  - The permanent loss of a genuine filled transfer is not disclosed (criterion b), and DEC-104 is violated.

### [M-01] The manager names the Across exclusive relayer and the Mandate accepts a 100% bridge fee, so the one bound on what a send gives away becomes manager revenue
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/core/CoreVaultLogic.sol:659-662`: the only check is fee ≤ `maxBridgeFeeBps`.
  - `src/core/CoreVaultLogic.sol:684-686`: the manager's `quoteTimestamp`, `exclusivityDeadline` and
    `exclusiveRelayer` are passed through.
  - `src/interfaces/FundTypes.sol:77-82`: `BridgeQuote`.
  - `src/adapters/AcrossBridgeAdapter.sol:119-122`: encoded as received.
  - `src/mandate/Mandate.sol:176`: `maxBridgeFeeBps` is accepted up to 10,000.
  - `src/spoke/SpokeCrossChainLib.sol:257-259`: the same on the way home.
- Rule: QA19 (`maxBridgeFeeBps` as the per-send bound); DEC-087 (the vault fixes the call); DEC-002 (the manager acts
  inside the Mandate); DEC-085.
- What: The manager supplies `outputAmount`, `exclusiveRelayer` and `exclusivityDeadline`.
  - With `exclusiveRelayer` set to its own relayer and `exclusivityDeadline = 21,600` (an offset covering the whole
    fill window), only the manager can fill the deposit.
  - Across repays the filler `inputAmount`, less the LP fee, for the `outputAmount` delivered. So an `outputAmount` at
    the Mandate maximum turns `maxBridgeFeeBps` from a cost bound into a fee the manager takes on every send, in both
    directions. It repeats as often as Free Idle and the cap allow, and H-01 lifts the cap.
  - `MandateLib.validate` rejects only values above 10,000, so a fund can be created where one send
    (`outputAmount = 1`) hands the manager the whole amount.

  Exclusivity also makes the atomic eviction of H-01 (B) deterministic. The docs present QA19 as the protection and
  disclose neither point.
- Scenario:
  1. The fund holds 1,000,000 and the Mandate `maxBridgeFeeBps` is 50.
  2. The manager calls `sendToSpoke(0, 100,000, 0, {outputAmount 99,500, exclusivityDeadline 21,600, exclusiveRelayer
     managerRelayer})`. The vault makes exactly that `depositV3` call; `vm.expectCall` checks the full calldata. Share
     Assets drop by 500 at once.
  3. For 6 h only `managerRelayer` can fill. It delivers 99,500 USDG and is repaid about 100,000 USDC less a 1 to 6 bps
     LP fee: about 0.44% of the send. `sendToHub` works the same way, so a round trip yields about 0.9% of the amount.
  4. With a Mandate `maxBridgeFeeBps` of 10,000 (accepted) and `outputAmount = 1`, Share Assets drop by
     99,999.999999 USDC. The manager's relayer collects it for 0.000001 USDG.
- PoC: `test/review/core-b/M01_ManagerCapturesBridgeFee.t.sol`.
  - Command: `forge test --match-path 'test/review/core-b/M01_ManagerCapturesBridgeFee.t.sol' -vv`.
  - Result: 2 passed.
- Fix:
  - In `MandateLib.validate`, cap `maxBridgeFeeBps` with a protocol constant near Across's route fee (for example 30 to
    50 bps).
  - In `_sendRequest` and in the spoke's `_buildCall`, force `exclusiveRelayer = 0` and `exclusivityDeadline = 0`, or
    accept exclusivity only for a relayer the protocol lists.
  - State in the docs that the bound is a per-send loss budget the manager can spend repeatedly.
- Known?: No. The QA19 row and ARCHITECTURE §4.2 present `maxBridgeFeeBps` as the bound, and the REVIEW-LOG documents
  only how the exclusivity parameter is encoded. The finding is Medium rather than High because DEC-027 and DEC-030
  accept no loss limit on manager operations and the Mandate value is visible to investors.

### [L-01] Income the manager already collected is shared with whoever enters before someone forwards it
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/spoke/SpokeVault.sol:496-503`: `forwardIncomeToCoreVault` has no access control.
  - `src/core/CoreVaultIncome.sol:28-34` and `src/core/CoreVaultLogic.sol:386-397`: the index moves on the forward.
  - `src/core/CoreVaultLogic.sol:463-482` and `:510-526`: spoke Income moves on report delivery or on the fill.
- Rule: DEC-014; ruling of 2026-09-29; CS-OQ-1.
- What: CS-OQ-1 says income "collected before the entry is not shared" and that "frequent collection narrows the
  window". But the manager's `collectIncome` on the hub Spoke Vault only fills that vault's bucket; the index moves when
  anyone forwards it. An entrant deposits and forwards in one transaction and takes a pro-rata share of income collected
  before the entry. Spoke income enters on the permissionless report delivery, or on the fill, after sitting visible on
  Robinhood (`SentToHub`) for 15 to 20 minutes. In the other direction, a leaver loses its share of spoke income still in
  flight to the holders who stay.
- Scenario (default fees: flow fee 25 bps each way, performance fee 20%, slice 50%, Standard exit):
  1. Alice holds a 100,000 USDC fund. A hub position earns 2,000 USDC, and the manager collects it into the hub bucket.
  2. Mallory deposits 100,000 and calls `forwardIncomeToCoreVault(usdc)`. 400 goes to the protocol and the fee vault;
     the 1,600 net splits Alice 799.99, Mallory 800.01. Mallory withdraws her share.
  3. Mallory requests a Standard Payout and claims after 72 h, receiving 99,500.62. Her profit is +300.64 USDC, and
     Alice loses 800.
- Break-even: the attack pays when the net income waiting to be forwarded exceeds 0.5% of the fund value after entry
  (two flow fees, Standard exit with 72 h of exposure), or 2.5% with an Instant exit. Below that it is griefing at the
  entrant's own cost.
- PoC: `test/review/core-b/L01_IncomeTimingCapture.t.sol` (on core-a's `CoreAHubFixture`, with the real hub SpokeVault
  and UniswapV4Adapter).
  - Command: `forge test --match-path 'test/review/core-b/L01_IncomeTimingCapture.t.sol' -vv`.
  - Result: 1 passed.
- Fix:
  - Have the hub vault's `collectIncome` forward to the Core Vault in the same call.
  - Restate CS-OQ-1: attribution happens when income reaches the Core Vault, anyone can choose that moment, and the
    threshold above applies.
- Known?: CS-OQ-1 is the documented stance. The gap is the permissionless timing and the inaccurate "collected before
  entry" wording (criterion b). It is Low because the flow fee bounds it.

### [I-01] CS-OQ-6 misstates when a send below the listing minimum is attested
- Status: CONFIRMED (PoC passes)
- Where: `src/core/CoreVaultLogic.sol:554-559`; `src/spoke/SpokeVault.sol:459`; `docs/OPEN-QUESTIONS.md:74`.
- Rule: CS-OQ-6, OQ-09.
- What: CS-OQ-6 says such a send "is attested only through the deadline plus report lifetime path". The spoke never
  lists it, so the first report built after the deadline (window not full) already proves "non-arrival". The cap is
  released about 26 minutes earlier than documented, for a transit that did arrive.
- Scenario: 0.9 USDC is sent and arrives as 0.8996 USDG. At deadline + 1 a report is delivered, and `attestExpiry`
  succeeds at once.
- PoC: `forge test --match-path 'test/review/core-b/I01_SubMinimumArrivalAttestedByReport.t.sol' -vv` → 1 passed.
- Fix: correct the row. The H-01 fix removes the cap consequence.
- Known?: The row itself is the inaccuracy.

### [I-02] NatSpec that no longer matches the code
- Status: CONFIRMED (by reading; Info needs no PoC)
- Where:
  - `src/core/CoreVaultBase.sol:58-59`: says the hub Spoke Vault "may call back `returnToIdle` and
    `receiveCollectedIncome` from inside a payout". `receiveCollectedIncome` is `nonReentrant`
    (`CoreVaultIncome.sol:28`) and cannot be called back; `CoreVaultIncome.sol:27` says the opposite.
  - `src/interfaces/ICoreVault.sol:336`: `sweepExcess` "never sweeps ... owed fees". No owed fees exist any more, and
    `unmatchedArrivals`, which the code keeps out of the sweep, is not listed.
  - `src/interfaces/ICoreVault.sol:372-373`: `onReportAccepted` "if the MVP recognizes spoke income on delivery,
    advances the index". Only matched Income arrivals do.
  - `src/interfaces/ICoreVault.sol:347`: the `sendToSpoke` cap formula omits the return leg the code adds
    (`CoreVaultLogic.sol:666`).
  - `src/interfaces/ICoreVault.sol:325`: Share Assets count the transit "until its refund is recognized". They also stop
    counting it on a confirmed arrival.
- Rule: best practice (NatSpec matches the code).
- Fix: update the texts.
- Known?: No.

### [I-03] After `decreaseManagerFee`, the stored Mandate still reports the old performance fee
- Status: CONFIRMED (by reading)
- Where: `src/core/CoreVaultIncome.sol:72`; `src/core/CoreVaultBase.sol:145`, `:185-187`.
- Rule: DEC-110.
- What: `performanceFeeBps()` returns the live value, but `mandate().performanceFeeBps` keeps the creation value (the
  Mandate copy is never written again). An integrator reading the Mandate shows the old fee.
- Fix: document that the Mandate field is the creation value, or read the live one in `mandate()`.
- Known?: No.

### [I-04] Dead accumulator code, and an ignored return value
- Status: CONFIRMED (by reading)
- Where: `src/libraries/IncomeAccumulator.sol:125-163`, `:224-233` and `:273-275` (no production caller since the
  consolidation removed recognition); `src/core/CoreVaultLogic.sol:392-393`.
- Rule: best practice.
- What: The source-counter machinery has no production caller: `advanceSource`, `recognizeFromSource`,
  `isSourceFlagged`, `sourceCumulative`, `flaggedSources` and the uncapped `takeOwed`. Separately, `_collectIncome`
  ignores `distribute`'s return value. A skipped distribution (amount above 2^128-1, unreachable in practice) would
  still be added to `collectedIncome`, unclaimable and unsweepable.
- Fix: remove the dead code. Add the net to `collectedIncome` only when `distribute` returns true.
- Known?: No.

### [I-05] Cap-term units: the return leg is counted at the amount to arrive, and the fee check compares two tokens' raw units
- Status: CONFIRMED (by reading)
- Where: `src/core/CoreVaultLogic.sol:292-303` (the return leg at `amountToArrive`) and `:660-661`.
- Rule: DEC-066 C1 (the cap counts the amount sent).
- What: In the cap, the pending return leg counts at its hub-USDC `amountToArrive`. That understates it by its bridge
  fee (at most `maxBridgeFeeBps`), in the manager's favour. The fee check, and the adapter's `output <= input`, compare
  raw USDC units against spoke-token units. That is correct only for tokens with equal decimals; USDG has 6, so it holds
  today. A Mandate with an 18-decimal spoke token would make every send revert.
- Fix: count the return leg at the amount sent; check the decimals of `spokeToken` in `MandateLib.validate`.
- Known?: No.

### [I-06] Monitoring gaps in the events
- Status: CONFIRMED (by reading)
- Where:
  - `CoreVaultLogic.sol:620`: `SentToSpoke` omits `exclusiveRelayer`, `exclusivityDeadline` and `quoteTimestamp`.
  - `:723`: `TransitExpiryAttested` does not say which proof path was used.
  - `CoreVaultIncome.sol:55` and `CoreVaultTransit.sol:131`: nothing is emitted on a zero withdrawal or a zero sweep.
  - `TransitEscrow.sol:26-38`: `initialize` and `release` emit no events.
- Rule: best practice (every operation ends with an event a server can monitor).
- What: A monitor cannot see from the vault's events that the manager named itself exclusive relayer (M-01), or that an
  expiry was attested on time alone (H-01).
- Fix: add these fields.
- Known?: No.

## Checks and validations

| Function | Access control | Input validation | Reentrancy guard | CEI | Event | Gaps |
|---|---|---|---|---|---|---|
| `CoreVaultIncome.receiveCollectedIncome` | hub Spoke Vault only | registered token, amount > 0, backed above ledger (`_requireUnledgered`) | `nonReentrant` | state and index, then fee pushes | `CollectedIncomeReceived` (before transfers) | fee push can revert (known) |
| `CoreVaultIncome.withdrawIncome` | caller's own income | registered token | `nonReentrant` | checkpoint, `takeOwed`, then transfer | `IncomeWithdrawn` | no event on 0 (I-06) |
| `CoreVaultIncome.decreaseManagerFee` | `onlyManager` | new perf < old, management fee = 0 | `nonReentrant` | no external call | `ManagerFeeDecreased` | Mandate copy stale (I-03) |
| `CoreVaultTransit.allocateToHubSpokeVault` | `onlyManager` | amount > 0, ≤ Free Idle after top-up | `nonReentrant` | state, event, then transfer and callback | `AllocatedToHubSpokeVault` | none |
| `CoreVaultTransit.returnToIdle` | hub Spoke Vault; guard not held unless unwinding | amount > 0, backed above ledger | callback guard | no external call | `ReturnedToIdle` | none |
| `CoreVaultTransit.sendToSpoke` | `onlyManager` | amount > 0; spoke index; Free Idle; adapter by rank, not paused or deprecated, codehash; fee ≤ max; cap; target, amount to arrive and deadline match; exact debit | `nonReentrant` | books, then approve, call, reset | `SentToSpoke` | **cap bypass (H-01); exclusivity and fee bound (M-01)**; event fields (I-06) |
| `CoreVaultTransit.attestExpiry` | anyone | state Sent, deadline passed, non-arrival proof | `nonReentrant` | receiver view only | `TransitExpiryAttested` | **time path releases the cap of arrived transits (H-01)** |
| `CoreVaultTransit.recognizeRefund` | anyone | state ExpiryAttested, escrow ≥ `amountSent` | `nonReentrant` | books, then release, then balance check | `TransitRefundRecognized` | none |
| `CoreVaultTransit.onReportAccepted` | ValueReportReceiver only | spoke index, fund id | `nonReentrant` | books, then fee pushes for Income | `ReportAccepted`, `TransitArrived`, `TransitReceived` | **matching limited to the in-flight window (H-02)** |
| `CoreVaultTransit.handleV3AcrossMessage` | Across SpokePool only | USDC only, amount > 0, message version, fund id | `nonReentrant` | books, then fee pushes for Income | `TransitReceived`, `ArrivalHeldApart` | fee push can make a genuine fill fail (known) |
| `CoreVaultTransit.sweepExcess` | anyone | none (balance above ledger) | `nonReentrant` | computed, then transfer to the fixed recipient | `ExcessSwept` | no event on 0 (I-06) |
| `CoreVaultLogic` public non-view functions | reachable only by DELEGATECALL from the entries above (Solidity library call guard) | as their entries | via entries | as their entries | as their entries | none |
| `TransitEscrow.initialize` | once; implementation self-bound | non-zero vault and token | none needed | no external call | none | no event (I-06) |
| `TransitEscrow.release` | vault only | none | none needed | single transfer | none | no event (I-06) |
| `ManagerFeeVault.withdraw` | manager only | `to` ≠ 0 | `nonReentrant` | event, then transfer | `ManagerFeeWithdrawn` | none |
| `ManagerRegistry.setProtocolSliceBps` | `onlyOwner` (Ownable2Step) | manager ≠ 0, bps ≤ 5,000 | n/a | no external call | `ProtocolSliceSet` | none |
| `ManagerRegistry.clearProtocolSliceBps` | `onlyOwner` | manager ≠ 0 | n/a | no external call | `ProtocolSliceSet` | none |
| `ManagerRegistry.renounceOwnership` | always reverts | n/a | n/a | n/a | n/a | none |
| `ManagerRegistry.transferOwnership` / `acceptOwnership` | owner, then pending owner | OZ | n/a | n/a | OZ events | none |

## Checked and found correct
- **Q128 index with carried remainder** (`IncomeAccumulator.sol:194-219`).
  - The increment is exactly floor((a·2^128 + r) / T), and the remainder is reduced against the current supply
    (`fresh + carried ≥ T` is tested through the gap, with no overflow).
  - Summing over distributions, Σ T_k·ΔI_k = 2^128·Σa − r_final.
  - Holders are checkpointed before every balance change: deposit before the mint (`CoreVault.sol:80`), payout before
    the burn (`:238`), and `withdrawIncome`. Share transfers are disabled.
  - So Σ owed ≤ Σ distributed ≤ Σ net, and `collectedIncome` ≥ Σ owed at all times: `min(owed, collected)` always pays
    `owed`.
  - Overflow is bounded by `MAX_STEP`, `tryAdd` on the index and 512-bit `mulDiv` in checkpoints. Ownerless income stays
    in `collectedIncome`, outside the sweep (LC-32).
- **Backing of `receiveCollectedIncome`.**
  - Only the hub Spoke Vault can call it. It zeroes its bucket, transfers, then calls with the same amount, and
    `_requireUnledgered` stops a donation already in the Core Vault from being credited. Nothing is collected twice.
  - Donations to the Core Vault stay unledgered and are swept.
  - A donation becomes income only through the spoke's Income-kind arrival (`SpokeVault.sol:463-465`), which is paid
    for by the donor.
- **Registry read gas griefing.** I swept every gas limit from 60,000 to 400,000 in 250-gas steps, with the real
  `ManagerRegistry` and a 10% slice. All 859 successful collections read the registry; none fell back to the 50%
  default. The work after the wrapped call (SSTOREs, transfers) far exceeds the 1/64 left when the read runs out of gas.
  Test: `test/review/core-b/Refute_RegistryReadGasGriefing.t.sol`, 1 passed.
- **Fee arithmetic.**
  - The fee and the slice round down. Net = amount − fee.
  - The performance fee is capped at 2,500 bps (`Mandate.sol:177`), and the slice is capped at 10,000 in the vault and
    5,000 in the registry.
  - The split happens and is transferred in the same transaction, in kind (DEC-109).
- **`decreaseManagerFee`**: strictly decreasing, with the management fee kept at 0. What it settles is CS-OQ-2
  (documented).
- **Report application exactly once.** `deliver` calls `onReportAccepted` without try/catch, so a report is stored only
  if it is applied. Sequences strictly increase. Skipping or overtaking a report only delays confirmations, since the
  window re-lists them (H-02 is the exception). Every field comes from the fund's own Spoke Vault (emitter check).
- **The three transit books.** The six transitions keep these equalities, with no underflow (`CoreVaultLogic.sol:451-453`,
  `:722`, `:748`):
  - `inFlightSent` = Σ `amountSent` over Sent transits;
  - `inFlightToArrive` = Σ `amountToArrive` over Sent and ExpiryAttested transits;
  - `confirmedArrived` = Σ `amountToArrive` over ArrivalConfirmed transits.
- **A stranger's fill under a real id.**
  - Hub-to-spoke, at or above `amountToArrive`: confirms early, and the stranger's funds make the fund whole. Below it:
    confirms nothing.
  - Under a listed hub-bound key: credited by the listed kind up to the room left, and the displaced genuine arrival is
    held apart, with no net loss (CV-OQ-5).
  - A fabricated key: held apart, and never reaches a base or the sweep.
- **`recognizeRefund`.**
  - Only from ExpiryAttested, only with ≥ `amountSent` in the escrow, and exactly `amountSent` is credited; the surplus
    is swept. It cannot run twice.
  - A donation-funded "refund" of a filled transit is paid by the donor.
  - RefundRecognized → ArrivalConfirmed does not touch `inFlightToArrive` again, so there is no double credit.
- **Revert paths of `handleV3AcrossMessage` on a genuine fill**: only the fee pushes of an Income credit (the known
  Protocol Recipient issue). The caller, token, amount, version, fund-id and pending/credit paths cannot revert for the
  fund's own transfer.
- **`sweepExcess`.** The ledger is Idle (the reserve inside it) + Operating Cash + `unmatchedArrivals` + collected
  income per token. No path leaves ledger USDC unrecorded between a transfer and its credit: the hub vault transfers and
  credits in one call, Across transfers then calls, and a refund is credited then released with an exact-delta check.
- **`sendToSpoke` custody.**
  - The target is pinned; approval is exact, then reset to zero; the call is plain; the debit must be exact.
  - `amountToArrive` must equal the quote, and the deadline must be in the future.
  - The escrow clone is initialized in the same transaction. The transit id is unique (a nonce), and the codehash is
    pinned.
- **`TransitEscrow`, `ManagerFeeVault`, `ManagerRegistry`.**
  - TransitEscrow: the implementation is self-bound, clones are initialized atomically, and `release` is vault-only and
    moves the whole balance.
  - ManagerFeeVault: fund and manager are immutable, `withdraw` is manager-only, and the vault is outside every base.
  - ManagerRegistry: Ownable2Step, a 5,000 bps cap, renounce disabled, and the default applies when a manager has no
    entry.
- **Library call guard.** `CoreVaultLogic`'s public state-changing functions cannot be called directly on the library.
- **Share Price moves from the transit paths.** Confirmation, attestation and hub-bound credits move value between bases
  at equal amounts. Only `recognizeRefund` lifts Share Assets, by the bridge fee (≤ 50 bps of one transit), which is
  below the 0.5% round-trip flow fee, so it is not worth a sandwich.

## Not covered
- **Report bloat by the manager (spoke and receiver scope).** `sendToHub` has no minimum amount, and every in-flight id
  is listed for about 6.5 h. The receiver stores the whole payload, and the Core Vault decodes it on every valuation.
  About 1,000 one-unit sends home (about 3,000 extra payload words, more than 32M gas on first store) would make reports
  undeliverable. That is a trigger on demand for H-01 (A) and H-02, and it blocks deposits. Not measured.
- **Principal turned into income through wash trades** against the fund's own V4 position, which then pays the
  performance fee (FV-16 class). Adapter and spoke scope.
- **Timing assumptions not checked:**
  - Across slow fills executed after `fillDeadline`, against the spoke's "presumed filled" pruning.
  - Clock skew between Arbitrum and Robinhood against the time path.
- **Spoke code and other scopes.**
  - SpokeVault and SpokeCrossChainLib were read only where they feed these paths.
  - The valuation code (`CoreVaultLogic.sol:60-370`) was read only to judge impact.
  - Fork tests and real Wormhole verification were not run.

All PoCs: `forge test --match-path 'test/review/core-b/*' -vv` → 9 passed, 0 failed.
