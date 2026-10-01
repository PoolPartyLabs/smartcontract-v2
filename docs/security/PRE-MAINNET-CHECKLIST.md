# Pre-mainnet checklist

The gate between the buildathon MVP and any deployment that holds real value. Every box is a hard requirement
unless marked "recommended". The state on 2026-09-30 is noted where it is known.

## A. Decisions

- [ ] S-8 ruled and implemented: manager swaps bounded against a price the manager does not control
      ([`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md) §1). **Blocking**: a compromised or buggy manager key can move
      the Unallocated Balance out today.
- [ ] S-15 ruled (CS-OQ-1): income attribution across an entry, either a contract rule or a written operational rule
      with the keeper cadence that enforces it.
- [ ] S-5 ruled: a protocol cap on the Operating Cash floor and top-up, or an explicit acceptance of the interim
      `releaseOperatingCash` path.
- [ ] S-13 reading of DEC-066 A2 confirmed (a time-attested expiry keeps the Spoke Cap held until the refund or
      the confirmation).
- [ ] The OPEN parameters introduced by the sweep and its cross-check given values by ruling and recorded as DEC
      entries ([`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md) §3, OPEN-QUESTIONS SEC-OQ-5): `HUB_BOUND_RETENTION`,
      `MAX_HUB_BOUND_IN_FLIGHT`, `MAX_OPEN_POSITIONS`, `MAX_BRIDGE_FEE_BPS`, `MAX_PAYOUT_FEE_BPS`,
      `MAX_UNWIND_SLIPPAGE_BPS` (SEC-OQ-12), `MAX_POOL_FEE`, `MandateLib.MAX_REPORT_AGE`, `MAX_PRICE`.
- [ ] The independent review's open questions ruled (OPEN-QUESTIONS SEC-OQ-7 to SEC-OQ-14): performance fee net of the
      fund's own swap fees, the guardian's holder, spoke pool tokens in the Mandate, price bands, Mandate exit bounds,
      the unwind band, the ETH / USD price age, a second bridge route.
- [ ] S-26 / S-28 accepted explicitly against Q57 (b) / OQ-10 (payouts without a price-age or sequencer check), or
      a sequencer-uptime feed added to the price source.
- [ ] Pricing of every token a Mandate may hold decided (ARCHITECTURE §5 is OPEN): only WETH (Chainlink) and USDG
      (1:1) are priced today; a token without a price stops mints (S-16).
- [ ] The DEC-089 supported-chain registry designed (spoke token, Wormhole chain id, `maxReportAge` bound per
      chain; S-7, S-16, S-24, S-25).
- [ ] The report lifetime (1,588 s, ruling 2026-09-29) re-checked against observed Arbitrum finality (S-31).

## B. Independent review

- [ ] An external audit of `src/` at the release commit by a firm with Uniswap V4, Across and Wormhole
      experience, scoped with [`THREAT-MODEL.md`](THREAT-MODEL.md) and [`FINDINGS.md`](FINDINGS.md) as input. The
      independent model-driven review of 2026-09-30 ([`independent-review-2026-09-30/`](independent-review-2026-09-30/))
      does not replace it.
- [ ] The verification plan's scope decided (F-1, F-2, F-14 in [`VERIFICATION-PLAN.md`](VERIFICATION-PLAN.md)):
      the plan's own lean order is rulings, one fix batch, an external audit, then formal phases on the audited code.
- [ ] Every audit finding fixed or accepted in writing, with regression tests in the `test_SEC_*` pattern.
- [ ] Recommended: a public bug bounty with a defined disclosure contact ([`SECURITY.md`](../../SECURITY.md)
      still has a placeholder).

## C. Code and tests

- [x] Contract sizes under EIP-170 with margin recorded (`SpokeVault` 559 bytes to spare; any change to it must
      re-check).
- [x] Non-fork suite, fork suite, the ported review proofs of concept, the local two-fork harness and the API probe
      green on the cross-check branch (2026-10-01; numbers in [`CROSS-CHECK-2026-10-01.md`](CROSS-CHECK-2026-10-01.md)).
- [x] CI green on `main` (it had never passed before 2026-10-01: an unpinned forge and unset fork blocks).
- [ ] Coverage measured on the release commit and a per-file ratchet in CI (the review measured 97.31% lines and
      83.67% branches at `e5c778a`; the verification plan lists 81 zero-hit branches).
- [ ] Static-analysis ratchets in CI (Slither, Aderyn, Solhint against the committed triage), per the verification
      plan section 7.
- [ ] Deep campaign re-run on the release commit ([`TOOLING.md`](TOOLING.md): 5,000 fuzz runs x 3 seeds,
      invariants 256 x 64, both liveness switches).
- [ ] Slither diff against `reports/raw/slither.json` triaged; Aderyn, Semgrep, Solhint counts compared.
- [ ] Halmos re-run if `ShareMath`, `IncomeAccumulator`, `ReportCodec` or `TransitMessage` changed; mutation
      re-run for the two libraries.
- [ ] No `test_POC_*` left passing for a finding above low severity.
- [ ] `forge fmt --check` clean, no compiler warnings in `src/`.

## D. Deployment

- [ ] The factory deployed through `script/DeployFactory.s.sol` on a fork of each target chain first, addresses
      predicted and matched (`predictAddresses`), then on mainnet with the same salts
      ([`../DEPLOYMENT.md`](../DEPLOYMENT.md)).
- [ ] Protocol wiring verified on chain: Wormhole Core, Across SpokePool, Aave Pool, V4 PoolManager and
      PositionManager, Chainlink aggregator, protocol recipient, price source, per chain
      ([`../INTEGRATIONS.md`](../INTEGRATIONS.md)).
- [ ] Across `fillDeadlineBuffer` and `depositQuoteTimeBuffer` read on both chains and recorded (S-23).
- [ ] Wormhole chain ids and emitter addresses of every spoke recorded and cross-checked with the Mandate
      (S-24).
- [ ] Keys: the adapter guardian, the Manager Registry owner and the factory deployer on hardware or a multisig,
      with a written procedure for `setPaused`, `deprecate` and the registry's `Ownable2Step` transfer. The guardian is
      one immutable address for every adapter of every fund of a factory (SEC-OQ-8).
- [x] The deployment script refuses a wiring with a codeless address or Uniswap V4 contracts of different
      deployments (`FactoryDeployment._checkWiring`, plan F-12).
- [ ] Source verified on the block explorers of both chains; linked library addresses published.
- [ ] Linked libraries (`CoreVaultLogic`, `SpokeCrossChainLib`) deployed once per chain and their addresses
      pinned in the factory wiring (ARCHITECTURE §1.1).

## E. Operations

- [ ] A production keeper (not `local-e2e/`) that: calls `report()` on every spoke within the report lifetime and
      delivers the VAA; delivers a new spoke's first report before the first `sendToSpoke` (S-14); calls
      `recognizeRefund`, `attestExpiry`, `recoverUnlistedArrival`, `claimOwedFees`, `forwardIncomeToCoreVault`
      when their conditions hold (`recoverUnlistedArrival` right after delivering the first report built after an
      unlisted arrival, so no entrant prices in between); collects and forwards income on the cadence the S-15 rule
      requires; quotes Across without exclusivity (S-9); computes every manager swap minimum from the oracle (S-8
      open; `local-e2e/src/api.ts` shows how).
- [ ] Monitoring and alerts on: report age per spoke, transits past their fill deadline, `unmatchedArrivals`,
      `owedFees`, Operating Cash above its floor, Share Price moves above a threshold within one block,
      Chainlink staleness and sequencer status.
- [ ] A manager runbook with the S-11 rate limit (64 sends home per about 3.25 days), the deprecation semantics
      (S-10), and the Payout Fee and bridge fee bounds.
- [ ] An incident procedure: who pauses which adapter, how Shareholders exit when an adapter is deprecated
      (exits and swaps into the base token keep working), how a stuck transit is recovered.
- [ ] Recommended: a canary fund with protocol-owned capital run for several report lifetimes, several sends in
      each direction, one Instant Payout with an unwind and one deprecation drill before customer funds.

## F. Disclosure

- [ ] `SECURITY.md` contact defined and reachable.
- [ ] Shareholder-facing disclosure of the Mandate's immutable fees and of the accepted rules (S-17, S-19, S-26,
      S-35).
- [ ] This directory updated to the release commit: [`README.md`](README.md) numbers, [`FINDINGS.md`](FINDINGS.md)
      statuses, [`TOOLING.md`](TOOLING.md) results.
