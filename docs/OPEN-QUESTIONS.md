# Open questions and how the MVP code handles them

Nothing in this file is decided. Each item names the question id used in the specification repository, what is at
stake, the research recommendation, and **what the MVP code does meanwhile** (the conservative behaviour, behind a
parameter or an interface so the founder's answer slots in). The digest that follows was produced from
`docs/definicao-v2/26..31` and `17` of the specification repository at commit `96d44cc` (2026-09-25).

## Rulings of 2026-09-29 (founder, in chat; not yet DEC entries)

| Topic | Ruling | Code consequence |
|---|---|---|
| Adapters | Uniswap V4 on both chains plus Aave V3 supply-only on Arbitrum, per DEC-018/028 | No V3 adapter |
| Spoke pricing (Q57 b) | `IPriceSource`: Chainlink for WETH, 1:1 for USDG; other tokens need a reliable on-chain method derived from how Uniswap V4 prices them (to research) | `ChainlinkPriceSource` with fixed 1:1 tokens; adding a token is a new price source, never a Mandate change |
| Report lifetime (Q57 a / Q66 b) | Keep the research value (Robinhood 1,587 s plus one block); adjust later if complications appear | Mandate `maxReportAge` for Robinhood = 1587 + spoke block time |
| Fee split point (DEC-107, OQ-02/03) | At collection: the investor portion enters the accumulator, the manager portion goes into the manager's own fee vault, the protocol portion is transferred to the fee wallet immediately | Income index advances when collected income reaches the Core Vault (hub adapter operations forwarded, or spoke income bridged home as `Income`); `ManagerFeeVault` per fund holds the manager's tokens; protocol fees (slice and flow fee) transfer to the Protocol Recipient at each charge. **Handled in consolidation:** `feat(core-vault): split income fees at collection, drop recognition-time booking`. |
| Management fee (DEC-108, LC-144) | Paid at fund closure; 0 in the MVP | Mandate accepts only 0 |
| Hub-to-spoke instructions (feedback q2) | Same approach as reports (Wormhole in the other direction) later; MVP stays limited | Automatic unwinds on hub positions only |
| Across refund recognition (QA6) | Approved | Keyless per-send `TransitEscrow` |
| Pause / deprecate holder (Q17-2b) | Immutable guardian address is fine for now | `AdapterGuard` |

## MVP code stance, one line per open item

| Id | Question | MVP code behaviour |
|---|---|---|
| DEC-079 open | Uniswap V4 pools with hooks that charge on withdrawal (a third value outside principal/income) | MVP Mandate validation accepts only hookless pools (`hooks == address(0)`) |
| Q57 (b) | How spoke positions are priced into USDC on the hub (report value vs quantities priced with Chainlink) | Report carries a superset (quantities, ticks, liquidity, cumulative income counters); the hub prices through `IPriceSource` with a Chainlink implementation for WETH and 1:1 for USDG (fixed tokens configured with their decimals); a feed older than its own `maxPriceAge(token)` reverts mints. **Handled in consolidation:** `feat(price-source): maxPriceAge per token`. |
| Q57 (c) | Who pays VAA delivery gas and how it is reimbursed | Not implemented; delivery is permissionless and unpaid; Operating Cash bucket exists |
| Q57 (d) | Variation band on accepted report values (2% proposed) | Not enforced; parameter slot reserved on the receiver, default disabled |
| Q66 | Cadence and the exact report lifetime parameter per spoke | `maxReportAge` per spoke in the Mandate, no round concept; recommended Robinhood value 1,587 s plus one block |
| Q58 | Share transferability | Transfers, approvals and permit disabled (DEC-004); per-address state kept in one copyable block |
| Q59 | Share token name/symbol pattern | Research reading D in the Fund Factory: symbol `PP-{n}`, name `Pool Party Fund {n}`, `n = NUMBER_OFFSET + creation count` (first fund `NUMBER_OFFSET + 1`), an immutable `NUMBER_OFFSET` per factory (Arbitrum 0, Robinhood 1,000,000), `isFund(coreVault)` and `fundByNumber(n)`, no manager text; `fundId = keccak256(abi.encode(hubChainId, factory, n, manager))` (the Manager bound into the id, not the name, so only the Manager's key reaches the fund's addresses: FF-OQ-1). The symbol stays within 11 characters up to `n` = 99,999,999 (not enforced) |
| Q60 | Income accumulator mechanism (when the index advances) | Per-token Q128 index with per-holder checkpoint; advances only when collected income reaches the Core Vault (ruling 2026-09-29): `receiveCollectedIncome` from the hub Spoke Vault and matched spoke-to-hub Income arrivals; reports' cumulative counters are informational. **Handled in consolidation:** `feat(core-vault): split income fees at collection, drop recognition-time booking`. |
| LC-100 / LC-77 | How much Attributed Income is payable now when part sits uncollected on a spoke | Income Withdrawal pays `min(owed, collected balance on the hub)` |
| LC-142 / LC-143 / LC-144 / LC-57 | Fee registry writer and caps, flow fee on payouts, management fee recipient, fee caps | Flow fee applied on deposit and on both payout modes, never on Income Withdrawal; registry writer is `Ownable2Step` owner; management fee accepted only as 0; caps exposed as constants with the proposed values |
| DEC-107 ambiguity | Fee at collection vs index at recognition | Ruled 2026-09-29: both at collection. Fee and slice are split when collected income reaches the Core Vault and transferred at once (slice to the Protocol Recipient, the rest to the `ManagerFeeVault`). **Handled in consolidation:** `feat(core-vault): split income fees at collection, drop recognition-time booking`. |
| LC-45 / LC-141 | Who bears the market cost of a leaver's unwound slice | Fund bears it (single consolidated Share Price per DEC-105); flagged |
| QB11 / QB10 | Number of transit states; the window between attested expiry and recognized refund | Four states mirroring DEC-066; the amount stays in Share Assets until the refund is recognized |
| QA6 | How the hub recognizes an Across refund | Per-send keyless `TransitEscrow` clone as depositor |
| QA19 | Max bridge fee per send | Mandate parameter `maxBridgeFeeBps` |
| Q17-2a/2b, LC-26, LC-121 | Who triggers pause and `deprecated`, where the flag lives, deprecated-position timing | Pause and deprecate are booleans on the adapter set by an immutable `guardian` address passed at construction; entry verbs check them, exit verbs never do |
| Q17-4 | Whether the Mandate pins the adapter codehash | Codehash stored next to the address at creation and revalidated on each call |
| Q17-5 / LC-120 | Who adds Collectors | Collectors out of scope for the buildathon |
| Feedback q2 | Hub-to-spoke unwind instruction proof | Automatic unwind limited to hub positions in the MVP; spoke unwinds are manager-driven |
| Erratum 22 | Protocol floor under the first-deposit minimum | No floor; Mandate value only |
| DEC-105 reading | Whether every spoke or only the unwound spoke needs a post-unwind report | Only the unwound spoke |
| Q57 reading | Whether a stale report may block an idle-paid payout | Idle-paid payouts use the last accepted report even if past its lifetime; mints revert |
| OQ-01 (DEC-080) | Across passes no depositor to `handleV3AcrossMessage`, so a stranger can bridge dust with a valid-looking message | Hub: an arrival is credited only up to what an accepted report of the origin spoke listed for that id, and by the kind the report carries, never the message's claim; anything else is held apart in `unmatchedArrivals` for good, never swept. Spoke: every well-formed arrival is credited; Principal arrivals are reported per id at their credited total (ids of 1 USDG or more, plus `cumulativeReceived`), Income arrivals are not tracked per id (the hub only sends Principal). The hub confirms an id it sent only when the listed total reaches the `amountToArrive` it expects (a stranger's listing of a public transit id below it confirms nothing) and deducts the rest as unknown value. **Handled in consolidation:** `feat(report-codec): TransferKind on inFlightToHub entries, payload version 2`; `fix(core-vault-logic): confirm a hub-to-spoke arrival only at or above its amountToArrive (OQ-09, OQ-01)`; `fix(spoke-vault): count and list only Principal arrivals per transit id (OQ-09, OQ-01, DEC-085)`. |
| OQ-02 / OQ-03 (Q60, DEC-107) | When income is recognized, and fee-at-collection vs index-at-recognition | Ruled 2026-09-29: both at collection. The index advances only when collected income reaches the Core Vault; uncollected income stays in its own bucket (DEC-092) and only informs Gross Assets. Reports carry cumulative income for information; `recognizeHubIncome`, `payOwedFees` and the owed-fee views are removed. **Handled in consolidation:** `feat(core-vault): split income fees at collection, drop recognition-time booking`. |
| OQ-04 (swap verb) | Whether a swap is an entry or exit verb, and who bears its Market Costs | `swapExactInput` exists on adapters and vaults, manager only; blocked when deprecated, not when paused; Market Costs stay LC-45/LC-141 |
| OQ-05 / OQ-06 (LC-143) | Flow fee base on deposit (offered amount vs amount spent) and rounding of bps fees | Fee on the offered amount, rounded down; the remainder left by whole-share rounding stays in the wallet |
| OQ-07 (DEC-060) | Standard Payout claim before the term ends when the reserve already covers it | Claim allowed only after the term ends |
| OQ-08 | Whether a fund must have a Spoke Chain | Hub-only funds accepted |
| OQ-09 (QB11) | Retention of arrivals on the spoke; hub-bound transit past its deadline with no refund seen | The window serves liveness; value rests on the hub's ledger, which confirms an id only at or above the amount it expects to arrive (and takes a post-deadline report listing the id below it as proof of non-arrival). The report lists the last 256 arrival ids whose credited total reached 1e6 base units (smaller arrivals are credited but not listed); the hub accepts a report's silence as proof of non-arrival only while it lists fewer than 256 ids, else only the deadline plus report lifetime path. A hub-bound transit leaves the spoke's `inFlightToHub` once its refund is recognized or `fillDeadline + maxReportAge` has passed (presumed filled; a later refund is still recognized). (Reconciled with the code: the earlier "until the hub confirms" wording needs hub-to-spoke messaging.) A hub-to-spoke transit evicted from the window before an accepted report lists it is never confirmed: it stays in In-flight Value and holds its Spoke Cap until its expiry is attested through the deadline plus report lifetime path (liveness cost), and it is counted once only because the hub deducts unknown-origin value (`cumulativeReceived` above what it confirmed) from the fund total rather than clamping it per spoke, so the deduction follows the value home (DEC-080, DEC-104; the earlier "never value" wording was disproved by the consolidation verifier). **Handled in consolidation:** `fix(spoke-vault, core-vault): 256-id arrival window, listing minimum, no proof from a full window`; `fix(core-vault-logic): deduct unknown-origin spoke value from the fund total, not clamped per spoke`; `fix(core-vault-logic): confirm a hub-to-spoke arrival only at or above its amountToArrive (OQ-09, OQ-01)`. |
| OQ-10 (Q57) | Payout behaviour on a stale price feed | Mints revert on a stale report or price and on any failing dependency; payouts use the last price and never revert on age, and on a reverting price source or hub report they fall back to the last known valuation kept from the last successful deposit or payout, with an event; the last hub value follows the USDC moved between Idle and the hub Spoke Vault since. **Handled in consolidation:** `fix(core-vault): payout liveness with last known valuation fallback`; `fix(core-vault): payout fallback hub value follows Idle moves since the last valuation`. |
| OQ-11 (LC-142) | Protocol slice cap and writer | Cap 5,000 bps, only at or below the default; writer is the registry owner (`Ownable2Step`) |
| OQ-12 (DEC-079) | Hooked V4 pools | Adapter `poolTokens` reverts for hooked pools; the Spoke Vault checks every Mandate pool at creation |
| OQ-13 (Q17-4) | Whether the adapter codehash belongs in `mandateHash` | Pinned in the vault at creation, not in the Mandate hash |
| DEC-066 B1 | Spoke Cap must count the pending return leg | `spokeCapUsage` returns the pending return leg (Principal and Income) as its own value `inFlightToHub`, next to hub-to-spoke sends `inFlightSent`; the send check adds both. **Handled in consolidation:** `feat(core-vault): ICoreVault views and explicit return leg in spokeCapUsage`. |
| DEC-061 residual | Share Price when every share was burned but Share Assets remain (dust, late refund) | Next mint prices at 1.00 and captures the residual; flagged for a ruling |
| DEC-095 | Minimum Standard Payout term (a zero term makes it a fee-free Instant Payout) | No minimum enforced; flagged |
| DEC-069 | Whether the unwind order must cover every pool | Not enforced; a pool outside the order can only be unwound manually |
| DEC-027 / DEC-044 | Manager full-unwind trigger above 50% (base open) | No hook in the MVP; flagged |
| DEC-041 | Explicit "insufficient cash" state | Payer field on every expense event; `OperatingCashInsufficient` only when Free Idle cannot fund the whole top-up (cash stays unable to pay), never on a routine top-up. **Handled in consolidation:** `fix(core-vault): OperatingCashInsufficient only when the top-up falls short`. |
| Bridge custody | Whether a buggy immutable bridge adapter can misdirect funds | The vault holds the tokens, pins the bridge target at creation, approves exactly the input amount for one call built by the adapter, and requires the exact balance debit |
| CV-OQ-1 (DEC-085 vs DEC-092) | Whether a spoke-to-hub transfer in flight is Principal or Income | The report's `inFlightToHub` entries carry the kind (ReportCodec version 2): Principal in flight counts in Share Assets, Income does not; both count toward the Spoke Cap. **Handled in consolidation:** `feat(report-codec): TransferKind on inFlightToHub entries, payload version 2`. |
| CV-OQ-2 (Q60 spoke income tokens) | Spoke income in spoke-chain tokens can never be paid in kind on the hub | Spoke income reaches the hub as USDC: `swapCollectedIncome` turns non-base income into the spoke token inside the collected bucket, `sendToHub(..., Income, ...)` brings it home, and the fee split happens on arrival. **Handled in consolidation:** `feat(spoke-vault): swapCollectedIncome so spoke income reaches the hub as USDC`. |
| Payout liveness (DEC-021, DEC-056) | Whether a claim may revert while a valuation dependency fails | Never: last known valuation with an event (see OQ-10). **Handled in consolidation:** `fix(core-vault): payout liveness with last known valuation fallback`. |
| Linked libraries (DEC-022, DEC-054, DEC-058) | Whether the external linked libraries `CoreVaultLogic` and `SpokeCrossChainLib` are acceptable | Ratified: the only DELEGATECALL, into the fund's own immutable code; the factory deploys them once per chain (the Spoke Vault's at a chain-independent address) and pins them (docs/ARCHITECTURE.md §1.1). **Handled in consolidation:** `docs(spoke-vault, core-vault): disclose the linked-library DELEGATECALL boundary`. |
| CS-OQ-1 (DEC-014 vs ruling 2026-09-29) | Income generated in a position before a Shareholder's entry but collected after it | **OPEN, raised in consolidation.** Attributed at collection to the holders of that moment, so the entrant shares it (pinned by `test_DEC014_OPEN_incomeGeneratedBeforeEntryIsSharedWhenCollectedAfterIt`); income collected before the entry is not shared. Frequent collection narrows the window. |
| CS-OQ-2 (DEC-110 "settling accrued first") | What a manager-fee decrease settles when fees are charged only at collection | **OPEN, raised in consolidation.** Nothing accrues between collections, so the decrease applies from the next collection, including to income generated before it. |
| CS-OQ-3 (DEC-109 "no swap by the contract") | Spoke income swapped into the spoke token before the fee is taken | **OPEN, raised in consolidation.** The swap is a manager verb on income (its Market Costs are borne by the income, LC-45 / LC-141), and the fee on spoke income is then paid in USDC, not in the token the income was earned in. Hub income stays in kind. |
| CS-OQ-4 (payout fallback) | Value of a token that fails to price in a payout and was never priced before | **OPEN, raised in consolidation.** Valued at 0 (with `PriceFallback(token, 0)`), which lowers the Share Price for that claim; only reachable for a token that appeared after the last successful deposit or payout. |
| CS-OQ-5 (DEC-099 clock skew) | A spoke report timestamp ahead of the hub clock | **Assumption, raised in consolidation.** Tolerated up to one `maxReportAge` (counts as age 0), rejected beyond (`ReportFromFuture`), so a report is fresh for at most twice its lifetime. |
| CS-OQ-6 (OQ-09 listing minimum) | A hub-to-spoke send below 1e6 base units is never listed by the spoke | **OPEN, raised in consolidation.** Its expiry is attested only through the deadline plus report lifetime path and it stays `ExpiryAttested` in In-flight Value while the spoke counts it and the hub deducts it as unknown value from the fund total, so it is counted once, also after the spoke sends it home (`fix(core-vault-logic): deduct unknown-origin spoke value from the fund total, not clamped per spoke`); its Spoke Cap is released at that attestation. No minimum send is enforced. |
| FF-OQ-1 (DEC-001, DEC-054, DEC-086, DEC-087) | How a Spoke Chain knows that a `createSpoke` Mandate is the one the hub created | **Partly closed in the factory stage (verifier round 1).** The spoke cannot see the hub: `createSpoke(creationNumber, Mandate, SpokeParams)` derives `fundId` from `Mandate.hubChainId`, `creationNumber` and `Mandate.manager` (never from a caller-given id; `SpokeOnHubChain` when the hub is this chain), and requires `msg.sender == Mandate.manager`, a Mandate hashing to the `mandateHash` passed in (copied from the hub's `FundCreated`), and every Mandate address equal to the fund's prediction. Because the Manager is bound into `fundId`, nobody but the Manager can create a contract at any of the fund's addresses, so a stranger can no longer squat a real fund's Spoke Vault. Residual: the Manager alone could create their own spoke with a Mandate other than the hub's (same addresses, other rules); investors and the hub operator check that the spoke vault's `mandateHash()` equals the hub's (docs/DEPLOYMENT.md). Full fix candidate: the hub factory publishes `FundCreated` through Wormhole and the spoke factory verifies the VAA (same mechanism as reports, Q57) |
| FF-OQ-2 (DEC-054) | "Same factory bytecode at the same address on every chain through the deterministic deployer" with per-chain immutable wiring | **Assumption, raised in the factory stage.** Not possible as stated (immutables change the creation code, hence the CREATE2 address). `Create3Deployer` (no constructor arguments) goes through the deterministic deployer at one address everywhere and CREATE3-deploys the factory with a caller-bound salt: same operator and salt, same factory address, per-chain wiring |
| FF-OQ-3 (DEC-087) | Which vault owns the hub Across adapter | **Reading, raised in the factory stage.** The Core Vault, not the hub Spoke Vault: the Core Vault executes hub-to-spoke sends (`sendToSpoke`) and pins the adapter's target; the adapter NatSpec says "Core Vault on the hub". The Uniswap V4 and Aave adapters belong to the hub Spoke Vault; a spoke's Across adapter to its Spoke Vault |
| FF-OQ-4 (Q17-4, DEC-001, DEC-058) | Whether a factory-created Mandate may list adapters the factory did not deploy | **Conservative stance, raised in the factory stage.** No: every Mandate adapter, bridge adapter and Spoke Vault, on every chain, must be the fund's CREATE3 prediction (`UnexpectedAdapter`, `UnexpectedBridgeAdapter`, `SpokeVaultMismatch`), so a fund id can only name code the factory deploys from its pinned creation code. Adding an adapter kind means new creation code in a new factory |
| FF-OQ-5 (Q59) | Two creators racing for the same fund number | **Assumption, raised in the factory stage.** A Mandate is built for a predicted `n`; if another fund takes `n` first, `createFund` reverts `CreationNumberTaken` and the manager predicts again (the loser pays only a reverted transaction; a front-runner pays for a whole fund) |



## Handled in consolidation (2026-09-29)

Review-log items (docs/REVIEW-LOG-2026-09-29.md) closed in the consolidation stage, with the commit subject that
closes each. Open questions that remain open keep their row above.

| Item | Commit subject |
|---|---|
| Fee split at collection, `ManagerFeeVault`, `CollectedIncomeReceived` with real fees (ruling 2026-09-29, CV finding) | `feat(manager-fee-vault): per-fund ManagerFeeVault for the manager fee portion`; `feat(core-vault): split income fees at collection, drop recognition-time booking` |
| CV-OQ-2 spoke income tokens | `feat(spoke-vault): swapCollectedIncome so spoke income reaches the hub as USDC` |
| CV-OQ-1, DEC-092 return-leg kind, kind relabelling by a stranger (CV minor) | `feat(report-codec): TransferKind on inFlightToHub entries, payload version 2` |
| Payout liveness (CV major) | `fix(core-vault): payout liveness with last known valuation fallback`; `fix(core-vault): payout fallback hub value follows Idle moves since the last valuation` (consolidation verifier major) |
| Per-feed `maxPriceAge` (report-receiver request, OQ-10) | `feat(price-source): maxPriceAge per token` |
| `fundId()` in IValueReportReceiver | `feat(report-receiver): expose fundId in IValueReportReceiver` |
| `unmatchedArrivals`, `incomeState` in ICoreVault; `spokeCapUsage` return leg (DEC-066 B1) | `feat(core-vault): ICoreVault views and explicit return leg in spokeCapUsage` |
| ICoreVaultExtensions folded into ICoreVault | `refactor(core-vault): fold ICoreVaultExtensions into ICoreVault` |
| Across exclusivityParameter, quoteTimestamp, `enabledDepositRoutes`, InvalidParty NatSpec | `docs(bridge-interfaces): Across exclusivityParameter, quote time and InvalidParty NatSpec` |
| OQ-09 arrival window dust eviction (spoke major), attestExpiry proof from a flushed window (CV minor) | `fix(spoke-vault, core-vault): 256-id arrival window, listing minimum, no proof from a full window` |
| Unconfirmed hub-to-spoke transit counted twice once the spoke sends it home (consolidation verifier blocking, OQ-09, CS-OQ-6) | `fix(core-vault-logic): deduct unknown-origin spoke value from the fund total, not clamped per spoke` |
| Stranger listing of a real transit id below its amount confirmed it and stranded the expiry refund (consolidation verifier round 2 blocking, OQ-09, OQ-01) | `fix(core-vault-logic): confirm a hub-to-spoke arrival only at or above its amountToArrive (OQ-09, OQ-01)`; `fix(spoke-vault): count and list only Principal arrivals per transit id (OQ-09, OQ-01, DEC-085)` |
| DEC-041 OperatingCashInsufficient (CV minor) | `fix(core-vault): OperatingCashInsufficient only when the top-up falls short` |
| Across test ids citing DEC-085 | `test(across-adapter): cite DEC-087 for the InvalidAmounts rule` |
| TransitEscrow zero-address initialize | `fix(transit-escrow): reject a zero vault or token at initialize` |
| Aave ledger clamp, CEI in close, `lastIndex` and rounding NatSpec | `fix(aave-adapter): ledger underflow reverts, open cleared before exit, NatSpec` |
| V4 swap surplus, settle return, cumulativeIncome cost, custody citations, test ids | `fix(v4-adapter): hand back swap surplus, named settle mismatch, NatSpec and test ids` |
| Receiver unbounded future timestamp | `fix(report-receiver): bound a future report timestamp to one report lifetime` |
| Fixed-token decimals, feed decimals assumption | `fix(price-source): fixed 1:1 tokens take their decimals; document feed decimals` |
| ManagerRegistry `renounceOwnership` | `fix(manager-registry): renounceOwnership reverts` |
| Unwind proceeds from a balance-derived amount (CV minor) | `fix(core-vault): unwind proceeds reach Idle only through returnToIdle` |
| Spoke arrival top-up, refund CEI (spoke minors) | `fix(spoke-vault): arrivals top up Operating Cash; refund state before escrow release` |
| Spoke collected income and Operating Cash missing from the report (spoke minor, DEC-098) | `feat(report-codec): spoke collected income and Operating Cash in the report` |
| Across route list gone, report delivery gas (docs) | `docs(integrations): Across route liveness and report delivery gas` |
| `recognizeRefund` preconditions in ICoreVault | `docs(core-vault): state recognizeRefund's preconditions in ICoreVault` |
| Linked-library DELEGATECALL boundary (CV and spoke majors, ratified) | `docs(spoke-vault, core-vault): disclose the linked-library DELEGATECALL boundary` |

---

# Pool Party v2: open questions, fee model and canonical naming (English digest)

**Source repo:** `/Users/rafaelzochling/gitrepos/external/PoolParty_SCs_v2` at commit `96d44cc` (merge of PR #7, Lot 13).
All paths below are relative to that repo. `DEC:NNNN` = `docs/definicao-v2/01-RESPOSTAS-E-DECISOES.md` line NNNN;
`CTX:NNN` = `CONTEXT.md` line NNN (glossary dated 2026-09-25); `Dnn §x` = `docs/definicao-v2/nn-*.md` section.

**Status convention used in this digest.**
- **DECIDED** = a founder decision (DEC-nnn) in the register. The register says later decisions prevail over earlier ones.
- **RECOMMENDED** = research recommendation in the source docs; the founder has not answered.
- **OPEN** = no founder answer. The last register entry is Lot 13, 2026-09-25 (DEC-106..110). No later answer exists
  in the repo, so every question below that is not tied to a DEC is **OPEN as of 2026-09-25**.
- Portuguese pseudocode identifiers from the source are quoted in backticks with an English gloss; the gloss is mine,
  not a canonical name.

---

## Canonical identifiers

**Where the confirmed list lives.** Doc 14 (`14-NOMES-CANONICOS-EN-2026-09-16.md`) is explicitly *support material,
nothing in it is decided* (D14:11-12). The confirmed names are in doc 15 (`15-REVISAO-DE-TERMOS-EN-2026-09-16.md`,
"Termos confirmados" ("confirmed terms") table at :34, and the QV1-QV3 answers table at :268-292) and, consolidated, in the
`_Canonical_` lines of `CONTEXT.md`. Several doc 14 recommendations were overridden by the founder (`Satellite*` became
`Spoke*`, `Fund Vault` became `Core Vault`, `Fulfillment` became `Payout`, `Toll` became `Payout Fee`, `Attributed
Revenue` became `Attributed Income`, `Revenue Withdrawal` became `Income Withdrawal`, `Reinvest` disappeared with
DEC-064 "no compound"). The table uses the confirmed names.

"Forbidden" column: the source's `_Avoid_` list rendered in English, restricted to what matters for identifiers.
Where the source says explicitly "in identifiers", it is marked **(id)**.

| Concept | Canonical English name | Words forbidden / to avoid in identifiers | Source |
|---|---|---|---|
| Role that creates the fund and operates it within the mandate | `Manager` | owner of the fund as a synonym, curator, operator (doc 14 proposed `onlyManager`, `error NotManager()`, indexed `manager` in operation events) | CTX:30-31; D15 term 1; D14:35 |
| AI agent holding the manager key | `Autonomous Manager` | must not become a contract identifier at all (no `onlyAutonomousManager`, no `isAutonomous`: "for the contract there is no difference") | CTX:28-29, CTX:38-39; D14:36 (research obligation) |
| Investor (one per address) | `Shareholder` | user, depositor as investor synonym; `Depositor` and `Requester` roles were removed (identity = Shareholder; depositing is an action, having an open request is a state, DEC-048) | CTX:47-48; D15 terms 3, 5; DEC:1104 |
| Product brand / companies | `Pool Party`; `Pool Party Labs`, `Yieldbay`; API brand `Pool Party Infrastructure` | "protocol" as synonym of a company; none of these become contract identifiers | CTX:55-64; DEC-076 item 3 |
| Fund | `Fund` | pool, strategy, vault | CTX:72-73 |
| Hub-chain fund contract (custody, mint/burn, pays withdrawals, never talks to adapters) | `Core Vault` | unqualified vault, "main vault" | CTX:80-81; D15 term 8 |
| Per-chain fund account (also exists on the Hub, DEC-054; talks to adapters and collectors) | `Spoke Vault` | satellite, sub-fund, raw address balance as a synonym of its internal registry | CTX:89-90; D15 term 9 |
| Mandate | `Mandate`, identified by `mandateHash` (`mandateId` removed) | policy, configuration | CTX:102-103; D15:72 |
| Home chain | `Hub Chain` | bare `hub` (collides with Across `HubPool`), main chain, `Base Chain` | CTX:140-141; D15 terms 11-12 |
| Other chain | `Spoke Chain` | satellite, secondary chain | CTX:147-148 |
| Executes operations on an external protocol; unit of pause | `Adapter` | plugin, connector, strategy | CTX:165-166; D15 terms 13-14 |
| Only receives value (campaign reward, airdrop) | `Collector` | adapter as synonym, "claim adapter"; garbage collector must never be a bare "collector" | CTX:175-176, CTX:313 |
| Position whose USDC value is read without a swap (e.g. aUSDC) | `Exact-Value Position` | cash-equivalent, "stable position" | CTX:185-186; DEC-076 item 4 |
| Verification seal | `Verified Wallet` | badge; must have no on-chain registry and no identifier on the execution path (DEC-050) | CTX:202-203 |
| Share (ERC-20, 18 decimals, whole units only) | `Share` | fraction of share | CTX:213-214; DEC-091 |
| Everything that backs shares | `Share Assets` | NAV unqualified, total assets, TVL (doc 14 proposed forbidding `totalAssets()` in the fund contract) | CTX:221-222; D14:107 |
| Share Assets / shares | `Share Price` | NAV per share, "quote" | CTX:229-230 |
| Realized unwind proceeds / shares burned (recorded measure only, DEC-105 item 4) | `Settlement Price`, identifier "always qualified by the withdrawal" | **(id)** `settlement` unqualified; liquidation price | CTX:237-239; DEC:2367; pending, see rule R1 |
| Total fund value (Share Assets + Operating Cash + attributed income + uncollected external incentive) | `Gross Assets` | TVL, total assets, NAV unqualified, AUM in contract rules (AUM is a commercial label only, DEC-103) | CTX:247-248; DEC:2914 |
| Money in the Core Vault not yet sent to any Spoke Vault (the total) | `Idle` | buffer, cash, idle meaning free idle | CTX:256-257 |
| Part of Idle reserved for Standard Payouts | `Payout Reserve` | reserve alone, committed cash, minimum cash | CTX:265-266; DEC-072 |
| Part of Idle the manager may allocate | `Free Idle` | unreserved idle, "available" unqualified | CTX:274-275; DEC-072 |
| Arrived in a Spoke Vault, not yet a position | `Unallocated Balance` | spoke idle, hub idle | CTX:282-283 |
| Per-network operating budget (Payout Fee + top-ups) | `Operating Cash` | **(id)** `treasury`; gas vault | CTX:292-293; DEC:2106 |
| Pool Party Labs address (garbage-collector sweeps; protocol fees, to confirm) | `Protocol Recipient` | **(id)** `treasury`, `feeRecipient` (whether "fee recipient" leaves the avoid list is LC-132) | CTX:303-307; DEC:2108 |
| Income already owned by specific shareholders | `Attributed Income` | **(id)** `yield`, `revenue`, `accrued`; dividend | CTX:321-322; DEC:2036 |
| Value sent between chains, not yet confirmed/refunded | `In-flight Value` | "on the way" | CTX:333-334 |
| Max principal per spoke (checked only on send) | `Spoke Cap` | bare `cap`, exposure limit | CTX:344-345 |
| Swap fee, price impact, slippage | `Market Costs` | execution cost, swap cost | CTX:352-353 |
| Transport and gas costs | `Network Costs` | execution cost, fixed cost | CTX:360-361 |
| Cost paid by the fund, always with funding source | `Operating Expense` | **(id)** `cost` in the identifiers of this expense | CTX:368-369; DEC-075 |
| Investor's withdrawal request (gross USDC, not cancelable) | `Payout Request` | withdrawal request, redemption | CTX:380-381; DEC-074 |
| Process that closes a request (burn + pay) | `Payout`; `Partial Payout`; investor call `claim` as `claimPayout`; events `PayoutExecuted`, `PartialPayoutExecuted` | **(id)** `fulfillment`, `settlement` as process name, `liquidation`; `withdrawal` for an exit that burns shares | CTX:392-393; DEC:2061, DEC:2064 |
| Express withdrawal (fee, 1 h target) | `Instant Payout` | express; instant as a guarantee | CTX:406-407; DEC-075 |
| Scheduled withdrawal (no fee, 72 h) | `Standard Payout` | scheduled, queued | CTX:414-415; DEC-075 |
| Toll on Instant Payout (2%, immutable, to Operating Cash) | `Payout Fee` | toll, exit fee | CTX:422-423; DEC-075 |
| Taking attributed income out, no share burn | `Income Withdrawal` | `claim` as its synonym; compound, reinvest flag; `payout` for an income exit | CTX:429-430; DEC-073 |
| Converting positions to cash on the Hub | `Unwind` | position liquidation | CTX:441-442 |
| Execution plan | `Journal` | route unqualified, batch, intent | CTX:451-452 |
| Path moving value Hub <-> spoke (implemented as a bridge adapter) | `Transport Route` | bare `route`, bridge, "bridge adapter" meaning the messaging channel | CTX:460-461 |
| Manager fee, protocol slice, flow fee, manager registry, supported network | **no canonical English name yet** (VC-45, LC-142, LC-118). Descriptive glosses used in this digest only | manager fee: loose "fee", performance on share price, fee in shares, high-water mark; protocol slice: "revenue share recorded in the mandate"; flow fee: toll, "entry fee that stays in the fund" | CTX:107-135, CTX:150-156 |

### Identifier-level rules

**Decided.**

- **R1. `liquidation`, `settlement`, `fulfillment` are out of fund identifiers** (DEC-074 item 5, DEC:2064). Exception
  in tension: DEC-084 named the conversion price `Settlement Price` (DEC:2367). The register (errata item 21,
  DEC:3094) says the DEC-084 name stands and the new wording of the ban is only a *proposal* until the founder answers
  the counter-argument. Current proposed wording (CTX:237-239, CTX:393-399): `settlement` allowed only inside the
  withdrawal-qualified price identifier, never unqualified and never as the name of the process; `liquidation` never.
  The exact identifier form (e.g. whether `payoutSettlementPrice`) is **not given in the source**.
- **R2. `accrued` is out of identifiers** (collides with Morpho) (DEC-073, DEC:2036).
- **R3. `yield` and `revenue` are not used in identifiers** for attributed income (CTX:322). Doc 14's
  `attributedRevenue` / `withdrawRevenue()` are superseded.
- **R4. `cost` is not used in identifiers of the `Operating Expense`** (CTX:369). `Market Costs` / `Network Costs` keep "Costs".
- **R5. `treasury` is out of identifiers; `feeRecipient` is out** (DEC-076, DEC:2106, DEC:2108). LC-132 may revisit
  "fee recipient" now that the protocol receives fees (DEC-106).
- **R6. "withdrawal" names only the income exit without burning shares; "payout" names only exits that burn shares**
  (DEC-073, DEC-074 item 3).
- **R7. `claim` = the investor call that executes a Payout (`claimPayout`)** (DEC-074 item 4). NatSpec must say that,
  unlike ERC-7540, this claim executes the missing unwind and pays in the same transaction. `claim` is not a synonym
  for Income Withdrawal (CTX:430). Note: doc 14 had recommended reserving `claim` for third-party incentive
  collection only; DEC-074 overrides that for `claimPayout`.
- **R8. No compound in the contracts** (DEC-064, DEC:1692): no compound/reinvest function, flag or identifier.
- **R9. Exit family names:** `Instant Payout`, `Standard Payout`, `Payout Fee`, `Payout Reserve`, `Operating Expense`
  (DEC-075). Do not use express/scheduled/queued/toll/exit fee.

**Research recommendations (doc 14, not decided, still consistent with the glossary).**

- Never a bare `vault`, `route`, `cap`, `hub`; always qualified (CTX avoid lines; D15 terms 11-12, 17, 19).
- `position` always qualified inside adapters (Uniswap collision) (D14:139-142).
- `idle` is an internally credited storage variable; never computed from `balanceOf` (D14:69; consistent with DEC-080).
- No `totalAssets()` in the fund contract, because the ERC-4626 name would lie about the set (D14:107).
- The share-price view returns the pair `(shareAssets, totalShares)`, never a truncated decimal; events carry
  numerator and denominator (D14:108).
- Four cross-cutting event obligations (D14:238-246): (1) every event that mints, burns or publishes a price carries
  the measurement-base identifier, with numerator and denominator; (2) every expense event carries the payer
  (order: Payout Fee, then Operating Cash, then Share Assets); (3) every exit carries the modality enum (now
  Instant/Standard); (4) every cross-chain event carries the Hub chain id, the destination chain and the transfer id.
  The enum values doc 14 proposed for (1) (`SHARE_ASSETS`, `CONVERSION_PRICE`, `AUM`, `NONE`) predate DEC-084 and
  DEC-103 (conversion price is now `Settlement Price`; AUM is a commercial label only), so the enum value names are
  **ambiguous in source**.
- Observation (mine, not in source): doc 14 sketched `requestWithdrawal(uint256 grossAssets)`. Since DEC-098 `Gross
  Assets` names the fund total, a parameter called `grossAssets` for the requested gross USDC amount would collide.

---

## Q57 · Report finalized age, spoke pricing and VAA-delivery gas

**What is at stake.** Under finalized consistency (DEC-093) every Robinhood report reaches the Hub 15-20 min old
(and up to ~26 min in the full history), and with DEC-067/DEC-105 that stale value prices every mint and every Payout.
The founder also asked who pays the gas to deliver the VAA.

**Alternatives** (D30 §4, §6, §9).
- (a) Report life: **decided by DEC-099** (time to finality + 1 block); cadence and parameter value moved to Q66 (b).
- (b) Price. 1: accept the report's value, bounded only by the Spoke Cap.
- (b) Price. 2: report carries an inventory (pool, ticks, liquidity per position; principal balances; revenue counters); the Hub prices it with Chainlink ETH/USD on Arbitrum at operation time.
- (b) Price. 2b: 2 plus the Hub LP priced by the same feed (one price per asset; changes the source DEC-067 fixed).
- (b) Price. 3: conservative two-sided (mint at the higher, pay at the lower of two values).
- (b) Price. 4: oracle gate (mint open only if ETH moved < X% since report; price stays the report's).
- (b) Price. 5: instant consistency (rejected by DEC-093: 17.5-18.5 min reorg window).
- (b) Price. 6: alternative 1, but a Standard Payout burn uses the first report whose origin block is after the claim.
- (c) Reimbursement: (i) measured in-transaction, paid in USDC by Arbitrum Operating Cash with caps; (ii) none, the API pays; (iii) Wormhole Executor only (prepaid at origin, 9-10x the cost).
- (d) Variation band: (i) 2% vs previous report; (ii) with alternative 2, anomaly lock "spoke-computed value vs Chainlink at the same instant"; (iii) both.

**Research recommendation.** (b) alternative 2 with variant 2b, alternative 4 as anomaly lock, alternative 3 as the
payment rule when the feed fails (stale feed / sequencer down / anomaly: mint reverts, every Payout uses the lower
of the two values and never reverts); MVP pools restricted to assets with a push feed on the Hub (WETH, USDG; NVDA,
TSLA, AAPL only with caveats; HOOD has none). If the founder refuses an oracle in price: **1 + 6 with a low Spoke
Cap**, not 1 alone. (c) (i) plus a top-up trigger inside the report path, a floor sized by cadence, and a top-up cap
equal to the daily reimbursement cap (33.75 USDC/day at one report per epoch). (d) (iii) with alternative 2; (i) with
alternative 1. Strongest counter: alternative 2 puts Chainlink into the price of every Payout, which DEC-032 refused
on exit; 1 + 6 with a 10% cap bounds the patient actor at 67.7 per 100,000 per cycle (entry leg only).

**Founder.** Partly decided: DEC-093, DEC-094, DEC-099 (and DEC-105 for unwind payouts). Parts (b), (c), (d) are
**OPEN as of 2026-09-25**. DEC-106 research note: the 0.25% flow fee on entry and exit shrinks the patient actor's
gain under alternative 1 (580 -> ~80 per 100,000 with perfect foresight; ~258 -> negative without); the
dilution-protection entry fee that stays in the fund was not answered and returns with Q57.

**What an implementer must do now.** Details and numbers in the "Report age and gas (Q57)" section below.
- Build the receiver to the decided rules: finalized consistency only, permissionless delivery, strictly increasing
  sequence per (emitter chain, emitter address) rejecting replays and out-of-order VAAs, emitter must equal the
  mandate's registered Spoke Vault (Robinhood Wormhole chain id 72).
- Report life is a **per-supported-network parameter** (`T_fin` + 1 block), not a code constant; the Robinhood value is
  open (research: 1,587 s).
- Make the payload a superset that serves alternatives 1, 2 and 6: spoke-computed value at the report block; per
  position pool, `tickLower`, `tickUpper`, `liquidity`; principal-only unallocated balance per token; monotonic
  cumulative revenue counter per revenue token; `cumulativeReceived` and `cumulativeSentHome`. Keep spoke valuation
  behind one internal function; after deploy, switching alternative 1 <-> 2 needs a new factory version plus opt-in
  migration (DEC-022).
- Admission never reverts because a revenue counter regressed, and never depends on reimbursement succeeding.
- Implement reimbursement as a separable leg after admission (decision (c) pending).
- DEC-105: for a Payout with unwind, accept only a report with sequence after the unwind block on that spoke; burn at
  the consolidated NAV; `Settlement Price` is only recorded in the event.
- No report-validity predicate may block a Payout paid by idle; mint closes when the report is past its life.

---

## Q58 · Share transferability

**What is at stake.** DEC-091 made the share a standard ERC-20 (18 decimals, whole-share check at mint and burn), and
every per-address rule (income attribution, campaign eligibility, open Payout Request, manager minimum, 50% trigger,
whole shares) assumes balances change only at mint and burn; any transfer is a third mutation point that needs hooks.

**Alternatives** (D26 §5).
- A: never transferable; `transfer`, `transferFrom`, `approve`, `permit` revert; `allowance` returns 0.
- B: free ERC-20 (contradicts DEC-014, DEC-024, DEC-044, DEC-045, DEC-091; in practice becomes C).
- C: transferable with settlement hooks (whole-share check, manager blocked, open-request lock, settle both sides, campaign checkpoint, 100% rule).
- D: C plus a recipient allowlist (new list-writing power; conflicts with DEC-049/050/001).
- E1: whole-position portability to a never-used address, two steps (`iniciarMigracao` / `aceitarMigracao`, "initiate/accept migration"), no settlement needed.
- E2: recovery by an authority (only fix for a lost key; conflicts with DEC-049, DEC-050, DEC-052).

**Research recommendation.** A in the MVP, with E1 as the only exception if the founder wants mobility from day one;
B, C, D, E2 not in the MVP. Q58b: `approve` and `permit` revert (yes). Q58c (if E1): open request blocks migration;
manager address excluded; destination must never have been a Shareholder; campaign eligibility moves with the
position. Key findings: whole-share check makes AMM/lending composability mostly unusable anyway (only integrators
that fix share amounts in whole units pass); partial transfer collides with DEC-092 because the accumulator is only as
fresh as the last recognition (15-20 min for spoke revenue). Strongest counter: E1 is a disguised transfer of whole
positions and adds a value-moving path to the immutable core for an unrequested need; then "A pure".

**Founder.** Q58 **OPEN as of 2026-09-25**. What binds today is **DEC-004 (DECIDED 2026-09-09)**: no ordinary share
transfer to another wallet in the first implementation, and no delegated transfer function may bypass it; recovery
or wallet-change exceptions were left open by DEC-004 itself.

**What an implementer must do now.**
- Share token: `transfer`, `transferFrom`, `approve`, `permit` revert with a custom error; `allowance` returns 0; do
  not inherit `ERC20Permit`. `Transfer` events only from `address(0)` (mint) and to `address(0)` (burn).
- Put the whole-share check (`amount % 1e18 == 0`) in the two internal mint/burn functions only (DEC-091 item 3); a
  transfer path, if it ever exists, is "the third place".
- Keep all per-address accounting state in one copyable block per address so E1 can be a copy later: shares, and per
  revenue token the checkpoint and owed amount, plus the campaign-eligibility pair: 2k + 3 fields (9 with k = 3).
  Doc 26 also reserved two HWM fields for "Q62 D"; DEC-107 chose Q62 B (no high-water mark), so those two fields are
  no longer needed.

---

## Q59 · Token name and symbol pattern per fund

**What is at stake.** The founder proposed `PP_{{FUNDIDHASH}}` (DEC-091 answer). Name/symbol are not identity (the
address is), but whatever the fund creator can choose can be used to impersonate another fund created through the
official permissionless factory (DEC-001), and the Yieldbay seal has no on-chain registry (DEC-050).

**Alternatives** (D27 §6).
- A: `PP_{hash}` (founder's idea); k = 6 or 8 hex; unreadable; suffix forgeable if the source includes creator-chosen data (6 hex found in 11 s single-thread); 1% accidental collision at 9,292 funds with k = 8.
- B: `pp` + manager ticker, name "Pool Party: {fund name}"; readable; open to impersonation and name squatting; ticker enters `mandateHash`.
- C: `PP-{ticker}-{shorthash}`; 3-letter ticker to fit 11 chars; combines the downsides of A and B.
- D: `PP-{n}` with the factory's sequential number, name `Pool Party Fund {n}`; unique by construction, not choosable, resolvable via `fundByNumber(n)`; unreadable; exposes creation order.
- D2: D plus the manager's commercial name emitted only in the creation event (research: not in MVP).

**Research recommendation.** D: symbol `PP-{n}`, name `Pool Party Fund {n}`, `n` sequential per factory, built in the
view functions from an immutable number, hyphen not underscore, no chain suffix, an immutable `NUMBER_OFFSET` per
factory (disjoint ranges for future Hub chains), public `isFund(address)` and `fundByNumber(n)`, the manager's
commercial name only in the Yieldbay listing, D2 out of the MVP. Constraints derived: symbol <= 11 chars (MetaMask
legacy `wallet_watchAsset`), ASCII only, no manager text, immutable, not derived from anything mutable (the
`Operating Cash` floor is manager-editable, so a hash of the live mandate would drift). If A is chosen: hash of
(`chainid`, factory address, counter), k = 8, uniqueness check. Strongest counter: investors cannot tell funds apart in
their wallet without the frontend, and every curator-vault precedent lets the curator brand the token; then B with
hard rules.

**Founder.** **OPEN as of 2026-09-25** (LC-137).

**What an implementer must do now.**
- `decimals()` = 18. `name()` / `symbol()` immutable, no setter, computed in view from an immutable per-fund id
  set at construction/initialization; this works for both A and D (the two options that keep manager text out).
- Factory: keep a creation counter and `isFund(address)` now (needed in every alternative); add `fundByNumber(n)`
  if D. Do not put name/symbol inputs into `mandateHash` unless B or C is chosen.
- If `permit` ever exists, the EIP-712 domain name is fixed at construction, another reason to never mutate `name()`.

---

## Q60 · Per-share income accumulator: how the index advances

**What is at stake.** DEC-092 decided a separate bucket for uncollected income and a fee-growth-style direction, with
the founder's constraint of not reading all positions on every user operation; how often the index advances decides who
gets income generated near an entry or exit, and what each mint/burn must read.

**Alternatives** (D29 §6).
- (a) Read all positions (and require a fresh spoke report) on every operation: breaks synchronous mint (DEC-071), reduces to (c) with a 15-20 min wait.
- (b) Index advances only on recognition events, plus a Hub-recognition age guard on mint (`idadeMaxReconhecimentoHub`, "max Hub recognition age"; suggested 20 min).
- (c) Hybrid: Hub revenue read inside every mint and burn (inside the price loop DEC-067 already runs), spoke revenue via the report.
- (d) Time-weighted attribution within each recognition window.

**Research recommendation.** (c) with `try/catch` per source and a **per-token** index (not a single USDC index).
Strongest counter: (c) reads the fee fields of every Hub position on every mint/burn, including Aave which the price
function does not read, which is the literal opposite of the founder's words; (b) complies literally, with error
0.21-0.69 per 100,000 at the report's arrival age. "Together" items: per-token vs USDC index (rec per-token); DEC-082
redistribution base, reading A (shares at collection) vs B (generation rights) (no recommendation); destination of
income arriving with `totalSupply == 0` (rec: retain until fund closure, LC-32); confirm the reading of the DEC-092
constraint as "the income mechanism adds no position to read, and never the spoke".

**Founder.** Direction and bucket **DECIDED (DEC-092)**; the mechanism is **OPEN as of 2026-09-25** (LC-69, LC-100).
DEC-107 adds: the performance fee and protocol slice are taken from the collected value before it enters the
shareholders' accumulator. DEC-107 open reading (4): the per-source cap on counter advance "returns with Q60".

**What an implementer must do now.** Build the common core of all four alternatives (see "Income accumulator design"
below) behind internal functions, so (b) vs (c) is one call site: per-token index in Q128, per-address checkpoint and
owed amount, per-source monotonic counters, recognition that never reverts, permissionless Hub recognition, and the
adapter interface requirement (monotonic cumulative revenue counter per token). Switching later is a new contract
version (DEC-022).

---

## Q66 · Multi-spoke report synchronization

**What is at stake.** After DEC-099 the founder asked whether report firings can be staggered so that all spokes arrive
together, minimizing report age at NAV time. Measured: for all candidate chains (Robinhood, Arbitrum, Base, Ethereum)
Wormhole's "finalized" is Ethereum finality, which advances in 384 s epoch steps, so arrival depends on the firing phase
within the epoch, not on per-chain averages.

**Alternatives** (D31 §3).
- A: stagger by expected finality time (founder's formulation): improves mean age (1,304 -> 1,182 s), worsens max (1,304 -> 1,396 s).
- B: fire all simultaneously: simplest; Robinhood and Ethereum arrive ~15-18 s apart; waits for Base (~250 s later, long tail).
- C: continuous per-spoke cadence, no coordination; NAV uses last valid report of each spoke.
- D: C in the normal regime plus A on demand for a Payout with unwind.
- E: aligned to the Ethereum epoch: each spoke fires at its own latest safe phase `phi*` (Robinhood 300 s, Ethereum 348 s, Arbitrum 192 s, Base 264 s); event-triggered firing for chains with their own fast finality (E2).

**Parts.** (a) coordination; (b) cadence and reading of "+1 block": (i) one report per epoch (225/day, US$6.77/day per
spoke), (ii) one every 3 epochs (window 2,424 s, US$2.26/day), (iii) 20 min free phase reading DEC-099 as finality +
cadence (window ~2,310-2,531 s, US$2.17/day); (c) whether DEC-105's "all spokes" is literal (every spoke needs a report
after the unwind instant) or only the unwound spoke.

**Research recommendation.** (a) E (i.e. D with E instead of A): per-epoch cadence at each chain's phase; unwind
emits the report in the same transaction, executed at the chain's phase; event trigger for fast-finality chains.
(b) (i), keeping the **letter of DEC-099** with `T_fin` = worst case measured: Robinhood 1,587 s, life 1,587.1 s
(mint closed ~0.2% of the time; 1.1% with 1,371 s); on Ethereum the letter does not cover usage age (1,173 s vs 1,206 s,
8.6% of time without a valid report), so there "+1 block" reads as "+1 finality step" (822 + 768 = 1,590 s); alternative
reading for Robinhood 1,656 s. (c) (ii), only the unwound spoke. Strongest counter: one report per epoch costs ~3x the
20 min cadence (US$2,472 vs ~US$791 per spoke per fund per year, 24.7%/yr of a 10,000 fund) for a small per-operation
gain that nearly vanishes if Q57 goes to alternative 2.

**Founder.** **OPEN as of 2026-09-25** (LC-140). Answer (b) together with Q57 (b).

**What an implementer must do now.**
- With C, D or E there is **no round concept in the contract**. Per supported network: validity window, tolerance and
  minimum `report()` interval (60 s proposed by the engineering analysis). Phase `phi*` is keeper metadata only.
- Spoke `report()` is public (anyone may fire; keeper is the API per DEC-052).
- The spoke unwind function emits a report in the same transaction; the Hub accepts, for the unwound spoke, only a
  report whose `cumulativeSentHome` covers the unwind proceeds (research reading of DEC-105 item 3, to confirm with
  Q66 (c)).
- Payload carries `cumulativeReceived` / `cumulativeSentHome`; flows after capture are reconciled by transfer id
  (DEC-085, DEC-090, DEC-104), not by synchronizing capture instants.

---

## Q17-x · Adapter immutability, `deprecated` flag and Collector (Q17-2a to Q17-5)

**Decided context (applies to the Uniswap and Across adapters).**
- DEC-053: `Adapter` executes and is fixed in the mandate at creation, never added later; `Collector` only receives and
  may be added to a live mandate (who/when unresolved).
- DEC-056: pausing an adapter is a quarantine: it blocks entry and position increase and **never** blocks moving value
  from the external protocol back to the Spoke Vault; the investor exit path stays open end to end. Open: bug in the
  withdrawal path itself, whether quarantine expires, who triggers it (DEC-021).
- DEC-058: advisory catalog (publishes implementations and the current one, routes nothing); the mandate pins the
  adapter **address**; a live fund never adopts a new implementation, not even opt-in; `deprecated` is global,
  immediate, irreversible; a fund with a deprecated adapter can withdraw but never open or increase ("definitive
  unwind"). Q17-1 is answered by DEC-058 (variant H2).
- DEC-087/088/089/090: a bridge is an adapter (same regime, incl. `deprecated`); new bridge adapters only for new funds;
  the mandate lists bridges in order per spoke network; supported networks only with live protocols; the core owns one
  transit state machine and each bridge adapter translates into it (Across as a mirror; a 3-state machine
  initiated/finalized/reverted is a research reading to confirm). DEC-066: 6 h Across deadline as an adapter constant.
- DEC-079/080: the position adapter returns principal and income as two separate values from the protocol's own
  accounting; the fund counts only what adapters and collectors report (no donations).

### Q17-2a · Do quarantine and `deprecated` block collection of already-generated income?
- Stake: collection brings value in without raising exposure, but reward-token/callback reentrancy is real; blocking forever loses income.
- C1: neither blocks collection. C2: quarantine suspends collection and reward sale; `deprecated` never blocks collection. C3: both block.
- Recommendation: **C2** (cumulative Merkl leaves make a short suspension lossless). Counter: carves an exception into DEC-056's one-line promise.
- Founder: **OPEN as of 2026-09-25**.

### Q17-2b · Who triggers `deprecated`, and where does the flag live?
- Stake: after DEC-058 it is the only outside power over a live fund's capability and it is irreversible (A16/A17).
- Subject: S1 dedicated Labs key; S2 quorum with an independent signer; S3 S1 but only for adapters already in quarantine; S4 permissionless on violated invariant.
- Location: L1 in the adapter (monotonic bool plus immutable deprecator address; catalog mirrors); L2 in the catalog (execution path reads it); L3 both.
- Recommendation: **L1 with S3** (multisig key). Counter: S3 documents rather than solves DEC-057 (same owners); only S2 gives independence.
- Founder: **OPEN as of 2026-09-25** (LC-26).

### Q17-3 · Open position in a deprecated adapter: timing and what counts as "reduce"
- Stake: money sits behind code declared buggy; who decides the exit pace and which verbs count as exit.
- Timing: P1 forced immediate permissionless unwind; P2 reduce-only at the manager's pace (the minimum DEC-058 fixed); P3 P2 plus a published deadline after which anyone forces the unwind. P4 closed by DEC-058.
- "Reduce": R1 by value direction (balance delta, protocol -> Spoke Vault); R2 per-verb reduce/increase tag in adapter bytecode.
- Recommendation: **P3 with ~7 days and R1** in the DEC-018 scope (no borrowing in POC/MVP); R2 only if borrowing opens; condition: the exit swap goes through another conversion adapter/pool in the mandate, not through the deprecated adapter.
- Founder: **OPEN as of 2026-09-25** (LC-121).

### Q17-4 · What the mandate commits per adapter beyond the address, and where the address may come from
- O1 free address, no codehash; O2 free address, `codehash` in `mandateHash` and revalidated on every use; O3 address must be in the catalog at creation (catalog becomes authorization at creation).
- Recommendation: **O2** (keeps DEC-001 permissionless and DEC-058 advisory literal). Counter: `deprecated` then does not reach copies outside the catalog (A18). Gas of per-use `EXTCODEHASH` not measured.
- Founder: **OPEN as of 2026-09-25**.

### Q17-5 · Who may add a Collector to a live mandate, and with what window
- A Manager only, no window, restricted to collectors passing an on-chain passivity test; B Manager with notice and exit window; C Labs certification in the catalog as a condition; D anyone if destination is that fund's Spoke Vault; E Labs adds without the manager.
- Recommendation: **A, with C as the de facto (non-binding) path**. Passivity checked on-chain: immutable destination = that fund's Spoke Vault, single `SOURCE` and `VERB`; no `DELEGATECALL` is an off-chain process check. Counter: the Merkl Distributor is UUPS without timelock; B's window is the only reaction left if a code restriction cannot be guaranteed.
- Founder: **OPEN as of 2026-09-25** (LC-120).

**What an implementer must do now (all adapters, incl. Uniswap V3 and Across).**
- Adapter immutable: no proxy, no mutable logic pointer, no setter for targets; closed list of targets and selectors
  in bytecode; ephemeral approvals (`forceApprove` to zero after each operation).
- Spoke Vault calls only mandate-pinned adapter addresses; store `codehash` next to the address now (keeps O2/O3 open).
- Deprecation/quarantine as an explicit boolean read by every entry/increase verb, never by redirecting a pointer to a
  stub (dHEDGE `ClosedContractGuard` pitfall). Withdrawal verbs are never gated (write no function that could block
  them). Classify every adapter verb as entry/increase vs withdraw/reduce now; quarantine, deprecation and R2 all need
  it. Keep the flag read behind one internal function so the L1/L2 choice stays local.
- Any adapter that can be a creditor of an incentive campaign locks its claim recipient in the constructor (Merkl:
  `setClaimRecipient(dest, address(0))` + `toggleOperator(address(this), address(0))`), otherwise income is lost after deprecation.
- Spoke Vault "rule 8" (needed before the first Collector): `receive()` without logic, the same reentrancy lock on
  every function that moves value or reads balances for NAV/report, state written before external calls, accounting
  by measured balance delta.
- Uniswap V3 (POC per DEC-018; MVP is Uniswap V4 + Aave): V3 `burn` adds principal to `tokensOwed`, so separate income
  by poking the position with zero liquidity before `burn`, then read the difference (D29 §2.1). Expose a monotonic
  cumulative income counter per token (all fees ever realized plus current uncollected), never a balance (D29 §3.4).
- Across adapter: report the signed "value that will arrive" (DEC-085/087); the **core**, not the adapter, verifies
  that the destination is the fund's own vault on the destination chain registered in the mandate; the adapter maps
  Across states into the core transit state machine (DEC-090); 6 h deadline constant (DEC-066).

---

## Fee model as decided (DEC-106..110)

All DECIDED on 2026-09-25 (Lot 13, DEC:3325-3512) unless marked. Doc 28 §8 (D28:1680) summarizes; the register prevails.
Founder answers: Q61 -> C with E; Q62 -> B; Q63 -> B with default zero; Q64 -> A without swap; Q65 -> B with the
slice moved to a per-manager registry.

**Fees that exist in the MVP (DEC-106 item 1).** Manager fee fixed in the mandate (performance and management
components); protocol slice of the manager fee; protocol flow fee; the `Payout Fee` of the Instant Payout.

| Rule | Decided value / behavior | Source | Still open |
|---|---|---|---|
| Protocol slice of the manager fee | 50% of the manager fee by default; Pool Party may set a different value per manager "via our API" to negotiate incentives. Lives in the per-manager registry, outside the mandate; read at **every charge**; a change applies from the next charge, past charges keep the old slice. Manager without an entry: 50% (no API dependency, DEC-052). Not an extra charge to investors: it splits the fee they already pay. | DEC-106 items 2, 4; DEC-110 item 3 | LC-142: which Pool Party role writes it on-chain, whether it may exceed 50% and its cap (research proposed <= 5,000 bps of the manager fee), guardrails (core cap; only-down-below-default) |
| Protocol flow fee | 0.25% by default for every new fund, **cap 1%** (core constant), configurable via the API. Charged on the investor's **entry and exit**, on the flow itself. Example: deposit 100,000 -> 250 to the protocol in the same tx, 99,750 buys 99,750 shares at 1.00. | DEC-106 item 3; DEC-109 item 3; DEC-110 item 1 | LC-143: research reading = applies to Standard and Instant Payout, on the amount paid, deducted from what the investor receives; does not apply to Income Withdrawal. LC-142: whether a live fund's rate may change within the 1% cap, and whether it lives in the fund or the registry |
| Performance fee | Base = **income** (LP fees, interest), not the share price; **no high-water mark** (charged even when principal lost; e.g. 16,000 on 30,000 total return = 53.3%); **charged at collection**; the fee and protocol slice come out of the collected amount **before** it enters the shareholders' accumulator. Rate in the mandate; recipient = manager's receiving address. No price read needed for the fee. | DEC-107 | Readings to confirm: (1) external incentive pays the same fee, separated at collection in the incentive token, before distribution; (2) fee only on collected income; (3) fee never blocks a withdrawal (if the calculation fails, collection and Payout proceed); (4) per-source cap on counter advance returns with Q60 |
| Management fee | Optional mandate field, **default zero**; base **`Share Assets`** (excludes attributed income and Operating Cash); accrues continuously over time in USDC, registered on movements, transferred at "position close". While unpaid it is a recognized expense lowering `Share Price` (allowed by the DEC-104 expense caveat). Example: 1%/yr on 1,000,000 = 27.40/day, 10,000/yr. | DEC-108; DEC-109 item 3 | LC-144: recipient (reading A: to the manager, with the protocol slice; reading B: entirely to the protocol, per "transferred to the protocol"); meaning of "position close" (a fund position closing, an investor's full exit, or fund closure) |
| Payment form | Every fee paid **in asset, never in shares**; **no swap by the contract**: performance is paid in the token the income was collected in, so recipients receive several tokens (USDC, WETH, USDG). Example: collection of 1,000 USDC + 0.5 WETH at 20% performance and 50% slice: 100 USDC + 0.05 WETH protocol, 100 USDC + 0.05 WETH manager, 800 USDC + 0.4 WETH to the shareholders' accumulator. | DEC-109 items 1-2 | Engineering reading: where the fee is split from spoke-collected income (at collection on the spoke vs. on arrival at the Hub). Doc 28 suggested it travels with the income to the Hub, which also keeps the registry Hub-only |
| Timing (all fees) | Taken from moving money: performance and slice at income collection; flow fee at entry/exit; management accrued in a register at movements and transferred at position close. The founder rejected the "100% allocated manager never gets paid" counter-argument on this basis. | DEC-109 items 3-4 | see LC-144 |
| Caps | **Caps are core constants.** Flow fee cap = 1%. | DEC-110 item 1 | LC-57: caps for performance, management and slice not answered (research proposed 2,500 bps, 200 bps/yr, 5,000 bps); manager-fee minimum (0, or 10% as in V1) not answered |
| Mutability | Manager fee in the mandate **can only decrease**, immediate effect, **settling what has accrued first**; raising only via a new version with opt-in migration (DEC-022). The rest of the mandate stays immutable. `Payout Fee` stays immutable (DEC-006). | DEC-110 items 2, 4 | none beyond LC-57 |
| Manager registry | Separate contract, **one per manager**, the single source of truth for manager properties valid across all their funds; today it holds the protocol slice; outside the mandate. Extra cost ~5,000 gas per charge (cold access), NOT MEASURED. Research note: a single controller (DEC-057) controls every manager's net revenue through it. | DEC-110 item 3 and notes | LC-142: who writes it, with which locks, where it lives |
| Recipients | Manager fee -> manager's receiving address; protocol slice and flow fee -> "the protocol"; `Payout Fee` -> Operating Cash (DEC-102, 2%, Instant Payout only; network costs charged separately). Instant Payout of 30,000: 600 Payout Fee + 10 network + 75 flow fee = 685. With a zero-fee manager the protocol still earns the flow fee. | DEC-106 item 4 and journey | LC-132: confirm the protocol fees go to the `Protocol Recipient` address (CTX:295-307) |

**Not answered.** The dilution-protection entry fee that would stay in the fund (doc 28 Q61 list) was not answered and
returns with Q57 (D28 §8; DEC-106 note).

**Research notes recorded without reopening (DEC-106 note, DEC-110 consequences).** The exit flow fee is the incentive
ADR-013 (a research proposal) refused: the protocol earns when shareholders leave; the founder's decision prevails. It
also acts as a brake on the "patient actor" who exploits stale spoke reports (a 100,000 cycle costs ~500), but the
money goes to the protocol and does not compensate diluted shareholders. A slice change affects the manager, not the
investor.

**Ambiguity to resolve before coding the collection path (ambiguous in source).** DEC-107 says the performance fee is
taken "from the collected value, before it enters the shareholders' accumulator". Doc 29's recommended index advances at
*recognition*, which by DEC-092 includes income recognized but not yet collected (adapter ops, `reconhecerHub()`,
spoke reports). Doc 28 had proposed separating the fee at recognition and paying it only on the collected fraction
(`Tx[t] * C[t] / Rrec[t] - paidFee[t]`). The register does not reconcile "fee at collection" with "index at
recognition"; DEC-107 reading (2) and DEC-109's engineering reading are still to confirm.

**What an implementer must do now.** Flow-fee deduction before the share calculation on deposit (whole shares,
DEC-035) and on payouts behind a single function (payout incidence LC-143 pending); per-token owed balances for manager
and protocol; a registry read at each charge with a 50% default when empty; core constants for caps (only the 1% flow cap
has a value); a manager-only function that accepts a strictly lower manager fee and settles accrued amounts first; no
fee ever paid in shares and no swap in the fee path.

---

## Income accumulator design (Q60)

### Decided
- **DEC-092:** income generated in positions and not yet collected sits in its **own bucket**, outside `Share Assets`
  and inside `Gross Assets` (DEC-098); collecting only moves it between buckets without touching `Share Price`; it
  belongs to those entitled (DEC-014) and is withdrawable independently of shares via `Income Withdrawal`; the
  mechanism **must not read all positions on every user operation**. Direction (mechanism still in question):
  global accumulator with per-holder checkpoint, like Uniswap fee growth / Synthetix `rewardPerToken` /
  MasterChef `accRewardPerShare`.
- **DEC-014:** income belongs to whoever was eligible when it was generated. **DEC-073:** `Income Withdrawal` is the
  only exit for income. **DEC-064:** no compound. **DEC-045 + DEC-047:** burning 100% of shares pays all attributed
  income, atomically with the burn. **DEC-077:** shares stay in the wallet until Payout execution, so they keep earning
  until burned. **DEC-091:** whole-share mint/burn. **DEC-080:** the fund counts only what adapters/collectors report.
  **DEC-079:** the adapter separates principal and income. **DEC-104:** no recognized value in two bases or in none.
- **DEC-078 + DEC-082:** external incentives (Merkl, airdrops) have their own vault, do **not** go through this index,
  and are attributed by eligibility during the campaign; the share of someone who left before collection goes to those
  who stayed (base A vs B open, errata item 19).
- **DEC-107/DEC-109:** performance fee and protocol slice leave the collected amount before it enters the shareholders'
  accumulator; paid in the collected token. With Q62 B (no HWM), the extra USDC-valued scalar that a high-water-mark gate
  would have needed is **not** required (D28 §8).

### Recommended mechanism (D29 §3; RECOMMENDED, not decided)

English glosses of the source names: `I[t]` index; `resto[t]` -> remainder; `semDono[t]` -> ownerless; `I_a[t]`
checkpoint; `devido_a[t]` -> owed; `acumulado_f[t]` -> cumulative per source; `ContadorRegrediu` -> "counter regressed" event; `ReceitaSemDono` -> "ownerless income" event; `liquidar` -> "settle" (do not use
`settle*` in code: rule R1 bars `settlement`); `reconhecer` -> recognize.

**State.** Lives in the `Core Vault` (shares exist only on the Hub).
- Per income token `t` (closed list derived from the mandate's closed pool/protocol list): `I[t]` = income recognized
  per share since fund creation, **Q128, never decreases**; `resto[t]` division remainder carried to the next
  recognition; `semDono[t]` income recognized while `totalSupply == 0`, held with an event.
- Per address `a`: `I_a[t]` (value of `I[t]` at `a`'s last checkpoint) and `devido_a[t]` (attributed and not yet
  withdrawn = `Attributed Income` per address per token).
- Per source `f` (each Hub position, each spoke): `acumulado_f[t]` (highest cumulative-since-inception counter the source
  ever reported) and a revenue-quarantine flag (signals only, blocks nothing).
- Campaign eligibility (DEC-082): global `G` ("seconds per share", advanced at every mint/burn:
  `G += (now - last) * 2^128 / totalSupply`), per address `g_a` (share-seconds) and `G_a` (checkpoint), plus per-campaign
  snapshots of `G` at campaign boundaries; `g_a += shares_a * (G - G_a)` at every checkpoint.
- The per-address state must fit one **copyable block** (shares, `I_a[t]`, `devido_a[t]`, `g_a`, `G_a`: 2k + 3 fields;
  9 with k = 3; plus one field per open campaign) so a future E1 migration (Q58) is a copy without settlement.

**Per-holder checkpoint (`liquidar(a)`).** For each token `t`:
`devido_a[t] += shares_a * (I[t] - I_a[t]) / 2^128` (round down), then `I_a[t] = I[t]`. Called **before** any change to
`a`'s share balance or owed amount:
1. **Mint:** checkpoint first; a first-time entrant has zero shares and only receives the checkpoint; new shares earn
   from the next recognition (this is how DEC-014 is enforced).
2. **Burn in every form:** Payout execution (DEC-077), Partial Payout (DEC-068), 100% burn.
3. **Income Withdrawal:** checkpoint, then pay from `devido_a`.
4. **Transfer, if it ever exists:** both sides before moving; E1 migration copies the block instead.

**When the index advances (`reconhecer(f, A[t])`).**
```
for each token t:
  if A[t] < acumulado_f[t]:           // counter regressed on an in-order delivery
    emit ContadorRegrediu(f, t, old, new); flag source; continue   // never revert: the same report's principal must still be admitted
  delta = A[t] - acumulado_f[t]; acumulado_f[t] = A[t]
  if totalSupply == 0: semDono[t] += delta; emit ReceitaSemDono(f, t, delta); continue
  num = delta * 2^128 + resto[t]
  I[t] += num / totalSupply;  resto[t] = num - (num / totalSupply) * totalSupply
```
O(k), touches no address. Recognition events:
- **Adapter operation on a Hub position** (allocate, unwind, move range; automatic unwind; payout claim): exact at that
  block. On Uniswap V4 any liquidity change realizes **all** fees of the position (`feesAccrued`); on Aave:
  units x change in `liquidityIndex` via the DEC-068 book.
- **`reconhecerHub()`** ("recognizeHub"): permissionless (API keeper, frontend in the deposit tx, anyone); exact at that block.
- **Spoke report delivery:** the spoke's cumulative counter per token inside the report; 15-20 min old at arrival.
- **Collector receipt:** no case today (incentives bypass the index).
- **Under recommended alternative (c): inside every mint and burn**, reading Hub income inside the price loop DEC-067 already
  runs, with `try/catch` per source; a failed read falls back to the last recognized value with an event and never
  reverts a mint or burn (DEC-056 spirit).

**Adapter interface requirement.** Every source reports **cumulative income since inception, per token, monotonic**,
never "currently uncollected" (a collection between recognitions would make the delta negative). V4: sum of all realized
`feesAccrued` plus current uncollected `liquidity * (feeGrowthInside_now - checkpoint) / 2^128`. Aave: sum of
`units * (index_now - index_prev)`. Spoke: the Spoke Vault sums across its positions, including closed ones, so the
counter never restarts; a lost report loses nothing (the next carries the cumulative total).

**Scale and rounding.** Index in **2^128** with 512-bit `mulDiv` (or an index per whole share dividing by
`totalSupply / 1e18`, exact because supply is a multiple of 1e18). 1e18 scale would lose ~13,140 USDC/yr per source at
20-min recognitions; 1e12 (MasterChef) would never advance for a fund of this size. Round down at both ends; carry
`resto[t]`. Dust from per-address rounding stays in the income bucket (it is registered value, so the garbage
collector must not sweep it).

**Interplay with whole-share mint/burn.** The whole-share check lives only in mint/burn; the index is in token units and
`Income Withdrawal` pays tokens without burning shares, so the check never touches the index.

**Interplay with the uncollected-income bucket.** `devido_a` includes income that is recognized but still uncollected
(in positions or on a spoke). How much can be paid now is **LC-100 (OPEN)**: first come first served
`min(devido, collected balance of the token)` vs proportional `devido * collected / total owed` (O(1) with a global
total). On a 100% burn the index gives the exact `devido_a`, but only the Hub-collected part can be paid atomically; the
uncollected spoke part depends on collection and bridging (**LC-77, OPEN**). The Across fee on income bridged back
(~0.06%) needs a payer; the research recommends Operating Cash (LC-49, OPEN), so the index never decreases.

**Error between recognitions (entrant of 100,000 into 1,000,000; 600k Hub / 400k spoke; 20%/yr).** (b), whole fund
stale: 0.69 per 100,000 at 20 min, 0.92 at 26.45 min (end of the recommended life). (c), only the spoke stale: 0.28 at
20 min, 0.37 at 26.45 min. Compare 363.64 per 100,000 per percentage point of spoke principal staleness: roughly 395-527x
smaller. The error has one sign on entry (entrant gains), cancels on average for entry+exit.

**Gas (EIP-2929 estimates, not measured; 0.020 gwei, ETH 2,454).** Checkpoint of an existing holder with k = 3: 36,300
gas (US$0.0018); 87,600 if `devido_a` was zero; first entry 72,600. Standalone `reconhecerHub()` with 2 V4 positions + 1
Aave: 113,700 gas (US$0.0056). Alternative (c) on top of the price-function baseline: 29,000 per V4 position, 16,500 per
Aave position, 104,500 in the example (US$0.0051).

**Fitness functions from day one (D29 §6).** `I[t]` and `acumulado_f[t]` never decrease; sum of owed + each address's
computable pending + `resto[t] / 2^128` + `semDono[t]` never exceeds total recognized minus total paid; report
admission never reverts because of income; under (c) no mint or burn reverts because of an income read; DEC-080
registry-vs-balance reconciliation.

**Still open around the mechanism.** Q60 itself (a/b/c/d); per-token vs USDC index (rec per-token); DEC-082 base A/B;
`semDono` destination (rec retain until closure, LC-32); per-source counter-advance cap (proposal:
`delta * price <= cap * sourceValue * dt / year`, e.g. 200%/yr over 60 min = 91.32 on a 400,000 spoke, 136.99 on a
600,000 Hub; DEC-107 reading (4)); fee split point (see the fee-model ambiguity above).

---

## Report age and gas (Q57)

### Measured numbers
| Measurement | Value | Source |
|---|---|---|
| Spike 2026-09-18, finalized VAA | 1,190 s (single sample; later shown to be a one-epoch slip: fired at phase 363 s) | D30 §0.2; D31 §1.4 |
| 20 Robinhood NTT operations, block to VAA | 925-1,176 s | doc 19 via D30 §2.1 |
| Robinhood block time; `finalized` lag vs `latest` | 0.1 s; ~17.5-18.5 min | D30 §2.1 |
| Wormholescan, Robinhood since 2026-09-09 (n = 334) | min 812, p10 853, p50 1,006, p90 1,165, p99 1,285, max 1,371 s | D31 §1.3 |
| Wormholescan, Robinhood full history (n = 677) | p50 1,045, p90 1,242, p99 1,438, **max 1,587 s** | D31 §1.3 |
| Arbitrum / Base / Ethereum (finalized) | p50 1,065 / 1,307 / 965 s; max 2,083 / 4,418 / 1,161 s | D31 §1.3 |
| BSC / Avalanche (reference, own finality) | p50 3 / 4 s | D31 §1.3 |
| Structure | finality advances in **384 s Ethereum-epoch steps**; arrival = start of epoch k+3 + psi (psi p50: 4 s Ethereum, 18-20 s Arbitrum/Robinhood, 274 s Base); age at arrival = 3x384 - phase + psi, ~770-1,170 s, +384 s on a slip | D31 §1.4 |
| Robinhood fired at phase 300 | arrival age ~870 s median (866-888 p10-p90); ~1.6% slip to ~1,254 s | D31 §3.5, §4 |
| Wormhole docs claim "~7 min" for Robinhood | refuted by data | D31 §1.1 |
| ETH move, 20 / 60 min windows (1 yr) | p50 0.151% / 0.261%; p99 1.429% / 2.549% | D30 §3.2 |
| Value transferred per ETH percentage point (reference fund) | 181.82 per 100,000 deposited | D30 §3.3 |
| Patient actor (mint + Standard Payout, ~5-day cycle), alt 1 | up to 580 per 100,000 per cycle with perfect foresight; ~258 without (19%/yr); ~65 with a 10% Spoke Cap | D30 §3.4-3.5 |
| Chainlink ETH/USD on Arbitrum | 0.05% deviation, 1,755 s heartbeat; updates p50 90 s; move between updates p90 0.112%, max 0.254% | D30 §0.4 |
| VAA verification (13 signatures) | `parseAndVerifyVM` 146,387 gas; +~6,819 execution and +~1,045 calldata per extra signature; ~187,300 at 19 | D30 §6.3 |
| Hub delivery / spoke send | ~229,952-282,863 gas, US$0.0126 per Hub delivery; US$0.015-0.020 per spoke send (0.0175 mid); US$0.0301 per report | D30 §6.4, §6.8 |
| Cadence cost per spoke per fund | one per epoch 225/day = US$6.77/day, ~2,472/yr; one per 3 epochs US$2.26/day; 20 min US$2.17/day, ~792/yr | D30 §6.8; D31 §3.3 |

### Candidate rules for report life
- DEC-094 as first proposed (life tied to spoke block time): would reject 100% of finalized reports (9,250-11,900
  Robinhood blocks elapse before a VAA exists).
- Research original `T_fin + N + slack` (45 min with alt 1, 85 min with alt 2): superseded by DEC-099, kept as sensitivity.
- **DEC-099 letter, `T_fin + 1 block`:** with `T_fin` = 1,200 s each report arrives with 10-275 s of life and no cadence
  keeps mint open (14.3-16.9% of time without a valid report even at one per epoch). With `T_fin` = worst measured
  **1,587 s** -> life **1,587.1 s**, one report per epoch keeps a valid report except on slips (mint closed ~0.2% of
  time; 1.1% with 1,371 s).
- "+1 finality step" reading: Robinhood 888 + 384 + 384 = **1,656 s**; Ethereum 822 + 768 = **1,590 s** (where the
  letter fails: 1,173 s vs usage age 1,206 s, 8.6% without a valid report).
- Cadences: (i) one per epoch at the chain's phase; (ii) every 3 epochs (2,424 s window); (iii) 20 min free phase,
  reading DEC-099 as finality + cadence (2,310-2,531 s window).

### Decided
- **DEC-093:** finalized consistency; **anyone delivers the VAA** (no dependency on the Executor or the API);
  **strictly increasing sequence per emitter**, rejecting repeated and out-of-order VAAs by (emitter chain, emitter
  address, sequence), because the Wormhole core does not deduplicate application VAAs. Consequences recorded: minting
  uses the last finalized report (on-demand proof no longer works for minting); gas is estimated by the submitter
  (`eth_estimateGas`); reimbursement needs design. Base of trust: 13 of 19 guardians + emitter check against the
  mandate's Spoke Vault; ZK out of scope (DEC-086 closing note).
- **DEC-094:** report life is fixed and depends on a property of the spoke network; the cost of the proof is not a
  decision factor ("whoever operates pays", 0.01% or 0.14%).
- **DEC-099:** life = **time to finality of the spoke network + one block**, a parameter of each supported network
  (DEC-089), not a case-by-case choice. Robinhood per the register: ~925-1,190 s + one block (the parameter value itself
  is refined in Q66 (b)).
- Related: **DEC-105** (Payout with unwind: only a report with sequence after the unwind block on that spoke; burn at the
  consolidated NAV; adds ~15-20 min); **DEC-096/DEC-100/DEC-102** (Operating Cash per network with floor and top-up,
  floor effect on Share Price accepted with no protocol cap, Payout Fee fully into Operating Cash and usable for spoke gas).

### Open
- Q57 (b) spoke pricing (alt 1, 2, 2b, 3, 4, 6); (c) VAA-delivery reimbursement and the top-up trigger + cap in the
  report path; (d) variation band. Q66 (b) cadence and the `T_fin` parameter value / reading of "+1 block" (research:
  one per epoch, 1,587 s on Robinhood). Dilution-protection entry fee (DEC-106 note). QA3 (Hub LP price guard), QB9 (USDG
  price), LC-141 (market cost of the unwound slice of whoever exits).
- Proposed reimbursement parameters (per supported network, RECOMMENDED): `GAS_CAP` 400,000 (500,000 with alt 2);
  `PRICE_CAP_WEI` 0.1 gwei; `CAP_PER_DELIVERY_USDC` 0.15; `REIMBURSE_INTERVAL` = cadence N (384 s at one per epoch);
  daily cap `86,400 / N * 0.15` = 33.75 USDC/day at one per epoch; top-up-in-report-path cap = daily cap. Formula:
  `(g0 - gasleft() + G_FIXED + 16 * msg.data.length)`, capped, times `min(tx.gasprice, block.basefee, PRICE_CAP_WEI)`,
  plus `ArbGasInfo.getCurrentTxL1GasFees()` capped, converted to USDC with the Arbitrum ETH/USD feed; only the first
  delivery of each new sequence spaced by `REIMBURSE_INTERVAL`; exact calldata length check; missing cash emits an
  event and never reverts admission. Research counter: this is auditable payment code to save US$0.91-2.84/day per fund.
