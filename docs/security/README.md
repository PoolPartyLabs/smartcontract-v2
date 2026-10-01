# Security sweep of the Pool Party v2 MVP (2026-09-30)

This directory documents the internal security review of `src/` and how to reproduce it. **It is not an audit.**
The contracts have not been reviewed by an independent third party; see [`SECURITY.md`](../../SECURITY.md).

## What was reviewed

Main at commit `e5c778a` (the buildathon MVP before the sweep: Core Vault with its linked `CoreVaultLogic`,
Spoke Vault with its linked `SpokeCrossChainLib`, Mandate, Share token, Fund Factory with CREATE3 addresses,
Manager Registry and Manager Fee Vault, Value Report Receiver, Chainlink price source, Uniswap V4, Aave V3 and
Across adapters, Transit Escrow). The fixes landed on `fix/pp-sc-fix-security-sweep`, merged into main at
`28551af`.

## Method

The sweep ran as one workflow of agents, each in its own git worktree and branch, with every result verified by a
second, independent agent before it was accepted. Findings carry the id of the lens that raised them; the
consolidated register renumbers them `S-n` ([`FINDINGS.md`](FINDINGS.md)).

| Lens | Id prefix | Branch | What it did |
|---|---|---|---|
| Static analysis | `SA` | `docs/pp-sc-docs-sec-static` | Slither, Aderyn, Semgrep (two rule sets), Solhint, Mythril on four small contracts; every high, medium and low result read against the code. Report: [`reports/static-analysis.md`](reports/static-analysis.md) |
| Dynamic and symbolic | `DYN` | `test/pp-sc-test-sec-dynamic` | Deep fuzz and invariant campaigns (three seeds), new whole-fund stateful invariant suites, Halmos on the libraries and codecs, Medusa, slither-mutate with kill tests. Report: [`reports/dynamic-analysis.md`](reports/dynamic-analysis.md) |
| Access control and privilege | `AX` | `test/pp-sc-test-sec-access` | Every verb's caller, what a manager, guardian, registry owner or stranger can do to the value bases |
| Accounting | `AC` | `test/pp-sc-test-sec-accounting` | Share Price, buckets, income attribution, rounding, fee arithmetic |
| Cross-chain | `XC` | `test/pp-sc-test-sec-crosschain` | Transit state machine, Across arrivals and refunds, Wormhole reports, Spoke Cap |
| Integrations | `IN` | `test/pp-sc-test-sec-integrations` | Uniswap V4, Aave V3, Across, Chainlink assumptions, on mainnet forks |
| Liveness | `LV` | `test/pp-sc-test-sec-liveness` | Griefing, stuck value, gas limits, dependencies that stop a fund |

Every manual lens wrote its findings as proof-of-concept Foundry tests (`test_POC_*`) that pass against the
vulnerable code. The fix phase converted each PoC of a fixed finding into a regression test (`test_SEC_S<n>_*`)
that asserts the attack now fails. The PoCs of the three items waiting for a decision still pass, as pins.

Verification rules that applied to every lens: a finding needs a concrete input and a concrete wrong outcome; a
verifier that could not reproduce it downgraded or refuted it (one refutation is kept in the register, `IN-6`);
severity follows one rubric (critical: unbounded loss of customer value; high: bounded loss or a freeze of value
that needs a privileged key to undo; medium: loss bounded by a fee or a small fraction, or a freeze undone by a
permissionless verb; low: needs an unlikely precondition or costs more than it yields; info: hygiene, gas,
disclosure).

## Numbers

- 44 findings: 1 critical, 10 high, 4 medium, 17 low, 12 info; plus 1 refuted. 16 fixed, 3 waiting for a founder
  decision (S-5, S-8, S-15), 25 acknowledged with their reason.
- Regression tests on main: 54 `test_SEC_S<n>_*` tests, 11 `test_POC_*` pins of the three open items, 9 stateful
  invariants, 31 Halmos properties (20 proved, 11 without a counterexample within the solver budget).
- Suite on main after the merge: 750 non-fork tests (unit, fuzz, invariants, security), 57 fork tests, the local
  two-fork harness (35 steps, 213 assertions). Contract sizes under EIP-170 (`SpokeVault` 24,017 bytes, 559 to
  spare).
- Slither after the fixes: 191 results, all triaged as false positives or accepted patterns; no true positive left
  ([`TOOLING.md`](TOOLING.md)).

Cross-check of 2026-10-01 against an independent review and a verification plan
([`CROSS-CHECK-2026-10-01.md`](CROSS-CHECK-2026-10-01.md)): 20 more entries (S-45 to S-64), among them two regressions
of the sweep's own fixes (S-45 in the S-4 recovery, S-63 in the S-5 interim verb, both high, both fixed), 13 more
fixed (two in part); the suites now count 854 non-fork tests and 136 fork tests, the review's 121 proofs of concept included.

## How to read the rest

- [`THREAT-MODEL.md`](THREAT-MODEL.md): who can do what, which assumptions the design rests on.
- [`FINDINGS.md`](FINDINGS.md): the register, one entry per finding with sources, fix commit and tests.
- [`INVARIANTS.md`](INVARIANTS.md): the properties the suites hold, with the decision each one encodes.
- [`TOOLING.md`](TOOLING.md): how to re-run each tool with the resource limits that fit a laptop.
- [`KNOWN-LIMITATIONS.md`](KNOWN-LIMITATIONS.md): what is still open and what an operator must know.
- [`PRE-MAINNET-CHECKLIST.md`](PRE-MAINNET-CHECKLIST.md): the gate before real value.
- [`reports/`](reports/): the two analysis snapshots written at `e5c778a`, before the fixes, and the raw tool
  outputs. They describe the pre-fix behaviour and cite PoC test names that were renamed by the fix phase; the
  register maps them.

## Conventions

Everything in this directory is in English and cites decisions by id (`DEC-nnn`, from the specification repository)
and findings by id (`S-n`). NatSpec in `src/` cites the finding a rule comes from (`security review S-n`).
