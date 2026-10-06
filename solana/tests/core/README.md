# T1 core/report validation

DEC-188, DEC-190, DEC-192, DEC-195 govern this isolated test suite. No mainnet
transaction is authorized. Use the mainnet-state harness, on this track's ports:

```sh
export PP_LOCALNET_RPC_PORT=8910 PP_LOCALNET_FAUCET_PORT=9910
export PP_LOCALNET_GOSSIP_PORT=11000 PP_LOCALNET_DYNAMIC_PORTS=11001-11060
cargo test --locked
anchor build
npm ci --ignore-scripts
./scripts/localnet.sh prepare
node tests/core/prepare-fixtures.ts
./scripts/localnet.sh start
node --test --test-concurrency=1 tests/core/core.test.ts tests/report/report.test.ts
./scripts/localnet.sh stop
```

Run commands from `solana/`. The fixture extension writes only ignored genesis
overrides inside this worktree. It creates a synthetic already-initialized Fund,
a recorded USDC ledger of 50 USDC and a token account containing 60 USDC. The
10-USDC difference is an intentional donation/excess, excluded from reports.
There are no additional mainnet clone addresses. Ephemeral ECDSA test signing
keys are generated in memory and are never saved or printed. Noble crypto comes
from the existing locked web3.js dependency tree; no manifest or lock changed.

**Synthetic state is not proof of Hub deployment or EOA status.** Initialization
with a valid EIP-712 binding and Solana signer intentionally reaches
`BootstrapNotAuthenticated` without creating accounts. Wrong key, expiration,
claimed contract address and duplicate Fund PDA tests cover rejection paths.
The claimed-contract test is not an EVM `extcodesize` proof: that requires the
unresolved authenticated Hub creation evidence. Rust tests additionally check
an independently signed exact EIP-712 digest, nonce/domain/fund changes and low-s.

Report tests execute the actual spoke SBF binary and its CPI into the cloned
mainnet Wormhole binary, not a mock. They inspect canonical report bytes,
Finalized VAA metadata 32 (CPI enum 1), monotonic sequences, keeper-paid live
Bridge fee and unchanged custody. Golden-vector Rust tests match both fixtures
from the T2a Hub track byte-for-byte. Posting locally is **not** proof of guardian
VAA delivery. Hub order verification Rust fixtures test authenticated-account
structure, not live guardian verification; dispatch remains fail-closed.

## Integration gates

- `TODO(decision)`: authenticated factory creation/EOA evidence, trusted factory
  identity, binding commitment and EVM/native Mandate transport. Do not remove
  the bootstrap gate or replace it with caller-supplied Manager/config data.
- `TODO(interface)`: T3/T4 position enumeration, valuation and collection; T1b
  persistent transit/arrival/ACK registry; resumable order/result execution.
  Every writer must maintain `active_positions`, `pending_transits` and
  `pending_results`, and use the core Manager guard and internal ledger helpers.
- `TODO(interface)`: verified TSLAx Token-2022 extension/frozen/hook/multiplier
  witnesses. Stock reports fail closed even at zero holdings until integrated.
- `TODO(decision)`: sealed excess/late-arrival garbage-collector recipient.
- Coordinator: approved program identity, separate Mandate PDA if required in
  addition to sealed Fund config, unique error ranges/shared events, and refresh
  T0's scaffold-only assertions. `build_report` refuses >1024-byte return data;
  `publish_report` encodes independently and does not truncate it. Larger real
  reports still need measured SBF heap/CU/account forwarding limits.

The initialization instruction remains named `initialize_fund`, as declared in
the coordinator-owned `lib.rs`; no second `initialize_spoke` entrypoint is added.
The native config hash follows T2a's v6 registry exactly. Wormhole/Circle program
IDs are compile-time pinned in track-local custody helpers, not Manager-settable.
Fund PDA allocation tolerates unsolicited rent donations; no balance-derived
economic credits or native SOL spending/unwrap paths exist.
