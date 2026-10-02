# Internal alpha deployment — DEC-134

Prepared and rehearsed on **October 2, 2026**, against `main` `1db9a9d`. Arbitrum One is the Hub Chain
(EVM 42161 / Wormhole 23); Robinhood Chain is the Spoke Chain (EVM 4663 / Wormhole 72).
This is an operator runbook, **not authorization to broadcast on mainnet**. No mainnet deployment took place.

## Release gates

1. Freeze an independently reviewed commit after the outstanding unwind, income and closure work lands. On this
   baseline, spoke UNWIND/CLOSE/COLLECT handlers and complete closure are not ready. Do not infer feature completion
   from the deposit smoke test. Re-run this entire rehearsal on the frozen commit: library addresses and creation
   code hashes depend on the build.
2. Pass `forge build --sizes`, `forge fmt --check`, the size suite, all non-fork and all fork tests, and the final
   `local-e2e` scenario/API probe required by HANDOFF section 6. This branch's smoke is not that final scenario.
3. Obtain Rafael's signed-off input sheet, maximum alpha exposure, funded wallets, incident contact and process
   supervisor. Keep the API loopback-only, behind an authenticated internal tunnel; do not expose the ordinary
   harness API. Only Pool Party wallets participate. Contracts remain permissionless: this is operational access
   restriction, not an on-chain allowlist (DEC-001/134).
4. Confirm a **real guardian-signed VAA** from the newly deployed emitter is available through the configured VAA
   service, accepted by the destination Core, and delivered before report expiry. The local guardian override is
   not evidence that the mainnet service observes a new emitter. Do not allocate to the spoke before this passes.
5. Confirm Across route availability, token limits, relayer fill/refund support and fee economics with a tiny
   transfer, before allocating meaningful Share Assets. The alpha keeper does not act as an Across relayer.
6. Verify all executable contracts and libraries, retain the release build/broadcast records, and publish the
   address manifest internally. Explorer submission itself was not rehearsed: the local deployments have no
   explorer records. The Robinhood API probe from this environment returned HTTP 403; confirm accessibility and
   successful verification at execution time.

Decisions: DEC-053/054 (Mandate/predictions), DEC-058/131 (pinned code/libraries), DEC-127 (seed), DEC-134
(internal dual-chain alpha), DEC-136/153/170 (swap/API signer), DEC-159/160 (reports), DEC-176 (no signed bridge
quote), DEC-182/184/186 (fees), DEC-187 (manager pays own gas). DEC-186/187 are Slack-only. The October 2 ruling
defers Operating Cash, native gas top-up and refunds; keep Operating Cash zero. This is a recorded departure from
DEC-185 in the written register, not implementation of it. DEC-186 supersedes the register's older 10% management
fee reading: the effective cap is **500 bps (5%)**, not 1,000 bps.

## Input sheet and secrets

Use encrypted Foundry keystores for operator/manager/guardian transactions. Import keys interactively; never put
them in shell history, files, logs or a PR. The runtime takes signer keys through an ephemeral environment from
a secret manager or hidden prompt. Disable shell tracing and terminal recording. Never print RPC URLs: they include
provider credentials. Do not source the worktree's shared `.env` for an alpha run: it belongs to other sessions.

For **every fork test, cast call or runtime start**, source the RPC helper in the **same shell invocation**:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
```

It exports archive URLs and pins. Fork pins are for local rehearsal only: mainnet transactions use live RPCs, not
`--fork-block-number`. Foundry also loads `.env`; export every chosen parameter explicitly to override it. An
empty `REGISTRY_OWNER` is not an unset variable: `unset REGISTRY_OWNER` to use `API_SIGNER`.

### Rafael provides or explicitly approves

| Input / env | Meaning / units / default |
|---|---|
| operator keystore; `DEPLOYER_ADDRESS` | Same operator address on both chains; controls the caller-bound factory salt. Fund ETH on both chains. `DEPLOYER_ADDRESS` is used by the checker; scripts use the signing account. |
| `API_SIGNER` | Public API signing address, same on both chains. Nonzero for this alpha. The immutable swap route signer and default ManagerRegistry owner (DEC-170). |
| `REGISTRY_OWNER` | Optional alternate hub registry owner. Normally **unset**, so it is `API_SIGNER`; an alternative is a deviation requiring approval. |
| `ADAPTER_GUARDIAN` | Public address authorized to `setPaused` / `deprecate` each adapter on both chains; fund its transaction wallet. |
| `PROTOCOL_RECIPIENT` | Protocol Recipient receiving flow fees, protocol income slices and swept excess; not the manager fee wallet. |
| `MANAGER`; manager keystore | First fund Manager / creator. Same address signs hub and spoke creation. Holds hub USDC seed and ETH on both chains. Manager pays own gas (DEC-187). |
| `PERFORMANCE_FEE_BPS` | Manager-selected 1,000..9,000 inclusive (10..90%); default 2,000. |
| `MANAGEMENT_FEE_BPS` | Annual manager-selected 0..500 inclusive (0..5%); default 0, DEC-186. |
| `SPOKE_CAP` | Maximum spoke principal including In-flight Value, in hub USDC base units (6 decimals); default `10000000000` = 10,000 USDC. Not a fund-wide TVL cap. |
| `SEED_AMOUNT` | Creation seed budget in USDC base units; defaults to `MIN_FIRST_DEPOSIT`. Must meet that minimum. Whole-share rounding means actual charged amount can be lower than budget; inspect receipt. |
| `MIN_FIRST_DEPOSIT` | Minimum first deposit/seed budget, USDC base units; default `100000000` = 100 USDC. Later deposits still need at least one whole share after fees. |
| `SPOKE_OPERATING_CASH_FLOOR`, `SPOKE_OPERATING_CASH_TOP_UP` | Both **0**, USDG base units; hub has no Operating Cash Mandate entry and also starts at 0. |
| `HUB_POOL_TOKEN0`, `HUB_POOL_TOKEN1` | Ordered Uniswap V4 token addresses; defaults Arbitrum WETH `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` / USDC `0xaf88d065e77c8cC2239327C5EDb3A432268e5831`. |
| `HUB_POOL_FEE`, `HUB_POOL_TICK_SPACING` | V4 fee in hundredths of a basis point / positive int24 spacing; defaults 500 / 10 (0.05%). |
| `SPOKE_POOL_TOKEN0`, `SPOKE_POOL_TOKEN1` | Defaults Robinhood WETH `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` / USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`. |
| `SPOKE_POOL_FEE`, `SPOKE_POOL_TICK_SPACING` | Defaults 500 / 10. Both chains' pool keys are hookless (`hooks = 0`); token0 must be numerically below token1. |
| `HUB_AAVE_ASSET` | Hub Aave reserve asset; default Arbitrum USDC. Zero omits Aave from the Mandate. No Aave on Robinhood. |
| `ARBITRUM_RPC_URL`, `ROBINHOOD_RPC_URL` | Archive RPC provider URLs from helper; never log. Runtime uses these for live reads/transactions. |
| `ARBISCAN_API_KEY` | Explorer verification credential. Arbiscan uses Etherscan-compatible verification. |
| `ALPHA_KEEPER_KEY` | Separate funded runtime signer on both chains; never the Wormhole guardian key. No gas refund assumed. |
| `ALPHA_API_SIGNER_KEY` | Runtime private key matching `API_SIGNER`; fund both chains because `/report` publishes and delivers. |
| `ALPHA_API_TOKEN` | Long random HTTP bearer token; secret manager / hidden prompt. Do not put it in request logs. |

Changing pool tokens/reserve is supported, but **not adding arbitrary assets without pricing them**: the immutable
price source supports only the two chains' WETH (hub ETH/USD feed), USDC and USDG (1:1). The factory checks pricing
at creation. Choose initialized/liquid pools and a listed, usable Aave reserve; check pause/freeze state before any
position is opened. The selected pools are investment venues, not swap venues (swaps use V3 adapters).

### Derived, fixed and operational env vars

| Env / fixed value | Meaning |
|---|---|
| `FUND_FACTORY` | Copy the identical factory address from the two successful deployment logs. Required for creation/checking. |
| `CREATION_NUMBER`, `MANDATE_HASH` | Copy exactly from hub `FundCreated` / CreateFund output, not a spoke's `nextCreationNumber`. Checker requires both. |
| `ARBITRUM_FORK_BLOCK`, `ROBINHOOD_FORK_BLOCK` | Helper pins 511007613 / 78293056 for this rehearsal. Optional helper `*_FORK_BLOCK_OVERRIDE` selects different archive pins. |
| `FOUNDRY_BROADCAST` | Optional private deployment-record directory, separate for each immutable release. Do not stage raw broadcasts/caches. |
| `ALPHA_CORE_VAULT`, `ALPHA_SPOKE_VAULT` | Actual hub Core Vault / actual Robinhood Spoke Vault; not the hub's Spoke Vault. |
| `ALPHA_REPORT_RECEIVER`, `ALPHA_SHARE_TOKEN` | Hub receiver / ShareToken from the hub creation record. |
| `ALPHA_HUB_START_BLOCK`, `ALPHA_SPOKE_START_BLOCK` | Inclusive scanning start blocks, normally respective fund-creation blocks. Never start after an undelivered order/report. |
| `ALPHA_STATE_FILE` | Durable keeper cursor/queue, default relative `.state/alpha-keeper.json` under local-e2e. Use an absolute, access-controlled path; one keeper per file/fund. |
| `ALPHA_VAA_API` | HTTPS signed-VAA service, default `https://api.wormholescan.io/api/v1/vaas`; must serve `(emitterChain, emitterAddress, sequence)`. |
| `ALPHA_POLL_MS` | Poll delay, default 5,000 ms, minimum 1,000. |
| `ALPHA_REPORT_SECONDS` | Periodic safety report, default 300 s, permitted 10..600. A fresh report also follows detected mint/burn; API client triggers synchronous pre/post reports. |
| `ALPHA_API_PORT` | Loopback HTTP port, default 8787. |
| `ALPHA_ALLOW_LOCAL_TEST_KEYS` | **Unset in mainnet**. `1` permits public test keys only when both endpoints identify as Anvil. |
| `ALPHA_LIBRARIES` | Nonsecret JSON map of fully qualified library names to deployed addresses, for verification record extraction. |
| `ALPHA_REHEARSAL_HUB_PORT`, `ALPHA_REHEARSAL_SPOKE_PORT` | Local-only ports, default 18645 / 18646. |
| `LOCAL_E2E_ARBITRUM_PORT`, `LOCAL_E2E_ROBINHOOD_PORT` | Set by rehearsal; legacy harness uses loopback only. Do not use these to configure mainnet. |
| `ALPHA_REHEARSAL_STATE` | Local-only record directory passed by rehearsal to its runtime probe. |

Not env configurable: three salts `keccak256("pool-party.v2.Create3Deployer")`,
`keccak256("pool-party.v2.library")`, `keccak256("pool-party.v2.FundFactory")`; flow fee 25 bps; price maximum
age 3,600 s; spoke report lifetime 1,588 s; hub/spoke number offsets 0 / 1,000,000. Deployment protocol addresses
are constants in `script/FactoryDeployment.sol` (also listed in `docs/INTEGRATIONS.md`). They are checked against
the actual immutable wiring, not taken from an operator's unchecked manifest.

## Exact deployment order

Run from the release worktree root. Keep operator and manager keystores separate. Do not invoke the deploy script
twice on a chain after success: registry/price-source/stores are CREATE deployments, and the fixed factory CREATE3
salt is already occupied. A failed broadcast needs receipt-by-receipt reconciliation, not a blind rerun.

```bash
forge build --sizes
forge fmt --check
forge test --match-path test/size/ContractSizes.t.sol -vv
forge test --no-match-path 'test/{fork/**,review/**/*Fork*}'
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
forge test --match-path 'test/{fork/**,review/**/*Fork*}' -j 4
CI=true pnpm --dir local-e2e install --frozen-lockfile
bash script/rehearse-alpha.sh
```

Then load Rafael's approved nonsecret inputs into the shell explicitly, and unlock the correct keystores:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
test "$(cast chain-id --rpc-url "$ARBITRUM_RPC_URL")" = 42161
test "$(cast chain-id --rpc-url "$ROBINHOOD_RPC_URL")" = 4663
cast balance "$DEPLOYER_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
cast balance "$DEPLOYER_ADDRESS" --rpc-url "$ROBINHOOD_RPC_URL"
cast call 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'balanceOf(address)(uint256)' "$MANAGER" --rpc-url "$ARBITRUM_RPC_URL"
forge script script/DeployFactory.s.sol --rpc-url "$ARBITRUM_RPC_URL" --sender "$DEPLOYER_ADDRESS"
forge script script/DeployFactory.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --sender "$DEPLOYER_ADDRESS"
```

These two are simulations. Compare predicted factory, Create3Deployer, all **three spoke libraries**, and spoke
creation-code hash. The factory must be the same with the same operator/salt; hub registry/price-source may differ
from simulations if operator nonce changes. Core Vault libraries exist only on the hub. Spoke Vault addresses
themselves differ across chains because their salts include the chain id.

**Broadcast hub stack, then spoke stack**, with identical operator and build:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
forge script script/DeployFactory.s.sol --rpc-url "$ARBITRUM_RPC_URL" --account alpha-operator --sender "$DEPLOYER_ADDRESS" --broadcast --slow
forge script script/DeployFactory.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --account alpha-operator --sender "$DEPLOYER_ADDRESS" --broadcast --slow
```

On each chain: wiring validation; hub-only ManagerRegistry and ChainlinkPriceSource; deterministic Create3Deployer;
SpokeCrossChainLib, SpokeUnwindLib, SpokeIncomeLib; hub-only CoreVaultIncomeLogic → CoreVaultLogic →
CoreVaultPayoutLogic → CoreVaultTransitLogic; CodeStores; CREATE3 factory (which creates its TransitEscrow
implementation). Save every actual library address and both creation-code hashes. If any differ unexpectedly,
stop before creating a fund.

Export `FUND_FACTORY` from the successful logs. Dry-run hub creation with the actual manager, inspect predictions
and seed charge, then broadcast. Re-read `nextCreationNumber` just before creation: permissionless creation can
advance it between simulation and broadcast. Do not assume number 1.

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
cast call "$FUND_FACTORY" 'nextCreationNumber()(uint256)' --rpc-url "$ARBITRUM_RPC_URL"
forge script script/CreateFund.s.sol --rpc-url "$ARBITRUM_RPC_URL" --sender "$MANAGER"
forge script script/CreateFund.s.sol --rpc-url "$ARBITRUM_RPC_URL" --account alpha-manager --sender "$MANAGER" --broadcast --slow
```

CreateFund approves the seed and creates the fund; no separate factory allowance transaction is needed. Copy
`CREATION_NUMBER`, `MANDATE_HASH`, fund id and addresses from the successful **hub broadcast event**, export them,
and use **exactly the same pool/fee/cap/minimum/Operating Cash inputs** on Robinhood:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
forge script script/CreateFund.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --sender "$MANAGER"
forge script script/CreateFund.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --account alpha-manager --sender "$MANAGER" --broadcast --slow
forge script script/CheckAlphaDeployment.s.sol --rpc-url "$ARBITRUM_RPC_URL"
forge script script/CheckAlphaDeployment.s.sol --rpc-url "$ROBINHOOD_RPC_URL"
```

Checker has no `startBroadcast`, `send` or write calls: contract reads are `staticcall`, storage reads are `vm.load`.
It rebuilds the approved Mandate with `FundMandate`, compares its hash, checks factory prediction and fixed wiring,
hub registry owner and price source, code at active roles and every CodeStore/library/external integration, stored
creation-code hashes, CodeStore contents, runtime library links, adapter custody/guardian/API signer, receiver and
Core Vault wiring, and ShareToken/ManagerFeeVault CREATE nonce predictions. Factory storage slot 4 for CodeStores
is build-specific; re-check `forge inspect FundFactory storage-layout --json` if the frozen factory layout changes.
Robinhood intentionally has no Core Vault, ShareToken, price source, registry, Aave or Core libraries, so those
addresses are checked on the hub only. The hub's Spoke Vault intentionally has `wormholeCore() == 0`.

The checker detects wiring and linked-address faults; it is not a byte-for-byte runtime authenticity proof against
an adversarial counterfeit contract returning the same getters. Explorer verification plus release codehash
records are required too. It does not require live adapters to be unpaused: it remains useful during an incident.

## Source verification and library linking

**Arbitrum:** Arbiscan / Etherscan-compatible API, chain 42161, `ARBISCAN_API_KEY`.
**Robinhood:** official Blockscout explorer `https://robinhoodchain.blockscout.com`, Etherscan-compatible
Blockscout verification API `https://robinhoodchain.blockscout.com/api/`, chain 4663. No API key is required by the
standard Blockscout Forge workflow. Confirm the actual service on deployment day; do not confuse testnet explorer
`explorer.testnet.chain.robinhood.com` / chain 46630 with mainnet.

Primary sources checked October 2, 2026:
- https://docs.blockscout.com/robinhood-api (official mainnet explorer/API)
- https://docs.blockscout.com/devs/verification/foundry-verification (Forge / Blockscout workflow)
- https://www.getfoundry.sh/reference/forge/verify-contract (constructor/link/verifier flags)
- https://docs.etherscan.io/contract-verification/verify-with-foundry (Etherscan workflow)
- https://wormhole.com/docs/protocol/infrastructure/vaas/ (real signed VAA indexing/retrieval)

Use the **same** Solidity 0.8.28, optimizer 800, Cancun, no via-IR and exact source tree as deployment. Do not rebuild
with new linking flags into the release `out/`: `CreateFund` reads its creation code there. Work in a preserved
verification checkout if explorer commands change artifacts. Verify libraries first: three spoke libraries on
both chains; CoreVaultIncomeLogic, CoreVaultLogic, CoreVaultPayoutLogic, CoreVaultTransitLogic on hub, in that order.
CoreVaultLogic links income; payout links logic/income; transit links all three; Core Vault links all four; Spoke
Vault links all three spoke libraries. Adapters/factory/registry/price source have no external links.

Populate `ALPHA_LIBRARIES` using the actual logs, with **all seven fully qualified names** as JSON keys:
`src/core/CoreVaultLogic.sol:CoreVaultLogic`, `src/core/CoreVaultTransitLogic.sol:CoreVaultTransitLogic`,
`src/core/CoreVaultIncomeLogic.sol:CoreVaultIncomeLogic`, `src/core/CoreVaultPayoutLogic.sol:CoreVaultPayoutLogic`,
`src/spoke/SpokeCrossChainLib.sol:SpokeCrossChainLib`, `src/spoke/SpokeUnwindLib.sol:SpokeUnwindLib`,
`src/spoke/SpokeIncomeLib.sol:SpokeIncomeLib`. It is a public address map, **not keys**.

Extract exact constructor bytes from Forge's retained creation traces, including factory CREATE3 and nested fund
deployments (no guessing constructor arguments of contracts created through proxies):

```bash
node script/alpha-verification.mjs "$FOUNDRY_BROADCAST/DeployFactory.s.sol/42161/run-latest.json" "$FOUNDRY_BROADCAST/CreateFund.s.sol/42161/run-latest.json" > alpha-hub-verification.json
node script/alpha-verification.mjs "$FOUNDRY_BROADCAST/DeployFactory.s.sol/4663/run-latest.json" "$FOUNDRY_BROADCAST/CreateFund.s.sol/4663/run-latest.json" > alpha-spoke-verification.json
node --test script/alpha-verification.test.mjs
```

For each record with `contract`, set `ADDRESS`, `CONTRACT`, `CTOR_ARGS` from that record and a Bash `LINK_ARGS`
array from its `libraries` list (one `--libraries "src/path.sol:Name:0x..."` pair per link). Unlinked contracts use
an empty array; libraries with no constructor use `CTOR_ARGS=0x`:

```bash
forge verify-contract "$ADDRESS" "$CONTRACT" --chain-id 42161 --verifier etherscan --etherscan-api-key "$ARBISCAN_API_KEY" --compiler-version v0.8.28+commit.7893614a --num-of-optimizations 800 --constructor-args "$CTOR_ARGS" "${LINK_ARGS[@]}" --watch
forge verify-contract "$ADDRESS" "$CONTRACT" --chain-id 4663 --verifier blockscout --verifier-url 'https://robinhoodchain.blockscout.com/api/' --compiler-version v0.8.28+commit.7893614a --num-of-optimizations 800 --constructor-args "$CTOR_ARGS" "${LINK_ARGS[@]}" --watch
```

Execute only the command for the record's chain. Check successful verified status on the explorer, not only a
submission GUID. Save the linked-library map and verification receipts with the deployment record. If Blockscout
rejects ABI argument flags, use its standard-JSON browser verifier with the exact linked settings:

```bash
forge verify-contract "$ADDRESS" "$CONTRACT" --chain-id 4663 "${LINK_ARGS[@]}" --show-standard-json-input > alpha-standard-input.json
```

Coverage inventory: Create3Deployer, all applicable linked libraries, ManagerRegistry, ChainlinkPriceSource,
FundFactory, TransitEscrow implementation, hub and spoke adapters/vaults, ValueReportReceiver, ShareToken and
ManagerFeeVault. On the sample: **21 hub + 10 spoke executable contract records**.

CodeStores and one-use CREATE3 proxies are **raw assembly data/proxies**, not deployed Solidity `CodeStore` or
`Create3` library artifacts: do not submit those artifact names to a verifier. Extraction records their raw
creation bytes/address separately; retain these, codehashes and the checker-reassembled role hashes in the
manifest. CodeStore runtime is STOP + data, up to 24,576 bytes (zero margin for a full chunk by design). CREATE3
proxy runtime is 24 bytes. TransitEscrow clones created later are EIP-1167 proxies: record implementation and
clone links separately, not an implementation constructor at each clone address.

## Mainnet alpha keeper and API

Do **not** point `pnpm keeper` / `pnpm api` / `pnpm up` at mainnet: those paths use public Anvil actor keys, replace
guardian sets, edit storage/fund accounts, simulate fills and update oracle state. Instead this branch adds a
separate, loopback-only `local-e2e/src/alpha.ts`, reusing protocol ABIs and the route signature encoding, with real
RPC clients and ephemeral funded keys. It contains no Anvil storage writes, guardian signing, impersonation or
mock fills. It fetches real VAAs, validates them with the destination Wormhole Core, then delivers reports and
executes Hub orders. Third-party Across relayers handle bridging; incident operators handle expired refunds and
late/unlisted arrivals explicitly. No generic refund automation or production settlement orchestration is claimed.

Install with the frozen lockfile; type-check; export the nonsecret runtime variables from the actual deployment.
Inject only the key required by the process (hidden prompt below is **Bash**, not zsh):

```bash
CI=true pnpm --dir local-e2e install --frozen-lockfile
pnpm --dir local-e2e exec tsc --noEmit
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
read -r -s -p 'Funded keeper key: ' ALPHA_KEEPER_KEY; printf '\n'; export ALPHA_KEEPER_KEY
pnpm --dir local-e2e alpha:keeper
```

In a second private shell, source helper, export the same actual fund addresses/start blocks, inject API key/token:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
read -r -s -p 'API signer key: ' ALPHA_API_SIGNER_KEY; printf '\n'; export ALPHA_API_SIGNER_KEY
read -r -s -p 'API bearer token: ' ALPHA_API_TOKEN; printf '\n'; export ALPHA_API_TOKEN
pnpm --dir local-e2e alpha:api
```

Use a supervisor that stops the child on shutdown and restarts the keeper with its same cursor. The keeper scans
**finalized** blocks in bounded batches; delayed finalized visibility is why the deposit client must use the
synchronous API report flow rather than rely on polling alone. Keeper cursor includes the fund identity and a
durable pending VAA queue. Watch transaction receipts, queue growth, report age, chain finality lag, key balances,
failed ticks and Across events. Stale or expired orders require manual inspection; do not discard the queue or
rewind it blindly. Mainnet Wormhole finality/observation latency, report expiry and order deadlines must be proved
compatible before opening positions. No supervisor, alert delivery or service SLA is supplied by this branch.

API (all POST, all `Authorization: Bearer <token>`, no public bind):
- `/report`: publish a Robinhood report, wait for a real signed VAA, validate and deliver it; returns `delivered`
  and `sequence`. Waits up to 30 minutes, but the report expires after 1,588 seconds: a timeout/stale failure means
  stop and publish a fresh report, not proceed with mint/burn. Keeper can discover undelivered publications later.
- `/swap-route`: JSON `{side: "hub"|"spoke", tokenIn, tokenOut, amountIn: "base-units", maxLossBps: 1..500}`.
  Quotes direct Uniswap V3 pools at 100/500/3000/10000, picks best output, signs the immutable fund adapter's EIP-712
  domain. Returns adapter, encoded route, minimum output and deadline. Zero max loss is refused (on-chain zero
  means no bound). Only Mandate endpoints accepted; direct V3 routes only, not Trading API/two-hop optimization.

This is intentionally smaller than the ordinary development API: no public deposit endpoint, automatic money
movement, Share Price history or frontend service. Internal operators call contracts with keystores. Enforce
reports **before and after** mint/burn; API signer doubles as registry owner by default, so isolate that host.
Registry ownership can be transferred by its contract but this does not rotate immutable route signers. API
rotation needs new factory/fund deployment (DEC-170).

## Post-deployment smoke (mainnet)

Do not use `alpha:rehearsal` on mainnet. Use small Pool Party wallet balances and actual release addresses.
The seed exists already. Keep funds in Idle; no investment/bridge allocation until the VAA/Across gates pass.

1. Start keeper/API. Call `/report`, wait for `delivered: true`; confirm receiver sequence and a live price source.
2. Use manager wallet for a tiny **2 USDC budget** deposit; a 1 USDC budget fails `DepositBelowOneShare` at the
   initial Share Price after the 25 bps flow fee. A new shareholder's first deposit must meet the Mandate minimum.
3. Call `/report` immediately after deposit. Check minted shares, actual USDC debit, flow fee to Protocol Recipient,
   Idle, Share Assets, Share Price, Operating Cash zero and receiver sequence. Do not assume budget = charged amount.
4. Call `/report` again immediately before a 1 USDC Instant Payout; keep manager holdings well above half its peak
   (DEC-127/146/147). Call `requestPayout(1000000,0)`; Instant is enum 0 and claims immediately. If the frozen ABI
   has changed, regenerate ABIs and follow the new payout arguments rather than broadcasting the old selector.
5. Call `/report` immediately after burn. Confirm actual USDC payment, ShareToken burn, Payout Fee, no unexpected
   Payout Reserve / In-flight Value, report accepted and fund still Open. No unwind is expected for an Idle-only
   smoke. Standard Payout is enum 1: request then `claimPayout(bytes)` only after its term ends, with a fresh report.

Example calls (Bash; keep bearer token out of process command arguments by passing curl config on stdin):

```bash
printf 'header = "Authorization: Bearer %s"\n' "$ALPHA_API_TOKEN" | curl --config - --fail-with-body -X POST "http://127.0.0.1:${ALPHA_API_PORT:-8787}/report"
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
cast send 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'approve(address,uint256)' "$ALPHA_CORE_VAULT" 2000000 --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"
cast call "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 2000000 1 --from "$MANAGER" --rpc-url "$ARBITRUM_RPC_URL"
cast send "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 2000000 1 --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"
# /report after deposit, then /report immediately before payout (same authenticated call as above).
cast send "$ALPHA_CORE_VAULT" 'requestPayout(uint256,uint8)' 1000000 0 --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"
# /report after burn; check the receipt and state, not only transaction submission.
cast call "$ALPHA_CORE_VAULT" 'idle()(uint256)' --rpc-url "$ARBITRUM_RPC_URL"
cast call "$ALPHA_CORE_VAULT" 'fundState()(uint8)' --rpc-url "$ARBITRUM_RPC_URL"
cast call "$ALPHA_REPORT_RECEIVER" 'lastReportSequence(uint256)(uint64)' 0 --rpc-url "$ARBITRUM_RPC_URL"
```

For bridging after smoke, simulate `quoteSend` from the actual adapter and `sendToSpoke(0,amount,0,0x)` from the
Manager, inspect the fixed adapter terms, then broadcast only an approved tiny amount. Caller cannot set the
bridge fee; no signed Across quote (DEC-158/162/176). Track `FundsDeposited` to `FilledRelay` by full relay data,
not only `transitId`. Report after arrival. Do not treat a pending/refundable transfer as a successful allocation.

## Pause, rollback and recovery

There is **no global factory/fund pause or upgrade rollback**. Immutables and CREATE3 salts cannot be overwritten.
Before transactions: cancel and fix inputs. After partial stack broadcast: stop, preserve receipts/nonces/code,
reconcile which steps succeeded; `--resume` only on the saved, reviewed broadcast with the exact signer/build.
Do not blindly resume a fund creation: seed approval/creation and concurrent creation numbers need reconciliation.
Wrong immutable wiring or leaked route signer requires a new deployment with a **new operator address** under the
existing constant salt (or a separately reviewed salt change); a new build alone does not free the old factory salt.

Guardian incident action, **each actual adapter on both chains**, using the appropriate RPC (derive addresses
from factory `addressOf(fundId,role,chainId)` and the manifest; never pause an integration protocol globally):

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
cast send "$ADAPTER" 'setPaused(bool)' true --account alpha-guardian --rpc-url "$CHAIN_RPC"
cast call "$ADAPTER" 'paused()(bool)' --rpc-url "$CHAIN_RPC"
# Only after root cause/review: reversible quarantine release.
cast send "$ADAPTER" 'setPaused(bool)' false --account alpha-guardian --rpc-url "$CHAIN_RPC"
# Irreversible retirement, separate explicit approval:
cast send "$ADAPTER" 'deprecate()' --account alpha-guardian --rpc-url "$CHAIN_RPC"
cast call "$ADAPTER" 'deprecated()(bool)' --rpc-url "$CHAIN_RPC"
```

Pause/deprecation blocks risk-increasing entries; exits/collection remain usable, and V3 swaps into base token
remain usable. This **does not block Core Vault deposits**. Remove API access and stop operator deposits/allocations;
retain safe reporting/relay while unwinding. Do not pause a required exit blindly. Preserve receipt/log evidence.
For Across expiries, `attestExpiry`, `recognizeRefund` and unlisted arrival recovery are operator procedures after
checking origin/destination evidence and balances; the alpha runtime does not fabricate proofs or fund refunds.

Manager `closeFund()` is irreversible; do not use it as a temporary pause. On this baseline closure is incomplete:
fund could remain Closing, so the release gate requires full closure implementation/e2e before relying on it as a
recovery path. No third-party wallet onboarding, fund migration or reverse deployment is provided. On shutdown,
Ctrl-C each foreground service/supervisor, verify owned PIDs exited, unset signer env vars; never kill another
session's nodes. `rehearse-alpha.sh` traps exit and stops only its two owned Anvil processes.

For a refund incident, use the specific origin chain and independently identified transit id; first simulate,
then broadcast only after the documented expiry/refund evidence is confirmed:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
cast call "$ALPHA_CORE_VAULT" 'attestExpiry(bytes32)' "$TRANSIT_ID" --from "$KEEPER_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
cast send "$ALPHA_CORE_VAULT" 'attestExpiry(bytes32)' "$TRANSIT_ID" --account alpha-keeper --rpc-url "$ARBITRUM_RPC_URL"
cast call "$ALPHA_CORE_VAULT" 'recognizeRefund(bytes32)(uint256)' "$TRANSIT_ID" --from "$KEEPER_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
cast send "$ALPHA_CORE_VAULT" 'recognizeRefund(bytes32)' "$TRANSIT_ID" --account alpha-keeper --rpc-url "$ARBITRUM_RPC_URL"
# A spoke-origin refund uses the actual spoke vault and Robinhood RPC, not the hub Core Vault.
```

`TRANSIT_ID`, `ADAPTER`, `CHAIN_RPC`, `KEEPER_ADDRESS`, `ADDRESS`, `CONTRACT`, `CTOR_ARGS` and `LINK_ARGS` in the
examples are temporary operator shell variables derived from the verified manifest/incident/verification record;
they are not deployment-script configuration. Fund `alpha-keeper` keystore if manual keeper calls are necessary.

## Recorded fork rehearsal (no secrets)

Executed the complete `bash script/rehearse-alpha.sh` successfully after checker/pool changes. Fresh, private
127.0.0.1 ports 18645/18646; archive pins 511007613/78293056; public throwaway Anvil operator account 0, manager
account 1, API signer account 8, guardian operator, Protocol Recipient account 6. Keys and RPC URLs intentionally
omitted. Manager fork USDC balance was set to 1,000 USDC using the harness's storage-layout discovery (slot 9);
never do that on mainnet. Both deployments use the same three fixed salts and build.

| Item | Output |
|---|---|
| Both FundFactory addresses | `0x408EBd63EC5DdB000471452253A73DB682590E5c` |
| Both Create3Deployers | `0x1Da47CED247a6776329281836600283b033f8e41` |
| Both SpokeCrossChainLibs | `0x94d4B7223cb376d5A32e0Bc59E95960A305eE1Cc` |
| Both SpokeUnwindLibs | `0x2e20dAEe66E950cF3934f2756f3dC5444A6d7eec` |
| Both SpokeIncomeLibs | `0xD3E194bEc5AFc41CDB52863547fD4fD4d38Ca770` |
| Hub CoreVaultIncomeLogic | `0xA9FB4eb1A3dbadF3FAE078770eE5707F3d7E35ee` |
| Hub CoreVaultLogic | `0x5aF35C02C9EC2c8956636F8D605054861dAB9169` |
| Hub CoreVaultPayoutLogic | `0x4EE363FE44958c74008B317D169d5F408e1fA0fB` |
| Hub CoreVaultTransitLogic | `0xC8613F53930699dB7846D1C6d2E946A386641659` |
| Hub registry / price source | `0x19b3317E15d2202639510992C13591bAd1E3365F` / `0xaDB9cFAd43287840EA1cf21C633b6f6E45Ffd348` |
| Both TransitEscrow implementations (same factory nonce) | `0x173f041905C82c6Caa459916610358FBEf6FbE6D` |
| Spoke Vault creation-code hash, both | `0x2882c6f46db5f444e916715b61fc44011bc22a9cc0adb5ebcac1f02d3686b5d5` |
| Hub Core Vault creation-code hash | `0xece5dd78b2024be9de0a6b772ab0379bc12787314f2ddccef076e63b102ebd11` |
| Creation number / seed budget | 1 / 100,000,000 USDC base units |
| Mandate hash | `0xcc0dc347e672cd65b6b2427a256cc15233ab28293ffa39587fb19ec513e42886` |
| Fund id | `0x6bd990bc05fc4bf19028b0f0c47cd6fac1f9d221fb076c2699dae83d90d185bf` |
| Core Vault | `0x3D010D998E19d52CE7be47021a3000e3eAa12F8E` |
| ShareToken / ManagerFeeVault | `0xd2982AA13aA39b7ABA2c0C8019B0532Aa654c431` / `0xDBa9415D84a97BC7DbAa240Caf891B67aEBdfF7b` |
| ValueReportReceiver | `0xF90640a43acf3F7443fCf01891f1C9772A560b54` |
| Hub Spoke Vault | `0x70660b467e9cB79bEE9e9f12050a1083Fe3FBEcD` |
| Robinhood Spoke Vault, predicted = actual | `0x3a0Ef4d68EDDd9821593472ac84a75741bBcf3cf` |
| Hub V4 / Aave adapters | `0x3b1D5Cc737cD2DF4c1320050e5324C2d589b3E4E` / `0xB599d5fB0a75C122fde4a47b2aF11BB5BCeF3D65` |
| Hub V3 / Across adapters | `0x85021221cd17D5E003380290B1A22290EDD6e518` / `0xad4F63f668b3742134446cac889B793D7a403937` |
| Robinhood V4 / V3 / Across adapters | `0x4308332805BCC727a7117B156aF14Dbe288915E2` / `0x5be6f4881bEb2bd5E3d7a6ef4c6011a32b8DB7fe` / `0xC10Aa9BdAe907e6D9376b0bb88dd093fe3239e28` |
| Checks | `ALPHA CHECK PASS chain 42161`, `ALPHA CHECK PASS chain 4663` |

The default V4 pool ids are hub `0xfc7b3ad139daaf1e9c3637ed921c154d1b04286f8a82b805a6c352da57028653`
and spoke `0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593`; Aave reserve is hub USDC;
Spoke Cap 10,000 USDC; performance 20%; management 0%; Operating Cash 0.

| Operation | Actual execution gas / result |
|---|---|
| DeployFactory hub / spoke | 41,797,928 (18 tx) / 26,245,639 (10 tx) |
| CreateFund hub / spoke | 24,420,014 (2 tx incl approval) / 12,758,190 (1 tx) |
| Tiny deposit | budget 2 USDC, actual charged 1.005 USDC, 1 share minted; gas 274,531; receipt success |
| Deposit tx | `0x9d35e3b602aff26b32d1d92cd02830ab6f0d2944f1efe1ef728e9956dd47e061` |
| Report publication tx | `0x05c4dde65b046e0b0dbccd3f7f261eb30e47298b65782eebe9f13c44fed9d639` |
| Report delivery tx | `0x136676f879b2041c3fb508e3a2695a58f0a204489ed406ebc7e8936bf90ba7d8` |
| 1 USDC Instant Payout tx | `0xc9f91c1647c96f8e0d5e60d190f229c550a45a28ad8ee69cc4887b92d2e565c5`; gas 371,052; final Idle 100,000,000 |
| Alpha runtime probe | 5 API checks (401, both-chain signed routes, both zero-loss refusals); funded keeper startup, report publication and durable cursor passed |

An initial Arbitrum deployment attempt hit archive `eth_feeHistory` missing metadata; no transactions had been
broadcast. Rehearsal uses `--legacy --with-gas-price 100000000` (0.1 gwei) for both chains, not a mainnet gas-price
recommendation. Another test deliberately tried 1 USDC and confirmed `DepositBelowOneShare`; successful 2 USDC
budget deposited only the rounded whole-share charge. Final smoke overrides Wormhole guardian sets **on forks
only**, signs locally and delivers a VAA: external mainnet guardian observation, VAA service reliability, Across
fills/refunds, explorer verification and full future unwind/closure scenario remain release gates. Fork traces,
broadcasts and cursor are untracked under `local-e2e/.state/alpha-rehearsal`; no process remains running.

## Validation and runtime sizes

Green on this branch: `forge build --sizes`; `forge fmt --check`; size suite **3/3**; non-fork **1,178/1,178
in 167 suites**; fork **217/217 in 52 suites** (`-j 4`, includes new two-fork checker test); alpha checker **5
unit + 1 fork**; verification extractor **1 Node test**; TypeScript type-check; full scripted private-fork
rehearsal and runtime probe. No shared fork fixture changes, no `_createForks()` caller added, so no CI scenario
shard change is required. Node typings added to make the existing harness type-check as well as the new runtime.

Production bytes before = after (no `src/` change), limit 24,576:

| Contract / linked library | Bytes | Margin |
|---|---:|---:|
| AaveV3Adapter | 10,158 | 14,418 |
| AcrossBridgeAdapter | 6,713 | 17,863 |
| UniswapV3SwapAdapter | 10,586 | 13,990 |
| UniswapV4Adapter | 18,079 | 6,497 |
| CoreVault | 20,996 | 3,580 |
| ManagerFeeVault | 1,077 | 23,499 |
| ManagerRegistry | 1,603 | 22,973 |
| ShareToken | 1,822 | 22,754 |
| TransitEscrow | 894 | 23,682 |
| Create3Deployer | 1,342 | 23,234 |
| FundFactory | 18,347 | 6,229 |
| ChainlinkPriceSource | 1,709 | 22,867 |
| ValueReportReceiver | 8,080 | 16,496 |
| SpokeVault | 22,304 | 2,272 |
| CoreVaultLogic | 13,739 | 10,837 |
| CoreVaultTransitLogic | 14,227 | 10,349 |
| CoreVaultIncomeLogic | 5,929 | 18,647 |
| CoreVaultPayoutLogic | 9,098 | 15,478 |
| SpokeCrossChainLib | 11,904 | 12,672 |
| SpokeUnwindLib | 10,985 | 13,591 |
| SpokeIncomeLib | 698 | 23,878 |

No executable production margin below 1,000 bytes. **Full CodeStore data chunks have 0-byte margin**, intentionally
at EIP-170 maximum; do not increase their chunk size. New scripts/helpers are off-chain only.
