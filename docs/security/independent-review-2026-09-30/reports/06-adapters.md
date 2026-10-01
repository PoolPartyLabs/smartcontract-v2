# Adapters (Uniswap V4, Aave V3, Across, AdapterGuard) review

Reviewer slug `adapters`, repository `PoolPartyLabs/smartcontract-v2` at `e5c778a`, working copy `scratchpad/smartcontract-v2`.
PoCs are in `test/review/adapters/`.

- Unit, no network: `forge test --match-path 'test/review/adapters/*' --no-match-path '*Fork.t.sol' -vv`. Result: 4 passed, 0 failed.
- Fork, real Arbitrum One contracts: `ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 100> forge test --match-path 'test/review/adapters/*Fork.t.sol' -vv`. Result: 5 passed, 0 failed at block 510393797, which is the block the numbers below come from. Also passed at 510392380 and 510393499.

## Summary

Against the real protocols, the adapters do what they claim:
- the V4 action plans encode what the live PositionManager decodes;
- the V4 principal/income split replicates the PoolManager's own formulas to the wei;
- allowances are exact and cleared, and the swap callback is authenticated;
- the Aave ledger follows the live pool's rounding;
- the Across call matches the live `depositV3`.

The weak points are economic, or sit at the protocol edges:
- The manager can turn principal into income that pays the performance fee by trading through the fund's own V4 range. A Mandate pool with up to a 100% LP fee does it in one swap (M-01).
- The Aave income step can revert a whole exit when foreign aTokens are present (L-01), and pays nothing whenever pending income exceeds the virtual liquidity (L-02).
- A non-USDC Aave reserve blocks the unwind (L-03).
- A later cut of Across's deadline buffer kills every route for good (L-04).
- One guardian key can deprecate every fund's V4 adapter (L-05).

Counts: Critical 0, High 0, Medium 1, Low 5, Info 7.

## Findings

### [M-01] The manager can turn the fund's principal into performance-fee-bearing income by trading through the fund's own V4 range, and a Mandate pool with a very high LP fee does it in one swap
- Status: CONFIRMED (two fork PoCs pass on the real Arbitrum contracts)
- Where:
  - `src/adapters/UniswapV4Adapter.sol:598-615` (`_uncollectedIncome`): all fee growth inside the fund's range is income.
  - `src/adapters/UniswapV4Adapter.sol:495-510` (`collectIncome`) and `:660-663` (`_recordIncome`) realize that income.
  - `src/adapters/UniswapV4Adapter.sol:516-543` (`swapExactInput`): any registered hookless pool with any `minAmountOut`, including a pool where the fund holds the in-range liquidity.
  - `src/adapters/UniswapV4Adapter.sol:228-242` (constructor): each `PoolKey` is checked only for `tickSpacing > 0`, a non-native `currency0` and duplicates. Its static LP fee is never bounded.
  - `src/factory/FundFactory.sol:386-395`: only matches each key's id with the Mandate.
  - `src/spoke/SpokeVault.sol:333-345` (the manager's swap), `:320-328` (collect) and `:496-503` (anyone forwards).
  - `src/core/CoreVaultLogic.sol:386-397` (`_collectIncome`): takes `performanceFeeBps` of every unit of collected income. The protocol slice goes to the Protocol Recipient and the rest to the `ManagerFeeVault`.
- Rule: DEC-107 (performance fee on income, no high-water mark), DEC-079 (income as the protocol accounts it), DEC-030 ("the Manager cannot create a pool and operate in it"), DEC-014 (principal and income belong to different sets of holders), FV-16 (open).
- What: The loop has four steps:
  1. The fund's swaps pay the LP fee to whoever holds liquidity in range.
  2. When that liquidity is the fund's own range, the fee comes back to the fund as fee growth.
  3. The adapter reports that fee growth as income, which is correct by the pool's accounting.
  4. Collecting and forwarding it moves principal out of Share Assets into Attributed Income, and `_collectIncome` charges the performance fee on it.

  Two things are missing:
  - Nothing nets the fees the fund paid against the income it earned.
  - Nothing bounds a Mandate pool's fee tier. V4 accepts any static LP fee up to 1,000,000 pips (100%) for a hookless pool (`lib/v4-core/src/libraries/LPFeeLibrary.sol:25,37-45`). An exact-input swap at 100% returns nothing and turns the whole input into fee growth (`lib/v4-core/src/libraries/SwapMath.sol:65-74`).

  DEC-030's rule that the manager cannot create a pool and operate in it is not checkable on-chain.

  Who gains and who loses (π = performance fee, σ = protocol slice, s = the fund's share of in-range liquidity):
  - **Manager, trading the fund's own Unallocated Balance:**
    - The manager gains π(1−σ) × income, and the protocol gains πσ × income.
    - Holders lose the fees paid minus (1−π) × income. With s ≈ 1 and no Uniswap protocol fee, that is π × income, exactly what the manager and the protocol take.
    - On the live 0.05% pool, which also charges a 125-pip Uniswap protocol fee, at π = 20% and σ = 50%: per 1,000,000 USDC of wash volume the manager gains 48.0 USDC, the protocol 48.0, and holders lose 243.6.
    - In a Mandate pool with a 100% LP fee at π = 25%: the manager takes 12.5% of whatever principal is piped through and the protocol 12.5%. Holders keep 75%, but as income instead of principal.
    - There is no accomplice and no outside capital, unlike spoke-a M-01, and the trades look like active management.
    - The spoke works the same way: collect, `swapCollectedIncome`, `sendToHub(Income)`.
  - **Third party doing the same:** it pays every fee and receives nothing. The fund receives s × LP fees as a gift, on which the manager and the protocol are paid a fee. No stranger profits, so this is the FV-16 donation case.
- Scenario (fork, block 510393797):
  1. Live WETH/USDC 0.05% pool, performance fee 20%, slice 50%. Alice deposits 1,000,000 USDC. The manager allocates 600,000 and places 400,000 in a 200-tick range just below the price.
  2. The market sells WETH into the range down to its middle. That legitimate income is collected and forwarded first.
  3. The manager runs 60 round trips of 50,000 USDC → WETH → USDC through `hubVault.swapExactInput(..., minAmountOut = 0)`: 6,000,000 USDC of volume, and nobody else trades.
  4. `collectIncome` returns 0.539137 WETH + 1,433.80 USDC, worth 2,880.35 USDC at the oracle. That is 96.0% of the LP fees on the volume, and the pool tick ends where it started. Anyone forwards WETH and USDC.
  5. The `ManagerFeeVault` receives 288.04 USDC and the Protocol Recipient 288.04 USDC. Share Assets fall from 998,645.69 to 994,879.91. Holders' Share Assets plus Attributed Income fall by 1,461.50. The rest went to Uniswap's protocol fee and to the other LPs.
  6. One-shot variant, same block, performance fee 25% (the Mandate cap): the Mandate lists a hookless WETH/USDC pool with a 1,000,000-pip fee, initialized by anyone. The manager opens a tiny in-range position (0.34 WETH + 1,000 USDC) and swaps 100,000 USDC of Unallocated Balance through it with `minAmountOut = 0`. The output is 0.
  7. `collectIncome` reports 99,999.999999 USDC of income and anyone forwards it. Share Assets fall by 100,000 and Attributed Income rises by 75,000. The Protocol Recipient gets 12,499.999999, and the manager withdraws 12,500.00 from its `ManagerFeeVault`.
- PoC:
  - Files: `test/review/adapters/WashTradeIncomeFork.t.sol` (on `test/review/spoke-a/SpokeAForkBase.sol`) and `test/review/adapters/HighFeePoolIncomeFork.t.sol` (on `test/review/adapters/AdaptersForkBase.sol`).
  - Command: `ARBITRUM_RPC_URL=https://arb1.arbitrum.io/rpc ARBITRUM_FORK_BLOCK=<head - 100> forge test --match-path 'test/review/adapters/*IncomeFork.t.sol' -vv`.
  - Result: 2 passed. The tests assert the manager's and the protocol's cut of income the fund generated itself, and that holders lost more than that cut.
- Fix:
  1. Bound the static LP fee of every Mandate V4 pool at creation, for example `fee <= 10_000` pips (1%), in the adapter constructor or in `_deployUniswapV4Adapter`. This closes the one-shot variant.
  2. Stop charging the fee on the fund's own fees:
     - `swapExactInput` knows `amountIn` and the pool's fee, so the adapter can keep a monotonic `swapFeesPaid(token)`.
     - The hub vault forwards it with the collected income, and `_collectIncome` charges π only on `max(0, income − fees paid since the last collection)` per token.
     - Net spoke income the same way before sending it home.
     - Otherwise, have the founder extend FV-16 from `donate` to the manager's own swaps and disclose it in the Mandate documentation.
- Known?: FV-16 (`docs/DECISIONS.md` "Still open"; REVIEW-LOG V4 section "FV-16 (V4 donate)") covers a third party's `donate`. Earlier rounds only mention the wash-trading route: spoke-a M-01 (report 04) as "reasoned, not PoC'd", and report 03 lists it as not covered. Nothing mentions the unbounded fee tier, or that DEC-030's creation rule is not checked. Grounds (b) and (d).
- Severity: Medium, because spoke-a M-01 already lets a manager with an accomplice extract more. The coordinator may weigh the one-shot variant at High, since it needs no accomplice and takes 12.5% of any amount in one call.

### [L-01] With foreign aTokens in the Aave adapter, the income step of a fallback full exit reverts the whole exit
- Status: CONFIRMED (unit PoC and fork PoC on the live pool)
- Where:
  - `src/adapters/AaveV3Adapter.sol:399-416`: the one-shot `withdraw(type(uint256).max)`, whose failure is caught.
  - `src/adapters/AaveV3Adapter.sol:421-429`: the fallback withdraws the principal, then `_takeIncome`.
  - `src/adapters/AaveV3Adapter.sol:444-445`: the income take is bounded by the income and the aToken's cash, not by what the ledger still holds.
  - `src/adapters/AaveV3Adapter.sol:494`: `LedgerUnderflow`, raised outside the `try` at `:482-487`.
- Rule: DEC-056 and DEC-021 (exits stay open); `IAdapter.closePosition` ("The whole principal always leaves"); the adapter NatSpec at `:27-28` ("Income never blocks a principal exit").
- What:
  - After a whole-principal withdrawal, which burns `ceil(P·RAY/i)` scaled units, burning the whole measured income needs one scaled unit more than the ledger keeps. That happens in nearly every case: in a search at P = 1,000 USDC over index values from 1.00001 to 1.2, 19,998 of 19,999 hit.
  - With no foreign aTokens, Aave refuses that withdrawal on the user balance, and the `try` pays 0.
  - With any foreign aTokens in the adapter (DEC-080: never reported), Aave accepts the withdrawal. The adapter then reverts `LedgerUnderflow`, and the whole close reverts, principal included.
  - The fallback runs whenever the one-shot maximum withdrawal fails. Foreign aTokens themselves cause that failure whenever the virtual liquidity lies between the fund's value and the adapter's whole aToken balance.
- Scenario:
  1. Unit test with live rounding: 1,000 USDC supplied at index 1.0, index now 1.1, so 100 USDC of pending income. The reserve holds 1,110 USDC of liquidity. The control close succeeds.
  2. A stranger supplies 50 USDC on the adapter's behalf. The same close now reverts `LedgerUnderflow(90,909,091, 90,909,090)`, and so does `decreasePosition(1,000 USDC)`.
  3. Fork, live pool, block 510393797: 12 principal sizes around 1,000,000 USDC, 30 days of interest, and a stranger supplies 1,000 USDC on the adapter's behalf. Borrowers leave virtual liquidity at the fund's value plus 500 USDC.
  4. 6 of the 12 closes revert `LedgerUnderflow` (7 and 9 of 12 at the other two blocks).
- Impact: a donor who pays the window's width can block the fund's full Aave exit, and the automatic unwind's close, while utilization sits in that window. The donor can wait for such utilization or create it by borrowing. The manager can still take all but 2 units with `decreasePosition(principal − 2)` and `collectIncome`. This is paid griefing only.
- PoC:
  - `test/review/adapters/AaveIncomeBurnUnderflow.t.sol` (2 passed).
  - `test/review/adapters/AaveLiveReserveFork.t.sol::test_foreignATokensBlockTheCloseOnTheLivePool` (passed).
- Fix: cap the income take at the ledger's remaining value, `take = min(income, _value(l, index), liquidity)`. Because `ceil(floor(S·i/R)·R/i) <= S`, the burn can then never exceed the ledger.
- Known?: AAVE-4 (REVIEW-LOG aave section) recorded that donated aTokens could make the old one-shot close revert, and the final verification added the `try` and fallback. The fallback's income step brings a revert back in that same window. It is not listed.

### [L-02] The Aave income bound uses the aToken's cash, not the liquidity `withdraw` checks, so "best effort" income pays 0 during a liquidity crunch
- Status: CONFIRMED (fork)
- Where: `src/adapters/AaveV3Adapter.sol:444` (`min(income, IERC20(asset).balanceOf(aToken))`) and `:20-28` (NatSpec); `src/interfaces/external/IAaveV3Pool.sol`, which has no `getVirtualUnderlyingBalance`.
- Rule: DEC-068 and the final-verification stance ("pending income is withdrawn best effort up to the reserve's available liquidity", `docs/OPEN-QUESTIONS.md` section "Handled in the final verification", Aave row).
- What:
  - At revision 11, `withdraw` is capped by the reserve's virtual balance.
  - The aToken's USDC `balanceOf` also counts stray transfers. On aArbUSDCn it holds 40.946615 USDC more than the virtual balance (measured).
  - Whenever pending income exceeds the virtual liquidity, the adapter asks for more than Aave will pay, the `try` catches the revert, and 0 is paid instead of the whole virtual liquidity.
- Scenario (fork, block 510393797):
  1. 1,000,000 USDC supplied for 60 days: 4,839.65 USDC of pending income.
  2. Borrowers leave 2,419.82 USDC of virtual liquidity.
  3. `collectIncome` pays 0.
  4. A `withdraw` of 2,419.82 USDC for the adapter then succeeds.
- PoC: `test/review/adapters/AaveLiveReserveFork.t.sol::test_incomeBoundUsesTheATokenBalanceNotTheVirtualLiquidity` (passed).
- Fix: bound the take by `IPool.getVirtualUnderlyingBalance(asset)`, which is live at revision 11 (add it to the vendored interface), and by the ledger's value (L-01).
- Known?: no. The existing `test_DEC068_fork_pendingIncomeAboveReserveLiquidityNeverBlocksPrincipal` passes with 0 paid, because it asserts only an upper bound. Income is delayed, not lost.

### [L-03] The Aave adapter accepts a non-USDC reserve, declares it exact-value, and every unwind that reaches it reverts
- Status: CONFIRMED (unit PoC)
- Where:
  - `src/adapters/AaveV3Adapter.sol:123-138`: any listed reserve is accepted.
  - `src/adapters/AaveV3Adapter.sol:146-148`: `isExactValue()` always returns true.
  - `src/adapters/AaveV3Adapter.sol:152-154`: `poolTokens` returns `(asset, address(0))`.
  - `src/factory/FundFactory.sol:414-428`: the reserves come from the Mandate's pool keys, with no rule on the asset.
  - `src/spoke/SpokeVault.sol:871-895`: `_unwindRoute` calls `_otherToken` at `:883`, and `_otherToken` (`:811-817`) reverts on a single-token pool before the hint route is read.
- Rule: DEC-028 (ARCHITECTURE §1: the adapter "Supplies USDC"), DEC-059 (aUSDC is exact value), DEC-069, DEC-021.
- What: If a Mandate puts an Aave WETH position in its unwind order, every unwind that reaches that step reverts `UnexpectedToken(WETH)`. This happens even when the claimant's hint names a valid Mandate WETH/USDC route. The claim is then paid from Free Idle only, and spoke-a L-03 rolls back the earlier steps too. `isExactValue()` also declares aWETH exact-value, although no vault reads it today.
- Scenario (unit, real `AaveV3Adapter` over the mock pool with a WETH reserve, real hub `SpokeVault`):
  1. The manager buys 0.5 WETH through the Mandate route and supplies it to Aave.
  2. `unwindForPayout(500 USDC)` reverts `UnexpectedToken(WETH)`, both without a hint and with a valid route hint.
- PoC: `test/review/adapters/AaveNonUsdcReserveUnwind.t.sol` (1 passed).
- Fix: Either reject any reserve other than the Mandate's USDC (the MVP scope) in the adapter constructor or the factory, or:
  - have `_unwindRoute` treat a single-token non-USDC pool like a pair without USDC and require a hint route;
  - make exact value a per-asset property.
- Known?: no. It is a creation-time Mandate choice visible to investors, hence Low.

### [L-04] If Across later cuts `fillDeadlineBuffer`, every fund's route stops working in both directions, for good
- Status: CONFIRMED (unit PoC on the adapter suite's own SpokePool stand-in)
- Where: `src/adapters/AcrossBridgeAdapter.sol:36` (constant), `:59-66` (the buffer is checked once, at construction), `:104`.
- Rule: DEC-066 (6 h as an adapter constant), DEC-058 (no new code for a live fund), DEC-021 and DEC-056 (the exit path stays open).
- What:
  - The adapter always encodes `now + 21,600`.
  - The live SpokePools are UUPS proxies. If Across lowers the buffer, even by one second, every `depositV3` that any fund's adapter builds reverts `InvalidFillDeadline`.
  - A live fund cannot adopt another adapter, and a Mandate fallback would be another instance of the same code.
  - Spoke value then has no route home.
- Scenario:
  1. A send works at a 21,600 s buffer.
  2. The buffer is set to 21,599 s.
  3. Sends revert on each of the following days.
- PoC: `test/review/adapters/AcrossBufferReduction.t.sol` (1 passed).
- Fix: encode `min(FILL_DEADLINE_SECONDS, spokePool.fillDeadlineBuffer())` at build time; both vaults already store `call.fillDeadline`. Also record the dependency in `docs/INTEGRATIONS.md`.
- Known?:
  - The adapter NatSpec at `:56-58` and the REVIEW-LOG across minor on `AcrossBridgeAdapter.sol:62` say that sends would then revert atomically.
  - Neither says that, with immutable adapters, the route is gone for good and spoke value is stranded. Ground (b).

### [L-05] One immutable guardian per factory can deprecate every fund's V4 adapter, irreversibly
- Status: PLAUSIBLE. The wiring is read from code; the effect of a deprecation is spoke-a H-01's PoC.
- Where: `src/factory/FundFactory.sol:60, :110, :367, :402, :427`; `src/adapters/AdapterGuard.sol:13, :41-47`; `src/adapters/UniswapV4Adapter.sol:523`.
- Rule: DEC-021 (Pool Party acts only on shared infrastructure; investor exit is unblockable), DEC-058; `docs/OPEN-QUESTIONS.md` rulings row "Pause / deprecate holder (Q17-2b): Immutable guardian address is fine for now".
- What:
  - Every adapter of every fund a factory creates gets the same immutable `_guardian`, and `deprecate()` is irreversible.
  - Per spoke-a H-01, a deprecated V4 adapter blocks swaps, and with them the automatic unwind, which strands non-USDC principal.
  - So one lost or compromised key disables every fund's automatic exit at once. There is no timelock, no rotation and no per-fund scope.
- Fix:
  - Fix spoke-a H-01 so that exit swaps are never gated. That removes the harm.
  - Also put the guardian behind a rotatable, two-step holder with a delay on `deprecate`.
- Known?: the ruling accepts an immutable guardian. Its reach across all funds, combined with H-01, is not disclosed. Ground (b).

### [I-01] Input for the C-01 fix: what the V4 adapter must expose for an oracle-guarded unwind, measured
- Status: measurement (a probe copy compiled with the project settings)
- Where: `src/adapters/UniswapV4Adapter.sol:316-340` (`unwindExitParams`, `spotQuote`) and `:621-637` (`_principal`, which reads `slot0`).
- What:
  - **Deviation guard and oracle floor: no adapter change.** `spotQuote(pool, token, 1 unit)` already gives the pool price, and the vault can compare it with the oracle price the Core Vault reads. The vault can also compute the swap floor at the oracle price itself.
  - **Sizing an exit, and setting its minimums at the oracle price: one view.** `unwindExitParamsAt(positionKey, num, den, sqrtPriceX96, toleranceBps)` computes the principal at a given sqrt price. It uses `_principal`'s `SqrtPriceMath` branches, compares prices instead of ticks, and returns non-zero minimums.
  - **Measured cost:**

    | Variant | Runtime size | Change |
    |---|---|---|
    | Current `UniswapV4Adapter` | 17,854 B | — |
    | Plus `unwindExitParamsAt` and its helper | 18,765 B | +911 B |
    | Also plus `principalAt(positionKey, sqrtPriceX96)`, `spotSqrtPriceX96(pool)` and `sqrtPriceX96FromPrice(price1e18)` | 19,726 B | +1,872 B |

    Both variants stay under the 24,576 B limit.
  - **Aave adapter: nothing.** Its value is exact.
  - **The binding constraint is the Spoke Vault**, with a 932 B margin (baseline).
- PoC: `test/review/adapters/OracleAwareV4AdapterProbe.sol` (the probe itself). Sizes from `forge inspect <path>:<contract> deployedBytecode`.
- Known?: requested by the coordinator.

### [I-02] The V4 adapter NatSpec overstates what `CurrencyNotSettled` proves
- Where: `src/adapters/UniswapV4Adapter.sol:40-46`.
- What: The end-of-unlock check proves only that each currency's TAKE equals principal plus income, not how that sum splits between the two. The split is right because the adapter replicates the pool's own formulas (see the checked list), but a drift in those formulas would pass unnoticed.
- Fix: reword the NatSpec, and add a fork test that compares the adapter's income with the `feesAccrued` the PoolManager returns for the same change.

### [I-03] Adapter events cannot show slippage, price or fee
- Where: `src/interfaces/IAdapter.sol:59-80`; `src/adapters/UniswapV4Adapter.sol:381, 418, 458, 489, 509, 542`; `src/adapters/AaveV3Adapter.sol:181, 207, 235, 262-265, 282`.
- What:
  - `Swapped` has no minimum, no price limit, no execution price and no fee tier.
  - `PositionOpened`, `PositionIncreased` and `PositionDecreased` have no ticks, no liquidity and no minimums.
  - So a monitor cannot flag M-01 or spoke-a M-01, against the founder's rule that every operation lets a server see route, amounts, slippage and fees. This is spoke-a I-02 at the adapter layer.
- Fix:
  - Add `minAmountOut`, the sqrt price before and after the swap, and the fee to `Swapped`.
  - Add ticks, liquidity and minimums to the position events.

### [I-04] The V4 position key is read before external token calls
- Where: `src/adapters/UniswapV4Adapter.sol:366`, then `:379` → `:681-685`.
- What: `positionKey = nextTokenId()` is read before `forceApprove` and `permit2.approve`. A Mandate pool token with approve hooks that minted a V4 position in between would make the recorded key name another NFT. The fund's own NFT would then go untracked, and every later verb on the recorded key would revert. USDC, WETH and USDG have no such hooks.
- Fix: read `nextTokenId()` after `_grant`, or check `ownerOf(tokenId) == address(this)` after the plan.

### [I-05] Protocol incentives credited to an adapter address have no claim path
- Where: `src/adapters/AaveV3Adapter.sol` (no rewards call) and `src/adapters/UniswapV4Adapter.sol` (the adapter owns the NFTs).
- What:
  - Aave's RewardsController, and Merkl campaigns, credit the aToken holder or the NFT owner, which here is the immutable adapter.
  - The adapter cannot claim, and a later Collector (DEC-053) cannot claim on its behalf either.
  - Measured: the only ARB stream on aArbUSDCn ended at timestamp 1719151200 (2024-06-23), so nothing is lost today.
  - DEC-078 expects incentives to be collected.
  - The Merkl side is reasoned, not verified on-chain (PLAUSIBLE).
- Fix: either add a guarded claim passthrough that pays the vault, or state that MVP positions forgo incentives.

### [I-06] Docs and interfaces that do not match the code
- `docs/INTEGRATIONS.md:79-82` lists `SETTLE_PAIR` and `TAKE_PAIR`. The adapter uses `SETTLE` and `TAKE` with explicit amounts and never an open delta.
- `src/interfaces/IAdapter.sol:100-102` says "Aave V3 aUSDC supply: true", but the adapter returns true for any reserve (L-03).
- DEC-058 says deprecation is "global, immediate". The flag lives on each adapter instance (one per fund per chain), so deprecating a buggy implementation takes one guardian transaction per fund and per chain (Q17-2b stance L1).
- `IAaveV3Pool` lacks `getVirtualUnderlyingBalance`, the value that actually bounds `withdraw` at revision 11 (L-02).

### [I-07] Token behaviours the adapters assume away
- Where: `src/adapters/UniswapV4Adapter.sol:454-455, 485-486` (the TAKE amount is reported as the amount received); `src/spoke/SpokeVault.sol:972-977` (`_requireBacked`).
- What: The adapters report what they asked the protocol to move. That assumes plain ERC-20s:
  - **Fee-on-transfer, or a fee switched on after entry:** the vault receives less than reported, and `_requireBacked` reverts every exit of that position. The position is locked unless unrelated excess sits in the vault.
  - **Positive rebases:** they are unledgered and get swept to the Protocol Recipient.
  - **Issuer pause or freeze (USDC, USDG):** blocks exits while it lasts.

  The manager picks the pool tokens and nothing checks them. USDC and WETH are plain transfer-wise; I did not audit USDG's token code, but the existing Robinhood V4 fork lifecycle, which settles and takes exact USDG amounts, passes (baseline).
- Fix: either allowlist plain tokens in Mandate validation, or credit `min(reported, received)` on exits and emit the difference.

## Checks and validations

| Function | Access control | Input validation | Reentrancy guard | CEI order | Event | Gaps |
|---|---|---|---|---|---|---|
| `UniswapV4Adapter` constructor | deployer (factory) | non-zero vault, PoolManager, PositionManager, StateView, Permit2; per key `tickSpacing > 0`, non-native `currency0`, no duplicate | n/a | n/a | `PoolRegistered` per key | **LP fee never bounded (M-01)**; hooked keys registered, never operable (OQ-12, by design) |
| `openPosition` | `onlyVault`; `_requireEntryAllowed` (deprecated, then paused) | operable pool; liquidity > 0; `used >= min`; `used <= max` and deadline checked by the PositionManager | `nonReentrant` | position stored before the plan; exact Permit2 grant, plan, revoke, hand-back | `PositionOpened` (last) | key read before token calls (I-04); event without ticks, liquidity or minimums (I-03) |
| `increasePosition` | `onlyVault`; entry gate | open key; liquidity > 0; minimums; deadline | `nonReentrant` | `realizedIncome` booked before the plan | `PositionIncreased` (last) | none |
| `decreasePosition` | `onlyVault`; flags never read (DEC-056) | open key; `0 < liquidity < position`; principal minimums; deadline | `nonReentrant` | income booked before the plan; explicit TAKEs to the vault | `PositionDecreased` (last) | minimums unbounded (known) |
| `closePosition` | `onlyVault`; flags never read | open key; minimums; deadline | `nonReentrant` | key deleted and income booked before the plan | `PositionClosed` (last) | none |
| `collectIncome` | `onlyVault`; flags never read | open key; no call when income is 0 | `nonReentrant` | income booked before the plan | `IncomeCollected` (last, also for 0) | none |
| `swapExactInput` | `onlyVault`; reverts when deprecated, not when paused | operable pool; token in pool; `amountIn > 0`; deadline; price limit; `amountOut >= minAmountOut` (any value); `PartialSwap` | `nonReentrant` | unlock, then the callback settles exactly and takes to the vault; surplus hand-back | `Swapped` (last) | blocked when deprecated (spoke-a H-01); any fee tier (M-01); no minimum or price in the event (I-03) |
| `unlockCallback` | `msg.sender == poolManager`, reachable only inside the adapter's own `unlock` | the adapter's own encoded data | covered by the outer guard | swap, sync, transfer, `settle` (checked), take | none (the outer `Swapped` follows) | none |
| `AaveV3Adapter` constructor | deployer (factory) | non-zero vault and pool; non-empty list; non-zero, unique assets; aToken listed | n/a | reads `getReserveData`, then writes | none | **any reserve, always exact-value (L-03)** |
| `openPosition` | `onlyVault`; entry gate | listed asset; not open; explicit non-zero amount `<=` transferred | `nonReentrant` | `open` and index set before the supply; ledger written from the measured scaled delta after it (inherent) | `PositionOpened` (last) | none |
| `increasePosition` | `onlyVault`; entry gate | open key; explicit amount | `nonReentrant` | supply, then income best effort | `PositionIncreased` (last) | L-02 |
| `decreasePosition` | `onlyVault`; flags never read | open key; `0 < amount <= principal` | `nonReentrant` | principal first, then income best effort | `PositionDecreased` (last) | L-01, L-02 |
| `closePosition` | `onlyVault`; flags never read | open key (params ignored) | `nonReentrant` | `open` cleared before Aave is called, restored only while income stays pending | `PositionClosed` or `PositionDecreased` (last) | L-01, L-02 |
| `collectIncome` | `onlyVault`; flags never read | open key; no call when income is 0 | `nonReentrant` | index, then best-effort withdrawal | `IncomeCollected` (last, also for 0) | L-02 |
| `swapExactInput` (Aave) | none (pure) | always `UnsupportedOperation` | n/a | n/a | n/a | none |
| `AcrossBridgeAdapter` constructor | deployer (factory) | non-zero vault and SpokePool; `fillDeadlineBuffer >= 21,600` at creation | n/a | n/a | none | buffer checked once (L-04) |
| `buildSend` (view) | anyone (moves nothing) | non-zero amounts, `output <= input` in raw units; non-zero depositor; recipient non-zero and at most 160 bits | n/a | n/a | none (view) | exclusivity passed through (known, report 03 M-01) |
| `AdapterGuard.setPaused` | `onlyGuardian` | none | n/a | n/a | `PausedSet` | one factory-wide immutable guardian (L-05) |
| `AdapterGuard.deprecate` | `onlyGuardian` | idempotent | n/a | n/a | `AdapterDeprecated` (first call only; a second call is a silent no-op) | L-05 |

## Checked and found correct

1. **V4 action plans against the live PositionManager.**
   - Action constants 0x00-0x03, 0x0b and 0x0e match.
   - Encodings match `CalldataDecoder`: MINT as 11 static words plus hookData; INCREASE and DECREASE as `(tokenId, liquidity, uint128, uint128, bytes)`; BURN as `(tokenId, uint128, uint128, bytes)`; SETTLE as `(Currency, uint256, bool)`; TAKE as `(Currency, address, uint256)`.
   - Only explicit non-zero amounts are passed; 0 would mean "the whole open delta".
   - The MINT owner is the adapter, and every TAKE goes to the vault.
   - The deadline is the caller's, and `block.timestamp` for collect and for unwind exits.
   - `lib/v4-periphery` is on `main`, not the deployed tag, but the adapter uses only these constants and two view interfaces.
   - Evidence: the existing fork lifecycle tests on both chains, plus my fork runs through the live PositionManager.
2. **The principal/income split matches the PoolManager to the wei.**
   - `_uncollectedIncome` applies `Position.update`'s formula to StateView's `getFeeGrowthInside`, which is `Pool.getFeeGrowthInside` verbatim.
   - `_principal` uses `Pool.modifyLiquidity`'s branches and rounding: up when adding, down when removing.
   - The realize step (a DECREASE of 0) runs first, so the principal step's fees are 0.
   - Tick updates on already-initialized ticks never touch `feeGrowthOutside`, and slot0 does not move during a liquidity change.
   - So every computed TAKE equals the pool's credit, and `CurrencyNotSettled` enforces the per-currency sum.
3. **A stranger cannot make a V4 exit revert (plain tokens).**
   - No one else is approved for the NFT, and it has no subscriber.
   - `CannotUpdateEmptyPosition` cannot fire: a decrease requires less than the position's liquidity, and a close skips the realize step at 0.
   - `feesOwed.toInt128` would need more than 2^127 units of fees.
   - `positionValue` and `cumulativeIncome` cannot overflow: the fee-growth difference is below 2^256 and the liquidity below 2^128.
   - Unwind minimums are 0, so a price move cannot revert an exit; that is the C-01 problem instead.
4. **Allowances.**
   - The ERC-20 allowance to Permit2 and the Permit2 allowance to the PositionManager are exact, expire at the current block, are consumed to 0 by SETTLE, and are reset.
   - A reverting plan reverts the grants too, and nothing is left between calls.
   - Aderyn L-14 flags `permit2.approve` as an unsafe ERC-20 call, but it is Permit2's four-argument `approve`, not ERC-20's.
5. **Swap path.**
   - The callback requires `msg.sender == poolManager`, and the PoolManager calls back only its unlocker. A hook token cannot reach the callback, because a second unlock reverts `AlreadyUnlocked`.
   - The swap is exact-input, with `PartialSwap` checked on both the delta and `settle()`.
   - The output is taken straight to the vault, and any surplus input is handed back. A zero output is accepted only against a zero minimum.
6. **Measured versus computed amounts (lead 3).**
   - V4: `used`, principal and income are computed, but they are settled and taken as explicit amounts, which the PoolManager checks per currency. The swap output is measured from the delta, and hand-backs are measured and not reported.
   - Aave: principal and income are Aave's own return values (`withdrawn == amount`), and a full exit reports `attributable <= withdrawn`.
   - Across: `amountToArrive` is the quote's `outputAmount`, which the escrow cannot change through a speed-up.
   - An over-report fails `_requireBacked`; an under-report becomes sweepable excess. With plain tokens, no computed amount can exceed what moved (see I-07 for the rest).
7. **Aave ledger at revision 11.**
   - The vendored `ReserveData` matches the live 15-word return, with aArbUSDCn at word 8 (measured with `cast`).
   - Mint and balance round down, burn rounds up, and the ledger moves only by measured scaled deltas.
   - There is no borrow, collateral, delegation or eMode path. The aToken `permit` needs an ECDSA signature the adapter cannot give, and a position with no debt cannot be liquidated.
   - Reserve states:
     - Paused: principal exits revert (DEC-059 fact; for the unwind, spoke-a L-03).
     - Frozen: exits work.
     - Supply cap reached: only entries are affected.
     - Full utilization: principal exits revert (DEC-069 waits).
8. **Donated aTokens never become income.**
   - Report 02's checked note "Aave aTokens: become income" is inaccurate.
   - They stay outside the ledger. A full exit pays them out unreported (pro rata, floored), and they are then swept.
   - The existing `test_DEC080_donatedATokensNeverReported` covers this.
9. **Across against the live SpokePools** (implementations `0xcfcda843…` and `0x1771c470…`, unchanged since 2026-09-29).
   - `depositV3`'s argument order and types match; the buffers are 21,600 and 3,600; `numberOfDeposits` is a uint32.
   - `now + 21,600` equals the buffer, which the pool accepts with `<=`.
   - The pool enforces `quoteTimestamp` and exclusivity.
   - The adapter holds no tokens, grants nothing and calls only views.
   - The escrow has no EIP-1271, so no speed-up can lower the output. A recipient above 160 bits is rejected.
10. **AdapterGuard gating, verb by verb.**
    - Entries (open, increase) check deprecated, then paused.
    - Exits never read the flags.
    - The V4 swap checks deprecation only (spoke-a H-01).
    - Across: the Core Vault refuses a paused or deprecated hub adapter, and the spoke never checks.
11. **Unwind depth on the live pool** (`UnwindSwapDepthFork.t.sol`).
    - Selling 20 WETH through the adapter returns 97.04% of the spot quote, and 1 WETH returns 99.79%.
    - So after the fund's own liquidity is gone, the 5% floor does not block sales of up to about 20 WETH (about 53,000 USDC at the fork price). At these sizes this refutes spoke-a L-01 (3), "sells into the pool it just left"; a fund position much larger than the pool's own depth can still hit it.
12. **Views a stranger cannot make revert:** the V4 income and principal views, and Aave's `positionValue`.
13. **Static-analysis leads in scope, dismissed:**
    - Slither #10: `limit == 0` is the "no price limit" sentinel.
    - Slither #20-#29 (Aave, reentrancy-no-eth): every entry is `onlyVault nonReentrant` against the fixed Pool, and the writes after the call record deltas Aave measured. USDC has no hooks, so there is no read-only window either.
    - Slither #40 and #41: the zero-initialization is intentional, and the variable is assigned in both branches.
    - Slither #55-#60: the unused tuple fields are not needed, and `add` and `remove` act on keys that are fresh or known to be present.
    - Aderyn H-3 (Aave `:133`, `:174`, `:199`, `:277`; Across `:62`; V4 `:366`): each is a constructor call or a view read. See I-04 for the ordering at `:366`.
    - Aderyn H-5 at `:707`: every `Actions` constant is below 0x20.
    - Aderyn L-12 (Aave `:424`; V4 `:369`, `:480`): `_withdraw` returns true or reverts, and set membership is already known.
    - Aderyn L-10: an array cannot be immutable.
    - Aderyn L-7: `onlyVault` is a pure check.

## Not covered

- Robinhood forks. The existing Robinhood V4 lifecycle suite runs there, but my PoCs ran on Arbitrum only; the spoke-side wash-trade channel is reasoned.
- A randomized fork fuzz of the V4 split across tick and price edges on the real PoolManager. This is reasoned from code equivalence (item 2 above).
- Merkl claim mechanics (I-05).
- Outside my scope: the vault half of the C-01 fix, and the Across fill and refund lifecycle beyond `buildSend`.
