# Founder MVP report — October 3, 2026 (draft)

## Executive status and evidence boundary

**Code measured:** `main` `f88b25b96913301aa9b00dd0b638adc89f9ee689`, through wave-3 landing PR #23 and
wave-4 PR #21 (which contains approved PR #22). This WP-19b is docs only: no executable, compiler, fixture,
ABI or deployment change. The final lifecycle transaction report is **pending PR #24**, not certified here.

**Fresh local results:** 1,432 non-fork tests in 183 suites; 222 fork tests in 56 suites; zero failures/skips.
The 3/3 size tests are included in the non-fork total, not three additional tests. Every listed production
contract/linked library fits 24,576 bytes. Tightest: SpokeUnwindLib 23,473 bytes, **1,103 bytes headroom**.
No margin below 1,000, but that library is only 103 bytes above the warning threshold.

**Readiness:** feature-complete for the landed proportional unwind, dollar income, spoke orders and closure
scope, subject to explicit deferrals/limitations. Internal alpha preparation is not a public release, external
audit, real guardian-service certificate or mainnet broadcast. Rafael's input approval and final rehearsal remain gates.

## 1. What Rafael asked for

Bring the contracts into line with DEC-111..187, with small identifiable commits, independent PR review/fix
rounds and merge evidence; enforce the smallest-chain bytecode limit; test local units/invariants, real mainnet
forks and the two-fork API/keeper harness; report tests, gas, share-price behavior, scenarios and release inputs;
then deploy an **internal alpha with Pool Party wallets/capital only**, Arbitrum One Hub and Robinhood Chain spoke.

Two founder details guided implementation: swaps must use a separate swap adapter (on-chain V3 route discovery
or a Pool Party API-signed route), not the fund's position pools; bridge send economics must be fixed inside the
bridge adapter, so callers cannot widen the input/output gap for a colluding relayer. Fork research found Across
fees from other users are logs, not readable contract history, so the reference uses the fund's own sends.
Wormhole carries orders/reports, never capital; Across carries stablecoins.

Sources of truth: Portuguese register `01-RESPOSTAS-E-DECISOES.md` at spec `9cde6b7`, later decisions overriding
earlier ones; PLAN-AMENDMENTS overriding PLAN; ruling 2026-10-02. DEC-186 (500-bps annual management cap) and
DEC-187 (manager pays own gas) are Slack-only. [DECISIONS](../DECISIONS.md) maps every current status.

## 2. What was built, by decision group

| DEC group | Landed behavior | Merged PR evidence |
|---|---|---|
| DEC-022/058/131/183 | Immutable thin vault layers, linked library splits, completeness/size test and nested dependency-first deploy linking | [#1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/1), [#10](https://github.com/PoolPartyLabs/smartcontract-v2/pull/10), [#21](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21) |
| DEC-031/087/158/162/169/176/177 | Across vault-only builder: own last 3 rates, 0.08% initial, 0.03% floor, x1.5 expiry step, 1% rate cap plus 0.03 input-token fixed fee; no caller quote | [#2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/2), [#12](https://github.com/PoolPartyLabs/smartcontract-v2/pull/12), [#13](https://github.com/PoolPartyLabs/smartcontract-v2/pull/13) |
| DEC-112/115/125/127/144/146/154/155/181/182/184/186 | Atomic manager seed, half-peak manager base, shared registry 5–50% protocol slice, 10–90% performance/0–5% management fee, 72-hour Standard term, Instant Payout Fee <=10% retained in Idle | [#3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/3), [#12](https://github.com/PoolPartyLabs/smartcontract-v2/pull/12) |
| DEC-129/136/142/143/153/170/173 | Mandate swap adapter, whole-fill direct V3 tier discovery and EIP-712 weighted split/multihop routes; endpoint allowlist, guarded mid-swap report; payout sales now use it too | [#4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/4), [#7](https://github.com/PoolPartyLabs/smartcontract-v2/pull/7), [#13](https://github.com/PoolPartyLabs/smartcontract-v2/pull/13), [#19](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19), [#23](https://github.com/PoolPartyLabs/smartcontract-v2/pull/23) |
| DEC-105/111/120/139/151/157/160 | Instant-consistency authenticated UNWIND/CLOSE/COLLECT, id/sequence replay protection, result/report hooks, earmarked proceeds, post-unwind reports and one-price permissionless settlement; targeted Hub ACK retirement | [#5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/5), [#14](https://github.com/PoolPartyLabs/smartcontract-v2/pull/14), [#15](https://github.com/PoolPartyLabs/smartcontract-v2/pull/15), [#22](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22), [#21](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21) |
| DEC-118/132/137/140/141/148/151 | Idle-first proportional fraction with 2% buffer, per-position exclusion/retry memory, requester sale/bridge bounds, per-sale cost attribution, retained requester debt and terminal whole-share resolution | [#19](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19), [#23](https://github.com/PoolPartyLabs/smartcontract-v2/pull/23), [#22](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22), [#21](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21) |
| DEC-014/117/122/124/138/152/161/166/172/175 | Live token recognition cohorts and Hub dollar index; sale-boundary cohort sealing, all-chain stablecoin collection, actual credited-dollar conversion, fee split/owed handling, USDC Income Withdrawal | [#6](https://github.com/PoolPartyLabs/smartcontract-v2/pull/6), [#18](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18), [#23](https://github.com/PoolPartyLabs/smartcontract-v2/pull/23) |
| DEC-114/121/135/147/149/150/163/167 | Open -> Closing -> Closed, stop accrual, 72-hour manager window then permissionless unwind, manual/automatic closure costs, final collection/transit gates, management payment, frozen Closed split and late-value exclusion | [#12](https://github.com/PoolPartyLabs/smartcontract-v2/pull/12), [#21](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21) |
| DEC-133/134/159/160/187 | CI fork isolation, harness/API ports and secret redaction, alpha rehearsal/checker/executable verification manifest, funded runtime roles; no actual production broadcast | [#8](https://github.com/PoolPartyLabs/smartcontract-v2/pull/8), [#9](https://github.com/PoolPartyLabs/smartcontract-v2/pull/9), [#11](https://github.com/PoolPartyLabs/smartcontract-v2/pull/11), [#16](https://github.com/PoolPartyLabs/smartcontract-v2/pull/16), [#20](https://github.com/PoolPartyLabs/smartcontract-v2/pull/20) |
| DEC-111..187 documentation | English merged-code status digest and explicit deferrals, without claiming standalone libraries/stubs as completed features | [#17](https://github.com/PoolPartyLabs/smartcontract-v2/pull/17) |

GitHub metadata was freshly queried with `gh pr list --state merged --limit 100 --json number,title,url,mergedAt,mergeCommit,body`.
#18/#19 landed through #23; #22 landed through the containing #21 rather than a separate conflicting merge.
PR #24 was still **OPEN / draft**, head `b10f60b2b7ad24aecb0ba6c34171f31dd1ccac05`, when checked on October 3.
This report does not claim its stale “deployment blocked” title describes current main: #21 fixed nested linking.

## 3. Review history: findings caught, fixes and residuals

Evidence is the **PR conversation comments**, not inferred from commit counts or a green CI badge. Formal GitHub
review/inline-comment endpoints were also checked. Earlier wave-1 individual review transcripts are not all posted:
a fix reply establishes a round, not an independently visible final re-review. Counts below mean visible review/fix
rounds; a shared integration review is not six additional independent audits. Acceptance of an explicitly disclosed
residual is not a security fix. All PR links open their conversations; round-comment links identify direct evidence.

| PR | Visible rounds / evidence | Defects caught and disposition |
|---|---|---|
| [#1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/1) | Shared wave-1 integration review. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/1#issuecomment-5954660288) | Pure-move/size completeness landing checked; missing size-list entries/seed-versus-fee merge assertions and stale harness ABIs identified for integration/ports. Individual review transcript not separately posted. |
| [#2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/2) | Round-1 fix reply + shared integration review. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/2#issuecomment-5948712938); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/2#issuecomment-5954660698) | Expiry step below reference, one-step-per-batch exhaustion, sub-1-USDG expiry notes fixed. Donated-refund ambiguity and fee-churn/cap liveness disclosed, not cured; English/security wording corrected. |
| [#3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/3) | Round-1 fix reply + shared integration review. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/3#issuecomment-5949186047); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/3#issuecomment-5954661064) | Claim-time manager-base protection fixed; per-actor Payout Fee invariant slack corrected. Seed/Operating Cash guard declined with zero defaults and explicit residual. |
| [#4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/4) | Two fix rounds + shared integration review. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/4#issuecomment-5950128735); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/4#issuecomment-5952930304); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/4#issuecomment-5954661502) | Partial-fill quotes could win; uninitialized spot, high-price arithmetic coverage, zero router-balance leg, gas wording fixed. Round 2 addressed self-referenced tier limits, dust routes and partial-fill fork oracle; sweepable intermediate residue/no-maximum reference remain disclosed. #7 revisited manipulation. |
| [#5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/5) | Round-1 fix reply + shared integration review. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/5#issuecomment-5951859933); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/5#issuecomment-5954661905) | Order deadline, replay guard inside verifier, payout-mode bound and planned byte budget corrected. |
| [#6](https://github.com/PoolPartyLabs/smartcontract-v2/pull/6) | Round-1 fix reply + shared integration review. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/6#issuecomment-5952369555); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/6#issuecomment-5954662302) | Partial sale re-spread unsold recognized claims over current holders; fixed cohort preservation. Impossible zero-sold/nonzero-dollar acceptance and dependent reference model/16-token coverage fixed. |
| [#7](https://github.com/PoolPartyLabs/smartcontract-v2/pull/7) | Rounds 1–2; approval with residuals. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/7#issuecomment-5955121242); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/7#issuecomment-5955362499); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/7#issuecomment-5955404692) | Above-market tier can block/inflate bounded loss; discounted tier can beat honest route while understating loss. Tests/NatSpec pin the economics; selector not changed by the fix round. Most-in-range-liquidity alternative is cheaply manipulated. Alpha acceptance is not remediation. |
| [#8](https://github.com/PoolPartyLabs/smartcontract-v2/pull/8) | Round 1 + fix reply/CI evidence. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/8#issuecomment-5956569014); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/8#issuecomment-5956765031); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/8#issuecomment-5956991139) | Missing numeric fork pins, overbroad shared-fork clock explanation, incorrect scenario shard membership fixed; exact _createForks caller-set CI guard added. |
| [#9](https://github.com/PoolPartyLabs/smartcontract-v2/pull/9) | Rounds 1–2; approved. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/9#issuecomment-5955488152); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/9#issuecomment-5955816188); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/9#issuecomment-5955966092) | Late-registered spoke dropped queued orders; RPC URL secrets leaked on failures; arbitrary adapter zero-minimum signatures, non-idempotent after-deposit reporting and unexecuted two-hop coverage fixed. Production key-governance boundary remains. |
| [#10](https://github.com/PoolPartyLabs/smartcontract-v2/pull/10) | Rounds 1–2; approved with landing prerequisite. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/10#issuecomment-5955825960); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/10#issuecomment-5956112756); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/10#issuecomment-5956231660) | New deploy return broke harness tuple parsing; moved to #11 name-based parser. Required-library code checks/NatSpec and mechanism mixed into pure-move commit corrected. |
| [#11](https://github.com/PoolPartyLabs/smartcontract-v2/pull/11) | Round 1 + low-fix reply. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/11#issuecomment-5956502961); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/11#issuecomment-5956558308) | Unsafe address index signature, EOA address code requirement and silently dropped non-address outputs corrected; output parsing is explicitly by field/type. |
| [#12](https://github.com/PoolPartyLabs/smartcontract-v2/pull/12) | Round 1; approved with low carry-overs. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/12#issuecomment-5958415692) | Aave-first assertion impossible after removal, management accrual sub-unit pre-entry charge, Operating Cash floor/top-up expectation caught. Unwind/harness fixes ported later; L-2 bound remains documented, NatSpec unchanged here. |
| [#13](https://github.com/PoolPartyLabs/smartcontract-v2/pull/13) | Rounds 1–2; approved. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/13#issuecomment-5958734105); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/13#issuecomment-5958942404); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/13#issuecomment-5959009485) | Non-Mandate hop token could reenter mint against mid-swap NAV: guarded buildReport fixed. Missing sale price-source/route fields, stale PR base, removed harness verbs and removed future bridge-data slot recorded/ported to later owners. |
| [#14](https://github.com/PoolPartyLabs/smartcontract-v2/pull/14) | Round 1; low findings. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/14#issuecomment-5958810006) | Stale LC-132 script note, repeated-hook idempotency documentation, unexercised harness order phase and stale library/deploy lists caught; later feature/port/docs WPs address integration, no executor completion claimed then. |
| [#15](https://github.com/PoolPartyLabs/smartcontract-v2/pull/15) | One integration review; approved. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/15#issuecomment-5959374177) | Merge preserving mid-swap guard audited. API over-strict swap probe never proved reversion; zero slippage sentinel misdescribed. Ported in harness follow-up; not a claim that zero means zero loss. |
| [#16](https://github.com/PoolPartyLabs/smartcontract-v2/pull/16) | Round 1 + regression fix reply. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/16#issuecomment-5960171121); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/16#issuecomment-5960282462) | URL userinfo credentials survived redaction and could persist to disk. Shared redactor/log/report persistence fixed and tested; no separately posted round-2 verdict. |
| [#17](https://github.com/PoolPartyLabs/smartcontract-v2/pull/17) | Round 1 + docs fix reply. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/17#issuecomment-5960711741); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/17#issuecomment-5960769712) | DEC-136 incorrectly marked implemented while payout sales still used position pools; downgraded DEC-136/143/153 and cross-doc scope until WP-09 landed. No separately posted round-2 verdict. |
| [#18](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18) | Rounds 1–3; approved. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18#issuecomment-5960795543); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18#issuecomment-5961396424); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18#issuecomment-5961783764); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18#issuecomment-5961933415); [comment 5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/18#issuecomment-5962011691) | R1: delayed sale paid post-sale entrant (39.749999 USDC probe), aged eight-result refund lost WETH sale identity, unlisted Income became principal/global collection blocker. Sealed cohorts, retained unresolved metadata and Income recovery fixed. R2: unrelated pending Income stranded recovered Principal; keyed Principal reservation/release fixed. R3 counterfactual regressions confirmed. |
| [#19](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19) | Rounds 1–3; approved with low landing fix. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19#issuecomment-5960843695); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19#issuecomment-5961500576); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19#issuecomment-5961782774); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19#issuecomment-5961919146); [comment 5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/19#issuecomment-5961993810) | R1: proceeds-limited burns shifted Instant/Standard requester Market Costs to fund; net-cash sizing/debt retention fixed. R2: sub-share retained cost permanently kept request open; terminal one-whole-share/debt clearing fixed. R3 stale fuzz conservation rejected authorized retained surplus; assertions fixed in #23. |
| [#20](https://github.com/PoolPartyLabs/smartcontract-v2/pull/20) | Round 1 + six relay regression fix reply. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/20#issuecomment-5960806995); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/20#issuecomment-5960897766) | First sequence-zero report falsely marked delivered; require hasReport. Runtime could not decode linked OrderSequenceTooLow after external execution/crash; merged error ABI and durable-queue retry regressions fixed. MANAGER clarified as fund creator, not registry prerequisite. Real VAA service/explorer still unverified. |
| [#21](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21) | Rounds 1–3; approved with low carry-over. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5961763269); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5962111623); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5962331334); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5962403319); [comment 5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5962541622); [comment 6](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5962820213); [comment 7](https://github.com/PoolPartyLabs/smartcontract-v2/pull/21#issuecomment-5962891186) | R1: real CLOSE tuple incompatible with finalization and manual closure loss bypassed manager excess; shared result/cumulative cost book fixed (3% probe now manager 975/Alice 995 USDC). R2: 416-byte result writer versus 384-byte payout stride broke multiple results; shared size/decoder tests fixed. Library splits restored margins; final main/#22 integration and nested deployment linking fixed. R3 raw retirement abi.encode bypasses shared size assertion: low documented follow-up, identical bytes today. |
| [#22](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22) | Rounds 1–3; approved. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22#issuecomment-5961795723); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22#issuecomment-5962336988); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22#issuecomment-5962434238); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22#issuecomment-5962677634); [comment 5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/22#issuecomment-5962759209) | R1: unreserved credited proceeds, expired-claim gate/cost bypass, retry erasing unresolved send, unnecessary 0/0 publication, omitted incurred refund/refusal costs, same order-id execution under new sequence. R2: retention fix created 16-send lifetime lock and double-charged older refunded bridge fee. Targeted authenticated ACK retirement/refund-aware cumulative costs fixed. R3 requires keeper ACK delivery; 16 undelivered ACKs still block capacity. |
| [#23](https://github.com/PoolPartyLabs/smartcontract-v2/pull/23) | One integration review; approved. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/23#issuecomment-5962466720) | Approved #18/#19 heads preserved, test/mock merge resolutions inspected, no new production rule. Low #19 terminal-surplus fuzz assertions corrected; independent pre-closure harness 46 steps/294 assertions and API 19 concepts passed. |

Internal September 30 sweep/model reports remain historical, not release certification: 44 findings, 16 fixed,
3 then awaiting decisions, 25 acknowledged. Current disclosure is [KNOWN-LIMITATIONS](../security/KNOWN-LIMITATIONS.md).
No public-audit claim follows from independent agent reviews.

## 4. Fresh verification and reproducibility

Measured October 3 in a dedicated origin/main worktree with shared dependency/RPC configuration, no source edits.
Foundry **1.7.1**, commit `4072e48705af9d93e3c0f6e29e93b5e9a40caed8`; Solidity **0.8.28**, optimizer **800**,
`via_ir = false`, Cancun. Default fuzz 512; invariants 256 runs/depth 32. No statistical gas confidence interval implied.

```bash
forge build --sizes
forge fmt --check
forge test --match-path test/size/ContractSizes.t.sol -vv
forge test --no-match-path 'test/{fork/**,review/**/*Fork*}'
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
forge test --match-path 'test/{fork/**,review/**/*Fork*}' -j 4
```

| Run | Suites | Passed | Failed | Skipped |
|---|---:|---:|---:|---:|
| Non-fork, including size | 183 | 1,432 | 0 | 0 |
| Fork including review Fork suites | 56 | 222 | 0 | 0 |
| Size, separately rerun (already included above) | 1 | 3 | 0 | 0 |
| Relevant unit gas suites (repeated subset) | 9 | 198 | 0 | 0 |
| Relevant fork gas suites (repeated subset) | 4 | 5 | 0 | 0 |
| Instant high-loss gas regression (repeated subset) | 1 | 1 | 0 | 0 |
| Standard high-loss gas regression (repeated subset) | 1 | 1 | 0 | 0 |

Archive fork pins: **Arbitrum 511007613; Robinhood 78293056**, exported by the helper in the same shell before
each fork command. Never log URLs/keys. Full fork run completed locally, not copied from a PR. Build and format
passed; existing compiler/lint warnings retained. No harness/Anvil/API/keeper was started by WP-19b.
CI uses one non-fork job plus five independent fork shards: ordinary fork, swap, cross-fork scenarios,
review integration-price, remaining review forks. Scenario shard membership must exactly match `_createForks()`
callers; shared-fork clock changes otherwise contaminate subsequent suites. CI normally pins latest-minus-300;
this local report uses the fixed archive pins, not an assertion of identical provider state to CI.

### Counts per suite from the fresh run

These are executed test counts, not declared-function counts (fuzz/invariant runs do not inflate test totals).

| Category | File : suite | Passed |
|---|---|---:|
| non-fork | `test/review/adapters/AaveIncomeBurnUnderflow.t.sol:AaveIncomeBurnUnderflowTest` | 3 |
| non-fork | `test/review/adapters/AaveNonUsdcReserveUnwind.t.sol:AaveNonUsdcReserveUnwindTest` | 1 |
| non-fork | `test/review/adapters/AcrossBufferReduction.t.sol:AcrossBufferReductionTest` | 1 |
| non-fork | `test/review/adapters/OracleAwareV4AdapterProbeSize.t.sol:OracleAwareV4AdapterProbeSizeTest` | 1 |
| non-fork | `test/review/core-a/C01_SpotCompositionValuation.t.sol:C01_SpotCompositionValuation` | 3 |
| non-fork | `test/review/core-a/GasFallbackMeasure.t.sol:GasFallbackMeasure` | 2 |
| non-fork | `test/review/core-a/H01_OperatingCashSink.t.sol:H01_OperatingCashSink` | 2 |
| non-fork | `test/review/core-a/H02_ReturnLegDroppedBeforeRefund.t.sol:H02_ReturnLegDroppedBeforeRefund` | 3 |
| non-fork | `test/review/core-a/L01_PayoutFeeTrap.t.sol:L01_PayoutFeeTrap` | 2 |
| non-fork | `test/review/core-a/ShareMathReview.t.sol:ShareMathReview` | 2 |
| non-fork | `test/review/core-b/H01_SpokeCapBypass.t.sol:H01_SpokeCapBypass` | 3 |
| non-fork | `test/review/core-b/H02_ReturnTransferStrandedInUnmatched.t.sol:H02_ReturnTransferStrandedInUnmatched` | 4 |
| non-fork | `test/review/core-b/I01_SubMinimumArrivalAttestedByReport.t.sol:I01_SubMinimumArrivalAttestedByReport` | 1 |
| non-fork | `test/review/core-b/L01_IncomeTimingCapture.t.sol:L01_IncomeTimingCapture` | 1 |
| non-fork | `test/review/core-b/M01_ManagerCapturesBridgeFee.t.sol:M01_ManagerCapturesBridgeFee` | 2 |
| non-fork | `test/review/core-b/New_PreSeededUnlistedArrivalRecovery.t.sol:New_PreSeededUnlistedArrivalRecovery` | 3 |
| non-fork | `test/review/core-b/Refute_RegistryReadGasGriefing.t.sol:Refute_RegistryReadGasGriefing` | 1 |
| non-fork | `test/review/factory/Check_ScriptEnvironment.t.sol:Check_ScriptEnvironment` | 3 |
| non-fork | `test/review/factory/H01_SendToASpokeThatDoesNotExist.t.sol:H01_SendToASpokeThatDoesNotExist` | 3 |
| non-fork | `test/review/factory/H02_DivergentSpokeMandateAcceptedByTheHub.t.sol:H02_DivergentSpokeMandateAcceptedByTheHub` | 2 |
| non-fork | `test/review/factory/L01_MandateSizeInitcodeCliff.t.sol:L01_InitCodeLimitProbe` | 1 |
| non-fork | `test/review/factory/L01_MandateSizeInitcodeCliff.t.sol:L01_MandateSizeInitcodeCliff` | 4 |
| non-fork | `test/review/factory/M01_UnreportableSpokeLocksItsCapital.t.sol:M01_HugeReportLifetime` | 1 |
| non-fork | `test/review/factory/M01_UnreportableSpokeLocksItsCapital.t.sol:M01_UnreportableSpokeLocksItsCapital` | 3 |
| non-fork | `test/review/spoke-a/C01_UnwindAtManipulatedSpot.t.sol:C01_UnwindAtManipulatedSpot` | 1 |
| non-fork | `test/review/spoke-a/H01_DeprecatedAdapterStrandsWeth.t.sol:H01_DeprecatedAdapterStrandsWeth` | 3 |
| non-fork | `test/review/spoke-a/H02_SpokeOperatingCashSink.t.sol:H02_SpokeOperatingCashSink` | 2 |
| non-fork | `test/review/spoke-a/L01_UnwindCannotReach.t.sol:L01_UnwindCannotReach` | 1 |
| non-fork | `test/review/spoke-a/L01_UnwindCannotReach.t.sol:L05_SingleAssetNonUsdcStep` | 1 |
| non-fork | `test/review/spoke-a/L03_FailingStepRollsBackTheUnwind.t.sol:L03_FailingStepRollsBackTheUnwind` | 1 |
| non-fork | `test/review/spoke-a/M01_ManagerSwapExtraction.t.sol:M01_ManagerSwapExtraction` | 2 |
| non-fork | `test/review/spoke-b/H01_ManagerMakesReportsUndeliverable.t.sol:H01_ManagerMakesReportsUndeliverable` | 3 |
| non-fork | `test/review/spoke-b/H02_SpokeOperatingCashDeadEnd.t.sol:H02_SpokeOperatingCashDeadEnd` | 2 |
| non-fork | `test/review/spoke-b/I01_ArrivalWindowNeverDrains.t.sol:I01_ArrivalWindowNeverDrains` | 1 |
| non-fork | `test/review/spoke-b/M01_UnpriceableSpokeToken.t.sol:M01_UnpriceableSpokeToken` | 1 |
| non-fork | `test/review/spoke-b/Measure_ReportBloat.t.sol:Measure_ReportBloat` | 9 |
| non-fork | `test/review/spoke-b/Measure_SteadyStateReadVsWrite.t.sol:Measure_FullWindowSteadyState` | 1 |
| non-fork | `test/review/spoke-b/Measure_SteadyStateReadVsWrite.t.sol:Measure_SteadyStateReadVsWrite` | 1 |
| non-fork | `test/review/spoke-b/Refute_SpokeCrossChainChecks.t.sol:Refute_SpokeCrossChainChecks` | 4 |
| non-fork | `test/review/wp07c/MidSwapReentrantMint.t.sol:MidSwapReentrantMintTest` | 3 |
| non-fork | `test/security/access/BridgeFeeChurn.t.sol:BridgeFeeChurnPoC` | 1 |
| non-fork | `test/security/access/DeprecationTrapsNonBaseTokens.t.sol:DeprecationTrapsNonBaseTokensPoC` | 2 |
| non-fork | `test/security/access/ExpiredSendHomeMint.t.sol:ExpiredSendHomeMintPoC` | 1 |
| non-fork | `test/security/access/FeeRecipientLiveness.t.sol:FeeRecipientLivenessPoC` | 2 |
| non-fork | `test/security/access/ManagerSwapNoPriceGuard.t.sol:ManagerSwapNoPriceGuardPoC` | 2 |
| non-fork | `test/security/access/OperatingCashSink.t.sol:OperatingCashSinkPoC` | 2 |
| non-fork | `test/security/access/ReportGasBrick.t.sol:ReportGasBrickPoC` | 1 |
| non-fork | `test/security/access/RogueSpokeMandate.t.sol:RogueSpokeMandatePoC` | 2 |
| non-fork | `test/security/access/SendToUncreatedSpoke.t.sol:SendToUncreatedSpokePoC` | 2 |
| non-fork | `test/security/access/SpokeCapBypass.t.sol:SpokeCapBypassPoC` | 2 |
| non-fork | `test/security/access/SpotCompositionExit.t.sol:SpotCompositionExitPoC` | 1 |
| non-fork | `test/security/access/UncappedBridgeFee.t.sol:UncappedBridgeFeePoC` | 1 |
| non-fork | `test/security/access/UnmatchedReturnLeg.t.sol:UnmatchedReturnLegPoC` | 1 |
| non-fork | `test/security/access/UnverifiedSpokeToken.t.sol:UnverifiedSpokeTokenPoC` | 1 |
| non-fork | `test/security/accounting/ExpiredSendHomeBaseGap.t.sol:ExpiredSendHomeBaseGapPoC` | 1 |
| non-fork | `test/security/accounting/HubBoundTransferFrozen.t.sol:HubBoundTransferFrozenPoC` | 1 |
| non-fork | `test/security/accounting/JitIncomeCapture.t.sol:JitIncomeCapturePoC` | 1 |
| non-fork | `test/security/accounting/OperatingCashSink.t.sol:OperatingCashSinkPoC` | 1 |
| non-fork | `test/security/accounting/SharePriceSpotManipulation.t.sol:SharePriceSpotManipulationPoC` | 2 |
| non-fork | `test/security/accounting/UnwindAtManipulatedSpot.t.sol:UnwindAtManipulatedSpotPoC` | 1 |
| non-fork | `test/security/crosschain/DustSendsReportBloat.t.sol:DustSendsReportBloatPoC` | 1 |
| non-fork | `test/security/crosschain/ExpiredSendHomeCapBypass.t.sol:ExpiredSendHomeCapBypassPoC` | 1 |
| non-fork | `test/security/crosschain/ExpiredSendHomeDiscountedMint.t.sol:ExpiredSendHomeDiscountedMintPoC` | 1 |
| non-fork | `test/security/crosschain/OperatingCashSweep.t.sol:OperatingCashSweepPoC` | 1 |
| non-fork | `test/security/crosschain/RecoveredIncomeAsPrincipal.t.sol:RecoveredIncomeAsPrincipalTest` | 1 |
| non-fork | `test/security/crosschain/SendHomeStranded.t.sol:SendHomeStrandedPoC` | 2 |
| non-fork | `test/security/crosschain/SpokeCapBypass.t.sol:SpokeCapBypassPoC` | 1 |
| non-fork | `test/security/crosschain/SpotManipulatedReport.t.sol:SpotManipulatedReportPoC` | 1 |
| non-fork | `test/security/integrations/CompositionSharePrice.t.sol:CompositionSharePriceTest` | 1 |
| non-fork | `test/security/integrations/FeeRecipientBlocklist.t.sol:FeeRecipientBlocklistTest` | 1 |
| non-fork | `test/security/integrations/UnwindFloorResidual.t.sol:UnwindFloorResidualTest` | 1 |
| non-fork | `test/security/integrations/UnwindSpotSandwich.t.sol:UnwindSpotSandwichTest` | 1 |
| non-fork | `test/security/invariants/CoreVaultValueInvariant.t.sol:CoreVaultValueInvariantTest` | 3 |
| non-fork | `test/security/invariants/FundSystemPoC.t.sol:FundSystemPoCTest` | 6 |
| non-fork | `test/security/invariants/LibraryPropertyFuzz.t.sol:LibraryPropertyFuzzTest` | 8 |
| non-fork | `test/security/invariants/SpokeVaultLedgerInvariant.t.sol:SpokeVaultLedgerInvariantTest` | 3 |
| non-fork | `test/security/invariants/TransitStateMachineInvariant.t.sol:TransitStateMachineInvariantTest` | 4 |
| non-fork | `test/security/liveness/POC_CompositionMarking.t.sol:POC_CompositionMarking` | 1 |
| non-fork | `test/security/liveness/POC_DeprecatedAdapterUnwind.t.sol:POC_DeprecatedAdapterUnwind` | 1 |
| non-fork | `test/security/liveness/POC_OperatingCashFreeze.t.sol:POC_OperatingCashFreeze` | 1 |
| non-fork | `test/security/liveness/POC_ProtocolRecipientBlocklist.t.sol:POC_ProtocolRecipientBlocklist` | 1 |
| non-fork | `test/security/liveness/POC_ReturnLegValuationGap.t.sol:POC_ReturnLegValuationGap` | 1 |
| non-fork | `test/security/mutation/LibraryMutationKill.t.sol:LibraryMutationKillTest` | 16 |
| non-fork | `test/size/ContractSizes.t.sol:ContractSizesTest` | 3 |
| non-fork | `test/unit/AdapterGuard.t.sol:AdapterGuardTest` | 4 |
| non-fork | `test/unit/DollarIncomeIndex.t.sol:DollarIncomeIndexTest` | 34 |
| non-fork | `test/unit/DollarIncomeIndexModel.t.sol:DollarIncomeIndexLatestRateTest` | 2 |
| non-fork | `test/unit/DollarIncomeIndexModel.t.sol:DollarIncomeIndexModelInvariantTest` | 2 |
| non-fork | `test/unit/DollarIncomeIndexModel.t.sol:DollarIncomeIndexModelTest` | 1 |
| non-fork | `test/unit/IncomeAccumulator.t.sol:IncomeAccumulatorInvariantTest` | 2 |
| non-fork | `test/unit/IncomeAccumulator.t.sol:IncomeAccumulatorTest` | 29 |
| non-fork | `test/unit/Mandate.t.sol:MandateTest` | 51 |
| non-fork | `test/unit/OrderCodec.t.sol:OrderCodecTest` | 18 |
| non-fork | `test/unit/OrderVerifier.t.sol:OrderVerifierTest` | 23 |
| non-fork | `test/unit/ReportCodec.t.sol:ReportCodecTest` | 8 |
| non-fork | `test/unit/ShareMath.t.sol:ShareMathTest` | 28 |
| non-fork | `test/unit/ShareToken.t.sol:ShareTokenInvariantTest` | 2 |
| non-fork | `test/unit/ShareToken.t.sol:ShareTokenTest` | 13 |
| non-fork | `test/unit/TransitEscrow.t.sol:TransitEscrowTest` | 5 |
| non-fork | `test/unit/TransitMessage.t.sol:TransitMessageTest` | 3 |
| non-fork | `test/unit/aave/AaveV3Adapter.t.sol:AaveV3AdapterHalfUpRoundingTest` | 24 |
| non-fork | `test/unit/aave/AaveV3Adapter.t.sol:AaveV3AdapterTest` | 24 |
| non-fork | `test/unit/aave/AaveV3AdapterAdversarial.t.sol:AaveV3AdapterAdversarialTest` | 13 |
| non-fork | `test/unit/aave/AaveV3AdapterFinalVerifyRound1.t.sol:AaveV3AdapterFinalVerifyRound1Test` | 3 |
| non-fork | `test/unit/aave/AaveV3AdapterForeignATokens.t.sol:AaveV3AdapterForeignATokensTest` | 2 |
| non-fork | `test/unit/aave/AaveV3AdapterLifecycle.t.sol:AaveV3AdapterLifecycleHalfUpTest` | 2 |
| non-fork | `test/unit/aave/AaveV3AdapterLifecycle.t.sol:AaveV3AdapterLifecycleTest` | 2 |
| non-fork | `test/unit/across/AcrossBridgeAdapter.adversarial.t.sol:AcrossBridgeAdapterAdversarialTest` | 7 |
| non-fork | `test/unit/across/AcrossBridgeAdapter.t.sol:AcrossBridgeAdapterTest` | 24 |
| non-fork | `test/unit/across/AcrossFeeRule.t.sol:AcrossFeeRuleTest` | 12 |
| non-fork | `test/unit/across/AcrossSendFlow.t.sol:AcrossSendFlowTest` | 6 |
| non-fork | `test/unit/across/BridgeFeeRule.t.sol:BridgeFeeRuleTest` | 9 |
| non-fork | `test/unit/core/CoreVaultAdversarial.t.sol:CoreVaultAdversarialTest` | 11 |
| non-fork | `test/unit/core/CoreVaultAdversarialRound2.t.sol:CoreVaultAdversarialRound2Test` | 8 |
| non-fork | `test/unit/core/CoreVaultClosure.t.sol:CoreVaultClosureTest` | 29 |
| non-fork | `test/unit/core/CoreVaultConsolidateVerify.t.sol:CoreVaultConsolidateVerifyTest` | 6 |
| non-fork | `test/unit/core/CoreVaultConsolidateVerifyRound2.t.sol:CoreVaultConsolidateVerifyRound2Test` | 6 |
| non-fork | `test/unit/core/CoreVaultConsolidateVerifyRound3.t.sol:CoreVaultConsolidateVerifyRound3Test` | 5 |
| non-fork | `test/unit/core/CoreVaultDeposit.t.sol:CoreVaultDepositTest` | 15 |
| non-fork | `test/unit/core/CoreVaultFinalVerify.t.sol:CoreVaultFinalVerifyTest` | 1 |
| non-fork | `test/unit/core/CoreVaultFinalVerifyRound1.t.sol:CoreVaultFinalVerifyRound1Test` | 2 |
| non-fork | `test/unit/core/CoreVaultIncome.t.sol:CoreVaultIncomeTest` | 30 |
| non-fork | `test/unit/core/CoreVaultIncomeHooks.t.sol:CoreVaultIncomeHooksTest` | 4 |
| non-fork | `test/unit/core/CoreVaultIncomeModel.t.sol:CoreVaultIncomeModelTest` | 1 |
| non-fork | `test/unit/core/CoreVaultInvariant.t.sol:CoreVaultInvariantTest` | 6 |
| non-fork | `test/unit/core/CoreVaultLifecycle.t.sol:CoreVaultLifecycleTest` | 9 |
| non-fork | `test/unit/core/CoreVaultManagerBase.t.sol:CoreVaultManagerBaseTest` | 11 |
| non-fork | `test/unit/core/CoreVaultManagerFeeFloor.t.sol:CoreVaultManagerFeeFloorTest` | 2 |
| non-fork | `test/unit/core/CoreVaultMandateV2.t.sol:CoreVaultMandateV2Test` | 7 |
| non-fork | `test/unit/core/CoreVaultPayout.t.sol:CoreVaultPayoutTest` | 32 |
| non-fork | `test/unit/core/CoreVaultPayoutDustSettlement.t.sol:CoreVaultPayoutDustSettlementTest` | 7 |
| non-fork | `test/unit/core/CoreVaultPayoutFeeIdle.t.sol:CoreVaultPayoutFeeIdleTest` | 2 |
| non-fork | `test/unit/core/CoreVaultPayoutLossAccounting.t.sol:CoreVaultPayoutLossAccountingTest` | 6 |
| non-fork | `test/unit/core/CoreVaultProportionalUnwind.t.sol:CoreVaultProportionalUnwindTest` | 6 |
| non-fork | `test/unit/core/CoreVaultSeed.t.sol:CoreVaultSeedTest` | 11 |
| non-fork | `test/unit/core/CoreVaultSetup.t.sol:CoreVaultSetupTest` | 20 |
| non-fork | `test/unit/core/CoreVaultSpokeReview.t.sol:CoreVaultSpokeReviewTest` | 21 |
| non-fork | `test/unit/core/CoreVaultSpokeRoundTwo.t.sol:CoreVaultSpokeRoundTwoTest` | 13 |
| non-fork | `test/unit/core/CoreVaultSpokeSettlement.t.sol:CoreVaultSpokeSettlementTest` | 10 |
| non-fork | `test/unit/core/CoreVaultTransit.t.sol:CoreVaultTransitTest` | 46 |
| non-fork | `test/unit/core/CoreVaultUnwindingFlag.t.sol:CoreVaultUnwindingFlagTest` | 4 |
| non-fork | `test/unit/core/DelayedIncomeCollection.t.sol:DelayedIncomeCollectionTest` | 38 |
| non-fork | `test/unit/core/ExpiredPrincipalRecovery.t.sol:ExpiredPrincipalRecoveryTest` | 33 |
| non-fork | `test/unit/core/ManagementFee.t.sol:ManagementFeeTest` | 10 |
| non-fork | `test/unit/core/ManagerFeeVault.t.sol:ManagerFeeVaultTest` | 4 |
| non-fork | `test/unit/factory/AlphaDeploymentCheck.t.sol:AlphaDeploymentCheckTest` | 5 |
| non-fork | `test/unit/factory/Create3.t.sol:Create3Test` | 17 |
| non-fork | `test/unit/factory/FactoryDeploymentLinking.t.sol:FactoryDeploymentLinkingTest` | 8 |
| non-fork | `test/unit/factory/FundFactory.t.sol:FundFactoryTest` | 34 |
| non-fork | `test/unit/factory/FundFactorySeed.t.sol:FundFactorySeedTest` | 8 |
| non-fork | `test/unit/factory/FundFactorySwapAdapter.t.sol:FundFactorySwapAdapterTest` | 7 |
| non-fork | `test/unit/factory/FundFactoryVerify.t.sol:FundFactoryVerifyTest` | 3 |
| non-fork | `test/unit/factory/FundFactoryVerifyRound2.t.sol:FundFactoryVerifyRound2Test` | 4 |
| non-fork | `test/unit/receiver/ChainlinkPriceSource.t.sol:ChainlinkPriceSourceTest` | 10 |
| non-fork | `test/unit/receiver/ChainlinkPriceSourceAdversarial.t.sol:ChainlinkPriceSourceAdversarialTest` | 9 |
| non-fork | `test/unit/receiver/ManagerRegistry.t.sol:ManagerRegistryTest` | 10 |
| non-fork | `test/unit/receiver/ManagerRegistryAdversarial.t.sol:ManagerRegistryAdversarialTest` | 3 |
| non-fork | `test/unit/receiver/ValueReportReceiver.t.sol:ValueReportReceiverTest` | 32 |
| non-fork | `test/unit/receiver/ValueReportReceiverAdversarial.t.sol:ValueReportReceiverAdversarialTest` | 9 |
| non-fork | `test/unit/security/StaticReviewFindings.t.sol:StaticReviewFindingsTest` | 6 |
| non-fork | `test/unit/spoke/AgedIncomeRefund.t.sol:AgedIncomeRefundTest` | 8 |
| non-fork | `test/unit/spoke/ExecuteOrder.t.sol:ExecuteOrderTest` | 18 |
| non-fork | `test/unit/spoke/OrderResultEncoding.t.sol:OrderResultEncodingTest` | 2 |
| non-fork | `test/unit/spoke/SpokeIncomeCollection.t.sol:SpokeIncomeCollectionTest` | 6 |
| non-fork | `test/unit/spoke/SpokeUnwindOrders.t.sol:SpokeUnwindOrdersTest` | 18 |
| non-fork | `test/unit/spoke/SpokeUnwindReview.t.sol:SpokeUnwindReviewTest` | 23 |
| non-fork | `test/unit/spoke/SpokeUnwindRoundTwo.t.sol:SpokeUnwindRoundTwoTest` | 24 |
| non-fork | `test/unit/spoke/SpokeVaultAdversarial.t.sol:SpokeVaultAdversarialAdapterTest` | 1 |
| non-fork | `test/unit/spoke/SpokeVaultAdversarial.t.sol:SpokeVaultAdversarialHubTest` | 1 |
| non-fork | `test/unit/spoke/SpokeVaultAdversarial.t.sol:SpokeVaultAdversarialSpokeTest` | 6 |
| non-fork | `test/unit/spoke/SpokeVaultConsolidateVerifyRound3.t.sol:SpokeVaultConsolidateVerifyRound3Test` | 2 |
| non-fork | `test/unit/spoke/SpokeVaultFinalVerify.t.sol:SpokeVaultFinalVerifyTest` | 1 |
| non-fork | `test/unit/spoke/SpokeVaultFinalVerifyRound1.t.sol:SpokeVaultFinalVerifyRound1Test` | 2 |
| non-fork | `test/unit/spoke/SpokeVaultHub.t.sol:SpokeVaultHubTest` | 25 |
| non-fork | `test/unit/spoke/SpokeVaultInvariant.t.sol:SpokeVaultInvariantTest` | 3 |
| non-fork | `test/unit/spoke/SpokeVaultMandateV2.t.sol:SpokeVaultMandateV2Test` | 5 |
| non-fork | `test/unit/spoke/SpokeVaultSingleAssetUnwind.t.sol:SpokeVaultSingleAssetUnwindTest` | 2 |
| non-fork | `test/unit/spoke/SpokeVaultSpoke.t.sol:SpokeVaultSpokeTest` | 62 |
| non-fork | `test/unit/spoke/SpokeVaultSwap.t.sol:SpokeVaultSwapTest` | 16 |
| non-fork | `test/unit/swap/UniswapV3SwapAdapter.t.sol:UniswapV3SwapAdapterTest` | 40 |
| non-fork | `test/unit/swap/UniswapV3SwapAdapterRoutes.t.sol:UniswapV3SwapAdapterRoutesTest` | 24 |
| non-fork | `test/unit/v4/UniswapV4Adapter.t.sol:UniswapV4AdapterTest` | 27 |
| non-fork | `test/unit/v4/UniswapV4AdapterAdversarial.t.sol:UniswapV4AdapterAdversarialTest` | 5 |
| fork | `test/fork/Toolchain.t.sol:ToolchainForkTest` | 2 |
| fork | `test/fork/aave/AaveV3Adapter.fork.t.sol:AaveV3AdapterForkTest` | 7 |
| fork | `test/fork/aave/AaveV3AdapterAdversarial.fork.t.sol:AaveV3AdapterAdversarialForkTest` | 3 |
| fork | `test/fork/across/AcrossBridgeAdapter.fork.t.sol:AcrossBridgeAdapterForkTest` | 7 |
| fork | `test/fork/across/AcrossFeeRuleLive.fork.t.sol:AcrossFeeRuleLiveForkTest` | 4 |
| fork | `test/fork/across/AcrossFill.fork.t.sol:AcrossFillForkTest` | 4 |
| fork | `test/fork/across/AcrossSpokePoolReadability.fork.t.sol:AcrossSpokePoolReadabilityForkTest` | 15 |
| fork | `test/fork/closure/FundClosure.fork.t.sol:FundClosureForkTest` | 1 |
| fork | `test/fork/closure/SpokeClosure.fork.t.sol:SpokeClosureForkTest` | 1 |
| fork | `test/fork/core/CoreVaultAcross.t.sol:CoreVaultAcrossForkTest` | 2 |
| fork | `test/fork/e2e/EndToEnd.t.sol:EndToEndForkTest` | 1 |
| fork | `test/fork/e2e/EndToEndAdversarial.t.sol:EndToEndAdversarialForkTest` | 3 |
| fork | `test/fork/e2e/SpokeUnwindOrder.fork.t.sol:SpokeUnwindOrderForkTest` | 1 |
| fork | `test/fork/factory/AlphaDeploymentCheckFork.t.sol:AlphaDeploymentCheckForkTest` | 1 |
| fork | `test/fork/factory/FactoryWiringCheckFork.t.sol:FactoryWiringCheckForkTest` | 3 |
| fork | `test/fork/factory/FundFactoryFork.t.sol:FundFactoryForkTest` | 3 |
| fork | `test/fork/receiver/ChainlinkPriceSourceFork.t.sol:ChainlinkPriceSourceForkTest` | 2 |
| fork | `test/fork/receiver/ValueReportReceiverFork.t.sol:ValueReportReceiverForkTest` | 8 |
| fork | `test/fork/security/SpotCompositionInflation.t.sol:SpotCompositionInflationForkTest` | 1 |
| fork | `test/fork/spoke/ProportionalUnwind.fork.t.sol:ProportionalUnwindForkTest` | 2 |
| fork | `test/fork/spoke/SpokeVaultArbitrumFork.t.sol:SpokeVaultArbitrumForkTest` | 3 |
| fork | `test/fork/spoke/SpokeVaultRobinhoodFork.t.sol:SpokeVaultRobinhoodForkTest` | 3 |
| fork | `test/fork/spoke/SwapAdapterVault.fork.t.sol:SwapAdapterVaultFork` | 5 |
| fork | `test/fork/swap/UniswapV3SwapAdapter.fork.t.sol:UniswapV3SwapAdapterForkTest` | 27 |
| fork | `test/fork/swap/V3ApiRoute.fork.t.sol:V3ApiRouteForkTest` | 3 |
| fork | `test/fork/swap/V3Deployments.fork.t.sol:V3DeploymentsForkTest` | 5 |
| fork | `test/fork/swap/V3TierQuoteGas.fork.t.sol:V3TierQuoteGasForkTest` | 11 |
| fork | `test/fork/v4/UniswapV4AdapterFork.t.sol:UniswapV4AdapterArbitrumForkTest` | 3 |
| fork | `test/fork/v4/UniswapV4AdapterFork.t.sol:UniswapV4AdapterRobinhoodForkTest` | 3 |
| fork | `test/fork/wormhole/OrderChannel.fork.t.sol:OrderChannelForkTest` | 10 |
| fork | `test/review/adapters/AaveLiveReserveFork.t.sol:AaveLiveReserveFork` | 2 |
| fork | `test/review/adapters/HighFeePoolIncomeFork.t.sol:HighFeePoolIncomeFork` | 1 |
| fork | `test/review/adapters/HighFeePoolIncomeFork.t.sol:OnePercentPoolWashFork` | 1 |
| fork | `test/review/adapters/UnwindSwapDepthFork.t.sol:UnwindSwapDepthFork` | 1 |
| fork | `test/review/adapters/WashTradeIncomeFork.t.sol:WashTradeIncomeFork` | 1 |
| fork | `test/review/factory/Fork_AcrossFillToCodelessSpokeVault.t.sol:Fork_AcrossFillToCodelessSpokeVault` | 1 |
| fork | `test/review/integration-price/DeprecatedAdapterFork.t.sol:DeprecatedAdapterFork` | 2 |
| fork | `test/review/integration-price/DepthProbeFork.t.sol:DepthProbeFork` | 2 |
| fork | `test/review/integration-price/FallbackPoisonFork.t.sol:FallbackPoisonFork` | 2 |
| fork | `test/review/integration-price/FeeTierFork.t.sol:FeeTierFork` | 2 |
| fork | `test/review/integration-price/IntegrationFactsFork.t.sol:IntegrationFactsFork` | 1 |
| fork | `test/review/integration-price/SharePriceSpotFork.t.sol:SharePriceSpotFork` | 5 |
| fork | `test/review/integration-price/SpokeReportSpotFork.t.sol:SpokeReportSpotFork` | 1 |
| fork | `test/review/integration-price/UnwindAttackFork.t.sol:UnwindAttackFork` | 26 |
| fork | `test/review/integration-xchain/Fork_ConservationWalk.t.sol:Fork_ConservationWalk` | 1 |
| fork | `test/review/integration-xchain/Fork_RelayerAndOperatingCash.t.sol:Fork_RelayerAndOperatingCash` | 6 |
| fork | `test/review/integration-xchain/Fork_ReportBloat.t.sol:Fork_ReportBloat` | 4 |
| fork | `test/review/integration-xchain/Fork_SpokeCapBypass.t.sol:Fork_SpokeCapBypass` | 2 |
| fork | `test/review/integration-xchain/Fork_SpokeCreation.t.sol:Fork_SpokeCreation` | 2 |
| fork | `test/review/integration-xchain/Fork_TransferHome.t.sol:Fork_TransferHome` | 6 |
| fork | `test/review/spoke-a/C01_UnwindAtManipulatedSpotFork.t.sol:C01_UnwindAtManipulatedSpotFork` | 1 |
| fork | `test/review/spoke-a/L01_UnwindGasPerPositionFork.t.sol:L01_UnwindGasPerPositionFork` | 2 |
| fork | `test/review/spoke-a/M01_ManagerSwapExtractionFork.t.sol:M01_ManagerSwapExtractionFork` | 1 |
| fork | `test/review/spoke-a/PoolDepthProbeFork.t.sol:PoolDepthProbe` | 1 |
| fork | `test/review/spoke-b/Fork_AcrossDeadlineAndDustSends.t.sol:Fork_AcrossDeadlineAndDustSends` | 2 |
| fork | `test/review/wp07c/HopTokenReentrantMintFork.t.sol:HopTokenReentrantMintFork` | 2 |

## 5. Bytecode sizes and margins

Fresh `forge build --sizes`, cross-checked by the 3-test completeness/limit suite. Before/after columns refer
**to this docs-only PR** and are identical. This is not a claim wave-3/4 sizes equal the old #17 baseline.
EIP-170/smallest supported-chain limit **24,576 bytes** for every production contract and linked library.
Inlined library artifact stubs are not deployed executables; CodeStore byte chunks are data, full chunks may use
24,576 bytes intentionally. Complete deployment verification still includes every executable and creation-code link.

| Production contract / linked library | Before B | After B | Margin B |
|---|---:|---:|---:|
| SpokeUnwindLib | 23,473 | 23,473 | 1,103 |
| SpokeVault | 22,887 | 22,887 | 1,689 |
| CoreVault | 22,862 | 22,862 | 1,714 |
| CoreVaultPayoutLogic | 22,256 | 22,256 | 2,320 |
| FundFactory | 18,347 | 18,347 | 6,229 |
| CoreVaultIncomeCollectionLogic | 16,816 | 16,816 | 7,760 |
| CoreVaultClosureLogic | 16,085 | 16,085 | 8,491 |
| CoreVaultTransitLogic | 15,596 | 15,596 | 8,980 |
| UniswapV4Adapter | 14,369 | 14,369 | 10,207 |
| CoreVaultLogic | 13,684 | 13,684 | 10,892 |
| SpokeCrossChainLib | 12,199 | 12,199 | 12,377 |
| CoreVaultIncomeLogic | 12,101 | 12,101 | 12,475 |
| SpokeIncomeLib | 11,631 | 11,631 | 12,945 |
| UniswapV3SwapAdapter | 10,586 | 10,586 | 13,990 |
| AaveV3Adapter | 9,893 | 9,893 | 14,683 |
| ValueReportReceiver | 8,080 | 8,080 | 16,496 |
| AcrossBridgeAdapter | 6,713 | 6,713 | 17,863 |
| SpokeCloseLib | 5,875 | 5,875 | 18,701 |
| ShareToken | 1,822 | 1,822 | 22,754 |
| ChainlinkPriceSource | 1,709 | 1,709 | 22,867 |
| ManagerRegistry | 1,603 | 1,603 | 22,973 |
| Create3Deployer | 1,342 | 1,342 | 23,234 |
| ManagerFeeVault | 1,077 | 1,077 | 23,499 |
| TransitEscrow | 894 | 894 | 23,682 |

**No margin under 1,000 bytes.** SpokeUnwindLib 1,103 is the growth bottleneck; SpokeVault 1,689 and CoreVault
1,714 also warrant monitoring. CoreVaultClosureLogic and SpokeCloseLib splits plus linked income collection
keep each executable legal without via-IR/compiler changes. The old #17 SpokeVault 22,304/2,272 is historical.

## 6. Gas of the main operations

Gas below is **Foundry call-level gas**, not a production fee quote. Relevant suites include failures, retries,
fuzz calls and mocks, so mixed-suite min/mean/median/max can include early reverting calls and varied warm storage.
Deployment/setup-heavy `[PASS] test... (gas: ...)` values are not user-operation gas. Cross-chain operations need
multiple transactions plus externally funded Wormhole fees, Across fees, L1 data fees and relayer latency; gas
cannot be converted here into a dollar cost or used as a maximum safe transaction limit.

```bash
forge test --match-path 'test/unit/{core/CoreVaultDeposit.t.sol,core/CoreVaultTransit.t.sol,core/CoreVaultProportionalUnwind.t.sol,core/CoreVaultSpokeSettlement.t.sol,core/CoreVaultIncome.t.sol,core/DelayedIncomeCollection.t.sol,core/CoreVaultClosure.t.sol,spoke/SpokeUnwindOrders.t.sol,spoke/SpokeIncomeCollection.t.sol}' --gas-report
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
forge test --match-path 'test/fork/{e2e/SpokeUnwindOrder.fork.t.sol,spoke/ProportionalUnwind.fork.t.sol,closure/**}' -j 4 --gas-report
forge test --match-path test/unit/core/CoreVaultPayoutLossAccounting.t.sol --match-test test_DEC118_instantHighLossNeverMovesRequesterCostToFund --gas-report
forge test --match-path test/unit/core/CoreVaultPayoutLossAccounting.t.sol --match-test test_DEC141_standardHighLossNeverExceedsFundCap --gas-report
```

### Real-fork call samples (not the final end-to-end run)

| Contract operation | Min | Mean | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| closeFund | 54,359 | 54,359 | 54,359 | 54,359 | 2 |
| deposit | 344,691 | 344,691 | 344,691 | 344,691 | 5 |
| exitClosedFund | 263,734 | 263,734 | 263,734 | 263,734 | 2 |
| finalizeClosure | 128,808 | 460,116 | 531,998 | 719,543 | 3 |
| requestPayout | 3,026,861 | 3,026,861 | 3,026,861 | 3,026,861 | 1 |
| sendToSpoke | 197,609 | 416,805 | 312,031 | 740,776 | 6 |
| settlePayout | 1,047,177 | 1,047,177 | 1,047,177 | 1,047,177 | 1 |
| unwindAllAfterDeadline | 100,793 | 1,173,211 | 1,709,414 | 1,709,427 | 3 |
| executeOrder | 659,282 | 1,783,261 | 2,230,623 | 2,459,878 | 3 |
| report | 168,373 | 193,273 | 168,373 | 243,074 | 3 |
| unwindForPayout | 201,868 | 1,978,801 | 1,285,927 | 5,141,483 | 4 |

The fork requestPayout sample is Instant with spoke unwind: request -> executeOrder -> report/Across arrival ->
settlePayout, not a single atomic payout. The test's explicit gasleft deltas were **executeOrder 2,544,648**,
**settlePayout 1,115,251**; they differ from the gas-report call accounting above. Sixteen Hub positions unwound
at one fraction in an explicit **5,167,459-gas** delta; not a worst-case 16-position/report certificate.

### Unit/mock income and mode-specific samples

| Operation (mixed unit suites) | Min | Mean | Median | Max | Calls |
|---|---:|---:|---:|---:|---:|
| requestIncomeWithdrawal | 37,893 | 437,003 | 441,157 | 532,457 | 607 |
| settleIncomeWithdrawal | 35,563 | 136,569 | 85,552 | 237,171 | 23 |
| withdrawIncome | 77,884 | 151,304 | 180,160 | 195,026 | 21 |

Income collection includes Hub sale and COLLECT publication; spoke execution/bridge/settlement are separate calls.
The income sample uses mock protocol/bridge results, not measured production collection. `withdrawIncome` is the
final USDC payment without a burn, not an investor Payout.

| Explicit high-loss Hub unwind regression | Operation | Min | Mean | Median | Max | Calls |
|---|---|---:|---:|---:|---:|---:|
| Instant | claimPayout | 274,420 | 274,420 | 274,420 | 274,420 | 1 |
| Instant | requestPayout | 730,688 | 730,688 | 730,688 | 730,688 | 1 |
| Standard | claimPayout | 270,842 | 444,404 | 444,404 | 617,967 | 2 |
| Standard | requestPayout | 263,881 | 263,881 | 263,881 | 263,881 | 1 |

Instant `requestPayout` includes inline Hub unwind/payment attempt; its later claim is retry work. Standard
request reserves Idle and starts the 72-hour term; its two claims include unwind and retry. These deliberately
99%-loss/mock regressions verify who bears costs, not normal market gas estimates. Final successful Instant and
Standard multi-chain operation gas, balances and share-price trajectory will come from PR #24's lifecycle report.

## 7. End-to-end flow and Share Price over time

This is the **implemented flow**, not a claim all phases ran together in this WP:

1. Operator deploys both immutable factories/libraries; manager atomically seeds Hub fund, creates spoke with the
   same Mandate/predicted addresses; keeper delivers first fresh report. Creation/seed pays flow fee.
2. Investors deposit USDC and mint whole shares; per-token income rights are recognized before balance changes.
   Core retains Idle. API/keeper publishes/delivers reports; on-chain deposit itself does not atomically publish.
3. Manager allocates Free Idle to Hub/spoke; Across arrival credit, In-flight Value and Spoke Cap reconcile;
   Mandate adapters open Aave/V4 positions. Swap routes use the separate V3 adapter.
4. Protocol activity generates position income. Reports recognize per-token holder rights; collection sells to
   local stablecoin, seals cohorts and sends spoke dollars to Hub. Credited dollars convert at that sale's rate;
   performance fee splits to manager/protocol, net Attributed Income remains outside Share Assets.
5. Holder requests collection/settles and withdraws USDC Income without share burn, flow fee or Payout Fee.
6. Instant Payout starts inline; Standard reserves Idle, waits 72 hours then holder claims. Both use Idle first,
   proportional Hub unwind and, if needed, authenticated spoke UNWIND. Sales have per-position maximum/exclusion
   memory; proceeds are earmarked and bridge/refund identities retained. Post-unwind report/arrival gates precede
   one-price consolidated payment. Keeper delivers ACKs to retire resolved spoke capacity.
7. Manager closes; management accrual stops. Manager unwinds for the initial 72 hours, then anyone may unwind
   all/publish CLOSE. Finalization waits for fresh empty reports, transits, final collection and cost accounting,
   pays management liability/manager final exit and freezes Hub-USDC `closedSupply`/`closedIdle`.
8. Holders exit the frozen split immediately, no fresh report/Payout Fee; flow fee remains. Late value is outside
   frozen Idle and sweepable to Protocol Recipient.

Share Price is net Share Assets / whole-share supply, not Gross Assets or raw token balances. Management accrual
reduces Share Assets; recognition separates income from principal; collection should not turn Attributed Income
into share backing; Market Costs/bridge fees and mode-specific absorption change post-unwind pricing. Deposits
and burns have whole-share rounding. Frozen closing Share Price does not change with late donations/arrivals.
The fresh isolated spoke-unwind fork logged **0.998786632916418503077228 USDC Share Price** after its Robinhood
report: one fixture datapoint, not the missing founder lifecycle time series.

### End-to-end run (from PR #24)

**PLACEHOLDER — intentionally unfilled until PR #24 merges and its local-e2e/reports evidence is available.**
Do not copy pre-closure smoke data or manufacture a successful final lifecycle run. The future update must cite
PR #24 merged head/release SHA, exact report files, fixed pins, real versus simulated fills, actor balances,
transaction hashes/status, keeper errors/ack queue, phase gas and assertion counts. Include fund creation,
investors in, fees generated, income collected/withdrawn, Instant and Standard Hub/spoke unwinds, refunds/retries,
closure/finalization, every holder's frozen exit and final residuals.

| Phase / timestamp / chain | Transaction hash | Gas / message fee | Idle / reserve / In-flight Value | Share Assets / supply / Share Price | Holder Income / manager / protocol fees |
|---|---|---|---|---|---|
| PENDING PR #24 | PENDING | PENDING | PENDING | PENDING | PENDING |

Historical #23 integration review independently ran **46 steps / 294 assertions**, **3 real Across fills**,
zero simulated fills/errors; API **19 concepts / 19 assertions**. #21 records deployment `up/status/probe`
passing after nested linking fixes. Those are reviewed historical snapshots, not a WP-19b final harness run.

## 8. Known limitations and explicit deferrals

- **Silent spoke:** DEC-157/160 have no inactivity escape; exits needing its fresh report and closure cannot
  finish if a spoke never answers. Permissionless relay replaces a keeper, not the report source.
- **ACK delivery:** spoke capacity is reclaimed only when Hub acknowledgements are delivered. Sixteen undelivered
  ACKs can block later sends/exits; anyone can republish/deliver them, the keeper must. Full Hub credit alone
  is insufficient. Elapsed time is not accepted as the Hub publisher's expiry proof.
- **External transaction funding:** Standard Payout Wormhole fees are caller-funded for now. Manager pays own
  gas (DEC-187); keeper/API/callers pay gas and message fees. Accounting for fund collection/bridge costs is
  not gas reimbursement. DEC-164/165 refund and DEC-171 executor-gas absorption are deferred.
- **Deferred:** DEC-185 spoke gas top-up; native Operating Cash WP-16 (including native cap/unwrap); WP-11 signed
  bridge quotes DEC-168/176; WP-14 entry-time filter DEC-145. Confirmed future refund caps are 0.5 gwei,
  0.001 ETH/call and /day/vault, no minimum interval. Existing base-token Operating Cash defaults 0 but can
  be changed by manager; zero defaults are not enforced globally.
- **Economics:** manager no-floor swaps (S-8/DEC-129), pre-sale spot manipulation/empty-route reference residual
  (C-01/#7) remain accepted only for internal alpha. Optional signed/caller minima are not independent market-price
  guarantees; flow fee is not an attack brake. Partial intermediate V3 route residue can be sweepable.
- **Income:** recognition cohorts are implemented, but missing DEC-145 timestamp filter leaves old income first
  recognized after entry exposed to stale-report attribution. No external incentive collector distribution.
- **Pricing/bridge:** incomplete DEC-123 reliable-source hierarchy/cache initialization; 1:1 USDG ignores depeg.
  Adapter cap is 1% rate plus fixed 0.03 token, not total 1% gap. Mean is own sends, expiry may mean downtime/limits;
  Across refunds observed 57–99 minutes after deadline in research, not an SLA. Native token fixed fee/window
  semantics need redesign before gas bridge support.
- **PR #12 L-2 management rounding:** sub-unit valuation keeps clock; positive old base bounds entrant pre-entry
  overcharge below `(new base / old base)` USDC base units. About 0.01 USDC per 1M over a 100-USDC old base;
  at the 1-USDC test seed the reviewer measured 0.998859 USDC. Each positive rounded booking loses manager <1
  base unit. Local rounding bound, not exact entry-time isolation/global-loss cap. Docs only, NatSpec unchanged.
- **PR #21 L-1:** retirement `abi.encode(records)` matches shared encoder bytes today but bypasses its 416-byte
  size assertion; low code follow-up, not fixed in docs. Immutable API route signer/registry-owner transfer
  discrepancy, guardian/key compromise and absent public depositor allowlist remain disclosed.
- No external audit, current full formal verification/deep-fuzz/coverage/mutation rebaseline, worst-case report
  gas certificate, real new-emitter VAA delivery or production explorer verification claimed by this report.

## 9. Deploy readiness and Rafael's required inputs

**Ready evidence:** #20 dual-chain deploy/checker rehearsal and executable verification extraction; #21 fixed
nested library linking with deployment regressions; fresh green tests/sizes/format. **Not ready evidence:** final
PR #24 lifecycle, final frozen-SHA deployment rehearsal, production guardian service, live Across route confirmation,
explorer source verification, approved real keys/ETH budgets and internal risk acceptance. No mainnet deployment here.

Use [DEPLOYMENT-ALPHA](../DEPLOYMENT-ALPHA.md) for the input sheet/broadcast procedure; its October 2 feature-gap
warnings are historical and superseded by this report, but its final-SHA/mainnet gates still apply. Generic
DEPLOYMENT/INTEGRATIONS historical snapshots are not a substitute for the current artifact-derived link graph.
Rehearse on the final frozen release and update manifests after every bytecode change. Alpha runtime #20 predates
ACK retirement: **verify/add keeper ACK publication/delivery coverage before relying on it**, even if manual
permissionless delivery is available. This docs WP does not certify that older runtime handles the new queue.

| Rafael provides / explicitly approves | Required choice or gate |
|---|---|
| Operator keystore / DEPLOYER_ADDRESS | Same operator both chains (caller-bound factory salt), funded ETH; no raw keys in files/history/PR |
| API_SIGNER and registry owner | Same nonzero immutable route signer; default registry owner that signer, alternate REGISTRY_OWNER explicitly approved |
| ADAPTER_GUARDIAN / PROTOCOL_RECIPIENT | Controlled public addresses, funded guardian wallet, custody/incident policy; not manager fee recipient |
| MANAGER and manager keystore | First fund creator, same wallet both chains; hub USDC seed plus own ETH gas; no manager-registration prerequisite |
| PERFORMANCE_FEE_BPS / MANAGEMENT_FEE_BPS | 1,000..9,000 / 0..500; defaults 2,000 / 0; decrease-only afterward |
| SEED_AMOUNT / MIN_FIRST_DEPOSIT | USDC base units, default minimum 100 USDC; inspect actual charged seed/whole-share receipt |
| SPOKE_CAP / maximum alpha exposure | Hub-USDC base units, default 10,000 USDC spoke cap; no fund-wide on-chain TVL cap or depositor allowlist |
| Mandate investment venues | Initialized/liquid hookless V4 pool keys, ordered WETH/stablecoin tokens, fee/tick spacing (default 500/10), optional usable Aave USDC reserve on Hub |
| Operating Cash | Both floor/top-up explicitly 0 and operator monitors manager changes; no native spend/refund/top-up promised |
| Keeper/API service | Separate funded ALPHA_KEEPER_KEY, ALPHA_API_SIGNER_KEY matching API_SIGNER, secret bearer ALPHA_API_TOKEN; loopback authenticated tunnel, durable queue, supervisor/incident contact |
| RPC/VAA/explorer credentials | Archive helper without URL/key logs; real new-emitter guardian VAAs accepted/delivered in time; live Across tiny fill/refund; Arbiscan credential and Robinhood explorer access (prior 403 unresolved) |
| Final manifest / approval | Release SHA/build, factory salts, all linked addresses/stores, fund creation number/Mandate hash, scanning start blocks, fees/seed/receipts, internal-only risk acceptance and no audited/public marketing |

Do not invent an ETH budget from these call samples: Rafael must approve funded amounts after final release
rehearsal/live chain fee estimation. Public gates remain DEC-133 order: unit -> invariants -> formal -> external audit.
[PRE-MAINNET-CHECKLIST](../security/PRE-MAINNET-CHECKLIST.md) separates historical alpha evidence from open gates.

## 10. Deviations and spec divergences

WP-19b deliberately changes docs only, including README/report; management-fee NatSpec follow-up is documented,
not edited. No new tests/CI shard/fixture/runtime edits; full forks nevertheless rerun for founder evidence.
Final end-to-end section is intentionally deferred to merged PR #24, per task, not omitted silently.

Existing divergences are not resolved by documentation: native Operating Cash/refunds/DEC-185 MVP top-up versus
ruling 2026-10-02 delivery scope; DEC-171 fund executor gas versus external funding; Standard Wormhole fee caller
funding; DEC-145 absent timestamp eligibility; DEC-159 off-chain reporting versus atomic publication; DEC-123
incomplete source hierarchy. DEC-186 Slack cap overrides register's older 10%; registry Ownable2Step/override can
separate owner from immutable API signer; 1% rate plus fixed fee differs from a 1% total gap; raw result retirement
encoder bypasses size assertion. ACK delivery and silent-spoke liveness are implementation/operating prerequisites,
not new waivers. Full dispositions: [OPEN-QUESTIONS](../OPEN-QUESTIONS.md).
