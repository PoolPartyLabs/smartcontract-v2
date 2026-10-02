# Pre-mainnet checklist: internal alpha versus public release

Status at **2026-10-02**, `main` **`1db9a9d`**, through PR #15, DEC-001..DEC-187.
Checked items mean baseline evidence exists, not that deployment happened. Historical reports are not release certificates.
DEC-134 permits a small Pool Party-capital internal alpha; public/customer use requires the remaining gates.

## A. Decisions and scope

- [x] Register synced to DEC-187 with code statuses and PR evidence; Slack DEC-186 management cap is **500 bps**,
      DEC-187 manager pays own gas. Performance range **1000–9000 bps** applies at creation (PR #12).
- [x] S-8/F-13 answered by DEC-129: no mandatory manager oracle floor, **accepted residual**, not fixed.
- [x] S-5 cap question answered by DEC-130/144 (0.5 ETH floor + top-up per chain); native implementation deferred,
      current base-token sink remains; script/harness defaults 0.
- [x] S-15 attribution question answered DEC-117/138/145/152/161; implementation not complete.
- [x] DEC-169/176/177/183 bridge rule: own last-3-send reference, unsigned MVP, 1% rate plus fixed token component.
- [x] Record ruling 2026-10-02: native Operating Cash, gas refunds and DEC-185 top-up deferred; DEC-165 caps confirmed.
- [x] Record DEC-167 closure-event/frozen-split ruling, not per-holder snapshot; implementation in progress.
- [ ] **WP-09 proportional unwind — in progress.**
- [ ] **WP-10 income dollar index — in progress.**
- [ ] **WP-12 spoke orders — in progress.**
- [ ] **WP-13 closure — in progress.**
- [ ] Resolve deferred entry-time rule DEC-145 and pricing hierarchy/report fallback before public use.
- [ ] Resolve empty-route spot-reference Market Cost attribution (PR #7), creation-price caching and registry-owner
      versus immutable-signer discrepancy; disposition in OPEN-QUESTIONS.

## B. Verification and review gates

- [x] Internal sweep and independent model reviews recorded; merged PRs reviewed, fixes carry regression evidence.
- [x] DEC-131 completeness/size suite: **3/3**, every production contract/linked library <=24,576 bytes;
      SpokeVault **22,304 / 2,272 margin**; no margin below 1,000. Full unchanged-before/after table in BASELINE-2026-10-02.
- [x] Baseline build and `forge fmt --check` pass; non-fork result in BASELINE-2026-10-02.
- [x] PR #15 records green full fork baseline (216 tests across 5 CI shards); docs-only change affects no fork fixture.
- [ ] Re-run applicable fork/harness suites at the final release SHA; PR #15's harness startup/status/API probe is not
      evidence of the unfinished new Payout/income/closure scenario.
- [ ] Unit tests -> invariants -> formal verification -> independent external audit in DEC-133 order. Internal
      alpha acceptance is not a replacement for public audit or post-change rebaseline.
- [ ] Re-measure v4 worst-case report delivery gas and creation gas on both chains; old v3 26.87M report gas is historical.
- [ ] Re-run deep fuzz campaigns, coverage, static-analysis triage/ratchets, symbolic checks and mutations on release
      code, including new codecs/libraries. Do not treat old percentages as current coverage.
- [ ] Public deployment must close or explicitly gate above-low exploitable PoCs, including accepted internal-alpha
      risks; accepted economics must be disclosed, never relabeled fixed.
- [ ] External audit findings fixed with regression tests and reviewed; public security contact/bounty defined.

## C. Deployment gates (internal alpha included)

- [ ] Fork rehearsal of `DeployFactory.s.sol` and `CreateFund.s.sol` on both chains; predicted addresses matched.
- [ ] Verify Wormhole Core/chain ids, Across SpokePool/buffers, V3 factory/QuoterV2/router, V4 managers, Aave Pool,
      token/feed configuration, Protocol Recipient, guardian, API signer and ManagerRegistry owner.
- [ ] Explicitly configure Operating Cash floor/top-up **0** for the alpha; confirm no manager changes reintroduce sink.
- [ ] Publish linked addresses: **CoreVaultLogic, CoreVaultTransitLogic, CoreVaultIncomeLogic, CoreVaultPayoutLogic,
      SpokeCrossChainLib, SpokeUnwindLib, SpokeIncomeLib**. Verify library dependency links and stored vault creation code.
- [x] Factory deployment checks code/wiring and required library links; final deployed addresses still need verification.
- [ ] Verify source on both explorers; record deployment SHA, salts, addresses, Mandate hashes, fee rates and fund seed.
- [ ] Hardware/multisig custody, guardian deprecation runbook and immutable API-signer compromise plan; registry owner
      `Ownable2Step` transfer/override behavior disclosed. No silent claim of signer rotation.
- [ ] Security contact reachable; alpha risk acceptance approved and recorded. No customer funds/marketing as audited.

## D. Operations and disclosure

- [ ] Funded keeper/API for alpha, manager funded for own gas (DEC-187); reports after deposits/burns where required,
      prompt finalized VAA delivery, first accepted report before first send, monitored reports and transits.
- [ ] Only attempt executable orders; on this baseline all kinds revert. Keeper readiness does not complete WP-12.
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
