# Raydium CLMM track — POO-2259

DEC-190/193/194/195 govern this adapter. Existing TSLAx/USDC is primary;
SOL/USDC is the approved fallback. No pool creation, farm claim, swap route,
Manager-owned position, native Fund fee treasury, or mainnet transaction exists.

## Implemented interface

- `raydium_open_position`: strict Borsh payload inside the shared `Vec<u8>`:
  `i32 lower, i32 upper, u128 liquidity, u64 max0, u64 max1, u128 minLiquidity`,
  all little-endian. Both liquidity values must be positive. Fixed aligned ticks
  must satisfy creation-time policy bounds. No EVM zero-liquidity shorthand.
- `raydium_collect_fees`: empty payload, zero-liquidity `decrease_liquidity_v2`.
- `raydium_close_position`: `u64 minPrincipal0, u64 minPrincipal1`, little-endian.
  Decrease all recorded liquidity, collect fees, burn/close Token-2022 NFT and
  transfer the measured refunded lamports from the vault to the original payer.
- `validation::valuation`: returns `(raw principal[2], uncollected trading fees[2])`
  with full-width Q64 floor math, current sqrt price and both boundary fee-growth
  checkpoints. Reports must also include position identity, ticks, liquidity,
  mints and issuer state for codec v6. Independent USD pricing stays on the Hub.

Wire and account layouts are pinned to `raydium-io/raydium-clmm` commit
`ed1eb41519d5355755f7df52b43fa9610938b60b`. Successful CPIs against cloned
deployed programs prove exercised ABI compatibility, not binary/source equality.
Canonical tick arrays and bitmap extensions are checked; no arbitrary remaining
accounts are forwarded. TSLAx checks its eight observed extension kinds, dormant
hook, public initialized accounts, unpaused state, and both unit multipliers.
Issuer powers remain external risks and cannot be overridden by the adapter.

CLMM uses the same payer for rent and token transfers. The adapter temporarily
approves the Manager for capped token amounts, executes the pinned CPI, then
revokes both delegates atomically. Vault tokens/NFT remain Fund-owned.

## Coordinator requests — required before funding

1. Create immutable `RaydiumPolicy` at `[b"raydium_policy", fund, pool]` during
   authenticated Fund initialization; bind Fund, Mandate hash, exact pool and
   tick bounds. No public initializer/setter is provided by T4.
2. Create `RaydiumLedger` at `[b"raydium_ledger", fund, pool]`. Only authenticated
   arrivals/allocations may credit idle principal; reconcile/debit it across
   CCTP, Kamino and swap modules atomically. Raw balances/donations and idle
   income are not entry budget. Do not double-count these buckets in reports.
3. Report registered `RaydiumPosition` accounts at `[b"position", fund, personal]`,
   valuation results, ledger buckets and cumulative/collected fees exactly once.
   Authenticate Hub collect/unwind dispatch separately; these public entrypoints
   require the bound Manager and reject closed Funds.
4. Create segregated reward token accounts at `[b"raydium_reward", fund, mint]`
   owned by the vault, never ordinary pair ATAs. Required optional reward triples
   are passed in initialized slot order. Any reward transfer rolls back atomically.
5. Coordinate Raydium error codes 7400–7409 and track events. Update shared
   entrypoint comments that still call implemented handlers scaffolds.
6. Retained position-record rent is refundable only when the coordinator defines
   authenticated report acknowledgement/record retirement. No premature GC exists.

## Unresolved decisions / safe restrictions

- **TODO(decision):** shared ledger allocation/report lifecycle and authenticated
  creation transport. Without T1 provisioning, entries fail closed.
- **TODO(decision):** farm claims versus mandatory auto-collection in Raydium.
  Existing ended reward slots with zero newly earned rewards work. If a pool
  starts emitting, any forced reward transfer rolls back; previously accrued
  rewards can prevent collection/closure. Do not call this a guaranteed exit.
- **TODO(decision):** late issuer seizure/pause/active-hook/non-unit multiplier
  recovery follows coordinator excess/valuation rules; unsupported states reject.
- **TODO(decision):** swap venue and DEC-136 overlap remain unresolved; increase,
  partial decrease and swaps stay scaffolded, outside this open/collect/close task.

## Reproduce safely

Run inside `solana/`, with local-only generated wallets:

```sh
export PP_LOCALNET_RPC_PORT=8940 PP_LOCALNET_FAUCET_PORT=9940
export PP_LOCALNET_GOSSIP_PORT=14000 PP_LOCALNET_DYNAMIC_PORTS=14001-14060
npm ci
anchor build
./scripts/localnet.sh prepare
node tests/raydium/fixture-extension.ts
./scripts/localnet.sh start
node --test tests/raydium/lifecycle.test.ts
./scripts/localnet.sh stop
cargo test --locked
npx tsc --noEmit
```

The explicit fixture extension clones memo/reward accounts read-only; only local
Fund/policy/ledger/quarantine/wallet accounts are synthesized, never pool/mint
state. It exercises both pools, unauthorized/wrong-Fund/wrong-pool/zero-liquidity
and principal-budget negatives, a direct pool swap, real fee realization,
ledger segregation, NFT closure, rent neutrality, CU and versioned tx size.
ALTs are local test tables; production clients must provision their own tables.

512 deterministic SDK vectors are checked by the Rust suite. Regenerate without
changing workspace manifests/locks using an isolated SDK installation:

```sh
npm install --prefix /tmp/pp-raydium-sdk --ignore-scripts @raydium-io/raydium-sdk-v2@0.2.73-alpha
PP_RAYDIUM_SDK_ROOT=/tmp/pp-raydium-sdk node tests/raydium/generate-math-vectors.cjs > /tmp/raydium-vectors.csv
diff tests/raydium/math-vectors.csv /tmp/raydium-vectors.csv
```
