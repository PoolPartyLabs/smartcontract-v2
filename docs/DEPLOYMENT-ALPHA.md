# Internal alpha deployment — DEC-134

Final B-04 measured baseline: **October 3, 2026**, `origin/main` `f171dc6`, including **PR #30 / DEC-145**
(merged through `6395173`; waiting lots/resumable checkpoints, max-config peak 2.04M gas).
The final alpha-sized rehearsal and full lifecycle replay pass on this production build. Historical rehearsal sections retain their original SHAs/counts; current tests and sizes are in
the [founder report](reports/2026-10-03-MVP-REPORT.md). Arbitrum One is the Hub Chain
(EVM 42161 / Wormhole 23); Robinhood Chain is the Spoke Chain (EVM 4663 / Wormhole 72).
**Mainnet internal alpha deployed October 3, 2026 from release `797d592`.** Addresses, receipt-derived costs,
verification and measured smoke outcomes are in the [mainnet deployment record](reports/2026-10-03-MVP-REPORT.md#mainnet-alpha-deployment).
The B-04 figures below remain historical rehearsal evidence. This operator runbook is **not authorization for
additional broadcasts or public capital**; preserve the frozen deployment artifacts and require explicit approval.

## Release gates

1. Freeze an independently reviewed commit. DEC-145 PR #30, unwind/income/closure are merged, including
   #28 conformance fixes and #29 report v5/all-kind acknowledgements. #24's full lifecycle and #29's integrated
   replay and the final B-04 post-#30 rehearsal are committed evidence. Re-run if production code changes: library addresses and creation
   code hashes depend on the build. WP-17 is deferred by Rafael. G-02/G-03/G-04/G-06/G-07 remain accepted only
   for alpha; see [KNOWN-LIMITATIONS](security/KNOWN-LIMITATIONS.md).
2. Pass `bash script/alpha-safe.sh forge build --sizes`, `bash script/alpha-safe.sh forge fmt --check`, the size suite, all non-fork and all fork tests, and the final
   `local-e2e` scenario/API probe required by HANDOFF section 6. B-04 also reran that scenario: 57 steps / 330 assertions, API 31 concepts.
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

For **every fork test, bash script/alpha-safe.sh cast call or runtime start**, source the RPC helper in the **same shell invocation**:

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
| `MANAGER`; manager keystore | Only the wallet that creates the first (smoke-test) fund, not a deployment manager list or registration input. Same address signs hub and spoke creation. Holds hub USDC seed and ETH on both chains. Manager pays own gas (DEC-187). |
| `PERFORMANCE_FEE_BPS` | Manager-selected 1,000..9,000 inclusive (10..90%); default 2,000. |
| `MANAGEMENT_FEE_BPS` | Annual manager-selected 0..500 inclusive (0..5%); default 0, DEC-186. |
| `SPOKE_CAP` | Maximum spoke principal including In-flight Value, in hub USDC base units (6 decimals); set `100000000` = 100 USDC for alpha. Not a fund-wide TVL cap. |
| `SEED_AMOUNT` | Creation seed budget in USDC base units; defaults to `MIN_FIRST_DEPOSIT`. Must meet that minimum. Whole-share rounding means actual charged amount can be lower than budget; inspect receipt. |
| `MIN_FIRST_DEPOSIT` | Minimum first deposit/seed budget, USDC base units; set `2000000` = 2 USDC for alpha. Later deposits still need at least one whole share after fees. |
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
| `FOUNDRY_BROADCAST` | Required absolute private deployment-record directory, defined before deployment; separate for each immutable release. Do not stage raw broadcasts/caches. |
| `ALPHA_CORE_VAULT`, `ALPHA_SPOKE_VAULT` | Actual hub Core Vault / actual Robinhood Spoke Vault; not the hub's Spoke Vault. |
| `ALPHA_REPORT_RECEIVER`, `ALPHA_SHARE_TOKEN` | Hub receiver / ShareToken from the hub creation record. |
| `ALPHA_HUB_START_BLOCK`, `ALPHA_SPOKE_START_BLOCK` | Inclusive scanning start blocks, normally respective fund-creation blocks. Never start after an undelivered order/report. |
| `ALPHA_STATE_FILE` | Durable keeper cursor/queue, default relative `.state/alpha-keeper.json` under local-e2e. Use an absolute, access-controlled path; one keeper per file/fund. |
| `ALPHA_VAA_API` | HTTPS signed-VAA service, default `https://api.wormholescan.io/api/v1/vaas`; must serve `(emitterChain, emitterAddress, sequence)`. |
| `ALPHA_POLL_MS` | Poll delay, default 5,000 ms, minimum 1,000. |
| `ALPHA_REPORT_SECONDS` | Periodic safety report, default 300 s, permitted 10..600. A fresh report also follows detected mint/burn; API client triggers synchronous pre/post reports. |
| `ALPHA_API_PORT` | Loopback HTTP port, default 8787. |
| `ALPHA_ALLOW_LOCAL_TEST_KEYS` | **Unset in mainnet**. `1` permits public test keys only when both endpoints identify as Anvil. |
| `ALPHA_REHEARSAL_LOCAL_VAA` | **Unset in mainnet**. `1` substitutes locally signed VAAs and scans latest blocks; requires test-key mode and two loopback Anvil nodes. Never proves guardian service or finality latency. |
| `ALPHA_LIBRARIES` | Nonsecret JSON map of fully qualified library names to deployed addresses, for verification record extraction. |
| `ALPHA_REHEARSAL_HUB_PORT`, `ALPHA_REHEARSAL_SPOKE_PORT` | Local-only ports, default 18645 / 18646. |
| `ALPHA_REHEARSAL_API_PORT` | Local-only API port, default 18787; all three ports must be unused. |
| `LOCAL_E2E_ARBITRUM_PORT`, `LOCAL_E2E_ROBINHOOD_PORT` | Set by rehearsal; legacy harness uses loopback only. Do not use these to configure mainnet. |
| `ALPHA_REHEARSAL_STATE` | Local-only record directory passed by rehearsal to its runtime probe. |

Not env configurable: three salts `keccak256("pool-party.v2.Create3Deployer")`,
`keccak256("pool-party.v2.library")`, `keccak256("pool-party.v2.FundFactory")`; flow fee 25 bps; price maximum
age 3,600 s; spoke report lifetime 1,588 s; hub/spoke number offsets 0 / 1,000,000. Deployment protocol addresses
are constants in `script/FactoryDeployment.sol` (also listed in `docs/INTEGRATIONS.md`). They are checked against
the actual immutable wiring, not taken from an operator's unchecked manifest.

## Exact deployment order

Run from the release worktree root. For Rafael's approved alpha, `alpha-operator` and `alpha-manager` refer to the
same signing address; API signer, keeper, adapter guardian and Protocol Recipient use that address too. The second
investor is separate. Do not invoke the deploy script
twice on a chain after success: registry/price-source/stores are CREATE deployments, and the fixed factory CREATE3
salt is already occupied. A failed broadcast needs receipt-by-receipt reconciliation, not a blind rerun.

Every Foundry command uses `bash script/alpha-safe.sh`: stdout **and** stderr are redacted before display,
command substitution or disk logging, preserving failure status. URL userinfo, paths, queries and fragments are
removed. Never enable shell tracing or bypass the wrapper for private RPCs.

```bash
bash script/alpha-safe.sh forge build --sizes
bash script/alpha-safe.sh forge fmt --check
bash script/alpha-safe.sh forge test --match-path test/size/ContractSizes.t.sol -vv
bash script/alpha-safe.sh forge test --no-match-path 'test/{fork/**,review/**/*Fork*}'
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh forge test --match-path 'test/{fork/**,review/**/*Fork*}' -j 4
CI=true pnpm --dir local-e2e install --frozen-lockfile
bash script/rehearse-alpha.sh
```

Then load Rafael's approved nonsecret inputs into the shell explicitly, and unlock the correct keystores:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
export ALPHA_RECORD_DIR="$PWD/local-e2e/.state/mainnet-$(git rev-parse --short HEAD)"
export FOUNDRY_BROADCAST="$ALPHA_RECORD_DIR/broadcast"
mkdir -p "$FOUNDRY_BROADCAST"
chmod 700 "$ALPHA_RECORD_DIR"
export MIN_FIRST_DEPOSIT=2000000 SEED_AMOUNT=5000000 SPOKE_CAP=100000000
export ALPHA_DEPOSIT_AMOUNT=5000000 ALPHA_SEND_AMOUNT=5000000 ALPHA_PAYOUT_AMOUNT=1000000
export ALPHA_AAVE_AMOUNT=1000000 ALPHA_INVESTOR_DEPOSIT=5000000 ALPHA_MIN_COLLECT_USDC=500000
test "$(bash script/alpha-safe.sh cast chain-id --rpc-url "$ARBITRUM_RPC_URL")" = 42161
test "$(bash script/alpha-safe.sh cast chain-id --rpc-url "$ROBINHOOD_RPC_URL")" = 4663
bash script/alpha-safe.sh cast balance "$DEPLOYER_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast balance "$DEPLOYER_ADDRESS" --rpc-url "$ROBINHOOD_RPC_URL"
bash script/alpha-safe.sh cast call 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'balanceOf(address)(uint256)' "$MANAGER" --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh forge script script/DeployFactory.s.sol --rpc-url "$ARBITRUM_RPC_URL" --sender "$DEPLOYER_ADDRESS"
bash script/alpha-safe.sh forge script script/DeployFactory.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --sender "$DEPLOYER_ADDRESS"
```

These two are simulations. Compare predicted factory, Create3Deployer, all **four spoke libraries**, and spoke
creation-code hash. The factory must be the same with the same operator/salt; hub registry/price-source may differ
from simulations if operator nonce changes. Core Vault libraries exist only on the hub. Spoke Vault addresses
themselves differ across chains because their salts include the chain id.

**Broadcast hub stack, then spoke stack**, with identical operator and build:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh forge script script/DeployFactory.s.sol --rpc-url "$ARBITRUM_RPC_URL" --account alpha-operator --sender "$DEPLOYER_ADDRESS" --broadcast --slow > alpha-deploy-hub.log
bash script/alpha-safe.sh forge script script/DeployFactory.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --account alpha-operator --sender "$DEPLOYER_ADDRESS" --broadcast --slow > alpha-deploy-spoke.log
export FUND_FACTORY=$(sed -n 's/^  FundFactory //p' alpha-deploy-hub.log | tail -1)
test -n "$FUND_FACTORY"
test "$FUND_FACTORY" = "$(sed -n 's/^  FundFactory //p' alpha-deploy-spoke.log | tail -1)"
```

On each chain: wiring validation; hub-only ManagerRegistry and ChainlinkPriceSource; deterministic Create3Deployer;
SpokeCrossChainLib → SpokeUnwindLib → SpokeCloseLib, then SpokeIncomeLib (linked to SpokeCrossChainLib);
hub-only CoreVaultIncomeCollectionLogic → CoreVaultIncomeLogic → CoreVaultLogic →
CoreVaultPayoutLogic → CoreVaultClosureLogic → CoreVaultTransitLogic; CodeStores; CREATE3 factory (which creates its TransitEscrow
implementation). Save every actual library address and both creation-code hashes. If any differ unexpectedly,
stop before creating a fund.

There is **no manager list or manager registration at deploy**. `createFund` is permissionless (DEC-001): managers
appear as they create funds. The ManagerRegistry gives any manager without an entry the default **50% protocol
slice of the manager fee** (DEC-052/106). The API signer may set a manager-specific **5–50% protocol slice later**
(DEC-112); this is optional and is not a prerequisite for creating the smoke-test fund. `MANAGER` below selects
only that fund's creator wallet, not an approved or registered manager.

Export `FUND_FACTORY` from the successful logs. Dry-run hub creation with the smoke-test fund's creator, inspect predictions
and seed charge, then broadcast. Re-read `nextCreationNumber` just before creation: permissionless creation can
advance it between simulation and broadcast. Do not assume number 1.

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh cast call "$FUND_FACTORY" 'nextCreationNumber()(uint256)' --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh forge script script/CreateFund.s.sol --rpc-url "$ARBITRUM_RPC_URL" --sender "$MANAGER"
bash script/alpha-safe.sh forge script script/CreateFund.s.sol --rpc-url "$ARBITRUM_RPC_URL" --account alpha-manager --sender "$MANAGER" --broadcast --slow > alpha-create-hub.log
export CREATION_NUMBER=$(sed -n 's/^  CREATION_NUMBER //p' alpha-create-hub.log)
export MANDATE_HASH=$(sed -n '/^  MANDATE_HASH/{n;s/^  //;p;}' alpha-create-hub.log)
export ALPHA_CORE_VAULT=$(sed -n 's/^  Core Vault //p' alpha-create-hub.log)
export ALPHA_SPOKE_VAULT=$(sed -n 's/^  Robinhood Spoke Vault (predicted) //p' alpha-create-hub.log)
export ALPHA_REPORT_RECEIVER=$(sed -n 's/^  ValueReportReceiver //p' alpha-create-hub.log)
export ALPHA_SHARE_TOKEN=$(sed -n 's/^  ShareToken //p' alpha-create-hub.log)
export ALPHA_HUB_SPOKE_VAULT=$(sed -n 's/^  hub Spoke Vault //p' alpha-create-hub.log)
test -n "$CREATION_NUMBER" && test -n "$MANDATE_HASH" && test -n "$ALPHA_CORE_VAULT"
```

CreateFund approves the seed and creates the fund; no separate factory allowance transaction is needed. Copy
`CREATION_NUMBER`, `MANDATE_HASH`, fund id and addresses from the successful **hub broadcast event**, export them,
and use **exactly the same pool/fee/cap/minimum/Operating Cash inputs** on Robinhood:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh forge script script/CreateFund.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --sender "$MANAGER"
bash script/alpha-safe.sh forge script script/CreateFund.s.sol --rpc-url "$ROBINHOOD_RPC_URL" --account alpha-manager --sender "$MANAGER" --broadcast --slow > alpha-create-spoke.log
export ALPHA_HUB_START_BLOCK=$(jq -r '[.receipts[].blockNumber | if startswith("0x") then .[2:] | explode | reduce .[] as $char (0; . * 16 + (if $char >= 97 then $char - 87 else $char - 48 end)) else tonumber end] | min' "$FOUNDRY_BROADCAST/CreateFund.s.sol/42161/run-latest.json")
export ALPHA_SPOKE_START_BLOCK=$(jq -r '[.receipts[].blockNumber | if startswith("0x") then .[2:] | explode | reduce .[] as $char (0; . * 16 + (if $char >= 97 then $char - 87 else $char - 48 end)) else tonumber end] | min' "$FOUNDRY_BROADCAST/CreateFund.s.sol/4663/run-latest.json")
export ALPHA_STATE_FILE="$ALPHA_RECORD_DIR/keeper.json"
bash script/alpha-safe.sh forge script script/CheckAlphaDeployment.s.sol --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh forge script script/CheckAlphaDeployment.s.sol --rpc-url "$ROBINHOOD_RPC_URL"
```

Checker has no `startBroadcast`, `send` or write calls: contract reads are `staticcall`, storage reads are `vm.load`.
It rebuilds the approved Mandate with `FundMandate`, compares its hash, checks factory prediction and fixed wiring,
hub registry owner and price source, code at active roles and every CodeStore/library/external integration, stored
creation-code hashes, CodeStore contents, runtime library links, adapter custody/guardian/API signer, receiver and
Core Vault wiring, and ShareToken/ManagerFeeVault CREATE nonce predictions. Factory storage slot 4 for CodeStores
is build-specific; re-check `bash script/alpha-safe.sh forge inspect FundFactory storage-layout --json` if the frozen factory layout changes.
Robinhood intentionally has no Core Vault, ShareToken, price source, registry, Aave or Core libraries, so those
addresses are checked on the hub only. The hub's Spoke Vault intentionally has `wormholeCore() == 0`.

The checker detects wiring and linked-address faults; it is not a byte-for-byte runtime authenticity proof against
an adversarial counterfeit contract returning the same getters. Explorer verification plus release codehash
records are required too. It does not require live adapters to be unpaused: it remains useful during an incident.

## Source verification and library linking

**Arbitrum:** Arbiscan / Etherscan-compatible API, chain 42161, `ARBISCAN_API_KEY`.
**Robinhood:** chain 4663, verification through **Sourcify** (`--verifier sourcify`); matches are imported by the
Robinhood Blockscout explorer. On October 3 the public Blockscout API returned Cloudflare 403/challenges,
while its PRO API required a key. Do not rely on the previously proposed keyless Blockscout endpoint.
Recorded successful coverage is **24/24 Arbitrum and 11/11 Robinhood**, excluding raw CodeStores/CREATE3 proxies.
Do not confuse testnet chain 46630 with mainnet.

Primary sources checked October 2, 2026:
- https://docs.blockscout.com/robinhood-api (official mainnet explorer/API)
- https://docs.blockscout.com/devs/verification/foundry-verification (Forge / Blockscout workflow)
- https://www.getfoundry.sh/reference/forge/verify-contract (constructor/link/verifier flags)
- https://docs.etherscan.io/contract-verification/verify-with-foundry (Etherscan workflow)
- https://wormhole.com/docs/protocol/infrastructure/vaas/ (real signed VAA indexing/retrieval)

Use the **same** Solidity 0.8.28, optimizer 800, Cancun, no via-IR and exact source tree as deployment. Do not rebuild
with new linking flags into the release `out/`: `CreateFund` reads its creation code there. Work in a preserved
verification checkout if explorer commands change artifacts. Verify libraries first in the deployment order
above: four spoke libraries on both chains and six Core Vault libraries on the hub. Core Vault links all six;
Spoke Vault links all four. Nested links are extracted from artifacts, not a hand-written subset.
Adapters/factory/registry/price source have no external links.

Populate `ALPHA_LIBRARIES` using the actual logs, with **all ten fully qualified names** as JSON keys:
`src/core/CoreVaultLogic.sol:CoreVaultLogic`, `src/core/CoreVaultTransitLogic.sol:CoreVaultTransitLogic`,
`src/core/CoreVaultIncomeLogic.sol:CoreVaultIncomeLogic`, `src/core/CoreVaultPayoutLogic.sol:CoreVaultPayoutLogic`,
`src/spoke/SpokeCrossChainLib.sol:SpokeCrossChainLib`, `src/spoke/SpokeUnwindLib.sol:SpokeUnwindLib`,
`src/spoke/SpokeIncomeLib.sol:SpokeIncomeLib`,
`src/spoke/SpokeCloseLib.sol:SpokeCloseLib`,
`src/core/CoreVaultIncomeCollectionLogic.sol:CoreVaultIncomeCollectionLogic`,
`src/core/CoreVaultClosureLogic.sol:CoreVaultClosureLogic`. It is a public address map, **not keys**.

Extract exact constructor bytes from Forge's retained creation traces, including factory CREATE3 and nested fund
deployments (no guessing constructor arguments of contracts created through proxies):

```bash
export ALPHA_LIBRARIES=$(bash script/alpha-safe.sh node script/alpha-libraries.mjs alpha-deploy-hub.log)
node script/alpha-verification.mjs "$FOUNDRY_BROADCAST/DeployFactory.s.sol/42161/run-latest.json" "$FOUNDRY_BROADCAST/CreateFund.s.sol/42161/run-latest.json" > alpha-hub-verification.json
node script/alpha-verification.mjs "$FOUNDRY_BROADCAST/DeployFactory.s.sol/4663/run-latest.json" "$FOUNDRY_BROADCAST/CreateFund.s.sol/4663/run-latest.json" > alpha-spoke-verification.json
node --test script/alpha-verification.test.mjs
```

Run the complete verification loop for both chains. It derives address/artifact/constructor bytes and every nested
link from the inventories, orders libraries before dependants, refuses unknown/missing records and requires
successful verified status, not merely a GUID:

```bash
bash script/alpha-safe.sh node script/alpha-verify-all.mjs 42161 alpha-hub-verification.json "$ALPHA_RECORD_DIR/verified-hub"
bash script/alpha-safe.sh node script/alpha-verify-all.mjs 4663 alpha-spoke-verification.json "$ALPHA_RECORD_DIR/verified-spoke"
jq -e '.verified | length == 24' "$ALPHA_RECORD_DIR/verified-hub/coverage.json"
jq -e '.verified | length == 11' "$ALPHA_RECORD_DIR/verified-spoke/coverage.json"
```

The exact Robinhood inventory command against the preserved mainnet records is:

```bash
bash script/alpha-safe.sh node script/alpha-verify-all.mjs 4663 "$ALPHA_RECORD_DIR/alpha-spoke-verification.json" "$ALPHA_RECORD_DIR/verified-spoke"
```

It verifies linked dependencies first and invokes each artifact with this command shape (the inventory supplies
the exact constructor arguments and any repeated `--libraries` flags):

```bash
bash script/alpha-safe.sh forge verify-contract "$VERIFY_ADDRESS" "$VERIFY_CONTRACT" --chain-id 4663 --compiler-version v0.8.28+commit.7893614a --num-of-optimizations 800 --constructor-args "$VERIFY_CONSTRUCTOR_ARGS" --watch --verifier sourcify
```

Save inventories, the public linked-library map and per-address redacted verification receipts. A rejection is a
release-blocking failure; do not mark coverage complete using only a submission or a browser upload.

Coverage inventory: Create3Deployer, all applicable linked libraries, ManagerRegistry, ChainlinkPriceSource,
FundFactory, TransitEscrow implementation, hub and spoke adapters/vaults, ValueReportReceiver, ShareToken and
ManagerFeeVault. On the fresh sample: **24 hub + 11 spoke executable contract records**.

CodeStores and one-use CREATE3 proxies are **raw assembly data/proxies**, not deployed Solidity `CodeStore` or
`Create3` library artifacts: do not submit those artifact names to a verifier. Extraction records their raw
creation bytes/address separately; retain these, codehashes and the checker-reassembled role hashes in the
manifest. CodeStore runtime is STOP + data, up to 23,576 bytes with a 1,000-byte reserve enforced by #28. CREATE3
proxy runtime is 24 bytes. TransitEscrow clones created later are EIP-1167 proxies: record implementation and
clone links separately, not an implementation constructor at each clone address.

## Mainnet alpha keeper and API

### Manual Principal returns and acknowledgement-driven reuse

**Merged PR #29 removes the Sent-after-ACK restriction.** Manual Principal and order-driven Principal/Income
sends share **64 slots**, reused only after delivered credit/refund-backed acknowledgements. Report v5 carries
authenticated refund proofs; **16 unwind result entries** is a separate bound. Manual Income stays forbidden:
use COLLECT. Cash arrival, Hub credit, ACK publication or an empty local queue alone does not prove retirement.
The alpha/harness keepers retain durable all-kind work until terminal spoke confirmation and retry/republish.
Repeat terminal CLOSE after its ACK when required. Revalidate the deployed runtime/codec/slot release on the
frozen post-#30 release; do not use the historical #20 runtime. See the
[founder report](reports/2026-10-03-MVP-REPORT.md#manual-and-income-acknowledgements-merged-pr-29).

Do **not** point `pnpm keeper` / `pnpm api` / `pnpm up` at mainnet: those paths use public Anvil actor keys, replace
guardian sets, edit storage/fund accounts, simulate fills and update oracle state. Instead this branch adds a
separate, loopback-only `local-e2e/src/alpha.ts`, reusing protocol ABIs and the route signature encoding, with real
RPC clients and ephemeral funded keys. Its normal mode contains no Anvil storage writes, guardian signing,
impersonation or mock fills. It fetches real VAAs, validates them with the destination Wormhole Core, then delivers reports and
executes Hub orders. Third-party Across relayers handle bridging; incident operators handle expired refunds and
late/unlisted arrivals explicitly. No generic refund automation or production settlement orchestration is claimed.

The explicit `ALPHA_REHEARSAL_LOCAL_VAA=1` test mode dynamically loads the local guardian signer, validates both
clients as loopback Anvil and requires `ALPHA_ALLOW_LOCAL_TEST_KEYS=1`. Only that mode scans latest rather than
finalized blocks: a pinned Anvil fork otherwise remains 64 blocks behind and cannot discover new orders.
Production always uses finalized blocks and the HTTPS VAA service. Keep both test flags unset in production.
Set `ALPHA_LOG_RANGE` to the provider's inclusive `eth_getLogs` block cap: default **1000**, minimum **1**
(positive safe integer). The October 3 Alchemy free tier capped calls at **10 blocks**, so it requires
**`ALPHA_LOG_RANGE=10`**. That tier cannot keep up continuously with Robinhood at roughly **10 blocks/second**:
use PAYG or another provider with sufficient log range, request throughput and archive/finalized access.
A smaller window fixes rejected requests, not the capacity deficit. Each tick loops windows fairly across
Hub, Spoke and credited scans within a **20-second scanning budget**, then proceeds to reports and relay work;
the budget is checked between requests and does not cancel an in-flight RPC request.

The state also stores a separate Hub credited-scan next-block cursor (`credited`) and decimal matched
`TransitReceived` totals (`credits`) per transit. Legacy keeper JSON initializes this cursor from
`ALPHA_HUB_START_BLOCK`, not the advanced message cursor, so earlier credits are backfilled. Totals and
next-block progress are saved atomically after each successful window; a restart does not recount completed
windows. Keep start blocks and fund identity unchanged. ACK resolution reads these totals instead of making
an unbounded start-to-finalized log query. Backfill must catch up before a pending transit can be acknowledged.

The keeper persists every `SentToHub` before advancing the scanned cursor and retries uncredited transits and
pending acknowledgement messages every poll with exponential backoff capped at 60 seconds, including after a
restart or temporary RPC/send failure. After authenticated Principal credit it publishes
`acknowledgeSpokeTransit(0,transitId)` and retains work until the Spoke Vault confirms resolution. Income work
resolves only after authenticated credit; late/unlisted recovery and refunds still require incident handling.
The 64 shared unresolved Principal/Income slots can block new sends and closure; monitor the durable queues (DEC-068/139/151).

Install with the frozen lockfile; type-check; export the nonsecret runtime variables from the actual deployment.
Inject only the key required by the process (hidden prompt below is **Bash**, not zsh):

```bash
CI=true pnpm --dir local-e2e install --frozen-lockfile
pnpm --dir local-e2e exec tsc --noEmit
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
read -r -s -p 'Funded keeper key: ' ALPHA_KEEPER_KEY; printf '\n'; export ALPHA_KEEPER_KEY
# Only for a provider with the observed free-tier cap; prefer PAYG for continuous operation.
export ALPHA_LOG_RANGE=10
bash script/alpha-safe.sh pnpm --dir local-e2e alpha:keeper
```

In a second private shell, source helper, export the same actual fund addresses/start blocks, inject API key/token:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
read -r -s -p 'API signer key: ' ALPHA_API_SIGNER_KEY; printf '\n'; export ALPHA_API_SIGNER_KEY
read -r -s -p 'API bearer token: ' ALPHA_API_TOKEN; printf '\n'; export ALPHA_API_TOKEN
bash script/alpha-safe.sh pnpm --dir local-e2e alpha:api
```

Use a supervisor that stops the child on shutdown and restarts the keeper with its same cursor. The keeper scans
**finalized** blocks in bounded batches; delayed finalized visibility is why the deposit client must use the
synchronous API report flow rather than rely on polling alone. Keeper cursor includes the fund identity and a
durable pending VAA queue. Watch transaction receipts, queue growth, report age, chain finality lag, key balances,
failed ticks and Across events. Stale or expired orders require manual inspection; do not discard the queue or
rewind it blindly. Mainnet Wormhole finality/observation latency, report expiry and order deadlines must be proved
compatible before opening positions. No supervisor, alert delivery or service SLA is supplied by this branch.

**Measured October 3 report latency:** first signed report v5/sequence 1 delivered in **858 seconds**;
Robinhood finalized-head lag **980–1,109 seconds**; later synchronous report cycles approximately **19 minutes**.
The **1,588-second** lifetime leaves **730 seconds** after that first delivery, or only **479–608 seconds**
beyond the observed finality lag for other delivery work. These are separate measurements, not additive timings
or an SLA. Enforce DEC-159/160 pre/post mint/burn reports and stop on stale delivery. The shared
`alpha-report-client.ts` uses Node HTTP with a **35-minute socket timeout**, avoiding global fetch's fixed
**300-second headers timeout**; it does not extend on-chain report validity. The first capital attempt failed
at about 303 seconds with zero broadcasts. Continuous keeper operation was not demonstrated during this smoke:
the free-tier cap stopped ticks, while explicit API reports enabled the money operations.

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

## Executable spoke, income and closure continuation

After release gates, explorer coverage and a real VAA report pass, execute from the worktree root in **Bash**.
Keep the keeper/API running under the supervisor. This authorized one-time continuation is not an automatic
retry script. It refuses Anvil/public keys and contains no storage funding, guardian override or simulated fills.
Every broadcast hash is appended and fsynced to `continuation-state.jsonl` **before** receipt polling.
Polling failures retain `status: submitted` with an unknown receipt outcome; successful and reverted receipts
are persisted too. A phase with prior broadcasts refuses to run again, even if all receipts succeeded.
Reconcile from saved hashes without sending any transactions before planning an explicit recovery.

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
unset ALPHA_ALLOW_LOCAL_TEST_KEYS ALPHA_REHEARSAL_LOCAL_VAA
test -n "$ALPHA_RECORD_DIR" && test -n "$ALPHA_CORE_VAULT" && test -n "$ALPHA_SPOKE_VAULT"
read -r -s -p 'Authorized manager key: ' ALPHA_MANAGER_KEY; printf '\n'; export ALPHA_MANAGER_KEY
trap 'unset ALPHA_MANAGER_KEY' EXIT
export ALPHA_DEPOSIT_AMOUNT=5000000 ALPHA_SEND_AMOUNT=5000000 ALPHA_PAYOUT_AMOUNT=1000000
export ALPHA_MIN_COLLECT_USDC=500000
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-smoke.ts capital
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-smoke.ts income
# Irreversible: execute only after approval to close this smoke fund.
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-smoke.ts closure
unset ALPHA_MANAGER_KEY
```

On interruption, use the same record directory, chain configuration and authorized manager identity:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
read -r -s -p 'Authorized manager key: ' ALPHA_MANAGER_KEY; printf '\n'; export ALPHA_MANAGER_KEY
trap 'unset ALPHA_MANAGER_KEY' EXIT
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-smoke.ts reconcile
unset ALPHA_MANAGER_KEY
```

`reconcile` loads `continuation-state.jsonl` and queries each submitted hash on its recorded chain. It saves
success/revert outcomes, retains unknown/pending hashes on RPC errors or missing receipts, prints hash/status
records and exits nonzero if any remain unresolved or reverted. It never broadcasts or resubmits. Do not delete
or replace this state file to bypass the phase guard: receipt success alone does not prove relay delivery or
settlement. Inspect the saved receipts, full relay data and vault state, then authorize only the missing steps
as a separate recovery operation. This is receipt reconciliation, not automatic workflow replay.

`capital` derives the Mandate bridge adapter, fetches live Across min/max/fee terms, calls `quoteSend`, checks
the adapter fee covers current terms, simulates every write, deposits 5 USDC, sends 5 USDC, waits for exact
`FilledRelay` matching (chains/id, all relay fields/message hash), asserts the vault arrival/confirmed transit,
and requests a 1 USDC Instant Payout with fresh reports. Unavailable routes, missing terms or insufficient
immutable adapter fees are **STOP** conditions: no caller may widen fees.

Across terms requests must name **`inputToken` (USDC) and `outputToken` (USDG)** for this route; the legacy
`token` parameter returned HTTP 400 on mainnet. Smoke log scans use bounded `ALPHA_LOG_RANGE` windows
(default **10** in that script; the keeper default is **1000**).

**`bridge` is an explicit resume mode after a confirmed manager deposit**, not a capital replay. First run
`reconcile` and inspect balances, successful deposit receipts and any send hashes. Only if the deposit succeeded
but no send was submitted, authorize the bridge phase; it sends to the Spoke Chain, matches the real Across
fill/`TransitArrived`, then requests the manager Instant Payout, without approving/depositing again:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-smoke.ts bridge
```

Use the same protected manager-key environment and record directory as the continuation above. The mode
allow-list includes `bridge`; its durable phase guard still prevents blind repeat broadcasts.

`alpha-mainnet-positions.ts` supplies separately authorized live modes: **`spoke-position`** (spoke swap and
V4 openPosition), **`hub-aave`** (allocation and Aave openPosition), **`investor-deposit`**, **`investor-payout`**,
**`hub-batch`** (Aave allocation/open, second investor deposit and Instant Payout in three report cycles), and
**`status`** (read-only snapshot). For example, with the nonsecret manifest loaded and approved keys injected:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-positions.ts status
```

Writes append submission/receipt records to `positions.jsonl`; **this script does not use the continuation
journal's fresh-mode replay guard**. Never rerun a write mode blindly: reconcile saved hashes, chain balances
and open positions first, and authorize only missing work. The live smoke left the fund Open with one V4 and
one Aave position; closure, Standard Payout, above-minimum COLLECT and keeper order relay were not exercised.

`income` collects real open-position income without adding capital. Below `ALPHA_MIN_COLLECT_USDC`
(default **500000 = 0.50 USDC**) it defers COLLECT and retains income. Above it, it checks current route/fee
terms, reads the payable Wormhole fee, publishes COLLECT, matches the real fill, waits for
`pendingSpokes == 0 && openResults == 0`, then settles the manager's Income Withdrawal. Deferred income is
expected at alpha size. Retry only this stage as income accrues, never repeat capital to manufacture income.
Runtime `/income` uses the same conservative base-only minimum/positive-quote gate, but requests for the API
signer (the transaction caller), not the manager; use the CLI for manager income. Non-base income must first
be converted into base; the runtime does not estimate it as bridgeable dollars. Operator live route checks
remain required: an adapter quote does not prove relayer acceptance. Income is not requested autonomously.

`closure` reads the message fee, calls `closeFund`, then the manager calls `unwindAllAfterDeadline` immediately
(only non-managers wait 72 hours). It waits for CLOSE execution, full return-fill matches and durable keeper
Principal acknowledgements, delivers a fresh report, finalizes, asserts Closed and the manager's automatic
payment/burn. If other holders remain, set `ALPHA_EXIT_HOLDER` to the approved investor address: it checks that
permissionless exit against `shares * closedIdle / closedSupply` and the frozen supply. With manager-only supply,
it asserts zero remaining supply/Idle and never divides by zero or attempts a second manager payout. Mainnet time is never manipulated. Retained
dust/unsettled positions can block finalization: report the failing call, do not claim successful closure.

Quotes, confirmed receipts and fill assertions go to `$ALPHA_RECORD_DIR/continuation.jsonl`; every broadcast
and receipt outcome goes to the durable `$ALPHA_RECORD_DIR/continuation-state.jsonl`. Keeper queues remain in
`$ALPHA_STATE_FILE`. Never delete queues to clear timeouts. Close this sample only with explicit approval.

## Post-deployment smoke (mainnet)

Do not use `alpha:rehearsal` on mainnet. Use small Pool Party wallet balances and actual release addresses.
The seed exists already. Keep funds in Idle; no investment/bridge allocation until the VAA/Across gates pass.

1. Start keeper/API. Call `/report`, wait for `delivered: true`; confirm receiver sequence and a live price source.
2. Use manager wallet for a tiny **2 USDC budget** deposit; a 1 USDC budget fails `DepositBelowOneShare` at the
   initial Share Price after the 25 bps flow fee. Only the fund seed/first deposit must meet the Mandate minimum;
   subsequent deposits, including a new investor's, need at least one whole share after fees.
3. Call `/report` immediately after deposit. Check minted shares, actual USDC debit, flow fee to Protocol Recipient,
   Idle, Share Assets, Share Price, Operating Cash zero and receiver sequence. Do not assume budget = charged amount.
4. Call `/report` again immediately before a 1 USDC Instant Payout; keep manager holdings well above half its peak
   (DEC-127/146/147). Call `requestPayout(1000000,0,100)`; Instant is enum 0 and claims immediately. If the frozen ABI
   has changed, regenerate ABIs and follow the new payout arguments rather than broadcasting the old selector.
5. Call `/report` immediately after burn. Confirm actual USDC payment, ShareToken burn, Payout Fee, no unexpected
   Payout Reserve / In-flight Value, report accepted and fund still Open. No unwind is expected for an Idle-only
   smoke. Standard Payout is enum 1: request then `claimPayout(uint16)` only after its term ends, with a fresh report.

Example calls (Bash; keep bearer token out of process command arguments by passing curl config on stdin):

```bash
printf 'header = "Authorization: Bearer %s"\n' "$ALPHA_API_TOKEN" | bash script/alpha-safe.sh curl --config - --fail-with-body -X POST "http://127.0.0.1:${ALPHA_API_PORT:-8787}/report"
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh cast send 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'approve(address,uint256)' "$ALPHA_CORE_VAULT" 2000000 --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 2000000 1 --from "$MANAGER" --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast send "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 2000000 1 --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"
# /report after deposit, then /report immediately before payout (same authenticated call as above).
bash script/alpha-safe.sh cast send "$ALPHA_CORE_VAULT" 'requestPayout(uint256,uint8,uint16)' 1000000 0 100 --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"
# /report after burn; check the receipt and state, not only transaction submission.
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'idle()(uint256)' --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'fundState()(uint8)' --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast call "$ALPHA_REPORT_RECEIVER" 'lastReportSequence(uint256)(uint64)' 0 --rpc-url "$ARBITRUM_RPC_URL"
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
bash script/alpha-safe.sh cast send "$ADAPTER" 'setPaused(bool)' true --account alpha-guardian --rpc-url "$CHAIN_RPC"
bash script/alpha-safe.sh cast call "$ADAPTER" 'paused()(bool)' --rpc-url "$CHAIN_RPC"
# Only after root cause/review: reversible quarantine release.
bash script/alpha-safe.sh cast send "$ADAPTER" 'setPaused(bool)' false --account alpha-guardian --rpc-url "$CHAIN_RPC"
# Irreversible retirement, separate explicit approval:
bash script/alpha-safe.sh cast send "$ADAPTER" 'deprecate()' --account alpha-guardian --rpc-url "$CHAIN_RPC"
bash script/alpha-safe.sh cast call "$ADAPTER" 'deprecated()(bool)' --rpc-url "$CHAIN_RPC"
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
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'attestExpiry(bytes32)' "$TRANSIT_ID" --from "$KEEPER_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast send "$ALPHA_CORE_VAULT" 'attestExpiry(bytes32)' "$TRANSIT_ID" --account alpha-keeper --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'recognizeRefund(bytes32)(uint256)' "$TRANSIT_ID" --from "$KEEPER_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast send "$ALPHA_CORE_VAULT" 'recognizeRefund(bytes32)' "$TRANSIT_ID" --account alpha-keeper --rpc-url "$ARBITRUM_RPC_URL"
# A spoke-origin refund uses the actual spoke vault and Robinhood RPC, not the hub Core Vault.
```

`TRANSIT_ID`, `ADAPTER`, `CHAIN_RPC`, `KEEPER_ADDRESS`, `ADDRESS`, `CONTRACT`, `CTOR_ARGS` and `LINK_ARGS` in the
examples are temporary operator shell variables derived from the verified manifest/incident/verification record;
they are not deployment-script configuration. Fund `alpha-keeper` keystore if manual keeper calls are necessary.

## Recorded fork rehearsal (no secrets)

### Final command sequence on the frozen release

Run from the dedicated worktree root, not the shared repository root. The script sources the RPC helper itself,
sets every fund input explicitly, uses throwaway Anvil accounts, starts fresh private forks, regenerates the
linked-library ABIs, broadcasts the actual deployment/creation scripts on both chains, runs both checkers,
and stops both forks and every runtime child on exit. Never execute this script against mainnet.

```bash
CI=true pnpm --dir local-e2e install --frozen-lockfile
pnpm --dir local-e2e exec tsc --noEmit
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
ALPHA_REHEARSAL_HUB_PORT=18745 ALPHA_REHEARSAL_SPOKE_PORT=18746 ALPHA_REHEARSAL_API_PORT=18787 bash script/rehearse-alpha.sh
bash script/alpha-safe.sh forge build --sizes
bash script/alpha-safe.sh forge fmt --check
bash script/alpha-safe.sh forge test --match-path test/size/ContractSizes.t.sol -vv
bash script/alpha-safe.sh forge test --no-match-path 'test/{fork/**,review/**/*Fork*}'
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
bash script/alpha-safe.sh forge test --match-path 'test/{fork/**,review/**/*Fork*}' -j 4
pnpm --dir local-e2e test:alpha
pnpm --dir local-e2e check:urls
node --test script/alpha-verification.test.mjs
```

The expanded smoke sequence is exact in `script/rehearse-alpha.sh` and `local-e2e/src/alpha-final-smoke.ts`:

1. Fund only two parameterized 5 USDC seeds and one 5 USDC deposit on the fork; deploy both factories and
   create the fund (minimum 2 USDC, Spoke Cap 100 USDC) and its Spoke Vault.
2. Run both on-chain checkers, approve/deposit a 5 USDC budget, and start the alpha API/keeper in guarded local
   VAA mode. `/report` publishes and delivers before and after the 1 USDC Instant Payout.
3. Send 5 USDC to the spoke; fill through the real Across SpokePool with fork-funded relayer inventory;
   match `FilledRelay` to the exact origin deposit and `TransitArrived`, then deliver the arrival report.
4. Swap half the spoke allocation through V3; open its Mandate V4 position; a fork-funded third-party trader
   moves the real V4 pool to earn fees. Allocate 1 USDC on the Hub and supply the Mandate Aave reserve.
5. Advance both clocks one day and re-stamp the fork oracle; collect real Aave interest; request Income Withdrawal
   with `maxLossBps=100`. The alpha keeper delivers COLLECT, the Spoke Vault sells fees and sends Income through
   Across when bridgeable. At alpha size assert an authenticated empty result, retained dust and runtime
   deferral instead of waiting for a nonexistent deposit; settle the positive Hub Attributed Income.
6. Create a second 5 USDC seed fund on both chains. Ana deposits a 2 USDC budget, producing one whole share.
   Start a separate alpha runtime/cursor for this fund; `closeFund`, advance past `closingDeadline`, re-stamp
   the fork oracle, `unwindAllAfterDeadline`, deliver CLOSE and its report, `finalizeClosure`, then permissionlessly
   `exitClosedFund(Ana)`. The manager is already paid/burned by finalization; the frozen `closedSupply` remains
   one share (1e18 base units) after Ana exits. Assert Closed and the frozen split, then stop all processes.

**Mainnet continuation:** use the keystore deployment/creation/check commands in “Exact deployment order”, not
the rehearsal script. The inputs Rafael must supply are the full input sheet above **plus** a frozen release SHA,
maximum alpha exposure, VAA-service observation proof, tiny Across route fill/refund proof, a supervisor with
durable per-fund cursors, incident owner, authentication/tunnel policy and a manual acknowledgement/refund/
settlement owner. ETH is required for deployer, manager, keeper, API signer and guardian on both chains; manager
also needs seed/deposit USDC. Approve all pool/reserve keys, Spoke Cap, fees, seed and minimum explicitly.

After the initial deposit/report smoke, approve only a tiny capital allocation; call
`sendToSpoke(uint256,uint256,uint256,bytes)` with `(0,approvedAmount,0,0x)`. Wait for a third-party Across fill,
match its entire relay data, then call `/report` before treating capital as arrived. To collect actual earned
income use `requestIncomeWithdrawal(uint16)` with the approved bound and exact Wormhole message fee if an order
is published; let the keeper execute COLLECT, wait for the return fill and accepted collection result, then
`settleIncomeWithdrawal(address)`. Never fabricate income or oracle state on mainnet. For the second fund,
`closeFund()` then `unwindAllAfterDeadline()` (manager may call before the deadline), supply the exact Wormhole
fee, wait for CLOSE results and every return transfer, and only then `finalizeClosure()` / `exitClosedFund(address)`.
All mint/burn operations require synchronous pre/post reports. Inspect fees, received amounts and actual share
balances; do not infer success from a transaction submission or from an unledgered token balance.

### Historical October 3 rehearsal evidence (before #28/#29)

The following round-specific counts, sizes and manual-send blocker describe their original commits, not current
main. #28 now enforces zero Operating Cash, gated closure exposure, recorded/sweepable terminal dust strictly
below 0.50, no Idle credit after Closed and the CodeStore reserve. #29 resolves manual/Income acknowledgement
retirement. Current green bar: **1,548 non-fork / 190 suites; 227 fork / 57 suites; size 3/3**, build/format PASS.
SpokeVault **22,907 B / 1,669 B margin**, CoreVaultPayoutLogic **22,547 / 2,029**, CoreVault **22,358 / 2,218**;
no executable below 1,000-byte margin. See the report's complete freshly measured inventory.

### Round-2 corrections and fresh alpha-sized rehearsal (October 3, 2026)

Fix commits: `9ba93bd` (URL redaction) and `fa6773f` (durable broadcast checkpoints). `origin/main`
remains `2b04b28`, already included in this branch; no additional main merge was needed.

Shell and TypeScript now keep only scheme/host/port, strip userinfo and consume every non-whitespace suffix,
including embedded parentheses, quotes, brackets and trailing punctuation. Conservative redaction may remove
closing log delimiters too. **13 synthetic URL cases** pass across shell output/saved logs, TypeScript and all
logger levels, plus **5 actual failing cast commands** with synthetic credentials; command exit status is preserved.

`continuation-state.jsonl` is fsynced immediately after each broadcast and before polling. Post-broadcast outages
retain submitted/unknown records; reverted receipts are saved before failure. The executable `reconcile` mode
reloads saved hashes, queries receipts without broadcasting, and refuses success with unresolved/reverted records.
Already-started phases cannot replay, and unresolved prior broadcasts block new phases. **3 new transaction
regressions** cover durable-before-poll ordering, restart/outage recovery, read-only reconciliation, reverted and
successful receipts, no duplicate broadcast, and corrupt-state failure. Recovery remains operator-authorized,
not automatic workflow replay; the mainnet CLI was tested through its shared transaction helper, not live writes.

Fresh rehearsal passes at archive pins **511007613 / 78293056**, private ports **20645 / 20646 / 20787**,
with the same tiny parameters listed below: both deployment checkers, 5 USDC capital send / 4.966000 USDG fill,
1 USDC Instant Payout, V3/V4/Aave, retained **2594 USDG units** and empty COLLECT result, **80 USDC units**
Attributed Income settlement, second-fund CLOSE/frozen exit, and **5 API checks**. All three ports have no
listeners after cleanup; no owned Anvil/keeper/API remains. No mainnet broadcast or live explorer verification.

Green bar: size **3/3 (1 suite)**, non-fork **1433/1433 (183 suites)**, full fork **222/222 (56 suites)**,
alpha Node **11/11**, verification tooling **2/2**, URL **13/13**, TypeScript, formatting and diff checks pass.
Production bytecode is unchanged: Core Vault **22862 / 1714 margin**, Spoke Vault **22887 / 1689**, tightest
SpokeUnwindLib **23449 / 1127**. No executable margin below 1000; full CodeStore data chunks intentionally
have zero margin. The older 23473/1103 unwind figures were pre-encoder and are corrected in the current table.
No new specification divergence or scope deviation; manual Principal returns and all live release gates remain
restricted as documented below. Full multi-strategy WP-15b/18 coverage remains outside this smoke scope.

### Round-1 corrections and alpha-sized evidence (October 3, 2026)

Baseline now includes `origin/main` `2b04b28` (shared result encoder). Default rehearsal parameters are
minimum **2 USDC**, seed **5 USDC**, Spoke Cap **100 USDC**, additional deposit **5 USDC**, send **5 USDC**,
Aave allocation **1 USDC**, Instant Payout **1 USDC**, and second-fund investor deposit **2 USDC**.
All are environment parameters with conservative upper bounds; trader inventory/pool tick movement are
synthetic fork-only fee generation, not alpha investor exposure. The larger historical run below is not the
current release rehearsal and does not establish live acceptance of small Income sends.

**Root cause of the alpha COLLECT timeout:** the execution succeeds with an empty result, not a bridge failure.
After fee collection/sale, retained base income is **2594 units = 0.002594 USDG**. Direct call to the deployed
spoke Across adapter `quoteSend(USDG,42161,2594,0x)` reverts with
**`FeeNotBelowAmount(30003,2594)`**: the adapter's fixed 0.03 USDG fee plus rounded variable fee exceeds
the entire income. `SpokeIncomeLib._bridgeable` catches this; `_sendResult` emits an empty collection result
and preserves `unsentBase`/the collected income bucket. No `FundsDeposited` exists to fill. Thus the original
timeout is caused by the smoke's unconditional deposit wait, not a relayer failing to fill or a proven universal
Across 0.50 minimum. `ALPHA_MIN_COLLECT_USDC=500000` is a conservative **operator-configured floor**, not
a hard-coded claim about current Across limits; fetch actual route terms at execution time. Runtime `/income`
returns 409/deferred below that floor or on a nonpositive/reverting quote. The alpha smoke deliberately exercises
one dust COLLECT directly to prove contract retention, then proves the runtime will defer a repeat.

Default end-to-end smoke passes: 5 USDC send / **4.966000 USDG** real fork relay arrival, 1 USDC Instant Payout,
V3 swap/V4 position, 1 USDC Aave supply, authenticated empty COLLECT/retained dust, **80 units = 0.000080 USDC**
Attributed Income settlement, second alpha fund CLOSE/finalization/frozen exit, API 5 checks and durable keeper
startup. No larger synthetic return was needed or filled to claim alpha success.

**Additional contract-behaviour blocker (not changed in `src/`):** an optional
`ALPHA_MANUAL_ACK_PROBE=1 bash script/rehearse-alpha.sh` sends 1 USDG using manual `sendToHub(1000000,Principal,0)`.
It proves durable queue retention before the later real fill. The Hub subsequently credits 969200 units;
`acknowledgeSpokeTransit(0,0x58dc2f195c2b26eb1f9a533e9531292de0c6950e307250845e494ccabc517476)` succeeds
in transaction `0xd1049abe1c15d9cde3e4c5863c6f5bcaf1e4526ea13bf1eb27cbba526ac95a87` (210123 gas).
Spoke `executeOrder(ACKNOWLEDGE VAA)` succeeds in
`0xa17e08db7a68468abfca808a672ecfefff47f6ddc285d3e3d604788ce8ee79fe` (218685 gas), but the transit stays Sent.
`SpokeUnwindLib.acknowledge` returns early when `s.unwind.transitRequest[transitId] == 0`; manual `sendToHub`
does not populate that unwind mapping. The probe fails precisely at `Timed out: durable keeper Principal acknowledgement`.
The runtime keeps this work pending and retries; it does not falsely mark it resolved. This is a separate
contract limitation requiring an independently reviewed source fix, **not** the alpha COLLECT root cause.
Historical pre-#29 limitation, now superseded: B-04 proves a manual Principal return is credited, acknowledged and
removed from the shared slot list by the durable alpha keeper. Manual refunds still require incident handling.
Default capital/income/second-fund-closure rehearsal does not use this unsupported manual acknowledgement path.

All production sizes match merged main: Core Vault **22862 / 1714 margin**, Spoke Vault **22887 / 1689**, tightest
SpokeUnwindLib **23449 / 1127**. No executable margin below 1000; full CodeStore data chunks intentionally reach
24576. Green bar: size **3/3**, non-fork **1433/1433 (183 suites)**, fork **222/222 (56 suites)**, alpha tests **8/8**,
verification tooling **2/2**, URL cases **8/8** including failing stdout/stderr/real synthetic cast, TypeScript and
format/build checks pass. Inventories recognize **24 hub / 11 spoke**, zero unknown. Mainnet broadcast/explorer
submission/real guardian and relayer gates remain unexecuted and explicit.

**PASS on fresh forks; no mainnet broadcasts.** Source baseline `f88b25b`, Solidity 0.8.28, optimizer 800,
Cancun, no via-IR. Ports 18745/18746 (API 18787); archive pins 511007613/78293056.
Same public throwaway operator account 0, manager account 1, API signer account 8, keeper account 4;
Protocol Recipient account 6; guardian is the operator. Registry owner defaults to API signer.
All three salts remain the script constants. Operating Cash floor/top-up are zero on both funds/chains;
performance 2,000 bps, management 0, Spoke Cap 10,000 USDC, minimum/seed budget 100 USDC.
Pool keys are the hookless WETH/USDC and WETH/USDG defaults (500/10); Hub Aave reserve is USDC.

| Deployment role | Address |
|---|---|
| FundFactory (both chains) | `0x408EBd63EC5DdB000471452253A73DB682590E5c` |
| Create3Deployer (both chains) | `0x1Da47CED247a6776329281836600283b033f8e41` |
| SpokeCrossChainLib (both chains) | `0x0E6F4244f3C78e4F58d1CB3Fc24adeAe7A548B0e` |
| SpokeUnwindLib (both chains) | `0xa5ed63D406dF4b1683Cd9E078e21Fe5e00d5dB03` |
| SpokeCloseLib (both chains) | `0x79203F0b14767e002075bD4591687f1d14be5a36` |
| SpokeIncomeLib (both chains) | `0x805B29e8Af6Ff896C7F826F0FBC6257976aA4DeF` |
| CoreVaultIncomeCollectionLogic (Hub) | `0x20Ed82f63228db766c8A9C0fF8a3Acf74dfe111e` |
| CoreVaultIncomeLogic (Hub) | `0xaCe0eEdb23CC983ebdd44120d21F385d7846b465` |
| CoreVaultLogic (Hub) | `0x94E23e5146291AC6513032dAE1A9F21cB3E2Fd21` |
| CoreVaultPayoutLogic (Hub) | `0x4c405deF26A7CeA1f27DaF08C95776a3E60d06f5` |
| CoreVaultClosureLogic (Hub) | `0xDc36EEE5A17c177c442cF6D5437B20e3fE5D1595` |
| CoreVaultTransitLogic (Hub) | `0x1De457f88cDC00C7739786fAc2504d7DBEe4A9A5` |
| ManagerRegistry (Hub) | `0x19b3317E15d2202639510992C13591bAd1E3365F` |
| ChainlinkPriceSource (Hub) | `0xaDB9cFAd43287840EA1cf21C633b6f6E45Ffd348` |
| TransitEscrow implementation (both chains) | `0x173f041905C82c6Caa459916610358FBEf6FbE6D` |

| Fund role | First fund | Second fund |
|---|---|---|
| Core Vault | `0x3D010D998E19d52CE7be47021a3000e3eAa12F8E` | `0x18fa5d0be5EdedB600b7E528b887F496839F42fF` |
| ShareToken | `0xd2982AA13aA39b7ABA2c0C8019B0532Aa654c431` | `0x44D16e7A387a21fa8EC90E72db20F2a58cb7f470` |
| ManagerFeeVault | `0xDBa9415D84a97BC7DbAa240Caf891B67aEBdfF7b` | `0x75978e2C5de87FD7fFdD0f5BCE9f44cC0A034070` |
| ValueReportReceiver | `0xF90640a43acf3F7443fCf01891f1C9772A560b54` | `0xce60dCaCcAacc13ca0423035248047E44384eaf4` |
| hub Spoke Vault | `0x70660b467e9cB79bEE9e9f12050a1083Fe3FBEcD` | `0xcB06d6303b665E8C9972CdB1FCb7143D51af9EbD` |
| Robinhood Spoke Vault (predicted) | `0x3a0Ef4d68EDDd9821593472ac84a75741bBcf3cf` | `0x772d26fc86CD5a19Ce11bCb90a61489EeCfCE6aF` |

First fund id: `0x6bd990bc05fc4bf19028b0f0c47cd6fac1f9d221fb076c2699dae83d90d185bf`.
First Mandate hash: `0xcc0dc347e672cd65b6b2427a256cc15233ab28293ffa39587fb19ec513e42886`.
Second creation number: 2; id `0xeca320944f53b75dd77c48a33913ed646dc87d829e4625536f4b29214e4d28ab`;
Mandate hash `0xb9d5678d5837b593be58b5bf9c9c30e019c97fe216872618381ee57971007d29`.
Hub Core Vault creation-code hash: `0xc50b26c3c8d02c01ef071ece3219d7aba90895601a8162aba2a7eb2336347fa4`;
Spoke Vault hash (both): `0x7285e226ddf43e886c6f75ed83e85a1f03e883dc1b8788c853cf3de752c0ce2f`.
Both checkers log `ALPHA CHECK PASS` (42161 / 4663), including all new closure/collection libraries and nested links.

| Operation | Transaction hash | Gas / result |
|---|---|---|
| DeployFactory 42161 (final factory tx) | `0x6bb2de63e5400f5a4abc764ea516177e929327bd98a13e3b11b70a295d422c47` | 21 transactions; total gas 59216193 |
| DeployFactory 4663 (final factory tx) | `0x53047ea1aa34c1c51a2c0e1f887d27b5b25e7891b69bb27988cf0fa1c12b74b8` | 11 transactions; total gas 32016035 |
| CreateFund first Hub | `0x05d865a824a489d481d05a9d56cb4128a5504ef0c39c6d4ecd37e1006b428720` | 2 transactions incl approval; total gas 24,353,889 |
| CreateFund first spoke | `0xa6a7975b1b31b1d6dd56d3b9ddd8b0dd5759b2103511fe4e215f8d7c941d2cf1` | 1 transaction; gas 12,124,601 |
| First fund deposit | `0x20cfdb2dbbcfb96452fef403fbe81a61488ab9179975e218a8f30e0117109164` | gas 343290; 500 USDC budget |
| sendToSpoke arbitrum | `0x9c8339fa23daac5652de5e94a5a0641f055755110a79e547765a2629c8b9d81c` | 740776 |
| fillRelay robinhood | `0x52b1fab5562a07ab1b15ebb6a84f09c90849edac56560bd11592e93084bdf737` | 299730000 base units arrived |
| requestPayout arbitrum | `0x986b94955ddd06291913539ac2409a78fe6344a5476e54465f0ee791e346df7f` | 743372 |
| swap robinhood | `0xdf87259bb0f77965acc32bce1ba39047b66fb4caad7966e384935255aa9fcc65` | 1180829 |
| openPosition robinhood | `0xd9b6942dece277f3662ee2488e8900e94bf30d03ce88483beb6040252b804819` | 770006 |
| allocateToHubSpokeVault arbitrum | `0xa253e640ca2f5a56d22a6fa02a7e82e55b52d4f6310f89f55c4c4f1c095ece6b` | 138274 |
| openPosition arbitrum | `0x8ced2d4ea2892936293afaae769462f0b493fba47f152ec01b25a583c34abaa0` | 482592 |
| collectIncome arbitrum | `0x8a659da58049efdff0ec9c3a787e0c8230a754e8fc568f38fa10bf69c5426ec1` | 304160 |
| requestIncomeWithdrawal arbitrum | `0x33ea1ec06d590032287eaf7146a5cd2ec591e658e40e7f130c7eb069ad08fe08` | 762418 |
| fillRelay arbitrum | `0x6785abb810744fd74b42d9b926500c11137251e96f56433db81678f8132a27b6` | 126497 base units arrived |
| settleIncomeWithdrawal arbitrum | `0x5bad3a0a8c7321bac906b23023c0a049717eafbc17ae3ca06f7ea05fff1b9e0c` | 313800 |
| secondFundDeposit | `0xee30aaa54da495875cb0b12b3317bb35d1f2b9f379aab796db9d39d68bd41b67` | success |
| closeFund arbitrum | `0xba4fdc2f7d4d338e0877f2d7ad717cc1bc6f1774b9f1db32dcce5ce31bc222f9` | 54359 |
| unwindAllAfterDeadline arbitrum | `0x45dd4e0a497328facffa875c598d82bb55469724db2a1155f29262c3382193fb` | 134993 |
| finalizeClosure arbitrum | `0x04d319ac11b251461d560be701ab756a2b5322412a79374f9518210ca4a3908c` | 596873 |
| exitClosedFund arbitrum | `0x3e8cc9ba52e912e513a2864a709bdf1bdfcac61fcbdd24a484386777454fd6ed` | 183739 |
| Alpha keeper executeOrder spoke | `0xa262f13f9305b23fe91afb85dfd4414ef936a783bc4b35e6ad354c88d11ca722` | gas 2505155 |
| Alpha keeper executeOrder spoke | `0xda15fa0f07126af9307c7ae2b2125868d5b6fce541ce0e251adf5b521f8a47b5` | gas 497308 |
| Alpha API report | `0xbff9a610d87d9e8dd2f4ab86c4cc765be6b08dae3c6432a5f7c8920ff1d03e6d` | gas 168373 |
| Alpha API deliver | `0xbd62ccc7c4ded7aff571b6c0e8cac7153fa7070910ae03e39e8e451a596e313c` | gas 845037 |

Capital send: 300 USDC; confirmed arrival **299.730000 USDG**, linked through the real SpokePool's FilledRelay.
Income return: **0.126497 USDC**, initially held unmatched until the COLLECT result report; settlement pays
**0.102820 USDC Attributed Income** (real Hub Aave interest plus spoke V4 fees, after costs/performance fees).
Second fund: manager paid and shares burned at finalization; Ana's one remaining share has frozen closedSupply
**1e18** and exits through the frozen split. All listed transactions have successful receipts.
Alpha API probe: **5 checks** (401, both chains' signed routes, both zero-loss refusals); keeper funded startup,
publication and durable cursor pass. Verification extractor recognizes all **24 Hub / 11 spoke executable
records**, zero unknown executables; no explorer submission performed.

### Fixes, limitations and readiness

- Regenerate the committed Core Vault/Spoke Vault ABIs for all MVP entries and linked-library events/errors;
  the old rehearsal used the removed two-argument payout selector. Use three arguments and an explicit loss bound.
- Checker now checks SpokeCloseLib, CoreVaultClosureLogic, CoreVaultIncomeCollectionLogic and nested links;
  verification extraction now identifies both closure libraries instead of unknown executable records.
- Add real capital/return fills, V3 swap, V4 fees, Aave interest, COLLECT, second-fund CLOSE and frozen exit.
  Guard local guardian signing/latest scanning behind explicit test mode and loopback Anvil preflight.
- No `src/` changes or blocking contract failure found. Test-only assertion corrections reflect actual
  18-decimal shares and manager payment during finalization, not a contract/spec change.
- Scope deviation: this is the requested deploy rehearsal plus smoke, not the full WP-15b/18 multi-strategy
  Standard Payout/unwind/refund scenario. That independent final scenario remains a release gate. No shared fork
  fixture or new fork suite was added; CI SCENARIO_SUITES is unchanged.
- Existing spec divergences remain: DEC-185/native Operating Cash/refunds deferred by ruling October 2;
  management cap is 500 bps under Slack DEC-186, not the register's older 1,000 bps reading; DEC-187 manager
  pays own gas. DEC-157 has no inactivity switch: a silent spoke blocks exits. No new monetary divergence found.

**The deploy/link/create/check path is fork-ready, but NOT yet approved/ready to broadcast on mainnet.**
Rafael must approve/fund the input sheet; obtain independent review and green CI on the frozen release; complete
the full strategy scenario; prove real guardian observation/VAA service and finality/report deadlines; prove
real Across relayer route/fill/refund economics with tiny exposure; verify all sources; and assign authenticated
services, supervision/alerts plus manual acknowledgement, refund and settlement operations. Public third-party
funds remain outside this internal-alpha authorization. No keys or RPC URLs are included in evidence.
Fork storage funding, guardian override, V4 test trader and oracle re-stamp are not evidence for those live gates.
The final script prints both smoke passes and stops both private forks; no owned Anvil/API/keeper remains.

## Historical round-2 validation and sizes

Fresh round-2 green bar: build/sizes and format check; size **3/3 in 1 suite**; non-fork **1,433/1,433 in 183 suites**;
fork **222/222 in 56 suites** with -j 4; alpha **11/11 Node tests**; verification tooling **2/2 Node tests**;
URL redaction **13 synthetic cases**; TypeScript type-check; final scripted two-fork rehearsal and **5 API checks**.

Production before = after (no source change), EIP-170 limit 24,576 bytes:

| Contract / linked library | Before / after bytes | Margin |
|---|---:|---:|
| AaveV3Adapter | 9893 / 9893 | 14683 |
| AcrossBridgeAdapter | 6713 / 6713 | 17863 |
| UniswapV3SwapAdapter | 10586 / 10586 | 13990 |
| UniswapV4Adapter | 14369 / 14369 | 10207 |
| CoreVault | 22862 / 22862 | 1714 |
| CoreVaultClosureLogic | 16085 / 16085 | 8491 |
| ManagerFeeVault | 1077 / 1077 | 23499 |
| ManagerRegistry | 1603 / 1603 | 22973 |
| ShareToken | 1822 / 1822 | 22754 |
| TransitEscrow | 894 / 894 | 23682 |
| Create3Deployer | 1342 / 1342 | 23234 |
| FundFactory | 18347 / 18347 | 6229 |
| ChainlinkPriceSource | 1709 / 1709 | 22867 |
| ValueReportReceiver | 8080 / 8080 | 16496 |
| SpokeVault | 22887 / 22887 | 1689 |
| CoreVaultLogic | 13684 / 13684 | 10892 |
| CoreVaultTransitLogic | 15596 / 15596 | 8980 |
| CoreVaultIncomeLogic | 12101 / 12101 | 12475 |
| CoreVaultIncomeCollectionLogic | 16816 / 16816 | 7760 |
| CoreVaultPayoutLogic | 22256 / 22256 | 2320 |
| SpokeCrossChainLib | 12199 / 12199 | 12377 |
| SpokeUnwindLib | 23449 / 23449 | 1127 |
| SpokeCloseLib | 5875 / 5875 | 18701 |
| SpokeIncomeLib | 11631 / 11631 | 12945 |

Tightest executable: **SpokeUnwindLib 23,449 B / 1,127 B margin**; Core Vault 22,862 / 1,714;
Spoke Vault 22,887 / 1,689. No executable margin below 1,000. Full CodeStore data chunks intentionally
have **0 B margin** (STOP plus data at EIP-170); do not increase chunk size. Script contracts are off-chain.

## Final B-04 rehearsal — October 3, 2026

**PASS on final main `f171dc6`, including #30. No mainnet transactions were sent.** This section supersedes
historical readiness, sizes, counts, role assignments and manual-send limitations above. B-04's code/test gates
are complete; the deployment is **conditionally ready for the approved internal alpha, not an unconditional
mainnet GO**. Independent review of this tooling PR, live guardian observation/finality, tiny real Across fills
and source verification remain execution gates. There is no contract failure requiring a `src/` change.
Rafael already approved the one-wallet role layout, 30 USDC budget and stopping the keeper after smoke.

The full, sanitized address manifest, every transaction hash/receipt gas/price and scenario assertions are in
`local-e2e/reports/2026-10-03-B04-alpha-final.json`. The independent full-size lifecycle and API reports are
`local-e2e/reports/2026-10-03-B04-scenario.md` and `local-e2e/reports/2026-10-03-B04-api-probe.md`.
Fork hashes are evidence only; they are not mainnet explorer transactions. The fixed archive pins were
Arbitrum **511007613**, Robinhood **78293056**. No credential-bearing RPC URL, key, calldata or raw broadcast
file is committed. Both private forks and all API/keeper children were stopped.

### Exact reproducible fork sequence

From this release worktree, after the required shared `lib` and `.env` symlinks:

```bash
CI=true pnpm --dir local-e2e install --frozen-lockfile
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
ALPHA_REHEARSAL_HUB_PORT=18845 ALPHA_REHEARSAL_SPOKE_PORT=18846 ALPHA_REHEARSAL_API_PORT=18847 \
  bash script/rehearse-alpha.sh
```

The script uses the real DeployFactory/CreateFund scripts and checks both chains for **both funds**. The single
throwaway operator `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` is deployer, API signer, manager, keeper,
adapter guardian and Protocol Recipient. The separate investor is `0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC`.
The local Wormhole guardian-set signer and fee-generating trader are fork infrastructure, not alpha wallet roles.

Exact ordered flow in `script/rehearse-alpha.sh` / `local-e2e/src/alpha-final-smoke.ts`:

1. Explicit minimum **2 USDC**, seed budget **5 USDC**, Spoke Cap **100 USDC**, performance fee **2,000 bps**,
   management fee **0**, Operating Cash **0**. Seed/deposit budgets charge only whole-share cost plus flow fee:
   a 5 USDC budget initially mints four shares, not five. Two seeds and the manager's 5 USDC deposit are funded.
2. Deploy both protocol stacks, create first Hub fund and Robinhood Spoke Vault, run both deployment checkers.
   Start authenticated alpha API/keeper, synchronously report **before and after** the manager's 5 USDC deposit.
3. Send **5 USDC** to Robinhood; fill through the real Across SpokePool and match full `FilledRelay` data.
   Report arrival; manually `sendToHub(1000000,Principal,0)`, fill the return, wait for durable acknowledgement,
   prove `inFlightTransitIds` and keeper queue no longer contain the transit. Synthetic relayer funding is additive:
   with one role wallet, never overwrite its remaining seed/investment USDC with the relayer's inventory.
4. Swap half of the remaining spoke allocation through V3, open its Mandate V4 position, generate real LP fees
   with a fork-only trader. Allocate/supply **1 USDC** to the Hub Aave position; advance both clocks one day,
   re-stamp the fork oracle and collect Aave interest. No mock income is credited to the fund.
5. Deliver a report showing earned spoke Income, then the separate investor deposits **5 USDC**. Deliver the
   immediate post-deposit report. Assert `unconvertedIncome(investor,1,USDG) == 0`; request Income Withdrawal,
   deliver COLLECT, match/fill its Income send and confirm its shared slot is freed. Settle the manager's positive
   Attributed Income; assert `incomeOwed(investor) == 0` after conversion too. This is DEC-145's prior-interval proof.
6. Invest remaining Free Idle in the already-open Aave position using **increasePosition**, report, and have the
   investor request a **2 USDC Instant Payout with maxLossBps=500**. Prove automatic Hub unwind and a Hub UNWIND
   order, execute it on Robinhood, match/fill Principal return, report, settle, and report after the share burn.
   The final run pays **1.983821 USDC gross / 1.908657 USDC net**, with **1.992926 USDC** unwind proceeds.
7. Create a second 5 USDC-seed fund on both chains, check both, deposit a separate-investor 5 USDC budget,
   report, close, advance beyond the deadline, unwind/CLOSE, wait for the **specific order id** in its report,
   perform final Income collection, report, finalize, and exit the investor. Manager shares are paid/burned at
   finalization; investor shares are zero after exit and frozen `closedSupply` stays **4e18**.

The full-size regression replay also ran independently on fresh ports 18855/18856:

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
export LOCAL_E2E_ARBITRUM_PORT=18855 LOCAL_E2E_ROBINHOOD_PORT=18856
unset ALPHA_REHEARSAL_SAME_ROLES
pnpm --dir local-e2e run up --warm-up none
pnpm --dir local-e2e scenario
pnpm --dir local-e2e api:probe
pnpm --dir local-e2e down
```

### Addresses and representative receipts

| Role | First fund / shared deployment | Second fund |
|---|---|---|
| Factory, both chains | `0x408EBd63EC5DdB000471452253A73DB682590E5c` | same |
| Core Vault | `0xE83aBE79E1639676F90CF82034cDb8c6dB14f64e` | `0xf28CcCE6D425Bec5117ebaF92Aaf7048E9cc2De1` |
| Hub Spoke Vault | `0x11249C90f34f8cAa50Ff8597A893EE5336C66B7d` | `0xFC340c62C4f6e7Ab18b5c9eF61377737aD6080F7` |
| Robinhood Spoke Vault | `0x323a06D8d48bDf02a78aa882A24894d35C774b32` | `0x5d356D17A4855Dc70F2785A70d1c073f11dD9F89` |
| ShareToken | `0x82c735287B6e8B61d06235b6b5Ab7c0E7FaAf70E` | `0x04CF8efCe306Ea22138C6556eB8b5CE45008D3C0` |
| ValueReportReceiver | `0xD641f0e1Dc8beD2995e8f2897330f30dA13Ea439` | `0xbA34BeF1e70c2d915E044a32CAd2687940de5A00` |

Every receipt is retained in the JSON evidence, including deployments, approvals, reports/deliveries and
fork-only fills/trades. Separate categories prevent attributing third-party relayer/trader costs to the alpha.

### ETH budget: do not confuse Anvil prices with mainnet

The final receipt totals were **132,354,567 gas** for the shared Arbitrum alpha wallet and **70,145,599 gas**
for Robinhood, including both fund creations and repeated synchronous reports. The investor separately used
**2,919,806 gas on Arbitrum**. Fork-only relayer gas was 757,557 / 306,918; the LP trader is excluded entirely.
Anvil is not Nitro: legacy deploys were forced to 0.1 gwei while ordinary runtime EIP-1559 transactions include
Anvil's tip/basefee. The synthetic receipt debits **0.032574957 ETH / 0.018737585 ETH** are therefore **not** the
mainnet funding requirement. Likewise, applying the pinned Anvil `eth_gasPrice` to all gas is not a live quote.

Read-only live sample **October 3, 2026, 04:07:50 UTC**: Arbitrum **20,020,000 wei (0.02002 gwei)**;
Robinhood **29,454,000 wei (0.029454 gwei)**. Repricing all measured EVM gas at those live prices:

| Budget | Arbitrum ETH | Robinhood ETH |
|---|---:|---:|
| Both deployments + both funds + entire rehearsed alpha flow, no 6x discount | **0.002649738** | **0.002066068** |
| Separate investor transactions | 0.000058455 | 0 |
| Rafael's 6x lower-gas planning estimate, shared wallet only | 0.000441623 | 0.000344345 |
| Approved real shared-wallet balance | **0.0115** | **0.0131** |

The wallet covers the undiscounted EVM estimate **4.34x / 6.34x**; use **0.00530 / 0.00414 ETH** as a 2x EVM
planning reserve, not a guaranteed fee cap. Do not divide actual measured receipt gas by six and call it measured
mainnet gas: the 6x value is Rafael's heuristic only. Nitro parent-chain data fees, changing basefee, guardian
count (one local signer versus the real set), live relayer fees and retries are not reproduced by Anvil.
Before each real broadcast obtain the live full gas estimate, including the Nitro data component, and stop if
the remaining wallet cannot cover it. Official fee reference: Arbitrum Docs, “How to estimate gas in Arbitrum”.
No claim is made that these fork EVM costs include the parent-chain data charge.

The 30 USDC budget covers two 5 USDC seeds, a 5 USDC manager deposit and up to 8 USDC sent to the approved
second investor (**23 USDC maximum budget**, before share rounding; no separate extra 5 USDC is needed to send
existing fund assets to the spoke). Bridge/Payout Fees are deducted by the protocol, not additional ETH transfers.
The initial 1% Instant loss bound correctly refused the ~0.622293 USDG return: fixed+variable fee **0.030498**,
arrival **0.591795**, effective loss **4.90%**. The alpha-sized 5% requester bound passes; it does **not** widen
the adapter's fixed fee terms. Keep meaningful allocations disabled until live route terms accept the tiny amount.
The fork produced only about 0.0115 USDC of bridge-returned Income after accelerated fee trades: this is **below
the normal 0.50 USDC runtime COLLECT floor**. Direct contract collection is fork evidence, not authorization to
force an uneconomic live Income send. On mainnet defer until actual fees, conversion and route limits are viable.

### Exact mainnet continuation and stops

Use “Exact deployment order” above for build, DeployFactory, CreateFund, export of the **actual** predictions
and CheckAlphaDeployment on each chain. Never reuse the fork addresses or run `rehearse-alpha.sh` on mainnet.
Override the shared `.env` explicitly; unlock the same approved address for `alpha-operator` and
`alpha-manager`; set `DEPLOYER_ADDRESS`, `MANAGER`, `API_SIGNER`, `ADAPTER_GUARDIAN`, `PROTOCOL_RECIPIENT`
to the approved shared wallet. Keep `REGISTRY_OWNER` unset. Secret-manager/hidden-prompt injection supplies
the same key separately to the keeper/API processes; no key goes into a command file. Keep all three
`ALPHA_ALLOW_LOCAL_TEST_KEYS`, `ALPHA_REHEARSAL_LOCAL_VAA`, `ALPHA_REHEARSAL_SAME_ROLES` unset.
Persist per-fund cursor and transaction records, run the keeper only during smoke, then stop it cleanly.

After first deployment/check and live authenticated report/VAA gate, the ordered manual calls are below.
`report` means the authenticated synchronous `/report` command documented above; wait for HTTP 200/delivered
before each following mint/burn. A human must inspect every successful receipt before the next call.

```bash
. /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
report() {
  printf 'header = "Authorization: Bearer %s"\n' "$ALPHA_API_TOKEN" | \
    bash script/alpha-safe.sh curl --config - --fail-with-body -X POST "http://127.0.0.1:${ALPHA_API_PORT:-8787}/report"
}
hub_send() { bash script/alpha-safe.sh cast send "$@" --account alpha-manager --rpc-url "$ARBITRUM_RPC_URL"; }
spoke_send() { bash script/alpha-safe.sh cast send "$@" --account alpha-manager --rpc-url "$ROBINHOOD_RPC_URL"; }
export ALPHA_INVESTOR_ADDRESS=0x3A3ea619C0f37a7D2fF07FF442d863f316A99A7a
report
hub_send 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'approve(address,uint256)' "$ALPHA_CORE_VAULT" 5000000
hub_send "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 5000000 1
report
# Top up the approved investor with 5-8 USDC only after checking its current balance.
# Check real Across route terms and quoteSend before the tiny send; STOP on unsupported/unprofitable terms.
hub_send "$ALPHA_CORE_VAULT" 'sendToSpoke(uint256,uint256,uint256,bytes)' 0 5000000 0 0x
# Wait for full FilledRelay/TransitArrived match and accepted arrival report; no simulated fill on mainnet.
report
spoke_send "$ALPHA_SPOKE_VAULT" 'sendToHub(uint256,uint8,uint256)' 1000000 0 0
# Wait for real fill, report, durable acknowledgeSpokeTransit/executeOrder and disappearance from inFlightTransitIds.
report
```

Position operations must use the actual Mandate adapter/PoolKey/position key and current tick/spot, not a fork
tick or NFT id. The exact selectors/parameter encoding rehearsed are `swap(adapter,tokenIn,tokenOut,amount,100,0x)`,
`openPosition(adapter,poolKey,amount0,amount1,params)`, `allocateToHubSpokeVault(1000000)` and
Aave `openPosition(adapter,poolKey,1000000,0,abi.encode(uint256(1000000)))`. V4 `params` is
`abi.encode(int24 lower,int24 upper,uint128 liquidity,uint128 amount0Max,uint128 amount1Max,uint128 amount0Min,
uint128 amount1Min,uint256 deadline)` with tick-spacing-valid bounds, liquidity 0 to derive size, approved
nonzero minimums and a future deadline. Never reproduce storage funding, trader loops, oracle writes or time warps.
Wait for genuinely earned income and a report before the late entrant; use that investor's separate keystore:

```bash
report
bash script/alpha-safe.sh cast send 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 'approve(address,uint256)' "$ALPHA_CORE_VAULT" 5000000 --account alpha-investor --rpc-url "$ARBITRUM_RPC_URL"
bash script/alpha-safe.sh cast send "$ALPHA_CORE_VAULT" 'deposit(uint256,uint256)' 5000000 1 --account alpha-investor --rpc-url "$ARBITRUM_RPC_URL"
report
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'unconvertedIncome(address,uint256,address)(uint256)' "$ALPHA_INVESTOR_ADDRESS" 1 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168 --rpc-url "$ARBITRUM_RPC_URL"
# Expected zero before conversion; invoke income phase only after the 0.50 USDC/runtime and live route gates pass.
bash script/alpha-safe.sh pnpm --dir local-e2e exec tsx src/alpha-mainnet-smoke.ts income
bash script/alpha-safe.sh cast call "$ALPHA_CORE_VAULT" 'incomeOwed(address)(uint256)' "$ALPHA_INVESTOR_ADDRESS" --rpc-url "$ARBITRUM_RPC_URL"
# Expected zero for the prior interval after its conversion; fund operations have not earned a later interval yet.
# Invest remaining Free Idle using Aave increasePosition(adapter,positionKey,amount,0,abi.encode(amount)), then report.
report
bash script/alpha-safe.sh cast send "$ALPHA_CORE_VAULT" 'requestPayout(uint256,uint8,uint16)' 2000000 0 500 --account alpha-investor --rpc-url "$ARBITRUM_RPC_URL"
# Wait for Hub UNWIND, spoke executeOrder, full Principal fill match and an accepted post-unwind report.
report
hub_send "$ALPHA_CORE_VAULT" 'settlePayout(address)' "$ALPHA_INVESTOR_ADDRESS"
report
```

For the second fund, keep the first fund's addresses/cursor saved, unset `CREATION_NUMBER`/`MANDATE_HASH`, repeat
the exact Hub CreateFund/export/Robinhood CreateFund/check sequence, start a **new** per-fund runtime cursor,
deposit the investor's approved budget with pre/post reports, and export `ALPHA_EXIT_HOLDER` to that investor.
Run `alpha-mainnet-smoke.ts closure` once: close, manager's immediate unwind/CLOSE (permissionless callers must
wait 72 hours), real return matching/acknowledgements, **final Income collection**, report, finalize and frozen exit.
Do not run the `capital` continuation phase after the manual sequence: it would deposit/send again. On any failure
reconcile saved receipts and state; never blindly replay a partly completed phase. No external-wallet capital.

### Final validation and size budget

`forge build --sizes`, `forge fmt --check`: PASS. Size **3/3 in 1 suite**; non-fork **1,567/1,567 in 193 suites**;
fork **228/228 in 58 suites** with `-j 4`; alpha Node **19/19**; harness Node **12/12**; verification Node **2/2**;
URL redaction **42 cases**; TypeScript PASS; alpha API **5 checks**; full replay **57 steps / 330 assertions**;
full API probe **31 concepts**. No shared fork fixture/new fork suite: CI `SCENARIO_SUITES` unchanged.

Production before = after relative to final main, compiler/optimizer unchanged, limit 24,576 bytes:

| Contract / linked library | Before = after bytes | Margin |
|---|---:|---:|
| AaveV3Adapter | 9893 | 14683 |
| AcrossBridgeAdapter | 6713 | 17863 |
| UniswapV3SwapAdapter | 10586 | 13990 |
| UniswapV4Adapter | 14369 | 10207 |
| CoreVault | 22578 | 1998 |
| CoreVaultClosureLogic | 17052 | 7524 |
| ManagerFeeVault | 1077 | 23499 |
| ManagerRegistry | 1603 | 22973 |
| ShareToken | 1822 | 22754 |
| TransitEscrow | 894 | 23682 |
| Create3Deployer | 1342 | 23234 |
| FundFactory | 18347 | 6229 |
| ChainlinkPriceSource | 1709 | 22867 |
| ValueReportReceiver | 8309 | 16267 |
| SpokeVault | 22907 | **1669** |
| CoreVaultLogic | 13612 | 10964 |
| CoreVaultTransitLogic | 16005 | 8571 |
| CoreVaultIncomeLogic | 18118 | 6458 |
| CoreVaultIncomeCollectionLogic | 17713 | 6863 |
| CoreVaultPayoutLogic | 22547 | 2029 |
| SpokeCrossChainLib | 16953 | 7623 |
| SpokeUnwindLib | 21594 | 2982 |
| SpokeCloseLib | 5875 | 18701 |
| SpokeIncomeLib | 12563 | 12013 |

Tightest executable is Spoke Vault **22,907 B / 1,669 B margin**; no production executable has <1,000 B margin.
Full CodeStore chunks have **0 B margin** by deliberate STOP+data layout; do not enlarge them. Inlined libraries
have no deployed entry point. The size suite checks every production source declaration.

Scope deviations: only rehearsal scripts/runtime/runbook changed; no production source changes. Shared-role
funding is additive, the Aave follow-on uses increasePosition, final collection precedes closure, and CLOSE proof
matches the actual order id instead of any nonempty historical blob. The 5% Instant requester bound is an explicit
alpha-size execution choice, not a protocol/spec change. Existing DEC-185/native Operating Cash/refund deferrals
remain per October 2 ruling; DEC-186 caps management fee at 500 bps; DEC-187 manager pays own gas. No new
monetary spec divergence found. Live guardian/finality, Across economics/refunds, explorer verification and
authenticated service supervision cannot be certified by a local fork; keep them as mandatory live stops.
