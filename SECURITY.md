# Security

## Status

**These contracts have not been audited by an independent third party.** Nothing is deployed to production. The
code is a buildathon MVP under active development; do not put real value into any deployment of it until the
[pre-mainnet checklist](docs/security/PRE-MAINNET-CHECKLIST.md) is complete.

What has been done, as of 2026-10-01:

- One internal security sweep of `src/` (static analysis, fuzzing, invariants, symbolic execution, mutation testing
  and five manual review lenses), with every finding verified by an independent reviewer and the fixes
  re-verified. Method and numbers: [`docs/security/README.md`](docs/security/README.md).
- 44 findings registered, 16 fixed with regression tests, 3 waiting for a founder decision, 25 acknowledged with
  their reasoning: [`docs/security/FINDINGS.md`](docs/security/FINDINGS.md).
- An independent model-driven review (2026-09-30, 121 proofs of concept) and a test and formal verification plan were
  cross-checked against the code on 2026-10-01: every proof of concept now runs in `test/review/`, two regressions of
  the sweep's own fixes were found and fixed (S-45 in the S-4 recovery; S-63, the interim Operating Cash release verb,
  removed because it let a manager and an ally extract the fund), and thirteen further items were fixed
  ([`docs/security/CROSS-CHECK-2026-10-01.md`](docs/security/CROSS-CHECK-2026-10-01.md)).
- The open items and residual risks a deployer must know: [`docs/security/KNOWN-LIMITATIONS.md`](docs/security/KNOWN-LIMITATIONS.md).

## Reporting a vulnerability

Do not open a public issue for a vulnerability.

Contact: **to be defined by Pool Party Labs before any mainnet deployment** (a security mailbox or a bug bounty
program). Until then, report privately to the repository maintainers through GitHub's private vulnerability
reporting on `PoolPartyLabs/smartcontract-v2`, if enabled, or to a maintainer directly.

Please include the affected contract and function, the chain and commit, a description of the impact and, when
possible, a proof of concept as a Foundry test (the repository's `test/security/` suites show the pattern).

## Scope

In scope: every contract under `src/`, deployed through `script/DeployFactory.s.sol` and `script/CreateFund.s.sol`.

Out of scope: the external protocols the funds integrate with (Uniswap V4, Aave V3, Across, Wormhole, Chainlink),
the off-chain keeper in `local-e2e/` (a development harness, not a production component), and the test mocks.

## Security documentation

| Document | Content |
|---|---|
| [`docs/security/README.md`](docs/security/README.md) | The sweep: method, lenses, tools, numbers, how to read the rest |
| [`docs/security/THREAT-MODEL.md`](docs/security/THREAT-MODEL.md) | Actors, trust assumptions, assets, attack surfaces |
| [`docs/security/FINDINGS.md`](docs/security/FINDINGS.md) | Register S-1 to S-64, the refuted item, the final verification, the cross-check of 2026-10-01 |
| [`docs/security/INVARIANTS.md`](docs/security/INVARIANTS.md) | Properties the suites hold, and where each is checked |
| [`docs/security/TOOLING.md`](docs/security/TOOLING.md) | Tools, versions, commands, resource limits, how to re-run |
| [`docs/security/KNOWN-LIMITATIONS.md`](docs/security/KNOWN-LIMITATIONS.md) | Open decisions, residual risks, operational constraints |
| [`docs/security/PRE-MAINNET-CHECKLIST.md`](docs/security/PRE-MAINNET-CHECKLIST.md) | What must happen before real value |
| [`docs/security/reports/`](docs/security/reports/) | Raw tool outputs and the two pre-fix analysis snapshots |
| [`docs/security/CROSS-CHECK-2026-10-01.md`](docs/security/CROSS-CHECK-2026-10-01.md) | Every finding of the independent review and the verification plan against the current code |
| [`docs/security/VERIFICATION-PLAN.md`](docs/security/VERIFICATION-PLAN.md) | The test and formal verification plan: tiers, tools, what has happened, the founder's decisions |
| [`docs/security/independent-review-2026-09-30/`](docs/security/independent-review-2026-09-30/), [`docs/security/verification-plan-2026-09-30/`](docs/security/verification-plan-2026-09-30/) | The two documents as delivered (snapshots at `e5c778a`) |
