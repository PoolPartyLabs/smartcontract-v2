# T3 Kamino supply-only adapter (POO-2258)

DEC-059/068/080/190/193/195 govern this adapter. It implements the existing
`kamino_supply`, `kamino_redeem` (withdraw), and `kamino_refresh` entrypoints.
There is no obligation, borrow, farm, reward claim, native SOL treasury or
Manager-owned receipt account. No mainnet transactions are authorized.

## ABI and account pin

Upstream source: `Kamino-Finance/klend` commit
`a08760976f51a3a58c4a0c6ea27b4a0e565bca79`, specifically
`libs/klend-interface/src/instructions/{deposit,withdraw,refresh}.rs` and
`programs/klend/src/state/reserve.rs`. No venue crate dependency is added.
Program, main market, reserve, USDC, cToken mint and liquidity vault are pinned
inside the adapter. Owner, executable, market PDA, mint, token authority, ATA,
delegate/close-authority and reserve-layout checks precede CPIs.

The deployed program is exercised from the T0 mainnet-state clone. Clone hashes
and observation slots are in the ignored `.localnet/manifest.json`. Successful
CPIs prove exercised ABI compatibility, not reproducible-build equivalence or
future upgrade safety. Reserve size is exactly 8624 bytes/version 1; unsupported
upgrades fail closed. Interest includes borrowed receivables and subtracts
protocol/referrer/pending-referrer fees; it is not capped to available cash.

## Wire payloads

The shared entrypoints retain `Vec<u8>`; inside that vector:

| Instruction | Payload |
| --- | --- |
| `kamino_supply` | Exactly 8 bytes: little-endian u64 USDC amount |
| `kamino_redeem` | Exactly 16 bytes: little-endian u64 cToken units, u64 minimum USDC; max-u64 units = all recorded units |
| `kamino_refresh` | Empty |

Zero supply/redemption and malformed lengths fail. Redemption never silently
burns fewer units than requested. Insufficient freely available liquidity
(including the reserve's queued withdrawals) records unchanged pending cToken
units/minimum; unchanged retries are allowed, supply and replacement requests
are blocked. No cTokens or principal are written off. Other protocol failures
revert atomically, preserving previously recorded pending state. If a new
request first hits an external protocol error rather than the preflight
liquidity check, the caller must retry its failed request; it was not committed.

## Coordinator requests — required before funding

1. T1 must create `[b"position", fund, pinned_reserve]` as `KaminoPosition`
   during approved initialization, bind `fund`/`reserve`, and set `enabled` only
   when the immutable Mandate permits Kamino. Manager pays rent. No public
   position initializer or principal-credit setter exists in T3.
2. **TODO(decision):** finalize the shared ledger interface. T1/T1b must credit
   `idle_principal` only atomically with authenticated arrivals/allocations and
   debit it for CCTP/other adapters. T3 reduces those credits on supply and
   restores principal/income separately on exit. Do not also count them in
   another ledger; raw vault balances/donations are never credits. Until this
   integration exists, production supply fails closed.
3. Report handlers must call `valuation::refresh_and_value` atomically while
   building the report, passing the actual program-owned, Fund-bound position
   and canonical vault. Serialize units, principal/income in underlying USDC,
   pending units/results and cumulative realized income into the T1 v6 schema.
   Never accept `last_refresh_slot`/cached values as sufficient report freshness.
   The function refreshes the reserve and checks same-slot/non-stale state.
4. Wire authenticated Hub unwind/close/collection orders to checked adapter
   helpers. Current public exits require the fixed Manager signature;
   `kamino_collect_income` deliberately remains `NotImplemented`. No permissive
   keeper bypass or guessed order authentication is introduced.
5. Coordinator must update the obsolete scaffold unit test requiring every
   instruction file to return `NotImplemented` and treating every helper `.rs`
   as an instruction. T3 does not own `tests/unit/`.

Only the explicitly permitted single `pub mod kamino;` line is appended to
shared `state/mod.rs`. No shared errors/events/entrypoints/manifests/locks change.
Token accounts must already exist as vault-owned legacy SPL ATAs; tracked
position rent recovery stays with T1 and the original Manager payer.

## Local validation

Run inside this worktree's `solana/` directory:

```sh
export PP_LOCALNET_RPC_PORT=8930 PP_LOCALNET_FAUCET_PORT=9930
export PP_LOCALNET_GOSSIP_PORT=13000 PP_LOCALNET_DYNAMIC_PORTS=13001-13060
npm ci --ignore-scripts --no-audit --no-fund
cargo test --locked
anchor build
./scripts/localnet.sh prepare
node tests/kamino/prepare.ts
./scripts/localnet.sh start
npm run test:localnet
npx tsc --noEmit
./scripts/localnet.sh stop
```

The track fixture extension needs no additional mainnet clone addresses.
Synthetic Fund/position accounts and token balances model T1-approved credits
on localnet only; the deployed venue, reserve, mint and market are untouched.
The large synthetic position tests liquidity failure, not real collateral
ownership. The historical-cost fixture tests positive interest recognition;
ordinary live supply tests rate accrual/rounding using the untouched reserve.
Reset only this worktree's validator before repeating stateful tests.

Tests execute supply, partial/full withdrawal, uncollected/realized interest,
pending retries, independent full-width bigint math and Kamino's own deployed
rate-return instruction. The direct formula matches exactly; the whole-cToken
returned rate can differ by one USDC base unit because it is rounded first.
Negatives cover wrong Manager, reserve, program, cross-Fund ATA, disabled
Mandate entry, donation-funded supply, zero amount and pending replacement.

## Remaining limitations

Kamino is externally upgradeable; an operational pre-demo revalidation is
required. Liquidity availability is not principal assurance. Pending withdrawals
are not force-filled, partially filled, canceled or expired. A minimum that is
later above value blocks a retry until the original minimum is again met;
**TODO(decision):** approve an authenticated amendment/recovery mechanism if
needed, rather than silently weaken a committed minimum. Fresh NAV is a token
quantity; USD pricing and common report-age rules remain Hub responsibilities.
