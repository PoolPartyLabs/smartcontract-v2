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

The domain matches quote v2, with program ID as salt; `policyHash` is Keccak of
the exact Borsh policy. The bootstrap signature format remains unchanged.
`TODO(decision)`: approve the additional policy-consent domain/ABI with T8b.
This is cryptographic consent, not a rule allowing Manager/API oracle replacement.

Large configs require staging. Until the coordinator adds a named instruction,
`swap_exact_in` is **staging only**, not a token swap. Its payload is
`StageRequest { binding_digest, creation }`; one remaining signer account is a
Manager-rent-funded temporary account. Anyone may stage only with their own
signatures/rent; unverified staging never admits a Fund or authorizes capital.
The creation handler validates the EVM consent against the bootstrap digest,
Fund and fixed Solana signer, atomically seals `swap_config`, zeros the consumed
temporary account and refunds only Manager rent (DEC-195). No live setter exists.
Unconsumed staging rent has no cancellation path yet; clients must pre-simulate.

`initialize_fund` accepts either an appended `CreationPolicy`, or unchanged
bootstrap payload plus remaining `[swap_config, staged_policy]`. Append
`[NVDAx mint, NVDAx ATA, NVDAx ledger]` when admitted. Without policy no production
swap can execute. Large Mandates can still exceed the 1232-byte packet ceiling;
the verified fixture admits USDC/WSOL/NVDAx and one SOL/USDC venue. Larger
Kamino + multiple-LP configurations require T8b's compact commitment/bootstrap.

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

Run from `solana/`, never a mainnet transaction endpoint:

```sh
npm ci
anchor build
./scripts/localnet.sh prepare
node tests/swap/prepare-v2.ts
node tests/swap/production.prepare.ts
bash tests/swap/production.start.sh
PP_LOCALNET_RPC_PORT=8990 node --test tests/swap/production.localnet.test.ts
./scripts/localnet.sh stop
```

Track extension changes only local clones, synthetic Manager WSOL/reward
quarantine accounts, and Circle's explicitly local attester fixture. Protocol
mint/pool/oracle bytes stay cloned. The launcher uses 32-slot epochs so a huge
mainnet-slot warp does not advance Clock by ~15 hours against fresh oracle bytes.
Mainnet epoch behavior is not proven by that local timing setting. Ports are
8990/9990/19000/19001–19060. Reclone immediately before the suite: oracle freshness
is intentionally strict. `prepare-v2.ts` rewrites its tracked extension inventory;
restore that generated metadata unless intentionally publishing new evidence.

Verified composed run: signed swap + open **387197 CU / 799 bytes**, collected
**10 raw USDC** trading fees with principal unchanged, **1952 report bytes**,
consistency **32**, NVDAx witness present, position close and zero Fund SOL.
Forged/expired/wrong-nonce/impact/stock-disabled requests fail; a submitted
swap + invalid-open transaction fails with unchanged nonce/ledgers/custody.
The committed report fixture round-trips the actual Hub v6 decoder.
Evidence is clone-based, not deployment approval or mainnet readiness.
