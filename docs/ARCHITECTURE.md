# Architecture: buildathon MVP

Target design for the first contracts. Every rule cites the decision that governs it (`DEC-nnn`, see
`docs/DECISIONS.md`). Where no decision exists, the section says **OPEN** and points to `docs/OPEN-QUESTIONS.md`;
the code then takes the conservative path and exposes a parameter or an interface so the founder's answer slots
in without a redesign.

Scope: Arbitrum One (Hub Chain) and Robinhood Chain (Spoke Chain), Uniswap V3 positions on both chains, Across
as the Transport Route, Wormhole (finalized consistency) for value reports. Addresses in `docs/INTEGRATIONS.md`.

## 1. Components

```
                         ARBITRUM ONE (Hub Chain)                     ROBINHOOD CHAIN (Spoke Chain)
  Shareholder ─deposit/requestPayout/claim/withdrawIncome─▶ CoreVault
  Manager ─────sendToSpoke / allocate on hub──────────────▶ CoreVault ──▶ SpokeVault(hub) ──▶ UniswapV3Adapter
  Anyone ──────deliver VAA───────────────────────────────▶ ValueReportReceiver ◀── Wormhole VAA ◀── SpokeVault(robinhood).report()
                                                           AcrossBridgeAdapter ══ Across ══▶ SpokeVault(robinhood).handleV3AcrossMessage
                                                                                              SpokeVault(robinhood) ──▶ UniswapV3Adapter
  FundFactory (CREATE2, same salt on both chains) deploys everything from the Mandate.
```

| Contract | Chain | Responsibility | Decisions |
|---|---|---|---|
| `ShareToken` | hub | ERC-20, 18 decimals, only whole shares (multiples of 1e18) ever minted or burned; `transfer`, `transferFrom`, `approve` revert; only the Core Vault mints and burns | DEC-004, DEC-035, DEC-077, DEC-091 |
| `CoreVault` | hub | Custody of Idle USDC; share ledger via `ShareToken`; Payout Requests and Payouts; Attributed Income bucket and Income Withdrawal; sends capital to spokes through a bridge adapter; the transit state machine; reads the hub `SpokeVault` directly and the spoke values from `ValueReportReceiver`. Never calls a DeFi protocol. | DEC-009, DEC-020, DEC-054, DEC-065, DEC-067, DEC-072, DEC-077, DEC-081, DEC-085, DEC-090, DEC-095, DEC-105 |
| `SpokeVault` | every chain, hub included | The fund's account on a chain: internal ledger per token (never `balanceOf`), position registry per adapter, Unallocated Balance, Operating Cash bucket; drives adapters within the Mandate's closed lists; receives Across fills; builds and publishes value reports (spoke chains) or exposes the same data to the Core Vault (hub) | DEC-054, DEC-069, DEC-070, DEC-079, DEC-080, DEC-093, DEC-096 |
| `ValueReportReceiver` | hub | Accepts a spoke's report only if the guardian quorum signed it, the emitter is the fund's Spoke Vault on that chain, the sequence is strictly greater than the last accepted, and the report is within the max age; stores the latest accepted report per spoke | DEC-086, DEC-093, DEC-094, DEC-099 |
| `UniswapV3Adapter` | both | Opens, increases, decreases, closes and collects V3 positions in pools from the Mandate's closed list; reports principal and income of each position **separately** by reading the pool's own accounting; immutable, one instance per fund per chain | DEC-053, DEC-058, DEC-079 |
| `AcrossBridgeAdapter` | both | Builds the Across `depositV3` call for the vault; the **vault**, not the adapter, fixes the recipient (the fund's own vault on the destination chain) and the token pair; 6-hour fill deadline as an adapter constant | DEC-031, DEC-066, DEC-087, DEC-088, DEC-090 |
| `TransitEscrow` | both | Minimal per-send depositor (EIP-1167 clone) so an Across refund lands in a dedicated address and can be recognized as a Reverted transit rather than mistaken for a donation | implements research proposal QA6; **OPEN** |
| `ManagerRegistry` | hub | One record per manager: protocol slice of the manager's fee (default 50%), adjustable per manager by the protocol; outside the Mandate | DEC-106, DEC-110 |
| `FundFactory` | both | Deploys a fund's contracts from its Mandate with CREATE2 and a fund-id salt so hub and spoke addresses are known to each other at creation | DEC-053, DEC-054 |
| `IPriceSource` + `ChainlinkPriceSource` | hub | Prices non-USDC tokens carried in reports and hub positions into USDC for Share Assets; pluggable because the pricing rule is **OPEN** | see §5 |

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
| `performanceFeeBps`, `managementFeeBps` | uint16; management default 0 | may only **decrease** after creation | DEC-107, DEC-108, DEC-110 |
| `operatingCashFloor[chainId]`, `operatingCashTopUp[chainId]` | uint256 | manager may adjust on a live fund | DEC-096, DEC-100 |
| `maxReportAge[spoke]` | uint32 seconds | immutable; value **OPEN** (Q57) | DEC-094, DEC-099 |
| `maxBridgeFeeBps` | uint16 | immutable; value **OPEN** (QA19) | DEC-030 exception |

Protocol-level constants live in the core, not the Mandate: flow fee 25 bps default with a 100 bps cap
(DEC-106), fee caps for performance and management fees (DEC-110; the cap values are **OPEN**, LC-144).

## 3. Value bases (DEC-042, DEC-083, DEC-084, DEC-098, DEC-104)

- **Share Assets** = Idle (incl. Payout Reserve) + hub positions' principal (read directly from the hub Spoke
  Vault) + In-flight Value at the amount that will arrive (DEC-085) + each spoke's principal and Unallocated
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
   to 6 decimals, the remainder never leaves the wallet (DEC-061). Revert if `shares < minShares` or zero.
4. Pull USDC, mint, credit Idle. Same transaction; no queue; no wait for a fresh report (DEC-071, DEC-085).
5. Update the income accumulator checkpoint for the depositor before minting (§4.5).

### 4.2 Allocation
- Hub: `CoreVault.allocateToHubSpoke(amount)` moves Idle to the hub Spoke Vault's Unallocated Balance; the
  manager then opens positions on the hub Spoke Vault. Only Free Idle may be allocated (DEC-017, DEC-072).
- Spoke: `CoreVault.sendToSpoke(spokeIndex, amount, bridgeIndex, quote)`: manager only; revert unless
  `spokeValue + inFlightTo + inFlightFrom + amount <= spokeCap` (DEC-037, DEC-095); the bridge adapter builds
  the Across deposit with recipient = the spoke's vault, `outputAmount` from the quote, fill deadline = now + 6 h;
  the vault checks the quote's fee against `maxBridgeFeeBps`; a `TransitEscrow` clone is the depositor;
  in-flight counted at `outputAmount` (DEC-085). Transit state: `Initiated`.
- Arrival: the Robinhood Spoke Vault's `handleV3AcrossMessage` (callable only by the Across SpokePool, only for
  USDG) credits Unallocated Balance and records the deposit id as arrived; the next report carries the arrived
  ids; the receiver moves those transits to `Arrived` and drops them from In-flight (DEC-090).
- Expiry: after the fill deadline, if the refund reaches the escrow, `recognizeRefund(transitId)` pulls it back
  to Idle and marks `Reverted` (DEC-066). Cap is released on the first known outcome.

### 4.3 Positions (Spoke Vault on any chain)
Manager-only `openPosition`, `increasePosition`, `decreasePosition`, `closePosition`, `collectIncome`, each
restricted to `(adapter, poolKey)` in the Mandate. The vault transfers tokens to the adapter, the adapter acts
on the protocol and returns `(principalDelta0, principalDelta1, income0, income1)`; the vault updates its
ledger from what the adapter returned, never from balances (DEC-080). Income collected goes to the income bucket
of the vault (spoke) or is bridged/handed to the Core Vault's Attributed Income (hub). Adapter pause blocks
open/increase only, never decrease/close/collect (DEC-021, DEC-058; who may pause is **OPEN**).

### 4.4 Value report (DEC-070, DEC-086, DEC-093)
`SpokeVault.report()` is permissionless: builds `ReportPayload { fundId, sequence, spokeChainId, blockNumber,
timestamp, unallocated[token], positions[] {adapter, poolKey, token0, token1, principal0, principal1, income0,
income1}, arrivedTransitIds[], inFlightToHub }` from the ledger and adapters, and calls
`CoreBridge.publishMessage(nonce, payload, 1 /* finalized */)`. Anyone delivers the VAA to
`ValueReportReceiver.deliver(bytes vaa)`, which verifies with the Core Bridge, checks emitter chain and address
against the Mandate, requires `sequence > lastSequence`, requires `now - timestamp <= maxReportAge`, and stores
the report. Pricing of the quantities into USDC happens on the hub through `IPriceSource` (§5).

### 4.5 Attributed Income (DEC-014, DEC-025, DEC-064, DEC-073, DEC-092)
Global accumulator `incomePerShare` (1e18 scale) with a per-holder checkpoint, advanced only when income is
recognized (adapter collect on the hub; spoke report income for spoke positions, pending Q60 details). Holders
call `withdrawIncome()` to take the USDC out at any time without burning shares; burning all shares pays the
income too. No compounding in the contract (DEC-064). Performance fee is taken on income at collection, in
kind, no high-water mark (DEC-107, DEC-109); the protocol slice is read from `ManagerRegistry` at that moment
(DEC-106). Exact accumulator mechanics for spoke income are **OPEN** (Q60); the MVP recognizes spoke income
only when it is actually bridged back to the hub, which is conservative.

### 4.6 Payout (DEC-020, DEC-024, DEC-060, DEC-065, DEC-067, DEC-074, DEC-075, DEC-077, DEC-081, DEC-095, DEC-102, DEC-105)
- `requestPayout(uint256 usdcAmount, PayoutMode mode)`: one open request per holder, not cancellable, shares
  are not locked or burned at request time. Standard: reserve `min(usdcAmount, Free Idle)` in the Payout
  Reserve as USDC and start the term. Instant: no reserve.
- `claim(bytes unwindHints)`: only the requester. If the idle the request may use covers it (Instant: Free
  Idle only, never the Payout Reserve; Standard: its reserve then Free Idle), burn `floor(amount / sharePrice)`
  whole shares, pay `shares * sharePrice` (never more than requested), atomically. Otherwise unwind in Mandate
  order only what is missing plus 2% (fund bears the margin's market cost, DEC-097), proceeds go to Idle, then
  require a report from every spoke with sequence after the unwind (DEC-105) before burning at the resulting
  Share Price. Partial Payout burns only what was paid and leaves the USDC remainder open (DEC-068).
- Instant: 2% Payout Fee on the requested amount into Operating Cash (DEC-102); network costs charged to the
  requester separately (**OPEN** how, LC-45/LC-47: MVP charges nothing extra and flags it). Standard: after the
  term the requester's claim runs the remaining unwind; the fund pays network costs from Operating Cash (DEC-060).
- Flow fee 25 bps on the amount paid out goes to the Protocol Recipient (DEC-106).
- Unwinds on a spoke need an instruction from the hub. **OPEN** (feedback question 2): MVP restricts automatic
  unwind to hub positions and to spoke positions the manager has already closed and bridged; a spoke unwind
  driven by a hub-to-spoke message is the next milestone.

### 4.7 Operating Cash (DEC-041, DEC-096, DEC-100, DEC-102)
Per-chain bucket fed by the Payout Fee and top-ups; floor and top-up amounts adjustable by the manager; when it
falls below the floor the next operation tops it up from Share Assets (accepted effect on Share Price). Spending
it (relayer gas reimbursement) is **OPEN** (doc 30); the MVP keeps the bucket and the top-up rule only.

## 5. Pricing (**OPEN**, the most consequential gap)

Reports and hub positions carry token quantities. Share Assets needs a USDC value for WETH and for USDG.
Decisions say: no oracle in the payout path for the unwound part (DEC-032, DEC-081), the report is read before
the burn (DEC-081, DEC-105), and the buildathon draft leans to "quantities in the report, Chainlink on the hub"
(feedback question 1, option B). Nothing is decided. The MVP therefore:
- puts pricing behind `IPriceSource.priceInUsdc(token) -> (price, decimals, updatedAt)`;
- ships `ChainlinkPriceSource` for WETH on Arbitrum and a fixed 1:1 for USDG (working assumption of the draft);
- rejects a price older than a configurable staleness bound;
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
  checks-effects-interactions; custom errors; no `tx.origin`; no delegatecall into adapters.
- No upgradeability: a live fund never adopts new code; a new version is a new fund (DEC-058).
- Pausing an adapter blocks entries only; exits always work (DEC-021).

## 7. Testing strategy

- Unit and fuzz tests for every library and every rule, named after the decision (`test_DEC067_idlePaysWholeRequest`).
- Invariants: `totalSupply` is a multiple of 1e18; Share Assets equals the sum of buckets; Payout Reserve never
  exceeds Idle; a transfer into a vault that is not from an adapter or the bridge never changes Share Price;
  sequence per spoke is strictly increasing.
- Fork tests on Arbitrum One and Robinhood Chain (never testnets): real Uniswap V3 pools, real Across
  SpokePools (fills simulated by dealing the output token and calling `handleV3AcrossMessage` from the SpokePool
  address), real Wormhole Core with `WormholeOverride` signing VAAs.
- End-to-end fork scenario: deposit on Arbitrum, send to Robinhood, fill, open WETH/USDG position, report,
  deliver VAA, deposit again at the new price, request and claim a payout.
