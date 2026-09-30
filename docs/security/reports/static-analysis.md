# Static analysis report, 2026-09-30

Security sweep of `src/` at commit `e5c778a` (main) with every static analyzer that could be made to run, each
result read against the code. Branch `docs/pp-sc-docs-sec-static`. Raw outputs are in `docs/security/reports/raw/`.

Verdicts used in the tables: **true positive** (the tool is right and something should change), **false positive**
(the pattern matched but the code is safe, with the reason), **accepted by design** (the tool is right about the
pattern and a decision or a documented stance chose it; the reasoning says which). Severity follows the sweep's rubric:
critical, high, medium, low, info.

## 1. Result

| | |
|---|---|
| Tools run | Slither 0.11.6 (102 detectors, 2 printers, `slither-check-erc`), Aderyn 0.6.8 (88 detectors), Semgrep 1.178.0 (registry pack `p/smart-contracts`, 50 rules; Decurity rules at `2e878a8`, 57 rules), Solhint 6.2.4 (recommended plus the security rules), Mythril 0.24.8 (four standalone contracts) |
| Tools not run | none of the five requested; limits in section 9 |
| High / medium / low results triaged | Slither 8 / 68 / 77, Aderyn 21 high-classified and 114 low-classified instances, Semgrep 1 error, 2 warnings and 13 info in the security category, Solhint 43 warnings of its security rules, Mythril 1 medium and 1 low |
| True positives from the tools | 1 low (SA-04) and 5 informational hygiene items (SA-06); no tool result of high or medium impact survived the reading |
| Found while reading the code for the triage | 1 high (SA-01), 2 medium (SA-02, SA-03), 1 info (SA-05); none of them is a pattern these tools detect |

What the tools say about this codebase: the classic defects they look for (unguarded reentrancy, unchecked transfers,
`tx.origin`, arbitrary delegatecall, unprotected initializers, locked ether, packed-hash collisions) are absent. Every
value-moving entry carries a reentrancy guard, every ERC-20 move goes through SafeERC20, value bases come from
internal ledgers and not from `balanceOf`, and the low-level calls target pinned addresses. The risk that remains is
economic, in rules the tools cannot see: how a position is priced (SA-01), what happens to value when a cross-chain
message is missed (SA-02), and ledger buckets that only grow in contracts that can never be upgraded (SA-03).

## 2. Findings

| Id | Severity | Title | Source | Proof of concept |
|---|---|---|---|---|
| SA-01 | high | Share Assets follow the pool's spot composition, not the oracle: anyone who moves a Uniswap V4 pool raises the Share Price, and a Payout claimed then is overpaid | code reading during the triage of `unused-return` on `UniswapV4Adapter._principal` (S-36) | `test/fork/security/SpotCompositionInflation.t.sol::test_POC_forkHubSharePriceFollowsPoolSpotCompositionNotTheOracle` |
| SA-02 | medium | The fund's own transfer home is locked for good when no accepted report listed it while it was in flight | code reading during the triage of `CoreVaultLogic` reentrancy results | `test/unit/security/StaticReviewFindings.t.sol::test_POC_SA02_transferHomeNoAcceptedReportListedIsLockedForGood` |
| SA-03 | medium | Operating Cash only grows: Payout Fees and top-ups are locked for good, and the manager sets floor and top-up without a bound | code reading during the triage of `incorrect-equality` on `_topUpOperatingCash` | `test/unit/security/StaticReviewFindings.t.sol::test_POC_SA03_managerParametersMoveAllFreeIdleIntoOperatingCashForGood`, `::test_POC_SA03_payoutFeeIsLockedInOperatingCash` |
| SA-04 | low | `_collectIncome` ignores whether the accumulator accepted the distribution | Slither `unused-return` (S-38), Aderyn L-12 | none (not reachable with real amounts) |
| SA-05 | info | The price read keeps only the answer and its time; a payout never checks price age | Slither `unused-return` (S-42); accepted stance OQ-10 | none |
| SA-06 | info | Hygiene: dead code, a shadowed name, an initializer without an event, uncached array length, constant-style names on non-constants | Slither `dead-code`, `shadowing-local`, `naming-convention`, `cache-array-length`; Aderyn L-9, L-11 | none |

### SA-01 (high): Share Assets follow the pool's spot composition

**Where.** `src/adapters/UniswapV4Adapter.sol:266-284` (`positionValue`) and `:621-637` (`_principal`, amounts at
`stateView.getSlot0`); `src/core/CoreVaultLogic.sol:235-248` (`_positionsPrincipal`: each amount times the price
source's price); used by `recordValuation` for every deposit, Payout Request and claim (`src/core/CoreVault.sol:69`,
`:105`, `:185`) and, for a spoke, by the permissionless `SpokeVault.report()` (`src/spoke/SpokeVault.sol:404`,
`src/spoke/SpokeCrossChainLib.sol:160`).

**What.** A position's principal is reported as the two token amounts it would return at the pool's current price, and
the Core Vault values those amounts with Chainlink (WETH) and par (USDC, USDG). For a liquidity position the bundle
held at pool price `P`, valued at an outside price `P0`, is smallest exactly when `P = P0` (`dV/dP = x'(P) * (P0 - P)`
with `x' < 0`). So any move of the pool away from the oracle price, up or down, raises the reported value while the
position's real value is unchanged. Moving a pool inside one transaction costs only the swap fees of the round trip:
no arbitrageur can step in between the two swaps.

**Measured** (fork of Arbitrum One at block 510,364,369, live WETH/USDC 0.05% pool, the end-to-end fund: 9,973 USDC of
Share Assets, a 3,000 USDC position 200 ticks wide on each side):

| State | Share Assets (USDC) |
|---|---:|
| pool at the oracle price | 9,973.100463 |
| pool pushed 600 ticks down (position reported as WETH only) | 9,985.748091 |
| pool pushed 600 ticks up (position reported as USDC only) | 9,990.579137 |
| pool restored | 9,973.100463 |

An Instant Payout of 1,000 USDC claimed in the pushed state burned at 1.001077 instead of 0.999810 and took 1.27 USDC
more from Idle than the burned shares were worth. The trader's whole round trip (down, up, back) cost 124.30 USDC in
fees. At this size the manipulation does not pay; the numbers show the mechanism and its cost.

**When it pays.** The raise is a property of the range, not of the pool:

| Position range around the oracle price | Reported value above fair, pool pushed below / above the range |
|---|---|
| 200 ticks each side (about 2%) | +0.5% / +0.5% |
| 10% each side | +2.8% / +2.3% |
| 25% each side | +8.7% / +5.2% |
| 50% each side | +25.5% / +8.7% |
| full range, pool price moved 4x / 10x / 100x | +25% / +74% / +405% |

A claim paid from Idle takes `payout * raise / (1 + raise)` from the holders who stay, where `raise` is the table's
figure times the position's share of Share Assets. The claimant pays the flow fee (0.25%) on a Standard Payout, or the
flow fee plus the Payout Fee (2.25%) on an Instant Payout in the same transaction, plus the swap fees of the round
trip, which scale with the liquidity in the path and not with the raise. A fund whose hub position is wide or full
range and is a large part of Share Assets is exposed for any holder with a matured Standard Payout Request; a fund with
narrow ranges in a deep pool is not, today.

**Spoke Chain.** `report()` is permissionless and reads the same spot amounts, so the move does not have to be atomic
with the claim: push the Robinhood pool, call `report()`, restore, let the report be delivered. The raised value then
prices every Payout, and every deposit (the entrant overpays, to the benefit of current holders), until the next
report is accepted; a payout keeps using it even past its lifetime (Q57 reading). The Q57 (d) variation band that would
bound it is stored and never enforced.

**Relation to the decisions.** DEC-067 says the hub position is valued "at guarded pool price" and QA3 lists the price
guard of the hub Uniswap position as "now a payment guard, not only an execution guard (parameters undecided)". The
final verification added a guard on the unwind swap only (`MAX_UNWIND_SLIPPAGE_BPS`); the valuation has none. This is
the open rule QA3 turning into a loss, not a new rule.

**Fix.** Value a price-dependent position from its liquidity and range at the oracle-implied price instead of at
`slot0`: `P = priceInUsdc(token0) / priceInUsdc(token1)` (base units of token1 per base unit of token0), clamp it to
the range, take the amounts with `SqrtPriceMath`, then price them. That is the position's value at the oracle price and
cannot be moved by trading in the pool. The report already carries `tickLower`, `tickUpper` and `liquidity` per
position (the Q57 (b) superset), so the same computation serves the spoke on the hub without a payload change. If the
spot amounts are kept, a mint must revert and a payout must take the lower of the two valuations when spot and oracle
differ by more than a bound, and the unwind path needs the same bound. Decide QA3 and Q57 (d) before funds with wide
ranges go live.

### SA-02 (medium): a transfer home that no accepted report listed is locked for good

**Where.** `src/core/CoreVaultLogic.sol:489-505` (`receiveHubBound`: an arrival whose id no report listed goes to
`unmatchedArrivals`), `:463-482` (`_matchReturnLeg`: only a report's `inFlightToHub` entry sets `listed`);
`src/spoke/SpokeCrossChainLib.sol:300-302` (`_stillInFlight`) and `:103-106` (pruned at the next report).

**What.** Two stances meet. OQ-01: the hub credits a spoke-to-hub arrival only against what an accepted report listed
for its id, and what is not matched is held apart "for good, never swept". OQ-09: the spoke lists a send home only
until `fillDeadline + maxReportAge` (about 6 h 26 min), then presumes it filled and drops it. Across fills within
minutes and does not depend on Wormhole. So if no report built inside that window is accepted on the hub, the fund's
own filled transfer is never listed again: the USDC sits in the Core Vault under `unmatchedArrivals`, outside Share
Assets, outside the sweep, with no verb that can credit it. The proof of concept shows Share Assets losing the whole
500 USDC transfer while the Core Vault holds the USDC.

**When.** A report must be delivered within its own lifetime (1,588 s on Robinhood) and finality there already takes
15 to 20 minutes, up to about 26 in the measured history (Q57). The window closes on any of: the keeper that relays
reports down for six and a half hours; Wormhole guardians or Robinhood Chain finality slower than the report lifetime
for that long (every report built in the window is then `ReportTooOld`); or the manager sending home during such an
outage. No attacker is needed and none can force it, which is why this is medium and not high; the loss is permanent
and its size is whatever was in flight home.

**Fix.** Give a listing a second chance instead of relying on one window. The cheapest shape: a permissionless
`relist(transitId)` on the Spoke Vault that puts a past hub-bound transit (amount and kind from its own books) into a
"past transfers" list of the next report, which the hub uses only to set `listed` and credit what is pending (it must
not count as In-flight Value or toward the Spoke Cap). The hub already credits at most `listed` per id, once, so
relisting is idempotent. Until then: runbook rule that the manager never sends home unless a report was accepted in
the last few minutes, and an alert on `TransitReceived(..., matched = false)` for ids the spoke did send.

### SA-03 (medium): Operating Cash only grows

**Where.** `src/core/CoreVaultBase.sol:269-296` and `src/spoke/SpokeVault.sol:368-372`, `:988-998`
(`setOperatingCashParameters`, `_topUpOperatingCash`); `src/core/CoreVault.sol:243` (Payout Fee). The only writes to
`operatingCash` in `src/` are those three additions.

**What.** DEC-096 says Operating Cash is distributed to holders at fund close and DEC-102 says it can be sent to spokes
for gas. Neither verb exists (spending is OPEN, doc 30; there is no fund close), and the contracts are immutable
(DEC-058), so for any fund created from this code every unit that enters Operating Cash is locked for good and outside
Share Assets: the 2% Payout Fee of every Instant Payout (100 USDC on a 5,000 USDC payout in the proof of concept) and
every top-up. That is a bounded, continuous leak on the honest path.

The manager sets the floor and the top-up on a live fund with no bound (DEC-096, DEC-100: "no protocol cap on the
floor"). The decisions had 1 to 10 USD in mind; the code accepts any value. Two manager calls,
`setOperatingCashParameters(max, freeIdle - 1e6)` then `allocateToHubSpokeVault(1e6)`, move all Free Idle into
Operating Cash: Share Assets went from 9,975 to 1 USDC in the proof of concept. On a spoke the same two steps empty the
Unallocated Balance of the base token. This is an intended rule, and the manager is already trusted with the fund's
capital inside the Mandate pools, so it is not rated as theft; but it is the one manager lever that destroys value
with no counterparty, no Mandate limit and no recovery, which matters for an Autonomous Manager whose key or policy
fails.

The same one-way property holds for two smaller buckets: `ownerless` income (LC-32 OPEN: kept "until fund closure")
and `unmatchedArrivals` above a listing (OQ-01). Both are documented; neither has an exit either.

**Fix.** Before mainnet: a cap on floor and top-up (a Mandate value fixed at creation, or a core constant with the
DEC-096 orders of magnitude), and one verb that returns Operating Cash above the floor to Idle (hub) or to Unallocated
Balance (spoke). Returning it to Share Assets can never take value out of the fund, keeps DEC-096's close-out rule
reachable, and needs no decision on who may spend it.

### SA-04 (low): the accumulator's answer is ignored at collection

**Where.** `src/core/CoreVaultLogic.sol:392-393`; `src/libraries/IncomeAccumulator.sol:173-221` (`distribute`).

**What.** `distribute` returns false and emits `DistributionSkipped` when it does not take an amount (above
`2^128 - 1`, or an index that would overflow), and its NatSpec says the caller then keeps the amount out of what is
distributed. `_collectIncome` adds the net amount to `collectedIncome[token]` first and ignores the answer, so a skipped
amount would sit in the collected balance owed to nobody, inside the ledger and therefore never swept. Not reachable
with real amounts (3.4e38 base units is 3.4e20 WETH), hence low: it is the one place where a documented "never
reverts, caller decides" contract has no caller deciding.

**Fix.** Branch on the result: when false, keep the net out of `collectedIncome` and book it in a bucket with an exit
(or revert in `receiveCollectedIncome`, which may revert, and route to the ownerless bucket on the report path, which
may not).

### SA-05 (info): what the price read checks

`ChainlinkPriceSource.priceInUsdc` (`src/report/ChainlinkPriceSource.sol:118-130`) rejects a non-positive answer and
returns `updatedAt`; it does not read the Arbitrum sequencer-uptime feed and does not know a feed's minimum or maximum
answer. A mint checks age against `maxPriceAge(token)` (`src/core/CoreVaultLogic.sol:342`); a payout never does and,
when the source reverts, uses the last price stored by an earlier deposit or payout. All of this is the OQ-10 stance
and is written in the NatSpec and the review log, so it is accepted, not a defect. The risk it carries: while a feed is
stale or the sequencer has just come back, holders who claim are paid at the old price and the holders who stay bear
the difference. For mints the bound is a trade: the deployment script sets one hour for ETH / USD
(`script/FactoryDeployment.sol:70`), which closes mints whenever the feed has not updated for an hour and otherwise
accepts a price up to an hour old; it should be set against the feed's published heartbeat and deviation. Worth a
ruling together with Q57 (b): at least a sequencer-uptime check for mints and the lower of the two prices for payouts,
as the research recommended (alternative 3).

### SA-06 (info): hygiene the tools confirmed

| Item | Where | Tool |
|---|---|---|
| `_spoke(uint256)` is never called | `src/core/CoreVaultBase.sol:350-353` | Slither `dead-code` |
| Named return `reportSequence` shadows the getter of the same name | `src/interfaces/ISpokeVault.sol:273` | Slither `shadowing-local` |
| `initialize` binds the vault and token of an escrow clone without an event | `src/core/TransitEscrow.sol:26-31` | Aderyn L-9 |
| `_assets.length` read from storage on every iteration of a view | `src/adapters/AaveV3Adapter.sol:327`, `:332` | Slither `cache-array-length`, Aderyn L-11 |
| `NUMBER_OFFSET`, `DEFAULT_PROTOCOL_SLICE_BPS()`, `MAX_PROTOCOL_SLICE_BPS()` are not mixedCase (an immutable and two constant getters, named as constants on purpose) | `src/factory/FundFactory.sol:47`, `src/interfaces/IFundFactory.sol:226`, `src/interfaces/IManagerRegistry.sol:26`, `:29` | Slither `naming-convention` |

## 3. Tools, versions and commands

Run from the repository root with Foundry 1.7.1 and solc 0.8.28 (`foundry.toml`: evm cancun, optimizer 800 runs,
`via_ir` off). `lib/` must be populated (`forge install` or the worktree symlink).

| Tool | Version | Command | Raw output |
|---|---|---|---|
| Slither | 0.11.6 | `slither . --filter-paths "lib\|test\|script"` (all 102 detectors; add `--json <file>` for the machine-readable form) | `raw/slither.txt`, `raw/slither.json` (compact: one entry per result) |
| Slither printers | 0.11.6 | `slither . --filter-paths "lib\|test\|script" --print human-summary` and `--print contract-summary` | `raw/slither-human-summary.txt`, `raw/slither-contract-summary.txt` |
| slither-check-erc | 0.11.6 | `slither-check-erc . ShareToken --erc ERC20` | `raw/slither-check-erc-ShareToken.txt` |
| Aderyn (Cyfrin) | 0.6.8 | `npx --yes @cyfrin/aderyn . -s src -o docs/security/reports/raw/aderyn.md` | `raw/aderyn.md`, `raw/aderyn-stdout.txt` |
| Semgrep, registry pack | 1.178.0 | `semgrep scan --metrics=off --config p/smart-contracts --json --output <file> src` | `raw/semgrep-p-smart-contracts.json`, `.txt` |
| Semgrep, Decurity rules | 1.178.0, rules at commit `2e878a89ac7bba1f8435e8a68e3ecb7700096cd5` (2025-06-02) | `git clone --depth 1 https://github.com/Decurity/semgrep-smart-contracts /tmp/decurity` then `semgrep scan --metrics=off --config /tmp/decurity/solidity --json --output <file> src` | `raw/semgrep-decurity.json`, `.txt` |
| Solhint | 6.2.4 | `npx --yes solhint -c docs/security/reports/raw/solhint.config.json --noPoster -f unix 'src/**/*.sol'` | `raw/solhint.txt`, config `raw/solhint.config.json` |
| Mythril | 0.24.8 | `uv tool install mythril --with "setuptools<81"`; with solc 0.8.28 first on `PATH`: `myth analyze <file>:<Contract> --solc-json docs/security/reports/raw/mythril-solc.json --execution-timeout 300 -t 3` for `TransitEscrow`, `ManagerFeeVault`, `ManagerRegistry`, `ShareToken` | `raw/mythril.txt`, settings `raw/mythril-solc.json` |

Installed for this sweep: Semgrep (`uv tool install semgrep`) and Mythril; Slither was already present; Aderyn and
Solhint run through `npx`. The proofs of concept: `forge test --match-path "test/unit/security/*"` (no network) and
`forge test --match-path "test/fork/security/*"` with `ARBITRUM_FORK_BLOCK` and `ROBINHOOD_FORK_BLOCK` set to a recent
block (the public RPCs serve only recent state).

## 4. Slither

174 results: 8 high, 68 medium, 77 low, 19 informational, 2 optimization (the `human-summary` printer reports 1 high:
its own count leaves out the seven `reentrancy-balance` results). Line numbers in the location column are the function
Slither anchors the result to; the statement lines are in brackets. "Results" is the number of Slither results the
row covers.

| Id | Impact | Detector | Function at file:line (statement lines) | Results | Verdict | Reasoning |
|---|---|---|---|---:|---|---|
| S-01 | High | `encode-packed-collision` | `factory/FundFactory.sol:460` (478) | 1 | false positive | The packed bytes are creation code followed by one `abi.encode` blob of constructor arguments, handed to CREATE and never hashed or compared. The creation code is fixed by `coreVaultCreationCodeHash` (FundFactory.sol:154-157). |
| S-02 | High | `reentrancy-balance` | `core/CoreVault.sol:144` (151, 160, 172) | 1 | false positive | The Share balance read before the unwind can only change through `ShareToken.mint` and `burn`, which only the Core Vault calls, from entries that are `nonReentrant` and already entered. During the unwind the only admitted callback is `returnToIdle` from the hub Spoke Vault, which touches no share. Shares are not transferable (DEC-004). |
| S-03 | High | `reentrancy-balance` | `core/CoreVaultLogic.sol:576` (624-633) | 1 | false positive | The balance read around the call is the custody check itself (exact debit, IBridgeAdapter rule 3). Idle, the transit and the books are written before the call; the target is the pinned Across SpokePool; the entry is `onlyManager nonReentrant`. |
| S-04 | High | `reentrancy-balance` | `core/CoreVaultLogic.sol:735` (743, 752-755) | 2 | false positive | State (RefundRecognized, Idle, In-flight Value) is written before `release`. The callee is the fund's own TransitEscrow clone, whose only code path is a token transfer to the vault. `received != held` is a fail-closed check, not a value base. |
| S-05 | High | `reentrancy-balance` | `spoke/SpokeCrossChainLib.sol:337` (339-349) | 1 | false positive | Same custody check as the hub send: the ledger is debited and the transit booked before the call (`_debit`, `_book`), the target is the pinned SpokePool, `sendToHub` is `onlyManager nonReentrant`. |
| S-06 | High | `reentrancy-balance` | `spoke/SpokeCrossChainLib.sol:70` (79, 87-90) | 2 | false positive | Same as the hub refund: state and ledger are written before `release` (lines 82-85), the callee is the fund's own escrow clone, the comparison fails closed. |
| S-07 | Medium | `divide-before-multiply` | `core/CoreVaultLogic.sol:386` (388-389) | 1 | accepted by design | The protocol slice is a share of the already floored fee, so at most one base unit per collection stays with the manager's portion instead of the protocol. The fee total never exceeds `floor(amount * bps / 10_000)` and the rounding directions are stated in NatSpec (CoreVaultLogic.sol:380-381). |
| S-08 | Medium | `incorrect-equality` | `adapters/UniswapV4Adapter.sol:516` (533) | 1 | false positive | `limit == 0` is the sentinel for 'no price limit'. |
| S-09 | Medium | `incorrect-equality` | `core/CoreVault.sol:144` (152, 172) | 2 | false positive | Zero checks on the claimant's own share balance and on a computed share count; no third party can set either (shares are not transferable). |
| S-10 | Medium | `incorrect-equality` | `core/CoreVault.sol:217` (231, 261) | 2 | false positive | `c.shares == c.balance` detects a full burn from values read in the same guarded call; nobody can add share dust to force or avoid it. |
| S-11 | Medium | `incorrect-equality` | `core/CoreVault.sol:98` (104) | 1 | false positive | Zero check on the requester's own share balance. |
| S-12 | Medium | `incorrect-equality` | `core/CoreVaultBase.sol:283` (291) | 1 | false positive | Early return when the top-up amount is zero (internal ledger arithmetic). |
| S-13 | Medium | `incorrect-equality` | `core/CoreVaultIncome.sol:53` (55) | 1 | false positive | Early return when nothing is owed. |
| S-14 | Medium | `incorrect-equality` | `core/CoreVaultTransit.sol:129` (131) | 1 | false positive | Early return when there is no excess; a donation only makes the sweep run. |
| S-15 | Medium | `incorrect-equality` | `report/ValueReportReceiver.sol:214` (220) | 1 | false positive | `acceptedAt == 0` is the 'never accepted' sentinel; it is set to `block.timestamp` on acceptance and is never 0 afterwards. |
| S-16 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:164` (178-179) | 1 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. |
| S-17 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:190` (203-205) | 2 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. |
| S-18 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:250` (260-264) | 1 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. `open` is cleared before the call and set back only when pending income stays behind. |
| S-19 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:382` (399-427) | 3 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. |
| S-20 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:439` (445-450) | 1 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. |
| S-21 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:457` (468-470) | 1 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. |
| S-22 | Medium | `reentrancy-no-eth` | `adapters/AaveV3Adapter.sol:478` (483-495) | 1 | accepted by design | Every verb is `onlyVault nonReentrant` and the callee is the Aave V3 Pool fixed at construction. The writes after the call record the scaled delta Aave produced, which cannot be known before it; stated in NatSpec (AaveV3Adapter.sol:246-249) and in the review log. |
| S-23 | Medium | `reentrancy-no-eth` | `core/CoreVault.sol:144` (160, 174) | 1 | false positive | `nonReentrant`. The unwind callee is the fund's hub Spoke Vault; while it runs only `returnToIdle` is admitted (hub Spoke Vault only, backed by USDC above the ledger), and the claim is priced again after the unwind (line 162) before anything is written. |
| S-24 | Medium | `reentrancy-no-eth` | `core/CoreVault.sol:217` (258-261) | 1 | false positive | The call is `burn` on the fund's own ShareToken, which calls nothing back; what follows is the income payment of the same holder, inside the same guard. |
| S-25 | Medium | `reentrancy-no-eth` | `spoke/SpokeVault.sol:249` (261-267) | 1 | false positive | Entry is `nonReentrant` and manager-only (or Core-Vault-only); the callee is a Mandate adapter whose codehash is pinned and rechecked (`_positionAdapter`). The ledger is credited after the call on purpose, from what the adapter returned (DEC-079, DEC-080), and `_requireBacked` reverts if the ledger ends above the balance. |
| S-26 | Medium | `reentrancy-no-eth` | `spoke/SpokeVault.sol:274` (287-289) | 1 | false positive | Entry is `nonReentrant` and manager-only (or Core-Vault-only); the callee is a Mandate adapter whose codehash is pinned and rechecked (`_positionAdapter`). The ledger is credited after the call on purpose, from what the adapter returned (DEC-079, DEC-080), and `_requireBacked` reverts if the ledger ends above the balance. |
| S-27 | Medium | `reentrancy-no-eth` | `spoke/SpokeVault.sol:524` (538-544) | 1 | false positive | Entry is `nonReentrant` and manager-only (or Core-Vault-only); the callee is a Mandate adapter whose codehash is pinned and rechecked (`_positionAdapter`). The ledger is credited after the call on purpose, from what the adapter returned (DEC-079, DEC-080), and `_requireBacked` reverts if the ledger ends above the balance. |
| S-28 | Medium | `reentrancy-no-eth` | `spoke/SpokeVault.sol:752` (759-773) | 2 | false positive | Entry is `nonReentrant` and manager-only (or Core-Vault-only); the callee is a Mandate adapter whose codehash is pinned and rechecked (`_positionAdapter`). The ledger is credited after the call on purpose, from what the adapter returned (DEC-079, DEC-080), and `_requireBacked` reverts if the ledger ends above the balance. |
| S-29 | Medium | `reentrancy-no-eth` | `spoke/SpokeVault.sol:779` (799-805) | 1 | false positive | Entry is `nonReentrant` and manager-only (or Core-Vault-only); the callee is a Mandate adapter whose codehash is pinned and rechecked (`_positionAdapter`). The ledger is credited after the call on purpose, from what the adapter returned (DEC-079, DEC-080), and `_requireBacked` reverts if the ledger ends above the balance. |
| S-30 | Medium | `reentrancy-no-eth` | `spoke/SpokeVault.sol:842` (860-864) | 2 | false positive | Entry is `nonReentrant` and manager-only (or Core-Vault-only); the callee is a Mandate adapter whose codehash is pinned and rechecked (`_positionAdapter`). The ledger is credited after the call on purpose, from what the adapter returned (DEC-079, DEC-080), and `_requireBacked` reverts if the ledger ends above the balance. |
| S-31 | Medium | `uninitialized-local` | `adapters/AaveV3Adapter.sol:326`, `adapters/AaveV3Adapter.sol:481`, `core/CoreVault.sol:109`, `core/CoreVault.sol:150`, `core/CoreVaultLogic.sol:181`, `core/CoreVaultLogic.sol:331`, `core/CoreVaultLogic.sol:698`, `factory/FundFactory.sol:386`, `factory/FundFactory.sol:462`, `mandate/Mandate.sol:246`, `spoke/SpokeCrossChainLib.sol:250`, `spoke/SpokeVault.sol:536`, `spoke/SpokeVault.sol:831` | 13 | false positive | The local relies on Solidity's zero default (a counter, an accumulator or a memory struct filled field by field). |
| S-32 | Medium | `unused-return` | `adapters/UniswapV4Adapter.sol:316`, `adapters/UniswapV4Adapter.sol:639`, `core/CoreVault.sol:98`, `core/CoreVaultBase.sol:235`, `core/CoreVaultBase.sol:245`, `core/CoreVaultLogic.sol:120`, `core/CoreVaultLogic.sol:143`, `core/CoreVaultLogic.sol:194`, `core/CoreVaultLogic.sol:323`, `core/CoreVaultLogic.sol:417`, `core/CoreVaultLogic.sol:541`, `factory/FundFactory.sol:184`, `spoke/SpokeVault.sol:132` | 13 | false positive | Only some members of a multi-value return are needed; the ignored ones are not status flags. |
| S-33 | Medium | `unused-return` | `adapters/UniswapV4Adapter.sol:333` (335) | 1 | false positive | Same `getSlot0` read in `spotQuote`: the ignored members are the tick and the two fees. The spot quote as a swap floor is QA3 (section 10). |
| S-34 | Medium | `unused-return` | `adapters/UniswapV4Adapter.sol:350` (369) | 1 | false positive | `EnumerableSet.add` on a token id the PositionManager has not minted yet; it cannot already be in the set. |
| S-35 | Medium | `unused-return` | `adapters/UniswapV4Adapter.sol:464` (480) | 1 | false positive | `EnumerableSet.remove` after `_openPosition` proved the key is in the set. |
| S-36 | Medium | `unused-return` | `adapters/UniswapV4Adapter.sol:621` (626) | 1 | false positive | The ignored members of `getSlot0` are the protocol fee and the LP fee. For this detector the code is fine; what the function does with the spot price it reads is finding SA-01. |
| S-37 | Medium | `unused-return` | `core/CoreVault.sol:204` (207) | 1 | accepted by design | The proceeds are measured as the Idle credited through `returnToIdle`, never as the amount the hub Spoke Vault reports (DEC-080, Core Vault verifier finding). |
| S-38 | Medium | `unused-return` | `core/CoreVaultLogic.sol:386` (393) | 1 | true positive | `IncomeAccumulator.distribute` returns false when it skips an amount (above 2^128 - 1, or an index overflow) and says the caller must keep the amount out of what holders are owed; `_collectIncome` adds the net to `collectedIncome` whatever the answer. Finding SA-04 (low: not reachable with real token amounts). |
| S-39 | Medium | `unused-return` | `core/CoreVaultLogic.sol:735` (753) | 1 | false positive | The amount `release` returns is replaced by a stricter check: the vault's balance delta must equal what the escrow held. |
| S-40 | Medium | `unused-return` | `factory/FundFactory.sol:460` (478) | 1 | false positive | `Create3.deploy` returns the address the factory already predicted and reverts when the deployment leaves no code. |
| S-41 | Medium | `unused-return` | `factory/FundFactory.sol:507` (509) | 1 | false positive | Same: predicted address, revert on failure. |
| S-42 | Medium | `unused-return` | `report/ChainlinkPriceSource.sol:118` (124) | 1 | accepted by design | `roundId`, `startedAt` and `answeredInRound` are not used: the source checks only a positive answer and hands `updatedAt` to the consumer, which decides on age (OQ-10). No sequencer-uptime feed; both are stated in NatSpec (lines 75-78) and in the review log. See 'Accepted rules that carry risk'. |
| S-43 | Medium | `unused-return` | `spoke/SpokeCrossChainLib.sol:70` (88) | 1 | false positive | Same as the hub refund: balance delta checked instead of the returned amount. |
| S-44 | Low | `calls-loop` | `adapters/AaveV3Adapter.sol:123`, `adapters/UniswapV4Adapter.sol:598` x2, `core/CoreVaultBase.sol:152`, `core/CoreVaultLogic.sol:120` x3, `core/CoreVaultLogic.sol:194` x12, `core/CoreVaultLogic.sol:323` x18, `core/CoreVaultLogic.sol:386`, `core/CoreVaultLogic.sol:401`, `factory/FundFactory.sol:482`, `report/ChainlinkPriceSource.sol:79`, `spoke/SpokeCrossChainLib.sol:121` x3, `spoke/SpokeCrossChainLib.sol:129` x2, `spoke/SpokeVault.sol:199`, `spoke/SpokeVault.sol:219`, `spoke/SpokeVault.sol:727`, `spoke/SpokeVault.sol:752` x3, `spoke/SpokeVault.sol:779`, `spoke/SpokeVault.sol:842` x2, `spoke/SpokeVault.sol:898`, `spoke/SpokeVault.sol:905`, `spoke/SpokeVault.sol:972` | 58 | accepted by design | The loop runs over a closed list fixed by the Mandate at creation (spokes, pools, adapters, bridge adapters, at most 16 income tokens), over positions only the manager opens, or over report entries bounded by the 256-entry arrival window. A reverting callee reverts a mint by design (Q57 reading) and is wrapped for a payout (payout liveness, DEC-021, DEC-056). |
| S-45 | Low | `reentrancy-benign` | `core/CoreVault.sol:204` (207-210) | 1 | false positive | The transient `_unwinding` flag is cleared after the call in both branches of the try; nothing reads it afterwards. |
| S-46 | Low | `reentrancy-events` | `core/CoreVaultLogic.sol:576` (590, 620) | 1 | false positive | Event order only; the external call before the event is `initialize` on the fund's own fresh escrow clone. |
| S-47 | Low | `reentrancy-events` | `factory/Create3Deployer.sol:23` (24-25) | 1 | false positive | Event order only; the contract has no state. |
| S-48 | Low | `reentrancy-events` | `spoke/SpokeCrossChainLib.sol:38` (52-57) | 1 | false positive | Event order only; `sendToHub` is `onlyManager nonReentrant`. |
| S-49 | Low | `shadowing-local` | `interfaces/ISpokeVault.sol:273` (273) | 1 | true positive | The named return `reportSequence` of `report()` shadows the getter `reportSequence()` in the same interface. Cosmetic, no behaviour; counted with the informational results (SA-06). |
| S-50 | Low | `timestamp` | `adapters/UniswapV4Adapter.sol:516`, `core/CoreVault.sol:144`, `core/CoreVaultLogic.sol:194`, `core/CoreVaultLogic.sol:323`, `core/CoreVaultLogic.sol:541`, `core/CoreVaultLogic.sol:576`, `core/CoreVaultLogic.sol:714`, `report/ValueReportReceiver.sol:144`, `report/ValueReportReceiver.sol:209`, `report/ValueReportReceiver.sol:214`, `report/ValueReportReceiver.sol:244`, `report/ValueReportReceiver.sol:279`, `spoke/SpokeCrossChainLib.sol:300`, `spoke/SpokeCrossChainLib.sol:70` | 14 | accepted by design | The comparison is against a window of minutes to days (report lifetime 1,588 s, fill deadline 6 h, Standard term 72 h, feed heartbeat), so a validator's few seconds of drift cannot change an outcome that matters; or it is a zero sentinel on a stored timestamp. |

Totals: high 8 false positive; medium 54 false positive, 13 accepted by design, 1 true positive (SA-04); low 4 false
positive, 72 accepted by design, 1 true positive (cosmetic, SA-06).

Note on `calls-loop` (S-44): the one growth path a stranger controls is the arrival window. 256 Across deposits of
1 USDG each to the Spoke Vault fill it for good, after which every report carries about 16 KB of arrivals and every
hub valuation reads that payload from storage (by estimate, 512 storage words: about a million gas more per
valuation, and above ten million for the first delivery that writes them). That is a cost, not a block, at Arbitrum
gas prices, and the payload size is recorded in docs/INTEGRATIONS.md; it should be weighed with Q57 (c).

### slither-check-erc on ShareToken

| Check | Verdict | Reasoning |
|---|---|---|
| `transfer`, `transferFrom` "must emit Transfer"; `approve` "must emit Approval" | accepted by design | The three functions always revert with `ShareTransfersDisabled` (DEC-004, Q58 reading A), so they never emit. Signatures, return types, `decimals`, `name`, `symbol`, `totalSupply`, `balanceOf`, `allowance` and both events pass. |
| "not protected for the ERC20 approval race condition" | false positive | No approval can exist: `approve` reverts and `allowance` is always 0. |
| Printer `human-summary`: "∞ Minting" | accepted by design | `mint` is `onlyCoreVault` and whole shares only (DEC-091); supply is bounded by deposits. |

## 5. Aderyn

Aderyn classifies every result as High or Low. "Instances" is the number it lists; file:line for each is in
`raw/aderyn.md`.

| Id | Aderyn class | Issue | Instances | Verdict | Reasoning |
|---|---|---|---:|---|---|
| H-1 | High | `abi.encodePacked()` hash collision | 3 (`factory/CodeStore.sol:42`, `factory/FundFactory.sol:478`, `:509`) | false positive | None of the three results is hashed: two are creation code plus one `abi.encode` blob passed to CREATE, one builds a data contract's init code. Same as Slither S-01. |
| H-2 | High | Contract locks Ether without a withdraw function | 1 (`spoke/SpokeVault.sol:37`) | false positive | The only payable entry is `report()`, which forwards the whole `msg.value` to `ICoreBridge.publishMessage` (SpokeVault.sol:413-414); the Wormhole Core requires `msg.value == messageFee()` (0 on both chains today) and reverts otherwise. There is no `receive` or `fallback`, so no ether can stay. |
| H-3 | High | Reentrancy: state change after external call | 13 (`adapters/AaveV3Adapter.sol:133`, `:174`, `:199`, `:277`; `adapters/AcrossBridgeAdapter.sol:62`; `adapters/UniswapV4Adapter.sol:366`; `core/CoreVaultLogic.sol:590`, `:592`, `:743`; `report/ChainlinkPriceSource.sol:85`; `report/ValueReportReceiver.sol:145`; `spoke/SpokeCrossChainLib.sol:79`; `spoke/SpokeVault.sol:261`) | false positive | Three are constructors. Eight are view calls (STATICCALL: the Aave index three times, `nextTokenId`, `balanceOf` twice, `buildSend`, `parseAndVerifyVM`) that cannot re-enter. `CoreVaultLogic.sol:590` is `initialize` on the fund's own fresh escrow clone. `SpokeVault.sol:261` is Slither S-25. All the mutating entries are `nonReentrant`. |
| H-4 | High | Storage array edited with memory | 1 (`spoke/SpokeVault.sol:538`) | false positive | `_unwindStep` takes a memory copy of one `UnwindStep` and only reads it; nothing is meant to be written back. |
| H-5 | High | Unsafe casting of integers | 2 (`adapters/UniswapV4Adapter.sol:707`, `core/CoreVaultLogic.sol:404`) | false positive | `uint8(action)` for `Actions` constants below 0x20; `uint16(BPS)` for the constant 10,000 in a branch that caps a value. Every other narrowing uses SafeCast or follows an explicit bound. |
| H-6 | High | Yul block contains `return` | 1 (`spoke/SpokeVault.sol:426`) | false positive | Intended: `buildReport` is an external view with no modifier and nothing after the block; it returns the library's encoded report without decoding and re-encoding it (the payload's tail from the second word is `abi.encode(report)` once that word holds the offset 0x20). |
| L-1 | Low | Centralization risk | 4 (`core/ManagerRegistry.sol:17`, `:50`, `:61`, `:67`) | accepted by design | The registry owner (protocol admin, `Ownable2Step`, LC-142 OPEN) sets only the protocol's share of the manager's fee, capped at 50%; it never touches holders' value. `renounceOwnership` reverts. |
| L-2 | Low | Costly operations inside loop | 4 | false positive | The loops are the income payment over at most 16 tokens, the holder checkpoint, and the unwind walk; each iteration must write. Gas only. |
| L-3 | Low | Internal function used only once | 11 | informational | Style. |
| L-4 | Low | Large numeric literal | 5 | informational | `10_000` written with a separator. Style. |
| L-5 | Low | Literal instead of constant | 11 (on 9 lines) | informational | Style. |
| L-6 | Low | Modifier invoked only once | 1 (`core/CoreVaultBase.sol:174`) | informational | Style. |
| L-7 | Low | `nonReentrant` is not the first modifier | 28 | false positive | The modifiers placed before it (`onlyManager`, `onlyVault`, `onlyOnHubChain`, `onlyOnSpokeChain`) compare `msg.sender` or an immutable and make no external call, so there is nothing to re-enter before the guard is taken. |
| L-8 | Low | Loop contains `require`/`revert` | 10 | accepted by design | Validation loops at creation (factory, code store) and the unwind walk, where a step that cannot be exited must revert (DEC-069). |
| L-9 | Low | State change without event | 1 (`core/TransitEscrow.sol:26`) | true positive | Informational (SA-06). |
| L-10 | Low | State variable could be immutable | 1 (`adapters/AaveV3Adapter.sol:72`) | false positive | `_assets` is a dynamic array; arrays cannot be immutable. |
| L-11 | Low | Storage array length not cached | 2 (`adapters/AaveV3Adapter.sol:327`, `:332`) | true positive | Informational, gas in a view (SA-06). |
| L-12 | Low | Unchecked return | 12 (`adapters/AaveV3Adapter.sol:424`; `adapters/UniswapV4Adapter.sol:369`, `:480`; `core/CoreVaultIncome.sol:49`; `core/CoreVaultLogic.sol:393`, `:753`; `factory/FundFactory.sol:478`, `:509`; `mandate/Mandate.sol:335`; `spoke/SpokeCrossChainLib.sol:88`; `spoke/SpokeVault.sol:890`, `:911`) | 1 true positive, 11 false positive | `CoreVaultLogic.sol:393` is SA-04. The others: `_withdraw` without best effort returns true or reverts; two EnumerableSet booleans; `_takeIncome`'s amount is only informative in the loop; `release` is checked by balance delta; `Create3.deploy` reverts on failure; `spokeByChainId` and `_positionAdapter` are called for their revert; `_swap` books the output itself. |
| L-13 | Low | Uninitialized local variable | 12 | false positive | Loop counters and accumulators that start at zero. Same as Slither S-31. |
| L-14 | Low | Unsafe ERC20 operation | 2 (`adapters/UniswapV4Adapter.sol:684`, `:690`) | false positive | The calls are `IAllowanceTransfer.approve` on Permit2, not an ERC-20 `approve`; the ERC-20 allowance next to each uses `forceApprove`. |
| L-15 | Low | Public function not used internally | 10 (`core/CoreVaultLogic.sol`) | false positive | Library functions must be `public` or `external` to be linked and called by DELEGATECALL (docs/ARCHITECTURE.md section 1.1). |

## 6. Semgrep

`p/smart-contracts` (50 rules): 228 results, all in the performance category, none in the security category.
Decurity rules (57 rules): the same 228 performance results plus 16 in the security category:

| Rule | Severity | Where | Verdict | Reasoning |
|---|---|---|---|---|
| `arbitrary-low-level-call` | ERROR | `core/CoreVaultLogic.sol:626` | accepted by design | The target must equal the bridge target pinned at creation (line 595), the adapter that builds the calldata has a pinned codehash (line 657), the approval is exactly the amount, the debit must be exact and the approval is reset (IBridgeAdapter custody, DEC-087). The residual trust is in the Across SpokePool, an upgradeable proxy; the loss it could cause is bounded by the amount of the send in progress. |
| `exact-balance-check` | WARNING | `core/CoreVault.sol:152`, `:261` | false positive | Both compare the claimant's Share balance (`== 0`, and equal to the shares being burned); Shares are not transferable, so no one can send dust to break either. |
| `basic-arithmetic-underflow` | INFO | `core/CoreVault.sol:75`; `core/CoreVaultLogic.sol:600`, `:632`, `:722`, `:748`, `:754`; `core/CoreVaultTransit.sol:31`, `:48`; `report/ValueReportReceiver.sol:265`; `spoke/SpokeCrossChainLib.sol:89`, `:104`; `spoke/SpokeVault.sol:543`, `:560` | false positive | Solidity 0.8 checked arithmetic: a negative result reverts. Each subtraction was read for a revert that could block a flow: every one is preceded by its own bound (`fee <= 1%` of the amount, Free Idle checked, transit state that guarantees the book holds the amount, `min`, `balance > ledger`, `i > 0`), or is a balance delta where a revert is the wanted fail-closed answer (`:632`, `:754`, `:89`). |

## 7. Solhint

0 errors, 1,053 warnings. The rules configured as errors (`avoid-tx-origin`, `avoid-suicide`, `avoid-call-value`,
`avoid-sha3`, `avoid-throw`, `check-send-result`, `multiple-sends`, `no-complex-fallback`, `not-rely-on-block-hash`,
`reentrancy`, `state-visibility`, `func-visibility`, `compiler-version` 0.8.28) found nothing.

| Rule | Warnings | Where | Verdict | Reasoning |
|---|---:|---|---|---|
| `not-rely-on-time` | 27 | adapters, Core Vault, receiver, price source, spoke library (list in `raw/solhint.txt`) | accepted by design | Same as Slither S-50: deadlines, report age and terms measured in minutes to days; `block.timestamp` as a swap deadline means "this block". |
| `no-inline-assembly` | 13 | `core/CoreVaultLogic.sol:628`; `factory/CodeStore.sol:36`, `:44`, `:65`; `factory/Create3.sol:44`, `:50`; `factory/FundFactory.sol:424`, `:492`; `spoke/SpokeCrossChainLib.sol:188`, `:201`, `:343`; `spoke/SpokeVault.sol:423`, `:743` | accepted by design | All thirteen blocks were read: revert-data bubbling (3), array length trims after a bounded fill (4), CREATE2 / CREATE / EXTCODECOPY in the factory helpers (4), one MCOPY of a struct behind an address word, one raw return of an ABI tail. Each is tagged `memory-safe`; none writes outside memory it allocated. `SpokeCrossChainLib._positionReport` (`:201`) depends on `PositionReport` staying `PositionValue` prefixed by one word (0x160 bytes copied); a field added to either struct must change that constant. |
| `avoid-low-level-calls` | 3 | `core/CoreVaultLogic.sol:626`, `factory/Create3.sol:48`, `spoke/SpokeCrossChainLib.sol:341` | accepted by design | The two bridge calls (Semgrep row above) and the CREATE3 proxy call, each with its result checked. |

## 8. Mythril

| Contract | Result | Verdict | Reasoning |
|---|---|---|---|
| `TransitEscrow` | no issue | | |
| `ManagerRegistry` | no issue | | |
| `ShareToken` | no issue | | |
| `ManagerFeeVault` | SWC-107 medium, "state access after external call" in `withdraw` | false positive | The write after the token transfer is OpenZeppelin's `ReentrancyGuard` clearing its own flag. |
| `ManagerFeeVault` | SWC-107 low, "external call to user-supplied address" in `withdraw` | accepted by design | `withdraw(token, to, amount)` is manager-only and the vault holds only the manager's own fees; the token is whatever the manager names (DEC-107, DEC-109). |

## 9. Informational results (not triaged one by one)

| Tool | Count | What they are |
|---|---:|---|
| Slither | 19 informational, 2 optimization | `assembly` 11, `low-level-calls` 3, `naming-convention` 4, `dead-code` 1, `cache-array-length` 2 |
| Aderyn | 38 instances in 5 style issues | L-3, L-4, L-5, L-6 and L-15 (L-15 is listed above as a false positive) |
| Semgrep | 228 (registry pack) and the same 228 again (Decurity) | gas: `unnecessary-checked-arithmetic-in-loop` 80, `array-length-outside-loop` 65, `state-variable-read-in-a-loop` 39, `use-nested-if` 32, `non-payable-constructor` 12 |
| Solhint | 1,010 | `use-natspec` 717, `gas-indexed-events` 91, `immutable-vars-naming` 69, `import-path-check` 64, `gas-strict-inequalities` 33, `use-forbidden-name` 12, `gas-struct-packing` 8, `gas-calldata-parameters` 7, `gas-increment-by-one` 5, `function-max-lines` 4 |

Limits of this sweep, stated plainly:

- Mythril ran on the four small contracts only, 300 s and three transactions each. The Core Vault and Spoke Vault are
  linked to external libraries and far beyond what symbolic execution finishes in minutes; they were not attempted.
- The full Slither JSON (9.4 MB) is not committed; `raw/slither.json` keeps one entry per result.
- Semgrep's registry pack was fetched without login; the JSON shows "requires login" in place of code excerpts. Rule
  ids, files and lines are complete.
- Static analyzers see patterns, not prices or cross-chain timing. SA-01 to SA-03 came from reading the code the tools
  pointed at, and the dynamic, accounting and cross-chain reports of this sweep are where that kind of defect is looked
  for on purpose.

## 10. Accepted rules that carry risk

Intended rules, not vulnerabilities; each is listed because the rule itself can cost holders money and someone should
own that risk knowingly.

| Rule | Risk it carries | Reference |
|---|---|---|
| A payout never reverts on price or report age and falls back to the last stored price or hub value | Holders who claim during a stale or failed feed are paid at the old price; those who stay bear the gap (SA-05) | OQ-10, DEC-021, DEC-056 |
| The unwind swap floor is the pool's spot price less 5% | A claimant whose claim triggers an unwind can move the pool in the same transaction and trade against the fund's swap; the floor follows the moved price. Same root as SA-01 | QA3 OPEN |
| Unmatched arrivals and ownerless income are held for good | No exit in immutable contracts (SA-02, SA-03) | OQ-01, LC-32 OPEN |
| The manager chooses every swap's minimum output | A manager, or whoever holds the key, can trade the fund's Unallocated Balance at any price inside a Mandate pool | OQ-04, DEC-002 |
| `createSpoke` trusts the manager for the Mandate it deploys on a spoke | The manager alone can deploy a spoke with rules other than the hub's at the same addresses; holders must compare `mandateHash()` | FF-OQ-1 |
| The bridge call's calldata is built by the adapter and only the target, the amount to arrive and the deadline are checked | Recipient and depositor inside the calldata rest on the adapter's code, pinned by codehash and deployed from the factory's pinned creation code | DEC-087, Q17-4 |
