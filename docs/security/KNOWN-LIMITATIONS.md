# Known limitations: merged internal-alpha baseline

Baseline: **`origin/main` `334eae6`**, October 3, 2026, including merged PR #24/#25/#26/#28/#29.
The conformance dispositions below supersede historical review snapshots.
These are accepted risks and unfinished requirements, not a claim of public readiness. Historical review snapshots
remain evidence for their original commits; current status is here and in [FINDINGS](FINDINGS.md).

## Conformance alpha exceptions (2026-10-03)

These are explicitly accepted **only for the protocol-owned internal alpha** by the conformance-fix task, not
silently implemented or approved for third-party deposits. G-01 remains pending the founder (DEC-145).

| Finding | Accepted scope and reason | Evidence |
|---|---|---|
| G-01 / DEC-145 | Remote entry-time eligibility is absent; WP-14 is deferred. Later spoke counter advances may include pre-deposit income. **Founder decision pending**; no claim of full DEC-014/145 conformance. Internal alpha operators must disclose this timing exception. | `src/core/CoreVaultIncomeLogic.sol` recognition hook; `src/libraries/DollarIncomeIndex.sol` mint adjustments |
| G-02 / DEC-045/124/161 | An Open-fund full exit pays converted dollars; unconverted token rights survive zero shares and need later collection. Accepted because rights are preserved, not confiscated; disclose the later Income Withdrawal. Closed exits still require final collection. | `src/core/CoreVaultIncomeLogic.sol` balance-change and withdrawal hooks; `test/unit/core/CoreVaultIncome.t.sol` full-exit regression |
| G-03 / DEC-092/098/104 | Gross Assets temporarily omits Income bridging home. Accepted as an informational aggregate defect, not authorization to count Income in Share Assets or a demonstrated payout loss. Telemetry must include Income return legs separately. | `src/core/CoreVaultLogic.sol` gross valuation; `src/spoke/SpokeCrossChainLib.sol` Income debit on send |
| G-04 / DEC-066 C1 | Return Spoke Cap usage uses bridge output rather than amount sent, understating occupancy by the bridge fee. Accepted for small protocol-owned alpha balances; do not claim symmetric sent-base conformance. | `src/core/CoreVaultLogic.sol` return-leg valuation and cap usage |
| G-06 / DEC-089/094/099 | Mandate report lifetime remains selectable within one day. Accepted only with the checked alpha value **1,588 seconds**; deployment validation is not protocol-wide per-network enforcement. | `src/mandate/Mandate.sol` spoke validation; `script/FundMandate.sol` report lifetime |
| G-07 | Direct construction permits distinct Protocol Recipient and excess recipient. Accepted because the standard factory wires both to the same protocol destination; verify equality on the alpha deployment. | `src/core/CoreVaultTypes.sol` wiring; `src/factory/FundFactory.sol` constructor arguments |

No G-01/G-02/G-03/G-04/G-06/G-07 behavior is changed by this patch. Other historical risk acceptance, including
manager execution-price risk, is unchanged. This is not an external security audit or public-readiness certificate.

Resolved deployment blockers: B-01 gates actual Hub Spoke Vault exposure on Core Fund State (only base-token
unwind swaps while Closing); B-02 records terminal dust exclusions and leaves them to `sweepExcess` (see
[CLOSURE-DUST](CLOSURE-DUST.md)); B-03 enforces zero Operating Cash (see [OPERATING-CASH-MVP](OPERATING-CASH-MVP.md));
G-05 tracks recovered-dollar reservations and never credits Idle after Closed. B-04 is evidenced by the final
build/test/private-port harness rehearsal, not by real production guardian or bridge liveness.

## 1. Accepted economics and remaining exposure

| Finding / rule | Current status | Operator consequence |
|---|---|---|
| S-8 / DEC-129 | **Accepted**, manager swaps have no mandatory oracle floor; PR #4/#7/#13 route adapter does not remove this risk | Manager/colluding counterparty can move pool spot and drain value; optional API minimum is not a contract invariant. Use protocol-owned small alpha capital, secure manager/signer keys |
| C-01 / D-18 / DEC-132/137 | Proportional swap-adapter unwind implemented PR #19/#23, #22/#21; pre-sale spot manipulation remains accepted only for internal alpha | Legacy mandatory 5% oracle floor removed; optional loss bound is against a manipulable spot. Flow fee is revenue, never an attack brake (DEC-119) |
| PR #7 empty-route reference | Whole-fill tiers ranked by output; chosen pre-sale spot can be manipulated | Live Market Cost/maximum calculations now use that spot (PR #19/#23, #22/#21); a route change does not fix inflated/discounted reference economics |
| S-5 / DEC-130/144 | Decision answered, native implementation **deferred**; current Operating Cash is uncapped base-token sink | Defaults 0 in creation script/harness reduce exposure, but manager parameter setters can still divert principal; no spend/return path. Zero defaults are not enforcement |
| S-15 / DEC-117/138/145/161 | Recognition-time token cohorts and live dollar index implemented PR #18/#23; entry-time filter WP-14 deferred | Already recognized rights remain with original holders, including delayed fills; income first recognized from stale reports after entry can still benefit entrants |
| S-17 / DEC-155 | Former 99% Payout Fee risk narrowed to **10% cap** (PR #3), immutable per fund | Read Mandate before deposit; flow fee up to 1% is additional |
| S-53 / DEC-123 | Factory validates nonzero prices for configured tokens (PR #12); broader reliable-source hierarchy incomplete | Never-priced tokens can still fall back to zero after a source failure; creation price is not cached into `lastPrice` |
| S-35 / DEC-128 | USDG priced 1:1 by alpha configuration | Depeg is not detected by a 1:1 source; dollar bridge accounting depends on this assumption |
| PR #12 L-2 / DEC-114 | Accrual rounds down; clock retained if less than one base unit booked | Entrant pre-entry charge < `(new base / old base)` USDC base units for positive old base; approximately 0.01 USDC at 1M over a 100-USDC old base, not a global loss bound |

## 2. Cross-chain liveness and bridge rule

- **Silent-spoke exit liveness (DEC-157/160).** No inactivity switch: a spoke that never answers blocks exits that
  need its fresh report and prevents closure finalization. Permissionless relay helps keeper outages, not a silent
  chain/vault. Closed frozen exits do not need reports (DEC-163), but reaching Closed does.
- **Hub acknowledgements reclaim spoke capacity (PR #22 round 3).** Fully credited/refunded historical sends stay
  on the spoke until a targeted ACKNOWLEDGE is delivered. Sixteen undelivered acknowledgements can block later
  sends/exits. Anyone can republish `acknowledgeSpokeTransit` and deliver to `executeOrder`; the keeper must do so.
  Never retire an unresolved obligation merely because time passed; the Hub publisher requires credit/refund proof.
- **Standard Payout Wormhole fees are caller-funded for now.** Manager pays own gas (DEC-187), keepers/callers
  pay publication/delivery/execution gas and message fees; no Operating Cash reimbursement. Collection/bridge
  accounting is separate from transaction funding. Refund DEC-164/165 and top-up DEC-185 are post-buildathon.
- **Shared encoder carry-over (PR #21 round 3 L-1).** `SpokeUnwindLib.acknowledgeTransit` writes
  `abi.encode(records)` instead of `SpokeUnwindTypes.encodeResults(records)`. Bytes match today, but the shared
  416-byte result-size assertion is bypassed. Low follow-up; unchanged in this docs-only WP.


- **Adapter rate cap is 1%, fixed fee additional.** `AcrossBridgeAdapter` computes
  `ceil(inputAmount * rate / 1e18) + 0.03 input-token units`. At cap a 100-USDC send pays 1.03 USDC, not 1.00;
  on small sends the total percentage can be much larger, and fee >= input reverts. DEC-169's wording is a 1%
  “fee cap”; DEC-177 separately confirms the fixed part. Record this total-gap distinction instead of pretending
  it is a vault/Mandate cap. There is no caller-selected quote or relayer (DEC-158/176).
- **Window is the fund's own sends, not market history.** Adapter storage is destination-keyed; mean of last 3
  recorded rates (missing slots contribute 0.08% to the mean), floor 0.03%, x1.5 expiry step, rate cap 1%. Oversize sends or
  relayer downtime can trigger the same step as low fee. High bridge-market fees can keep sends expiring.
- **Future native bridge residual N1:** fixed fee is 0.03 token units (0.03 WETH is not three US cents); destination-only
  windows conflate token routes. Native gas bridge needs value-based fixed amount and separate token/route windows.
  Gas bridge/unwrap is deferred despite DEC-180/185; nothing here implements it.
- Across refund research observed **57–99 minutes after fill deadline** (2026-10-02 sample), not a guaranteed bound.
  The adapter's fill window is bounded by SpokePool buffer and the 6-hour constant; refund/retention/liveness are distinct.
  `fillStatuses` is keyed by relay hash, not deposit id. Route maximums/availability must be checked operationally.
- Per-send keyless TransitEscrow and arrival reconciliation prevent arbitrary output reductions/double counting;
  they do not make refunds instant. S-4/S-45 recovery should occur immediately after a report built after an
  unlisted arrival, before an entrant can price between report acceptance and recovery.
- Hub-bound listing is capped at 64; arrival window 256; open positions 16. Do not reuse the old v3 26.87M-gas
  worst-case report as a **v4** gas certificate: fresh report gas in the MVP report is a sampled measurement, not a worst-case certificate.
- Report age, source failure, sequencer outage and immutable Spoke Cap can block allocation/mints. Existing PAYOUT
  fallback remains, and may use `lastHubValue`/cached token prices. Fresh report/burn gates are implemented; cached price fallback is not a report-age bypass.

## 3. Orders, reports, closure and guard

- UNWIND/CLOSE/COLLECT executors and permissionless settlement are implemented (PR #18/#23, #22/#21).
  This helps a dead manager's exits, but does not replace required reports/transit proofs. Spoke acknowledgement
  delivery remains necessary; the 72-hour closure window does not guarantee immediate closure completion.
- Increasing order sequence rejects reordered older orders; gaps accepted. Instant consistency 200 and 1-hour
  lifetime are engineering parameters, reports use finalized 202. Replayed UNWIND/CLOSE ids are rejected even
  under a newer sequence. Fork regressions cover actual CLOSE/UNWIND result/report/arrival/retry paths, not all reorgs.
- Report v4 result blobs are populated. Current shared UNWIND/CLOSE record is 416 bytes; the #21 review found/fixed
  a multi-result stride mismatch. Off-chain decoders must track this ABI; v3 is incompatible. Deposit reporting
  helper remains off-chain, not atomic (DEC-159).
- **Mid-swap mint guard fixed PR #13 M-1 / #15.** `buildReport` reverts inside guarded Spoke Vault entries, preventing
  mint against intermediate NAV. Other views remain readable; cached payout valuation remains separate from
  the now-enforced fresh-report/post-unwind gate. This does not constrain manager execution price.
- Closure/frozen event/late-value exclusion implemented PR #21. Live income cohorts implemented PR #18/#23;
  deferred entry-time eligibility, final release scenario evidence from PR #24 and public verification gates remain.

## 4. Keys, defaults and release gates

- API route signer is immutable per factory/adapter (DEC-170); leaked signer can sign routes indefinitely for that
  version. Signed routes have deadline but no one-shot nonce; valid routes may be replayed until expiry.
  Deployment defaults registry owner to signer, but allows `REGISTRY_OWNER` override and `Ownable2Step` transfer.
  Permanent same-key registry ownership must not be asserted.
- Manager pays own gas (DEC-187); keeper self-funds reports, deliveries and orders. Native Operating Cash, DEC-164/165
  refunds and DEC-185 bridge top-up are post-buildathon by ruling 2026-10-02. Spec MVP versus delivery scope is an
  explicit divergence, not silently closed work.
- No on-chain fund-value ceiling or alpha depositor allowlist (DEC-134/174). “Pool Party wallets only” is operational
  policy; an outsider discovering an alpha fund may deposit. No product marketing as public-ready.
- Fresh runtime sizes: SpokeUnwindLib **23,473 B / 1,103 B margin**, SpokeVault **22,887 / 1,689**,
  CoreVault **22,862 / 1,714**. Every runtime <=24,576; none below 1,000 margin. The smallest margin is only
  103 bytes above that warning threshold. Full table/tests/gas: [MVP report](../reports/2026-10-03-MVP-REPORT.md).
  BASELINE-2026-10-02 remains historical, not a current size certificate.
- Full external audit, post-change formal verification, public security contact/bounty, key governance and final
  end-to-end closure/attribution evidence remain gates. DEC-133 orders unit -> invariants -> formal -> audit.
  External protocol security and LP market risk are outside this repository's review scope.
