# Sealed Scope stock reference (sol-t10-scope)

## Approval and immutable switch

DEC-203 requires an on-chain reference and the stricter API/oracle minimum.
DEC-204 makes missing references unavailable. Neither selects a stock provider.
**TODO(decision): founder approval of Scope option A remains pending.** This
implementation is an opt-in capability, not permission to activate it for the
demo or deploy. No mainnet transactions are authorized.

The existing signed `SwapPolicy` bytes encode the switch without an ABI change:

| reference_mode | stock_enabled | Meaning |
| --- | --- | --- |
| 0 | false | Default; SOL/USDC unchanged, stocks unavailable |
| 1 | true | Scope Open equities; enable only with approved creation consent |
| anything else | either | Fail closed |

`config::digest` commits both bytes in EVM consent; the native creation policy
also commits the policy hash. The production initializer verifies and persists
them, and no post-creation setter exists. The test creation builder defaults OFF.
Enabling does not admit a new mint into the Fund or bypass an issuer witness.

## Account and unit pins

Upstream source: `Kamino-Finance/scope`, commit
`8d01cb8cfb9cfb3f75aec8ee39bcf9f6b40b16c5`; `oracle_prices.rs`,
`oracle_mappings.rs`, `dated_price.rs`, `oracles/chainlink.rs`.
Read-only finalized mainnet verification also checks these identities:

| Account | Pin |
| --- | --- |
| Scope owner/program | `HFn8GnPADiny6XqUoWE8uRPPxb29ikn4yTuPa9MF2fWJ` |
| Prices, 28,712 bytes | `3t4JZcueEzTbVP6kLxXrL3VpWx45jDer4eqysweBchNH` |
| Mappings, 29,704 bytes | `4zh6bmb77qX2CL7t5AJYCqa6YqFafbz3QJNeFvZjLowg` |
| TSLAx mint, entry 60 | `XsDoVfqeBukxuZHWhdvWHBhgEHjGNst4MLodqsJHzoB` |
| NVDAx mint, entry 46 | `Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh` |

Prices discriminator `598076dd0648b492`, mappings discriminator
`28f46e50ffd6f3bc`, and the embedded mappings key must match. Entries are
`40 + 56 * index`: u64 value, **unsigned denominator exponent**, slot, source
timestamp and generic bytes. Execution pins exponent **15**, type **34**
(`ChainlinkRWA`) with no frozen bit, Open mode **1**, exact v8 feed IDs and
zero reserved mapping bytes. It does not accept AllUpdates, Pyth, TWAP,
MostRecent or already-multiplied ChainlinkX entries as substitutes.

Only read-only pinned accounts and initialized eight-decimal Token-2022 stock
mints are admitted. Effective price is the underlying mark multiplied **once**
by the live ScaledUiAmount effective multiplier, using its exact IEEE rational
and activation timestamp, not a hardcoded NVDA factor (DEC-198). The existing
issuer/custody witness still rejects unsupported/changed/paused stock state.

Production stock remaining accounts are:

```text
[Jupiter route..., swap_config, Pyth SOL, Pyth USDC, Chainlink SOL,
 Scope prices, Scope mappings, input ledger, output ledger]
```

SOL/USDC keeps the existing six-account suffix. Stock request `stock_report`
must be absent; no paid verifier program or signed off-chain replacement is
accepted in Scope mode. USDC still uses the pinned Pyth primary reader.
Both swap entrypoints reach the same production handler. Nonce and principal
ledger updates occur only after guarded CPI/postconditions succeed.

## Market and freshness gates

The reviewed NYSE 2026 calendar admits only 09:30–16:00 Eastern weekdays,
excluding all ten full holidays. November 27 and December 24 close at 13:00
Eastern. US DST switches are March 8 at 07:00 UTC and November 1 at 06:00 UTC.
Exact open is inclusive, exact close exclusive. Unknown years are unavailable;
no extrapolated calendar or stale closing value is substituted.

Source publication must be inside the current session, non-future, and at most
`min(sealed.max_age_seconds, 60)` seconds old. The update slot must be positive
and not future; retained observations timestamp must equal the publication
timestamp, with standard-price reserved bytes zero. These are conservative
engineering admission gates, not new founder economic rules.
**TODO(decision): approve the provider, freshness ceiling and calendar horizon;
review emergency closures and next-year calendar before widening admission.**
Scope's Open adapter controls which upstream session updates enter the account;
the cached entry does not retain a separate live market-status attestation.
An extraordinary exchange halt/closure is not independently signaled here.

DEC-203 uses existing exact integer cancellation/upward rounding: with Manager
bound `0 < bps < 10000`, min-out is the larger of API min-out and the oracle
ratio adjusted by `10000-bps`. With 0 or >=10000, the Manager supplies no impact
maximum, but the oracle must still be available before the API minimum can be
used. API signature, expiry, nonce, route hash and custody gates remain intact.

## Reproduce without mainnet sends

From `solana/`:

```sh
npm ci --ignore-scripts --no-audit --no-fund
cargo test --locked
anchor build
cargo-build-sbf --manifest-path tests/swap/probe/Cargo.toml \
  --sbf-out-dir tests/swap/probe/target/deploy
./scripts/localnet.sh prepare
node tests/swap/scope.prepare.ts
PP_LOCALNET_RPC_PORT=8997 PP_LOCALNET_FAUCET_PORT=9997 \
PP_LOCALNET_GOSSIP_PORT=19800 PP_LOCALNET_DYNAMIC_PORTS=19801-19860 \
bash tests/swap/scope.start.sh
PP_LOCALNET_RPC_PORT=8997 node --test tests/swap/scope.localnet.test.ts
node --test tests/swap/scope-config.test.ts
./scripts/localnet.sh stop
```

The fixture extension is explicit and does not modify the shared clone manifest
source. Preparation records owners, SHA-256, finalized slots and decoded values
under ignored `.localnet/scope-evidence.json`. It clones the executable Scope
program and ProgramData too. Public RPC methods are read-only; secrets/endpoints
are never printed. The base harness supplies synthetic local Manager/keeper SOL.
Genesis stock mint and Scope account data remain unmodified mainnet clones.

The local-only SBF probe imports **the production reader and min-out function**.
For deterministic freshness testing it replays Clock's timestamp at the real
cloned source timestamp while retaining the validator slot. Production never
accepts caller-supplied time. Closed/stale/future tests alter only that test
Clock; wrong-account tests pass a different account. This is not proof that an
old clone is fresh against wall-clock time, nor an upstream update CPI.

Evidence: nine localnet tests, including real authenticated production Fund
creation OFF/ON with post-seal mutation rejection, both stock multipliers,
strict min-out, closed/stale/future/wrong-account/disabled rejection. Scope
reader probe used 19,120 CU TSLAx / 26,786 CU NVDAx. Production creation measured
222,645/222,647 CU and 297-byte ALT packets; staging was 906/784 bytes.

## Coordinator requests and remaining gates

- No shared source, manifest, lockfile, state size or dependency additions.
- Update production client/docs to match the stock suffix before activation.
  The owned test builder is updated; shared client changes belong to its owner.
- Register Scope clone extension/preparation and probe build/start requirements
  in coordinated acceptance CI. This suite requires its dedicated harness;
  unrelated production lifecycle suites were not run against it.
- Obtain founder Scope approval/data-use and operator-risk acceptance. Verify a
  live fresh regular-session snapshot immediately before the Friday demo.
- Run an approved fresh production API-signed TSLAx/NVDAx Jupiter V2 swap/LP
  packet and rollback test before capital. The track proves reader/min-out and
  creation paths, **not a complete signed stock Jupiter CPI or all-chain Fund**.
- Refresh calendar/halts, source uptime and upgrade monitoring for production;
  no mainnet deploy or send is performed by this work.
