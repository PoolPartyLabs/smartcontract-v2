# Deployment

How the protocol operator deploys the Fund Factory on each chain and how a manager creates a fund. Scripts:
`script/DeployFactory.s.sol`, `script/CreateFund.s.sol` (both built on `script/FactoryDeployment.sol` and
`script/FundMandate.sol`, which the fork tests in `test/fork/factory/` run too). Addresses: `docs/INTEGRATIONS.md`.
Always rehearse on a fork first (anvil or `--fork-url`), then broadcast with the same command and a keystore.

## Addressing

- Every fund contract sits at a CREATE3 address (`src/factory/Create3.sol`): it depends only on the factory address
  and the salt `keccak256(abi.encode(fundId, role, chainId))`, never on creation code. The Mandate, which the vaults'
  creation code contains, can therefore list every hub and spoke address before any of them exists (DEC-053, DEC-054).
- `fundId = keccak256(abi.encode(hubChainId, factory, n, manager))`, where `n = NUMBER_OFFSET + creation count` (first
  fund `NUMBER_OFFSET + 1`). The Share is `Pool Party Fund {n}` / `PP-{n}`, no manager text (Q59 stance, OPEN). The
  Manager is bound into the id, so only the Manager's key can create a contract at any of the fund's addresses, on any
  chain (DEC-001, FF-OQ-1).
- A fund id is always derived by the factory, never taken from a caller: `createFund` derives it with this chain as
  hub, `createSpoke` with `Mandate.hubChainId`, which must not be the chain it runs on (`SpokeOnHubChain`). No spoke
  can therefore consume the salts of a fund the local factory would create as hub (DEC-054).
- Roles: `CoreVault`, `SpokeVault`, `UniswapV4Adapter`, `AaveV3Adapter`, `AcrossBridgeAdapter`,
  `ValueReportReceiver`. The Core Vault creates its `ShareToken` (CREATE nonce 1) and `ManagerFeeVault` (nonce 2)
  itself (ruling 2026-09-29), so they have no salt; `predictAddresses` returns them too.

## One factory address on every chain

The factory's protocol wiring (USDC or USDG, Across SpokePool, Wormhole Core, Uniswap V4, Aave, ManagerRegistry, price
source, Protocol Recipient, adapter guardian, flow fee, linked libraries) is immutable and differs per chain, so its
creation code differs per chain and a plain CREATE2 through the deterministic deployer
(`0x4e59b44847b379578588920cA78FbF26c0B4956C`, present on Arbitrum One and Robinhood Chain) would give a different
address on each chain. Instead:

1. `Create3Deployer` (no constructor arguments) goes through the deterministic deployer: one address everywhere.
2. The operator calls `Create3Deployer.deploy(FACTORY_SALT, factory creation code + this chain's wiring)`. The salt is
   bound to the caller, so **the same operator key with the same salt gets the same factory address on every chain**,
   and nobody else can claim it.

The factory address is what every fund prediction is a function of: deploy the factory with the same operator and
`FACTORY_SALT` on every chain a fund may use, and never with another key.

## Operator: per chain, in order (`script/DeployFactory.s.sol`)

| Step | Arbitrum One (hub) | Robinhood Chain (spoke) |
|---|---|---|
| `Create3Deployer` via the deterministic deployer | yes | yes |
| `SpokeCrossChainLib` via the deterministic deployer (chain-independent address) | yes | yes |
| `SpokeUnwindLib` via the deterministic deployer (chain-independent address; DEC-131) | yes | yes |
| `SpokeCloseLib` linked to `SpokeUnwindLib`, via the deterministic deployer (DEC-131/147/149) | yes | yes |
| `CoreVaultLogic` via the deterministic deployer | yes | no |
| `ManagerRegistry(owner)`, `ChainlinkPriceSource` (WETH on ETH / USD, USDC and USDG at 1:1) | yes | no |
| Creation code stores (`CodeStore`): Spoke Vault (linked, 2 chunks), Uniswap V4, Across | yes | yes |
| Creation code stores: Aave V3, ValueReportReceiver | yes | no |
| `FundFactory` via `Create3Deployer` with `FACTORY_SALT` | yes | yes |

```bash
set -a; . ./.env; set +a
export PROTOCOL_RECIPIENT=0x... ADAPTER_GUARDIAN=0x... API_SIGNER=0x...
# fork first
forge script script/DeployFactory.s.sol --fork-url $ARBITRUM_RPC_URL --sender <operator>
forge script script/DeployFactory.s.sol --fork-url $ROBINHOOD_RPC_URL --sender <operator>
# then broadcast on each chain with the same operator
forge script script/DeployFactory.s.sol --rpc-url $ARBITRUM_RPC_URL --account <operator> --broadcast --slow
forge script script/DeployFactory.s.sol --rpc-url $ROBINHOOD_RPC_URL --account <operator> --broadcast --slow
```

`API_SIGNER` is the Pool Party API key: the route signer of every fund's swap adapters and, on the hub, the owner of
the `ManagerRegistry` (DEC-170 item 3), so `REGISTRY_OWNER` defaults to it; set `REGISTRY_OWNER` only to choose another
owner (required when `API_SIGNER` is zero). In the MVP the key is never rotated: a new key needs a new factory (DEC-170
item 4). The Across adapters take no API key (DEC-176).

Check that both runs print the same `FundFactory` address and the same Spoke Vault code hash. The factory records
`creationCodeHash(role)` for every stored role and `coreVaultCreationCodeHash`, the hash of the Core Vault creation
code linked to `CoreVaultLogic`; publish them with the release so anyone can compare with a local build.

Robinhood's factory has no hub wiring (`createFund` reverts `HubNotConfigured`) and `NUMBER_OFFSET` 1,000,000 so a
future hub there never reuses Arbitrum's numbers.

## Manager: create a fund (`script/CreateFund.s.sol`)

1. On the hub: `n = nextCreationNumber()`, `predictAddresses(n, manager, [42161, 4663])`, build the Mandate from those
   addresses
   (`FundMandate`), call `createFund(mandate, HubParams{n, hub PoolKeys, Core Vault creation code})` from the manager's
   address (DEC-001: the creator is the Manager). If another fund took `n` first, the call reverts
   `CreationNumberTaken`; predict again. `FundCreated` carries `fundId`, `mandateHash` and every address.
2. On each spoke: rebuild the same Mandate and call `createSpoke(n, mandate, SpokeParams{mandateHash, spoke
   PoolKeys})` from the same manager. The factory derives `fundId` from `mandate.hubChainId`, `n` and
   `mandate.manager`; the Spoke Vault lands at the address the hub's Mandate already names.

```bash
export FUND_FACTORY=0x... MANAGER=0x...
forge script script/CreateFund.s.sol --rpc-url $ARBITRUM_RPC_URL --account <manager> --broadcast
export CREATION_NUMBER=<from the log> MANDATE_HASH=<from the log or FundCreated>
forge script script/CreateFund.s.sol --rpc-url $ROBINHOOD_RPC_URL --account <manager> --broadcast
```

The script's optional rule values are listed in `.env.example`. The spoke Operating Cash floor and top-up
(`SPOKE_OPERATING_CASH_FLOOR`, `SPOKE_OPERATING_CASH_TOP_UP`) default to 0, and the hub has no Operating Cash entry:
Operating Cash is out of the MVP (ruling 2026-10-02; native Operating Cash, DEC-130 and DEC-144, and the gas refund come
after the buildathon), so a fund locks no value there.

What the factory refuses: a caller other than `Mandate.manager`; a chain other than the Mandate's hub for `createFund`;
a Mandate USDC or spoke token that is not the chain's base token; any Mandate adapter, bridge adapter or Spoke Vault
address, on any chain, other than the fund's prediction; Uniswap V4 `PoolKey`s that do not hash to the Mandate's pool
ids in order; Core Vault creation code other than the pinned one; a Mandate on the spoke whose hash differs from the
one passed in; a second `createSpoke` for the same fund and chain; `createSpoke` on the Mandate's own Hub Chain. Constructor reverts of the fund contracts surface
unchanged (for example `FillDeadlineBufferTooShort` when an Across SpokePool's buffer drops below 6 h, DEC-066).

## Measured (anvil forks at the .env pinned blocks, 2026-09-29)

| Call | Gas | Calldata |
|---|---:|---:|
| `createFund` (Uniswap V4 + Aave V3 + Across on the hub, one spoke) | 19.76M | 36 KB (the Core Vault creation code is 33.8 KB) |
| `createSpoke` (Uniswap V4 + Across) | 9.10M | small |

Both fit the 32M per-transaction limit of Arbitrum One. On Arbitrum the 36 KB of calldata also pays L1 data cost.

## Known limits (see docs/OPEN-QUESTIONS.md)

- **FF-OQ-1, spoke authenticity.** A spoke cannot see the hub, so `createSpoke` trusts the `mandateHash` it is given.
  Since the fund id binds the Manager, a stranger can no longer create a real fund's Spoke Vault first: another
  manager derives another fund id and other addresses. The residual is the Manager's own faithfulness: the Manager
  alone could create the spoke from a Mandate other than the hub's. Before relying on a spoke, check that its
  `mandateHash()` equals the hub's. A hub-attested `FundCreated` (Wormhole message verified by the spoke factory)
  would close it.
- **FF-OQ-2, factory address.** "Same factory bytecode at the same address through the deterministic deployer" is
  not possible with per-chain immutable wiring; `Create3Deployer` gives the same address with per-chain code.
