# Known limitations: merged internal-alpha baseline

Conformance addendum: **2026-10-03**, based on `origin/main` `2b04b28` plus the conformance-blocker fixes.
The addendum below supersedes stale historical baseline descriptions in sections 1–4.
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
| C-01 / D-18 / DEC-132/137 | Proportional unwind — **WP-09 in progress**; pre-sale price manipulation residual is accepted only for internal alpha DEC-134 | The old 5% oracle/spot floor still exists; do not assume proportional sizing or the future no-floor rule shipped. Flow fee is revenue, never credited as an attack brake (DEC-119) |
| PR #7 empty-route reference | Adapter ranks whole-fill V3 tiers by output, but the reference spot can be above/below market on a third-party tier | Maximum loss may block honest sales or misstate loss; interim no-Market-Cost charging against empty-route spot remains a carry-over for WP-09/12/13, not a implemented public guarantee |
| S-5 / DEC-130/144 | Decision answered, native implementation **deferred**; current Operating Cash is uncapped base-token sink | Defaults 0 in creation script/harness reduce exposure, but manager parameter setters can still divert principal; no spend/return path. Zero defaults are not enforcement |
| S-15 / DEC-117/138/145/161 | Recognition-time/dollar attribution **WP-10 in progress**, entry-time filter WP-14 deferred | Live collection-time index can attribute older income to entrants. Do not call this fixed because `DollarIncomeIndex` exists standalone |
| S-17 / DEC-155 | Former 99% Payout Fee risk narrowed to **10% cap** (PR #3), immutable per fund | Read Mandate before deposit; flow fee up to 1% is additional |
| S-53 / DEC-123 | Factory validates nonzero prices for configured tokens (PR #12); broader reliable-source hierarchy incomplete | Never-priced tokens can still fall back to zero after a source failure; creation price is not cached into `lastPrice` |
| S-35 / DEC-128 | USDG priced 1:1 by alpha configuration | Depeg is not detected by a 1:1 source; dollar bridge accounting depends on this assumption |
| PR #12 L-2 / DEC-114 | Accrual rounds down; clock retained if less than one base unit booked | Entrant pre-entry charge < `(new base / old base)` USDC base units for positive old base; approximately 0.01 USDC at 1M over a 100-USDC old base, not a global loss bound |

## 2. Cross-chain liveness and bridge rule

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
  worst-case report as a **v4** gas certificate: v4/result-book growth needs release remeasurement.
- Report age, source failure, sequencer outage and immutable Spoke Cap can block allocation/mints. Existing PAYOUT
  fallback remains, and may use `lastHubValue`/cached token prices. DEC-160 burn freshness is not complete.

## 3. Orders, reports, closure and guard

- **WP-12 spoke orders — in progress.** Order v1 verification and `executeOrder` exist (PR #5/#15), but UNWIND,
  CLOSE and COLLECT executors all revert `OrderKindNotSupported`; cursor changes roll back. Dead manager keys can
  still strand spoke capital (S-36), so do not describe permissionless execution as available recovery.
- Strictly increasing order sequence rejects reordered older orders; gaps accepted. Orders use instant consistency
  200 and a 1-hour engineering lifetime; reports finalized 202. Replay guard is implemented, reorg/retry proceeds
  handling is not proved merely by the codec. No inactivity switch (DEC-157).
- Report **v4** has `unwindResults`/`collectionResults` opaque blobs, empty on current baseline. Update decoders;
  v3 reports are incompatible. `/report/after-deposit` is an off-chain helper, not atomic deposit reporting.
- **Mid-swap mint guard fixed PR #13 M-1 / #15.** `buildReport` reverts inside guarded Spoke Vault entries, preventing
  mint against input-debited/output-uncredited NAV; mint/view valuation reverts, payout valuation uses `lastHubValue`.
  Other views remain readable. This does not constrain manager execution price or make all cached payouts fresh.
- **WP-13 closure — in progress.** `closeFund` reaches Closing, but no finalization/Closed exits/frozen event record.
  Late-arrival accounting required by DEC-167/ruling 2026-10-02 is not shipped.
- **WP-09 proportional unwind — in progress. WP-10 income dollar index — in progress.**

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
- Fresh runtime sizes: SpokeVault **22,304 B / 2,272 B margin**, CoreVault **20,996 / 3,580**; every contract/linked
  library <=24,576 and no margin below 1,000. Old 559/854/4,293-byte Spoke Vault margins are historical, not current.
  Full table: [BASELINE-2026-10-02](BASELINE-2026-10-02.md).
- Full external audit, post-change formal verification, public security contact/bounty, key governance and final
  end-to-end closure/attribution evidence remain gates. DEC-133 orders unit -> invariants -> formal -> audit.
  External protocol security and LP market risk are outside this repository's review scope.
