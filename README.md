# Pool Party v2 smart contracts

On-chain funds run by a manager, human or AI agent, inside a Mandate fixed at creation. Investors deposit and
withdraw USDC on one chain (the Hub Chain) while the fund's capital works on several chains (Spoke Chains).

This repository holds the Solidity implementation. **Everything here is in English.** The product definition,
decision register and research live in the separate specification repository (`PoolParty_SCs_v2`, in
Portuguese); its decisions (DEC-001 to DEC-110, later decisions override earlier ones) are the business rules
this code must follow. `docs/DECISIONS.md` is the English digest of that register and `docs/OPEN-QUESTIONS.md`
lists what is still undecided and how the code leaves room for it.

## Status

Buildathon MVP, in progress. Nothing is deployed to production. See `docs/ARCHITECTURE.md` for the target
design and the current scope.

## Scope of the buildathon MVP

| In scope now | Next | Not planned for now |
|---|---|---|
| Arbitrum One as Hub Chain, Robinhood Chain as Spoke Chain | More spokes (Base, Ethereum) with CCTP as primary bridge | Borrowing, leverage, perps |
| Uniswap V4 position adapter on both chains; Aave V3 supply-only adapter on Arbitrum | Collectors for reward campaigns (Merkl) | Share transfers between owners |
| Across bridge adapter (USDC on Arbitrum, USDG on Robinhood) | Collectors for reward campaigns (Merkl) | Auto-compounding inside the contract |
| Wormhole value reports, finalized consistency, permissionless relay | Multi-spoke report scheduling | ZK proofs of value, Uniswap V3 |
| Deposit, allocate, report, Instant and Standard Payouts, Income Withdrawal | Autonomous-manager guardrails, emergency runbook | CCTP on Robinhood Chain, Solana |

The specification's MVP names Uniswap V4 plus Aave V3 without borrowing (DEC-018, DEC-028); the founder confirmed
that scope on 2026-09-29, so the Uniswap V3 proof-of-concept adapter is not built. Every protocol sits behind the
same adapter interface.

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
  unit/        Pure unit and fuzz tests, no network
  invariant/   Invariant suites (share price never moved by third-party entries, ledger vs balance, ...)
  fork/        Mainnet fork tests against Arbitrum One and Robinhood Chain (never testnets)
script/        Deployment scripts (fork first, then mainnet)
docs/          DECISIONS.md, OPEN-QUESTIONS.md, ARCHITECTURE.md, INTEGRATIONS.md, DEPLOYMENT.md
```

## Toolchain

- Foundry (forge 1.7+), Solidity 0.8.28, EVM `cancun`.
- OpenZeppelin Contracts 5.7 for ERC-20, access control, reentrancy guards, SafeERC20, math.
- Uniswap `v4-core` and `v4-periphery` (interfaces, types and libraries; the pinned-pragma contracts are never
  compiled, the deployed ones are used on forks). `v3-core`/`v3-periphery` stay only for the toolchain smoke test.
- `wormhole-solidity-sdk` v1.0.0 for Core Bridge interfaces, VAA parsing, replay protection and the
  `WormholeOverride` fork-test helper that signs VAAs with a guardian set the test controls.
- Across and Aave V3: minimal interfaces vendored in `src/interfaces/external/` (both upstream repos are Hardhat
  monorepos).

## Getting started

```bash
cp .env.example .env            # public RPCs work; a provider key is recommended for fork suites
forge build
forge test --no-match-path "test/fork/**"     # unit + invariant, no network
forge test --match-path "test/fork/**" -vvv   # mainnet forks of Arbitrum One and Robinhood Chain
forge fmt --check
```

Fork tests read `ARBITRUM_RPC_URL` and `ROBINHOOD_RPC_URL`. Set `ARBITRUM_FORK_BLOCK` and
`ROBINHOOD_FORK_BLOCK` to pin blocks for deterministic runs.

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
| Unwind | Turning positions into USDC on the hub, in Mandate order, only for what Idle cannot cover, with a 2% margin |
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
