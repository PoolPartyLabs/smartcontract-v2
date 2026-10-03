# Pool Party v2 smart contracts

On-chain funds run by a manager, human or AI agent, inside a Mandate fixed at creation. Investors deposit and
withdraw USDC on one chain (the Hub Chain) while the fund's capital works on several chains (Spoke Chains).

This repository holds the Solidity implementation. **Everything here is in English.** The product definition,
decision register and research live in the separate specification repository (`PoolParty_SCs_v2`, in
Portuguese); its decisions (DEC-001 to DEC-187, later decisions override earlier ones) are the business rules
this code must follow. `docs/DECISIONS.md` is the English digest of that register and `docs/OPEN-QUESTIONS.md`
lists answered questions, remaining gaps and implementation divergences. DEC-186/187 are Slack-only decisions
recorded in the handoff; management cap is 500 bps (5%), manager pays own gas in the MVP.

## Status

Buildathon MVP, **internal-alpha code baseline `main` at `f88b25b` (2026-10-03)**. WP-09 proportional Hub
unwind and WP-10 live income dollar index landed via PR #23 (#19/#18); WP-12 spoke orders and WP-13 closure
landed via PR #21 (including #22). PR #20 prepares/checks dual-chain deployment, not a production broadcast.
No public-readiness claim: [founder MVP report](docs/reports/2026-10-03-MVP-REPORT.md) contains fresh tests,
sizes, gas, reviews and release inputs. Final end-to-end transaction evidence awaits PR #24.

## Scope of the buildathon MVP

| In scope now | Next | Not planned for now |
|---|---|---|
| Arbitrum One Hub, Robinhood Chain spoke; Across USDC/USDG | More spokes and CCTP routes | Borrowing, leverage, perps |
| Uniswap V4 positions; Aave V3 supply-only on Arbitrum | External reward collectors | Share transfers between owners |
| Mandate swap adapter: direct V3 discovery or signed split/multihop | V4/mixed API routes | V3 position adapter |
| Finalized report v4; UNWIND, CLOSE, COLLECT, ACKNOWLEDGE orders | Multi-spoke report scheduling | ZK proofs of value |
| Deposit, allocate, report, proportional Hub/spoke payouts, USDC Income Withdrawal | Entry-time filter, signed bridge quotes | Auto-compounding |
| Irreversible closure, final management payment and frozen Closed exits | Native Operating Cash, refunds, gas top-up | Solana / CCTP on Robinhood |

Core Vault directly links six libraries, Spoke Vault four; nested links are immutable and deployed dependency-first
(DEC-131). Performance fee is 10–90%; management 0–5%, accrued while Open and paid at finalization;
Instant Payout Fee <=10% stays in Idle. Standard sale Market Costs are fund-absorbed up to 1% per sale, excess
belongs to the leaver; closure excess belongs to the manager. Across fixes send terms (1% rate cap plus fixed fee),
no signed bridge quote in MVP (DEC-176). Standard Payout Wormhole fees are caller-funded for now.
A silent spoke blocks exits needing a fresh report (DEC-157/160); the keeper must deliver Hub acknowledgements
to reclaim spoke send capacity (anyone may republish/deliver). Native Operating Cash/refunds/DEC-185 gas top-up
are deferred by ruling 2026-10-02; creation defaults 0 are not enforcement. DEC-145 entry-time filter remains deferred.

## Layout

```
src/
  core/        Core Vault (hub books: shares, idle, payouts), Share token, Manager Fee Vault
  factory/     Fund Factory, CREATE3 library, creation code stores, the factory's one-address deployer
  spoke/       Spoke Vault (the fund's account on every chain, hub included), internal ledger
  report/      Value report encoding, Wormhole publisher (spoke) and receiver (hub)
  adapters/    IAdapter, IBridgeAdapter, Uniswap V4 adapter, Aave V3 adapter, Across bridge adapter
  mandate/     Mandate struct, validation and immutability rules
  libraries/   Shared math (whole-share rounding, USDC truncation, income accumulator)
  interfaces/  External protocol interfaces not shipped by a dependency (Across)
test/
  unit/        Pure unit and fuzz tests, no network (invariant suites next to their contract)
  security/    Regression tests of the security findings, whole-fund invariants, symbolic and mutation suites
  review/      The independent review's proofs of concept, ported: regressions of what is fixed, pins of what is not
  fork/        Mainnet fork tests against Arbitrum One and Robinhood Chain (never testnets)
script/        Deployment scripts (fork first, then mainnet)
docs/          DECISIONS.md, OPEN-QUESTIONS.md, ARCHITECTURE.md, INTEGRATIONS.md, DEPLOYMENT.md
  security/    Threat model, findings register, invariants, tooling, known limitations, pre-mainnet checklist
```

## Toolchain

- Foundry (forge 1.7+), Solidity 0.8.28, EVM `cancun`.
- OpenZeppelin Contracts 5.7 for ERC-20, access control, reentrancy guards, SafeERC20, math.
- Uniswap `v4-core` and `v4-periphery` (interfaces, types and libraries; the pinned-pragma contracts are never
  compiled, the deployed ones are used on forks). `v3-core`/`v3-periphery` stay only for the toolchain smoke test.
- `wormhole-solidity-sdk` for Core Bridge interfaces, VAA parsing, replay protection and the
  `WormholeOverride` fork-test helper that signs VAAs with a guardian set the test controls.
- Across and Aave V3: minimal interfaces vendored in `src/interfaces/external/` (both upstream repos are Hardhat
  monorepos).

## Getting started

```bash
cp .env.example .env            # public RPCs work; a provider key is recommended for fork suites
forge build
forge build --sizes
forge test --match-path test/size/ContractSizes.t.sol -vv
forge test --no-match-path "test/{fork/**,review/**/*Fork*}"
forge test --match-path "test/{fork/**,review/**/*Fork*}" -j 4
forge fmt --check
```

Fork tests read `ARBITRUM_RPC_URL` and `ROBINHOOD_RPC_URL`. Use archive endpoints and pin
`ARBITRUM_FORK_BLOCK` / `ROBINHOOD_FORK_BLOCK`; never log credentials. In the handoff environment source its
`tools/rpc-env.sh` in the same shell before any fork command or harness startup.

## Local two-fork environment (`local-e2e/`)

For API and frontend development against real transactions: two long-lived anvil forks (Arbitrum One on port 8545,
Robinhood Chain on port 8546) with the protocol deployed by `script/DeployFactory.s.sol` and `script/CreateFund.s.sol`,
a keeper that fills Across deposits through the live SpokePools and delivers Wormhole VAAs signed by a local guardian,
time warps on both clocks, committed ABIs, and an end-to-end scenario over JSON-RPC.

```bash
cd local-e2e && pnpm install
pnpm run up          # fork, deploy, fund the actors, warm the fork caches
pnpm keeper          # another terminal
pnpm scenario        # the fork e2e phases over JSON-RPC
pnpm down
```

See `local-e2e/README.md` for what is real and what is simulated, the actors and keys, the state file and
troubleshooting (public RPCs serve fork state for minutes only; an archive RPC is recommended for long sessions).

## Security

**Not audited by a third party.** One internal security sweep (static, dynamic, symbolic, mutation and five manual
lenses) ran on 2026-09-30: 44 findings, 16 fixed with regression tests, 3 waiting for a founder decision, 25
acknowledged. An independent model-driven review and a verification plan (2026-09-30) were cross-checked against the
code on 2026-10-01 (`docs/security/CROSS-CHECK-2026-10-01.md`; their proofs of concept run in `test/review/`).
Historical sweep counts are not current release certification: S-8 is accepted by DEC-129; S-5's native cap and
S-15's entry-time residual remain deferred despite implemented recognition cohorts.
Fresh baseline: **1,432 non-fork tests / 183 suites; 222 fork tests / 56 suites; 3/3 size tests**
(size suite included in non-fork total). Every production runtime fits 24,576 B; tightest SpokeUnwindLib is
**23,473 B / 1,103 B margin**. Fresh complete sizes, per-suite counts and gas are in
`docs/reports/2026-10-03-MVP-REPORT.md`; `docs/security/BASELINE-2026-10-02.md` is historical only. The
Mandate fixes where a manager may trade and where tokens may go, not the price of a manager's trade
(`docs/security/THREAT-MODEL.md`). Read `SECURITY.md` for the disclosure policy and `docs/security/` for the threat
model, the register, the invariants, the tooling and the pre-mainnet checklist.

## Canonical vocabulary

Identifiers, NatSpec and docs use the canonical English names from the specification glossary. The ones that
matter most:

| Term | Meaning |
|---|---|
| Fund, Mandate | A fund and its rules, written once at creation |
| Core Vault | Hub-chain contract: custody of idle USDC, share ledger, payout requests and payments; never calls a protocol |
| Spoke Vault | The fund's account on a chain (hub included): holds positions, drives adapters, keeps an internal ledger, publishes value reports |
| Share, Share Assets, Share Price | ERC-20 share (18 decimals, whole units only); what backs shares; assets divided by shares |
| Gross Assets | Everything the fund holds: Share Assets, Operating Cash, Attributed Income, external rewards |
| Idle, Payout Reserve, Free Idle | USDC in the Core Vault; the part reserved for Standard Payouts; the part the manager may allocate |
| Unallocated Balance, In-flight Value, Spoke Cap | Value in a Spoke Vault not yet in a position; value moving between chains; how much may be sent to a spoke |
| Payout Request, Payout, Instant Payout, Standard Payout, Payout Fee | The exit flow and its two speeds |
| Attributed Income, Income Withdrawal | Income that belongs to holders who held while it was earned; taking it out without burning shares |
| Unwind | Turning positions into USDC; Idle first, proportional Hub/spoke sale fraction with a 2% buffer and delivered-position retry memory |
| Adapter, Bridge Adapter, Collector, Transport Route | Integration code per protocol; the bridge as an adapter; receive-only code; the bridge route |
| Operating Cash, Operating Expense, Network Costs, Market Costs | Per-chain gas budget; a fund expense with its funding source; gas and bridge fees; swap fees, impact, slippage |

Words the glossary forbids in identifiers: `liquidation`, `settlement` (as a process name), `fulfillment`,
`yield`, `revenue`, `accrued`, `cost` (for Operating Expense), `withdrawal` for exits that burn shares.

## Contributing rules

1. Every rule in code cites the decision that governs it (`DEC-nnn`) in NatSpec and in the test name.
2. No rule is assumed. If a decision does not cover a case, the case goes to `docs/OPEN-QUESTIONS.md` and the
   code takes the most conservative behaviour (revert) until the founder decides.
3. English only, canonical names only.
4. Tests run on mainnet forks, never on testnets.
5. Branches follow `<type>/pp-sc-<type>-<num>-<slug>`; parallel work happens in git worktrees.

## License

To be decided by Pool Party Labs.
