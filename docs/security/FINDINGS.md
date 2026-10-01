# Findings register

Consolidated register of the 2026-09-30 security sweep ([`README.md`](README.md)). One entry per finding; duplicates
raised by several lenses were merged and every source id is listed (`SA` static, `DYN` dynamic, `XC` cross-chain,
`AC` accounting, `AX` access, `IN` integrations, `LV` liveness; an `N` suffix marks a finding raised by that lens's
verifier). Where verifiers disagreed the entry keeps the highest verified severity. Commit ids are on `main`.

Status values: **Fixed** (regression tests assert the attack fails), **Open, founder decision** (the PoC still
passes as a pin; the question is stated), **Acknowledged** (the behaviour stays, with the reason), **Refuted**.

## Summary

| Severity | Total | Fixed | Open | Acknowledged |
|---|---|---|---|---|
| critical | 1 | 1 | 0 | 0 |
| high | 10 | 8 | 2 | 0 |
| medium | 4 | 3 | 1 | 0 |
| low | 17 | 4 | 0 | 13 |
| info | 12 | 0 | 0 | 12 |
| **all** | **44** | **16** | **3** | **25** |

Plus one refuted report (`IN-6`, at the end).

## Index

| Id | Severity | Status | Title |
|---|---|---|---|
| [S-1](#s-1) | critical | Fixed | Share Assets valued Uniswap V4 positions at the pool's spot composition (hub inside claimPayout, spoke inside permissionless report()) |
| [S-2](#s-2) | high | Fixed | Automatic unwind sized and floored its swap at a spot the claimant moves first |
| [S-3](#s-3) | high | Fixed | Unfilled send home left every value base between fillDeadline+maxReportAge and its refund |
| [S-4](#s-4) | high | Fixed | Filled send home that no accepted report listed was frozen in unmatchedArrivals |
| [S-5](#s-5) | high | Open, founder decision | Unbounded Operating Cash floor and top-up move principal into a bucket with no exit |
| [S-6](#s-6) | high | Fixed | Spoke created from a Mandate the hub never saw could drain what the hub sends (FF-OQ-1) |
| [S-7](#s-7) | high | Fixed | Hub factory accepted any Mandate spoke token and could bridge Idle into a worthless one |
| [S-8](#s-8) | high | Open, founder decision | Manager swaps have no price anchor (manager trades the fund against itself) |
| [S-9](#s-9) | high | Fixed | Manager self-relayed exclusively at the max bridge fee, send after send; maxBridgeFeeBps capped only at 100% |
| [S-10](#s-10) | high | Fixed | Deprecating the V4 adapter trapped non-base principal and broke the automatic unwind |
| [S-11](#s-11) | high | Fixed | Dust sends home made report() and its VAA delivery exceed the 32M block gas limit |
| [S-12](#s-12) | medium | Fixed | USDC blocklist of the Protocol Recipient or ManagerFeeVault froze deposits, payouts and income |
| [S-13](#s-13) | medium | Fixed | Evidence-free (time-path) expiry released the Spoke Cap of a transit that arrived; pre-listed ids never re-listed |
| [S-14](#s-14) | medium | Fixed | sendToSpoke worked before the fund's Spoke Vault existed (principal lost, kept in Share Assets) |
| [S-15](#s-15) | medium | Open, founder decision | Income earned before an entrant's deposit captured just in time (permissionless forward, unwind, delivery) |
| [S-16](#s-16) | low | Acknowledged | Mints revert while the fund holds a token the immutable price source cannot price; factory accepts any hookless pool |
| [S-17](#s-17) | low | Fixed | Payout Fee plus flow fee above 100% made every Instant Payout underflow |
| [S-18](#s-18) | low | Fixed | At zero Share Assets with shares outstanding every payout verb reverted ZeroSharePrice |
| [S-19](#s-19) | low | Acknowledged | A matured Standard Payout Request never expires (free fee-less timing option) |
| [S-20](#s-20) | low | Fixed | Hub Across callback credited the stated amount without a backing check |
| [S-21](#s-21) | low | Acknowledged | Buckets without exit; _collectIncome ignores IncomeAccumulator.distribute's result |
| [S-22](#s-22) | low | Acknowledged | Escrow balances of transits in a terminal state have no exit |
| [S-23](#s-23) | low | Fixed | A lowered Across fillDeadlineBuffer would make every send, the send home included, revert |
| [S-24](#s-24) | low | Acknowledged | Per-spoke Wormhole chain id and 6-decimal spoke token assumptions not validated on chain |
| [S-25](#s-25) | low | Acknowledged | maxReportAge per spoke is manager-chosen with no protocol bound |
| [S-26](#s-26) | low | Acknowledged | No L2 sequencer-uptime check; payouts never check price age |
| [S-27](#s-27) | low | Acknowledged | One illiquid or paused step (Aave) blocks the whole automatic unwind |
| [S-28](#s-28) | low | Acknowledged | Payout fallback price and hub value have no age bound |
| [S-29](#s-29) | low | Acknowledged | Spoke value not bounded by the Spoke Cap in valuation; variation band stored but unenforced |
| [S-30](#s-30) | low | Acknowledged | 256 USDG fills the arrival window for good (report path of attestExpiry off; 21.7 KB reports) |
| [S-31](#s-31) | low | Acknowledged | Report lifetime equals worst-case finality; any delay above about 26.5 min closes mints |
| [S-32](#s-32) | low | Acknowledged | On the live thin Arbitrum pool a close-type unwind above about 35 WETH cannot meet the 5% floor |
| [S-33](#s-33) | info | Acknowledged | Chainlink min/maxAnswer clamp not detected |
| [S-34](#s-34) | info | Acknowledged | Aave best-effort income bound reads balanceOf(aToken), not the virtual balance |
| [S-35](#s-35) | info | Acknowledged | USDG priced 1:1 puts a depeg straight into the Share Price and the Spoke Cap |
| [S-36](#s-36) | info | Acknowledged | No hub-driven spoke unwind; a dead or compromised manager key traps spoke capital |
| [S-37](#s-37) | info | Acknowledged | CREATE3 proxies stay callable; library wiring immutables informational |
| [S-38](#s-38) | info | Acknowledged | A Standard reserve stays locked if its requester never claims |
| [S-39](#s-39) | info | Acknowledged | Passive patient actor quantified: unprofitable under live Chainlink pricing |
| [S-40](#s-40) | info | Acknowledged | buildReport walks every position on every deposit and claim (gas) |
| [S-41](#s-41) | info | Acknowledged | Carried index remainder can tip an entrant by one base unit |
| [S-42](#s-42) | info | Acknowledged | Deposit flow fee charged on the amount offered |
| [S-43](#s-43) | info | Acknowledged | Areas verified without a finding; dead IncomeAccumulator source-counter code |
| [S-44](#s-44) | info | Acknowledged | Hygiene: unused _spoke, shadowed named return, initializer without event, uncached array length, constant-style names |
| [IN-6](#in-6) | - | Refuted | REFUTED: an illiquid or paused Aave step reverts the whole automatic unwind (reported as a defect) |

## Entries

### S-1

**Share Assets valued Uniswap V4 positions at the pool's spot composition (hub inside claimPayout, spoke inside permissionless report())**

Severity: critical. Status: Fixed. Commit: `d89a472`.

**Sources:** SA-01 (high, unverified), AC-0 (critical), XC-2 (high), AX-9 (high), IN-2 (medium), LV-2 (medium).

**Fix:** CoreVaultLogic._oracleComposition recomputes every range position from liquidity and ticks at sqrt(price0/price1), using SqrtPriceMath.

**Regression tests:** test_SEC_S1_* in accounting/SharePriceSpotManipulation (2), crosschain/SpotManipulatedReport, access/SpotCompositionExit, integrations/CompositionSharePrice, liveness/POC_CompositionMarking, and fork/security/SpotCompositionInflation (passes on the live pool).

### S-2

**Automatic unwind sized and floored its swap at a spot the claimant moves first**

Severity: high. Status: Fixed. Commit: `d701388`.

**Sources:** AC-1, IN-1 (high).

**Fix:** SpokeVault._unwindSwap floors at max(spotQuote, ICoreVault.priceSource value) less 5%. A crashed spot makes the unwind revert and the claim is paid from Idle (DEC-068).

**Regression tests:** test_SEC_S2_* in integrations/UnwindSpotSandwich and accounting/UnwindAtManipulatedSpot.

### S-3

**Unfilled send home left every value base between fillDeadline+maxReportAge and its refund**

Severity: high. Status: Fixed. Commit: `91f81e3`.

**Sources:** DYN-01 (unverified), XC-0, AC-3, AX-7, LV-N1 (high), XC-N1 (medium, Spoke Cap variant).

**Fix:** a send home stays listed until its refund is recognized or HUB_BOUND_RETENTION (3 days, OPEN) has passed; report() and sendToHub recognize a refund that has landed.

**Residual:** an Across refund later than the retention reopens the gap.

**Regression tests:** test_SEC_S3_* in FundSystemPoC (2), ExpiredSendHomeDiscountedMint, ExpiredSendHomeCapBypass, ExpiredSendHomeBaseGap, ExpiredSendHomeMint, POC_ReturnLegValuationGap, and SpokeVaultSpoke (2). The invariants now pass with SEC_LATE_REFUNDS=true.

### S-4

**Filled send home that no accepted report listed was frozen in unmatchedArrivals**

Severity: high. Status: Fixed. Commit: `cd31c1f`.

**Sources:** DYN-02 (unverified), SA-02 (medium, unverified), XC-1, AC-2, AX-8 (high).

**Fix:** the 3-day listing from 91f81e3, plus a permissionless recoverUnlistedArrival(spokeIndex, transitId) once pendingSince + 6 h + retention + 2 x maxReportAge has passed. The recovered amount joins the transit's credited total, so it is never counted twice; room is guarded against underflow.

**Regression tests:** test_SEC_S4_* in SendHomeStranded (2), HubBoundTransferFrozen, UnmatchedReturnLeg, FundSystemPoC, and StaticReviewFindings (2).

### S-5

**Unbounded Operating Cash floor and top-up move principal into a bucket with no exit**

Severity: high. Status: Open, founder decision. Interim commit: `23c317a`.

**Sources:** DYN-03 (high, unverified), SA-03 (medium, unverified), XC-3 (downgraded to medium), AC-5 (low), AX-5 (high, confirmed), LV-4 (low).

**Question:** should the floor and top-up get a protocol cap (DEC-100 says none on the floor), and which verb returns or spends Operating Cash before fund close (DEC-096)?

**Interim mitigation:** releaseOperatingCash(amount), manager only, returns Operating Cash above the floor to Idle or Unallocated Balance, so a mistake is reversible.

**Regression tests:** test_SEC_S5_* on hub and spoke. The PoCs stay as pins.

### S-6

**Spoke created from a Mandate the hub never saw could drain what the hub sends (FF-OQ-1)**

Severity: high. Status: Fixed. Commit: `cca9c48`.

**Sources:** AX-1 (high), XC-6 (low).

**Fix:** ReportCodec v3 carries mandateHash and applyReport reverts WrongMandate. Works together with d602e73 (S-14) and 46eef9e (S-9).

**Regression tests:** RogueSpokeMandate test_SEC_S6_reportsOfASpokeRunningAnotherMandateAreRejected and test_SEC_S9_rogueSpokeMandateCanNoLongerAuthorizeTheOneSendDrain.

### S-7

**Hub factory accepted any Mandate spoke token and could bridge Idle into a worthless one**

Severity: high. Status: Fixed. Commit: `d602e73`.

**Sources:** AX-2 (high). Closed by S-14 together with S-6: a spoke whose token is not the chain's base token can never be created, so it never reports and is never funded. The DEC-089 supported-chain registry is still recommended.

**Regression test:** UnverifiedSpokeToken test_SEC_S7_hubCanNoLongerBridgeIdleIntoAWorthlessSpokeToken.

### S-8

**Manager swaps have no price anchor (manager trades the fund against itself)**

Severity: high. Status: Open, founder decision.

**Sources:** AX-3 (high), LV-8 (low), IN-9 (info).

**Question:** should manager swaps be bounded against a price the manager does not control (price source on the hub, TWAP or accepted risk per pool on a spoke), or does DEC-030 (no loss limit) cover a self-set price (OQ-04, DEC-027)? No interim mitigation: a spot floor would not stop the manager, who moves the spot itself. PoC ManagerSwapNoPriceGuard still passes.

### S-9

**Manager self-relayed exclusively at the max bridge fee, send after send; maxBridgeFeeBps capped only at 100%**

Severity: high. Status: Fixed. Commit: `46eef9e`.

**Sources:** AX-4 (high), XC-8 (low), AX-N1 (medium).

**Fix:** both vaults revert ExclusiveRelayerNotAllowed, and MAX_BRIDGE_FEE_BPS = 100 (OPEN).

**Residual:** a manager who over-quotes up to the bound still pays the fastest relayer; a per-period fee budget is a founder decision.

**Regression tests:** test_SEC_S9_* in BridgeFeeChurn, UncappedBridgeFee, RogueSpokeMandate and Mandate.t.sol.

### S-10

**Deprecating the V4 adapter trapped non-base principal and broke the automatic unwind**

Severity: high. Status: Fixed. Commit: `d32d265`.

**Sources:** AX-6 (high), LV-3 (medium).

**Fix:** when deprecated, swapExactInput only runs a swap whose output is ISpokeVault.baseToken (an exit); swaps out of the base token and entries stay blocked.

**Regression tests:** test_SEC_S10_* in DeprecationTrapsNonBaseTokens (2) and POC_DeprecatedAdapterUnwind; the adapter and Spoke Vault unit tests were updated.

### S-11

**Dust sends home made report() and its VAA delivery exceed the 32M block gas limit**

Severity: high. Status: Fixed. Commit: `e8c3308`.

**Sources:** AX-10 (high), XC-5 (medium).

**Fix:** sendToHub sweeps landed refunds and expired entries, then reverts HubBoundInFlightLimit at 64 listed sends (OPEN).

**Residual:** the position registry is bounded only by what the manager opens.

**Regression tests:** test_SEC_S11_* in ReportGasBrick and DustSendsReportBloat.

### S-12

**USDC blocklist of the Protocol Recipient or ManagerFeeVault froze deposits, payouts and income**

Severity: medium. Status: Fixed. Commit: `ca3c69e`.

**Sources:** AX-11, IN-3, LV-1 (medium).

**Fix:** CoreVaultLogic.payFee uses trySafeTransfer and books a failed fee in owedFees (counted in the ledger, outside every value base); claimOwedFees(token, recipient) is permissionless.

**Regression tests:** test_SEC_S12_* in FeeRecipientLiveness (2), FeeRecipientBlocklist and POC_ProtocolRecipientBlocklist.

### S-13

**Evidence-free (time-path) expiry released the Spoke Cap of a transit that arrived; pre-listed ids never re-listed**

Severity: medium. Status: Fixed. Commit: `8cda89b`.

**Sources:** AX-12, XC-4 (medium).

**Fix:** only a report's proof releases the cap; an expiry attested by time alone sets spokeCapHeld until the confirmation or the refund. Arrival ids are listed again on each credit of at least 1 USDG. This reads DEC-066 A2 conservatively; the founder should confirm.

**Regression tests:** test_SEC_S13_* in access/SpokeCapBypass (2), crosschain/SpokeCapBypass and the unit tests (3); the transit invariant counts the held caps.

### S-14

**sendToSpoke worked before the fund's Spoke Vault existed (principal lost, kept in Share Assets)**

Severity: medium. Status: Fixed. Commit: `d602e73`.

**Sources:** AX-13 (medium).

**Fix:** SpokeNotReporting until the fund's receiver has accepted a report from that spoke. The keeper must deliver the spoke's first report before the first send; all fixtures and the fork e2e now do.

**Regression tests:** test_SEC_S14_* in SendToUncreatedSpoke (2).

### S-15

**Income earned before an entrant's deposit captured just in time (permissionless forward, unwind, delivery)**

Severity: medium. Status: Open, founder decision.

**Sources:** AC-4 (medium), AX-18 (info), LV-11 (low). Question (CS-OQ-1): is income generated before an entry but collected after it shared with the entrant, or must attribution be time-weighted or snapshotted at collection? No interim mitigation without trading liveness. PoC JitIncomeCapture still passes.

### S-16

**Mints revert while the fund holds a token the immutable price source cannot price; factory accepts any hookless pool**

Severity: low. Status: Acknowledged.

**Sources:** AX-15. Fail-closed for mints; exits keep working through the price fallback. Recommended: check pool tokens against the price source at creation.

### S-17

**Payout Fee plus flow fee above 100% made every Instant Payout underflow**

Severity: low. Status: Fixed. Commit: `f6fa36e`.

**Sources:** AC-6, AX-14, LV-12. MAX_PAYOUT_FEE_BPS = 10,000 - MAX_FLOW_FEE_BPS.

**Regression test:** Mandate.t.sol test_SEC_S17_payoutFeePlusTheFlowFeeCapStaysWithinOneHundredPercent.

### S-18

**At zero Share Assets with shares outstanding every payout verb reverted ZeroSharePrice**

Severity: low. Status: Fixed. Commit: `1076573`.

**Sources:** DYN-04 (unverified), AC-7. The claim closes the request with nothing burned (closedBelowOneShare); a new request or deposit still reverts.

**Regression test:** FundSystemPoC test_SEC_S18_zeroShareAssetsClaimClosesTheRequest.

### S-19

**A matured Standard Payout Request never expires (free fee-less timing option)**

Severity: low. Status: Acknowledged.

**Sources:** AC-8. Decided rules DEC-024, DEC-060 and DEC-075; the reserve is bounded by the requester's own value (FV-OQ-1). A claim window is a founder question.

### S-20

**Hub Across callback credited the stated amount without a backing check**

Severity: low. Status: Fixed. Commit: `ee80b40`.

**Sources:** XC-7, AC-9. _requireUnledgered runs before crediting.

**Regression test:** CoreVaultTransit test_SEC_S20_hubAcrossCallbackRequiresTheTokensAboveTheLedger.

### S-21

**Buckets without exit; _collectIncome ignores IncomeAccumulator.distribute's result**

Severity: low. Status: Acknowledged.

**Sources:** AC-10, SA-04 (unverified). The skip is unreachable for real amounts (needs more than 2^128); ownerless income is LC-32 OPEN; unlisted arrivals now have the S-4 recovery.

### S-22

**Escrow balances of transits in a terminal state have no exit**

Severity: low. Status: Acknowledged.

**Sources:** XC-9 (low), LV-17 (info). Needs a stranger who paid the full amount to the spoke first, so the fund is whole. An escrow sweep is recommended hardening.

### S-23

**A lowered Across fillDeadlineBuffer would make every send, the send home included, revert**

Severity: low. Status: Fixed. Commit: `fa40104`.

**Sources:** XC-10. The fill window is min(21,600 s, fillDeadlineBuffer()); a zero buffer is refused.

**Regression test:** AcrossBridgeAdapter test_SEC_S23_fillDeadlineFollowsALoweredSpokePoolBuffer.

### S-24

**Per-spoke Wormhole chain id and 6-decimal spoke token assumptions not validated on chain**

Severity: low. Status: Acknowledged.

**Sources:** AX-16 (low), XC-13 (info). Since S-14 a wrong id only causes a self-DoS: the spoke never reports and is never funded. The complete fix is the DEC-089 registry.

### S-25

**maxReportAge per spoke is manager-chosen with no protocol bound**

Severity: low. Status: Acknowledged.

**Sources:** AX-N2. The bound is a per-supported-chain parameter (DEC-089, DEC-099) that the factory does not hold yet; recommended together with the registry.

### S-26

**No L2 sequencer-uptime check; payouts never check price age**

Severity: low. Status: Acknowledged.

**Sources:** IN-4 (low), SA-05 (info, unverified), AC-12 (info). OQ-10 stance; rule on it with Q57 (b).

### S-27

**One illiquid or paused step (Aave) blocks the whole automatic unwind**

Severity: low. Status: Acknowledged.

**Sources:** LV-5. DEC-069 and DEC-068 rule. Order exact-value steps last in the unwind order. IN-6 reported the same behaviour as a defect and was refuted.

### S-28

**Payout fallback price and hub value have no age bound**

Severity: low. Status: Acknowledged.

**Sources:** LV-6. OQ-10 payout liveness stance.

### S-29

**Spoke value not bounded by the Spoke Cap in valuation; variation band stored but unenforced**

Severity: low. Status: Acknowledged.

**Sources:** LV-7. DEC-086 and DEC-093 trust the guardian quorum; Q57 (d) OPEN.

### S-30

**256 USDG fills the arrival window for good (report path of attestExpiry off; 21.7 KB reports)**

Severity: low. Status: Acknowledged.

**Sources:** LV-9 (low), XC-11 (info). Documented OQ-09 cost; 13.25M gas on the first full delivery, under the 32M limit.

### S-31

**Report lifetime equals worst-case finality; any delay above about 26.5 min closes mints**

Severity: low. Status: Acknowledged.

**Sources:** LV-10 (low), XC-12 (info). DEC-099 and the 2026-09-29 ruling; payouts are unaffected.

### S-32

**On the live thin Arbitrum pool a close-type unwind above about 35 WETH cannot meet the 5% floor**

Severity: low. Status: Acknowledged.

**Sources:** IN-N1. Within DEC-068 and DEC-069 (paid from Idle, request stays open). Keep hub positions small against pool depth; unwinding in slices is future work.

### S-33

**Chainlink min/maxAnswer clamp not detected**

Severity: info. Status: Acknowledged.

**Sources:** IN-5 (downgraded). The live ETH/USD aggregator has minAnswer 1, so the clamp cannot bind; check any future feed.

### S-34

**Aave best-effort income bound reads balanceOf(aToken), not the virtual balance**

Severity: info. Status: Acknowledged.

**Sources:** IN-7. Income only, best effort.

### S-35

**USDG priced 1:1 puts a depeg straight into the Share Price and the Spoke Cap**

Severity: info. Status: Acknowledged.

**Sources:** IN-8. Founder ruling 2026-09-29 (Q57 b, QB9).

### S-36

**No hub-driven spoke unwind; a dead or compromised manager key traps spoke capital**

Severity: info. Status: Acknowledged.

**Sources:** AX-17, LV-15. MVP scope (feedback q2).

### S-37

**CREATE3 proxies stay callable; library wiring immutables informational**

Severity: info. Status: Acknowledged.

**Sources:** AX-19. No derived address is reachable; operator trust.

### S-38

**A Standard reserve stays locked if its requester never claims**

Severity: info. Status: Acknowledged.

**Sources:** LV-13. Bounded by the requester's own value; DEC-024.

### S-39

**Passive patient actor quantified: unprofitable under live Chainlink pricing**

Severity: info. Status: Acknowledged.

**Sources:** LV-14. The active variant was S-1.

### S-40

**buildReport walks every position on every deposit and claim (gas)**

Severity: info. Status: Acknowledged.

**Sources:** LV-16. Gas only.

### S-41

**Carried index remainder can tip an entrant by one base unit**

Severity: info. Status: Acknowledged.

**Sources:** DYN-05 (unverified). Dust; conservation holds.

### S-42

**Deposit flow fee charged on the amount offered**

Severity: info. Status: Acknowledged.

**Sources:** AC-11. OQ-05 and OQ-06 stance.

### S-43

**Areas verified without a finding; dead IncomeAccumulator source-counter code**

Severity: info. Status: Acknowledged.

**Sources:** AC-13. Assurance note.

### S-44

**Hygiene: unused _spoke, shadowed named return, initializer without event, uncached array length, constant-style names**

Severity: info. Status: Acknowledged.

**Sources:** SA-06 (unverified). No behaviour affected.

### IN-6

**an illiquid or paused Aave step reverts the whole automatic unwind (reported as a defect)**

Severity: none. Status: Refuted.

Refuted by the integrations verifier: this is the decided rule (DEC-069: an illiquid position is waited on, not skipped; DEC-068: pay what is possible). CoreVault catches the revert and makes a Partial Payout. The rule's risk is kept as S-27.

## Final independent verification (after the fixes)

A verifier that had not taken part in the fixes re-read every fix commit, re-attacked it with variants, re-ran the
suites (unit and invariants with a fresh fuzz seed, the whole-fund invariants with late refunds enabled, two fork
runs at fresh pins, Slither diffed against the pre-fix baseline) and added two pinning tests (`5c33042`,
`0dbaa59`). None of the 16 fixes could be broken. What it left on record:

| Item | Severity | Where | Statement |
|---|---|---|---|
| S-8 open | high | `SpokeVault.swapExactInput`, `swapCollectedIncome` | A compromised or buggy manager key moves the Unallocated Balance out in one sandwiched swap at a self-set price; `test_POC_managerSwapsUnallocatedBalanceAtAPriceItSet` still passes (891,000 of 900,000 USDC leave in one call on the fixture). Not defensible for real customer funds with autonomous managers; needs the founder's ruling ([`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md)) |
| S-2 residual | medium | `SpokeVault._unwindSwap` | Inside the 5% floor a claimant still makes the fund sell under the external price: on the S-2 fixture 25.8 WETH sold for 61,736 USDC against 64,490 fair, the holder who stays loses 1,887 USDC, the claimant gains 1,352 USDC over an honest claim; repeatable with Standard Payouts (no Payout Fee). Pinned by `5c33042` |
| S-15 open | medium | `SpokeVault.forwardIncomeToCoreVault` | Just-in-time capture pays whenever uncollected income exceeds about 0.5% of Share Assets (two flow fees). Defensible only with an operational rule of frequent collection |
| S-5 interim | medium | `CoreVaultBase.setOperatingCashParameters` | A mis-set floor freezes Share Assets at about 0 until the same manager key calls `releaseOperatingCash`; nothing lets anyone take Operating Cash. Defensible as an interim, not as a final state |
| S-4 kind | low | `CoreVaultLogic.recoverUnlistedArrival` | An unlisted arrival's kind is unknowable (the Across message is unauthenticated), so an Income send home recovered after an outage longer than `HUB_BOUND_RETENTION` enters Idle as Principal: no performance fee, no protocol slice, no accumulator. Pinned by `0dbaa59`; needs a multi-day report outage |
| S-26 / S-28 | low | `CoreVaultLogic` PAYOUT mode | A payout never checks price age or sequencer uptime (OQ-10 stance): during an outage claimants are paid at the old price. Unforceable by an attacker; needs an explicit founder acceptance against Q57 (b) |
| S-17 | info | `Mandate.MAX_PAYOUT_FEE_BPS` | 9,900 is an arithmetic bound only; a 99% Payout Fee is a valid, immutable, visible Mandate value (disclosure) |
| S-11 with S-3 | info | `SpokeVaultTypes.MAX_HUB_BOUND_IN_FLIGHT` | Sends home are rate-limited to 64 per about 3.25 days (every send stays listed until its refund or `fillDeadline` + 3 days); the keeper and manager runbooks must know |
| S-10 | info | `UniswapV4Adapter.swapExactInput` | A compiler shadowing warning introduced by the fix; removed on main by `8e97994` |
| local-e2e | info | `local-e2e/` | ABIs regenerated; the harness delivers a spoke report before the first `sendToSpoke` and quotes without exclusivity; its bucket sum follows the S-1 valuation (`64c6461`) |
| S-1 corner | info | `CoreVaultLogic._oracleComposition` | In the PAYOUT fallback a token that never priced (CS-OQ-4) keeps its position at the spot composition for the USDC leg while the other leg is valued at 0; only reachable for a fund whose mints never worked |

## Cross-check of 2026-10-01 (independent review and verification plan)

The independent review and the verification plan of 2026-09-30 were cross-checked against the code
([`CROSS-CHECK-2026-10-01.md`](CROSS-CHECK-2026-10-01.md)). New entries continue the numbering; ids in brackets are the
review's (C, H, M, L, I) or the plan's (CF, T, F, MM, SF). Commits are on `fix/pp-sc-fix-independent-review`.

| Id | Severity | Status | Title | Sources | Evidence |
|---|---|---|---|---|---|
| S-45 | high | Fixed | The S-4 recovery could be started early with dust under a predictable id, or after a report outage, while the latest report still counted the transfer on the spoke: Idle and that report counted it twice (a claimant was paid 49,850 USDC too much on a 1M fund; an Income send home skipped the fee split) | found while porting H-02 | `231a049`; `test_REVIEW_NEW_S04_*` (3), the S-4 regressions updated |
| S-46 | high | Fixed | Open positions were unbounded: about 180 dust positions made every report undeliverable within 32M gas, closing mints and freezing the hub's view of the spoke | [H-04], plan T3; S-11 residual | `5ce0bd2`, `d726ed3` (`MAX_OPEN_POSITIONS` = 16, OPEN); worst report under the caps 26.87M gas through the real Wormhole Cores (30.28M at 32) |
| S-47 | medium | Fixed in part | A Mandate pool's LP fee was unbounded: in a 100% pool one swap turned principal into income and the fees on it | [M-02] | `25ee3e5` (`MAX_POOL_FEE` = 1%); gross versus net is SEC-OQ-7 |
| S-48 | medium | Fixed | An income token that refused the holder reverted a full-burn claim and with it the exit of the principal | [CF-2], [L-02] | `5f4ed15`; `test_REVIEW_CF2_*` |
| S-49 | medium | Fixed | A single-asset non-USDC position in the unwind order reverted every automatic unwind that reached it, even with a route hint | [T14], [L-05] | `30b896d`; `test_REVIEW_T14_*` (2), `test_REVIEW_L05_singleAssetWethStepUnwindsThroughTheHintedRoute` |
| S-50 | medium | Fixed | With foreign aTokens in the Aave adapter, the income step of a fallback full exit over-burned one scaled unit and reverted the whole exit | [F1], [L-08] | `02e48f3`; `test_REVIEW_F1_*` (2) |
| S-51 | medium | Fixed | The price source took any positive answer (2^200 later panicked every payout) and assumed fixed feed decimals | [CF-R2], [CF-R3] | `610636a` (`MAX_PRICE` = 2^128, decimals checked per read, future rounds refused) |
| S-52 | medium | Fixed | Below one base unit per whole share, one-unit deposits minted whole shares for nothing and compounded to the supply | [MM-3], plan R-13 | `fd333b6` (`SharePriceBelowOneUnit`) |
| S-53 | medium | Fixed in part | A Mandate token the price source cannot price closed mints and was worth 0 in payouts; hub tokens are now refused at creation | [M-03], plan R-12; supersedes S-16 for the hub | `aa85f42`; spoke tokens are SEC-OQ-9 (`test_POC_REVIEW_M03_*` pin) |
| S-54 | low | Fixed | A spoke's report lifetime had no upper bound (mints on reports 136 years old; recovery out of reach) | [M-04]; S-25 | `6522d80` (`MAX_REPORT_AGE` = 1 day); the lower bound needs the DEC-089 registry |
| S-55 | low | Fixed | The Spoke Vault booked a built fill deadline without checking it is in the future | [L-09] | `76fdd62` |
| S-56 | low | Fixed | Deployment accepted a codeless registry or price source and Uniswap V4 contracts of different deployments | [SF-1], [CF-V4-10], plan F-12 | `c9dbbf8` (script only) |
| S-57 | low | Fixed | CI had never passed: an unpinned forge failed `fmt --check` and the fork suites could not start | review process findings | `9375158` |
| S-58 | low | Acknowledged | A large Mandate pushes `createFund` above 32M gas and then above EIP-3860 | [L-10], [FF-4] | `test_POC_REVIEW_L10_*` |
| S-59 | low | Acknowledged | `buildReport` readable while a hub verb is half done (read-only reentrancy), unreachable with USDC, WETH and hookless pools | [L-06] | review report 04 |
| S-60 | low | Acknowledged | A transfer fee switched on by an issuer after positions exist blocks every exit of that pool (fails closed) | [CF-V4-11] | plan card 05 |
| S-61 | low | Acknowledged | Aave answering outside its published behaviour (short `withdraw(max)`, zero scaled balance, payment reported but not made, falling index) | [F2], [F9], [F10], [F11] | plan card 06; the vault's backing checks fail closed |
| S-62 | info | Open | A successful but wrong price answer below `MAX_PRICE` is taken as is | [CF-12] | SEC-OQ-10 |

Status updates of earlier entries: S-4 is corrected by S-45; S-11's residual (positions) is closed by S-46; S-16 is
superseded by S-53 (hub) and SEC-OQ-9 (spoke); S-25 is closed by S-54 for the upper bound; S-27's single-asset case
is closed by S-49 (the roll-back of a failing step stays, DEC-069); S-34's exit blocking is closed by S-50; L-04's gas
starvation of the wrapped hub read needs a `buildReport` above about 9.6M gas, which the 16-position cap rules out.

