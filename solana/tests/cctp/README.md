# CCTP V2 Fast track (POO-2255)

DEC-188/190/191/195 govern this module. No mainnet transaction is authorized.
Circle source wire/account order is pinned to
`ec16e95d28ee47f7832df4203ae07b5981d146fc` in the official
`circlefin/solana-cctp-contracts` repository. The cloned executable, not source
equivalence, is what the local integration test executes.

## Reproduce

Run from `solana/` in this track's worktree:

```sh
export PP_LOCALNET_RPC_PORT=8920 PP_LOCALNET_FAUCET_PORT=9920
export PP_LOCALNET_GOSSIP_PORT=12000 PP_LOCALNET_DYNAMIC_PORTS=12001-12060
npm ci --ignore-scripts
cargo test --locked
anchor build
./scripts/localnet.sh prepare
node tests/cctp/fixtures.ts
./scripts/localnet.sh start
npm test
npm run test:localnet
./scripts/localnet.sh stop
```

The shared recursive runner already registers this track's `.test.ts` files.
Restart/reset before another run: business-id replay is deliberately persistent.
Never stop a validator outside this worktree. There are no additional mainnet
clone addresses; the shared Circle clone inventory covers the CPIs.

## Synthetic override, not real Circle attestation

`fixtures.ts` replaces ONLY `signature_threshold` and `enabled_attesters` in
the cloned MessageTransmitter state, preserving its original allocation, owner,
lamports, pause, domain, version, authority keys and body-size limit. Threshold
becomes one; the enabled address is derived from a public deterministic local
secp256k1 test scalar. Signatures are Keccak-256, compact r/s and recovery+27,
not Ethereum personal-sign. They are not accepted on mainnet.

The original snapshot is preserved at ignored
`.localnet/cctp-original-transmitter.json`. The override is written to BOTH
account directories because duplicate-address precedence must not determine
the test attester set. Consequently the original shared manifest hash does not
describe this modified account: `.localnet/cctp-fixture.json` explicitly records
the exception. Re-run shared preparation before returning to unmodified Circle
state. No protocol mint, custody balance or USDC issuer authority is overridden.

T1 initialization remains a scaffold at this integration point. Tests explicitly
inject a synthetic FundState, sealed CctpRoute, isolated CctpLedger, and a native
USDC ATA owned by the canonical Fund vault PDA at genesis. No production helper
creates or seals those accounts. The vault PDA itself has zero SOL; payers fund
transit/event/nonce rent. These fixtures prove the CCTP instruction composition,
not EIP-712 launch verification or full T1 accounting/report integration.

Versioned transactions use a local lookup table to fit the 536-byte CCTP message
and Circle accounts under Solana transaction size limits. All transaction
helpers enforce uncredentialed loopback HTTP. Remote access is read-only clone
preparation only.

## Instruction/account contract

- `SendParams` inside existing `Vec<u8>`: Borsh `[transit_id:32, amount:u64,
  max_fee:u64]`, no trailing data; only Principal is supported. Circle burn data
  is separately encoded with domain 3, Core mint recipient, sealed connector
  caller, finality 1000 and existing 160-byte Solidity TransitMessage v1 hook.
- `ReceiveParams`: Borsh `[transit_id:32, message:Vec<u8>, attestation:Vec<u8>]`.
  Exact 536-byte Circle message, header/body version 1, domains 3->5, pinned
  native-USDC/Circle messenger, Hub Core messageSender, vault destinationCaller,
  native USDC ATA recipient, Fund/id/42161/Principal hook and fee bounds required.
  Requested Fast 1000; executed finality may be stronger, never weaker.
- Both account structs bind FundState seeds, vault seeds, sealed route Mandate
  hash, and Fund-owned ledger/transit PDA. The CPI remaining accounts must exactly
  match `cpi::burn_accounts` or `cpi::receive_accounts`, followed by the executable
  target. Duplicated accounts are intentional external Anchor event-CPI accounts.
- CctpLedger principal is recognized backing, not raw token balance. Burns debit
  gross principal, record gross and `amount-maxFee` aggregate pending values;
  receives add `amount-feeExecuted` principal and separately track unused fee
  principal. All additions checked; failed accounting rolls Circle mint/nonce back.
- Inbound transit PDA `init` makes a business-id receipt exactly-once, including
  fresh-Circle-nonce replay. Failed attempts leave no receipt. Outbound records
  never close, time out or write down. Raw donations never enter this ledger.
- Rent reclaim: original payer calls Circle directly with the instruction built
  by `reclaim::reclaim_event_account`; Circle verifies original payee, signed
  destination message and its five-day retention window. The transit continues
  pending even after event rent recovery. No shared program entrypoint needed.
- API/Manager retries call `receive_and_credit` again after a failed atomic
  attempt. `retry_receive` and `recognize_refund` intentionally remain fail-closed;
  there is no CCTP timer refund, and no unverified alternate authorization path.

## Coordinator requests / release gates

1. T1 must create/seal `[cctp_route, fund]` during verified immutable Fund init,
   binding the connector, chain id and fee ceiling to the committed Mandate.
   There is no Manager-supplied route setter in this track. The only shared edit
   is the permitted appended `pub mod transit;` in `state/mod.rs`.
2. T1 must integrate `[cctp_ledger, fund]` with the canonical native-USDC ledger:
   recognized Principal source bucket, all strategy debits/credits, report arrival
   listings and net persistent outbound return transits. It must not duplicate
   these balances in report NAV. Donated ATA balance is excess, not principal.
3. T1/T2a must pin the Hub registry Solana chain id and custody/caller identity;
   this module uses the vault PDA as destinationCaller and messageSender, and
   ATA as mintRecipient. The test chain id is only a fixture. Do not configure
   the program id as a signer or a different receive PDA on the Hub.
4. Hub-order execution must invoke a separately authenticated T1 dispatch path;
   arbitrary keepers cannot use the Manager-only send entry. No unverified
   Hub-order payload is accepted here.
5. Implement source-finalized report acknowledgement before retiring outbound
   aggregates; there is deliberately no timer or caller-supplied retirement.

## TODO(decision) / limitations

- TODO(decision): numerical immutable scaled fee ceiling is not ruled; tests use
  2 bps (`20_000`) solely as a fixture, never a deployment default. Operational
  quote freshness/alerts are not an invented signed-quote rule.
- TODO(decision): canonical per-direction transit-id generation/namespace and
  shared T1 report acknowledgement are not sealed yet. Caller-provided ids must
  be nonzero and Fund-unique; collision fails rather than overwriting a claim.
- TODO(decision): closed-Fund Solana inbound late-arrival handling requires T1's
  excess path (DEC-167). Until integrated, closed Funds reject atomically rather
  than crediting principal or reopening shares; claim remains recoverable.
- Income sends/receives are unsupported and fail closed. A Principal-only path
  cannot recategorize Income. T1 must wire authenticated collection/ledger kinds
  before enabling that path (DEC-092/191).
- Reclaim success after five days is not proven by the initial end-to-end suite;
  the suite executes real Circle early-reclaim rejection and preserves the event.
- EIP-712 binding, complete Fund launch, reports, mainnet attestation delivery,
  cross-chain mainnet execution and production deployment are not proved here.
