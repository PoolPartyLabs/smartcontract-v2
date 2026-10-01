# Integration review: the cross-chain family on the factory-created fund, a value-conservation walk, and why the tests missed the findings (integration-xchain)

Reviewer slug `integration-xchain`, repository `PoolPartyLabs/smartcontract-v2` at `e5c778a`, working copy `smartcontract-v2-b`.
Tests in `test/review/integration-xchain/` (6 files, 15 fork tests, all passing). Every test builds on the project's own
harness (`test/fork/e2e/EndToEndBase.sol`, `EndToEnd.t.sol`): one fund created by the real `FundFactory` on an Arbitrum
fork and a Robinhood fork, with the real Uniswap V4, Aave V3, Chainlink and Wormhole contracts. Where the project's
scenario simulates a step, these tests do it for real:
- **Fills** go through the live SpokePools' `fillRelay` with the relay data of the live `FundsDeposited` event. The pool
  transfers the output token and calls the vault's handler itself (the project deals tokens and calls the handler as the
  pool).
- **Reports** are published on the real Robinhood Core and delivered through the real Arbitrum Core, which verifies 13 of
  19 guardian signatures (WormholeOverride keeps the mainnet guardian-set size). Delivery happens 1,000 s after
  publication (the finalized VAA latency; the project delivers at age 0).
- **Refunds** of expired deposits go through the live pool's `executeRelayerRefundLeaf`, after the HubPool's
  `relayRootBundle` admin call (see "Checked and found correct" for how the admin call is reproduced on each pool).

Command for every file (the public RPCs keep only recent state):
```
export ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ROBINHOOD_RPC_URL=https://rpc.mainnet.chain.robinhood.com
export ARBITRUM_FORK_BLOCK=$(( $(cast block-number --rpc-url $ARBITRUM_RPC_URL) - 100 ))
export ROBINHOOD_FORK_BLOCK=$(( $(cast block-number --rpc-url $ROBINHOOD_RPC_URL) - 100 ))
forge test --match-path 'test/review/integration-xchain/<File>.t.sol' -vv
```
Last full run, one file at a time, all passing (Arbitrum / Robinhood fork blocks): `Fork_SpokeCapBypass` 2 tests
(510410266 / 76687017), `Fork_TransferHome` 3 (510410698 / 76688177), `Fork_ReportBloat` 3 (510409705 / 76685476),
`Fork_SpokeCreation` 2 (510410819 / 76688496), `Fork_RelayerAndOperatingCash` 4 (510410934 / 76688797),
`Fork_ConservationWalk` 1 (510411056 / 76689112). Shared base: `XChainBase.sol`. Wall time 29 s to 130 s per file.

## Summary
- Every cross-chain finding I was asked to test reproduces on the integrated system: ten findings from reports 02, 03,
  04, 05 and 07, in 14 tests. None is refuted. The real stack changes numbers in one place only: the
  report-bloat thresholds (about 145 positions, 391 sends home, or 225 sends once a stranger has filled the arrival
  window). The Across refund delay I measured on chain is also longer than the documented one (I-02).
- The conservation walk has 28 steps and covers every flow of the scenario plus a send home of each kind, a refund in
  each direction and a donation. After a fresh report, holdings and books agree within 3 base units at every step
  except five: the known 02 I-04 and 02 H-02 gaps, the bridge fee returned at a refund, and the donation. With the
  books as they stand, three more steps diverge. W4 and W5 show the new I-01 (10 USDG counted twice until the next
  report; W5 adds report lag). W13 shows the documented hold-apart: 500 USDC counted in the last report and in
  `unmatchedArrivals`.
- The tests missed the findings for four reasons:
  - the hub unit tests only receive hand-written reports, never what the real spoke builds over time;
  - fills and deliveries are simulated, at report age 0;
  - mock values are inputs, so the spot price equals the oracle;
  - the DEC-104 checks rebuild Share Assets from the vault's own views.
- New findings: Critical 0, High 0, Medium 0, Low 0, Info 3.

## Reproduction table

Numbers are for the project's own Mandate plan unless stated: Ana's 10,000 USDC first deposit, Spoke Cap 4,000 USDC, a
4 bps bridge-fee maximum, `maxReportAge` 1,588 s, spoke Operating Cash floor 5 and top-up 10 USDG.

| Earlier finding | Result | Test (`test/review/integration-xchain/`) | Key numbers on the integrated system | What the real stack changed |
|---|---|---|---|---|
| 03 H-01 (A): Spoke Cap exceeded through the time path, reports withheld | REPRODUCED | `Fork_SpokeCapBypass.t.sol` `test_H01A_fork_withheldReports_capReleasedForTransitsThatArrived` | Three 4,000 USDC sends, each filled by the live Robinhood `fillRelay`. After each, `attestExpiry` by a stranger at `fillDeadline + 1,589 s` sets cap usage to 0, and mints stay open (no report was ever accepted). The spoke then holds 11,985.20 USDG, and the first delivered report confirms all three: `spokeValue` 11,985.20, three times the cap. | Nothing. The earlier PoC used mock pools and a Core Bridge stand-in. |
| 03 H-01 (B): the manager fills its own send plus 256 one-USDG fills in one Robinhood transaction | REPRODUCED | `test_H01B_fork_managerFlushesTheWindowWhileReportsFlow` | Each cycle: the manager names its own relayer contract exclusive and makes 256 real 1 USDC to 1 USDG deposits on Arbitrum. The contract fills the genuine deposit and the 256 in one transaction. Every report is fresh and deposits keep working. Report after report lists 256 dust ids and never the genuine one, and the time path releases the cap. After three cycles the spoke holds 12,753.20 USDG (3 × 3,998.40 plus 768 of the manager's dust, less 10 of Operating Cash), cap usage is 0, and a fourth 4,000 send is accepted. In-flight Value is 15,993.60 and Share Assets 32,898.29. | The live pool enforces exclusivity, so the eviction is deterministic, as 03 M-01 said. Cost per cycle: 256 USDG plus 256 deposits (the manager's relayer is repaid the inputs by Across). |
| 03 H-02: a filled transfer home that no accepted report listed in time stays in `unmatchedArrivals` | REPRODUCED | `Fork_TransferHome.t.sol` `test_H02core_fork_filledTransferHomeNotListedInTimeIsStrandedForGood`, control `..._control_oneReportInsideTheWindowCreditsIt` | Send home of 3,988.40 USDG, filled by the live Arbitrum pool 2 min later. The pool calls `CoreVault.handleV3AcrossMessage` and 3,986.90 USDC is held apart. No report until `fillDeadline + maxReportAge`, then reporting resumes. Share Assets fall from 9,963.40 to 5,975.00, `unmatchedArrivals` stays at 3,986.90 through three more reports, and `sweepExcess` returns 0. Control: one report inside the window credits it to Idle, and only the 1.50 fee is gone. | Nothing. |
| 02 H-02: an unfilled transfer home is in no base between `fillDeadline + maxReportAge` and its reported refund | REPRODUCED | `test_H02payout_fork_unfilledTransferHomeLeavesEveryBaseUntilItsRefundIsReported` | Send home of 3,988.40, exclusive to the manager's relayer. A stranger's fill reverts `NotExclusiveRelayer`, and after the deadline the manager's own fill reverts `ExpiredFillDeadline`. The first report built after `fillDeadline + 1,588 s` omits it: Share Assets fall from 9,963.40 to 5,975.00, Share Price 0.5990. Bruno deposits 10,000 in the window (fresh report, fresh prices). The refund is paid through the live pool's refund leaf at deadline + 55 min and recognized. The next report restores the Share Price to 0.7488. Bruno's 10,000 is now worth 12,468.77 (+24.7%), and Ana's value falls from 9,963.40 to 7,469.13 (−25.0%). | The refund path is now real. The window length is measured: see the next paragraph. |
| 05 H-01: the manager grows a spoke report until delivery exceeds 32M gas | REPRODUCED, thresholds refined | `Fork_ReportBloat.t.sol`, 3 tests | Gas is `deliver()` execution through the real Arbitrum Core plus intrinsic cost, measured from the same small stored report with storage cooled. **Positions** (real V4 adapter, 1 USDG base unit each): 140 cost 30.75M and fit; 160 cost 35.31M and do not; about 220k per position, limit about 145. **Sends home** (1 unit each, live pool): 350 cost 28.62M; 420 cost 34.37M and do not fit; about 82k per send, limit about 391. **Arrivals**: a stranger's 256 cost 13.64M, then 150 sends 25.81M, then 250 sends 34.01M (does not fit), limit about 225 sends. `report()` on Robinhood is 13.06M at 160 positions (about 82k per position with the real adapter), so the hub breaks first. A deposit after a 160-position report costs 5.13M gas. | The Core's signature check and parse cost 0.77M to 4.78M of the delivery, about 2,400 gas per payload word. Limits move from about 143 to 145 positions, 410 to 391 sends and 245 to 225 sends. The real Robinhood Core publishes a 62,592-byte payload, and the real Arbitrum Core parses and verifies its VAA; only the 32M cap (re-read from ArbGasInfo on both chains) stops delivery. |
| 07 H-01: a send before `createSpoke` | REPRODUCED | `Fork_SpokeCreation.t.sol` `test_H01factory_fork_sendBeforeCreateSpokeIsLostYetCountedForGood` | The live Robinhood pool fills the codeless predicted Spoke Vault, `fillStatuses(relayHash)` becomes Filled (2), and no handler runs. `createSpoke` from the hub's own Mandate passes the `mandateHash` check, and `sweepExcess` sends 3,998.40 USDG to the Protocol Recipient. The genuine report proves non-arrival and `attestExpiry` succeeds; `recognizeRefund` reverts `NoRefund` for good. Share Assets read 9,973.40 against 5,975.00 of Idle. Bruno deposits 10,000; Ana exits Instant with 8,797.07 although her real assets were at most 5,975.00. Idle 6,949.84 is left against Bruno's book value of 9,974.40. | The live pool marks the relay Filled, so Across can never refund it. |
| 07 H-02: a spoke from a Mandate that differs from the hub's | REPRODUCED | `test_H02factory_fork_divergentSpokeMandateDrainsAndTheHubAcceptsEverything` | A spoke built from the hub's Mandate refuses the drain (`BridgeFeeAboveMax(3,988.399999, 1.59536)`). The real factory creates a spoke with `maxBridgeFeeBps` 10,000 at the address the hub names, and the hub accepts its reports. It sends home 3,988.40 for an output of 1, exclusive to the manager's relayer. The relayer fills 1 unit on Arbitrum, credited as listed, and is repaid 3,988.40 USDG through the live pool's refund leaf. Share Assets fall from 9,963.40 to 5,975.000001, cap usage is 0, and the next send is accepted. | Nothing. |
| 03 M-01: the manager as exclusive relayer at the maximum fee | REPRODUCED | `Fork_RelayerAndOperatingCash.t.sol` `test_M01_fork_managerIsTheOnlyRelayerAtTheMaximumFeeBothWays`, `test_M01_fork_hundredPercentBridgeFeeMandateThroughTheRealFactory` | Both live pools accept the exclusive deposits (`exclusivityDeadline` = send time + 21,600). A stranger's fill reverts `NotExclusiveRelayer` on both pools, and the manager's relayer fills. It is repaid 4,000 USDC for 3,998.40 USDG and 3,988.40 USDG for 3,986.80 USDC, keeping 3.195 USDC per round trip (8 bps) before the LP fee. With a 10,000 bps Mandate, which the real factory creates: one send moves 3,999.999999 out of Share Assets, and the relayer is repaid 4,000 USDC for 0.000001 USDG. | The Across side, which the earlier PoC argued, is now executed. |
| 02 H-01: hub Operating Cash, unbounded and one-way | REPRODUCED | `test_OC_fork_hubOperatingCashSinksFreeIdle` | 14,949.999999 USDC of Free Idle moves into hub Operating Cash with one parameter change and a 1-unit allocation. `sweepExcess` returns 0, and resetting the parameters returns nothing. Bruno's reserved Standard request for 5,000 then burns all 9,975 of his shares for 2,493.75. | Nothing. |
| 04 H-02 / 05 H-02: spoke Operating Cash | REPRODUCED | `test_OC_fork_spokeOperatingCashSinksThePrincipalAndFreesTheCap` | A stranger makes a real 1 USDC deposit on Arbitrum and a real 1 USDG fill on Robinhood. The top-up moves the spoke's 3,988.40 into Operating Cash. Share Assets fall from 19,938.40 to 15,949.00, `sendToHub` reverts, `sweepExcess` returns 0, and cap usage is 0. The next 4,000 tranche sinks too: spoke Operating Cash 7,997.80 (twice the cap), Share Assets 11,949.00. | The stranger's trigger is a real Across deposit and fill. |

**The real length of the 02 H-02 window.**

What the fork shows:
- A fill one second after `fillDeadline` reverts `ExpiredFillDeadline` on Arbitrum, the destination of a send home.
- An expired deposit's refund reaches the escrow only through a root bundle that the HubPool relays, then
  `executeRelayerRefundLeaf`.
- `recognizeRefund` credits exactly `amountSent`.
- The value leaves Share Assets when the first report built after `fillDeadline + 1,588 s` is delivered, 15 to 20
  minutes after it is published.

What the live chains show (read-only RPC queries, 2026-09-30; they are observations, not fork tests):
- HubPool `liveness()` is 1,800 s.
- Over the last 27.7 h, 53 root bundles reached the Robinhood SpokePool, one every 23.9 to 38.8 min (median 32.9).
- For 10 proposals matched by root, the relay reached Robinhood 50.5 to 55.6 min after the Ethereum proposal.
- For 104 executions, the refund leaves ran 2.8 to 13.1 min (median 5.5) after the relay.

What is only documented: `docs/DECISIONS.md:279` gives 55 to 90 min after `fillDeadline` from Robinhood. The dataworker's
rule for including an expired deposit, and its end-block lag, are off-chain.

Combined:
- The refund lands about 53 to 107 min after the deadline.
- The value is out of every base from about deadline + 43 min until the first report built after `recognizeRefund` is
  delivered, about deadline + 70 to 127 min.
- That is roughly **25 to 85 minutes** when keepers act at once, and open-ended if nobody calls the permissionless
  `recognizeRefund`.
- In the test it lasted 28.5 min (value out at deadline + 2,589 s, back at deadline + 4,300 s), with the refund at the
  documented minimum.

## Conservation walk

`test/review/integration-xchain/Fork_ConservationWalk.t.sol` `test_walk_fork_valueConservationOverTheScenario`, one
fund, both forks. The sequence follows the project's scenario:
- phases 1 to 4, 8 and 9 are called as they are;
- phase 5's simulated fill is replaced by a real `fillRelay`; its spoke position and fee swings use the project's own
  helpers;
- phase 6's delivery is replaced by one 1,000 s after publication;
- phase 7 is run step by step (collect, forward, Bruno's deposit, Ana's income withdrawal);
- phase 10's donation and sweep are run as two steps;
- added: spoke income collected and swapped, a send home as Income and as Principal (real deposits and fills), a refund
  in each direction (real refund leaves), and a fresh deposit before the refunds.

After every step two totals are computed in USDC through the fund's own `ChainlinkPriceSource`:
- **(a) holdings:**
  - token balances (USDC, USDG and both WETHs) of the Core Vault, both Spoke Vaults and all five adapters, plus the
    escrow of every transit;
  - the fund's aUSDC;
  - what each V4 position would return (principal plus fees, from the PoolManager's state);
  - Across deposits of the fund that are neither filled nor refunded, at their output amount.
- **(b) books:** Share Assets, Operating Cash on each chain, collected income on each chain (Core Vault, hub Spoke Vault,
  spoke), uncollected position income on each chain, and `unmatchedArrivals`.
  - In-flight Value is inside Share Assets.
  - Attributed Income owed is a claim inside the Core Vault's collected income, so it is not added. The walk instead
    asserts at every step that owed never exceeds collected (Q60); it held throughout.

D = (a) − (b). A positive D is value the fund holds that no book counts; a negative D is value counted in two books.
"D now" uses the books as they stand. "D fresh" is D after one more report is published and delivered (on a snapshot
that is then reverted). It separates report lag, where the hub has not yet seen the spoke, from real gaps.

| Step | What happens | (a) holdings, USDC | D now | D fresh | Classification |
|---|---|---:|---:|---:|---|
| W0 | fund created on both chains | 0 | 0 | 0 | agrees |
| W1 | Ana deposits 10,000 | 9,975.000000 | 0 | 0 | agrees |
| W2 | allocation 5,000; Aave 2,000; hub V4 position; trader swings earn fees | 9,973.358252 | 0.000001 | 0.000001 | rounding |
| W3 | send 4,000 to Robinhood (live `depositV3`) | 9,971.758252 | 0.000001 | 0.000001 | rounding |
| W4 | real fill on Robinhood; the arrival tops up 10 USDG of spoke Operating Cash; no report yet | 9,971.758252 | **−9.999999** | 0.000001 | **New, I-01**: the top-up is counted in In-flight Value and in spoke Operating Cash until the next report |
| W5 | spoke swap 1,500 USDG to WETH, V4 position, trader swings | 9,970.483133 | −11.828839 | 0.000001 | I-01 (−10), plus report lag of the swap's market cost (−1.83); documented: spoke value only through reports (DEC-070, Q57 reading) |
| W6 | report delivered | 9,970.485020 | 0.000001 | 0.000001 | agrees |
| W7 | hub income collected (V4, Aave) | 9,970.485019 | 0.000001 | 0.000001 | agrees |
| W8 | hub income forwarded, fees split and paid out | 9,970.365262 | 0.000001 | 0.000001 | agrees (fees leave both sides) |
| W9 | Bruno deposits 11,000 | 20,942.105106 | 0.000001 | 0.000001 | agrees |
| W10 | Ana withdraws her income | 20,941.626076 | 0 | 0 | agrees |
| W11 | spoke income collected, WETH swapped to USDG in the collected bucket | 20,941.626390 | −0.000022 | 0.000001 | report lag (the swap nudged the pool) |
| W12 | sends home: Income 0.553832 and Principal 500 (live deposits) | 20,941.426169 | +0.353809 | **+0.553832** | **Known, report 02 I-04**: Income in flight home is in no base (out of the spoke bucket, out of Share Assets by DEC-092, no hub bucket). D now also has −0.2, the Principal send's fee still inside the stale report. |
| W13 | both filled on Arbitrum (live `fillRelay`), held apart | 20,941.426396 | **−500.000022** | 0.000001 | Documented, OQ-01 hold-apart plus report lag. The Principal 500 is in the last report and in `unmatchedArrivals`; Share Assets count it once, so the price is right. The project's `_sumOfBuckets` check passes here. |
| W14 | report lists both: Principal to Idle, Income split | 20,941.317517 | 0.000001 | 0.000001 | agrees |
| W15 | Ana's Standard Payout of 3,000 (phase 8) | 17,942.553600 | 0.000001 | 0.000001 | agrees |
| W16 | Bruno's Instant Payout above Free Idle with automatic unwind (phase 9; target 1,019.16) | 7,705.225317 | 0.000002 | 0.000002 | agrees (market cost of the unwind on both sides) |
| W17 | fresh report, Carol deposits 5,000 | 12,692.461072 | 0.000002 | 0.000002 | agrees |
| W18 | send 400 to Robinhood, never filled | 12,692.301072 | 0.000002 | 0.000002 | agrees |
| W19 | past the deadline: report, `attestExpiry` (report path) | 12,692.343826 | 0.000002 | 0.000002 | agrees |
| W20 | Across refund leaf pays 400 to the hub escrow | 12,692.503826 | **+0.160002** | +0.160002 | Documented: the bridge fee comes back at `recognizeRefund` (02 and 03 "checked and found correct") |
| W21 | `recognizeRefund` on the hub | 12,692.503826 | 0.000002 | 0.000002 | agrees |
| W22 | send home 300, exclusive, never filled; report lists it | 12,692.385713 | 0.000002 | 0.000002 | agrees |
| W23 | past `fillDeadline + maxReportAge`: report omits it | 12,692.429465 | **+299.880002** | **+299.880002** | **Report 02 H-02**: in no base even with a fresh report. The project's `_sumOfBuckets` check passes here. |
| W24 | Across refund leaf pays 300 to the spoke escrow | 12,692.549465 | **+300.000002** | **+300.000002** | 02 H-02, same window |
| W25 | `recognizeRefund` on the spoke, report | 12,692.551352 | 0.000002 | 0.000002 | agrees |
| W26 | 1,234 USDC donated to the Core Vault | 13,926.551352 | **+1,234.000002** | +1,234.000002 | Documented: unledgered until swept (DEC-080, DEC-101) |
| W27 | `sweepExcess` | 12,692.551352 | 0.000002 | 0.000002 | agrees |

The walk asserts every row: |D| ≤ 0.001 USDC, or the expected divergence within 0.001 USDC. The only row not asserted is
W5 "D now", where the swap's market cost varies from run to run.

What the walk does not see: it checks totals, not classification. A unit moved from principal to income, as in the
wash-trade finding 06 M-01, keeps D at 0, because both totals include income.

## Why the tests missed it

### The closest existing test for each Critical and High of reports 02 to 07

| Finding | Closest existing test | What in its setup hides the problem |
|---|---|---|
| 02 C-01, Share Price at the V4 spot composition | `test/unit/v4/UniswapV4Adapter.t.sol:398` `test_DEC079_principalTracksPrice`; `test/unit/core/CoreVaultDeposit.t.sol:123` `test_DEC080_directTransferNeverChangesSharePrice`; `invariant_DEC080_directTransferNeverMovesSharePrice` | **Adapter test:** pins the spot dependence as correct (principal follows `setTick`), and no Core Vault test values a position whose composition moved. **Core Vault suites:** they use `MockHubSpokeVault`, whose position principal is a number the test writes (`CoreVaultInvariant.t.sol:106` `movePrice` sets it directly), so there is no pool, no spot and no oracle to disagree. The "third party never moves the price" property covers only token transfers to the vault. **Fork scenario:** it moves the real pool only in `_generateFees` and returns it to the starting tick (`EndToEndBase.sol:262-266`) before valuing. Its `_sumOfBuckets` prices with the vault's own formula (spot amounts times the oracle). |
| 02 H-01, hub Operating Cash | `test/unit/core/CoreVaultSetup.t.sol:142` `test_DEC096_belowFloorTopsUpFromShareAssetsOnNextOperation` | Uses DEC-096-scale values (floor 1, top-up 3 USDC) and asserts only that the top-up happened. No test sets a larger top-up or looks for an outflow, and the invariant handler never calls `setOperatingCashParameters`. `invariant_DEC080_balanceCoversLedger` is one-sided (balance ≥ ledger) and stays true while cash is locked. `invariant_DEC104_shareAssetsEqualBuckets` compares Share Assets with `_bucketSum()` (`CoreVaultFixture.sol:254-264`), which is built from the vault's own `inFlightValue()` and `spokeCapUsage()`, so moving value into a bucket outside Share Assets cannot break it. |
| 02 H-02, unfilled transfer home dropped before its refund | Hub: `test/unit/core/CoreVaultAdversarial.t.sol:90` `test_DEC104_principalReturnLegKeepsSharePriceThroughTheFill`, `CoreVaultTransit.t.sol:401` `test_DEC085_listedReturnLegCountsInFlightUntilArrival`. Spoke: `test/unit/spoke/SpokeVaultSpoke.t.sol:848` `test_OQ09_hubBoundTransitDroppedAfterDeadlinePlusMaxReportAge` | The hub tests deliver hand-written reports (`_inFlightToHub(...)`) that keep listing the transfer until the test fills it. No hub test receives the report the real spoke builds after `fillDeadline + maxReportAge`. The spoke test asserts the prune and the later refund on the spoke ledger only; it ends with Unallocated Balance back at 1,000 and never values the hub in between. |
| 03 H-01, Spoke Cap bypass | `test/unit/core/CoreVaultConsolidateVerifyRound2.t.sol:104` `test_OQ09_strandedTransitReleasesItsSpokeCapAtTheTimePathExpiryAndStaysCountedOnce`; `test/unit/spoke/SpokeVaultAdversarial.t.sol:132` `test_OQ09_evictionNeedsAFullWindowOfListableArrivals` | **Hub test:** runs exactly the bypass (a transit the spoke credited but never listed, attested through the time path) and asserts it as correct. It checks `inFlightSent == 0` and that Share Assets count the value once, but never compares the cap terms with what the spoke holds. **Spoke test:** shows the eviction; its NatSpec says the eviction "cannot turn into a double count", and it stops before the hub's time path. No invariant handler ever sends to a spoke. |
| 03 H-02, filled transfer home stranded | `test/unit/core/CoreVaultTransit.t.sol:386` `test_OQ01_arrivalHeldApartUntilReportListsIt`; `test_OQ01_fabricatedIdNeverReachesABase` | The listing report is delivered right after the fill, and no test lets `fillDeadline + maxReportAge` pass between the fill and the first listing report. The fabricated-id test pins "held apart, never swept" as intended, and the same branch strands a genuine id. |
| 04 C-01, unwind sized and executed at spot | `test/unit/spoke/SpokeVaultHub.t.sol:223` `test_QA3_unwindSwapFloorFromSpotPriceAndHintsOnlyTighten`; the fork scenario's phase 9 (`EndToEnd.t.sol:619-655`) | **Unit test:** `MockPositionAdapter.spotQuote` returns the same fixed rate the mock swaps at (`test/mocks/spoke/MockPositionAdapter.sol:273-276`), and nobody can move it. **Fork scenario:** runs the unwind at the starting tick, and `_unwindHints` (`EndToEnd.t.sol:714-732`) passes a minimum 3% below the Chainlink price. The test gives the vault the oracle guard it lacks; a hostile claimant passes empty hints. |
| 04 H-01, deprecated V4 adapter blocks the unwind | `test/unit/spoke/SpokeVaultSpoke.t.sol:271` `test_DEC056_exitVerbsWorkWhilePausedOrDeprecated`; `test/unit/v4/UniswapV4Adapter.t.sol:187` | Asserts that the swap reverts after `deprecate` and that the close works, then stops. It never asks what becomes of the WETH the close returned, and no unwind test deprecates an adapter. The adapter test pins "swap blocked" as intended. |
| 04 H-02 and 05 H-02, spoke Operating Cash | `test/unit/spoke/SpokeVaultSpoke.t.sol:417` `test_DEC096_arrivalIsAnOperationThatTopsUpFromUnallocated`, `:467` `test_DEC096_managerAdjustsFloorAndTopUp` | Values are at the DEC-096 scale, and the second test only checks that the setter stores 20 and 30. The spoke invariant handler has no `setOperatingCashParameters` action, and its only value invariant is ledger ≤ balance. |
| 05 H-01, report bloat | `test/fork/receiver/ValueReportReceiverFork.t.sol:88` `test_DEC093_forkAcceptsFinalizedReportFromSpokeVault`; `SpokeVaultSpoke.t.sol:558` | **Fork test:** one hand-written one-position report; the delivery gas (1.02M) is logged, never asserted. **Spoke test:** bounds the arrival list at 256. Nothing grows positions or sends home. Foundry's test gas limit is far above Arbitrum's 32M per transaction (the scenario uses 169.7M in one call), so a report no one could deliver passes any test that does not cap the call's gas. |
| 07 H-01, send before `createSpoke` | `test/unit/factory/FundFactoryVerifyRound2.t.sol:210` `test_DEC087_verify_hubMandateMayNameASpokeThatCanNeverBeCreated`; `test/fork/factory/FundFactoryFork.t.sol:79` | The first records that the hub may name a spoke that can never exist and stops at the factory. The fork test and the scenario create both sides before any send. The scenario simulates a fill by dealing tokens to the vault and calling its handler as the pool (`EndToEnd.t.sol:326-330`), which cannot model a recipient without code: the live pool then skips the handler. |
| 07 H-02, divergent spoke Mandate | `FundFactoryVerifyRound2.t.sol:167` `test_FFOQ1_verify_managerCanCreateTheSpokeFromAMandateOtherThanTheHubs` | Proves the creation and that the spoke enforces other rules, then ends. No test connects such a spoke to the hub (a delivered report, a send home). The scenario always builds both sides from the same plan (`EndToEnd.t.sol:139`). |

### The four invariant suites

- **`CoreVaultInvariantTest`** (`test/unit/core/CoreVaultInvariant.t.sol`, 7 invariants).
  - `payoutReserve ≤ idle`, whole-share supply, index monotonic, and "every collected unit is a fee or accumulated" are
    real constraints, and they hold.
  - `shareAssetsEqualBuckets` is a tautology: `_bucketSum` reads `vault.inFlightValue()` and `vault.spokeCapUsage()`.
    Its second line, Share Assets = Idle + the mock's balance and principal, holds only because no handler ever leaves
    the hub.
  - `balanceCoversLedger` is one-sided, so value locked in Operating Cash or `unmatchedArrivals` satisfies it.
  - `directTransferNeverMovesSharePrice` covers donations only.
  - The handlers deposit, request, claim, donate, forward income, withdraw income, allocate, set the mock's principal and
    warp. Claims, deposits and allocations run in `try/catch` (`:51`, `:70`, `:101`), so a claim that can never be paid
    does not fail the run.
  - Unreachable: sends, reports, fills in either direction, expiries, refunds, the sweep, Operating Cash parameters,
    valuation fallbacks, unwind hints, a spot price apart from the oracle, and any spoke at all.
- **`SpokeVaultInvariantTest`** (3 invariants).
  - Ledger ≤ balance (one-sided), cumulative income monotonic, report sequence +1.
  - The handlers:
    - arrivals with fresh ids;
    - mock positions and swaps at a fixed 1:1 rate (`:214`);
    - donations and sweeps;
    - sends home, always at least 10,000 units at 50 bps, and every one of them is refunded, never filled;
    - reports and warps.
  - Unreachable: Operating Cash parameters, any hub-side effect of a report, report size, exclusivity, a send home that is
    neither filled nor refunded.
- **`IncomeAccumulatorInvariantTest`**: owed + taken ≤ distributed, index monotonic. It reaches `distribute` through the
  source-counter wrapper `recognizeFromSource`, which production no longer calls (core-b I-04). The math is covered;
  the production caller `_collectIncome` is not.
- **`ShareTokenInvariantTest`**: whole shares, allowance always 0. Sound for the token alone.

### The end-to-end scenario

Its assertions would not fail on any of the cross-chain findings:
- **DEC-104:** `_sumOfBuckets` recomputes Share Assets from the same report and formulas. The walk asserts that it still
  passes at W13 (500 USDC counted twice in the books) and W23 (299.88 USDC in no base). This is I-03.
- **Fill:** simulated, so exclusivity, deadlines and a recipient without code never occur.
- **Report:** one report, delivered at age 0, that never grows.
- **Flows never walked:** no send home, refund, expiry, deprecation or parameter change.
- **Unwind:** gets oracle-based minimums from the test, at an undisturbed price.

It does verify the happy-path wiring. My walk confirms that wiring on real fills and real Wormhole delivery (W0 to W3,
W6 to W10, W14 to W21, W25 to W27).

### Invariants and handlers that would have caught each finding

**Harness** (unit speed, no RPC):
- Real contracts: the Core Vault with its library, the receiver, the hub and spoke Spoke Vaults with their library, and
  the Across, V4 and Aave adapters.
- MockV4, with a spot price that swaps move and that differs from the oracle.
- A mock Across SpokePool that:
  - records deposits;
  - enforces `fillDeadline` and exclusivity;
  - skips the handler when the recipient has no code;
  - refunds expired deposits to the depositor.
- A report pipe that queues published payloads and delivers them after a chosen delay inside a `call{gas: 32M -
  intrinsic}`.

**Actors and actions:**
- shareholders: deposit, request (both modes), claim with empty hints;
- the manager, hostile within the Mandate:
  - every verb, `setOperatingCashParameters` with any values;
  - sends with any fee up to the maximum and optional exclusivity to its own relayer;
  - dust positions and one-unit sends home;
  - `createSpoke` from a mutated plan, and a send before `createSpoke`;
- a relayer: fills any pending deposit before its deadline, or never;
- a stranger: one-unit arrivals with fresh or real ids, donations, and a spot move and move-back around another actor's
  call;
- a keeper: publish, deliver after a random delay or never, `attestExpiry`, `recognizeRefund` on both sides, sweep;
- the guardian: pause and deprecate.

**Properties:**
1. Conservation, the walk's identity with a ghost ledger of stranger arrivals. After the keeper delivers a fresh report
   and recognizes every refund that exists, (a) = (b) within dust, and `unmatchedArrivals` holds only stranger value.
   Catches 02 H-01, 02 H-02, 03 H-02, 04 H-02, 05 H-02 and 07 H-01.
2. Recoverability at quiescence. With every deposit resolved and every holder claiming all shares, the fund pays Share
   Assets less fees and dust, and `operatingCash ≤ floor + topUp` at protocol-constant scale. Catches 02 H-01, 03 H-02,
   04 H-01, 04 H-02 and 05 H-02.
3. Spoke Cap: after every accepted send, ghost value on the spoke (filled hub-to-spoke deposits less what returned) plus
   in flight ≤ cap. Catches 03 H-01.
4. Third-party price independence: around any deposit or claim, a stranger's move-and-restore of the spot leaves the
   Share Price unchanged within fees. The stranger's USDC out ≤ USDC in plus its shares' oracle value. Catches 02 C-01
   and 04 C-01.
5. Exit under deprecation: after `deprecate`, a claim up to Free Idle plus exact-value positions completes. Every ledger
   token keeps a verb that can reduce it. Catches 04 H-01.
6. Deliverability: every payload `report()` publishes is accepted within 32M gas. Catches 05 H-01.
7. Mandate identity: the receiver accepts reports only from a spoke whose `mandateHash()` equals the Core Vault's.
   Catches 07 H-02.
8. No value counted for a deposit whose recipient had no code at fill time. Catches 07 H-01.
9. Unit property: every send has zero or protocol-listed exclusivity and a fee within the route constant. Catches 03 M-01.

**The fork scenario:**
- replace `_sumOfBuckets` with the walk's `_holdings` and `_books`;
- fill through `fillRelay`, and deliver after finality;
- add the flows the walk adds, a displaced spot during an unhinted claim, a deprecated adapter, and a Mandate at its
  bounds.

## Findings

### [I-01] An arrival's Operating Cash top-up is counted twice until the next report
- Status: CONFIRMED (the walk asserts it at step W4: D now = −9.999999 USDC, D fresh = +0.000001)
- Where:
  - `src/spoke/SpokeVault.sol:468`: the arrival runs `_topUpOperatingCash` after crediting.
  - `src/core/CoreVaultLogic.sol:202`: the hub keeps the transit in In-flight Value at `amountToArrive` until a report
    confirms it.
  - `src/core/CoreVaultLogic.sol:437-458`: `_confirmArrivals`.
- Rule: DEC-104 (never in two bases); DEC-096 and DEC-100 (the top-up is an expense whose price drop is accepted at the
  top-up); DEC-070.
- What: between a hub-to-spoke fill and the next accepted report:
  - the hub counts the whole `amountToArrive` in Share Assets as In-flight Value;
  - `operatingCashTopUp` of it already sits in the spoke's Operating Cash, outside Share Assets.

  Share Assets are therefore overstated by the top-up, and the DEC-100 price drop lands at the next report instead of at
  the top-up. At the Mandate values that is 10 USDG, 0.1% of this fund, for the 15 to 20 minutes before a report. With
  the unbounded top-up of 02 H-01, 04 H-02 and 05 H-02, the whole arrival goes to Operating Cash and stays counted for
  as long as no report is delivered. If no report was ever accepted, mints stay open meanwhile (02 L-02).
- Scenario (walk):
  1. W3: 4,000 USDC are sent; In-flight Value is 3,998.40.
  2. W4: the live pool fills the transfer. The spoke credits 3,998.40 and moves 10 into Operating Cash. The hub still
     counts 3,998.40 in flight, so the books total 10 USDG more than the fund holds.
  3. W6: the next report confirms the transit, and Share Assets drop by 10.
- PoC: `test/review/integration-xchain/Fork_ConservationWalk.t.sol`, with the command above. Result: 1 passed.
- Fix: leave the arrival handler out of the top-up, so the next manager verb pays it (DEC-096 "next operation"), or
  document that a spoke expense reaches the Share Price at the next report. The Operating Cash caps proposed for
  02 H-01 and 05 H-02 bound it either way.
- Known?: No.
  - `test_OQ09_strandedTransitWhoseArrivalToppedUpOperatingCashIsCountedOnce` and the OQ-09 row cover the path after a
    report that does not list the id.
  - The REVIEW-LOG spoke minor that added the top-up to arrivals does not mention the window before a report.

### [I-02] The documented Across refund delay from Robinhood is shorter than what the chain shows
- Status: CONFIRMED (measured with read-only RPC queries on 2026-09-30; not a contract defect)
- Where: `docs/DECISIONS.md:279` ("55 to 90 min from Robinhood").
- Rule: docs match facts. The 02 H-02 window, the QB11 reading and every keeper plan depend on this delay.
- What:
  - HubPool `liveness()` is 1,800 s (Ethereum).
  - Root bundles reached the Robinhood SpokePool 53 times in 27.7 h, every 23.9 to 38.8 min.
  - The relay came 50.5 to 55.6 min after the Ethereum proposal (10 matched roots).
  - Refund leaves executed 2.8 to 13.1 min after the relay (104 executions).
  - Together, an expired deposit's refund lands about 53 to 107 min after `fillDeadline`, before the dataworker's
    end-block lag. The documented 90 min is exceeded whenever the deadline falls just after a bundle's end block.
- PoC: none needed; the queries were `cast logs` on the Robinhood SpokePool (`RelayedRootBundle`,
  `ExecutedRelayerRefundRoot`) and on the Ethereum HubPool (`ProposeRootBundle`), plus `cast call liveness()`.
- Fix: update the fact with the cadence and a margin. Prefer a 02 H-02 fix that does not depend on the delay.
- Known?: No.

### [I-03] The end-to-end scenario cannot fail on the cross-chain failure modes
- Status: CONFIRMED (the walk asserts that `core.shareAssets() == _sumOfBuckets()` still holds at W13 and W23)
- Where:
  - `test/fork/e2e/EndToEndBase.sol:352-358`: `_sumOfBuckets`, the same formulas and report as the vault.
  - `test/fork/e2e/EndToEnd.t.sol:326-330`: simulated fill.
  - `test/fork/e2e/EndToEnd.t.sol:409-420`: delivery at age 0.
  - `test/fork/e2e/EndToEnd.t.sol:714-732`: Chainlink-based minimums in the unwind hints.
  - `test/unit/core/CoreVaultFixture.sol:254-264`: `_bucketSum` from the vault's own views.
- Rule: best practice (a test must be able to fail); DEC-104.
- What: the scenario's DEC-104 assertion compares Share Assets with a sum that reads the same state the same way. It
  passes while 500 USDC are counted twice (W13) and while 299.88 USDC are in no base (W23). The unit invariant repeats
  the pattern. The scenario also simulates the fill, delivers at age 0, never sends home or refunds, and supplies the
  oracle guard the unwind lacks. "97% coverage plus a passing DEC-104 invariant" therefore says nothing about DEC-104
  across chains.
- Fix: the harness, actors and properties in "Why the tests missed it". The walk's `_holdings` and `_books` can replace
  `_sumOfBuckets` directly.
- Known?: No.

## Checks and validations

Integration points exercised on the real stack (access, validation, event, and the finding that marks a gap):

| Entry point | Chain | Who may call (observed) | What the integrated runs showed | Event | Gaps |
|---|---|---|---|---|---|
| `CoreVault.sendToSpoke` | Arbitrum | manager | The live `depositV3` gets the vault-fixed recipient, token pair, message and escrow depositor, and exclusivity passes through as given | `SentToSpoke` | 03 H-01, 03 M-01, 07 H-01; the event omits exclusivity (03 I-06) |
| `SpokeVault.handleV3AcrossMessage` | Robinhood | the live pool only; it calls after the transfer, and not at all for a recipient without code | credits by id, then tops up Operating Cash | `TransitArrived` | 04 H-02, 05 H-02, I-01, 07 H-01 |
| `SpokeVault.report` | Robinhood | anyone | the real Core publishes payloads up to 62,592 bytes | `ReportPublished` | 05 H-01 |
| `ValueReportReceiver.deliver` | Arbitrum | anyone | the real Core verifies 13 of 19 signatures; stores the payload; calls the vault | `ReportAccepted` | 05 H-01, 07 H-02 |
| `CoreVault.onReportAccepted` | Arbitrum | the receiver only | confirms arrivals, matches return legs, splits Income | `ReportAccepted`, `TransitArrived`, `TransitReceived` | 03 H-02 |
| `SpokeVault.sendToHub` | Robinhood | manager | the live pool accepts one-unit deposits; exclusivity passes through | `SentToHub` | 02 H-02, 03 M-01, 05 H-01 |
| `CoreVault.handleV3AcrossMessage` | Arbitrum | the live pool only | held apart until a report lists the id | `TransitReceived`, `ArrivalHeldApart` | 03 H-02 |
| `CoreVault.attestExpiry` | Arbitrum | anyone | both paths: the report path and the time path | `TransitExpiryAttested` | 03 H-01 |
| `recognizeRefund`, hub and spoke | both | anyone | exact `amountSent` after a live refund leaf | `TransitRefundRecognized` | none |
| `FundFactory.createFund`, `createSpoke` | both | manager | `createSpoke` from a divergent plan is accepted | `FundCreated`, `SpokeCreated` | 07 H-01, 07 H-02 |
| `setOperatingCashParameters`, hub and spoke | both | manager | any values, and no outflow | `OperatingCashParametersSet` | 02 H-01, 04 H-02, 05 H-02 |

## Checked and found correct
- **Live fills.** For a recipient with code, `fillRelay` behaves as the project's simulation assumes: it transfers first,
  then calls `handleV3AcrossMessage(outputToken, outputAmount, msg.sender, message)`. Every real fill in these runs
  credited exactly `outputAmount`. The live pools accept one-unit deposits. They enforce `fillDeadline`
  (`ExpiredFillDeadline` one second after, on Arbitrum) and exclusivity (`NotExclusiveRelayer`, both pools).
- **Live refunds.**
  - An expired deposit's refund reaches the escrow only through `executeRelayerRefundLeaf` of a root bundle the HubPool
    relays.
  - On Arbitrum (`Arbitrum_SpokePool`) the admin call comes from the aliased HubPool.
  - On Robinhood the pool is a `Universal_SpokePool`: the call reverts `AdminCallNotValidated` unless it runs inside a
    light-client-verified `executeMessage`. The test sets that private flag the way `executeMessage` does, found by
    recording the pool's storage reads, and clears it afterwards.
  - `recognizeRefund` then credits exactly `amountSent` on both chains, with the escrow emptied and the balance delta
    checked (walk W20 to W21, W24 to W25).
- **Real Wormhole.** The real Arbitrum Core verifies the fund's VAAs (13 of 19 signatures). The receiver's emitter, fund,
  chain and sequence checks accept the fund's own spoke. The first delivery costs 1.04M gas.
- **Happy-path conservation.** The walk agrees within 3 base units across payouts with unwind, income collection and
  split, income withdrawal, both kinds of transfer home when reported in time, refunds in both directions, and a sweep.
- **Q60.** Owed income never exceeded collected income at any step.
- **Spoke-side report gas.** With the real V4 adapter, `report()` on Robinhood stays under 32M up to about 390 positions,
  so the hub breaks first.
- **Mandate contrast.** A spoke built from the hub's Mandate refuses the 100%-fee send home.
- **Gas cap.** ArbGasInfo `getGasAccountingParams()` returns a `maxTxGasLimit` of 32,000,000 on both chains (re-read).

## Not covered
- Whether guardians sign a 62 KB message. This is off-chain; Wormhole's documentation only says a message "may be capped
  to a certain maximum length" per chain.
- Relayer economics. The LP fee is not modelled in the repayments, and whether relayers fill USDC to USDG and back, or
  dust, is not known.
- The dataworker's inclusion rule and its end-block lag. They are inferred from on-chain cadence only.
- Income-kind sends home as a bloat lever. spoke-b measured about 117k per send with the stand-in.
- The price and unwind family (02 C-01, 04 C-01, 04 H-01) on forks. Another reviewer covers them; Part 3 covers only why
  the tests missed them.
- Implementing the proposed invariant harness.
