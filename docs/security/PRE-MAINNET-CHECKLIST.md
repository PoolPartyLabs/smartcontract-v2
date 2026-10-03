# Pre-mainnet checklist: internal alpha versus public release

Status at **2026-10-03**, `main` **`f88b25b`**, through PR #23 and PR #21 (including #22), DEC-001..DEC-187.
Checked items mean baseline evidence exists, not that deployment happened. Historical reports are not release certificates.
DEC-134 permits a small Pool Party-capital internal alpha; public/customer use requires the remaining gates.

## A. Decisions and scope

- [x] Register synced to DEC-187 with code statuses and PR evidence; Slack DEC-186 management cap is **500 bps**,
      DEC-187 manager pays own gas. Performance range **1000–9000 bps** applies at creation (PR #12).
- [x] S-8/F-13 answered by DEC-129: no mandatory manager oracle floor, **accepted residual**, not fixed.
- [x] S-5 cap question answered by DEC-130/144 (0.5 ETH floor + top-up per chain); native implementation deferred,
      current base-token sink remains; script/harness defaults 0.
- [x] S-15 attribution question answered DEC-117/138/145/152/161; recognition/dollar cohorts implemented PR #18/#23; entry-time filter deferred.
- [x] DEC-169/176/177/183 bridge rule: own last-3-send reference, unsigned MVP, 1% rate plus fixed token component.
- [x] Record ruling 2026-10-02: native Operating Cash, gas refunds and DEC-185 top-up deferred; DEC-165 caps confirmed.
- [x] Record DEC-167 closure-event/frozen-split ruling, not per-holder snapshot; implemented PR #21.
- [x] **WP-09 proportional unwind — implemented #19 via #23.**
- [x] **WP-10 income dollar index — implemented #18 via #23.**
- [x] **WP-12 spoke orders — implemented #22 via #21.**
- [x] **WP-13 closure — implemented #21.**
- [ ] Resolve deferred entry-time rule DEC-145 and pricing hierarchy/report fallback before public use.
- [ ] Resolve empty-route spot-reference Market Cost attribution (PR #7), creation-price caching and registry-owner
      versus immutable-signer discrepancy; disposition in OPEN-QUESTIONS.

## B. Verification and review gates

- [x] Internal sweep and independent model reviews recorded; merged PRs reviewed, fixes carry regression evidence.
- [x] DEC-131 completeness/size suite: **3/3**, every runtime <=24,576 bytes. SpokeUnwindLib
      **23,473 / 1,103 margin**, SpokeVault **22,887 / 1,689**, CoreVault **22,862 / 1,714**; no margin below 1,000.
      Docs-only before/after identical; complete measured table in [MVP report](../reports/2026-10-03-MVP-REPORT.md).
- [x] Fresh build and `forge fmt --check` pass; **1,432 non-fork tests / 183 suites**, including size suite.
- [x] Fresh full fork run with RPC helper: **222 tests / 56 suites**, fixed archive pins 511007613 / 78293056.
      CI has five isolated fork shards and validates scenario-shard `_createForks()` coverage (PR #8).
- [x] Fresh relevant unit/fork gas reports; operation samples in MVP report, not worst-case release gas certificates.
- [ ] Freeze final release SHA and re-run complete lifecycle harness after PR #24 merges. PR #23's
      **46 steps / 294 assertions** and API **19 concepts** are historical pre-closure evidence, not the final run.
- [ ] Unit tests -> invariants -> formal verification -> independent external audit in DEC-133 order. Internal
      alpha acceptance is not a replacement for public audit or post-change rebaseline.
- [ ] Re-measure v4 worst-case report delivery gas and creation gas on both chains; old v3 26.87M report gas is historical.
- [ ] Re-run deep fuzz campaigns, coverage, static-analysis triage/ratchets, symbolic checks and mutations on release
      code, including new codecs/libraries. Do not treat old percentages as current coverage.
- [ ] Public deployment must close or explicitly gate above-low exploitable PoCs, including accepted internal-alpha
      risks; accepted economics must be disclosed, never relabeled fixed.
- [ ] External audit findings fixed with regression tests and reviewed; public security contact/bounty defined.

## C. Deployment gates (internal alpha included)

- [x] PR #20 alpha fork rehearsal and PR #21 nested-library deployment/startup regressions recorded.
- [ ] Re-run dual-chain deployment/address checks on the frozen final release; no mainnet broadcast attested here.
- [ ] Verify Wormhole Core/chain ids, Across SpokePool/buffers, V3 factory/QuoterV2/router, V4 managers, Aave Pool,
      token/feed configuration, Protocol Recipient, guardian, API signer and ManagerRegistry owner.
- [ ] Explicitly configure Operating Cash floor/top-up **0** for the alpha; confirm no manager changes reintroduce sink.
- [ ] Publish linked addresses: **CoreVaultIncomeCollectionLogic, CoreVaultIncomeLogic, CoreVaultLogic, CoreVaultPayoutLogic,
      CoreVaultClosureLogic, CoreVaultTransitLogic, SpokeCrossChainLib, SpokeUnwindLib, SpokeCloseLib, SpokeIncomeLib**. Verify library dependency links and stored vault creation code.
- [x] Factory deployment checks wiring/direct and nested links; PR #21 fixed dependency-first artifact linking.
- [ ] Obtain real guardian-signed VAA for the new emitter, live Across route/fill confirmation and explorer access
      (PR #20 Robinhood explorer probe returned 403); fork guardian/fills are not mainnet certification.
- [ ] Verify source on both explorers; record deployment SHA, salts, addresses, Mandate hashes, fee rates and fund seed.
- [ ] Hardware/multisig custody, guardian deprecation runbook and immutable API-signer compromise plan; registry owner
      `Ownable2Step` transfer/override behavior disclosed. No silent claim of signer rotation.
- [ ] Security contact reachable; alpha risk acceptance approved and recorded. No customer funds/marketing as audited.

## D. Operations and disclosure

- [ ] Keeper acknowledges fully credited/refunded spoke transits: publish `acknowledgeSpokeTransit`, deliver
      ACKNOWLEDGE to `executeOrder`, retry/republish as needed. Hub credit alone does not reclaim the 16-slot capacity.
- [ ] Monitor silent-spoke freshness/closure stalls (DEC-157/160); no inactivity fallback. Disclose that Standard
      Payout Wormhole fees and all transaction gas remain caller/keeper-funded; no refunds in this MVP.
- [ ] Rafael approves input sheet: role addresses/keystores, fees, seed/Spoke Cap/Mandate, ETH budgets on both
      chains, authenticated API/supervisor/incident contact and maximum alpha exposure; see MVP report/DEPLOYMENT-ALPHA.


- [ ] Funded keeper/API for alpha, manager funded for own gas (DEC-187); reports after deposits/burns where required,
      prompt finalized VAA delivery, first accepted report before first send, monitored reports and transits.
- [ ] Verify keeper dispatch of live UNWIND/CLOSE/COLLECT/ACKNOWLEDGE and retirement/republication on the final
      release; the PR #20 alpha runtime predates ACK retirement and is not certified for that queue by this docs WP.
- [ ] Recognize refunds and recover unlisted arrivals immediately after enabling reports; retry owed fee transfers;
      match Across arrivals by full relay/event evidence, not `transitId` alone.
- [ ] Monitor expiry causes and route limits before fee retries; disclose **rate cap plus fixed fee** and no signed
      bridge quotes. Reverify service addresses/API route availability before release.
- [ ] Monitor source staleness/sequencer status, report age, unmatched arrivals, owed fees, Share Price and Operating Cash.
- [ ] Read Mandate immutable Payout Fee <=10%, performance 10–90%, management 0–5%, flow fee <=1%, Spoke Caps,
      zero-transfer shares and accepted manager price discretion with shareholders.
- [ ] Pool Party wallets/capital only, small seeded canary fund; fund discovery does not prevent external deposits.
- [ ] Publish fresh full-flow Payout/income/closure and Share Price evidence after relevant WPs merge; cleanly stop
      local keeper/API/anvil processes after rehearsal.
- [x] Current docs distinguish partial foundations, accepted risks, deferred requirements and historical snapshots.
- [ ] Resolve public gates in KNOWN-LIMITATIONS and record final release test/size/gas evidence, not just this docs sync.
