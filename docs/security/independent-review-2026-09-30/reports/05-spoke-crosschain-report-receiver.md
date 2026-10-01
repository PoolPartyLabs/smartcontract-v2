# Spoke cross-chain side, value report and pricing review (spoke-b)

Reviewer slug `spoke-b`, repository `PoolPartyLabs/smartcontract-v2` at `e5c778a`, working copy `smartcontract-v2-b`. PoCs in
`test/review/spoke-b/`. They build on core-b's real-contract fixture: the real CoreVault, ValueReportReceiver and Robinhood
SpokeVault, plus a log-only Wormhole stand-in in `SpokeBFixture.sol`.

## Summary
The send-home, refund, arrival and codec code does what it says: every revert path, ring index and CEI order I checked holds.
The receiver's checks and the Chainlink arithmetic are also correct. Tests back these results, and two fork runs cover Across.
The weak point is size. Anyone can build a report, but the manager decides how big it gets, and the hub must store all of it in one 32M-gas transaction. The manager can therefore stop reporting for good (H-01).
The spoke's Operating Cash has no exit, and any arrival fills it (H-02). The hub has no price for tokens outside WETH and USDG (M-01).
Counts: Critical 0, High 2, Medium 1, Low 1, Info 4. All 24 PoC and measurement tests pass (22 unit, 2 fork).

## Findings

### [H-01] The manager can make every value report of a spoke undeliverable, which freezes the hub's view of that spoke for as long as the manager wants
- Status: CONFIRMED (PoC passes)
- Where:
  - What a report carries has no bound:
    - `src/spoke/SpokeVault.sol:249-270`: `openPosition` has no cap, and every open position adds 12 words (push at `:266`).
    - `src/spoke/SpokeCrossChainLib.sol:215-223`: `_checkQuote` accepts one base unit, so a send home can be as small as 1.
    - `:293`: every send home is listed, 3 words each, until `fillDeadline + maxReportAge` (`:300-302`).
    - `:129-192`: `_build` loops over all of them.
  - What the hub does with it:
    - `src/report/ValueReportReceiver.sol:189`: stores the whole payload.
    - `:201`: calls the Core Vault in the same transaction.
    - `src/core/CoreVaultLogic.sol:419`: re-reads the payload.
    - `:472-475`: writes `listed`/`kind` for every newly listed send home.
    - `:206`: every valuation decodes the stored payload.
- Rule: DEC-093 (anyone may deliver; the report is the channel); DEC-070 and DEC-086 (spoke value comes only from reports); DEC-104. Best practice: no unbounded loops on user paths.
- What: a delivery pays about 22,100 gas for each non-zero word the stored report did not have before. It also pays about 22,100 for each send home that a report lists for the first time.
  - Arbitrum One and Robinhood Chain cap a transaction at 32,000,000 gas. I read `maxTxGasLimit` from `ArbGasInfo.getGasAccountingParams()` on both chains on 2026-09-30.
  - A report that grows by more than about 1,400 words over the stored one therefore cannot be accepted by anyone. Neither can any later report while the growth stays.
  - The manager can add that much in seconds on Robinhood at trivial cost: about 143 dust positions (these persist), or about 410 dust sends home (these are renewable every 6 h 26 min).
  - Publishing on Robinhood keeps working (6.1M gas at 160 positions). Only the hub side fails.
  - Consequences:
    - After `maxReportAge` every deposit reverts with `StaleSpokeReport`.
    - Every payout keeps pricing the spoke on the frozen report. Payouts read reports at any age (Q57 reading), and the frozen token composition drifts from reality.
    - Every transfer home the manager makes during the freeze is stranded in `unmatchedArrivals` for good once the spoke stops listing it. This is core-b H-02, now on demand.
    - The time path of `attestExpiry` releases the Spoke Cap of transits that did arrive. This is core-b H-01 (A), now on demand.
    - If the freeze starts before the first report is ever accepted, mints stay open and price the spoke at the amount sent (core-a L-02).
  - A stranger alone cannot do it: flushing the 256-id window adds 512 words (12.9M gas). It does halve what the manager needs.
- Measurements (`Measure_ReportBloat`, `Measure_SteadyStateReadVsWrite`):
  - Storage cold (`vm.cool`). The previous small report was committed in `setUp`.
  - The Core Bridge stand-in skips signature verification. The real Arbitrum Core costs about 146,000 gas more, per `docs/OPEN-QUESTIONS.md` "Report age and gas".

  | What the report lists (over a 36-word stored report) | Payload words | `report()` on Robinhood | `deliver()` incl. base + calldata | Deposit valuation |
  |---|---:|---:|---:|---:|
  | Nothing extra | 36 | 125k | 264k | 313k |
  | Stranger: 256 arrivals of 1 USDG | 546 | 1.55M | 12.9M | 1.58M |
  | Manager: 100 / 200 / 300 sends home of 1 unit (Principal) | 336 / 636 / 936 | 1.10M / 2.09M / 3.09M | 8.0M / 15.7M / 23.5M | 1.34M / 2.37M / 3.40M |
  | Manager: 200 sends home of 1 unit (Income) | 636 | 2.09M | 23.7M | 1.82M |
  | Manager: 50 / 100 / 160 dust positions | 636 / 1,236 / 1,956 | 1.88M / 3.73M / 6.08M | 11.4M / 22.4M / **35.8M** | 1.80M / 3.31M / n.a. |
  | 256 arrivals + 150 sends | 996 | 3.05M | 24.6M | 3.14M |

  - Slopes per entry:
    - Principal send about 77k.
    - Income send about 117k.
    - Position about 221k.
    - Listed arrival about 49k.
  - Limits at 32M:
    - About 410 Principal sends, or about 270 Income sends, or about 143 positions.
    - About 245 sends once a stranger has flushed the window.
  - Steady state, with a 4,836-word report grown in four steps:
    - One more delivery costs 18.1M (3.7k per stored word), so even growth in steps stops at about 8,500 words.
    - A claim reading that report costs 12.8M, and a deposit 12.8M (2.6k per word).
    - Payouts therefore can never be blocked by size: the stored report is bounded by what one delivery could write.
  - With a full window, every routine delivery costs 2.7M gas forever (see I-01).
  - On Robinhood, `report()` pays about 10k per live send and about 14k per expired send it prunes (4.2M for 300). It would break only at about 3,200 live or about 2,300 expired sends home. The hub side breaks first in every configuration.
  - Fork (Robinhood, real `AcrossBridgeAdapter` and live SpokePool, block 76,609,960):
    - All 50 of 50 one-unit sends home were accepted, at about 515k gas each.
    - 450 sends cost about 0.005 ETH at 0.0226 gwei.
- Scenario (from the PoC):
  1. A 1,000,000 USDC fund holds 99,950 USDG on Robinhood. The last accepted report shows it.
  2. The manager opens 160 positions of 1 USDG base unit each in the Mandate pool, at a cost of 0.00016 USDG plus gas.
  3. `report()` succeeds on Robinhood. On Arbitrum, `deliver` needs 35.8M gas. With a 32M budget it runs out of gas, and so does every report published over the next 24 h.
  4. 1,589 s later, Bob's deposit reverts with `StaleSpokeReport(0)`.
  5. Alice's Instant Payout still executes, priced on the day-old report: Share Assets 997,450.
  6. Renewable variant: the manager sends 50,000 USDG home and, in the same minute, 450 one-unit sends. A relayer fills the real transfer on Arbitrum.
  7. No report listing that transfer can be delivered before the spoke prunes everything at `fillDeadline + maxReportAge`.
  8. Reporting then resumes on its own. The 49,975 USDC stay in `unmatchedArrivals` for good, and Share Assets fall by 50,000 (997,450 to 947,450). `sweepExcess` returns 0.
- PoC: `test/review/spoke-b/H01_ManagerMakesReportsUndeliverable.t.sol`.
  - Command: `forge test --match-path 'test/review/spoke-b/H01_ManagerMakesReportsUndeliverable.t.sol' -vv`.
  - Result: 3 passed:
    - `test_H01_dustPositionsFreezeReportDeliveryForGood`;
    - `test_H01_dustSendsHomeFreezeDeliveryAndStrandARealTransferHome`;
    - `test_H01_strangerArrivalsAloneStayDeliverable`.
  - Measurements: `forge test --match-path 'test/review/spoke-b/Measure_*' -vv` gives 12 passed.
  - Fork (public RPCs keep only recent state, so pin about 100 blocks below the head at run time): `export ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com; export ARBITRUM_FORK_BLOCK=$(( $(cast block-number --rpc-url $ARBITRUM_RPC_URL) - 100 )) ROBINHOOD_FORK_BLOCK=$(( $(cast block-number --rpc-url $ROBINHOOD_RPC_URL) - 100 )); forge test --match-path 'test/review/spoke-b/Fork_*' -vv` gives 2 passed (last run at Arbitrum 510,382,003 and Robinhood 76,609,960).
- Fix:
  - Bound what a report can carry:
    - a core constant cap on open positions per chain, checked in `openPosition`;
    - a cap on live sends home and a minimum send, checked in `sendToHub`.
  - Make delivery cost independent of history:
    - the receiver stores `keccak256(payload)` and the few aggregates the Core Vault reads;
    - it passes the decoded report to `onReportAccepted` in memory instead of having the Core Vault re-read storage;
    - it keeps only the per-id lists the hub needs later.
  - Publish the payload size in `ReportPublished` (I-03) so keepers see the growth.
  - The core-b H-01 and H-02 fixes remove the worst consequences.
- Known?: No.
  - `docs/INTEGRATIONS.md:74-78` and the REVIEW-LOG report-receiver notes measure one-position and full-window reports and suggest storing a hash "if gas becomes a factor".
  - core-b listed the bloat as an unverified lead.
  - Nothing discloses that the manager can grow a report past what one Arbitrum transaction can accept, or what follows from it. Criteria (b) and (d) (DEC-093).

### [H-02] Spoke Operating Cash is a dead end that any arrival fills: one parameter change moves the whole spoke principal out of Share Assets for good, and the freed Spoke Cap lets it repeat
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/spoke/SpokeVault.sol:368-372`: `setOperatingCashParameters` takes any floor and top-up.
  - `:988-998`: `_topUpOperatingCash`, the only writer of `operatingCash`, and it only adds.
  - `:468`: every `handleV3AcrossMessage` runs it, including a stranger's fill.
  - `:965-968`: the bucket is ledger, so `sweepExcess` never takes it.
  - `src/spoke/SpokeCrossChainLib.sol:226-236`: `sendToHub` can only debit Unallocated Balance or collected income.
  - `src/core/CoreVaultLogic.sol:235-248`: spoke Operating Cash is outside Share Assets and outside the Spoke Cap. It appears only in Gross Assets (`:133`).
- Rule: DEC-096 (floor about 5 USD, top-up about 10 USD on Robinhood; Operating Cash goes to shareholders at close); DEC-013; DEC-037 and DEC-095 (Spoke Cap); DEC-102 (Operating Cash is for gas).
- What: this is the spoke counterpart of core-a H-01, which covers only the hub bucket. On the spoke:
  - nothing spends Operating Cash;
  - no send-home kind can bring it back;
  - there is no fund close.

  With floor and top-up at the maximum, the next value-moving operation moves the whole base-token Unallocated Balance into that bucket. A stranger's 1 USDG Across fill is such an operation.
  - The hub then drops it from Share Assets, and from `spokeValue` in the Spoke Cap check.
  - So the manager can send the next full tranche and sink it too, as many times as Free Idle allows.
  - The manager gains nothing, but every holder loses the sunk value for good.
- Scenario:
  1. A 1,000,000 USDC fund has 99,950 USDG on Robinhood. Share Assets are 997,450.
  2. The manager calls `setOperatingCashParameters(max, max)`.
  3. A stranger self-relays 1 USDG. Unallocated Balance goes to 0 and Operating Cash to 99,951.
  4. After the next report, Share Assets are 897,499. `sendToHub` reverts with `InsufficientUnallocatedBalance`, `sweepExcess` returns 0, and resetting the parameters to 0 changes nothing.
  5. `spokeCapUsage(0)` shows `spokeValue` 0. The manager sends another 100,000, and its own arrival sinks it.
  6. Spoke Operating Cash is now 199,901, twice the cap, and Share Assets are 797,499.
- PoC: `test/review/spoke-b/H02_SpokeOperatingCashDeadEnd.t.sol`.
  - Command: `forge test --match-path 'test/review/spoke-b/H02_SpokeOperatingCashDeadEnd.t.sol' -vv`.
  - Result: 1 passed.
- Fix:
  - Cap floor and top-up with core constants at the DEC-096 scale.
  - Give spoke Operating Cash an exit: an `OperatingCash` send-home kind that the hub credits back to Idle, or a return of cash above the floor to Unallocated Balance.
  - Count spoke Operating Cash above the floor in the Spoke Cap.
- Known?: Partly.
  - core-a H-01 covers only the hub.
  - The REVIEW-LOG spoke builder note "DEC-096-trigger" and ARCHITECTURE §4.7 say that nothing spends Operating Cash yet.
  - Nothing discloses the unbounded parameters, the missing send-home path, the stranger-triggered top-up on arrival, or the cap release. Criterion (b).
  - Severity is High, as in core-a H-01, under a malicious-manager model. It is Medium if DEC-100 is read as accepting it.
  - The spoke-ledger reviewer may report the same root cause. The parts in my scope are the arrival path and the send-home kinds.

### [M-01] A Mandate token the price source cannot price closes every mint and is valued at 0 in every payout, permanently, and nothing checks for it at creation
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/factory/FundFactory.sol:58,108,468`: one factory-wide `IPriceSource` for every fund.
  - `:474` and `:488`: hub pool tokens are read only to register income tokens.
  - `src/mandate/Mandate.sol:300` (`_validatePools`): no token check.
  - `src/report/ChainlinkPriceSource.sol:122`: `UnsupportedToken`.
  - `src/core/CoreVaultLogic.sol:341`: MINT and VIEW modes revert.
  - `:332-338`: PAYOUT mode falls back to `lastPrice`, which is 0 for a token never priced.
  - `:307-317`: a zero amount is valued without a price read, so the token is never priced before the fund holds some.
- Rule: DEC-081 and DEC-105 (one Share Price for every mint and burn); Q57 (b) ruling of 2026-09-29 ("Chainlink for WETH, 1:1 for USDG; other tokens ... to research"); CS-OQ-4; OQ-10.
- What: a Mandate may list any hookless pool.
  - For spoke pools the hub cannot even see the tokens at creation: a pool key is a hash, and the adapter lives on the spoke.
  - For hub pools the factory could check the tokens but does not.
  - As soon as the fund holds any amount of a token the price source lacks (for example a Robinhood stock token), the effects are:
    - every deposit reverts with the price source's `UnsupportedToken`;
    - `shareAssets()` and `spokeCapUsage` revert;
    - every `requestPayout` and `claimPayout` values that holding at 0, with `PriceFallback(token, 0)`.
  - Leavers are paid on Share Assets without that value, and the holders who stay keep it. The manager is a holder by DEC-026.
  - The manager decides when: a swap into the token or a position in its pool turns the effect on.
  - CS-OQ-4 says a zero price is "only reachable for a token that appeared after the last successful deposit or payout". For such a token it is permanent.
- Scenario:
  1. Alice deposits 600,000 and Bob 400,000. 100,000 goes to the spoke, and 99,950 USDG arrive and are reported.
  2. The manager swaps 60,000 USDG into 24 units of a token the price source does not list. A report is delivered.
  3. Carol's deposit of 50,000 reverts with `UnsupportedToken(token)`.
  4. Bob exits in full with an Instant Payout. The claim values Share Assets at 937,450 instead of 997,450. Bob is paid 374,980 gross instead of 398,980, which is 24,000 short.
  5. Alice's shares now carry the whole token position: 622,470 against a fair 598,470.
- PoC: `test/review/spoke-b/M01_UnpriceableSpokeToken.t.sol`.
  - The spoke WETH of the fixture stands in for the unlisted token: the mock price source reverts with `UnsupportedToken`, as `ChainlinkPriceSource` does for an unconfigured token.
  - Command: `forge test --match-path 'test/review/spoke-b/M01_UnpriceableSpokeToken.t.sol' -vv`.
  - Result: 1 passed.
- Fix:
  - Declare each spoke's token list in the Mandate (for example `SpokeConfig.tokens`).
  - In the hub factory, require `priceSource.priceInUsdc(token)` to succeed for every hub pool token and every declared spoke token.
  - In the Spoke Vault constructor, require every pool token to be in that list.
  - Correct CS-OQ-4.
- Known?: No.
  - The Q57 (b) ruling and ARCHITECTURE §5 ("adding a token is a new price source") assume that the price source covers the Mandate.
  - The research recommendation to restrict MVP pools to assets with a push feed on the hub is not enforced.
  - CS-OQ-4 understates the reach. Criteria (a) and (b).
  - Medium, because a leaver who waits avoids the underpayment. The mint shutdown is a denial of service at the manager's choice.

### [L-01] The Spoke Vault books the bridge adapter's `fillDeadline` without checking it, although the Core Vault does
- Status: PLAUSIBLE (defence in depth; the real adapter returns `now + 21,600`)
- Where:
  - `src/spoke/SpokeCrossChainLib.sol:261-266`: checks target and amount only.
  - `:289`: books `call.fillDeadline`.
  - Compare `src/core/CoreVaultLogic.sol:594-597`, which requires `call.fillDeadline > block.timestamp`.
- Rule: IBridgeAdapter custody (the vault verifies what it can); DEC-066.
- What: the booked deadline drives `_stillInFlight` (listing, `:300-302`) and `recognizeRefund` (`:76`). A past or zero value from an adapter would drop the send from every report at once, which makes the core-b H-02 stranding certain if the send is filled. A value that differs from the one encoded would move the listing window.
- Fix: on both sides, require `call.fillDeadline == block.timestamp + IBridgeAdapter(bridge).fillDeadlineSeconds()`.
- Known?: No. The REVIEW-LOG documents the residual trust in the calldata, not this missing check.

### [I-01] The arrival window never drains: after a fund's 256th listed arrival, the report path of `attestExpiry` is off for good, and every delivery costs about 10 times the baseline
- Status: CONFIRMED (PoC passes)
- Where: `src/spoke/SpokeCrossChainLib.sol:168-169` (`n = min(arrivalCount, 256)`, and `arrivalCount` only grows); `src/core/CoreVaultLogic.sol:554`.
- Rule: OQ-09 (`docs/OPEN-QUESTIONS.md:53`, "only while it lists fewer than 256 ids"); ARCHITECTURE §4.2 (`docs/ARCHITECTURE.md:152-156`).
- What: the window holds the last 256 listings of the fund's whole life. Once 256 arrivals of at least 1 USDG were ever listed, every report lists 256 ids. This counts the fund's own sends and costs a stranger 256 USDG. From then on, every expiry waits for the time path. Every routine delivery then rewrites 512 extra words, 2.7M gas against 0.26M (`Measure_FullWindowSteadyState`). That is far above the research's 400k `GAS_CAP` for Q57 (c).
- Scenario: 256 arrivals are listed. Thirty days later a send to the spoke is never filled. A report built after its deadline still lists 256 ids, so `attestExpiry` reverts with `ExpiryNotProvable` until `fillDeadline + maxReportAge`.
- PoC: `test/review/spoke-b/I01_ArrivalWindowNeverDrains.t.sol`, 1 passed.
- Fix: state it in OQ-09 and weigh the delivery cost in Q57 (c). Alternatively, list arrivals by recency (for example only ids credited in the last N days).
- Known?: The rule is documented, but its permanence and its cost are not.

### [I-02] Two cross-chain time rules assume clock skew below one report lifetime; only the receiver's tolerance is documented
- Status: CONFIRMED (by reading, with chain parameters read on-chain)
- Where:
  - `src/core/CoreVaultLogic.sol:548-550`: the time path of `nonArrivalProvable` compares the hub clock with a deadline that the spoke's SpokePool enforces on the spoke clock.
  - `src/spoke/SpokeCrossChainLib.sol:300-302`: pruning compares the spoke clock with a deadline that the hub's SpokePool enforces on the hub clock.
- Rule: CS-OQ-5 (documents only the receiver).
- What: both rules are safe only if the other chain's clock differs by less than `maxReportAge` (1,588 s). If the hub clock lags the spoke clock by more, a transfer home can be filled after the spoke stopped listing it, which is the core-b H-02 stranding.
  - Arbitrum One's SequencerInbox allows block timestamps 86,400 s behind and 768 s ahead of L1 time (`maxTimeVariation()` = 7200, 64, 86400, 768, read from Ethereum mainnet).
  - Normal operation keeps the chains seconds apart. During such a lag, deliveries also revert with `ReportFromFuture`.
- Fix: document the assumption next to CS-OQ-5.
- Known?: Only the receiver's rule, as CS-OQ-5.

### [I-03] Monitoring gaps in the spoke's cross-chain events
- Status: CONFIRMED (by reading)
- Where:
  - `src/interfaces/ISpokeVault.sol:75` / `src/spoke/SpokeCrossChainLib.sol:57`: `SentToHub` omits `exclusiveRelayer`, `exclusivityDeadline` and `quoteTimestamp`. This is the spoke side of core-b I-06 and M-01.
  - `src/spoke/SpokeVault.sol:441` and `:459-462`: `TransitArrived` omits the relayer, and no event says whether an id entered or evicted the 256-id window.
  - `ISpokeVault.sol:81`: `ReportPublished` carries neither the payload size nor its hash, so a keeper cannot see H-01 coming.
  - `SpokeCrossChainLib.sol:86`: `TransitRefundRecognized` is emitted before the escrow release (`:88`).
- Rule: best practice (every operation ends with an event a server can monitor).
- Fix: add these fields.
- Known?: Only the hub and escrow parts, in core-b I-06.

### [I-04] NatSpec and docs that do not match the code
- Status: CONFIRMED (by reading)
- Where:
  - `src/libraries/ReportCodec.sol:85-87`: "whose outcome it does not yet know". The spoke drops a send at `fillDeadline + maxReportAge` whatever its outcome (`SpokeCrossChainLib.sol:300-302`).
  - `ReportCodec.sol:80`: `cumulativeSentHome` "(Q66, DEC-105)". The hub never reads it, and it never falls on a refund.
  - `cumulativeIncome` is informational too. Yet every `report()` calls every adapter's counter for every ledger token (`SpokeCrossChainLib.sol:149`), which is O(tokens × positions) with the V4 adapter.
  - `SpokeCrossChainLib.sol:75`: a refunded transit reverts with `UnknownTransit`.
  - `docs/INTEGRATIONS.md:77`: says a full window "adds about 16 KB". It costs 12.9M gas on first store and 2.7M on every later delivery.
- Rule: best practice (NatSpec matches the code).
- Fix: update the texts, and consider dropping the informational counters from the report.
- Known?: No.

## Checks and validations

| Function | Access control | Input validation | Reentrancy guard | CEI order | Event | Gaps |
|---|---|---|---|---|---|---|
| `SpokeVault.sendToHub` (+ lib) | `onlyOnSpokeChain`, `onlyManager` | amount > 0; 0 < output ≤ amount; fee ≤ `maxBridgeFeeBps`; rank < n; pinned codehash; bucket balance by kind; built target = pinned; `amountToArrive` = quote | `nonReentrant` | top-up, debit, clone + init, build (STATICCALL), book, then approve / call / exact debit / reset | `SentToHub` (last) | no minimum amount and no cap on live sends (H-01); `fillDeadline` unchecked (L-01); exclusivity passed through (core-b M-01); event fields (I-03) |
| `SpokeVault.recognizeRefund` (+ lib) | anyone, spoke only | state Sent; after `fillDeadline`; escrow ≥ `amountSent` | `nonReentrant` | state, prune, credit, then release, then balance-delta check | `TransitRefundRecognized` (before release) | error name (I-04) |
| `SpokeVault.report` (+ `nextReport`) | anyone, spoke only, payable | none needed; the Core requires `msg.value == messageFee()` | `nonReentrant` | prune + sequence, build (STATICCALLs), then publish | `ReportPublished` (last) | unbounded size (H-01); no size in the event (I-03) |
| `SpokeVault.handleV3AcrossMessage` | Across SpokePool only; spoke only | base token; amount > 0; message version, fund id, origin = hub chain | `nonReentrant` | credit, listing, backed check, event, then top-up (no external call but `balanceOf`) | `TransitArrived`, then top-up events | top-up into a dead end (H-02); listing not evented (I-03) |
| `SpokeCrossChainLib` external non-view functions | DELEGATECALL only (library call guard) | as their entries | via entries | as above | as above | none |
| `ValueReportReceiver.deliver` | anyone | Core Bridge verification; consistency 1; Mandate emitter; VAA sequence > last; codec version; fund id; spoke chain id; report sequence > last; age ≤ `maxReportAge`; timestamp ≤ now + `maxReportAge` | `nonReentrant` | verify (STATICCALL), decode, store, event, then `onReportAccepted` | `ReportAccepted` | stores the whole payload (H-01); `variationBandBps` unused (known Q57 d) |
| `ValueReportReceiver` constructor | deployer | non-zero bridge, vault, fund; complete spokes; no duplicate emitter; band ≤ 100% | n/a | n/a | none | none |
| `TransitEscrow.initialize` / `release` (spoke use) | once (clone and init in the same transaction, CREATE2 from the vault only) / vault only | non-zero vault and token | n/a | single transfer | none | no events (core-b I-06) |
| `ChainlinkPriceSource` constructor | deployer | non-zero token and feed; `maxPriceAge` > 0; no duplicate; decimals bounded | n/a | reads `decimals()` | none | no coverage check against Mandates (M-01) |

## Checked and found correct
- **Lead 1 (report bloat)**: confirmed with a correction, see H-01.
  - Delivery breaks first, at about 410 one-unit sends home (not 1,000), about 270 Income sends, or about 143 dust positions.
  - A stranger's 256 arrivals use 12.9M gas and cannot break delivery alone.
  - `report()` on Robinhood breaks only at about 3,200 live or 2,300 expired sends.
  - Mints close through staleness after deliveries stop.
  - Payouts are never blocked: reading costs 2.6k gas per stored word against at least 3.7k to write it, and the stored report is bounded by one delivery.
- **Lead 2 (Across late and slow fills): refuted for fills, residual clock-skew assumption in I-02.**
  - On the live Arbitrum SpokePool (implementation `0xcfcd…`, block 510,382,003), a fill one second past `fillDeadline` reverts with `ExpiredFillDeadline()`, and so does a slow-fill request. A fill at the deadline goes through (`Fork_AcrossDeadlineAndDustSends`).
  - Both live implementations expose `fillRelay`, `fillV3Relay`, `requestSlowFill`, `executeSlowRelayLeaf`, `speedUpDeposit` and that error (selectors in the bytecode).
  - So no fill can land after `fillDeadline` on the destination clock. The spoke's "presumed filled" at `fillDeadline + maxReportAge` never drops a send that can still be filled; the value gap until the refund is core-a H-02.
  - The live Robinhood pool accepts USDG to Arbitrum-USDC deposits, including one-unit ones through the real adapter.
  - Could not establish from code:
    - whether relayers fill USDC to USDG and back, or dust;
    - whether Across's dataworker ever builds slow-fill leaves for non-equivalent tokens (off-chain; I expect not);
    - refund timing and whether dust deposits are refunded;
    - `executeSlowRelayLeaf` past the deadline, which needs a root bundle, so it was not executed on the fork.
- **Lead 3 (clock skew), rule by rule.**
  - Receiver age and future bound: CS-OQ-5, documented.
  - `isReportFresh`: same frame as delivery.
  - `nonArrivalProvable` report path (`r.timestamp > fillDeadline`): both sides use the spoke clock, because the destination SpokePool enforces the deadline on its own clock (fork-verified on Arbitrum). This is correct under any skew.
  - Time path and spoke pruning: they assume a skew below `maxReportAge` (I-02).
  - `recognizeRefund` on either side: the origin clock is only a precondition; the gate is a refund actually in the escrow.
  - `quoteTimestamp` and `fillDeadline` bounds at deposit: origin chain only.
- **Codec.**
  - `abi.encode(2, report)` and `decode` are symmetric for empty and full arrays (repository tests plus my `buildReport` versus `report()` equality).
  - Any other version reverts, a payload under 32 bytes reverts, and a malformed body reverts (enum and address ranges are validated).
  - A signed payload can only come from the fund's own `report()`. A decode failure reverts the delivery, and nothing is stored.
- **`buildReport` assembly and `_positionReport` MCOPY.**
  - The returned tail is the ABI encoding of the report; tuple-relative offsets survive the move.
  - `IAdapter.PositionValue` and `PositionReport` match field for field (11 words plus the adapter).
  - `test_refute_buildReportAndReportDisagree` shows identical reports in one block, with pruning pending.
- **Building cannot be made to revert by a stranger.**
  - Arrivals are bounded to 256 ids.
  - V4 fee growth uses unchecked subtraction.
  - The V4 adapter never drops a registered key without a close: `decreasePosition` requires liquidity below the position's (`UniswapV4Adapter.sol:440-442`). So the REVIEW-LOG spoke minor at `SpokeVault.sol:708` is unreachable with it.
- **Ring and arrivals.**
  - Oldest first across wrap-around (`test_refute_ringIndexingWrapsWrong`).
  - Each id is listed at most once. Income-kind fills never count per id.
  - Listing uses the current credited total.
  - Every revert path of a genuine fill was enumerated (caller, chain, token, zero, message, fund, origin, backed check). None can fire, including with the top-up running, a full window and a stranger pre-crediting the same id (`test_refute_genuineFillCanRevertOnTheSpoke`).
  - Predictable future hub transit ids let a stranger pre-list an id and schedule the known OQ-09 "listed once, never again" eviction in advance. There is no new consequence beyond core-b H-01.
- **Refunds on the spoke.**
  - Credited once, to the debited bucket, and still possible after pruning (`test_refute_refundDoubleCreditOrLostAfterPruning`).
  - Credit only when the escrow holds `amountSent`. Exact delta on release. A donation-funded refund is paid by the donor. The escrow is keyless, with no EIP-1271.
- **Receiver.**
  - `parseAndVerifyVM` checks: VM version 1, a guardian set not expired unless current, quorum, strictly increasing guardian indices (no duplicate signer), and ecrecover per key.
  - Everything left to the application is implemented: emitter pair, both sequences, consistency 1 (the SDK's finalized value), fund id, chain id, age.
  - No replay across funds, spokes or chains.
  - A newer report delivered first makes older ones undeliverable with no loss, except the core-b H-02 family.
  - A callback revert rolls back the whole delivery (known push issue).
  - Storage per spoke is one payload, overwritten; a shorter payload clears the tail.
- **Pricing arithmetic.**
  - `price1e18 = answer * 10^24 / 10^(feedDecimals + tokenDecimals)`, correct for every decimals combination (WETH gives 2.5e9 per wei). Fixed tokens use `10^(24 - decimals)`.
  - Answers ≤ 0 and prices that round to zero revert. `maxPriceAge` is per token and applies to mints only.
  - Stances known and not re-reported: no sequencer-uptime check, no min/max answers, USD read as USDC, USDG at 1:1, payouts at stale prices.
  - Keying by spoke-chain addresses: the configured addresses do not collide, and the Core Vault values hub USDC at face value.
- **Reentrancy and ordering.** Every entry in scope is `nonReentrant`. The external calls are:
  - adapters, by STATICCALL on the report path;
  - the pinned SpokePool;
  - the fund's own escrow;
  - the Core Bridge (a view on the hub; publish on the spoke, after the state changes);
  - the Core Vault callback (receiver-only, `nonReentrant`).
- **Wormhole fee.** `report()` forwards `msg.value`, and the real Core requires it to equal `messageFee()` (0 today). No ETH is kept.
- **Slither in my files, all false positives.**
  - `reentrancy-balance` ×3 (`_executeBridgeCall`, `recognizeRefund` ×2): intended exact-delta checks, pinned target or own escrow, guarded.
  - `incorrect-equality` in `latestReport`: a sentinel.
  - `uninitialized-local` `req`: every field is assigned.
  - `unused-return` of `release` and of the feed's round fields: the delta is checked; `answeredInRound` is deprecated.
  - `reentrancy-events` in `sendToHub`: the event is last by design.
  - `timestamp`: the design's clock.
  - `assembly` and `low-level-calls`: verified above.
  - `calls-loop` on `_build` and `cumulativeIncome`: the one lead that points at a real root cause, H-01.
- **Aderyn in my files.**
  - H-2 (locked Ether), H-3 (state change after a call: constructor, a view, `balanceOf`) and H-6 (Yul `return`): false positives for the reasons above.
  - L-3, L-4, L-5 and L-7: style.
  - L-7 (modifier order): the checks before `nonReentrant` make no external call.
  - L-9 (escrow `initialize` emits no event): known, core-b I-06.
  - L-12: the delta is checked.

## Not covered
- `report()` gas with the real Uniswap V4 adapter at hundreds of positions: estimated from the mock adapter only. The hub breaks earlier in any case.
- Delivery through the real Arbitrum Core at bloated sizes: measured with the Core Bridge stand-in. The real Core adds about 146k gas and more calldata, which only strengthens H-01.
- Whether Wormhole guardians sign arbitrarily large payloads.
- Across off-chain behaviour: relayer willingness, dataworker slow-fill eligibility and refunds of dust.
- Robinhood Chain's own sequencer time bounds: only Arbitrum One's were read.
- The spoke ledger beyond the arrival path, owned by another reviewer: position and swap verbs, the unwind, and the principal-to-income wash-trade path (FV-16 class) that core-b left open.
