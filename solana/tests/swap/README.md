# T5 Jupiter swap-to-ratio

**Integration slice, not a deployable Fund swap.** `swap_to_ratio` authenticates
the fixed Manager and Fund/vault PDAs, then returns `IntegrationPending`.
T1's sealed-Mandate decoder/config and atomic ledger conversion are absent in
the integration baseline. Never replace these with a Manager-provided allowlist.
`execute_guarded` is the tested CPI primitive; `Conversion` is an internal
principal conversion, never income (DEC-079, DEC-080, DEC-190, DEC-193).

## Decision status (DEC-197/DEC-198)

Jupiter is the chosen swap venue; Round 5 permits API-side venue filtering
(DEC-197/DEC-198). Venue selection is not unresolved. TODO(decision): coordinator
approval of the temporary V1 API/wire pin or a separately verified migration
remains outstanding. The sealed loss/slippage reference is still unanswered;
this slice makes no new decision about that reference or an independent loss
bound and does not open the runtime handler.

## Verified Jupiter interface, October 6, 2026

- Official program ID / source IDL:
  `https://github.com/jup-ag/jupiter-cpi-swap-example/blob/main/cpi-swap-program/idls/jupiter_aggregator.json`.
  `JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4` was executable,
  upgradeable-loader-owned at finalized mainnet slot 453990201. Executable and
  ProgramData hashes are recorded in `fixtures/clone-extension.json`.
- Official rate limits:
  `https://developers.jup.ag/docs/portal/rate-limits`.
  Keyless: 0.5 RPS / 30 requests per 60-second sliding window. Free: API key
  required, 1 RPS / 60 requests per window. Header: `x-api-key`. Limits are per
  organisation, shared across most APIs, not multiplied by keys. Inject one
  shared `JupiterClient` per service; independent processes need a shared limiter
  or organisation quota partition. Local pacing is 2100/1100 ms with capacity 1.
- Official migration and build references:
  `https://developers.jup.ag/docs/swap/migration/metis-to-build`,
  `https://developers.jup.ag/docs/swap/build`.
  Current maintained successor: GET `https://api.jup.ag/swap/v2/build` supports
  raw instructions/CPI. V1 GET `/swap/v1/quote` + POST
  `/swap/v1/swap-instructions` are unmaintained but were live, keyless HTTP 200.
  This slice deliberately pins the *executed* V1 direct `route` wire; it does
  not claim compatibility with V2 instructions. TODO(decision): coordinator
  approval of the temporary V1 pin or separately verified V2 migration.
- Both APIs expose `dexes`, `excludeDexes`, `maxAccounts`; V2 documents dexes and
  excludeDexes as mutually exclusive. V1 supports `onlyDirectRoutes=true`;
  V2's current OpenAPI does not list it. Route builder pins `Raydium CLMM`,
  direct route, maxAccounts 32; contract narrowing accepts only one-hop V1
  CLMM variants 26/40. DEC-197/DEC-198 permit API-side venue filtering; this
  narrower decoder is a safety restriction, not a new closed-venue economic rule.
- V1 response: `addressLookupTableAddresses`, fetched from RPC and checked active.
  V2: `addressesByLookupTableAddress` maps ALT addresses to account arrays.
  Do not interchange these response formats or V1 percent/V2 bps route encoding.
- Actual USDC -> TSLAx/NVDAx Token-2022 and USDC -> WSOL routes are committed.
  Both stock swaps executed via Jupiter -> Raydium -> Token-2022 locally.
  This proves these concrete mints/routes, not all Token-2022 extensions or
  mainnet issuer eligibility. No platform fee, shared accounts, wrapping or
  unwrapping; only existing vault ATAs. Manager prepares/rents ATAs separately.

## Wire and custody

The existing `Vec<u8>` entrypoint carries Borsh `SwapRequest`: input/output mint,
requested input u64, min_out u64, slippage u16, route bytes Vec. Jupiter account
metas are passed in order as remaining accounts. The vault is **not** a
transaction signer; invoke_signed grants it signer authority only in CPI.
Manager is the sole transaction signer/payer. All setup/cleanup/other API
instructions are discarded, not executed. Builder verifies existing ATAs.

Guard enforces authenticated sealed endpoints/config supplied by its caller,
positive exact input <= requested, admitted distinct mints, pinned executable,
exact derived vault ATAs, V1 output alias, nonzero floor, no fee account, no
additional signer or writable spoke-owned state. It snapshots every vault-owned
legacy/Token-2022 token account in the route, then checks exact debit, min-out
delta, unchanged token metadata/extensions/owner and untouched other accounts.
WSOL endpoint lamport delta must exactly match token delta; Fund vault has no SOL
and may not be writable (DEC-195). Accounts absent from CPI cannot be mutated.

Slippage is relative to Jupiter's route quoted output, **not** an authenticated
independent fair-price oracle / EVM spot-loss reference. TODO(decision): settle
the sealed slippage field/reference and any independent loss bound with T1 and
the coordinator. Current handler remains closed so no weaker policy is deployed.

Ratio math uses arbitrary-precision raw-unit CLMM weights, clamped current
sqrtPriceX64, 1..12 quote iterations (8 default). RPC pool price/range and current
inventory are explicit inputs from UI; no trusted NAV is inferred. Approximate
ratio is not guaranteed exact with rounded amounts; refresh LP sizing after swap.
Every quote, including the full-balance single-sided range shortcut, must have
positive u64 output and leave the recipient token-account balance within u64.
Client tests cover zero/negative/oversized output, recipient overflow and the
valid u64 boundary in both directions, plus in-range overflow regressions.

## Reproduce without Jupiter test calls

Run in `solana/`, with the assigned loopback ports only. Clone preparation is
read-only mainnet RPC; test transactions are exclusively loopback. Scripts do
not print credentials, RPC endpoints, or local key material.

```sh
npm ci --ignore-scripts
cargo test --locked
anchor build --no-idl
node --test tests/swap/client.test.ts tests/swap/builder.test.ts
./scripts/localnet.sh prepare
node tests/swap/record-fixtures.ts --replay
cargo-build-sbf --manifest-path tests/swap/probe/Cargo.toml \
  --sbf-out-dir tests/swap/probe/target/deploy
bash tests/swap/start-probe.sh
PP_LOCALNET_RPC_PORT=8950 node --test tests/swap/cpi.localnet.test.ts
PP_LOCALNET_RPC_PORT=8950 ./scripts/localnet.sh stop
```

`prepare` removes unknown snapshots: apply the track clone extension **after** it.
To intentionally refresh real Jupiter fixtures use `record-fixtures.ts` without
`--replay` (three quote/instruction pairs through the limiter). Fixtures commit
quote/instruction/account inventory/hash metadata, not dumped binaries or keys.
Re-cloning later may exceed quote minima; that must fail, never lower the floor
silently. Extension addresses can differ from T0's LP pool addresses.

Probe crate includes the exact guard source, under a **different local-only
program ID**, with a constant test allowlist. It must never be deployed to
mainnet or mistaken for Fund binding/sealed policy/ledger proof. Its lockfile
preserves the scaffold's SBF-compatible versions; no shared manifest/lock edited.

Observed local probe: TSLAx 98,157 CU / 698 bytes; NVDAx 102,848 CU / 698 bytes;
WSOL 82,223 CU / 691 bytes. Client mock-ALT unit bytes (527/527/520) are synthetic,
not real-network size evidence. No report/LP instruction or canonical ledger is
composed in those measurements. Default 1.2M CU is conservative, not a measured
production budget.

Negatives: wrong output (Custody), post-CPI min_out (MinOut), unadmitted mint
(Mint), absent signer (Unauthorized), substituted extra vault pool account
(Raydium rejects account owner before drain). **An actual adversarial extra-vault
drain was not executed by the pinned real Jupiter program**; the guard's snapshot
drain and metadata mutation detection is independently host-unit-tested.

## Coordinator requests

1. Authenticate canonical sealed mint/config state in `swap_to_ratio`, deserialize
   `SwapRequest`, call `execute_guarded`, persist returned principal conversion
   atomically in T1 ledger. Supply finalized T1 APIs/account order; no guessed
   state layout or new mandate is created here. Update builder account layout.
2. Resolve the unanswered sealed loss/slippage reference and any independent
   loss bound with T1. Jupiter selection and API-side venue filtering are already
   recorded in DEC-197/DEC-198; no new economic decision is made here.
3. Register track unit tests in coordinator runner if desired; tests remain under
   `tests/swap/` and shared runner/manifests are untouched.
4. Approval or verified migration for temporary V1 API/wire pin; cross-process
   quota coordination for API/frontend deployments and real LP composition CU.

Task expressly assigns `clients/` to T5 despite the older ownership table listing
only swap module/tests; changes are restricted to `clients/swap/`. No other
track/shared source/manifests were edited. T2a branch was absent remotely when
fetched; its merged interfaces subsequently arrived via integration PR #36.
