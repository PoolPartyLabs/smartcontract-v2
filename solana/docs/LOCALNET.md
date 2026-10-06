# Read-only mainnet clones, loopback-only execution

## Workflow

```sh
cd solana
npm ci
anchor build
./scripts/localnet.sh prepare
./scripts/localnet.sh start
npm run test:localnet
./scripts/localnet.sh stop
```

Run commands **inside `solana/`**. The Node 24.14.0 runner executes TypeScript
directly and discovers each track's `tests/**/*.test.ts` without shared runner
edits. `npm test` runs only offline unit tests. `npx tsc --noEmit` checks types.
`anchor test --skip-local-validator --skip-deploy` can invoke the same tests;
the binary is loaded at genesis, so no scaffold program private key is needed.

`prepare` uses public mainnet RPC by default, only `getAccountInfo` at
`finalized`; no transaction method is admitted. `SOLANA_MAINNET_RPC` can be
supplied by an env-loading wrapper if public cloning is rate-limited; scripts
never print the endpoint or load production keypairs. Reads back off up to five
times, with a default 350 ms delay (`SOLANA_CLONE_DELAY_MS` can increase it).
All fixture keys are generated locally under ignored `.localnet/`, mode 0600.

`start` never contacts mainnet: it loads dumped accounts/programdata with
`--account-dir`, a loopback validator and the local compiled SBF binary. This
is the cached equivalent of `--clone` / `--clone-upgradeable-program`, with
explicit owner/discriminator checks, hashes, and a reusable clone graph instead
of a rate-limited monolithic CLI fetch. Agave's validator was already installed;
Surfpool adds no needed dependency for this bounded snapshot and was not adopted.
The Node transaction helper rejects non-loopback RPC. The launcher refuses to
replace another process on port 8899; stop only the PID owned by this worktree.
The local config does not change the user's Solana CLI cluster/keypair defaults.

## Clone graph

- Raydium CLMM binary and ProgramData; TSLAx/USDC pool
  `8aDaBQkTrS6HVMjyc6EZebgdiaXhLYGriDWKWWp1NpFF` and SOL/USDC fallback
  `3ucNos4NbumPLZNWztqGHNFFgkHeRMBQAVemeeomsUxv`; derive configs,
  observations, vaults, bitmap extension and seven arrays centered around each
  pool's current-price array (`floor(tick / (60 * spacing))`, big-endian seed).
  Missing optional uninitialized arrays are recorded, not fabricated. Wider
  position ranges/swaps require a fresh snapshot or extra arrays from T4/T5.
- Kamino klend binary/ProgramData; main lending market and USDC reserve;
  decode liquidity supply/fee vault, cToken mint and collateral vault from the
  reserve. Clone Scope price state for extensions; supply-only refresh smoke
  explicitly skips price updates and therefore does not need oracle CPIs.
- Circle **V2**, never V1: MessageTransmitter and TokenMessengerMinter binaries/
  ProgramData, transmitter, messenger, minter, Arbitrum remote messenger,
  USDC local-token/custody, Arbitrum-USDC token pair, fee recipient's USDC ATA.
  Sender/event authority and destinationCaller signer PDAs are empty addresses
  when first used, not initialized mainnet state. Message-specific nonce,
  message event and attestation fixtures are T1b test additions.
- Wormhole core binary/ProgramData, Bridge config, fee collector and **current
  guardian set derived from config**, not a hardcoded guardian index. Posting
  emitter/sequence/message accounts are new per-Fund accounts. Historical VAAs
  need their corresponding guardian-set fixture added by T1.
- USDC, TSLAx and WSOL mints; legacy SPL Token, Token-2022 and ATA executable
  programs including ProgramData where upgradeable. No Solana Chainlink program.

All IDs originate in the supplied verified research; each snapshot records
owner, SHA-256 and finalized read-slot range in `.localnet/manifest.json`.
Dumped `rentEpoch` is normalized to zero: the retired rent-epoch field can be
u64-max on mainnet, beyond JavaScript's exact-integer JSON range; otherwise
validator account JSON parsing fails. Account data, lamports and owners are not
changed by this normalization.
Raydium pool layouts are pinned to research source `raydium-clmm`;
Kamino Borsh field offsets to klend-sdk
`38845294447623f6de3afc9dec29875f959f6f48`; Circle seed/layout references to
`solana-cctp-contracts/programs/v2`; Wormhole BridgeData is a 24-byte account
without an Anchor discriminator. Layout mismatch fails rather than guessing.

## Funding and clock

Wallet SOL is synthetic genesis lamports (100 SOL per local Manager/keeper).
USDC and TSLAx use ATAs overridden at genesis: copy a **cloned pool vault's**
token-account allocation/extensions, replace owner/mint/amount, clear legacy
delegate/native/close-authority fields, and initialize it. This preserves
Token-2022 extension sizing, but is **not** a issuer mint, eligibility proof or
mainnet token transfer. Protocol vaults and mint data are never overridden.
Balances are artificial and mint-supply totals are not a global invariant in
this local fixture. The Fund itself is never pre-funded with SOL (DEC-195).
`testWallet`, `testAta`, `fundSol`, `sendLocal` are shared helpers. A test can
move fixture USDC/TSLAx through actual Token CPIs; issuer restrictions must still
be tested by T4, not erased from the mint. No private fixtures are committed.

The validator warps to the latest cloned slot to avoid slot-underflow in
Kamino interest refresh. Reads are not an atomic bank snapshot; the manifest's
slot range documents this. Local wall-clock time is used after startup, not a
promise of historic market-time pricing. TSLAx valuation is admitted only in
US market hours on the Hub (DEC-194); the smoke price ratio is diagnostic,
**never** an independent NAV oracle. Re-clone immediately before integration
tests/demo rather than treating snapshot capacity/config as permanent.

## Proof and limitations

The smoke test reads both Raydium pool states/spot ratios and the Kamino USDC
reserve, then **executes** deployed Kamino `refresh_reserves_batch(true)` and
checks program-success logs, current-slot update and compute usage. This is
stronger than an executable flag/read-only quote alone. It also simulates the
compiled spoke and checks `NotImplemented` (6000) with unchanged local accounts.
Agave 2.3.0 produced a transient `Program cache hit max limit` on the first
Kamino preflight after genesis/warp; repeating the preflight succeeded. The local
send helper retries **only** this exact preflight error with an empty transaction
signature. It never retries a submitted transaction or economic/ABI failure.
It does not prove Raydium LP Token-2022 execution, Circle mint/attestation flows,
Wormhole guardian delivery or an end-to-end Fund. Those are owner-track gates.
External deployed binaries are upgradeable and are not proven equal to the
research source commits. No clone proves mainnet safety/capacity or authorizes
mainnet transactions. DEC-188–195 remain the governing rules.
