# Architecture: buildathon MVP

Target design for the first contracts. Every rule cites the decision that governs it (`DEC-nnn`, see
`docs/DECISIONS.md`). Where no decision exists, the section says **OPEN** and points to `docs/OPEN-QUESTIONS.md`;
the code then takes the conservative path and exposes a parameter or an interface so the founder's answer slots
in without a redesign.

Scope: Arbitrum One (Hub Chain) and Robinhood Chain (Spoke Chain), Uniswap V4 positions on both chains, Aave V3
supply-only on Arbitrum (DEC-018, DEC-028, confirmed by the founder on 2026-09-29), Across as the Transport Route,
Wormhole (finalized consistency) for value reports. Addresses in `docs/INTEGRATIONS.md`.

## 1. Components

```
                         ARBITRUM ONE (Hub Chain)                     ROBINHOOD CHAIN (Spoke Chain)
  Shareholder ─deposit/requestPayout/claim/withdrawIncome─▶ CoreVault
  Manager ─────sendToSpoke / allocate on hub──────────────▶ CoreVault ──▶ SpokeVault(hub) ──▶ UniswapV4Adapter, AaveV3Adapter
  Anyone ──────deliver VAA───────────────────────────────▶ ValueReportReceiver ◀── Wormhole VAA ◀── SpokeVault(robinhood).report()
                                                           AcrossBridgeAdapter ══ Across ══▶ SpokeVault(robinhood).handleV3AcrossMessage
                                                                                              SpokeVault(robinhood) ──▶ UniswapV4Adapter
  FundFactory (CREATE2, same salt on both chains) deploys everything from the Mandate.
```

| Contract | Chain | Responsibility | Decisions |
|---|---|---|---|
| `ShareToken` | hub | ERC-20, 18 decimals, only whole shares (multiples of 1e18) ever minted or burned; `transfer`, `transferFrom`, `approve` revert; only the Core Vault mints and burns | DEC-004, DEC-035, DEC-077, DEC-091 |
| `CoreVault` (+ linked library `CoreVaultLogic`) | hub | Custody of Idle USDC; share ledger via `ShareToken`; Payout Requests and Payouts; Attributed Income bucket and Income Withdrawal; the fee split at collection; sends capital to spokes through a bridge adapter; the transit state machine; reads the hub `SpokeVault` directly and the spoke values from `ValueReportReceiver`. Never calls a DeFi protocol. Deploys its `ShareToken` and `ManagerFeeVault` in its constructor. | DEC-009, DEC-020, DEC-054, DEC-065, DEC-067, DEC-072, DEC-077, DEC-081, DEC-085, DEC-090, DEC-095, DEC-105, DEC-107 |
| `SpokeVault` (+ linked library `SpokeCrossChainLib`) | every chain, hub included | The fund's account on a chain: internal ledger per token (never `balanceOf`), position registry per adapter, Unallocated Balance, Operating Cash bucket; drives adapters within the Mandate's closed lists; receives Across fills; builds and publishes value reports (spoke chains) or exposes the same data to the Core Vault (hub) | DEC-054, DEC-069, DEC-070, DEC-079, DEC-080, DEC-093, DEC-096 |
| `ValueReportReceiver` | hub | Accepts a spoke's report only if the guardian quorum signed it, the emitter is the fund's Spoke Vault on that chain, the sequence is strictly greater than the last accepted, and the report is within the max age; stores the latest accepted report per spoke | DEC-086, DEC-093, DEC-094, DEC-099 |
| `UniswapV4Adapter` | both | Opens, increases, decreases, closes and collects V4 positions (PositionManager, pools identified by `PoolId`, closed list in the Mandate, hookless pools only in the MVP; pools whose hooks charge on withdrawal are OPEN, DEC-079); reports principal (liquidity at current price) and income (`feesAccrued`, tracked as a monotonic cumulative counter per token) **separately** from the PoolManager's own accounting; price-dependent (`isExactValue() == false`); immutable, one instance per fund per chain | DEC-018, DEC-053, DEC-058, DEC-079 |
| `AaveV3Adapter` | hub only | Supplies USDC to the Aave V3 Pool and withdraws it; never borrows; Exact-Value Position (DEC-059): ledger keeps scaled units and the `liquidityIndex` at the last measurement, interest since then is income (DEC-068); read, not unwound, while the reserve has liquidity; `isExactValue() == true` | DEC-018, DEC-028, DEC-059, DEC-068 |
| `AcrossBridgeAdapter` | both | Builds the Across `depositV3` call for the vault; the **vault**, not the adapter, fixes the recipient (the fund's own vault on the destination chain) and the token pair; 6-hour fill deadline as an adapter constant | DEC-031, DEC-066, DEC-087, DEC-088, DEC-090 |
| `TransitEscrow` | both | Minimal per-send depositor (EIP-1167 clone, no EIP-1271 so nobody can sign a `fillRelayWithUpdatedDeposit` that delivers less, DEC-066) so an Across refund lands in a dedicated address and is recognized as a refund rather than mistaken for a donation | DEC-066 (keyless depositor); the escrow itself implements research proposal QA6, **OPEN** |
| `ManagerFeeVault` | hub | One per fund, deployed by the Core Vault constructor next to the `ShareToken` (immutable `fund` and `manager`): receives the manager's portion of every performance fee at collection by plain ERC-20 push (ruling 2026-09-29), multi-token, `withdraw(token, to, amount)` by the manager only, `balanceOf(token)` view, no other verb; outside every value base | DEC-107, DEC-109 |
| `ManagerRegistry` | hub | One record per manager: protocol slice of the manager's fee (default 50%), adjustable per manager by the protocol; outside the Mandate | DEC-106, DEC-110 |
| `FundFactory` | both | Deploys a fund's contracts from its Mandate with CREATE2 and a fund-id salt so hub and spoke addresses are known to each other at creation; links the two external libraries (§1.1). Not written yet | DEC-053, DEC-054 |
| `IPriceSource` + `ChainlinkPriceSource` | hub | Prices non-USDC tokens carried in reports and hub positions into USDC for Share Assets; pluggable because the pricing rule is **OPEN** | see §5 |

### 1.1 Linked external libraries (what the factory must link)

Two fund contracts do not fit the 24,576-byte runtime limit in one piece (compiler settings are fixed), so part of
their code is an **external linked library** that runs by DELEGATECALL over the fund contract's own storage. This is
the only DELEGATECALL in the system; adapters are always called with a plain CALL (§6). Ratified in the consolidation
of 2026-09-29 (Core Vault and Spoke Vault verifier majors) instead of a restructuring.

| Library | Linked into | Holds | Runtime size (consolidation) |
|---|---|---|---|
| `CoreVaultLogic` | `CoreVault` | Value bases and the payout fallback valuation, collected income and the fee split, report application, sends to spokes, transit outcomes | ~19.0 KB (Core Vault ~19.7 KB) |
| `SpokeCrossChainLib` | `SpokeVault` | Send home, refund recognition, the hub-bound in-flight list, report building and encoding | ~10.2 KB (Spoke Vault ~21.7 KB) |

What the factory must do:
- Deploy each library once per chain, immutable (no proxy, DEC-022, DEC-058), and link its address into the fund
  contract's creation code; the address is therefore part of every fund's CREATE2 init code hash and trust surface.
- Deploy `SpokeCrossChainLib` at a **chain-independent address** (CREATE2 from the same deployer and salt), so a
  Spoke Vault has the same init code, hence the same address, on every chain (DEC-054). Pin its codehash the way
  adapters are pinned (Q17-4 reading O2).
- Pass the Core Vault's creation code in calldata: its initcode (about 34 KB, the `ShareToken` and `ManagerFeeVault`
  creation code included) exceeds what a factory can embed next to its own (see `CoreVaultCreate2Deployer` in
  `test/unit/core/CoreVaultSetup.t.sol`).
- Surface `FillDeadlineBufferTooShort` from the Across adapter constructor as a deployment-time revert reason (the
  adapter refuses a SpokePool whose fill deadline buffer is below 6 h, DEC-066).
- Pass the fund id to the `ValueReportReceiver` constructor (`IValueReportReceiver.fundId()` exposes it) and the hub
  income tokens (read from the hub adapters' `poolTokens`) to the Core Vault (CV-OQ-3).

## 2. Mandate

Written once at creation (DEC-053), stored in the Core Vault and mirrored on each Spoke Vault. Fields:

| Field | Type | Mutability | Decision |
|---|---|---|---|
| `manager` | address | immutable in MVP (manager transfer is OPEN) | DEC-002 |
| `hubChainId`, `usdc` | uint256, address | immutable | DEC-011 |
| `adapters[]` | closed list of adapter addresses per chain | immutable; no adapter may be added to a live fund | DEC-053, DEC-058 |
| `pools[]` | closed list of `(adapter, poolKey)` the manager may open positions in | immutable | DEC-030, DEC-053 |
| `unwindOrder[]` | ordered list of `(chainId, adapter, poolKey)` for automatic unwinds | immutable | DEC-069 |
| `spokes[]` | per spoke: EVM chain id, Wormhole chain id, Spoke Vault address (bytes32), `spokeCap` (USDC, principal), ordered `bridgeAdapters[]` (primary, fallback) | immutable | DEC-031, DEC-037, DEC-088, DEC-095 |
| `payoutFeeBps` | uint16, default 200 (2%) | immutable | DEC-075, DEC-095, DEC-102 |
| `standardPayoutTerm` | uint32 seconds, default 72 h | immutable | DEC-060, DEC-095 |
| `minFirstDeposit` | uint256 USDC, set by the manager, no protocol floor (confirmation pending, DEC-095 erratum item 22) | immutable | DEC-061, DEC-095 |
| `performanceFeeBps` | uint16 | may only **decrease** after creation; charged at collection, so nothing accrues to settle first (ruling 2026-09-29) | DEC-107, DEC-110 |
| `managementFeeBps` | uint16, default 0 | MVP accepts only 0 at creation: base and accrual are decided (Share Assets, continuous) but recipient and the meaning of "position close" are **OPEN** (LC-144) | DEC-108, DEC-110 |
| `operatingCashFloor[chainId]`, `operatingCashTopUp[chainId]` | uint256 | manager may adjust on a live fund | DEC-096, DEC-100 |
| `maxReportAge[spoke]` | uint32 seconds | immutable; value **OPEN** (Q57) | DEC-094, DEC-099 |
| `maxBridgeFeeBps` | uint16 | immutable; value **OPEN** (QA19) | DEC-030 exception |

Protocol-level constants live in the core, not the Mandate: flow fee 25 bps default with a 100 bps cap
(DEC-106), fee caps for performance and management fees (DEC-110; the cap values are **OPEN**, LC-144).

## 3. Value bases (DEC-042, DEC-083, DEC-084, DEC-098, DEC-104)

- **Share Assets** = Idle (incl. Payout Reserve; Idle exists only in the Core Vault, DEC-055) + the hub Spoke
  Vault's Unallocated Balance and positions' principal (read directly, same chain) + In-flight Value at the amount that will arrive (DEC-085) + each spoke's principal and Unallocated
  Balance from its last accepted report. Excludes Operating Cash, Attributed Income (collected or not, DEC-092)
  and external rewards (DEC-078).
- **Share Price** = Share Assets / totalSupply, the only published price, used for every mint and burn.
  First mint: 1 share (1e18 units) = 1.00 USDC (1e6) (DEC-061).
- **Gross Assets** = Share Assets + Operating Cash + Attributed Income + external rewards. Informational.
- **Settlement Price** = what an unwind realized divided by the shares burned; recorded in the Payout event,
  never used to compute the burn (DEC-105).
- Invariant (DEC-104): no recognized unit of value sits in two bases at once.

## 4. Flows

### 4.1 Deposit (synchronous, DEC-071, DEC-009)
`deposit(uint256 usdcAmount, uint256 minShares)`:
1. First deposit must be at least `minFirstDeposit` (DEC-061, DEC-095).
2. Flow fee: 25 bps of the deposited amount goes to the Protocol Recipient (DEC-106). **OPEN** whether the fee
   is taken from the amount before pricing or on top; MVP takes it from the amount, flagged.
3. `shares = floor(net / sharePrice)` in whole units (DEC-035); charge only `shares * sharePrice`, truncated
   to 6 decimals, the remainder never leaves the wallet (DEC-061). Revert if `shares < minShares` or zero (a deposit
   below one share's price is rejected, DEC-035).
4. Pull USDC, mint, credit Idle. Same transaction; no queue; no wait for a fresh report (DEC-071, DEC-085).
5. Update the income accumulator checkpoint for the depositor before minting (§4.5).
6. Revert if any spoke's last accepted report is older than its `maxReportAge` (mint closes on a stale report; an
   idle-paid payout does not, research reading of Q57, flagged).

### 4.2 Allocation
- Hub: `CoreVault.allocateToHubSpoke(amount)` moves Idle to the hub Spoke Vault's Unallocated Balance; the
  manager then opens positions on the hub Spoke Vault. Only Free Idle may be allocated (DEC-017, DEC-072).
- Spoke: `CoreVault.sendToSpoke(spokeIndex, amount, bridgeIndex, quote)`: manager only; revert unless
  `spokeValue + inFlightTo + inFlightFrom + amount <= spokeCap` (DEC-037, DEC-095); the bridge adapter builds
  the Across deposit with recipient = the spoke's vault, `outputAmount` from the quote, fill deadline = now + 6 h;
  the vault checks the quote's fee against `maxBridgeFeeBps`; a `TransitEscrow` clone is the depositor;
  in-flight counted at `outputAmount` in Share Assets and at the amount sent in the Spoke Cap (DEC-085, DEC-066).
  Transit states mirror DEC-066: `Sent`, `ArrivalConfirmed`, `ExpiryAttested`, `RefundRecognized` (the three-state
  reading of DEC-090 is OPEN, QB11; four states lose nothing). The core accepts transitions only from the
  fund's own Mandate adapters and vaults (DEC-090). `spokeCapUsage(i)` returns `(spokeValue, inFlightSent,
  inFlightToHub, spokeCap)`: the pending return leg the spoke reports (Principal and Income) is its own line and
  counts toward the cap (DEC-066 B1).
- Arrival: the Robinhood Spoke Vault's `handleV3AcrossMessage` (callable only by the Across SpokePool, only for
  USDG) credits Unallocated Balance, records the deposit id as arrived and runs the Operating Cash top-up (DEC-096);
  the next report carries the arrived ids; the Core Vault moves those transits to `ArrivalConfirmed` and drops them
  from In-flight (DEC-090).
- Arrival window (OQ-09 stance, liveness only, never value): the report lists the last 256 arrival ids
  (`ReportCodec.ARRIVAL_WINDOW`), and an id is listed only once its credited total reaches 1e6 base units (1 USDG);
  smaller arrivals are still credited to the ledger and to `cumulativeReceived`. Across passes no depositor, so a
  stranger can reach the callback; flushing the window now costs 256 USDG donated to the fund, and value is never at
  stake because the hub confirms only ids it sent and deducts `cumulativeReceived` above what it confirmed.
- Expiry: after the fill deadline anyone may call `attestExpiry(transitId)`: it needs a spoke report built after
  the deadline that does not list the id **and lists fewer than 256 arrivals** (a full window may have evicted it),
  or the deadline plus the report lifetime to have passed; the Spoke Cap is released then; the amount stays in Share
  Assets until `recognizeRefund(transitId)` pulls the refund from the escrow back to Idle (DEC-066; the window
  between the two is OPEN, QB11/QB10).
- Return leg: a spoke sends home with `sendToHub(amount, kind, ...)` in its base token; it lands on the hub as USDC.
  The report lists it in `inFlightToHub` with its kind (ReportCodec version 2): Principal in flight counts in Share
  Assets (DEC-085, DEC-104), Income in flight does not (DEC-092). The hub credits an arrival up to the listed amount
  and by the **reported** kind, never by the Across message's claim (OQ-01): Principal to Idle, Income through the
  fee split (§4.5); anything unlisted or above the listing is held apart (`unmatchedArrivals`), never swept.

### 4.3 Positions (Spoke Vault on any chain)
Every adapter exposes a monotonic `cumulativeIncome(token)` counter (all income ever realized plus currently
uncollected, never a balance) so the income index can advance from deltas; on Uniswap V4 any liquidity change
realizes all fees of the position (`feesAccrued` in the `BalanceDelta` returned by `modifyLiquidity`), so the
adapter accumulates realized fees plus current uncollected fees computed from `feeGrowthInside`; on Aave the counter
is `scaledBalance * (liquidityIndex_now - liquidityIndex_last)` summed over time. Every adapter exposes `isExactValue()` (DEC-059: Idle, Unallocated Balance and Aave aUSDC are read, never unwound;
Uniswap positions are price-dependent and are unwound). Manager-only `openPosition`, `increasePosition`,
`decreasePosition`, `closePosition`, `collectIncome`, each
restricted to `(adapter, poolKey)` in the Mandate. The vault transfers tokens to the adapter, the adapter acts
on the protocol and returns `(principalDelta0, principalDelta1, income0, income1)`; the vault updates its
ledger from what the adapter returned, never from balances (DEC-080). Income collected goes to the income bucket
of the vault (spoke) or is bridged/handed to the Core Vault's Attributed Income (hub). Adapter pause blocks
open/increase only, never decrease/close/collect (DEC-021, DEC-058; who may pause is **OPEN**).

### 4.4 Value report (DEC-070, DEC-086, DEC-093)
`SpokeVault.report()` is permissionless: builds a versioned `ReportPayload` (version 2) that is a superset serving
every pricing option still open (Q57): `fundId, sequence, spokeChainId, blockNumber, timestamp, unallocated[]
{token, amount}, positions[] {adapter, poolKey, poolId (bytes32), tickLower, tickUpper, liquidity, token0, token1,
principal0, principal1, income0, income1}, cumulativeIncome[] {token, amount} (monotonic since inception,
informational), collectedIncome[] {token, amount}, operatingCash, cumulativeReceived, cumulativeSentHome,
arrivedTransits[] {transitId, amount} (last 256 listed), inFlightToHub[] {transitId, amount, kind}` from the ledger
and adapters, and calls `CoreBridge.publishMessage(nonce, payload, 1 /* finalized */)`. Anyone delivers the VAA to
`ValueReportReceiver.deliver(bytes vaa)`, which verifies with the Core Bridge, checks emitter chain and address
against the Mandate, requires `sequence > lastSequence`, requires `now - timestamp <= maxReportAge` and a
timestamp at most one `maxReportAge` ahead of the hub clock (DEC-099 assumption on clock skew), and stores the report. Pricing of the quantities into USDC happens on the hub through `IPriceSource` (§5).

### 4.5 Attributed Income and the fee flow at collection (DEC-014, DEC-025, DEC-064, DEC-073, DEC-092, DEC-106, DEC-107, DEC-109, DEC-110; ruling 2026-09-29)
Per-token global index in Q128 (2^128 scale, 512-bit mulDiv, remainder carried) with a per-holder checkpoint. The
index advances **only when collected income reaches the Core Vault**, and the fee split happens right there
(`CoreVaultLogic.collectIncome`):

| Source | How it reaches the Core Vault |
|---|---|
| Hub positions | the manager collects on the hub Spoke Vault; anyone calls `forwardIncomeToCoreVault(token)`, which transfers the collected bucket and calls `receiveCollectedIncome(token, amount)`; income stays in kind (USDC, WETH) |
| Spoke positions | the manager collects on the spoke, turns non-base income into the base token with `swapCollectedIncome` (CV-OQ-2), then `sendToHub(amount, Income, ...)`; it lands as USDC and is credited when a report lists it (§4.2) |

At each collection of `amount` in `token`: performance fee = `amount * performanceFeeBps` (DEC-107, on income, no
high-water mark); its protocol slice = fee * `ManagerRegistry.protocolSliceBps(manager)` read at that moment
(DEC-106, DEC-110; 50% default and on a failed read); the slice is transferred to the Protocol Recipient and the rest
of the fee to the fund's `ManagerFeeVault`, in kind, in the same transaction (DEC-109); the net enters the
accumulator and the collected balance (with no shares outstanding it is kept ownerless, LC-32). No fee is ever owed
or kept in the Core Vault. `CollectedIncomeReceived(token, amount, managerFee, protocolSlice, protocolSliceBps)`
records every split. Worked example (docs/OPEN-QUESTIONS.md): 1,000 USDC + 0.5 WETH at 20% and a 50% slice gives
100 USDC + 0.05 WETH to the protocol, 100 USDC + 0.05 WETH to the `ManagerFeeVault`, 800 USDC + 0.4 WETH to holders.

Uncollected income (hub and spoke positions, the spoke's collected bucket not yet sent home) stays in its own bucket
(DEC-092): it never moves the index and only informs Gross Assets; the reports' cumulative income counters are
informational. Holders call `withdrawIncome(token)` to take the collected income out at any time without burning
shares (`min(owed, collected)`, LC-100); burning all shares pays it too. No compounding in the contract (DEC-064).
`decreaseManagerFee` has nothing to settle first: no fee accrues between collections (DEC-110). Consequence flagged
in docs/OPEN-QUESTIONS.md: income generated before an entrant's deposit but collected after it is shared with the
entrant (DEC-014 tension).

### 4.6 Payout (DEC-020, DEC-024, DEC-060, DEC-065, DEC-067, DEC-074, DEC-075, DEC-077, DEC-081, DEC-095, DEC-102, DEC-105)
- `requestPayout(uint256 usdcAmount, PayoutMode mode)`: one open request per holder, not cancellable, shares
  are not locked or burned at request time. Standard: reserve `min(usdcAmount, Free Idle)` in the Payout
  Reserve as USDC and start the term. Instant: no reserve.
- `claimPayout(bytes unwindHints)`: only the requester (DEC-065, DEC-074). Events `PayoutExecuted` and
  `PartialPayoutExecuted` carry the Settlement Price, the payer of every Operating Expense (DEC-041) and the
  consolidation fields of DEC-083 (number of chains summed, block and sequence of each spoke report, age of the
  oldest report, In-flight Value on its own line). Burning all of a holder's shares pays their Attributed Income in
  the same transaction (DEC-045, DEC-047). If the idle the request may use covers it (Instant: Free
  Idle only, never the Payout Reserve; Standard: its reserve then Free Idle), burn `floor(amount / sharePrice)`
  whole shares, pay `shares * sharePrice` (never more than requested), atomically. Otherwise unwind in Mandate
  order only what is missing plus 2% (fund bears the margin's market cost, DEC-097), proceeds go to Idle (only what
  the hub Spoke Vault credits through `returnToIdle`, DEC-080), then require a report from every spoke with sequence
  after the unwind (DEC-105) before burning at the resulting Share Price. Partial Payout burns only what was paid and
  leaves the USDC remainder open (DEC-068).
- Payout liveness (DEC-021, DEC-056, OQ-10): a claim never reverts because a valuation dependency fails. In the payout
  valuation the hub Spoke Vault's report read and every `IPriceSource` read are wrapped; a failure falls back to the
  last successfully computed value kept in storage (`lastHubValue`; `lastPrice` per token), with
  `HubValuationFallback` or `PriceFallback`. The last known values are refreshed on every successful deposit and
  payout (the hub value only when the hub read and all its prices answered). A token never priced before falls back
  to 0. Remote spokes need no value fallback: the receiver keeps their last accepted report. Deposits keep reverting
  on any failure, stale report or stale price.
- Instant: 2% Payout Fee on the requested amount into Operating Cash (DEC-102); network costs charged to the
  requester separately (**OPEN** how, LC-45/LC-47: MVP charges nothing extra and flags it). Standard: after the
  term the requester's claim runs the remaining unwind; the fund pays network costs from Operating Cash (DEC-060).
- Flow fee 25 bps on the amount paid out goes to the Protocol Recipient (DEC-106); never on Income Withdrawal
  (LC-143 reading).
- A report only has to postdate the unwind on the spoke where the unwind happened (DEC-105, erratum 11); a
  hub-only unwind needs no new spoke report beyond the max-age rule.
- Unwinds on a spoke need an instruction from the hub. **OPEN** (feedback question 2): MVP restricts automatic
  unwind to hub positions and to spoke positions the manager has already closed and bridged; a spoke unwind
  driven by a hub-to-spoke message is the next milestone.

### 4.7 Operating Cash (DEC-041, DEC-096, DEC-100, DEC-102)
Per-chain bucket fed by the Payout Fee and top-ups; floor and top-up amounts adjustable by the manager; when it
falls below the floor the next operation (a spoke arrival included) tops it up from Share Assets (accepted effect
on Share Price). `OperatingCashInsufficient` (DEC-041's "insufficient cash" state) is emitted only when Free Idle
cannot fund the whole top-up, never on a routine one. Spending it (relayer gas reimbursement) is **OPEN** (doc 30);
the MVP keeps the bucket and the top-up rule only.

## 5. Pricing (**OPEN**, the most consequential gap)

Reports and hub positions carry token quantities. Share Assets needs a USDC value for WETH and for USDG.
Decisions say: no oracle in the payout path for the unwound part (DEC-032, DEC-081), the report is read before
the burn (DEC-081, DEC-105), and the buildathon draft leans to "quantities in the report, Chainlink on the hub"
(feedback question 1, option B). The founder's ruling of 2026-09-29 keeps that working assumption (Chainlink for
WETH, 1:1 for USDG). The MVP therefore:
- puts pricing behind `IPriceSource.priceInUsdc(token) -> (price1e18, updatedAt)` (USDC base units per base unit of
  the token, times 1e18) and `usdcValue(token, amount)`;
- ships `ChainlinkPriceSource`: Chainlink USD feeds read as USDC, and fixed 1:1 tokens configured with their decimals;
  adding a token is a new price source, never a Mandate change;
- never reverts on age: the source returns `updatedAt` and `maxPriceAge(token)`, each feed with its own bound (OQ-10);
  the Core Vault reverts a mint on a price older than its token's bound and never checks age on a payout; a payout
  also survives a reverting source through the last known price (§4.6);
- lists the rule as OPEN in `docs/OPEN-QUESTIONS.md`.

## 6. Security model

- Closed lists and vault-enforced destinations: the adapter builds calls, the vault decides recipients, tokens
  and amounts (DEC-087 §4.3). A compromised adapter cannot redirect funds.
- Internal ledger, never `balanceOf`, for every value that reaches a base (DEC-080). Donations and dust go to
  the garbage collector, which sends them to the fee wallet (DEC-096, DEC-101; fee wallet identity OPEN, LC-132).
- Whole shares rounded against the actor; minimum first deposit; no share transfers (DEC-035, DEC-061, DEC-091).
- Replay protection is ours: `(emitterChainId, emitterAddress)` fixed by the Mandate, strictly increasing
  sequence (DEC-093). Finalized consistency only.
- Reentrancy guards on every external entry that moves value (OpenZeppelin `ReentrancyGuard`); SafeERC20;
  checks-effects-interactions; custom errors; no `tx.origin`; no delegatecall except into the fund's own linked
  libraries (§1.1), never into adapters.
- No upgradeability: a live fund never adopts new code; a new version is a new fund (DEC-058).
- Pausing an adapter blocks entries only; exits always work (DEC-021).

## 7. Testing strategy

- Unit and fuzz tests for every library and every rule, named after the decision (`test_DEC067_idlePaysWholeRequest`).
- Invariants: `totalSupply` is a multiple of 1e18; Share Assets equals the sum of buckets; Payout Reserve never
  exceeds Idle; a transfer into a vault that is not from an adapter or the bridge never changes Share Price;
  sequence per spoke is strictly increasing.
- Fork tests on Arbitrum One and Robinhood Chain (never testnets): real Uniswap V4 pools and the real Aave V3 Pool, real Across
  SpokePools (fills simulated by dealing the output token and calling `handleV3AcrossMessage` from the SpokePool
  address), real Wormhole Core with `WormholeOverride` signing VAAs.
- End-to-end fork scenario: deposit on Arbitrum, send to Robinhood, fill, open a WETH/USDG V4 position, report,
  deliver VAA, deposit again at the new price, request and claim a payout.
