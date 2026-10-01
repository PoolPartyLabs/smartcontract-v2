# Spoke Vault (ledger, positions, swaps, automatic unwind, hub-side legs) review

Reviewer slug `spoke-a`, repository `PoolPartyLabs/smartcontract-v2` at `e5c778a`, working copy `scratchpad/smartcontract-v2`.
PoCs in `test/review/spoke-a/`. Unit PoCs run without network:
`forge test --match-path 'test/review/spoke-a/*' --no-match-path '*Fork.t.sol' -vv` (9 passed, 0 failed).
Fork PoCs and measurements need `ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc` and `ARBITRUM_FORK_BLOCK=<head - 100>`:
`forge test --match-path 'test/review/spoke-a/*Fork.t.sol' -vv` (5 passed, 0 failed at block 510379789).

## Summary
The ledger itself is sound. Every credit an adapter reports is checked against the balance, adapters are only ever pushed exact amounts, principal and income stay in separate buckets, and the sweep cannot take ledger value.
The automatic unwind is not safe. It values, sizes and swaps at the pool's spot price, and its only price guard is 95% of that same spot. A shareholder who moves the pool around their own claim takes the fund's V4 positions (C-01): 189,994 USDC profit on a 10,000 USDC stake against the real Arbitrum pool.
A deprecated V4 adapter blocks the whole unwind and strands every non-USDC principal (H-01). Spoke Operating Cash is an unbounded one-way sink (H-02). The Mandate does not bound what a manager moves out through prices (M-01, a disclosure).
Counts: Critical 1, High 2, Medium 1, Low 3, Info 5.

## Findings

### [C-01] The automatic unwind is sized and executed at the pool's spot price: a shareholder who moves the pool around their own claim takes the fund's V4 positions
- Status: CONFIRMED (unit PoC and fork PoC pass)
- Where:
  - `src/spoke/SpokeVault.sol:842-865` (`_unwindPosition`): the value comes from `positionValue` and `_unwindValue` at `:855-856`, the exit is sized at `:859`, and the whole position is closed when `value <= shortfall`.
  - `:898-901` (`_unwindValue` → `spotQuote`) and `:905-921` (`_unwindSwap`: the floor is `spotQuote × 95%`, `:908-910`, constant at `:55`).
  - `src/adapters/UniswapV4Adapter.sol:316-328`: `unwindExitParams` returns minimums of 0 (`:326-327`).
  - `:333-340`: `spotQuote` reads `slot0` (`:335`); `:621-637`: `_principal` reads `slot0` (`:626`).
  - Entered from `src/core/CoreVault.sol:157-162` and `:204-214`.
- Rule: DEC-067 (hub LP valued at a guarded pool price); DEC-069 and DEC-081 (unwind only what is missing, plus 2%); DEC-097 (the fund bears the margin's market cost, which is not a transfer to a third party); QA3 (OPEN); ARCHITECTURE §4.6 "Unwind sizing"; the ARCHITECTURE §7 invariant that a third party never moves the Share Price.
- What: For each position in unwind order, the hub Spoke Vault:
  - reads the principal composition at the pool's current `slot0` and converts the non-USDC leg with `spotQuote`;
  - asks the adapter for an exit of `min(shortfall, value) / value`, with no minimum amounts, and closes the whole position when its spot value does not exceed the shortfall;
  - swaps the exit's non-USDC principal in the position's own pool, with a minimum of 95% of that same spot.

  Nothing compares the spot with the oracle the Core Vault already reads. The claimant chooses when to claim and can act before and after it in the same transaction:
  1. Push the WETH price down. The position becomes all WETH, and its spot value becomes tiny.
  2. Claim. Any claim whose unwind shortfall exceeds that tiny value makes the vault close the whole position and sell all its WETH at the pushed price, into liquidity the claimant placed there. The 5% floor passes, because it is 95% of the pushed spot.
  3. Take the liquidity back, then swap the pool back.

  The loss is not bounded by the claim. One claim can liquidate every price-dependent position of the unwind order in pools the claimant can move.
  - A smaller move that leaves the exit partial still costs the fund `target × (V(P0) / V(Pm) − 1)`. That is 7.7% of the target when a ±10% position is pushed to its lower edge.
  - V4 flash accounting cannot wrap the claim: the adapter's own `unlock` would revert `AlreadyUnlocked` (`v4-core PoolManager.sol:104`). The push therefore needs outside capital, and an external flash loan provides it.
  - The push is cheap in the real pool the project lists (`docs/INTEGRATIONS.md`). Taking the Arbitrum WETH/USDC 0.05% V4 pool down to 0.1% of its price needs 28.1 WETH, and the round trip back costs about 0.047 WETH, roughly 126 USDC (probe at block 510379789).

  This is distinct from core-a C-01 (Share Price read at spot). Fixing the Core Vault's valuation would not change the unwind, which reads the adapter directly.
- Scenario (fork: real PoolManager, PositionManager, StateView and Permit2, real CoreVault, hub SpokeVault and UniswapV4Adapter; block 510379789; oracle = spot = 2,679.82 USDC per WETH):
  1. Alice deposits 200,000 USDC. An attacker contract deposits 10,000 USDC and opens an Instant Payout Request for 9,900.
  2. The manager allocates 200,000 USDC to the hub Spoke Vault and places it in a USDC-only range order about 1% to 20% below the price.
     - Free Idle is 9,471.85, so the claim needs about 437 USDC of unwind (the 428 shortfall plus 2%).
  3. In one transaction, with 1,000 WETH of flash capital, the attacker:
     - sells WETH until the pool is at 1/1,000 of its price, through the fund's range (which buys about 83.6 WETH with its 200,000 USDC) and through the pool's other liquidity;
     - adds 5e16 of USDC-only liquidity over the 1,000 ticks below the new price;
     - calls `claimPayout("")`;
     - removes its liquidity and swaps the pool back to the starting tick.
  4. Inside the claim, the vault values the fund's position at about 224 USDC and closes it. It sells the WETH into the attacker's liquidity for 224.09 USDC, which is above its own floor, and returns that to Idle. The attacker's claim completes: it burns all its shares for 451.32 USDC.
  5. After the swap back:
     - The pool is at the same tick, and the hub holds no position.
     - Share Assets fell from 209,471.85 to 9,234.23 USDC. Alice's value fell from 199,497.00 to 9,234.23.
     - The attacker holds 999.89 WETH (0.110 WETH, about 295 USDC, went on pool fees) and 200,264.61 USDC. Its profit is **189,994.42 USDC** at the unchanged oracle price, net of the value its own shares lost. The fund lost 200,237.62 USDC.

  Unit PoC (MockV4): a claim needing about 1,580 USDC of unwind makes the vault close a 1,000,000 USDC ±10% position. That position holds 410.12 WETH (1,025,306 USDC at the oracle), and the vault sells it for 820.26 USDC. Share Assets fall from 1,017,446.94 to 18,239.36 USDC.
- PoC:
  - Unit: `test/review/spoke-a/C01_UnwindAtManipulatedSpot.t.sol` (fixture `SpokeAHubFixture.sol`: the real CoreVault, hub SpokeVault and UniswapV4Adapter over MockV4). Command: `forge test --match-path 'test/review/spoke-a/C01_UnwindAtManipulatedSpot.t.sol' -vv`. Result: 1 passed.
  - Fork: `test/review/spoke-a/C01_UnwindAtManipulatedSpotFork.t.sol` (base `SpokeAForkBase.sol`). Command: `ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head-100> forge test --match-path 'test/review/spoke-a/C01_UnwindAtManipulatedSpotFork.t.sol' -vv`. Result: 1 passed at blocks 510376264, 510377542 and 510379789.
  - Pool depth: `test/review/spoke-a/PoolDepthProbeFork.t.sol`.
- Fix: give the unwind an oracle reference and use it for the three decisions that now read spot.
  1. When the pool's `slot0` deviates from the oracle by more than the QA3 band, do not exit a price-dependent position. Stop there and return what has been unwound; the claim becomes partial.
  2. Size the exit and set its minimum amounts from the composition at the oracle price (`getAmountsForLiquidity` at the oracle's sqrt price). `IAdapter.unwindExitParams` should then stop returning minimums of zero.
  3. Floor every unwind swap at the oracle price less `MAX_UNWIND_SLIPPAGE_BPS`, not at `spotQuote`.

  The Core Vault already prices the claim through `IPriceSource` and can pass those prices into `unwindForPayout`. Point 1 or point 3 alone defeats both PoCs.
- Known?: Partly.
  - The QA3 row (`docs/OPEN-QUESTIONS.md:82`) and the NatSpec at `SpokeVault.sol:50-55` say the floor "bounds execution against the price at the time of the swap, not against an oracle", and that the unwind's Market Costs stay the fund's.
  - Neither discloses that the claimant sets that price and can take whole positions whatever the claim's size. That is a transfer, not a market cost.
  - DEC-067 requires a guarded price, and no open question covers its absence here. Grounds (b) and (d). Related to core-a C-01, but that fix does not cover this.

### [H-01] Deprecating the V4 adapter blocks the whole automatic unwind and strands every non-USDC principal on that chain for good
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/adapters/UniswapV4Adapter.sol:523`: `swapExactInput` reverts when deprecated.
  - `src/spoke/SpokeVault.sol:883-887`: the unwind must use the position's own pool when it pairs the token with USDC.
  - `:863-864` and `:905-921`: every exit's non-USDC principal is swapped. `:524-547`: one revert undoes the whole unwind.
  - `:333-345` and `:350-363`: the manager's swaps go through the same adapter.
  - `src/interfaces/IAdapter.sol:151-155`.
- Rule:
  - DEC-056: a quarantined adapter "always allows pulling value back ... the exit path (protocol -> Spoke Vault -> Core Vault -> Shareholder) stays open".
  - DEC-058: a deprecated adapter is "withdraw-only".
  - DEC-021: investor exit is unblockable.
  - OQ-04 stance: swaps are blocked when deprecated.
- What: A deprecated adapter's exit verbs work, but the WETH they return can only become USDC through `swapExactInput` on the same adapter. The factory deploys one V4 adapter per chain, and the unwind insists on the position's own pool.
  - In the automatic unwind, the first V4 position with a WETH leg reverts the whole `unwindForPayout`, including later steps that hold liquid USDC. Every claim is then paid from Free Idle only, and once Free Idle is spent every claim reverts.
  - After the manager closes the positions, the WETH stays in Unallocated Balance for good. No verb can move it:
    - swaps and entries revert;
    - `returnToCoreVault` moves USDC only;
    - on a spoke, `sendToHub` moves only the base token, and `swapCollectedIncome` is blocked too.
  - Share Assets keep counting the WETH at the oracle. Early claimants are paid in full at a price that includes it, and the last holders are left with claims on stranded WETH.
  - Deprecation is irreversible (`AdapterGuard.sol:43-47`). It is the documented response to a buggy adapter, so this happens exactly in the emergency it exists for.
- Scenario (unit PoC):
  1. Alice deposits 1,000,000 USDC and Mallory 50,000. The manager opens a 500,000 USDC WETH/USDC position (first in the unwind order) and puts 500,000 USDC in an exact-value position (second). Free Idle is 47,371.85.
  2. Mallory requests an Instant Payout of 49,000. Control: without deprecation, the claim unwinds about 1,660 USDC and is paid in full.
  3. The guardian deprecates the V4 adapter.
  4. Mallory's claim emits `UnwindForPayoutFailed`:
     - the unwind returns 0, and the 500,000 USDC exact-value position is never reached;
     - she receives 47,370.86 from Idle and 1,629.14 stays outstanding;
     - her next claim reverts.
  5. The manager closes the V4 position: 99.99 WETH (about 250,000 USDC at the oracle) lands in Unallocated Balance. `swapExactInput` reverts `AdapterIsDeprecated`.
  6. Alice asks for her whole value, 997,497.00. She is paid 748,371.75, and 249,125.25 stays outstanding for good. Her next claim reverts, and the WETH never moves.
- PoC: `test/review/spoke-a/H01_DeprecatedAdapterStrandsWeth.t.sol`. Command: `forge test --match-path 'test/review/spoke-a/H01_DeprecatedAdapterStrandsWeth.t.sol' -vv`. Result: 3 passed (control, blocked unwind, stranded WETH).
- Fix:
  - Let an exit swap into the chain's base token run on a deprecated adapter, for example a never-gated `exitSwap`, or no gate when `tokenOut` is the vault's base token.
  - Alternatively, let the unwind and the manager route a token through any non-deprecated Mandate route.
  - Also stop the unwind at a failing step instead of reverting it whole (L-03).
- Known?:
  - The OQ-04 row (`docs/OPEN-QUESTIONS.md:49`) records "blocked when deprecated".
  - `IAdapter.sol:154-155` records Q17-3's recommendation "that the exit swap not go through a deprecated adapter".
  - Nothing discloses the permanent strand or the blocked unwind, which contradicts DEC-056 and DEC-058. Grounds (b) and (c).

### [H-02] Spoke Operating Cash is an unbounded one-way sink: one manager call moves all spoke principal out of Share Assets for good
- Status: CONFIRMED (PoC passes)
- Where:
  - `src/spoke/SpokeVault.sol:368-372`: `setOperatingCashParameters` has no bound.
  - `:988-998`: `_topUpOperatingCash` is the only writer of `operatingCash`, and it only adds. It runs at `:258, 284, 302, 314, 326, 343, 361, 389, 396, 468`.
  - `:965-968`: `_ledgerTotal` counts Operating Cash as ledger, so `sweepExcess` leaves it.
  - No function ever debits `operatingCash`.
- Rule: DEC-096 (floor about 5 USD and top-up about 10 USD on Robinhood; cash distributed to shareholders at close); DEC-013; DEC-100.
- What: This is the spoke twin of core-a H-01.
  - The manager can set any floor and top-up. While Operating Cash is below the floor, every value-moving operation moves `min(topUp, Unallocated base)` out of Share Assets.
  - Nothing spends, returns or sends that cash home.
  - On a spoke the drain needs no manager verb. `handleV3AcrossMessage` runs the top-up (`:468`), and Across passes no depositor (OQ-01), so a stranger's 1-unit fill carrying the fund's public id triggers it.
  - With the parameters at max, every hub-to-spoke send is swallowed on arrival. Position principal can be drained too: close first (exit verbs), then any operation.
- Scenario (unit PoC):
  1. 100,000 USDG arrive from the hub. The manager calls `setOperatingCashParameters(max, max)`.
  2. A stranger's 1-unit arrival moves all of it to Operating Cash (100,000.000001).
  3. The next report shows Unallocated Balance 0. `sweepExcess` returns 0, and `sendToHub` reverts.
  4. Resetting the parameters leaves the cash where it is.
  5. With the parameters back at max, a later 50,000 USDG arrival is swallowed too (150,000.000001).
- PoC: `test/review/spoke-a/H02_SpokeOperatingCashSink.t.sol`. Command: `forge test --match-path 'test/review/spoke-a/H02_SpokeOperatingCashSink.t.sol' -vv`. Result: 1 passed.
- Fix: as for core-a H-01. Cap floor and top-up with constants at the DEC-096 scale. Give Operating Cash an exit: return cash above the floor to Unallocated Balance, or send it home as Principal at close.
- Known?:
  - ARCHITECTURE §4.7 and the spoke REVIEW-LOG item "DEC-096-trigger" say that spending Operating Cash is OPEN.
  - Nothing says the top-up amount is unbounded, or that arrivals and strangers trigger it.
  - Same root cause as core-a H-01 (Core Vault). It is reported here because the brief asked for the spoke side; merge at will.

### [M-01] The Mandate does not bound what a manager moves to a counterparty through prices: every verb accepts minimums of zero and none is compared with an oracle
- Status: CONFIRMED (unit PoC and fork PoC pass)
- Where:
  - `src/spoke/SpokeVault.sol:333-345` and `:779-809`: `swapExactInput` takes any `minAmountOut`; its only check is `amountOut >= minAmountOut` (`:800`).
  - `:350-363`: `swapCollectedIncome`, same.
  - `:249-292` and `:296-316`: open, increase, decrease and close carry the manager's own minimums in `params`.
  - `src/adapters/UniswapV4Adapter.sol:516-543`.
- Rule: DEC-027 and DEC-030 (no loss limit; closed pool list); DEC-002 and DEC-003 ("the Mandate envelope is the main protection"); ARCHITECTURE §6 ("A compromised adapter cannot redirect funds").
- What:
  - The Mandate prevents:
    - calling any adapter, pool or token outside its closed lists (codehashes pinned);
    - sending tokens anywhere else (every output returns to the vault, and bridge recipients are fixed);
    - mixing the principal and income buckets;
    - entering through a paused or deprecated adapter.
  - It does not prevent trading at any price. With an accomplice who moves the pool, or in a thin pool the manager listed, a manager moves any part of the fund's value on a chain to the accomplice in a few transactions: swaps with `minAmountOut = 0`, opens at a moved price, closes with minimums of zero. A compromised manager key (DEC-003) can do the same.
  - Two more channels, reasoned and not PoC'd:
    1. Wash-trading Unallocated Balance through a pool where the fund is the main in-range LP turns principal into income. The adapter counts fee growth as income (FV-16), and the performance fee, up to 25% with no high-water mark (DEC-107), is then charged on it.
    2. H-02 and core-a H-01.
  - There is no loss limit by founder decision (DEC-027, DEC-030). The point is what investors must be told: the closed pool list bounds where the manager trades, not at what price.
- Scenario (fork, real pool, block 510379789):
  1. Alice deposits 200,000 USDC. The manager allocates 100,000 to the hub Spoke Vault.
  2. The accomplice pushes the WETH price up 100× and leaves a WETH-only range just above it.
  3. The manager calls `swapExactInput(adapter, pool, USDC, 100,000 USDC, 0, "")` and gets 0.369 WETH, worth 989.72 USDC at the oracle.
  4. The accomplice takes its range back and swaps the pool back to the same tick.
  5. Share Assets fall from 199,497.00 to 100,486.72 USDC, and the accomplice's profit is 98,911.13 USDC.

  Unit PoC: 500,000 USDC swapped at a moved rate for 2 WETH (Share Assets −495,000 USDC); a close with minimums of zero at a moved spot is also accepted.
- PoC:
  - Unit: `test/review/spoke-a/M01_ManagerSwapExtraction.t.sol`. Result: 2 passed.
  - Fork: `test/review/spoke-a/M01_ManagerSwapExtractionFork.t.sol`. Result: 1 passed (same environment as C-01).
- Fix: disclosure first. In the Mandate and investor documentation, say that the Mandate bounds venues and destinations but not prices, and that a manager or a leaked agent key can transfer value through Mandate pools. For defence in depth without a loss limit:
  - emit the minimum and the oracle and spot prices with every swap, open and exit, so monitors can flag off-market executions (I-02);
  - optionally, add a per-verb oracle deviation band that an API co-signer can tighten (DEC-002).
- Known?: DEC-027 and DEC-030 (no loss limit) and FV-16 (third-party `donate`) are documented. Nothing says that the execution price of a manager's trade is unbounded and is itself a transfer channel. Ground (b).

### [L-01] A complete unwind order does not guarantee an automatic exit: non-USDC Unallocated Balance is never unwound, and about 110 small positions exhaust the unwind's gas
- Status: CONFIRMED (unit PoC; gas measured on the fork)
- Where:
  - `src/spoke/SpokeVault.sol:524-547`: the unwind starts from USDC Unallocated Balance and walks positions only.
  - `:821-837`, `:735-746` (`_positionKeysOf`) and `:727-733` (`_adapterLists` reads every key on each close).
  - There is no cap on open positions.
- Rule: DEC-060 and DEC-065 (after the term, the claimant executes the unwind); DEC-069; DEC-021.
- What:
  1. The unwind swaps only what position exits return. WETH in Unallocated Balance counts in Share Assets, but no claim can reach it.
  2. On the real Arbitrum V4 contracts, a claim that visits 10 small positions costs 3,428,382 gas, and one that visits 40 costs 12,050,855. That is about 287k gas per extra position, so about 110 small positions ahead of the value put the claim over Arbitrum's 32M gas limit.
     - The Core Vault's `try` then pays from Idle only.
     - Each mint costs cents on Arbitrum.
  3. Reasoned from the pool probe: the unwind sells into the pool it has just withdrawn from. For a fund that is most of a thin pool (the real pool holds about 28 WETH of other liquidity), a large claim's sale breaks the 5% floor, the unwind reverts, and the claim is paid from Idle only.
- Scenario (unit PoC):
  1. Alice deposits 1,000,000 USDC and Mallory 50,000. The manager allocates 1,000,000 and swaps it into 400 WETH, which stay in Unallocated Balance.
  2. Mallory asks for her whole value, 49,874.85. The unwind returns 0. She is paid 47,370.86 from Idle, and 2,503.99 stays outstanding; her next claim reverts.
- PoC:
  - `test/review/spoke-a/L01_UnwindCannotReach.t.sol`. Result: 1 passed.
  - Gas: `test/review/spoke-a/L01_UnwindGasPerPositionFork.t.sol`. Result: 2 passed.
- Fix:
  - Unwind non-USDC Unallocated Balance through a Mandate route that pairs it with USDC, before exiting positions.
  - Cap open positions per chain (for example 32).
  - Document that an unwind order covering every pool is not enough.
- Known?: the DEC-069 row (`docs/OPEN-QUESTIONS.md:61`) covers pools outside the order only. Rated Low because a manager can already keep value out of reach that way.

### [L-02] `buildReport` can be read while a hub verb is half done
- Status: PLAUSIBLE (reasoned; unreachable with USDC, WETH and hookless pools)
- Where: `src/spoke/SpokeVault.sol:421-428` (no `_reentrancyGuardEntered()` check). The windows are `:759-773` (the adapter has moved tokens, `_credit` has not run yet) and `:799-805`. The reader is `src/core/CoreVaultLogic.sol:219-232`.
- Rule: best practice (read-only reentrancy); DEC-080; DEC-104.
- What: Between an adapter call and the ledger update, the value an exit returned is in neither the position nor Unallocated Balance.
  - Code that gains control in that window, such as a Mandate token with transfer callbacks, can call `CoreVault.deposit`. The Core Vault's guard is not engaged at that moment, because the manager called the hub vault directly.
  - That deposit is priced off an understated hub value.
  - Only the manager can open such a window. During a claim's unwind the Core Vault's guard blocks it.
- Fix: make `buildReport` and `cumulativeIncome` revert when `_reentrancyGuardEntered()`.
- Known?: the V4 REVIEW-LOG item "Q60 read-only reentrancy window" covers only the adapter's `cumulativeIncome`.

### [L-03] One step that cannot be served rolls back the whole unwind: the claim is paid from Idle only although earlier steps could pay
- Status: CONFIRMED (PoC passes)
- Where: `src/spoke/SpokeVault.sol:524-547` (no per-step handling); `src/core/CoreVault.sol:204-214` (the `catch` pays from Idle).
- Rule: DEC-068 ("pay what is possible and burn only shares paid"); DEC-069 ("an illiquid position is waited on, not skipped").
- What: The code honours DEC-069 by never skipping, but it also discards everything the steps before the failing one produced. Triggers include an Aave reserve at full utilization, a deprecated adapter's swap (H-01), or a hint the claimant got wrong.
- Scenario (unit PoC):
  1. Free Idle is 46,746. The claim needs about 248,000 from the unwind.
  2. The V4 step alone would give about 99,000, but the exact-value step after it cannot pay.
  3. The unwind returns 0, the V4 exit is rolled back, and the claim is paid 46,746 from Idle.
- PoC: `test/review/spoke-a/L03_FailingStepRollsBackTheUnwind.t.sol`. Result: 1 passed. The existing test `test_DEC069_illiquidStepRevertsInsteadOfSkipping` shows the revert itself.
- Fix: stop at the first step that cannot be served and return what the earlier steps produced. Either run each step through a `try` self-call, or check it beforehand (Aave available liquidity, adapter deprecated).
- Known?: `SpokeVault.sol:507-509` says "An illiquid step reverts", but not that the earlier steps' proceeds are lost to that claim. Ground (b).

### [I-01] NatSpec that does not match the code
- `ISpokeVault.ledgerTokens` (`src/interfaces/ISpokeVault.sol:331`) says "Tokens that ever had an Unallocated Balance entry". The code returns the closed list fixed at creation.
- The `ISpokeVault` header (`:21-22`) says every value-moving entry follows checks-effects-interactions. By design the ledger is written after the adapter call returns, under `nonReentrant`.
- `IAdapter.swapExactInput` (`src/interfaces/IAdapter.sol:151-152`) says the swap "serves the exit path (DEC-056)", yet it reverts when deprecated (H-01).

### [I-02] Events do not show the slippage a verb accepted
- `Swapped` and `IncomeSwapped` (`ISpokeVault.sol:49-66`) carry amounts but neither the minimum nor a reference price.
- `UnwoundForPayout` carries only the target and the proceeds, not the floor each swap used.
- `PositionOpened` and `PositionDecreased` omit the minimums.
- A monitor therefore cannot tell C-01 or M-01 from a normal execution, against the founder's rule that every event must let a server monitor route, amounts, slippage, fees and payer.

### [I-03] The Operating Cash top-up runs before a verb's own debit
- On a spoke, `_topUpOperatingCash` runs before the verb debits (`SpokeVault.sol:258`, etc.).
- A verb that uses the whole Unallocated base balance, for example `sendToHub(unallocated)`, then reverts whenever a top-up is due.

### [I-04] A leaver's own unwind realizes income they never receive
- The exits of the leaver's own unwind put their income into the hub vault's collected bucket (`SpokeVault.sol:773`, `:949-956`).
- That income is attributed only at a later `forwardIncomeToCoreVault`, after the leaver is gone.
- This is the leaver side of CS-OQ-1, against DEC-045's "nothing of theirs remains".

### [I-05] Test gaps
- Every unwind unit test uses `MockPositionAdapter`, whose `spotQuote` equals its own swap rate. A spot that differs from the oracle (C-01) is therefore invisible to the suite.
- No test deprecates an adapter and then unwinds or swaps (H-01).
- No test bounds the spoke Operating Cash parameters (H-02).
- The invariant suite checks ledger against balance, not value against the oracle.

## Checks and validations

| Function | Access control | Input validation | Reentrancy guard | CEI order | Event | Gaps |
|---|---|---|---|---|---|---|
| `constructor` | deployer (factory) | Mandate `validate`; chain id; non-zero fund id, Core Vault, SpokePool, excess recipient; hub: base token = USDC, no Wormhole; spoke: Mandate spoke, base token = spoke token, Wormhole and escrow set; adapter code present; codehashes pinned; `poolTokens` per pool (rejects hooked pools); bridge targets pinned | n/a | n/a | none | not checked: `address(this)` against the Mandate spoke vault (known REVIEW-LOG minor), each adapter's `vault()`, hub `coreVault_`. All are factory-guaranteed and fail closed |
| `openPosition` | `onlyManager`, any chain | Mandate adapter plus codehash, Mandate pool, one amount non-zero, `used ≤ sent`, key not yet registered | `nonReentrant` | top-up → debit → push → adapter → credit unused → registry → backed | `PositionOpened` | manager's minimums unbounded (M-01) |
| `increasePosition` | `onlyManager` | registered position, amounts, `used ≤ sent` | `nonReentrant` | as open, plus income credit | `PositionIncreased` | M-01 |
| `decreasePosition` / `closePosition` / `collectIncome` | `onlyManager`; never gated by pause or deprecation | registered position; adapter plus codehash | `nonReentrant` | top-up → adapter → (registry) → credit → backed | `PositionDecreased` / `PositionClosed` / `IncomeCollected` (after the adapter call, before the credit) | minimums of zero accepted (M-01) |
| `swapExactInput` | `onlyManager` | Mandate pool, `tokenIn` in the pool, `amountIn > 0`, `amountOut ≥ minAmountOut` (any value) | `nonReentrant` | top-up → debit → push → swap → credit → backed(tokenOut) | `Swapped` (no minimum) | no price bound (M-01); blocked when deprecated (H-01) |
| `swapCollectedIncome` | `onlyOnSpokeChain`, `onlyManager` | output must be the base token; `amountIn ≤ collected` | `nonReentrant` | as swap, inside the income bucket | `IncomeSwapped` | M-01, H-01 |
| `setOperatingCashParameters` | `onlyOnSpokeChain`, `onlyManager` | **none** | none (no external call) | n/a | `OperatingCashParametersSet` | unbounded sink (H-02) |
| `receiveFromCoreVault` | hub; `msg.sender == coreVault` | `amount > 0`; backed | `nonReentrant` | credit → backed | `ReceivedFromCoreVault` | none |
| `returnToCoreVault` | hub; `onlyManager` | `amount > 0`; ≤ Unallocated | `nonReentrant` | debit → transfer → `returnToIdle` | `ReturnedToCoreVault` (last) | none |
| `forwardIncomeToCoreVault` | hub; anyone | bucket > 0 | `nonReentrant` | zero bucket → transfer → `receiveCollectedIncome` | `IncomeForwardedToCoreVault` (last) | timing is anyone's (CS-OQ-1 stance) |
| `unwindForPayout` | hub; `msg.sender == coreVault` | `target > 0`; hints decoded; routes are Mandate pools | `nonReentrant` | per step: adapter → credit → swap → credit; then debit → transfer → `returnToIdle` | per-step events, then `UnwoundForPayout` | C-01, H-01, L-01, L-03 |
| `sweepExcess` | anyone | excess = balance − ledger | `nonReentrant` | compute → transfer | `ExcessSwept` (none when 0) | none |
| `handleV3AcrossMessage` (ledger part only) | Across SpokePool; spoke; base token | amount > 0, fund id, origin chain | `nonReentrant` | credit → backed → top-up | `TransitArrived`, then top-up events | runs the unbounded top-up (H-02) |
| `sendToHub`, `recognizeRefund`, `report` | spoke (next round) | — | `nonReentrant` | — | — | reviewed here only for the top-up and ledger debits |
| Core Vault side: `allocateToHubSpokeVault` | `onlyManager` | ≤ Free Idle after the top-up | `nonReentrant` | Idle, `lastHubValue` → transfer → `receiveFromCoreVault` | `AllocatedToHubSpokeVault` (before transfer) | — |
| Core Vault side: `returnToIdle` | hub Spoke Vault only; refused inside guarded calls except the claim's unwind | `> 0`; backed by unledgered USDC | callback (by design) | effects only | `ReturnedToIdle` | none |
| Core Vault side: `receiveCollectedIncome` | hub Spoke Vault only | registered token, `> 0`, backed | `nonReentrant` (so never reachable inside a claim) | split → transfers | `CollectedIncomeReceived` | none |

`src/mandate/Mandate.sol` has no state-changing functions (pure validation, hashing and lookups). `src/spoke/SpokeVaultTypes.sol` only declares types, constants, errors and the pure `encodeHints`.

## Checked and found correct
- **An adapter reporting amounts it did not transfer.**
  - *More than transferred:* every credit is followed by `_requireBacked` on the pool tokens (`SpokeVault.sol:268, 290, 774`), on `tokenOut` for swaps (`:808`), or on the base token (`:466, 482`). The credit reverts unless unledgered excess covers the gap, in which case a donation is absorbed into the ledger, bounded by the excess present. The real adapters cannot over-report: V4 takes explicit amounts under `CurrencyNotSettled`, and Aave reverts `UnexpectedWithdrawnAmount`.
  - *Less than transferred:* the rest is unledgered and sweepable to the excess recipient (DEC-101 recovery path).
  - *A different token:* the vault credits only the pool's two tokens. Anything else is unledgered, and a reported token that did not arrive fails `_requireBacked`.
- **Ledger above balance.** Every debit path transfers exactly what it debits: `_sendToAdapter`, the income swap, `returnToCoreVault`, the unwind payment, and `sendToHub` (which checks the exact debit). No path grants an adapter an allowance, so an adapter can never pull more than it was pushed.
- **Value no bucket counts.** Adapter hand-backs, donations, escrow surpluses and Aave foreign aTokens are the only such amounts, all documented and sweepable. No legitimate credit waits outside the ledger:
  - Across calls the handler after transferring;
  - the Core Vault calls `receiveFromCoreVault` after transferring;
  - refunds wait in the escrow, not in the vault.
- **Principal versus income.**
  - The buckets are separate and every debit names its bucket (`sendToHub` kinds, `swapCollectedIncome`).
  - `_credit` splits exactly as the adapter reports (DEC-079).
  - There is no verb that moves income into principal. The only principal-to-income routes are manager trading (M-01) and third-party `donate` (FV-16, known).
- **Closed lists and codehash.** `_positionAdapter` (Mandate list plus codehash) guards every position path:
  - open, increase, exit, swap and income swap;
  - every unwind step, including a hint's route (`:890`), and `_unwindSwap` on an already-checked adapter;
  - `_pool` guards every pool;
  - `SpokeCrossChainLib` checks the codehash when building reports.
- **Position registry.**
  - A V4 decrease cannot remove all liquidity (`InvalidLiquidity`), and a V4 close always drops the key.
  - An Aave decrease keeps the key; an Aave close keeps it only while income is pending, and `_adapterLists` follows that.
  - Swap-and-pop keeps the slots consistent, and the unwind iterates a snapshot of keys (existing `test_DEC069_unwindFollowsTheRegistryOrderAfterASwapAndPopClose`).
- **Pause and deprecation.**
  - Exit verbs never read the flags, in either adapter.
  - Entries revert when paused or deprecated.
  - Swaps revert only when deprecated; the consequence is H-01.
  - Pausing does not affect the unwind.
- **Hints.** A hint can raise a swap minimum, add a price limit or deadline, or name a Mandate route for a token the position's pool does not pair with USDC. It cannot size an exit or reroute a USDC-paired token, and a bad hint only fails the claimant's own unwind.
- **Hub legs.**
  - Both sides check the caller and the backing, and the hub vault debits before it transfers.
  - `returnToIdle` is refused inside guarded Core Vault calls except the claim's unwind.
  - `receiveCollectedIncome` cannot run inside a claim.
  - The unwind returns at most the target to Idle and leaves any excess in Unallocated Balance.
  - A stranger can trigger only the forward and the sweep on the hub vault.
- **The permissionless forward.** An entrant sharing income collected into the hub bucket before their deposit is the CS-OQ-1 stance. A flash deposit, forward and Instant exit costs 2% plus 2 × 0.25% (DEC-102, DEC-106), so it pays only when unforwarded net income exceeds roughly 5% of the fund.
- **Operating Cash top-up.** It never reverts and never blocks an exit (DEC-056), moving at most the Unallocated base balance. The bound is the only problem (H-02).
- **Exact-value versus price-dependent positions.** The vault ignores `isExactValue()` and follows the Mandate order, as `ISpokeVault` and ARCHITECTURE §4.6 document.
- **Arithmetic.**
  - Unwind exits round up (V4 liquidity ceil, Aave principal ceil), so an exit is never smaller than the share asked.
  - The floor rounds down.
  - There are no `unchecked` blocks in the vault, no divisions by zero (a zero value is skipped before `unwindExitParams`), and no truncating casts on value paths.
- **`buildReport` assembly.** It turns `abi.encode(VERSION, report)` into `abi.encode(report)` correctly: word 1 (offset `0x40`) is rewritten to `0x20` and the length is reduced by 32. The function has no modifier and no code after the `return`.
- **Static-analysis leads in scope, dismissed:**
  - *Aderyn H-2 "locks Ether":* `report()` forwards all `msg.value` to the Wormhole Core, which requires `msg.value == messageFee`, and there is no `receive` or `fallback`.
  - *Aderyn H-4 "storage array edited with memory":* `_unwindStep` only reads the step.
  - *Aderyn H-6 "Yul return":* intentional, see above.
  - *Aderyn L-12 unchecked returns* (`:890`, `:911`): `_positionAdapter` is called for its revert, and the `_swap` result is credited inside `_swap`.
  - *Slither reentrancy-no-eth (8):* every listed entry is `nonReentrant`, and the "cross-function" targets are constructor-only helpers. The residual exposure is the view (L-02).
  - *Slither uninitialized-local* (`visited`, `swaps`, `seen`): zero defaults by design.
  - *Slither unused-return* in the constructor: the spoke index is unused on purpose.
  - *Slither calls-loop (12):* bounded by the Mandate lists, except the manager's position count (L-01).
  - *Slither shadowing-local* (`report()` return name): harmless.
- **Known and still open, not re-reported.** The constructor does not assert `address(this)` equals the Mandate's spoke vault (REVIEW-LOG spoke item "SpokeVault.sol:143"). The factory guarantees it through CREATE3 predictions (FF-OQ-4).

## Not covered
- The cross-chain half (`sendToHub`, `recognizeRefund`, `report`, `buildReport`'s cross-chain fields, `SpokeCrossChainLib`, `ReportCodec`, the receiver, the price source) and the adapters' internals. Both belong to the next round; I read them only where the vault depends on them.
- The spoke-side runs of H-01 and H-02 on a Robinhood fork. The mechanism is the same code; only the unit test was run.
- A real flash-loan provider in the fork PoCs. The WETH is dealt to the attacker, and the tests check it is intact at the end.
- The wash-trading income channel in M-01 (reasoned, no PoC) and the "sells into the pool it just left" case of L-01 (reasoned from the probe).
- Fuzzing or invariant runs of the ledger beyond the existing suite.
