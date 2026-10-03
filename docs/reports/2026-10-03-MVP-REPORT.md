# Founder MVP report — October 3, 2026

## Executive status and evidence boundary

**Code measured:** merged main `334eae6` (October 3, 2026), including PR #24/#25/#26/#28/#29;
merged into the earlier docs baseline as `8e5755b`. These historical contract-suite measurements predate #30.
**DEC-145 is implemented by merged PR #30** and included in deployed release `797d592`.
This update records the live internal alpha and off-chain tooling fixes; no `src/` contracts change.
The historical suite counts below are retained, not presented as a rerun on the deployment release. The completed PR #24 lifecycle is reported in section 7
with its own executed SHA; it is not a mainnet broadcast or a conformance certificate.

**Fresh local results:** 1,548 non-fork tests in 190 suites; 227 fork tests in 57 suites; zero failures/skips.
The 3/3 size tests are included in the non-fork total, not three additional tests. Every listed production
contract/linked library fits 24,576 bytes. Tightest: SpokeVault 22,907 bytes, **1,669 bytes headroom**.
No margin below 1,000; the complete fresh 24-executable inventory is in section 5.

**Historical PR #24 end-to-end:** PASS, 55 steps / 319 assertions, 103 receipts, 6 real fills / 0 simulated, API 31 concepts.
Zero conservation residual; 6.577616-USDC bridge costs and 0.000008-USDC ledgered dust remain explicit.
**Conformance:** merged #28 resolves B-01/B-02/B-03/G-05; DEC-145 is implemented by merged PR #30.
G-02/G-03/G-04/G-06/G-07 are accepted for internal alpha only (section 8), not full-spec conformance.
Merged #29 ships report v5, manual Principal ACKs and **64 shared send slots with acknowledgement-driven reuse**.
Its committed replay has **56 steps / 326 assertions**, zero residual (distinct from #24’s historical figures).

**Readiness:** feature-complete for the landed proportional unwind, dollar income, spoke orders and closure
scope, subject to explicit deferrals/limitations. The internal mainnet alpha is deployed (see the final section); it is not a public release or external audit.
Live reports and the capital/position smoke pass; continuous keeper operation remains an operator gate.

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

GitHub metadata and every review/fix comment on #24/#25/#26/#28/#29/#30 were freshly queried using
`gh pr view <number> --comments` and `--json number,state,mergedAt,mergeCommit,headRefOid,comments`.
#18/#19 landed through #23; #22 landed through the containing #21 rather than a separate conflicting merge.
PR #24 **MERGED on October 3, 2026 at 01:03:52 UTC**, merge `7cea87d`. #25 merged at 00:13:31 UTC
(`2b04b28`); #26 at 01:48:46 UTC (`096df96`); #28 at 01:49:57 UTC (`e90e6a6`); #29 at 03:17:51 UTC
(`334eae6`). #30 remains OPEN at `c36da24`; its evidence is not counted in this measured main run.

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

| [#24](https://github.com/PoolPartyLabs/smartcontract-v2/pull/24) | Rounds 1–2. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/24#issuecomment-5963513579); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/24#issuecomment-5963781347); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/24#issuecomment-5963829282) | Round 1: report-before-fill/temporary-send failures lost Principal ACK retries; arbitrary outflow could be hidden as strategy P&L. Durable ACK retries and independently measured position P&L/conservation fixed both. Round 2 approved ONLY the fix/regression scope, not a new full contract-conformance audit. |
| [#25](https://github.com/PoolPartyLabs/smartcontract-v2/pull/25) | One orchestrator check; no numbered independent round. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/25#issuecomment-5963485898) | Approved the one-line shared-result encoder fix from #21 round-3 L-1 with append/refund/retirement/CLOSE regression; CI green. |
| [#26](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26) | Rounds 1–3 plus fix replies; no final numbered approval comment visible. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26#issuecomment-5963535568); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26#issuecomment-5963760912); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26#issuecomment-5963839481); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26#issuecomment-5963911614); [comment 5](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26#issuecomment-5963975875); [comment 6](https://github.com/PoolPartyLabs/smartcontract-v2/pull/26#issuecomment-5964048024) | Round 1: credential leakage, oversized alpha rehearsal/sub-minimum Income assumptions, incomplete executable runbook, stale executable/seed-minimum facts. Round 2: parenthesized URL redaction leakage and submitted hashes lost on receipt errors. Round 3: unsupported/encoded/Unicode host fallback retained userinfo. Fix replies record fail-closed authority stripping/regressions, fsynced journal/reconciliation, alpha-sized executable smoke and verification inventory. Merged status does not establish a separately visible round-4 approval. |
| [#28](https://github.com/PoolPartyLabs/smartcontract-v2/pull/28) | Rounds 1–2. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/28#issuecomment-5964072863); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/28#issuecomment-5964132093); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/28#issuecomment-5964163311) | Round 1: B-02 late Principal dust finalized but stayed ledgered/unsweepable. Arrival-path exclusion preserves credits and permits sweeping without a second CLOSE. Round 2 approved ONLY that fix commit/regression, including the two-fork ordinary-report-after-late-arrival case. B-01/B-03/G-05 checks recorded in round 1. |
| [#29](https://github.com/PoolPartyLabs/smartcontract-v2/pull/29) | Rounds 1–2. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/29#issuecomment-5964522295); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/29#issuecomment-5964615006); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/29#issuecomment-5964841756); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/29#issuecomment-5964911497) | Round 1: alpha keeper silently completed Income work without ACK, exhausting slots. Durable all-kind work stays until terminal spoke confirmation; retry/republish, 65 on-chain collection sends and 130-send runtime regressions, snapshot rollback and mined mint-price assertions. Round 2 approved the fix scope and independently reproduced default warm-up/replay and alpha Income/manual slot release. |
| [#30](https://github.com/PoolPartyLabs/smartcontract-v2/pull/30) | Rounds 1–2 plus fix replies; subsequently merged before release `797d592`. [comment 1](https://github.com/PoolPartyLabs/smartcontract-v2/pull/30#issuecomment-5964884845); [comment 2](https://github.com/PoolPartyLabs/smartcontract-v2/pull/30#issuecomment-5965066647); [comment 3](https://github.com/PoolPartyLabs/smartcontract-v2/pull/30#issuecomment-5965106507); [comment 4](https://github.com/PoolPartyLabs/smartcontract-v2/pull/30#issuecomment-5965160148) | Round 1 high: activated waiting-lot settlement exceeded transaction gas, blocking withdrawals/live/Closed exits. Fixed with shared 64-token-operation budget, persisted checkpoints and permissionless continuation. Round 2 reproduced 2,038,401 gas in 90 calls and verified settlement, but found medium: test-only SettlementCoreVault 31,536 B broke exact size build/CI. Fix c36da24 links history preparation into a test library, fixture 22,927 B / 1,649 margin; clean exact build/regressions pass in fix reply, production unchanged. Historical review observations; #30 is implemented in deployed release `797d592`. |

## 4. Fresh verification and reproducibility

Measured October 3 in this docs worktree after merging origin/main `334eae6`, with shared dependency/RPC
configuration and no source edits.
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
| Non-fork, including size | 190 | 1,548 | 0 | 0 |
| Fork including review Fork suites | 57 | 227 | 0 | 0 |
| Size, separately rerun (already included above) | 1 | 3 | 0 | 0 |
| Historical f88b25b unit gas suites (repeated subset) | 9 | 198 | 0 | 0 |
| Historical f88b25b fork gas suites (repeated subset) | 4 | 5 | 0 | 0 |
| Historical Instant high-loss gas regression (repeated subset) | 1 | 1 | 0 | 0 |
| Historical Standard high-loss gas regression (repeated subset) | 1 | 1 | 0 | 0 |

Archive fork pins: **Arbitrum 511007613; Robinhood 78293056**, exported by the helper in the same shell before
each fork command. Never log URLs/keys. Full fork run completed locally on the merged tree, not copied from a PR. Build and format
passed; existing compiler/lint warnings retained. No harness/Anvil/API/keeper was started by WP-19b.
CI uses one non-fork job plus five independent fork shards: ordinary fork, swap, cross-fork scenarios,
review integration-price, remaining review forks. Scenario shard membership must exactly match `_createForks()`
callers; shared-fork clock changes otherwise contaminate subsequent suites. CI normally pins latest-minus-300;
this local report uses the fixed archive pins, not an assertion of identical provider state to CI.

### Counts per suite from the fresh run

Every row below is regenerated from the fresh merged-branch run, including conformance and manual/Income
ACK regressions. Gas subsets in section 6 remain explicitly historical measurements.

These are executed test counts, not declared-function counts (fuzz/invariant runs do not inflate test totals).

| Category | File : suite | Passed |
|---|---|---:|
| fork | `test/fork/aave/AaveV3Adapter.fork.t.sol:AaveV3AdapterForkTest` | 7 |
| fork | `test/fork/aave/AaveV3AdapterAdversarial.fork.t.sol:AaveV3AdapterAdversarialForkTest` | 3 |
| fork | `test/fork/across/AcrossBridgeAdapter.fork.t.sol:AcrossBridgeAdapterForkTest` | 7 |
| fork | `test/fork/across/AcrossFeeRuleLive.fork.t.sol:AcrossFeeRuleLiveForkTest` | 4 |
| fork | `test/fork/across/AcrossFill.fork.t.sol:AcrossFillForkTest` | 4 |
| fork | `test/fork/across/AcrossSpokePoolReadability.fork.t.sol:AcrossSpokePoolReadabilityForkTest` | 15 |
| fork | `test/fork/closure/FundClosure.fork.t.sol:FundClosureForkTest` | 1 |
| fork | `test/fork/closure/SpokeClosure.fork.t.sol:SpokeClosureForkTest` | 2 |
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
| fork | `test/fork/spoke/ManualSendAcknowledgement.fork.t.sol:ManualSendAcknowledgementForkTest` | 4 |
| fork | `test/fork/spoke/ProportionalUnwind.fork.t.sol:ProportionalUnwindForkTest` | 2 |
| fork | `test/fork/spoke/SpokeVaultArbitrumFork.t.sol:SpokeVaultArbitrumForkTest` | 3 |
| fork | `test/fork/spoke/SpokeVaultRobinhoodFork.t.sol:SpokeVaultRobinhoodForkTest` | 3 |
| fork | `test/fork/spoke/SwapAdapterVault.fork.t.sol:SwapAdapterVaultFork` | 5 |
| fork | `test/fork/swap/UniswapV3SwapAdapter.fork.t.sol:UniswapV3SwapAdapterForkTest` | 27 |
| fork | `test/fork/swap/V3ApiRoute.fork.t.sol:V3ApiRouteForkTest` | 3 |
| fork | `test/fork/swap/V3Deployments.fork.t.sol:V3DeploymentsForkTest` | 5 |
| fork | `test/fork/swap/V3TierQuoteGas.fork.t.sol:V3TierQuoteGasForkTest` | 11 |
| fork | `test/fork/Toolchain.t.sol:ToolchainForkTest` | 2 |
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
| non-fork | `test/unit/AdapterGuard.t.sol:AdapterGuardTest` | 4 |
| non-fork | `test/unit/core/ClosureIncomeDust.t.sol:ClosureIncomeDustTest` | 31 |
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
| non-fork | `test/unit/core/ExpiredPrincipalRecovery.t.sol:ExpiredPrincipalRecoveryTest` | 35 |
| non-fork | `test/unit/core/ManagementFee.t.sol:ManagementFeeTest` | 10 |
| non-fork | `test/unit/core/ManagerFeeVault.t.sol:ManagerFeeVaultTest` | 4 |
| non-fork | `test/unit/core/ManualSendAcknowledgement.t.sol:CoreManualSendAcknowledgementTest` | 13 |
| non-fork | `test/unit/core/OperatingCashMvp.t.sol:OperatingCashMvpTest` | 2 |
| non-fork | `test/unit/DollarIncomeIndex.t.sol:DollarIncomeIndexTest` | 34 |
| non-fork | `test/unit/DollarIncomeIndexModel.t.sol:DollarIncomeIndexLatestRateTest` | 2 |
| non-fork | `test/unit/DollarIncomeIndexModel.t.sol:DollarIncomeIndexModelInvariantTest` | 2 |
| non-fork | `test/unit/DollarIncomeIndexModel.t.sol:DollarIncomeIndexModelTest` | 1 |
| non-fork | `test/unit/factory/AlphaDeploymentCheck.t.sol:AlphaDeploymentCheckTest` | 5 |
| non-fork | `test/unit/factory/Create3.t.sol:Create3Test` | 17 |
| non-fork | `test/unit/factory/FactoryDeploymentLinking.t.sol:FactoryDeploymentLinkingTest` | 8 |
| non-fork | `test/unit/factory/FundFactory.t.sol:FundFactoryTest` | 34 |
| non-fork | `test/unit/factory/FundFactorySeed.t.sol:FundFactorySeedTest` | 8 |
| non-fork | `test/unit/factory/FundFactorySwapAdapter.t.sol:FundFactorySwapAdapterTest` | 7 |
| non-fork | `test/unit/factory/FundFactoryVerify.t.sol:FundFactoryVerifyTest` | 3 |
| non-fork | `test/unit/factory/FundFactoryVerifyRound2.t.sol:FundFactoryVerifyRound2Test` | 4 |
| non-fork | `test/unit/IncomeAccumulator.t.sol:IncomeAccumulatorInvariantTest` | 2 |
| non-fork | `test/unit/IncomeAccumulator.t.sol:IncomeAccumulatorTest` | 29 |
| non-fork | `test/unit/Mandate.t.sol:MandateTest` | 51 |
| non-fork | `test/unit/OrderCodec.t.sol:OrderCodecTest` | 18 |
| non-fork | `test/unit/OrderVerifier.t.sol:OrderVerifierTest` | 23 |
| non-fork | `test/unit/receiver/ChainlinkPriceSource.t.sol:ChainlinkPriceSourceTest` | 10 |
| non-fork | `test/unit/receiver/ChainlinkPriceSourceAdversarial.t.sol:ChainlinkPriceSourceAdversarialTest` | 9 |
| non-fork | `test/unit/receiver/ManagerRegistry.t.sol:ManagerRegistryTest` | 10 |
| non-fork | `test/unit/receiver/ManagerRegistryAdversarial.t.sol:ManagerRegistryAdversarialTest` | 3 |
| non-fork | `test/unit/receiver/ValueReportReceiver.t.sol:ValueReportReceiverTest` | 32 |
| non-fork | `test/unit/receiver/ValueReportReceiverAdversarial.t.sol:ValueReportReceiverAdversarialTest` | 9 |
| non-fork | `test/unit/ReportCodec.t.sol:ReportCodecTest` | 8 |
| non-fork | `test/unit/security/StaticReviewFindings.t.sol:StaticReviewFindingsTest` | 6 |
| non-fork | `test/unit/ShareMath.t.sol:ShareMathTest` | 28 |
| non-fork | `test/unit/ShareToken.t.sol:ShareTokenInvariantTest` | 2 |
| non-fork | `test/unit/ShareToken.t.sol:ShareTokenTest` | 13 |
| non-fork | `test/unit/spoke/AgedIncomeRefund.t.sol:AgedIncomeRefundTest` | 8 |
| non-fork | `test/unit/spoke/ClosureDust.t.sol:ClosureIncomeDustTest` | 7 |
| non-fork | `test/unit/spoke/ClosureDust.t.sol:ClosurePrincipalDustTest` | 24 |
| non-fork | `test/unit/spoke/ExecuteOrder.t.sol:ExecuteOrderTest` | 18 |
| non-fork | `test/unit/spoke/HubClosureExposure.t.sol:HubClosureExposureTest` | 3 |
| non-fork | `test/unit/spoke/ManualSendAcknowledgement.t.sol:ManualSendAcknowledgementTest` | 33 |
| non-fork | `test/unit/spoke/OrderResultEncoding.t.sol:OrderResultEncodingTest` | 2 |
| non-fork | `test/unit/spoke/SpokeIncomeCollection.t.sol:SpokeIncomeCollectionTest` | 6 |
| non-fork | `test/unit/spoke/SpokeUnwindOrders.t.sol:SpokeUnwindOrdersTest` | 18 |
| non-fork | `test/unit/spoke/SpokeUnwindReview.t.sol:SpokeUnwindReviewTest` | 23 |
| non-fork | `test/unit/spoke/SpokeUnwindRoundTwo.t.sol:SpokeUnwindRoundTwoTest` | 25 |
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
| non-fork | `test/unit/TransitEscrow.t.sol:TransitEscrowTest` | 5 |
| non-fork | `test/unit/TransitMessage.t.sol:TransitMessageTest` | 3 |
| non-fork | `test/unit/v4/UniswapV4Adapter.t.sol:UniswapV4AdapterTest` | 27 |
| non-fork | `test/unit/v4/UniswapV4AdapterAdversarial.t.sol:UniswapV4AdapterAdversarialTest` | 5 |

## 5. Bytecode sizes and margins

Fresh `forge build --sizes`, cross-checked by the 3-test completeness/limit suite. Before/after columns refer
**to docs edits on merged main** and are identical. PR #25 reduced SpokeUnwindLib by 24 bytes
(historical 23,473 -> 23,449); #28/#29 further change the runtime inventory below. This documentation does not
change runtime size. This is not a claim wave-3/4 sizes equal the old #17 baseline.
EIP-170/smallest supported-chain limit **24,576 bytes** for every production contract and linked library.
Inlined library artifact stubs are not deployed executables; CodeStore byte chunks are data. #28 reserves
1,000 bytes: full chunk runtime is at most 23,576 bytes, not the old 24,576-byte full-limit size. Complete deployment verification still includes every executable and creation-code link.

| Production contract / linked library | Before B | After B | Margin B |
|---|---:|---:|---:|
| SpokeVault | 22,907 | 22,907 | 1,669 |
| CoreVaultPayoutLogic | 22,547 | 22,547 | 2,029 |
| CoreVault | 22,358 | 22,358 | 2,218 |
| SpokeUnwindLib | 21,594 | 21,594 | 2,982 |
| FundFactory | 18,347 | 18,347 | 6,229 |
| CoreVaultIncomeCollectionLogic | 17,689 | 17,689 | 6,887 |
| CoreVaultClosureLogic | 17,052 | 17,052 | 7,524 |
| SpokeCrossChainLib | 16,953 | 16,953 | 7,623 |
| CoreVaultTransitLogic | 16,005 | 16,005 | 8,571 |
| UniswapV4Adapter | 14,369 | 14,369 | 10,207 |
| CoreVaultLogic | 13,612 | 13,612 | 10,964 |
| SpokeIncomeLib | 12,563 | 12,563 | 12,013 |
| CoreVaultIncomeLogic | 12,236 | 12,236 | 12,340 |
| UniswapV3SwapAdapter | 10,586 | 10,586 | 13,990 |
| AaveV3Adapter | 9,893 | 9,893 | 14,683 |
| ValueReportReceiver | 8,309 | 8,309 | 16,267 |
| AcrossBridgeAdapter | 6,713 | 6,713 | 17,863 |
| SpokeCloseLib | 5,875 | 5,875 | 18,701 |
| ShareToken | 1,822 | 1,822 | 22,754 |
| ChainlinkPriceSource | 1,709 | 1,709 | 22,867 |
| ManagerRegistry | 1,603 | 1,603 | 22,973 |
| Create3Deployer | 1,342 | 1,342 | 23,234 |
| ManagerFeeVault | 1,077 | 1,077 | 23,499 |
| TransitEscrow | 894 | 894 | 23,682 |

**No margin under 1,000 bytes.** SpokeVault 1,669 is the growth bottleneck; CoreVaultPayoutLogic 2,029 and CoreVault
2,218 also warrant monitoring. CoreVaultClosureLogic and SpokeCloseLib splits plus linked income collection
keep each executable legal without via-IR/compiler changes. The old #17 SpokeVault 22,304/2,272 is historical.

## 6. Gas of the main operations

Gas below is **historical f88b25b Foundry call-level gas**, not a production fee quote or a fresh gas rerun.
Section 7 adds receipt-derived min/average/max for every operation in the authoritative PR #24 lifecycle.
Relevant suites include failures, retries,
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
Standard multi-chain operation gas, balances and Share Price trajectory appear in PR #24's lifecycle evidence
in section 7, separately from these historical mock samples.

## 7. End-to-end flow and Share Price over time

This is the **implemented flow**; the completed PR #24 run below supplies the step-by-step evidence.
That successful path does not waive the conformance/recovery limitations in section 8:

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
report: one historical fixture datapoint, separate from the completed founder lifecycle time series below.

### End-to-end run (from PR #24)

**PASS: the complete two-fork lifecycle, including the recovery rerun.** PR #24 merged into main as
`7cea87d1a05b6150925de0cc8799d788f84ce958` (use the repository merge commit as the baseline; the
executed run itself is pinned to `4eba29eea896ffbb7d6304e58d8d833372156d9d`). The authoritative round-1 rerun
supersedes the original October 2 UTC run and its conservation figures:

- [Completion and recovery report](../../local-e2e/reports/2026-10-03-wp15b-completed.md).
- [All 55 steps, actor balances and receipts](../../local-e2e/reports/2026-10-03T00-44-44Z-scenario.md)
  and [machine-readable accounting/evidence](../../local-e2e/reports/2026-10-03T00-44-44Z-scenario.json).
- [API probe](../../local-e2e/reports/2026-10-03T00-44-01Z-api-probe.md)
  and [API JSON](../../local-e2e/reports/2026-10-03T00-44-01Z-api-probe.json): 31 concepts passed.

Wall-clock run: **October 3, 2026, 00:44:44–00:46:06 UTC** (01:44:44–01:46:06 Lisbon),
82 seconds, 55 steps / 319 assertions, 103 receipt-derived transactions / 99,813,982 gas.
Archive pins: Arbitrum 511007613 (chain 42161), Robinhood 78293056 (chain 4663).
The keeper made **6 real SpokePool fills, 0 simulated fills, 22 report deliveries and 10 orders**;
exactly one intentionally injected ACK-send RPC error recovered. Local guardian signing and a funded local
relayer on mainnet forks are not evidence of production guardian acceptance or independent relayer service.
Chain timestamps advance through artificial warps, including 72-hour terms and closure: the recorded
October 11 Closing timestamp is simulated chain time, not an October 11 real-world run.
The scenario submits lifecycle calls directly through JSON-RPC; the HTTP API probe is not a second full lifecycle.

#### Executed lifecycle

1. **Creation and manager seed (steps 1–5).** One deterministic factory address on both chains creates the
   Core Vault / Spoke Vault with matching Mandate. The 100-USDC seed budget produces 99 whole shares at
   Share Price 1.000000, 99.000000 USDC Idle and a 0.250000 USDC flow fee. The actual capital charge is
   99.250000 USDC, not the whole 100-USDC budget. Mandate: 4,000-USDC Spoke Cap, 2% Payout Fee,
   72-hour Standard term, 20% performance fee, 1,588-second report lifetime, Operating Cash floor/top-up 0.
2. **Ana and Hub investment (steps 6–12).** Ana deposits 10,000 USDC, receives 9,975 shares and pays a
   25-USDC flow fee. The manager allocates 5,000 USDC to the Hub Spoke Vault, supplies 2,000 USDC to Aave,
   swaps 1,500 USDC through the separate V3 adapter and opens the WETH/USDC V4 range. A one-hour warp
   generates 0.008479 USDC Aave interest; trader swaps generate 0.000097 WETH + 0.292078 USDC V4 fees.
   Income is separate from Share Assets. A 1-bp swap bound deterministically reverts `InsufficientOutput`.
3. **Capital and fees on the spoke (steps 13–24).** Above-cap sends and caller-supplied bridge quotes revert.
   Across sends 4,000 USDC for 3,996.770000 USDG, with 3.230000 USDC bridge cost fixed by the adapter.
   The real `FilledRelay` receipt matches recipient/token/amount and the vault arrival; no Operating Cash
   top-up occurs. An API-signed V3 route buys WETH, the manager opens WETH/USDG V4, and trader swaps
   generate 0.000094 WETH + 0.289509 USDG fees. The local guardian report is delivered to the Hub:
   outbound transit becomes ArrivalConfirmed and In-flight Value becomes zero.
4. **Historical manual return (steps 25–27).** A 500-USDG manual `sendToHub` returns 499.570000 USDC
   (0.430000 bridge cost), held until a Principal report authorizes Idle credit. This is evidence of that
   executed run, **not an authorized alpha procedure**: the separate open contract issue below leaves a
   manual send Sent after acknowledgement. The runbook forbids manual Principal returns until its fix lands.
5. **Recognize, collect, split and withdraw income (steps 28–31).** Hub collection returns 0.300604 USDC
   + 0.000097 WETH; COLLECT also sells spoke income, bridges dollars and settles attribution in Hub USDC.
   At step 29, 1.085840 USDC has been collected, 0.217164 paid as performance fees (manager 0.108583,
   protocol 0.108581), and 0.868676 assigned to holders. Bruno then uses an 11,000-USDC budget:
   actual charge 10,999.542047 USDC, 10,975 shares at 0.999730, flow fee 27.500000 USDC.
   Ana withdraws 0.860137 USDC Income without burning shares or paying a flow fee / Payout Fee.
6. **Standard Payout after 72 hours (steps 32–34).** Ana requests 3,000 USDC; Idle is reserved and an early
   claim reverts `PayoutTermNotEnded`. After a 72-hour warp, refreshed price feed and fresh spoke report,
   3,001 shares burn at 0.999648; Ana receives 2,992.444724 USDC, flow fee 7.499861, no Payout Fee.
7. **Instant Payout with Hub unwind (steps 35–36).** Bruno's request exceeds Free Idle and starts inline
   proportional Hub/spoke unwind; no shares burn before the required return/report. Hub unwind proceeds
   are 1,017.244109 USDC. Final settlement burns 10,549 shares at 0.999636, pays 10,307.482583 USDC,
   and retains the 210.903373-USDC Payout Fee in Idle. Remaining Share Price rises to 1.027761.
   Bruno retains 426 shares: this Instant Payout is not his full closed-fund exit.
8. **Payout with spoke unwind through Wormhole (steps 37–39).** Ana requests 4,695.521566 USDC, beyond
   Idle plus Hub liquidity. UNWIND order
   `0x9d15c1f46f7101b27514072c0dd1bdb20134b60c00b20f1ad3be9dca565d25f7` is executed on the spoke.
   A Standard Payout with `maxLossBps=1` excludes two positions; a stranger settles 1,310.087178 USDC,
   leaving 3,382.150962 outstanding. Retry with `maxLossBps=0` retains the request/fraction, sells only
   previously undelivered positions and pays 3,373.069105 USDC. Fresh post-unwind reports and credited
   arrivals precede settlement; already-delivered Aave principal is not sold twice. The retry records
   **0.000000 USDC positive Market Costs absorbed by the fund**; it does not demonstrate a positive-cost case.
9. **Invariants and closure (steps 40–50).** Payout Reserve stays <= Idle, supply stays in whole shares and
   Share Assets reconcile. A 1,234-USDC donation is swept without changing Share Price. The manager's
   half-peak-base crossing reverts `ManagerMustCloseFund`; `closeFund` enters Closing and stops accrual.
   Deposits/requests/claims/repeated closure revert; the manager still withdraws 0.008535 USDC Income.
   Manager closes remaining Aave within 72 hours; a stranger's early unwind is refused, then succeeds after
   the deadline. CLOSE executes remotely, its Principal fill/empty report arrive, and ACKs retire order-linked
   Principal sends. A terminal CLOSE retry restores the result removed by ACK before final income collection.
   Finalization pays 2.374759 USDC management fees, burns/pays the manager, and freezes
   **2,904.439117 USDC / 2,830 shares** for the remaining investors.
10. **Closed-fund exits and conservation (steps 51–55).** After a deliberate 1,589-second warp makes the
    report stale, Ana receives 2,461.065710 USDC and Bruno 436.112309 USDC from the frozen split, without
    another report or Payout Fee (flow fees still apply). Supply reaches zero; unledgered excess is swept.
    Eight USDC base units remain as ledgered rounding dust, not an unexplained loss or a claimed successful dust sweep.

#### Share Price, assets and fee liabilities over the steps

All monetary columns are **USDC**, six decimals truncated for display. These are end-of-step snapshots,
not transaction execution prices; step 36's post-burn Share Price differs from its burn price. Management
accrual is a liability, not cash already paid; performance/flow fees are cumulative USDC paid. Payout Fee is
cumulative retained Idle, not external payment; bridge costs sum both routes.
Gross Assets remains an informational aggregate with the accepted G-03 Income-in-transit omission.
All 55 snapshots, Idle, Free Idle, Payout Reserve, In-flight Value, transaction hashes, block numbers,
effective gas prices and token balances are preserved in the linked Markdown/JSON evidence.

| Step / event | Share Price | Share Assets | Gross Assets | Management accrued | Management paid | Performance paid | Flow paid | Payout Fee retained | Bridge costs |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 5: Manager seed | 1.000000 | 99.000000 | 99.000000 | 0.000000 | 0.000000 | 0.000000 | 0.250000 | 0.000000 | 0.000000 |
| 6: Ana deposit | 0.999999 | 10,073.999997 | 10,074.000000 | 0.000003 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 0.000000 |
| 11: Hub interest | 1.000089 | 10,074.897773 | 10,074.917788 | 0.011536 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 0.000000 |
| 12: Hub V4 fees | 1.000089 | 10,074.897770 | 10,075.477417 | 0.011539 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 0.000000 |
| 16: Capital sent | 0.999768 | 10,071.667771 | 10,072.247420 | 0.011538 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 3.230000 |
| 18: Spoke arrival | 0.999768 | 10,071.667771 | 10,072.247420 | 0.011538 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 3.230000 |
| 21: Spoke V4 fees | 0.999768 | 10,071.667771 | 10,072.247420 | 0.011538 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 3.230000 |
| 24: Spoke report accepted | 0.999773 | 10,071.714934 | 10,072.843165 | 0.011570 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 3.230000 |
| 27: Manual Principal credited | 0.999730 | 10,071.284912 | 10,072.413182 | 0.011592 | 0.000000 | 0.000000 | 25.250000 | 0.000000 | 3.660000 |
| 29: Income collected | 0.999730 | 10,071.284883 | 10,072.165198 | 0.011621 | 0.000000 | 0.217164 | 25.250000 | 0.000000 | 3.690439 |
| 30: Bruno deposit | 0.999730 | 21,043.326930 | 21,044.207245 | 0.011621 | 0.000000 | 0.217164 | 52.750000 | 0.000000 | 3.690439 |
| 31: Ana Income Withdrawal | 0.999730 | 21,043.326930 | 21,043.347108 | 0.011621 | 0.000000 | 0.217164 | 52.750000 | 0.000000 | 3.690439 |
| 32: Standard requested | 0.999730 | 21,043.326930 | 21,043.347108 | 0.011621 | 0.000000 | 0.217164 | 52.750000 | 0.000000 | 3.690439 |
| 34: Standard after 72 h | 0.999648 | 18,041.652744 | 18,044.011877 | 1.741222 | 0.000000 | 0.217164 | 60.249861 | 0.000000 | 3.690439 |
| 35: Instant pending | 0.999634 | 18,041.399527 | 18,043.758660 | 1.741222 | 0.000000 | 0.217164 | 60.249861 | 0.000000 | 3.690439 |
| 36: Instant settled | 1.027761 | 7,707.179774 | 7,709.538960 | 1.741262 | 0.000000 | 0.217164 | 86.612782 | 210.903373 | 4.027144 |
| 37: Spoke UNWIND requested | 1.027676 | 7,706.546299 | 7,710.081915 | 2.374736 | 0.000000 | 0.217164 | 86.612782 | 210.903373 | 4.027144 |
| 38: Partial Payout | 1.027676 | 6,393.175689 | 6,396.711313 | 2.374743 | 0.000000 | 0.217164 | 89.896208 | 210.903373 | 4.027144 |
| 39: Retry settled | 1.027194 | 3,008.651461 | 3,012.187105 | 2.374757 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 5.574485 |
| 41: Donation swept | 1.027194 | 3,008.651461 | 3,012.187105 | 2.374757 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 5.574485 |
| 44: Closing | 1.027194 | 3,008.651459 | 3,012.187107 | 2.374759 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 5.574485 |
| 45: Manager Income Withdrawal | 1.027194 | 3,008.651459 | 3,012.178572 | 2.374759 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 5.574485 |
| 47: Post-deadline unwind | 1.026687 | 3,007.169038 | 3,010.696151 | 2.374759 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 5.574485 |
| 48: CLOSE fill/report | 1.026303 | 3,006.043170 | 3,009.570283 | 2.374759 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 6.577616 |
| 49: Principal ACKs delivered | 1.026303 | 3,006.043170 | 3,009.570283 | 2.374759 | 0.000000 | 0.217164 | 98.350015 | 210.903373 | 6.577616 |
| 50: Closure finalized | 1.026303 | 2,904.439117 | 2,905.352977 | 0.000000 | 2.374759 | 0.447631 | 98.604025 | 210.903373 | 6.577616 |
| 52: Ana Closed exit | 1.026303 | 437.205323 | 437.484187 | 0.000000 | 2.374759 | 0.447631 | 104.772109 | 210.903373 | 6.577616 |
| 53: Bruno Closed exit | 1.000000 | 0.000001 | 0.000009 | 0.000000 | 2.374759 | 0.447631 | 105.865122 | 210.903373 | 6.577616 |
| 54: Excess swept | 1.000000 | 0.000000 | 0.000008 | 0.000000 | 2.374759 | 0.447631 | 105.865122 | 210.903373 | 6.577616 |
| 55: Conservation checked | 1.000000 | 0.000000 | 0.000008 | 0.000000 | 2.374759 | 0.447631 | 105.865122 | 210.903373 | 6.577616 |

#### Each investor's position

Each cell is **whole shares / share value in USDC / converted Attributed Income owed in USDC**. Token
rights not yet converted are not represented by `incomeOwed`; a zero dollar balance is not proof that
all remote income rights have been collected (G-01/G-02). Full wallet USDC/USDG/WETH balances appear
at every step in the evidence; the ManagerFeeVault balance is separate from the manager's investor position.

| Step / event | Manager | Ana | Bruno |
|---|---:|---:|---:|
| 5: Manager seed | 99 / 99.000000 / 0.000000 | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 6: Ana deposit | 99 / 98.999999 / 0.000000 | 9,975 / 9,974.999997 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 11: Hub interest | 99 / 99.008822 / 0.000000 | 9,975 / 9,975.888950 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 12: Hub V4 fees | 99 / 99.008822 / 0.000000 | 9,975 / 9,975.888947 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 16: Capital sent | 99 / 98.977080 / 0.000000 | 9,975 / 9,972.690690 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 18: Spoke arrival | 99 / 98.977080 / 0.000000 | 9,975 / 9,972.690690 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 21: Spoke V4 fees | 99 / 98.977080 / 0.000000 | 9,975 / 9,972.690690 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 24: Spoke report accepted | 99 / 98.977544 / 0.000000 | 9,975 / 9,972.737389 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 27: Manual Principal credited | 99 / 98.973318 / 0.000000 | 9,975 / 9,972.311593 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 29: Income collected | 99 / 98.973317 / 0.008535 | 9,975 / 9,972.311565 / 0.860137 | 0 / 0.000000 / 0.000000 |
| 30: Bruno deposit | 99 / 98.973317 / 0.008535 | 9,975 / 9,972.311564 / 0.860137 | 10,975 / 10,972.042047 / 0.000000 |
| 31: Ana Income Withdrawal | 99 / 98.973317 / 0.008535 | 9,975 / 9,972.311564 / 0.000000 | 10,975 / 10,972.042047 / 0.000000 |
| 32: Standard requested | 99 / 98.973317 / 0.008535 | 9,975 / 9,972.311564 / 0.000000 | 10,975 / 10,972.042047 / 0.000000 |
| 34: Standard after 72 h | 99 / 98.965182 / 0.008535 | 6,974 / 6,971.547331 / 0.000000 | 10,975 / 10,971.140229 / 0.000000 |
| 35: Instant pending | 99 / 98.963793 / 0.008535 | 6,974 / 6,971.449484 / 0.000000 | 10,975 / 10,970.986248 / 0.000000 |
| 36: Instant settled | 99 / 101.748339 / 0.008535 | 6,974 / 7,167.605246 / 0.000000 | 426 / 437.826187 / 0.000000 |
| 37: Spoke UNWIND requested | 99 / 101.739976 / 0.008535 | 6,974 / 7,167.016120 / 0.000000 | 426 / 437.790201 / 0.000000 |
| 38: Partial Payout | 99 / 101.739976 / 0.008535 | 5,696 / 5,853.645511 / 0.000000 | 426 / 437.790201 / 0.000000 |
| 39: Retry settled | 99 / 101.692213 / 0.008535 | 2,404 / 2,469.374568 / 0.000000 | 426 / 437.584678 / 0.000000 |
| 41: Donation swept | 99 / 101.692213 / 0.008535 | 2,404 / 2,469.374568 / 0.000000 | 426 / 437.584678 / 0.000000 |
| 44: Closing | 99 / 101.692213 / 0.008535 | 2,404 / 2,469.374567 / 0.000000 | 426 / 437.584677 / 0.000000 |
| 45: Manager Income Withdrawal | 99 / 101.692213 / 0.000000 | 2,404 / 2,469.374567 / 0.000000 | 426 / 437.584677 / 0.000000 |
| 47: Post-deadline unwind | 99 / 101.642108 / 0.000000 | 2,404 / 2,468.157858 / 0.000000 | 426 / 437.369071 / 0.000000 |
| 48: CLOSE fill/report | 99 / 101.604053 / 0.000000 | 2,404 / 2,467.233793 / 0.000000 | 426 / 437.205322 / 0.000000 |
| 49: Principal ACKs delivered | 99 / 101.604053 / 0.000000 | 2,404 / 2,467.233793 / 0.000000 | 426 / 437.205322 / 0.000000 |
| 50: Closure finalized | 0 / 0.000000 / 0.000000 | 2,404 / 2,467.233794 / 0.634996 | 426 / 437.205322 / 0.278856 |
| 52: Ana Closed exit | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 | 426 / 437.205322 / 0.278856 |
| 53: Bruno Closed exit | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 54: Excess swept | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 |
| 55: Conservation checked | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 | 0 / 0.000000 / 0.000000 |

#### Accrued and paid fees

| Fee / allocation | Final cumulative USDC | Treatment |
|---|---:|---|
| Flow fees: seed / deposits / payouts including Closed exits | 0.250000 / 52.500000 / 53.115122 | 105.865122 total paid to Protocol Recipient |
| Instant Payout Fee | 210.903373 | Retained in Idle, not an external payment |
| Income collected and sold | 2.238190 | Includes final collection on both chains |
| Performance fee | 0.447631 | ManagerFeeVault 0.223817; Protocol Recipient 0.223814 |
| Net income assigned to holders | 1.790559 | Outside Share Assets; withdrawals in USDC |
| Management fee accrued at Closing, then paid at finalization | 2.374759 | ManagerFeeVault 1.187380; Protocol Recipient 1.187379; ending liability 0 |
| Bridge costs: outbound / return | 3.230000 / 3.347616 | 6.577616 total, independently matched to event ledger |

The protocol slice is 50% in this run. Split rounding is per collection/payment, so the final manager/protocol
performance halves differ by three base units. Final ManagerFeeVault holds 1.411197 USDC (= performance
0.223817 + management 1.187380); assignment to the vault is not a tested manager withdrawal to a wallet.

#### Receipt-derived gas per operation type

These are successful **transaction receipt gas units** from this run, not the Foundry call samples in section 6,
a production dollar quote or a worst-case certificate. Average = total receipt gas / count, rounded down.
Deployment rows include setup/creation; approval and trader rows are shown so all **103 receipts / 99,813,982 gas**
reconcile. Address-labelled rows retain the raw artifact labels; their role is not guessed. Cross-chain operations
span multiple rows; Wormhole fees and native gas remain externally funded under the MVP scope/DEC-187.

| Chain / contract — operation | Count | Min gas | Avg gas | Max gas |
|---|---:|---:|---:|---:|
| Hub: USDC — approve (forge CreateFund) | 1 | 38,325 | 38,325 | 38,325 |
| Hub: FundFactory — createFund (forge CreateFund) | 1 | 24,264,276 | 24,264,276 | 24,264,276 |
| Spoke: FundFactory — createSpoke (forge CreateFund) | 1 | 12,124,613 | 12,124,613 | 12,124,613 |
| Hub: USDC — approve | 3 | 38,325 | 49,733 | 55,437 |
| Hub: Core Vault — deposit | 2 | 352,419 | 730,199 | 1,107,979 |
| Hub: Core Vault — allocateToHubSpokeVault | 1 | 138,286 | 138,286 | 138,286 |
| Hub: hub Spoke Vault — openPosition | 2 | 492,192 | 616,051 | 739,911 |
| Hub: hub Spoke Vault — swap | 1 | 2,362,611 | 2,362,611 | 2,362,611 |
| Spoke: 0x3a0ef4d68eddd9821593472ac84a75741bbcf3cf — report | 5 | 139,859 | 150,358 | 164,934 |
| Spoke: Robinhood Spoke Vault — report | 7 | 168,373 | 313,640 | 403,510 |
| Hub: ValueReportReceiver — deliver | 17 | 477,571 | 881,798 | 1,741,871 |
| Hub: 0xf90640a43acf3f7443fcf01891f1c9772a560b54 — deliver | 5 | 329,917 | 395,742 | 630,980 |
| Hub: trader's V4 router (Arbitrum) — swap | 3 | 164,396 | 186,187 | 213,497 |
| Hub: Core Vault — sendToSpoke | 1 | 740,776 | 740,776 | 740,776 |
| Spoke: Across SpokePool (Robinhood) — fillRelay | 1 | 263,688 | 263,688 | 263,688 |
| Spoke: Robinhood Spoke Vault — swap | 1 | 852,441 | 852,441 | 852,441 |
| Spoke: Robinhood Spoke Vault — openPosition | 1 | 770,066 | 770,066 | 770,066 |
| Spoke: trader's V4 router (Robinhood) — swap | 3 | 130,074 | 155,048 | 167,763 |
| Spoke: Robinhood Spoke Vault — sendToHub | 1 | 640,636 | 640,636 | 640,636 |
| Hub: Across SpokePool (Arbitrum) — fillRelay | 5 | 173,420 | 253,431 | 461,831 |
| Hub: hub Spoke Vault — collectIncome | 2 | 269,960 | 302,973 | 335,986 |
| Hub: Core Vault — requestIncomeWithdrawal | 2 | 557,946 | 1,033,947 | 1,509,948 |
| Hub: Core Vault — acknowledgeSpokeTransit | 4 | 221,633 | 287,925 | 329,373 |
| Spoke: Robinhood Spoke Vault — executeOrder | 10 | 346,468 | 1,254,075 | 2,430,892 |
| Hub: Core Vault — settleIncomeWithdrawal | 1 | 313,790 | 313,790 | 313,790 |
| Hub: Core Vault — withdrawIncome | 2 | 78,145 | 177,305 | 276,465 |
| Hub: Core Vault — requestPayout | 3 | 798,861 | 1,348,902 | 2,443,227 |
| Hub: Core Vault — claimPayout | 3 | 862,728 | 1,669,865 | 2,271,632 |
| Hub: Core Vault — settlePayout | 3 | 886,582 | 948,381 | 985,148 |
| Hub: Core Vault — sweepExcess | 3 | 48,395 | 61,026 | 69,067 |
| Hub: USDC — transfer | 1 | 45,059 | 45,059 | 45,059 |
| Hub: Core Vault — closeFund | 1 | 727,437 | 727,437 | 727,437 |
| Hub: hub Spoke Vault — closePosition | 1 | 295,971 | 295,971 | 295,971 |
| Hub: Core Vault — unwindAllAfterDeadline | 2 | 100,806 | 596,672 | 1,092,539 |
| Hub: Core Vault — finalizeClosure | 1 | 724,612 | 724,612 | 724,612 |
| Hub: Core Vault — exitClosedFund | 2 | 231,745 | 231,750 | 231,755 |

Closure sends use a **15,000,000 gas budget**, not the smaller measured receipt value as a safe limit.
Earlier estimation selected a caught inner OutOfGas and emitted `ClosureUnwindFailed` despite an outer
successful receipt; the run asserts no such event. ACK retirement also removes the final CLOSE result,
so an additional terminal CLOSE is required before finalization. Both are unresolved implementation
limitations/workarounds, not fixed by this docs change.

#### Conservation and recovery

| Conservation component | USDC |
|---|---:|
| External capital, including the 1,234-USDC donation | 22,332.792047 |
| Evidence-derived realized investment/swap cash flow and income | -0.124707 |
| Total value in | 22,332.667340 |
| Investor/manager payouts and Income Withdrawals | 20,983.402203 |
| External fees and excess/garbage sweeps | 1,342.687513 |
| Bridge costs | 6.577616 |
| External fees/sweeps plus bridge costs | 1,349.265129 |
| Remaining physical vault cash: ledgered rounding dust | 0.000008 |
| Remaining positions / In-flight Value | 0 / 0 |
| Unexplained flows / conservation residual | 0 / 0.000000 |

**22,332.667340 = 20,983.402203 + 1,349.265129 + 0.000008 USDC.** The residual is exactly zero,
not merely below the 20-base-unit tolerance. Separate Core Vault physical-cash reconciliation also has zero
residual. Internal allocations/bridge principal cancel; Payout Fee remains internal, not counted again as an
external fee. USDG uses 1:1 and WETH the unchanged scenario feed; this fully unwound result is not a live
mark-to-market/depeg proof. The original run's positive 99.139509-USDC cash-flow figure is superseded by this
receipt/event-bounded rerun; unmatched flows are not allowed to become investment losses or Market Costs.

Recovery evidence:

- **Delayed fills:** `KEEPER_FILL_DELAY_SECONDS=5`, `KEEPER_VAA_DELAY_SECONDS=1` make reports arrive
  at least four seconds before later order-return fills. Polling completes credit/ACK without another report.
- **Acknowledgement failures:** exactly one temporary ACK-send RPC failure is injected after successful
  preflight. Deployment-scoped pending records/payloads persist atomically; 500-ms–30-s exponential backoff
  has no retry limit, reconstructs candidates independently of new reports, preserves emitter sequence, and
  republishes expired/superseded ACKs. The final queue is empty: four Principal candidates resolved.
- **Deterministic regressions:** 7/7 cover report-before-fill, temporary ACK send and delivery failures,
  restart/backoff/no retry cap, unrelated 10-USDC outflow, wrong transaction/token/counterparty/amount,
  and sub-tolerance unknown flow. The 100-in / 10-unexplained-out / 90-cash negative control fails with a
  10-USDC residual. Tiny unknown flows fail too; tolerance never authorizes unexplained transfers.
- The real scenario injects **ACK publication**, not delivery, failure; delivery-failure/restart cases are the
  deterministic tests. Refund tracking remains pending until its ACK executes, but this completed scenario
  does not certify a live Across refund, production outage recovery or the manual-send retirement fix.
- Cleanup from PR #24: `pnpm down` passed; no listener remained on its ports 59645, 59646 or 59687.
  This report update starts no Anvil/API/keeper process.

Historical #23's 46 steps / 294 assertions and API 19 concepts remain earlier integration evidence,
not the final lifecycle counts. Final frozen-release/mainnet rehearsal and conformance fixes remain gates.

## 8. Known limitations and explicit deferrals

### Whole-codebase conformance pass and alpha dispositions

Source: `pool-party-sc-v2-handoff/results/conformance-pass-full.md`, **October 3, 2026**, read-only review
of `f88b25b96913301aa9b00dd0b638adc89f9ee689`. It covers all production source families, DEC-001..187,
the PLAN section 8 divergence readings, authorization roles and release evidence. Its own build/format/size
checks and 1,432 non-fork tests passed; it did not run forks, a harness or new exploit demonstrations.
The current main validation and PR #24 rerun above supersede its old counts/lifecycle evidence, not its
unresolved code-path findings. **A conformance review is not an unconditional conformance pass or audit.**

The following dispositions are the instructions for this report update, not waivers inferred from green tests:

| ID | Finding / alpha consequence | Current disposition |
|---|---|---|
| B-01 | Historical finding: Hub Spoke Vault exposure callable during/after Core closure | **Resolved by merged #28:** Core Fund State gates Hub exposure during Closing/Closed; unwind-to-base remains available in Closing |
| B-02 | Historical finding: terminal Principal/Income too small to bridge could block closure | **Resolved by merged #28**, including round-1 fix: terminal dust strictly below 0.50 recorded/excluded/sweepable; late Principal needs no second CLOSE. Alpha exception to literal DEC-163 |
| B-03 | Historical finding: zero Operating Cash was only a deployment/manager convention | **Resolved by merged #28:** nonzero Mandate floor/top-up rejected; setters disabled, internal hooks inert |
| B-04 | Exact frozen-release deployment rehearsal, real new-emitter guardian/bridge evidence and explorer verification are not certified by this review | PR #24 supplies the local full lifecycle; production/final-SHA evidence remains a release gate |
| G-01 / DEC-145 | Deposit/report timestamp eligibility is absent; a later report can attribute pre-entry remote income to new shares | **Implemented (#30), included in release `797d592`:** waiting lots/resumable checkpoints, reported max-config peak 2.04M gas; historical measured main predates this fix |
| G-02 | Full Open-fund exit pays converted dollars; unconverted income rights survive zero shares and require later collection | **Accepted for internal alpha**; rights preserved, not immediate complete income cash-out; Closed exits require final collection |
| G-03 | Gross Assets omits Income bridging home | **Accepted for internal alpha**; informational view gap, not evidence that Share Assets include income or principal is lost |
| G-04 | Spoke Cap return occupancy uses bridge output rather than amount sent, understating usage by bridge cost | **Accepted for internal alpha**; DEC-066 sent-base symmetry remains incomplete |
| G-05 | Historical finding: reserved unlisted Principal recovery credited live Idle after Closed | **Resolved by merged #28:** Closed handling precedes recovered-Principal Idle credit; reservations gate finalization, frozen entitlements unchanged |
| G-06 | Report lifetime is selectable within one day, not enforced per supported network | **Accepted for internal alpha** with the checked 1,588-second Mandate value; not protocol-wide conformance |
| G-07 | Direct constructors permit different Protocol Recipient and excess recipient | **Accepted for internal alpha** with equality verified in standard factory wiring |

B-01/B-02 are static code-path findings, B-03 a configuration/trusted-manager gate, B-04 an evidence gate;
do not call them executed exploits. B-01..B-03/G-05 fixes are merged in reviewed #28, including the late-dust
round-2 regression verification. The frozen post-#30 rehearsal preceded release `797d592` deployment.
Accepted G findings are **internal-alpha limitations**, not permission for public capital. DEC-145 is implemented
by merged #30; the earlier WP-14 deferral is superseded.

### Manual and Income acknowledgements: merged PR #29

The Sent-after-ACK manual Principal limitation is **fixed by merged #29**. Report v5 carries authenticated
`refundedTransits`; credit/refund-backed Hub ACKs resolve manual and order-driven sends, remove the In-flight
Value slot and ignore repeats. Manual Income remains forbidden: Income is sent through COLLECT orders.
The **64 shared send slots** are reused only after delivered terminal ACKs; **16 unwind result entries** is
separate. Alpha/harness keepers persist all-kind work and retry/republish until `ArrivalConfirmed` or
`RefundRecognized` is observed on the spoke. Hub credit, ACK publication or an empty local queue alone is not
terminal retirement. Collection ownership is unchanged; time alone is never refund proof.

#29 round 2 approved its fix scope and reproduced manual/Income slot release, default warm-up/replay and
alpha closure smoke. See [ACK report](2026-10-03-MANUAL-SEND-ACK.md),
[round-1 evidence](../../local-e2e/reports/2026-10-03-pr29-round1.md), and
[committed full replay](../../local-e2e/reports/2026-10-03T02-50-31Z-scenario.md).
The committed replay records **56 steps / 326 assertions**, six real fills / zero simulated,
**zero conservation residual** and **6.577617 USDC bridge costs**, with API **31 concepts**.
These are committed #29 evidence, not a fresh harness run by this docs WP. The independent reporting-disabled
warm-up/replay was **55 / 321**; its review explicitly did not rerun the report-only conservation step.
Section 7’s #24 figures remain a separate historical run.

### DEC-145: implemented (#30)

Merged PR #30 (included in release `797d592`; reviewed fix head `c36da24`) implements report/deposit timestamp eligibility using per-source FIFO waiting lots,
waiting-first burns and resumable frozen capture/payment/merge checkpoints. One shared **64-token-operation
budget** covers sources, active and activated waiting shares; permissionless `settleHolderIncome(holder)`
progresses in Open/Closing/Closed without a collection request. Balance hooks retry after completion;
separate conservative credit/debit totals preserve exact split-call equivalence.

Round 1 found a high gas-liveness blocker; the fix reply reports cold maximum legal configuration of
**15 spoke tokens, 64 finalized collections and one activated waiting lot per holder/source**, calls capped
at 14M gas, peak **2,038,401 gas (2.04M)** with persisted progress. Income Withdrawal, Payout burn, closure
finalization and Closed exit tests stay below 15M including continuation. Its integrated replay is
**57 steps / 330 assertions**, zero residual; default warm-up **56 / 325**. These are #30’s reported evidence,
not freshly rerun counts or sizes here. Round 2 independently reproduced the 2.04M peak in **90 continuation
calls** and verified the settlement fix, but found a test-only fixture breaking the exact size build: 31,536 bytes,
6,960 over EIP-170. Its fix reply at `c36da24` moves history preparation into a linked test-only library:
fixture **22,927 / 1,649 B margin**, helper **9,494 / 15,082**. A clean unqualified build and existing path
regressions pass in that reply; production code and prior harness evidence are unchanged. The review history
above is historical; #30 subsequently merged and frozen-release validation preceded mainnet deployment.

### Other retained limitations

- **Silent spoke:** DEC-157/160 have no inactivity escape; exits needing its fresh report and closure cannot
  finish if a spoke never answers. Permissionless relay replaces a keeper, not the report source.
- **ACK delivery:** spoke capacity is reclaimed only when Hub acknowledgements are delivered. Sixty-four undelivered
  ACKs can block later sends/exits; anyone can republish/deliver them, the keeper must. Full Hub credit alone
  is insufficient. Elapsed time is not accepted as the Hub publisher's expiry proof.
- **External transaction funding:** Standard Payout Wormhole fees are caller-funded for now. Manager pays own
  gas (DEC-187); keeper/API/callers pay gas and message fees. Accounting for fund collection/bridge costs is
  not gas reimbursement. DEC-164/165 refund and DEC-171 executor-gas absorption are deferred.
- **Deferred:** DEC-185 spoke gas top-up; native Operating Cash WP-16 (including native cap/unwrap); WP-11 signed
  bridge quotes DEC-168/176; **WP-17 deferred by Rafael**. DEC-145 is implemented by merged PR #30. Confirmed future refund caps are 0.5 gwei,
  0.001 ETH/call and /day/vault, no minimum interval. MVP Operating Cash is enforced at 0 by #28:
  nonzero Mandate parameters rejected, manager setters disabled, no native spend/refund/top-up implemented.
- **Economics:** manager no-floor swaps (S-8/DEC-129), pre-sale spot manipulation/empty-route reference residual
  (C-01/#7) remain accepted only for internal alpha. Optional signed/caller minima are not independent market-price
  guarantees; flow fee is not an attack brake. Partial intermediate V3 route residue can be sweepable.
- **Income:** recognition cohorts implemented on main; DEC-145 is implemented by merged PR #30,
  replacing the timestamp-filter gap with waiting lots/checkpoints. No external incentive collector distribution.
- **Pricing/bridge:** incomplete DEC-123 reliable-source hierarchy/cache initialization; 1:1 USDG ignores depeg.
  Adapter cap is 1% rate plus fixed 0.03 token, not total 1% gap. Mean is own sends, expiry may mean downtime/limits;
  Across refunds observed 57–99 minutes after deadline in research, not an SLA. Native token fixed fee/window
  semantics need redesign before gas bridge support.
- **PR #12 L-2 management rounding:** sub-unit valuation keeps clock; positive old base bounds entrant pre-entry
  overcharge below `(new base / old base)` USDC base units. About 0.01 USDC per 1M over a 100-USDC old base;
  at the 1-USDC test seed the reviewer measured 0.998859 USDC. Each positive rounded booking loses manager <1
  base unit. Local rounding bound, not exact entry-time isolation/global-loss cap. Docs only, NatSpec unchanged.
- **PR #21 L-1 resolved:** merged PR #25 uses the shared 416-byte result encoder on retirement; its extra
  regression is included in the current non-fork count. Immutable API route signer/registry-owner transfer
  discrepancy, guardian/key compromise and absent public depositor allowlist remain disclosed.
- No external audit, current full formal verification/deep-fuzz/coverage/mutation rebaseline, worst-case report
  gas certificate, real new-emitter VAA delivery or production explorer verification claimed by this report.

## 9. Deploy readiness and Rafael's required inputs

**Ready evidence:** #20 dual-chain deploy/checker rehearsal and executable verification extraction; #21 fixed
nested library linking with deployment regressions; fresh green tests/sizes/format.
**Completed lifecycle evidence:** merged PR #24 recovery run, section 7. **Still not ready:** conformance
the completed DEC-145 PR #30 merge and frozen-SHA deployment rehearsal,
production guardian service, live Across route confirmation,
explorer source verification, approved real keys/ETH budgets and internal risk acceptance. No mainnet deployment here.

Use [DEPLOYMENT-ALPHA](../DEPLOYMENT-ALPHA.md) for the input sheet/broadcast procedure; its October 2 feature-gap
warnings are historical and superseded by this report, but its final-SHA/mainnet gates still apply. Generic
DEPLOYMENT/INTEGRATIONS historical snapshots are not a substitute for the current artifact-derived link graph.
Rehearse on the final frozen release and update manifests after every bytecode change. #26 supplies durable
transaction/redaction tooling; #29 supplies all-kind ACK persistence/retry and independent slot-release evidence.
Do not run an older #20 runtime against the new queue/codec. This docs WP starts no services.

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
| Operating Cash | Floor/top-up enforced at 0 by #28, setters disabled; no native spend/refund/top-up promised |
| Keeper/API service | Separate funded ALPHA_KEEPER_KEY, ALPHA_API_SIGNER_KEY matching API_SIGNER, secret bearer ALPHA_API_TOKEN; loopback authenticated tunnel, durable queue, supervisor/incident contact |
| RPC/VAA/explorer credentials | Archive helper without URL/key logs; real new-emitter guardian VAAs accepted/delivered in time; live Across tiny fill/refund; Arbiscan credential and Robinhood explorer access (prior 403 unresolved) |
| Final manifest / approval | Release SHA/build, factory salts, all linked addresses/stores, fund creation number/Mandate hash, scanning start blocks, fees/seed/receipts, internal-only risk acceptance and no audited/public marketing |

Do not invent an ETH budget from these call samples: Rafael must approve funded amounts after final release
rehearsal/live chain fee estimation. Public gates remain DEC-133 order: unit -> invariants -> formal -> external audit.
[PRE-MAINNET-CHECKLIST](../security/PRE-MAINNET-CHECKLIST.md) separates historical alpha evidence from open gates.

## 10. Deviations and spec divergences

WP-19b deliberately changes docs only, including README/report; management-fee NatSpec follow-up is documented,
not edited. No new tests/CI shard/fixture/runtime edits; full forks nevertheless rerun for founder evidence.
The final end-to-end placeholder is now replaced by merged PR #24's authoritative recovery evidence.
This update reruns build/format/size/non-fork and the full fork suite without changing contracts or fixtures.

Existing divergences are not resolved by documentation: native Operating Cash/refunds/DEC-185 MVP top-up versus
ruling 2026-10-02 delivery scope; DEC-171 fund executor gas versus external funding; Standard Wormhole fee caller
funding; DEC-145 implemented by merged PR #30 (FIFO/waiting-first and bounded timestamp-skew reading); DEC-159 off-chain reporting versus atomic publication; DEC-123
incomplete source hierarchy. DEC-186 Slack cap overrides register's older 10%; registry Ownable2Step/override can
separate owner from immutable API signer; 1% rate plus fixed fee differs from a 1% total gap; shared result retirement
encoder follow-up was fixed by PR #25; it is no longer an open divergence. ACK delivery and silent-spoke liveness are implementation/operating prerequisites,
not new waivers. Full dispositions: [OPEN-QUESTIONS](../OPEN-QUESTIONS.md).

## Mainnet alpha deployment

### Release, evidence and scope

The internal alpha (DEC-134) was deployed on **October 3, 2026**, from frozen release **`797d592`**,
including merged #30 / DEC-145. Solidity **0.8.28**, optimizer **800**, **Cancun**, **no via-IR**.
Arbitrum One is the Hub Chain (**42161**, Wormhole **23**); Robinhood Chain is the Spoke Chain
(**4663**, Wormhole **72**). Fund creation number **1**, Fund ID
`0xe49050db325f1963991d8b7fa591be9fe3fac1e7bfea0c34955c4f67893f6e46`, Mandate hash
`0x9714b37e5576b0d8b07652dee42cb16517fdea99528468d877e41b0ec806a198`.
Fund scan start blocks: Arbitrum **511198781**, Robinhood **78805261**.

Evidence is outside this repository: `/Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/mainnet-records/`.
Sources: `fund.env`, `alpha-deploy-*.log`, `alpha-create-*.log`, `check-*.log`,
`verified-*/coverage.json`, `broadcast/*/run-latest.json`, `continuation.jsonl`,
`continuation-state.jsonl`, `positions.jsonl`, `smoke-*.log` and `report-1.json`;
timing/operational observations are the October 3 entries in the external `HANDOFF.md`.
No keys, RPC URLs or handoff chronology are copied here. The Across fill gas and manager Payout receipt
were supplemented by read-only receipt queries on October 3, through the RPC loader and safe wrapper.
Historical test counts above are not updated by this evidence review.

### Factory and complete deployment inventory

The **FundFactory** is `0x2cdb1f3fa95f8a65495d01d20ad53cf980728534` on both chains.
The tables include every executable, linked library, CodeStore and one-use CREATE3 proxy in the recorded
factory/fund #1 inventories. Raw CodeStores/proxies are identified separately; they are not Solidity
verification targets. TransitEscrow below is the factory's implementation, not a separately deployed fund escrow.

#### Arbitrum One

| Contract / record | Address and explorer |
|---|---|
| ManagerRegistry | [`0xd6671dc995e6d5f2f7f65ea05a513738907737ce`](https://arbiscan.io/address/0xd6671dc995e6d5f2f7f65ea05a513738907737ce) |
| ChainlinkPriceSource | [`0xd1e43765fcb66515cd8cf0ede73dff2e4bf249bf`](https://arbiscan.io/address/0xd1e43765fcb66515cd8cf0ede73dff2e4bf249bf) |
| Create3Deployer | [`0x1da47ced247a6776329281836600283b033f8e41`](https://arbiscan.io/address/0x1da47ced247a6776329281836600283b033f8e41) |
| SpokeCrossChainLib | [`0x3341467fd9f8ce784d77348bea276ce80eb57693`](https://arbiscan.io/address/0x3341467fd9f8ce784d77348bea276ce80eb57693) |
| SpokeUnwindLib | [`0xfea626e44de1d2d7a01935a485399e992725351d`](https://arbiscan.io/address/0xfea626e44de1d2d7a01935a485399e992725351d) |
| SpokeCloseLib | [`0xfcadfa1b5bcd4edca95220e07661795efa883035`](https://arbiscan.io/address/0xfcadfa1b5bcd4edca95220e07661795efa883035) |
| SpokeIncomeLib | [`0xcb8ece6a3a1fcb80083ed1c8b7c7b6e85b14dc5b`](https://arbiscan.io/address/0xcb8ece6a3a1fcb80083ed1c8b7c7b6e85b14dc5b) |
| CoreVaultIncomeCollectionLogic | [`0x4a0ae1f3017f6869bc3b24cd69d0b501ba93faca`](https://arbiscan.io/address/0x4a0ae1f3017f6869bc3b24cd69d0b501ba93faca) |
| CoreVaultIncomeLogic | [`0x593bf11bf8e3b2f795bbc538aee1d59f8d4d55b8`](https://arbiscan.io/address/0x593bf11bf8e3b2f795bbc538aee1d59f8d4d55b8) |
| CoreVaultLogic | [`0x43ddb24ac75cffa09f0849ddd71a78f7e9c3068d`](https://arbiscan.io/address/0x43ddb24ac75cffa09f0849ddd71a78f7e9c3068d) |
| CoreVaultPayoutLogic | [`0xfaa7d44e670570cab3346522f55d1b25408d05e8`](https://arbiscan.io/address/0xfaa7d44e670570cab3346522f55d1b25408d05e8) |
| CoreVaultClosureLogic | [`0x75997f8b180e20695c58ff519d672cfa9274e028`](https://arbiscan.io/address/0x75997f8b180e20695c58ff519d672cfa9274e028) |
| CoreVaultTransitLogic | [`0x6e6b2461628008c5e496c480860c675c33fe957d`](https://arbiscan.io/address/0x6e6b2461628008c5e496c480860c675c33fe957d) |
| CodeStore | [`0x20f33f1ce98b43af4734ab59e2d0df534abdc1f9`](https://arbiscan.io/address/0x20f33f1ce98b43af4734ab59e2d0df534abdc1f9) |
| CodeStore | [`0x5b3abb330faf73c8cdf78c17f706c72bc5206123`](https://arbiscan.io/address/0x5b3abb330faf73c8cdf78c17f706c72bc5206123) |
| CodeStore | [`0x7fce7311e85fb90fbcc9724b233c3d2fbba78fd1`](https://arbiscan.io/address/0x7fce7311e85fb90fbcc9724b233c3d2fbba78fd1) |
| CodeStore | [`0x80a1e353259ab4560a27bc4b2fbfd13a52a7ae48`](https://arbiscan.io/address/0x80a1e353259ab4560a27bc4b2fbfd13a52a7ae48) |
| CodeStore | [`0x02a19e3d6a0db853f984069f7f0843816a8a7705`](https://arbiscan.io/address/0x02a19e3d6a0db853f984069f7f0843816a8a7705) |
| CodeStore | [`0x35a69cca3c10d3d78bebdff9c84408fe87b9643a`](https://arbiscan.io/address/0x35a69cca3c10d3d78bebdff9c84408fe87b9643a) |
| CodeStore | [`0x57540fde07ee9eed4867a6d32611737e17f8cf88`](https://arbiscan.io/address/0x57540fde07ee9eed4867a6d32611737e17f8cf88) |
| CREATE3 proxy | [`0x26e0e22a33d4509eb8ba01adea776c8518c6d913`](https://arbiscan.io/address/0x26e0e22a33d4509eb8ba01adea776c8518c6d913) |
| FundFactory | [`0x2cdb1f3fa95f8a65495d01d20ad53cf980728534`](https://arbiscan.io/address/0x2cdb1f3fa95f8a65495d01d20ad53cf980728534) |
| TransitEscrow | [`0xffdc3ede1d43678dde55e98fb924a81dca26383f`](https://arbiscan.io/address/0xffdc3ede1d43678dde55e98fb924a81dca26383f) |
| CREATE3 proxy | [`0x3d4e18d463c4d3ce5f7ddbe566884e72f2dab440`](https://arbiscan.io/address/0x3d4e18d463c4d3ce5f7ddbe566884e72f2dab440) |
| UniswapV4Adapter | [`0x0e4350488f3147ac87bb2b82c134c0cc9f263e15`](https://arbiscan.io/address/0x0e4350488f3147ac87bb2b82c134c0cc9f263e15) |
| CREATE3 proxy | [`0x9efa9b8318d0146708545e3095f65a0d93ee6cb5`](https://arbiscan.io/address/0x9efa9b8318d0146708545e3095f65a0d93ee6cb5) |
| AaveV3Adapter | [`0x945bb8b37f2f89d6835ccc340412ea15bfebf121`](https://arbiscan.io/address/0x945bb8b37f2f89d6835ccc340412ea15bfebf121) |
| CREATE3 proxy | [`0xe205d8078f397fb0d0cf2836e8410c4c35d090de`](https://arbiscan.io/address/0xe205d8078f397fb0d0cf2836e8410c4c35d090de) |
| UniswapV3SwapAdapter | [`0x114f39055393a2c25ceced1b2e6340ec2181d573`](https://arbiscan.io/address/0x114f39055393a2c25ceced1b2e6340ec2181d573) |
| CREATE3 proxy | [`0x3a38ccdd1c3321dd7e92751458ed69174e0c1a91`](https://arbiscan.io/address/0x3a38ccdd1c3321dd7e92751458ed69174e0c1a91) |
| AcrossBridgeAdapter | [`0xf95203f011d28e1019f88beb858dcc5bf93cf7dc`](https://arbiscan.io/address/0xf95203f011d28e1019f88beb858dcc5bf93cf7dc) |
| CREATE3 proxy | [`0xbfe6511b074cc2ed0da82b4bb0b3903d6b31c37b`](https://arbiscan.io/address/0xbfe6511b074cc2ed0da82b4bb0b3903d6b31c37b) |
| SpokeVault | [`0x670ad828f64e87b8b305296ce50c5728de3b9f01`](https://arbiscan.io/address/0x670ad828f64e87b8b305296ce50c5728de3b9f01) |
| CREATE3 proxy | [`0xb14c8a7cc153224f76b982f1f54dba68e82e4772`](https://arbiscan.io/address/0xb14c8a7cc153224f76b982f1f54dba68e82e4772) |
| ValueReportReceiver | [`0x5dcab91f669303c4d653c3bfdb710d8d2c92ffa8`](https://arbiscan.io/address/0x5dcab91f669303c4d653c3bfdb710d8d2c92ffa8) |
| CREATE3 proxy | [`0x24b2b86d0bba0b0142b40e20af811e4ccfb03a23`](https://arbiscan.io/address/0x24b2b86d0bba0b0142b40e20af811e4ccfb03a23) |
| CoreVault | [`0x89625f9e4b3941e503a2f0982c81046d82143e1f`](https://arbiscan.io/address/0x89625f9e4b3941e503a2f0982c81046d82143e1f) |
| ShareToken | [`0x8563aeed8db9c19e3b744029b863cfcfe650bdf7`](https://arbiscan.io/address/0x8563aeed8db9c19e3b744029b863cfcfe650bdf7) |
| ManagerFeeVault | [`0x80690160a116a92be5b24845695a3b6e79e92c00`](https://arbiscan.io/address/0x80690160a116a92be5b24845695a3b6e79e92c00) |

#### Robinhood Chain

| Contract / record | Address and explorer |
|---|---|
| Create3Deployer | [`0x1da47ced247a6776329281836600283b033f8e41`](https://robinhoodchain.blockscout.com/address/0x1da47ced247a6776329281836600283b033f8e41) |
| SpokeCrossChainLib | [`0x3341467fd9f8ce784d77348bea276ce80eb57693`](https://robinhoodchain.blockscout.com/address/0x3341467fd9f8ce784d77348bea276ce80eb57693) |
| SpokeUnwindLib | [`0xfea626e44de1d2d7a01935a485399e992725351d`](https://robinhoodchain.blockscout.com/address/0xfea626e44de1d2d7a01935a485399e992725351d) |
| SpokeCloseLib | [`0xfcadfa1b5bcd4edca95220e07661795efa883035`](https://robinhoodchain.blockscout.com/address/0xfcadfa1b5bcd4edca95220e07661795efa883035) |
| SpokeIncomeLib | [`0xcb8ece6a3a1fcb80083ed1c8b7c7b6e85b14dc5b`](https://robinhoodchain.blockscout.com/address/0xcb8ece6a3a1fcb80083ed1c8b7c7b6e85b14dc5b) |
| CodeStore | [`0x2e369b374857ac7e5df0bf1ebeaf7ce9ede2bbbc`](https://robinhoodchain.blockscout.com/address/0x2e369b374857ac7e5df0bf1ebeaf7ce9ede2bbbc) |
| CodeStore | [`0xdf9391fb5dc2f28e90e96435a7c3a191ed548742`](https://robinhoodchain.blockscout.com/address/0xdf9391fb5dc2f28e90e96435a7c3a191ed548742) |
| CodeStore | [`0x90a8e3cbe7ec8d8ed5c3d7d32f49ece5dd2d0d39`](https://robinhoodchain.blockscout.com/address/0x90a8e3cbe7ec8d8ed5c3d7d32f49ece5dd2d0d39) |
| CodeStore | [`0xb693ef1a5db184fdf0362a1dfaca03795d4f726e`](https://robinhoodchain.blockscout.com/address/0xb693ef1a5db184fdf0362a1dfaca03795d4f726e) |
| CodeStore | [`0x5ebfbc403b0b97c2fee9b77c7c7fd70a46ad65c4`](https://robinhoodchain.blockscout.com/address/0x5ebfbc403b0b97c2fee9b77c7c7fd70a46ad65c4) |
| CREATE3 proxy | [`0x26e0e22a33d4509eb8ba01adea776c8518c6d913`](https://robinhoodchain.blockscout.com/address/0x26e0e22a33d4509eb8ba01adea776c8518c6d913) |
| FundFactory | [`0x2cdb1f3fa95f8a65495d01d20ad53cf980728534`](https://robinhoodchain.blockscout.com/address/0x2cdb1f3fa95f8a65495d01d20ad53cf980728534) |
| TransitEscrow | [`0xffdc3ede1d43678dde55e98fb924a81dca26383f`](https://robinhoodchain.blockscout.com/address/0xffdc3ede1d43678dde55e98fb924a81dca26383f) |
| CREATE3 proxy | [`0x2459963d0de02b336fcf6179e9d8348adb765c4d`](https://robinhoodchain.blockscout.com/address/0x2459963d0de02b336fcf6179e9d8348adb765c4d) |
| UniswapV4Adapter | [`0xd38ae81065205e9e34ab9031afc80d4cd5136486`](https://robinhoodchain.blockscout.com/address/0xd38ae81065205e9e34ab9031afc80d4cd5136486) |
| CREATE3 proxy | [`0xac282006483933852d23bfb4082bbc983650942f`](https://robinhoodchain.blockscout.com/address/0xac282006483933852d23bfb4082bbc983650942f) |
| UniswapV3SwapAdapter | [`0x24a75f965cfed106a8a8542ba5370e60d303c50a`](https://robinhoodchain.blockscout.com/address/0x24a75f965cfed106a8a8542ba5370e60d303c50a) |
| CREATE3 proxy | [`0x3c3258dd3c9140ac4054e3cff7aa5b4fb4caf043`](https://robinhoodchain.blockscout.com/address/0x3c3258dd3c9140ac4054e3cff7aa5b4fb4caf043) |
| AcrossBridgeAdapter | [`0xc5f451ccaffdf9e37223ba81fd532fb17337f899`](https://robinhoodchain.blockscout.com/address/0xc5f451ccaffdf9e37223ba81fd532fb17337f899) |
| CREATE3 proxy | [`0x82baaff7e4a778293a712b02e404a62d4f9c887d`](https://robinhoodchain.blockscout.com/address/0x82baaff7e4a778293a712b02e404a62d4f9c887d) |
| SpokeVault | [`0x214cd74f0331eb47daa1491a57990e415af2fa8a`](https://robinhoodchain.blockscout.com/address/0x214cd74f0331eb47daa1491a57990e415af2fa8a) |

### Receipt-derived deployment costs

For each script and chain, **actual ETH = sum(BigInt(gasUsed) × BigInt(effectiveGasPrice)) / 10^18**,
using the hex fields in broadcast receipts, excluding dry-run directories. Hub creation includes the seed
approval plus creation; Robinhood creation is one transaction. Estimates are the logged Foundry
"Estimated amount required", not paid fees and not the earlier Anvil budget.

| Chain | Script | Receipts | Actual gas | Actual ETH | Foundry estimated gas | Foundry estimated ETH |
|---|---|---:|---:|---:|---:|---:|
| Arbitrum | DeployFactory | 21 | 62,255,942 | 0.001249158913033942 | 76,086,015 | 0.003046788460746015 |
| Arbitrum | CreateFund (including approval) | 2 | 24,502,457 | 0.000490054853144457 | 33,795,567 | 0.001352633807403567 |
| Robinhood | DeployFactory | 11 | 32,971,733 | 0.000967340718486000 | 44,575,939 | 0.002608762298611939 |
| Robinhood | CreateFund | 1 | 12,129,512 | 0.000355758586960000 | 17,738,994 | 0.001037660210762994 |

Totals: **Arbitrum 0.001739213766178399 ETH**, versus **0.004399422268149582 ETH** estimated;
**Robinhood 0.001323099305446000 ETH**, versus **0.003646422509374933 ETH** estimated.
Both chains together **0.003062313071624399 ETH**, excluding seed capital, later smoke transactions,
reports and investor funding. These receipt-based Network Costs are not a USD conversion or wallet-balance delta.

### Deployment checks, verification and report timing

`CheckAlphaDeployment` records **PASS on 42161 and 4663**: factory/fund/Mandate wiring and CodeStores
were checked. Verification coverage is **24/24 Arbitrum** via Arbiscan and **11/11 Robinhood** via
**Sourcify**. The public Robinhood Blockscout API returned a Cloudflare 403/challenge; its PRO API required
a key. The verifier switched to Sourcify, whose matches Blockscout imports. Coverage is successful per-address
verification, not merely submission; raw CodeStores and CREATE3 proxies remain outside those denominators.

The first real guardian-signed **report v5, sequence 1**, was delivered on Arbitrum in **858 seconds**
(`report-1.json`: `delivered: true`). Robinhood finalized-head lag was observed at **980–1,109 seconds**;
the earlier observation also recorded Arbitrum lag around **1,107 seconds**. Finality lag and actual report
end-to-end delivery are distinct measurements, not additive timings. Against the **1,588-second report
lifetime**, 858 seconds leaves **730 seconds**; the observed Robinhood lag alone leaves only **479–608 seconds**
for observation, signing, retrieval and Hub delivery. Later report cycles took roughly 19 minutes, not seconds.
DEC-159/160 pre/post mint/burn reports therefore require synchronous waits, strict freshness checks and a stop
on stale delivery. This proves a live delivery, not an SLA or a guarantee that every future report fits.

### Live smoke in execution order

Reports bracketed the money operations; the following are the capital/position/income receipts rather than
an exhaustive report-transaction ledger. Gas is receipt gasUsed; creation gas includes the bundled fund deployment.

| Step | Chain | Transaction hash | Gas | Result |
|---|---|---|---:|---|
| Seed approval | Arbitrum | `0x7acf462d26e456428b2e640199582bd1bcc457e1bb3ee5261c90562307e1de5b` | 55,771 | Approve seed transfer |
| Create fund + seed | Arbitrum | `0x76b444d75a8516ee681429e053219ec736215c438f3891c6f6b4c22d7779c55e` | 24,446,686 | 5 USDC seed; fund #1 |
| Create remote fund | Robinhood | `0x6842ca32de53580bff482e1d5263ee8725c6997d03b66157387f54e2d46c9c11` | 12,129,512 | Matching Spoke Vault |
| Manager deposit approval | Arbitrum | `0x9f0b54b77e8ae3e27f26cfd69381b94dccc45706842b8015f9d5ab27e700ab11` | 55,726 | Approve 5 USDC |
| Manager deposit | Arbitrum | `0x9a036e725581399323612f26ef5a50cdf1cbd0e1ac4681ea564e2cc4bf4eccea` | 650,882 | Deposit 5 USDC |
| sendToSpoke | Arbitrum | `0x8a55d8868baa382aecfe2fba184144885f5e4f3dc8e19babe892fe220e7d4863` | 742,272 | Send 5 USDC; expected 4.966000 USDG |
| Matched Across fill + TransitArrived | Robinhood | `0x2f1d58c9584795212bab134eea3c6d9aa89ae6e41c93f9d0d39161b9cde7749d` | 258,554 | Deposit ID 4711386; 4,966,000 base units received |
| Manager Instant Payout | Arbitrum | `0x8ff989f205240c4fe52f9ff556f2006c592d42c4b66c07dd7586aa9476abb25c` | 844,113 | 1-share burn; 0.973346 USDC paid |
| Spoke swap | Robinhood | `0x25cb4e4d2ee294251af5b62a448bbba5561bce16bb39af2ef4f4f091cf333c2c` | 1,154,745 | Output 925,757,908,345,888 wei WETH |
| V4 openPosition | Robinhood | `0x80a46b594efacc7566eb4b9d25bc0f6419d237847b13a374cb0c55736ce5129c` | 764,581 | Token ID 0x365e57; 925,757,908,345,535 wei WETH + 2,479,218 USDG base units |
| Aave allocation | Arbitrum | `0x78e4b388e94536a5793cbcb20305cd13716ae5f7a722d35e5ce8e1753fe37584` | 134,253 | Allocate 1 USDC to hub Spoke Vault |
| Aave openPosition | Arbitrum | `0x35fbc7032251f26a33f1a0ceb5adbd7310f11927e363343470f67aa1a96d497c` | 488,121 | Supply 1 USDC |
| Second investor approval | Arbitrum | `0xfec7bd8d528876d19f5636ad362a7b3acb829576b800b4e8df1168e9238069eb` | 55,723 | Approve deposit |
| Second investor deposit | Arbitrum | `0x05599c50c2c03cee9742451fa818177f5904aa2850dbb696eef09e5e9eb959e2` | 744,679 | 1 share minted; 1.003370 USDC charged |
| Second investor Instant Payout | Arbitrum | `0x67b85178e9c069883caccd90f5150b19cd62d4869b15a731b0ffec2b625816df` | 867,177 | Burn 1 share; 0.975878 USDC paid; zero outstanding |
| collectIncome | Robinhood | `0x83a03f9f90415a110185cd42b607574887056eec73998433039b33e7330c2336` | 338,786 | 21 USDG base units retained; COLLECT deferred |

Across matching checked chains, deposit ID, depositor/recipient, both tokens, amounts, deadlines, relayer,
message hash and vault arrival. Transit ID
`0xaccc9953f586ff761b128fd8c638b7d53f601c7fc23837aad3ae40495941bddd`;
origin **42161**, kind **Principal**, received **4.966000 USDG**. The **0.034000** base-value difference
is the adapter's selected send gap, not the API's suggested relayer fee (**0.013001 USDC**) in isolation.

Manager Instant Payout: gross **0.995750**, Payout Fee **0.019915**, flow fee **0.002489**, paid
**0.973346 USDC**. Second investor Instant Payout: requested **1.000000**, gross **0.998339**,
Payout Fee **0.019966** (2%), flow fee **0.002495** (0.25%), paid **0.975878 USDC**;
**998339 − 19966 − 2495 = 975878** base units. Receipt reports zero Market Costs, absorbed Market Costs,
leaver cost, unwind proceeds and outstanding amount. Settlement Share Price was
**0.998339125 USDC/share** (raw **998339125000000000000000**); shareAssets **7,986,713** base units,
pre-burn supply **8e18**. These are real Instant Payouts from Idle, not Standard Payout/unwind tests.

### Recorded state and income outcome

The last complete state snapshot in `positions.jsonl`, **2026-10-03 13:30:19 UTC**, follows report sequence **12**:
fund **Open** (state 0), Share Price **1.000921142857142857142857 USDC/share**
(raw **1000921142857142857142857**, scale **1e24**); total supply **7e18** = **7 shares**;
Core Vault Idle **1.044162 USDC**; Robinhood Unallocated Balance **0.003782 USDG**;
**one Robinhood V4 position and one Arbitrum Aave position**. Manager holds all **7 shares**;
second investor holds **0**; both recorded `incomeOwed` values are **0**.

The later income-stage receipt collected **21 base units = 0.000021 USDG**, below the configured
**500,000 base units = 0.50 USDG** minimum. Income stayed on the Spoke Chain; **no COLLECT, return bridge,
conversion, Income Withdrawal or ACK was executed** in this stage. The state snapshot is pre-collection:
the evidence does not include a fresh complete post-income Share Price/Idle/position valuation. Do not
present its figures as a later live balance or add retained income to Share Assets without a new report.

### Mainnet-only findings and tooling fixes

- **300-second fetch headers timeout:** the first capital attempt stopped around 303 seconds with **zero
  broadcasts**, although the report needed about 14 minutes. The shared Node HTTP report client waits up to
  **35 minutes**; report lifetime remains 1,588 seconds and stale reports still fail closed.
- **Across route parameters:** legacy `token` terms returned HTTP 400 for USDC → USDG. Requests now name
  `inputToken` and `outputToken`; adapter fee constraints remain immutable (DEC-158/176).
- **RPC log cap:** the provider's free tier rejects ranges over **10 blocks**. Smoke scans were bounded;
  keeper now supports `ALPHA_LOG_RANGE` (default **1000**, minimum **1**), catches up in bounded windows
  within a **20-second scan budget**, and stores an independent credited cursor plus matched totals in
  durable keeper state. Legacy files backfill from the fund's Hub start; restarts do not recount completed
  windows. Set **ALPHA_LOG_RANGE=10** on that tier, but use PAYG/another provider for continuous Robinhood
  operation at roughly **10 blocks/second**. Budgeting stops between requests, not a hard RPC cancellation.
- **Resume allow-list:** the explicit `bridge` mode resumes after the successful manager deposit without
  repeating it; the command allow-list now accepts that phase. Reconcile receipt state before recovery.
- **Robinhood verification:** Sourcify replaces the challenged public Blockscout endpoint; coverage is 11/11.

No contract code changed for these findings. API-driven reports enabled the smoke despite keeper ticks failing;
this is **not a passing continuous-keeper/order-relay demonstration**. Local API/keeper processes were stopped
at the end of the smoke; preserve their state for an explicitly supervised restart.

### Not exercised on mainnet

- **Closure/frozen exits:** not run; the alpha intentionally remains Open with V4/Aave positions. Irreversible
  closure requires a separately approved run and a working return/ACK relay.
- **Standard Payout:** only Instant Payouts were requested; Idle funded them, so asynchronous unwind/settlement
  was unnecessary. Historical fork lifecycle coverage is not substituted for a live Standard Payout.
- **COLLECT above the minimum:** only 21 base units of income accrued, below 0.50. No artificial capital or
  repeated deposit was used to manufacture bridgeable income; retry income only when real accrual qualifies.
- **Keeper order relay:** no live UNWIND/CLOSE/COLLECT order path was exercised; the free-tier log cap stopped
  keeper progress. The bounded-scan changes have mocked-client tests, not a new continuous live keeper run.

This is internal-alpha evidence, not a full live closure/conservation certificate, external audit or public-capital approval.
