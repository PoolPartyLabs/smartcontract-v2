# Core Vault (shares, deposit, payout, value bases, Operating Cash) review

Reviewer slug `core-a`, repository `PoolPartyLabs/smartcontract-v2` at `e5c778a`. PoCs in `test/review/core-a/` of the
working copy `smartcontract-v2-b`; all run with `forge test --match-path 'test/review/core-a/*' -vv` (10 passed, 0 failed).

## Summary
The share arithmetic of deposit and payout is sound: `payoutReserve <= idle` holds on every path, burns and payments are whole-share, atomic, rounded against the actor and never above the request, and a stranger cannot force the payout fallback at normal position counts.
The value bases are not sound. Share Assets value Uniswap V4 principal at the pool's spot composition, so one swap moves the Share Price used for mints and Idle-paid burns (C-01).
They also lose a whole unfilled transfer home between its "presumed filled" time and its reported refund (H-02). And the manager can move all Free Idle into an Operating Cash bucket that nothing can ever spend or return (H-01).
Counts: Critical 1, High 2, Medium 0, Low 5, Info 8.

## Findings

### [C-01] Share Price follows the Uniswap V4 spot price: position principal is spot-composition amounts times the oracle price
- Status: CONFIRMED (PoC passes)
- Where: `src/core/CoreVaultLogic.sol:219-248` (`_hubValue`, `_positionsPrincipal`), `:271-284` (`_spokePrincipal`), `:307-317` (`_usdcValue`). The amounts come from `src/adapters/UniswapV4Adapter.sol:266-284` and `:621-637` (`_principal` reads `slot0` at `:626`) through `src/spoke/SpokeCrossChainLib.sol:160` (`_build`, shared by the hub `buildReport` and the spoke `report()`). They are consumed at `src/core/CoreVault.sol:69` (deposit), `:105` (requestPayout) and `:185` (claimPayout).
- Rule: DEC-067 ("Hub LP valued at guarded pool price"); QA3 (the payment guard is undecided, but it is not optional); DEC-084 and DEC-105 (one Share Price for mint and burn); the ARCHITECTURE §7 invariant that third parties never move the Share Price; the Q57 (b) stance.
- What: For every V4 position the hub adds `principal0 * price(token0) + principal1 * price(token1)`. `principal0/1` is what the position would return at the pool's current `slot0` price, and `price()` is the Chainlink or fixed oracle.
  For a concentrated position, `V(P) = x(P)*P_oracle + y(P)` has `dV/dP = x'(P)*(P_oracle - P)`, so it is at its minimum when spot equals oracle. Any spot move away from the oracle, in either direction, therefore raises Share Assets although no value entered the fund.
  - On the hub the value is read live by every deposit, request and claim.
  - On a spoke it is frozen into the report by whoever calls the permissionless `report()` right after moving the price. It then stays in Share Assets until a newer report is delivered, and payouts never age it out.
  - Nothing compares spot with the oracle.
  - With V4 flash accounting the manipulation needs no capital: swap, call the Core Vault, swap back inside one `unlock`. The only cost is the pool fee on the round-trip volume, and part of that fee comes back to the fund as income when the fund is an in-range LP.
- Scenario (numbers from the PoC):
  1. Alice deposits 600,000 USDC and Mallory 400,000 (flow fee 25 bps). The manager allocates 400,000 to the hub Spoke Vault, swaps half into WETH at 2,500 and opens a WETH/USDC position of ±1,000 ticks (±10.5%) around the price. Share Assets are 997,497 USDC and the Share Price is 0.999995.
  2. Mallory opens a Standard Payout Request for 300,000 USDC, fully reserved, and 72 h pass.
  3. In one transaction Mallory swaps the pool just above the range, calls `claimPayout("")`, then swaps back. Chainlink does not move.
  4. During the claim Share Assets read 1,007,740 (+10,243). The claim burns 296,952 shares instead of 300,001 for the same 299,249 USDC paid. It is Idle-paid: no unwind and no swap by the fund.
  5. After the swap back the remaining shares are priced 0.995642 (−0.44%). Mallory kept 3,049 shares worth 3,035.7 USDC, taken from Alice.
  6. Against an entrant, a 100,000 USDC deposit made while the spot is displaced mints 98,736 shares. Once the spot is back they are worth 98,827 of the 99,750 paid, so the entrant loses 923 USDC to the existing holders. `minShares` protects only an entrant who derived it from an oracle price.
  7. The effect grows with the move relative to the range. A one-sided (range-order) position 10 to 20% away from the price is inflated by `sqrt(Pa*Pb)/P_oracle - 1`, about 15%, when the spot is pushed through it.
- PoC: `test/review/core-a/C01_SpotCompositionValuation.t.sol`, on the fixture `test/review/core-a/CoreAHubFixture.sol`.
  - The fixture uses the real `CoreVault` + `CoreVaultLogic`, the real hub `SpokeVault` + `SpokeCrossChainLib` and the real `UniswapV4Adapter` over `MockV4`. The spot move is `MockV4.setTick`, the pool state a swap leaves, and the swap back restores the exact initial price.
  - Command: `forge test --match-path 'test/review/core-a/C01*' -vv`. Result: 3 passed (`test_C01_sharePriceFollowsSpotWithOraclePriceUnchanged`, `test_C01_claimantBurnsFewerSharesByMovingSpotAroundTheClaim`, `test_C01_depositSandwichedBySpotMoveOverpays`).
  - Limit: MockV4 swaps at a fixed rate, so the attacker's swap cost is argued, not simulated. It is the standard AMM round trip: the same curve both ways, so the net cost is the fees.
- Fix:
  - Value V4 principal at an oracle-derived price, never at the spot composition: `getAmountsForLiquidity(sqrtPriceFromOracle(token0, token1), sqrtA, sqrtB, liquidity)`.
  - The report already carries `tickLower`, `tickUpper` and `liquidity`, so the hub can recompute spoke positions itself and ignore `principal0/1`.
  - Add the DEC-067 guard as defence in depth: compare `slot0` with the oracle, revert mints, and refuse to publish or accept a report when the deviation exceeds a band (the QA3 parameter).
- Known?: No.
  - The QA3 MVP row (`docs/OPEN-QUESTIONS.md:82`) bounds only the unwind swap's execution against spot.
  - The Q57 (b) row (`:26`) prices report quantities with Chainlink but does not say the quantities are spot-derived and movable within a block.
  - No REVIEW-LOG entry covers it.
  - DEC-067 requires a guarded price and no open question covers its absence in the valuation. Grounds (b) and (d).

### [H-01] Hub Operating Cash is a one-way sink with unbounded parameters: the manager can move all Free Idle out of Share Assets for good
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/core/CoreVaultBase.sol:269-273`: `setOperatingCashParameters`, no bound.
  - `:283-296`: `_topUpOperatingCash`.
  - The only writers of `operatingCash` are `CoreVaultBase.sol:293` and `CoreVault.sol:243`, and both add.
  - `_ledger` (`CoreVaultBase.sol:324-327`) keeps the bucket out of `sweepExcess`, and `_valuation` keeps it out of Share Assets.
  - The top-up runs at `CoreVault.sol:66` (deposit), `:153` (claim), `CoreVaultTransit.sol:28` (allocate) and `:67` (send).
- Rule: DEC-096 (floor about 1 USD, top-up about 3 USD; "at fund close Operating Cash is distributed to shareholders"); DEC-013 (restricted to operations); DEC-100 (a top-up's price drop is accepted, no cap on the floor); DEC-072.
- What: The manager may set any floor and any top-up. While cash is below the floor, every deposit, claim, allocation or send moves `min(topUp, Free Idle)` from Idle into Operating Cash.
  In the MVP nothing ever debits hub Operating Cash: there is no spending verb, no return to Idle and no fund close. The bucket is also outside Share Assets and counts as ledger for the sweep.
  One parameter change therefore sends all Free Idle into a bucket nobody can reach, and the Share Price falls by `freeIdle / supply` for good. Standard reserves are not taken by the top-up, but they are then paid at the collapsed price.
  Even without malice, every Instant Payout Fee (`CoreVault.sol:243`) and every routine top-up accumulates there with no exit, against DEC-096's close-out rule.
- Scenario:
  1. Alice and Bob deposit 500,000 USDC each. Bob opens a Standard Payout Request for 498,750, fully reserved. The Share Price is 1.00.
  2. The manager calls `setOperatingCashParameters(type(uint256).max, freeIdle - 1)` and then `allocateToHubSpokeVault(1)`.
  3. 498,749.999999 USDC move to Operating Cash, Free Idle is 0 and the Share Price is 0.50.
  4. After the term, Bob's claim burns all his shares and pays 248,751.56 USDC, about half of what he held. Alice's shares are worth half. `sweepExcess(usdc)` returns 0, and the 498,750 USDC stay in the Core Vault permanently.
  5. Variant: with both parameters at max, the next third-party deposit of 1,000 USDC runs the drain by itself, and Alice's value falls from 997,500 to 100,000.
- PoC: `test/review/core-a/H01_OperatingCashSink.t.sol`, command `forge test --match-path 'test/review/core-a/H01*' -vv`. Result: 2 passed.
- Fix:
  - Cap floor and top-up with core constants at the DEC-096 scale (for example at most 100 USDC each), or cap one top-up at a small fraction of Share Assets.
  - Give the bucket an exit consistent with DEC-096 and DEC-013: return cash above the floor to Idle, or distribute it at close.
- Known?: Partly.
  - ARCHITECTURE §4.7 and the DEC-041 row say that spending is OPEN and that top-ups lower the Share Price, and DEC-100 accepts an uncapped floor.
  - Nothing discloses that the top-up amount is uncapped too, or that the bucket has no outflow at all, so that the manager can lock 100% of Free Idle. Ground (b).
  - Severity is High under the brief's threat model (a malicious manager, a permanent lock). It is Medium if DEC-100 is read as accepting it.

### [H-02] An unfilled Principal transfer home leaves every value base between `fillDeadline + maxReportAge` and its reported refund
- Status: CONFIRMED (PoC passes)
- Where:
  - Hub side: `src/core/CoreVaultLogic.sol:292-303` (`_returnLeg` reads only the latest report) with `:208`.
  - Root cause on the spoke: `src/spoke/SpokeCrossChainLib.sol:300-302` (`_stillInFlight`), `:103-106` (the `nextReport` prune) and `:184` (the `_build` filter).
  - The amount returns to Unallocated Balance only at `recognizeRefund` (`:84`).
- Rule: DEC-104 (no recognized value outside all bases); DEC-085; DEC-066 (released by confirmed arrival, attested expiry or recognized refund; the hub-to-spoke leg is kept until the refund, QB11 stance); the OQ-09 stance.
- What: A spoke-to-hub Principal transfer counts in Share Assets only while the spoke's latest report lists it. The spoke stops listing it at `fillDeadline + maxReportAge` ("presumed filled") whether or not it was filled.
  When it was not filled, Across refunds the escrow 55 to 90 minutes after the deadline (DEC-063 facts). The amount re-enters Unallocated Balance only after someone calls `recognizeRefund` on the spoke and a later report is delivered.
  In between, the value is in no base: not on the spoke, not in the return leg, not in Idle and not in `unmatchedArrivals`. Share Assets fall by the whole amount and jump back later. Mints in the window are underpriced and payouts in the window underpay.
  The manager controls the send (`sendToHub` is manager-only and forwards the quote's `exclusiveRelayer` and `exclusivityDeadline`, `SpokeCrossChainLib.sol:240-266`). It can therefore make a transfer home that only its own address may fill, and open the window at will. Anyone can exploit a window that opens naturally.
- Scenario (numbers from the PoC):
  1. Alice deposits 200,000 USDC. The manager sends 100,000 to Robinhood, 99,940 USDG arrive and a report confirms them. Share Assets are 199,440.
  2. The manager sends 99,940 USDG home as Principal with an exclusive relayer that never fills. The next report lists the transfer, and Share Assets are 199,380.
  3. At `fillDeadline + maxReportAge + 1`, the report built by the real Spoke Vault lists nothing in flight and shows Unallocated Balance 0. Share Assets are 99,500 and the Share Price is 0.4987.
  4. Mallory deposits 100,000 USDC. The report and the prices are fresh.
  5. The refund lands, anyone calls `recognizeRefund` on the spoke, and the next report brings the Share Price back to 0.7489.
  6. Mallory's shares are worth 149,783 (+49,783). Alice's are worth 149,407, down from 199,440.
- PoC: `test/review/core-a/H02_ReturnLegDroppedBeforeRefund.t.sol`. Every report is built by the real spoke `SpokeVault`; only Wormhole, the receiver and Across are mocks. Command: `forge test --match-path 'test/review/core-a/H02*' -vv`. Result: 1 passed.
- Fix: keep the hub's own book.
  - The hub already stores `listed` and `credited` per hub-bound key (`HubBoundTransfer`).
  - Keep counting `listed - credited` for every Principal transfer the hub has seen listed until it is credited or the spoke reports its refund. For that, add refunded ids or a monotonic `cumulativeRefundedHome` to the report next to `cumulativeSentHome`.
  - This mirrors how a hub-to-spoke transit stays in In-flight Value until its refund. Alternatively, the spoke keeps listing an unfilled transfer until its refund is recognized.
- Known?: No. OQ-09 (`docs/OPEN-QUESTIONS.md:53`) and the spoke REVIEW-LOG OQ-09 item describe the prune ("presumed filled; a later refund is still recognized") but not its effect on Share Assets. Ground (b).

### [L-01] A Payout Fee near 100% makes every Instant claim underflow, and the request can then never close
- Status: CONFIRMED (PoC passes)
- Where: `src/mandate/Mandate.sol:175` (accepts `payoutFeeBps <= 10_000`), `src/core/CoreVault.sol:223-226`.
- Rule: DEC-110 (fee caps are core constants); DEC-024 (no cancel); DEC-056.
- What: `usdcPaid = gross - payoutFee - flowFee`. With `payoutFeeBps + flowFeeBps > 10_000`, every Instant claim with a gross of 400 base units or more reverts with an arithmetic panic. The open request cannot be cancelled and blocks a new Standard request, so the holder's shares are stuck.
- Scenario: The Mandate has `payoutFeeBps = 10_000` and the flow fee is 25 bps. Alice deposits 1,000 and requests an Instant Payout of 500. `claimPayout` reverts, and `requestPayout(Standard)` reverts with `PayoutRequestAlreadyOpen`.
- PoC: `test/review/core-a/L01_PayoutFeeTrap.t.sol`. Result: 1 passed.
- Fix: Cap `payoutFeeBps` in MandateLib with a core constant far below `10_000 - MAX_FLOW_FEE_BPS`, with a named error.
- Known?: No. The DEC-095 row covers only the zero term.

### [L-02] A spoke that never delivered a report is never stale for mints
- Status: PLAUSIBLE (reasoned from code)
- Where: `src/core/CoreVaultLogic.sol:202-205`.
- Rule: Q57 reading (a mint closes on a stale report), DEC-071.
- What: `_spokeValue` returns before the MINT staleness check when `hasReport` is false, but it still counts that spoke's hub-to-spoke transits at `amountToArrive`. After an attested expiry it keeps counting them until a refund that never comes, because they did arrive.
  If the spoke's positions lose value and nobody delivers a report, mints keep pricing that capital at the amount sent. Anyone can publish and deliver a report, which limits the risk.
- Fix: In MINT mode, treat a spoke that holds In-flight Value but has no accepted report as stale.
- Known?: No. ARCHITECTURE §4.1 step 6 speaks only of a "last accepted report".

### [L-03] Every exit depends on a push to the immutable Protocol Recipient
- Status: PLAUSIBLE
- Where: `src/core/CoreVault.sol:259` (payout flow fee), `:86` (deposit fee), `src/core/CoreVaultLogic.sol:395` (slice at collection).
- Rule: DEC-021 and DEC-056 ("investor exit is unblockable"); the payout-liveness stance (OQ-10).
- What: If the Protocol Recipient cannot receive USDC (a USDC blocklist on that address, or a recipient contract that reverts), every claim with a non-zero flow fee reverts, in every fund. Deposits and income collection revert too, and the address is immutable in each Core Vault.
- Fix: Accrue protocol fees in a ledger bucket that the recipient pulls, or `try` the push and keep a failed amount owed.
- Known?: No.

### [L-04] A full exit pushes every income token; one failing token blocks the full exit
- Status: PLAUSIBLE
- Where: `src/core/CoreVault.sol:261`, then `src/core/CoreVaultIncome.sol:46-59`.
- Rule: DEC-045, DEC-047.
- What: `_payAllIncome` transfers each registered income token, and these are the tokens of the manager's hub pools, so any ERC-20 the Mandate lists. A paused or blocklisting token makes every claim that burns the holder's last share revert. The holder must keep one share to get out.
- Fix: Wrap each token's payment in `try`, leave a failed amount owed (withdrawable later) and emit an event.
- Known?: No. LC-100 covers the `min(owed, collected)` cap, not failing tokens.

### [L-05] Every deposit, request and claim runs the full report builder over every hub position
- Status: PLAUSIBLE (measured: the hub read costs 135k gas for one position; `test/review/core-a/GasFallbackMeasure.t.sol`)
- Where: `src/core/CoreVaultLogic.sol:225,227` calls `buildReport`, which computes `cumulativeIncome` for every ledger token over every adapter and every position (`src/spoke/SpokeCrossChainLib.sol:149`, `:121-127`) on top of `positionValue` (`:160`).
- Rule: DEC-092 ("must not read all positions on each user operation"); the `UniswapV4Adapter.sol:290-292` NatSpec ("never from a Shareholder path").
- What: The Core Vault's valuation pays for income counters it never reads. The manager controls the number of positions, so it can make mints arbitrarily expensive, up to a denial of service of deposits.
  Beyond about 63 times the work left after the read (about 9.9M gas at the measured 157k), a claimant can starve the wrapped read of gas (the 63/64 rule) and force the `lastHubValue` fallback whenever that pays better.
- Fix: Add a hub-valuation view that returns only Unallocated Balance and principal, and cap the number of open positions per chain.
- Known?: Partly. The V4 verifier finding (`docs/REVIEW-LOG-2026-09-29.md:70`) asked callers to keep `cumulativeIncome` off Shareholder paths, but the Core Vault reaches it through `buildReport`.

### [I-01] NatSpec says `receiveCollectedIncome` can be called back during a payout
`src/core/CoreVaultBase.sol:58-59` says the hub Spoke Vault may call back `receiveCollectedIncome` during a payout. It is `nonReentrant` (`CoreVaultIncome.sol:28`) and would revert. The code agrees with CoreVaultIncome's own NatSpec, so only the base comment is wrong.

### [I-02] `lastHubValue` refresh condition is wider than documented
`recordValuation` refreshes `lastHubValue` only when every price of the whole valuation answered, spoke tokens included (`CoreVaultLogic.sol:98`). The NatSpec (`:83-84`) and ARCHITECTURE §4.6 say "the hub read and all its prices". The code is the more conservative of the two, so this is text only.

### [I-03] `sweepExcess` NatSpec lists a ledger item that no longer exists
The `sweepExcess` NatSpec (`src/interfaces/ICoreVault.sol:336`) still lists "owed fees" as ledger. They no longer exist, since fees leave at collection.

### [I-04] Gross Assets omit spoke income in flight home
Gross Assets (`CoreVaultLogic.sol:120-138`) leave out spoke Income-kind transfers in flight home, although DEC-098 says Attributed Income counts "collected or not". Gross Assets are informational only.

### [I-05] `claimPayout` and `deposit` NatSpec do not match the code
The `claimPayout` NatSpec (`ICoreVault.sol:302-303`) requires a post-unwind spoke report before burning. The MVP never asks for one: the unwind is hub-only, per the erratum 11 reading. The `deposit` NatSpec omits the `StalePrice` revert.

### [I-06] Some events are emitted before the token movements
`Deposited` (`CoreVault.sol:82`) and `AllocatedToHubSpokeVault` (`CoreVaultTransit.sol:33`) are emitted before the token movements, so the operation does not end with its event (founder's best practice). The transaction is atomic, so nothing is lost.

### [I-07] The first-deposit minimum is checked on the gross amount
The first-deposit minimum (`CoreVault.sol:64`) compares the gross amount, before the flow fee. A first deposit of exactly `minFirstDeposit` therefore mints shares worth `minFirstDeposit - fee`.

### [I-08] Test gap: no Core Vault test values a real V4 position
Every Core Vault unit and invariant suite uses `MockHubSpokeVault`, whose position has a fixed principal (`test/unit/core/CoreVaultInvariant.t.sol:10-17`). No test values a real V4 position or prunes a real return leg, so the "Share Price never moved by third-party entries" invariant cannot see C-01 or H-02.

## Checks and validations

| Function | Access control | Input validation | Reentrancy guard | CEI order | Event | Gaps |
|---|---|---|---|---|---|---|
| `CoreVault.deposit` | anyone | `usdcAmount > 0`; first-deposit minimum (gross, I-07); `shares > 0` and `>= minShares`; MINT valuation (fresh reports and prices, no fallback) | `nonReentrant` (transient) | valuation (STATICCALLs) → checkpoint, `idle` → two pulls → mint | `Deposited` (before transfers, I-06) | priced off the spot composition (C-01); no deadline, only `minShares` |
| `CoreVault.requestPayout` | holder with shares | `usdcAmount > 0`; no open request; `balance > 0`; at least one share at the payout price; reserve `min(amount, value, freeIdle)` | `nonReentrant` | valuation (writes last known values), then state | `PayoutRequested` | reserve bound uses the spot-inflatable price (C-01) |
| `CoreVault.claimPayout` | the caller's own request (DEC-065) | open; Standard term ended; `balance > 0` | `nonReentrant`; `_unwinding` admits only `returnToIdle` from the hub Spoke Vault | top-up → valuation → unwind (an external call before effects, contained by the guard and the sub-call rollback) → effects → burn, flow fee, pay, income | `PayoutExecuted` / `PartialPayoutExecuted`; `UnwindForPayoutFailed` | underflow at a Payout Fee near 100% (L-01); depends on a Protocol Recipient push (L-03) and on every income token (L-04); burn price spot-inflatable (C-01) |
| `CoreVaultBase.setOperatingCashParameters` | `onlyManager` | **none** | none (no value moved) | n/a | `OperatingCashParametersSet` | unbounded floor and top-up into a sink with no exit (H-01) |
| `CoreVaultTransit.allocateToHubSpokeVault` (moves `lastHubValue`) | `onlyManager` | `> 0`; at most Free Idle after the top-up | `nonReentrant` | `idle`, `lastHubValue` → transfer → `receiveFromCoreVault` | `AllocatedToHubSpokeVault` (before transfer) | runs the unbounded top-up (H-01) |
| `CoreVaultTransit.returnToIdle` (moves `lastHubValue`) | hub Spoke Vault only; refused inside any guarded call except the payout unwind | `> 0`; backed by unledgered USDC | none, by design (callback) | effects only | `ReturnedToIdle` | none |
| `CoreVaultLogic.recordValuation` (library) | only through the vault's guarded entries (DELEGATECALL); a direct call is blocked by library call protection | mode MINT or PAYOUT | caller's guard | reads first, then writes last known values | `HubValuationFallback`, `PriceFallback` | refresh condition documented narrower (I-02) |
| `ShareToken.mint` / `burn` | Core Vault only (`burn` needs no allowance) | multiple of 1e18 | n/a (no external call) | n/a | `Transfer` | none |
| `ShareToken.transfer` / `transferFrom` / `approve` | always revert (DEC-004); `allowance` is 0; no `permit` | n/a | n/a | n/a | n/a | none |

## Checked and found correct
- **`payoutReserve <= idle`.** Every writer of `idle` (`CoreVault.sol:81,239`; `CoreVaultBase.sol:292`; `CoreVaultTransit.sol:31,46`; `CoreVaultLogic.sol:524,600,750`) either adds or spends at most Free Idle, or at most the claimant's `freeIdle + own reserve`.
  - In `_executePayout`, `gross <= available` in both branches. Complete: `gross = wanted <= available`. Partial: `gross = usdcFor(floor(available / price)) <= available`.
  - The reserve drops by exactly the used part, or by all of it on close.
- **Claim twice, or be paid from someone else's reserve.** Neither is possible. There is one request per address, Instant uses Free Idle only, and Standard uses Free Idle plus its own reserve, where Free Idle already excludes every reserve. A closed request has `open = false`.
- **Burn without payment, or payment without burn.** Neither is possible, and burn and payment happen in the same transaction.
  - A partial never burns the whole balance. Since `available < wanted <= usdcFor(balance)`, it follows that `floor(available / price) < balance`.
  - `closedBelowOneShare` burns 0 and pays 0 and releases the reserve.
  - A complete payout burns exactly the shares whose value it pays.
- **Never pays more than requested; rounding favours the fund; whole shares.** `usdcFor(floor(outstanding / price)) <= outstanding`, with the price floored, shares floored and USDC floored.
  - Fuzzed in `test/review/core-a/ShareMathReview.t.sol`, 2 × 512 runs, pass: whole shares, paid ≤ request and ≤ pro rata.
  - A mint undercharges by less than one base unit per whole share plus one, which is negligible.
  - Arithmetic is overflow-safe for realistic sizes.
- **ShareToken.** Transfers, approvals and allowances are disabled, and `permit` is absent because the token is a plain OZ ERC20. Mint and burn are Core Vault only and whole-share.
- **Deposit ordering.** Top-up, then MINT valuation, then the checkpoint with the pre-mint balance (DEC-014), then Idle, then the pulls, then the mint. The entrant is priced after the expense. Stale reports revert via `isReportFresh`, and stale prices revert per token's `maxPriceAge` (fixed tokens are always fresh).
- **A deposit never prices off a fallback.** MINT and VIEW modes call `buildReport` and `priceInUsdc` without `try` (`CoreVaultLogic.sol:224-226, 339-345`).
- **Forcing the payout fallback.**
  - Gas starvation (63/64 rule): the measured hub read costs 135k gas against about 157k of work after it, so forcing it needs a read of more than 9.9M gas. That is unreachable at normal position counts (the edge case is in L-05).
  - A price read costs 10k to 20k gas and cannot be starved at all.
  - Making the reads revert:
    - V4 `positionValue` cannot be made to revert by a stranger: `decreasePosition` keeps the key, and a close removes it from both the adapter and the vault registry.
    - Aave reads the pool index.
    - The Chainlink source reverts only on answers of zero or less.
- **Donations.** None moves Share Assets.
  - To the Core Vault: unledgered, sweepable.
  - To the hub Spoke Vault: its internal ledger ignores them.
  - Aave aTokens: become income, since principal is `min(principal, value)`.
  - V4 `donate`: becomes income (FV-16, known).
- **In-flight timing.** No third-party call moves the price by more than the bridge fee.
  - `recognizeRefund` raises Share Assets only by `amountSent - amountToArrive` (the bridge fee, about 0.06%), less than the flow fee a front-runner pays twice.
  - `attestExpiry` moves only the Spoke Cap.
  - Arrival confirmation and hub-bound credits move value between two counted places at the same amount.
  - A report stored and not yet applied is still counted once, because the unknown-origin deduction covers it.
- **Unwind failure.** A revert inside `unwindForPayout` rolls back the nested `returnToIdle` effects. `_unwinding` is reset in both branches. `proceeds = idle - idleBefore` cannot underflow, since only `returnToIdle` runs inside. The claim then continues as a Partial Payout, or reverts with `InsufficientFreeIdle` when nothing is payable.
- **Unwind hints.** Hints can only raise swap minimums, name a Mandate route for a non-USDC leg, or set a price limit or deadline. They never size an exit, and a hint that makes the unwind fail only hurts the claimant.
- **Reentrancy.** Every value-moving entry is guarded. Valuation calls go through view interfaces, so they are STATICCALLs. During a claim, only `returnToIdle` from the hub Spoke Vault is admitted. Library state-changing functions cannot be called directly.
- **Prices and decimals.** `_usdcValue = amount * price1e18 / 1e18`. The Chainlink scale is `1e24 / 10^(feedDecimals + tokenDecimals)` and the fixed-token scale is `10^(24 - decimals)`: WETH gives 2.5e9 per wei and USDG 1e18 per base unit.
- **`lastHubValue`.** It follows the only exact USDC legs: allocation adds, `returnToIdle` subtracts, floored at 0. Every other hub Spoke Vault verb moves value inside the hub value or into income.
- **Standard reserve bound (FV-OQ-1).** It is implemented as documented: `requestPayout` uses PAYOUT mode and applies the one-share floor at the payout price.
- **Fees on the paths.** The Payout Fee applies to Instant only and goes to Operating Cash (DEC-102). The flow fee is on the offered deposit amount (OQ-05) and on the gross payout (LC-143 reading), as documented.
- **Top-up source and signal.** The top-up takes Free Idle only, never the reserve, and emits `OperatingCashInsufficient` only when it falls short.
- **Income on a full exit.** It checkpoints with the pre-burn balance and pays `min(owed, collected)`. A holder's `owed` never exceeds `collected`, because the sum of floored owed amounts is at most `distributed`, which is at most `collected`.

## Not covered
- The income accumulator and fee split, the transit state machine, report application, sends, refunds and the sweep. They belong to the next round; I read them only as far as my paths needed.
- Real Uniswap V4 swap costs for C-01. MockV4 swaps at a fixed rate, so the round-trip cost argument is analytical.
- Fork tests (no RPC). The real `ValueReportReceiver` VAA path: H-02 uses the mock receiver, but the reports come from the real Spoke Vault. `ChainlinkPriceSource` wired into the Core Vault: `MockPriceSource` was used.
- The economics of Spoke Vault manager verbs (swap minimums, wash trading through the fund's own pool) beyond their effect on Share Assets.

## Outside my scope
- **Spoke Cap bypass by withholding reports** (PLAUSIBLE, not PoC'd). When no report of a spoke is delivered, the time path of `nonArrivalProvable` (`src/core/CoreVaultLogic.sol:548-550`) lets anyone attest the expiry of transits that did arrive.
  - That releases their `inFlightSent`, while Share Assets keep counting them. With no report, `spokeValue` is 0.
  - The manager can then send cap-sized amounts again and again. Any stranger who delivers a report stops it.
  - OQ-09 records this as a liveness cost, not as a cap bypass.
- **A genuine Principal transfer home can be lost for good** (PLAUSIBLE). If no report listing it reaches the hub before the spoke prunes it at `fillDeadline + maxReportAge` (for example a delivery outage of about 6.5 h, during which mints are closed anyway), its arrival is held in `unmatchedArrivals` forever.
  - See `CoreVaultLogic.sol:497-502`. It is never swept, and later reports no longer list it, so it is never matched.
  - That is a permanent loss of principal. CV-OQ-5 covers unmatched arrivals in general, not genuine ones.
