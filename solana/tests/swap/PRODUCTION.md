# Signed V2 production wiring — T8c

DEC-190/200 bootstrap verifies the fixed EVM/Solana Manager tuple. DEC-202 API
quotes are the sole quote authority. DEC-203 allows explicit 0 or >=10000 bps
as no maximum; no placeholder Manager value is supplied by production code.
Fresh oracle identity, Full verification, price and confidence remain mandatory
even without a maximum (DEC-204). `max(API min, oracle min)` uses upward rounding.

## Creation and persistent state

`swap/config.rs` defines the Borsh `SwapPolicy`, `CreationPolicy`, `StagedPolicy`
and per-Fund `SwapConfig`. The EVM Manager signs an additional typed consent:

`SolanaSwapPolicy(bytes32 fund,bytes32 bindingDigest,bytes32 policyHash)`

The domain matches quote v2, with program ID as salt; this consent's `policyHash`
is Keccak of the exact Borsh `SwapPolicy` (the initializer's `swap_policy_hash`).
The native Config ABI adds final `bytes32 swapPolicyHash`, so its tuple header
is 544 bytes. Both the native mandate hash and identity-free native policy hash
include this commitment. Identity-free hashing zeros the emitter, mint recipient,
destination caller and remote vault authority, not the swap-policy commitment.
The canonical Fund `policyHash` is Keccak of the concatenated policy namespace
hash, `hub_policy_hash` and identity-free native policy hash. Fund seeds are
`[fund, LE64(hubChain), core, LE16(spokeIndex), policyHash]`.
Bootstrap typed data adds `bytes32 policyHash` immediately after `mandateHash`.
`InitializePayload` ends with `hub_policy_hash`, `policy_hash`, `swap_policy_hash`,
each 32 bytes, before the appended `CreationPolicy`.
Canonical bootstrap/native/Fund binding to the swap-policy commitment is solved.
The prior coordinator escalation concerns only approval/removal of the additional
redundant policy-consent domain/ABI, not missing commitment binding.
This is cryptographic consent, not a rule allowing Manager/API oracle replacement.

Large configs use the named `stage_swap_policy` instruction, never
`swap_exact_in`. Its accounts are `[authority mut signer, fund unchecked,
stage mut PDA, system_program]`; stage seeds are
`[swap_policy_stage, fund, manager]`. The Borsh request is
`StageRequest { policy_hash: [u8;32], total_len: u16, offset: u16,
chunk: Vec<u8>, seal: bool }`. Stage the full `InitializePayload + CreationPolicy`
in ordered chunks of at most 600 bytes, sealing only the final chunk. Requests
are wrapped in the instruction's Borsh `Vec<u8>`. Unverified staging never
admits a Fund or authorizes capital.

`initialize_fund` receives the one-byte payload `[2]`, with remaining
`[swap_config mut, stage mut]`, followed by `[NVDAx mint, NVDAx ATA, NVDAx ledger]`
when admitted. Initialization revalidates the stage's Fund, Manager, policy hash,
bootstrap and policy-consent signatures, seals `swap_config`, and closes/refunds
the stage to the Manager (DEC-195). No live setter exists. Without policy no
production swap can execute. The composed fixture admits USDC/WSOL/NVDAx and
one SOL/USDC venue; chunking keeps the initialization packet compact.

Generic no-swap initialization uses the same stage PDA and requests with a zero
`swap_policy_hash`; remaining accounts are `[stage mut]`, followed by any NVDAx
mint/ATA/ledger. Core send helpers estimate the complete v0 packet using a lookup
table and stage payloads that exceed 1232 bytes. The rehearsal stages the full
LP initializer rather than relying on the previously borderline compact packet.
`npm test` includes offline production hash/signature, chunk reconstruction,
replay-model rejection and generic full/compact packet regression tests. The
replay model tests client fixtures, not on-chain validator enforcement.

`swap_to_ratio` accepts existing `AuthorizedSwap`; remaining accounts are:

`[Jupiter route accounts..., swap_config, Pyth SOL, Pyth USDC, Chainlink SOL, input ledger, output ledger]`

Policy pins SOL/USDC accounts and feeds, API signer, <=300s age, confidence,
advisory Chainlink threshold and route slippage. Nonce and observed canonical
principal conversion persist only after every CPI/postcondition succeeds;
failure of a later LP instruction rolls back the entire transaction.
`TODO(decision)`: stock subscriptions are unresolved (`sol-oracle-Q2`); config
retains `stock_enabled` but rejects true until an approved fresh source lands.
`reference_mode=0` is DEC-203 option A; other values fail closed, not alternate
code paths. Primary Pyth failure never falls back to the signed quote.

## NVDAx and valuation

NVDAx raw mint units stay in custody, ledgers and report principal/fee arrays.
The report supplies current/new multiplier IEEE bits plus activation timestamp.
Live finalized clone confirmed `3ff003c2ac1bf43f / 3ff006f7d589fea9 / 1789000200`;
effective multiplier is 1.001701196801074, not a rounded decimal constant.
Both mint witnesses and Raydium validation reject changed tuples and writable
mint accounts, preventing a CPI from changing units mid-operation. The Hub
already applied `0x1006f7d589fea9 / 2^52` to NVDA/USD in the integration baseline;
T8c verifies it against the real feed instead of applying a second multiplier.

DEC-206 incidental rewards on exit go only to validated quarantine accounts;
no reward amount is added to principal/income. Exits no longer reject merely
because rewards accrued. Nonzero incidental-reward transfer is not demonstrated
by this fixture; its RAY quarantine remains zero during this run.

## Reproduce (local transactions only)

Only run after the main engineer authorizes validator testing. Run from
`solana/`, never a mainnet transaction endpoint. Preparation refreshes finalized
accounts using read-only `getAccountInfo`, recording slots and hashes in
`swap-production-clones.json`. Source the approved read-only RPC environment
script before preparing when required; `SOLANA_MAINNET_RPC` overrides the public
default without printing its value. No EVM request or mainnet transaction is
sent by this helper. Refresh oracle snapshots immediately before the rehearsal;
old snapshots do not bypass the strict oracle age checks.

```sh
npm ci
anchor build
node tests/swap/production.prepare.ts
PP_LOCALNET_RPC_PORT=8970 PP_LOCALNET_FAUCET_PORT=9970 \
  PP_LOCALNET_GOSSIP_PORT=17000 PP_LOCALNET_DYNAMIC_PORTS=17001-17060 \
  bash tests/swap/production.start.sh
PP_LOCALNET_RPC_PORT=8970 node --test tests/swap/production.localnet.test.ts
./scripts/localnet.sh stop
```

Preparation creates/retains `production-api-key.json` under ignored `.localnet/`
with owner-only permissions on creation. Its default is a deterministic public
test-only key, never a production credential. The test loads the same local
file without regeneration; preparation derives reward quarantine addresses and
owners from the resulting canonical Fund and vault. Do not print key contents.
Changing/removing this file requires preparing quarantine fixtures again.

Track extension changes only local snapshots, synthetic Manager WSOL/reward
quarantine accounts, and Circle's explicitly local attester fixture. Protocol
mint/pool/oracle bytes stay cloned. The launcher uses 32-slot epochs so a huge
mainnet-slot warp does not advance Clock by ~15 hours against fresh oracle bytes.
Mainnet epoch behavior is not proven by that local timing setting. Ports are
8970/9970/17000/17001–17060 by default, with the four port overrides shown above.
Oracle freshness is intentionally strict; preparation refreshes the oracle
snapshots instead of loosening policy. No RPC URL or secret is printed by these helpers.

Historical pre-#47 composed run: signed swap + open **387197 CU / 799 bytes**, collected
**10 raw USDC** trading fees with principal unchanged, **1952 report bytes**,
consistency **32**, NVDAx witness present, position close and zero Fund SOL.
Forged/expired/wrong-nonce/impact/stock-disabled requests fail; a submitted
swap + invalid-open transaction fails with unchanged nonce/ledgers/custody.
The committed report fixture round-trips the actual Hub v6 decoder.
These historical metrics do not validate the new commitment/chunked-staging
schema; an authorized composed rerun is required. Evidence is clone-based,
not deployment approval or mainnet readiness.
