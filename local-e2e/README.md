# local-e2e: the two-fork development harness

Two long-lived local anvil nodes, one forking **Arbitrum One** (Hub Chain, chain id 42161, port 8545) and one forking
**Robinhood Chain** (Spoke Chain, chain id 4663, port 8546), with the whole protocol deployed through the repository's
real deployment scripts, a keeper that stands in for what does not exist locally (the Across relayers and the Wormhole
guardians, in both directions), a scenario runner that drives one fund end to end over JSON-RPC with real signed
transactions, a minimal API with the API signer's key, and a run report for every run.

It is a developer tool for the API and frontend teams (and for anyone who wants to watch the contracts interact), not
production code. Everything the contracts talk to is the real mainnet contract as of the fork block; only the off-chain
actors are simulated.

## Prerequisites

- Foundry 1.7+ (`anvil`, `forge`) on the `PATH`: <https://getfoundry.sh>
- Node 24 and pnpm (10 or later)
- `bash`, `curl`, `lsof` (macOS or Linux)
- Network access to an Arbitrum One and a Robinhood Chain RPC. An archive endpoint is best: one Alchemy key serves both
  chains (Alchemy supports Robinhood Chain mainnet as well as Arbitrum One). Export `ARBITRUM_RPC_URL` and
  `ROBINHOOD_RPC_URL` (and, for reproducible runs, `ARBITRUM_FORK_BLOCK` and `ROBINHOOD_FORK_BLOCK`) in the shell that
  runs `pnpm run up`, for instance by sourcing a local env file. The harness prints the upstream host only, never the
  URL, its error output included (anvil's and forge's errors repeat the URL; the harness cuts every URL to its host).
  anvil's own logs, `.state/arbitrum.log` and `.state/robinhood.log`, hold the full URL with its key: they are
  gitignored, never share them. The public endpoints work for short sessions (see [Troubleshooting](#troubleshooting)).

## Quick start

```bash
cd local-e2e
pnpm install
pnpm run up                        # build, fork, deploy, fund, guardians, seeded fund, warm-up: about a minute
pnpm keeper --auto-report 600      # in another terminal: Across fills, VAAs both ways, reports every 10 min
pnpm scenario                      # the end-to-end scenario over JSON-RPC (about 40 s), with a run report
pnpm api:probe                     # the API's concepts over HTTP, with a run report
pnpm status                        # nodes, keeper, addresses, fund books, freshness, balances
pnpm down                          # stops the keeper and both forks
```

`pnpm up` is pnpm's own `update` command: the harness's script is **`pnpm run up`** (every other script works with or
without `run`).

Point a wallet or an app at `http://127.0.0.1:8545` (chain 42161) and `http://127.0.0.1:8546` (chain 4663), import the
actor keys below, and read every address from `local-e2e/.state/deployment.json`. The ABIs are in `local-e2e/abis/`.

## Commands

| Command | What it does |
|---|---|
| `pnpm run up [--warm-up scenario\|none]` | `forge build`; starts both forks (`scripts/start-forks.sh`); `script/DeployFactory.s.sol` on both nodes with the operator's key (same factory address required, DEC-054; the API signer owns the ManagerRegistry); replaces the guardian set of both Wormhole Cores with the local guardian and self-tests a VAA in each direction; re-stamps Chainlink; finds the storage layouts the keeper needs; deploys the trader's swap routers and a Uniswap V3 swap adapter per chain for the API's signed routes; funds the actors (clearing the EIP-7702 delegations the public keys carry on mainnet); `script/CreateFund.s.sol` with the manager's key (`createFund` with the manager's seed on the hub, DEC-127; `createSpoke` on Robinhood); writes `.state/deployment.json`; then warms the fork caches (see [Troubleshooting](#troubleshooting)) |
| `pnpm down` | Stops the keeper and both forks through their pid files (never another anvil), removes `deployment.json`, keeps the logs |
| `pnpm keeper [--auto-report <s>] [--vaa-delay <s>] [--order-delay <s>] [--fill-delay <s>] [--fill-mode auto\|real\|simulated]` | The long-running keeper (see [Keeper](#keeper)); Ctrl-C finishes running work and exits |
| `pnpm scenario [--keeper auto\|inprocess\|external] [--new-fund]` | The end-to-end scenario (see [Scenario](#scenario)); exits non-zero on the first failed assertion; writes a [run report](#run-reports) |
| `pnpm warp <duration> [--no-report]` | Advances **both** clocks (`3600`, `90s`, `30m`, `72h`, `3d`; `0` just refreshes), re-stamps Chainlink and publishes a fresh report from every spoke, delivered by the running keeper or directly |
| `pnpm status` | Nodes, keeper, deployment, fund books, report and price freshness, actor balances |
| `pnpm abis` | Re-exports `abis/*.json` from `forge build` (commit the result when the contracts change) |
| `pnpm api` | A minimal API over both forks on `127.0.0.1:8787`, holding the API signer's key (see [API probe](#api-probe)) |
| `pnpm api:probe` | Starts that API in-process with the keeper and checks, over HTTP, the concepts the product API relies on, on an unused fund (a fresh one when the deployed fund was used); writes a [run report](#run-reports) |
| `pnpm exec tsx src/fund-accounts.ts` | Tops every actor up again (idempotent) |
| `pnpm exec tsx src/guardian.ts` | Re-applies the guardian override on both Cores (idempotent) and self-tests a VAA in each direction |

## What is real and what is simulated

| Piece | On the local forks | In production |
|---|---|---|
| Fund contracts (factory, Core Vault, Spoke Vaults, adapters, receiver, fee vault, registry, price source) | Real, deployed by `script/DeployFactory.s.sol` and `script/CreateFund.s.sol`, CREATE3 addresses as on mainnet | Same scripts, same addresses for the same operator key |
| Uniswap V4 (PoolManager, PositionManager, StateView, the WETH/USDC and WETH/USDG 0.05% pools), Aave V3 Pool, USDC, USDG, WETH | Real contracts and liquidity as of the fork block | Live |
| Across SpokePools | Real: deposits go through `depositV3` on the live pool, fills through the live pool's `fillRelay` | Live |
| Across relayer | **Simulated by the keeper**, which fills every deposit to a fund vault through the real `SpokePool.fillRelay` as a funded relayer, so the pool itself transfers the output token and calls `handleV3AcrossMessage`. A simulated fill (pool impersonated) is only a logged fallback | Independent relayers, fill speed and willingness depend on fees |
| Across send terms | Fixed by the fund's Across bridge adapter (DEC-158, DEC-162): the amount to arrive from its fee rule over the route's last sends, quote time = the block, no exclusivity; nobody passes a quote (`quoteSend` shows it first) | Same contracts; the API may later relay a signed quote (R-162-B, WP-11) |
| Across refunds and repayments | **None**: no dataworker, no bundles; an unfilled deposit stays unrefunded | Refund of the full input to the escrow after the fill deadline, by bundle |
| Wormhole Cores | Real contracts: `report()` publishes on the Robinhood Core and `parseAndVerifyVM` runs on the Arbitrum Core; Hub orders publish on the Arbitrum Core and verify on the Robinhood Core | Live |
| Wormhole guardians | **Simulated**: one local guardian (the SDK's devnet key) replaces the guardian set of **both** Cores in storage (quorum 1 of 1); the keeper signs reports after `KEEPER_VAA_DELAY_SECONDS` and orders after `KEEPER_ORDER_DELAY_SECONDS` | 13 of 19 guardians, after 15 to 20 minutes of Robinhood finality for reports, at once for instant-consistency orders |
| VAA delivery and report cadence | The keeper (`deliver` and `executeOrder` are permissionless; `--auto-report` calls `report()`); the API publishes a report after each deposit (DEC-159) | The protocol's keeper, the API (or anyone) |
| Uniswap V3 (swaps, DEC-136) | Real factory, QuoterV2, SwapRouter02 and pools; the API signs routes with QuoterV2 on the fork for a swap adapter per chain whose vault is the manager's wallet, until the factory deploys each fund's own (WP-07) | The Pool Party API signs routes from the Uniswap Trading API's quote |
| Chainlink ETH / USD | Real feed with its answer frozen at the fork block; the round's timestamp is re-stamped by the keeper and by `warp` (no rounds are posted on a fork) | Live rounds (heartbeat and deviation) |
| Balances | Written into the tokens' balance mappings (USDC, USDG) and wrapped from ETH (WETH) | Real funds |
| Time | Both anvil clocks, advanced together by `warp` | Wall clock |
| Third-party trading | The `trader` actor swinging the pools through `test/mocks/v4/V4SwapRouter.sol` | The market |

## Actors and keys

anvil's default mnemonic (`test test test test test test test test test test test junk`). **Public test keys: never
use them on a real network.**

| Actor | Account | Address | Private key | Role |
|---|---:|---|---|---|
| operator | 0 | `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` | `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80` | Deploys the factories; adapter guardian; ManagerRegistry owner |
| manager | 1 | `0x70997970C51812dc3A010C7d01b50e0d17dc79C8` | `0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d` | Creates the fund (DEC-001) and manages it |
| ana | 2 | `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC` | `0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a` | Shareholder (100,000 USDC) |
| bruno | 3 | `0x90F79bf6EB2c4f870365E785982E1f101E93b906` | `0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6` | Shareholder (100,000 USDC) |
| keeper | 4 | `0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65` | `0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a` | Keeper and Across relayer (1,000,000 USDC and USDG, topped up automatically) |
| stranger | 5 | `0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc` | `0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba` | Permissionless calls, donations |
| protocolRecipient | 6 | `0x976EA74026E726554dB657fA54763abd0C3a0aa9` | `0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e` | Protocol Recipient: flow fee, protocol slice, swept excess (DEC-106) |
| trader | 7 | `0x14dC79964da2C08b23698B3D3cc7Ca32193d9955` | `0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356` | Swaps in the V4 pools to generate fees (50M USDC and USDG, 10,000 WETH per chain) |
| apiSigner | 8 | `0x23618e81E3f5cdF7f54C3d65f7FBc0aBf5B21E8f` | `0xdbda1821b80551c9d65939329250298aa3472ba22feea921c0cf5d620ea67b97` | The Pool Party API's key (reading D-01 of DEC-112): ManagerRegistry owner (`REGISTRY_OWNER`), route signer of the swap adapters and future quote signer of the bridge adapters (`API_SIGNER`), sender of the report after each deposit (DEC-159) |

The operator (account 0) deploys the factories and guards the adapters. Every actor has 10,000 ETH on both nodes; the
manager and the stranger also hold 10,000 USDC and 10,000 USDG (the manager's seed of each fund comes out of his USDC).
Because the keys are public, all nine accounts carry an EIP-7702 delegation (to a sweeper) on Arbitrum One and Robinhood
Chain; funding clears it on the forks so the actors are plain EOAs. The local Wormhole guardian is
`0xbeFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe` (key in `src/config.ts`).

## The default fund

`up` creates fund `PP-1` with `script/CreateFund.s.sol`, the Mandate of the end-to-end fork scenario: hub Uniswap V4
WETH/USDC 0.05% plus Aave V3 USDC, spoke Uniswap V4 WETH/USDG 0.05%, Across in both directions (the adapter's fee rule
fixes every send, DEC-162; the Mandate's `maxBridgeFeeBps` is a dead field until Mandate v2), a Spoke Cap of 4,000 USDC,
a 2% Payout Fee, a 72 h Standard Payout term, a 20% performance fee, no management fee, a 100 USDC minimum first
deposit and a Robinhood `maxReportAge` of 1,588 s. The manager seeds it in the creation transaction (DEC-127): 100 USDC,
99 shares at 1.00 after the 25 bps flow fee. `SPOKE_CAP`, `MIN_FIRST_DEPOSIT`, `SEED_AMOUNT` (default
`MIN_FIRST_DEPOSIT`), `PERFORMANCE_FEE_BPS` and `MAX_BRIDGE_FEE_BPS` override the values (the variables the script
reads). More funds can be created with the same script or from the frontend; the keeper serves every fund the
factories create.

## The state file

`local-e2e/.state/deployment.json` (numbers that may exceed 2^53 are decimal strings):

```jsonc
{
  "version": 2,
  "createdAt": "2026-09-30T13:07:32.000Z",
  "nodes": {
    "arbitrum":  { "rpc": "http://127.0.0.1:8545", "chainId": 42161, "forkBlockNumber": 510354801, "forkBlockTimestamp": 1790773620 },
    "robinhood": { "rpc": "http://127.0.0.1:8546", "chainId": 4663,  "forkBlockNumber": 76538423,  "forkBlockTimestamp": 1790773621 }
  },
  "actors": { "operator": "0x…", "manager": "0x…", "ana": "0x…", "bruno": "0x…", "keeper": "0x…", "stranger": "0x…", "protocolRecipient": "0x…", "trader": "0x…", "apiSigner": "0x…" },
  "guardian": { "address": "0xbeFA…0FBe",
                "arbitrum":  { "coreBridge": "0xa5f2…CA46", "guardianSetIndex": 8 },
                "robinhood": { "coreBridge": "0x141f…87FB", "guardianSetIndex": 8 } },
  "protocol": {
    "arbitrum":  { "fundFactory", "create3Deployer", "coreVaultLogic", "spokeCrossChainLib", "spokeUnwindLib",
                   "managerRegistry", "priceSource", "transitEscrowImplementation", "protocolRecipient", "adapterGuardian",
                   "registryOwner", "apiSigner" },
    "robinhood": { "fundFactory", "create3Deployer", "spokeCrossChainLib", "spokeUnwindLib", "transitEscrowImplementation",
                   "apiSigner" }
  },
  "external": { "arbitrum": { "usdc", "weth", "acrossSpokePool", "wormholeCore", "v4PoolManager", "v4PositionManager", "v4StateView",
                              "aaveV3Pool", "aaveV3AddressesProvider", "aUsdc", "ethUsdFeed", "permit2", "deterministicDeployer",
                              "v3Factory", "v3QuoterV2", "v3SwapRouter02" },
                "robinhood": { "usdg", "weth", "acrossSpokePool", "wormholeCore", "v4PoolManager", "v4PositionManager", "v4StateView",
                               "permit2", "deterministicDeployer", "v3Factory", "v3QuoterV2", "v3SwapRouter02" } },
  "fund": {
    "creationNumber": "1", "fundId": "0x…", "mandateHash": "0x…", "manager": "0x…", "shareSymbol": "PP-1",
    "hub":   { "chainId": 42161, "coreVault", "shareToken", "managerFeeVault", "valueReportReceiver", "spokeVault",
               "uniswapV4Adapter", "aaveV3Adapter", "acrossBridgeAdapter", "createdInBlock" },
    "spoke": { "chainId": 4663, "wormholeChainId": 72, "spokeIndex": 0, "spokeVault", "uniswapV4Adapter", "acrossBridgeAdapter", "createdInBlock" },
    "poolKeys": { "hub": [ { "currency0", "currency1", "fee": 500, "tickSpacing": 10, "hooks" } ], "spoke": [ { … } ] },
    "poolIds":  { "hub": ["0xfc7b…8653"], "spoke": ["0xfcfa…6593"], "aave": "0x…af88…5831" }
  },
  "helpers": { "arbitrumSwapRouter": "0x…", "robinhoodSwapRouter": "0x…",
               "swapAdapters": { "arbitrum": "0x…", "robinhood": "0x…" }, "swapAdapterVault": "0x…" },
  "storage": {
    "balances": { "arbitrum": [ { "token": "USDC", "mappingSlot": "9" } ], "robinhood": [ { "token": "USDG", "mappingSlot": "1" } ] },
    "acrossFillStatusesSlot": { "arbitrum": "2162", "robinhood": "2262" },
    "wormholeSequencesSlot": "4"
  }
}
```

The fund's addresses are the CREATE3 predictions, so they are the same after every `up` with the same operator and
manager keys: an app can hard-code them for local development, and the factory address matches on both chains.

## Keeper

`pnpm keeper` replaces four off-chain parties on the two forks:

1. **Across relayer.** Watches `FundsDeposited` on both SpokePools; for a deposit whose recipient is a known fund's vault
   on the other node (its Spoke Vault on Robinhood, its Core Vault on the hub) it builds the relay data from the event
   (bytes32 fields, origin chain id, the deposit id, fill and exclusivity deadlines, message), waits
   `KEEPER_FILL_DELAY_SECONDS`, and calls `fillRelay(relayData, repaymentChainId, repaymentAddress)` on the destination
   pool as the keeper account, which holds the output token and has approved the pool. The pool transfers
   `outputAmount` and calls the vault's `handleV3AcrossMessage` itself, exactly as a production fill does. Fills are
   idempotent (`fillStatuses` is checked first), skip expired deposits and deposits exclusive to another relayer, and
   top the relayer's inventory up when needed. The live implementations (Arbitrum `0xcfcd…f8c9`, Robinhood
   `0x1771…edd8`) both expose this bytes32 `fillRelay` (selector `0xdeff4b24`, verified in their bytecode), so the real
   path is the default; if it failed for another reason the keeper would fall back to impersonating the pool, and says
   so loudly (`--fill-mode real` forbids the fallback, `simulated` forces it).
2. **Wormhole guardians, spoke to Hub.** Watches `LogMessagePublished` on the Robinhood Core for messages from known
   Spoke Vaults, waits `KEEPER_VAA_DELAY_SECONDS`, builds the VAA v1 (the source block's timestamp, nonce, emitter chain
   72, the Spoke Vault as emitter, sequence, consistency level, payload), signs the double keccak of its body with the
   local guardian and calls `ValueReportReceiver.deliver(vaa)` on the hub, in sequence order per emitter.
3. **Wormhole guardians, Hub to spoke (orders, DEC-120, DEC-139).** Watches `LogMessagePublished` on the Arbitrum Core
   for messages from known Core Vaults (an `OrderCodec` order at instant consistency), waits
   `KEEPER_ORDER_DELAY_SECONDS`, signs the VAA (emitter chain 23, the Core Vault as emitter) for the Robinhood Core and
   calls the fund's `SpokeVault.executeOrder(vaa)` there, paying the Robinhood Core's message fee for the report the
   Spoke Vault publishes in the same transaction; orders of one emitter run in sequence order (DEC-093). `executeOrder`
   is detected in the Spoke Vault's code: until it exists (WP-07) the keeper logs the order and skips it.
4. **The protocol's keeper.** `--auto-report <seconds>` calls `SpokeVault.report()` on every known spoke on a cadence,
   so the hub never sees a report older than `maxReportAge` (1,588 s) and deposits keep working; it also re-stamps the
   Chainlink round when it is older than `KEEPER_FEED_MAX_AGE_SECONDS`.

Every fund, the deployed one included, is discovered from the factories' `FundCreated` and `SpokeCreated` events, so
funds created later (by the frontend, by the API, or by `pnpm scenario` on a used deployment) are served without a
restart. Each poll reads Arbitrum, then Robinhood, and registers both chains' creations before it relays anything, so
a Hub order always finds its fund's Spoke Vault. A restart rescans both chains from the fork block and relays what is
still pending; every action is idempotent.

| Environment | Default | Meaning |
|---|---|---|
| `KEEPER_VAA_DELAY_SECONDS` | 3 | Delay before a report's VAA is delivered; set 900 to 1200 to feel production finality |
| `KEEPER_ORDER_DELAY_SECONDS` | 1 | Delay before a Hub order is executed on the spoke (instant consistency) |
| `KEEPER_FILL_DELAY_SECONDS` | 1 | Delay before a deposit is filled |
| `KEEPER_AUTO_REPORT_SECONDS` | 0 (off) | Report cadence, same as `--auto-report` |
| `KEEPER_FILL_MODE` | `auto` | `auto`, `real` or `simulated` |
| `KEEPER_FEED_MAX_AGE_SECONDS` | 1800 | Re-stamp Chainlink when its round is older than this |
| `KEEPER_POLL_MS` | 500 | Log polling interval |

## Time

The hub judges a spoke report by its own clock (DEC-099: older than `maxReportAge` is stale, more than one
`maxReportAge` ahead is from the future), so time must move on **both** nodes at once: `pnpm warp 72h` sets both to the
later clock plus 72 hours, mines, re-stamps Chainlink and has every spoke publish a fresh report (delivered by the
running keeper, or directly when no keeper runs). Never use `evm_increaseTime` on one node only. The bounds that matter:

| Bound | Value | What happens past it |
|---|---|---|
| Spoke report lifetime (`maxReportAge`) | 1,588 s | Deposits revert `StaleSpokeReport` (payouts still work) |
| Chainlink ETH / USD `maxPriceAge` | 3,600 s | Deposits revert `StalePrice` |
| Across fill deadline | 6 h | The keeper stops filling; the deposit waits for a refund that never comes locally |
| Standard Payout term | 72 h | The claim becomes possible |

`pnpm warp 0` only refreshes the report and the price.

## Scenario

`pnpm scenario` reproduces the phases of `test/fork/e2e/EndToEnd.t.sol` over JSON-RPC, with signed transactions from
the actors and assertions at every step (each cites its decision), and adds three: Principal coming home through
Across (the keeper's fill on Arbitrum), the Hub-to-spoke order channel, and the closure.

1. The fund as created: one factory address on both chains, the spoke's Mandate hash equals the hub's, every Mandate
   rule; the manager's seed from the creation transaction (DEC-127: 99 shares at 1.00 after the flow fee, the first peak)
2. Ana deposits 10,000 USDC after the seed (25 bps flow fee, 9,975 whole shares at 1.00)
3. Hub allocation, Aave supply, a V4 position, a one-hour warp, the trader's fees; Share Assets as the sum of buckets
4. 4,000 USDC to Robinhood with no bridge parameter (DEC-158): the Across adapter's `quoteSend` is the amount to arrive
   (initial rate plus the fixed part, DEC-162), the Spoke Cap refusal, a manager quote refused (`QuotesNotSupported`),
   the deposit's fields (quote time = the block, no exclusivity) and `SendPriced`
5. The keeper's fill through the Robinhood pool's `fillRelay`, the arrival, a WETH/USDG position and fees
6. `report()` on the real Robinhood Core, the VAA delivered by the keeper, `ArrivalConfirmed`, the spoke value priced
7. 500 USDG of Principal sent home with a zero quote, at the spoke adapter's `quoteSend`, filled on Arbitrum, credited
   to Idle once a report lists it
8. Hub income collected and forwarded; the 20% fee split at collection (Protocol Recipient, ManagerFeeVault, holders);
   the net attributed pro rata to Ana and the manager's seed
9. Bruno deposits 11,000 USDC at the new Share Price, owing none of the income already collected
10. Ana's Income Withdrawal
11. Ana's Standard Payout: request, a 72 h warp of both clocks with a fresh report, the claim from Idle
12. Bruno's Instant Payout above Free Idle, with the automatic unwind of the hub V4 position; the Payout Fee stays in
    Idle (DEC-144)
13. Invariants: Payout Reserve within Idle, whole shares, Share Assets = sum of buckets, a donation swept
14. The order channel: until the Core Vault publishes orders itself, an UNWIND order is published from its address on
    the live Arbitrum Core (instant consistency); the keeper relays it (skipped until the Spoke Vault has
    `executeOrder`), and so does a second keeper started after the publication (a restart: it rescans from the fork
    block); its VAA passes `OrderVerifier` on the live Robinhood Core through the test receiver, once
15. The manager's base (`ManagerMustCloseFund` under half of the peak, DEC-146) and `closeFund`: Closing refuses
    deposits, requests, claims and a second closure; Income Withdrawal stays open

Keeper: `--keeper auto` (default) uses a running `pnpm keeper` if its pid file is live, else starts the keeper
in-process (and stops it at the end); `inprocess` and `external` force one. For CI-style runs:

```bash
pnpm run up && pnpm scenario --keeper inprocess; status=$?; pnpm down; exit $status
```

The scenario needs an unused fund: once the deployed fund has holders besides the manager's seed, a spoke report or
left Open, it creates a fresh one through `script/CreateFund.s.sol` (`--new-fund` forces that), so it can run any
number of times on the same nodes.

## API probe

`src/api.ts` is the smallest API that shows what the product API needs from the contracts: it reads chain state and
builds unsigned transactions for the user, and every number it returns is read from the contracts or obtained by
`eth_call` against the fork's state. It holds one key, the API signer's (account 8): it signs swap routes and publishes
the report after each deposit. Routes:

| Route | What it returns |
|---|---|
| `GET /health` | both nodes, clocks, the spoke report's age against its lifetime, the WETH price's age against its feed bound, `mintsOpen` (a spoke that never reported does not close mints), `payoutsOpen` |
| `GET /fund` | identity, the value bases (Share Assets, Gross Assets, Idle, Free Idle, Payout Reserve, In-flight Value, Operating Cash, held-apart arrivals), the Share Price, Spoke Cap usage, fee parameters in force |
| `GET /holders/:address` | shares, their value at the Share Price, Attributed Income and owed transfers per income token, the open Payout Request |
| `GET /quote/deposit?from=&amount=` | the exact shares and USDC charged, by simulating `deposit`, or the decoded revert (`StaleSpokeReport`, `StalePrice`, `SharePriceBelowOneUnit`, ...) |
| `GET /quote/claim?from=` | the exact payout receipt by simulating `claimPayout` with the API's hints |
| `GET /quote/swap?tokenIn=&amountIn=` | a manager swap minimum: the oracle value less 1% (the vault enforces none: security review S-8, open) |
| `GET /quote/swap-route?chain=&tokenIn=&tokenOut=&amountIn=&slippageBps=&adapter=&hops=` | the best single Uniswap V3 path QuoterV2 quotes on the fork (1,000,000 gas per quote, D-21), direct in one of the four fee tiers or two hops through another Mandate token of the adapter (D-52; `hops=1` or `hops=2` keeps only those), over the tiers with at least 1% of the pair's deepest in-range liquidity, signed by the API signer as the EIP-712 `SwapRoute` of `UniswapV3SwapAdapter` (domain bound to the adapter); `encodedRoute` is the `route` argument of `swap`; the minimum is the quote less `slippageBps` (default 100, at most 500, the Spoke Vault's own unwind floor: the API never signs a near-zero minimum, DEC-142); `adapter` may only name the swap adapter the API serves on that chain (422 otherwise), since every production adapter accepts the API signer's routes (D-01) |
| `GET /quote/bridge?direction=to-spoke\|to-hub&amount=` | what the fund's Across adapter fixes for a send of `amount` now (`quoteSend`: amount to arrive, fee, rate) and the route's fee state; `signed: false` until signed quotes (R-162-B, WP-11) |
| `GET /share-price/history?fromBlock=&toBlock=` | the Share Price, Share Assets and shares at every hub block where the Core Vault emitted an event, with the event names |
| `POST /tx/deposit`, `/tx/request`, `/tx/claim`, `/tx/swap` | unsigned transactions (approval first when needed); `/tx/deposit` answers 409 while mints are closed |
| `POST /report/after-deposit {txHash}` | DEC-159: checks the transaction is a deposit into the fund, publishes `report()` on every spoke with the API signer and waits for the keeper to deliver it (or, with no keeper running, delivers it with the harness guardian); once per deposit: a replayed hash gets the first answer, and a spoke whose report accepted on the Hub is already later than the deposit gets no new one (`published: false`) |
| `GET /events?fromBlock=` | the Core Vault's events, decoded |

`pnpm api:probe` drives those routes on an unused fund (the deployed one, or a fresh one) and checks: the deposit quote
equals the minted shares; the report the API publishes right after the deposit is delivered by the keeper and is the
Hub's latest (DEC-159), and the same deposit sent again gets the same answer and no second report; past the report lifetime with no new report `/health` shows mints closed, the chain reverts
`StaleSpokeReport` and the API refuses to build a deposit, while an Instant payout from Idle still executes and pays
exactly what `/quote/claim` said; a fresh report reopens mints; a 1,000 USDC hub swap built by the API respects its
oracle minimum on the live pool and the same swap at 0 bps reverts `InsufficientOutput`; the bridge quote is exactly
what the adapter fixed for a send to Robinhood and a send home (DEC-162); the API refuses to sign a minimum looser than
5% (400) or for an adapter it does not serve (422); a route the API signed executes through the swap adapter on the
live V3 pools of each chain for its quoted output, and a tampered minimum reverts `InvalidRouteSignature`; every step ended with an event the indexer served; the Share Price history holds every mint
at its price; a holder's value equals shares times the Share Price.

## Run reports

Every `pnpm scenario` and `pnpm api:probe` run writes `local-e2e/reports/<UTC time>-<kind>.json` and `.md`
(`src/report.ts`), passed or failed: the steps and assertions, the gas of every transaction the run sent (the forge
broadcasts of `createFund` included) and per verb, the Share Price timeline (at each phase start, and at every hub block
with a Core Vault event), the fee ledger summed from the vaults' events (flow fee of the seed, the deposits and the
payouts; Payout Fee kept in Idle; performance fee with its manager part and protocol slice per token; management fee
once the Core Vault accrues one; bridge fees per direction), the balances at the end, the commit and the fork blocks.
Git ignores them; commit a run worth keeping with `git add -f`.

## Environment

| Variable | Default | Used by |
|---|---|---|
| `ARBITRUM_RPC_URL`, `ROBINHOOD_RPC_URL` | the process environment, then the repo `.env`, else the public endpoints | the forks' upstreams (an archive endpoint, such as one Alchemy key for both chains, keeps any fork block usable) |
| `ARBITRUM_FORK_BLOCK`, `ROBINHOOD_FORK_BLOCK` | latest | fork blocks, **process environment only** (the repo `.env` pins old blocks for the forge fork suites, which a public RPC no longer serves); pin them with an archive endpoint for reproducible runs |
| `LOCAL_E2E_ARBITRUM_PORT`, `LOCAL_E2E_ROBINHOOD_PORT` | 8545, 8546 | every script |
| `LOCAL_E2E_API_PORT` | 8787 | `pnpm api`, `pnpm api:probe` |
| `LOCAL_E2E_ANVIL_CUPS`, `LOCAL_E2E_ANVIL_RETRIES`, `LOCAL_E2E_ANVIL_BACKOFF_MS` | 150, 10, 1000 | anvil's upstream rate limit, retries and backoff |
| `LOCAL_E2E_HARDFORK` | prague | both nodes |
| `SPOKE_CAP`, `MIN_FIRST_DEPOSIT`, `SEED_AMOUNT`, `PERFORMANCE_FEE_BPS`, `MAX_BRIDGE_FEE_BPS` | 4,000 USDC, 100 USDC, `MIN_FIRST_DEPOSIT`, 2000, 4 (dead field) | the funds `up`, `scenario` and `api:probe` create |
| `KEEPER_*` | see [Keeper](#keeper) | the keeper |

## Troubleshooting

**`state not available`, `missing trie node`, `failed to get storage` (and the harness's hint).** anvil fetches every
account and storage slot it has not seen yet from the upstream, at the fork block. The public endpoints are not archive
nodes: Robinhood's serves about 10 minutes of state, Arbitrum's about an hour, so after that a fork on them can only use
what it cached early. The harness designs for it: it forks at latest, deploys within about 30 s, and then warms the
cache. It runs the whole scenario inside a snapshot of both nodes, collects every account and storage slot its
transactions touched (anvil's prestate tracer), reverts to the fresh deployment (a revert also drops whatever anvil
fetched during the snapshot) and reads all of it again while the upstream still serves the fork block. The default
fund's flows (deposits, allocations, both Across legs, reports, income, payouts) then keep working for the whole
session (measured: the scenario passes end to end on the default fund after the Robinhood upstream stopped serving the
fork block). The keeper also zero-fills a fresh mapping slot it can compute (a new relay's `fillStatuses` entry, a
balance) when the upstream refuses it, since such a key never existed upstream. What cannot be cached ahead fails
after the window, with the hint: a fund created later (`pnpm scenario` on a used deployment creates one; its
`createSpoke` then fails on Robinhood and leaves a hub-only fund behind), a new address touching a token for the first
time, a price range the pools never visited. Then either `pnpm down && pnpm run up` (a minute), or, for day-long
sessions, point both forks at an archive endpoint: one Alchemy key serves Arbitrum One and Robinhood Chain alike
(`https://arb-mainnet.g.alchemy.com/v2/<key>` and `https://robinhood-mainnet.g.alchemy.com/v2/<key>`). With an archive
upstream the warm-up is not needed (`pnpm run up --warm-up none`), and pinned fork blocks stay usable for days.

**`Failed to get EIP-1559 fees ... metadata is not found`.** An archive endpoint stops serving fee history for old
blocks long before it stops serving state, so the harness hands forge the node's own gas price instead of letting it
estimate fees; a script of your own against a pinned fork needs `--with-gas-price` and `--priority-gas-price` too.

**Rate limits (HTTP 429, timeouts during `up`).** anvil retries with backoff; lower `LOCAL_E2E_ANVIL_CUPS` for the
public endpoints, or use a provider key.

**Ports in use.** `up` refuses to start over another process: stop it, or set `LOCAL_E2E_ARBITRUM_PORT` /
`LOCAL_E2E_ROBINHOOD_PORT` (every script reads them). `up` also refuses while the harness is already up: `pnpm down`.

**Deposits revert `StaleSpokeReport` or `StalePrice`.** The last spoke report is older than 1,588 s or the Chainlink
round older than an hour on the hub clock: run the keeper with `--auto-report 600` (it also re-stamps Chainlink), or
`pnpm warp 0`. `pnpm status` shows both ages.

**Clocks.** After `up` the nodes' clocks run a little behind the wall clock (the warm-up's snapshot revert takes them
back to the deployment); after a warp they run ahead. Deadlines must use the chain's latest block timestamp, never
`Date.now()`.

**Wallets.** After `pnpm down && pnpm run up` the chains restart, so a wallet's cached nonces are wrong: reset the
account's activity (MetaMask: Settings, Advanced, Clear activity tab data).

**Logs.** `local-e2e/.state/arbitrum.log`, `robinhood.log` (anvil), the keeper logs to its terminal, forge broadcast
files in `.state/broadcast/`. anvil writes its upstream URL, API key included, into its log (`Endpoint: ...`, and again
in its errors): read those files locally, never paste or share them. Everything the harness itself prints or writes to
a run report keeps the host of a URL only.

## How it differs from production

- **Guardians.** One local key signs with quorum 1 of 1 on both Cores; production VAAs carry 13 of 19 guardian
  signatures and appear only after Robinhood reaches finality (15 to 20 minutes for the finalized consistency level the
  reports use), at once for the instant-consistency orders. Set `KEEPER_VAA_DELAY_SECONDS=1200` to feel it.
- **Orders.** Until the Core Vault publishes orders (WP-09 on) and the Spoke Vault executes them (WP-07), the scenario
  publishes one from the Core Vault's address and the keeper only logs it.
- **The API signer.** Its key is a public anvil key held by the local API; in production it is the API's own key, the
  ManagerRegistry owner and the route and quote signer wired at deployment (reading D-01). The harness's swap adapters
  name the manager's wallet as their vault until the factory deploys each fund's own adapter (WP-07). The local API also
  pays the reports after deposits with it; production sends those from a separate gas key, never from the
  registry-owner and route-signer key, and keeps the deposits it answered in its store rather than in memory.
- **Across.** Real SpokePools, but one keeper fills every deposit to a fund vault at whatever fee the quote left, within
  seconds. Production relayers fill only profitable deposits, quotes come from the Across API, and an unfilled deposit
  is refunded to its TransitEscrow after the fill deadline by the dataworker's bundle, which does not exist locally.
- **Prices and markets.** Chainlink keeps the fork block's answer (only its timestamp moves); pools move only when
  someone swaps on the fork.
- **Gas.** anvil does not charge Arbitrum's L1 data fee; `createFund`'s 36 KB of calldata costs more on mainnet.
- **Balances.** Tokens are minted by storage writes; totalSupply does not follow.

## Layout

```
local-e2e/
  package.json, pnpm-lock.yaml, tsconfig.json
  abis/                 ABIs of the protocol contracts (pnpm abis)
  scripts/              start-forks.sh, stop-forks.sh, export-abis.sh
  src/config.ts         chains, protocol addresses, ports, actors, guardian key, Mandate plan defaults
  src/chain.ts          RPC clients, anvil methods, transactions and their gas log, revert decoding, pruned-state hint
  src/deploy.ts         DeployFactory and CreateFund through forge, the fresh-fund rule
  src/fund-accounts.ts  balances and approvals
  src/guardian.ts       guardian set override on both Cores and VAA signing
  src/orders.ts         the Hub-to-spoke order (OrderCodec) and executeOrder detection
  src/price-feed.ts     Chainlink re-stamp
  src/keeper.ts         Across filler, VAA relayer both ways, auto-report
  src/warp.ts           time warp on both nodes
  src/scenario.ts       the end-to-end scenario
  src/uniswap.ts        TickMath, adapter params, trader swings
  src/swap-route.ts     V3 paths quoted by QuoterV2 and the API signer's EIP-712 route signature
  src/history.ts        Share Price history and fee ledger from the vaults' events
  src/report.ts         run reports
  src/up.ts, status.ts  the up and status commands
  src/api.ts            the minimal API; src/api-probe.ts drives it over HTTP
  reports/              run reports (gitignored)
  .state/               pids, logs, deployment.json, broadcast files (gitignored)
```
