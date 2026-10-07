# T8a composed cloned rehearsal — October 7, 2026

**Local acceptance passed; production release acceptance is incomplete.**
One sequential test submitted 13 actual loopback transactions against cloned
Circle V2, Kamino, Jupiter, Raydium CLMM, Token-2022 and Wormhole programs.
No mainnet transaction, deployment, production key or account mutation occurred.
DEC-188/190/191/192/193/194/195/200 apply. The swap is explicitly a guarded,
recorded V1 rehearsal leg, not DEC-201/202 signed V2 production acceptance.

## Reproduce

Run from this worktree's `solana/` directory. Ports must remain isolated:

```sh
export PP_LOCALNET_RPC_PORT=8960 PP_LOCALNET_FAUCET_PORT=9960
export PP_LOCALNET_GOSSIP_PORT=16000
export PP_LOCALNET_DYNAMIC_PORTS=16001-16060
cargo test --locked
cargo test --locked --features rehearsal-v1-swap
npm test
npx tsc --noEmit
anchor build -- --features rehearsal-v1-swap
bash scripts/localnet.sh prepare
node tests/rehearsal/prepare.ts
bash scripts/localnet.sh start
node --test tests/rehearsal/lifecycle.test.ts
bash scripts/localnet.sh stop
```

Preparation performs only finalized read-only cloning. It records account
owners, slots and hashes in ignored `.localnet/manifest.json` and
`.localnet/rehearsal-clones.json`. Clone reads are not one atomic mainnet slot.
The validator loads cached accounts/programdata; it never connects to mainnet.
Local CCTP attester replacement and synthetic canonical Wormhole-owned PostedVAA
ACK accounts are genesis fixtures, not proofs of production attester/guardian
authorization. Manager and keeper keys are generated local test keys.
Do not run the combined discovery runner as a substitute: legacy track fixtures
and T5b probe setup have different genesis overrides and account ABIs.

After passing, update the committed `tests/rehearsal/fixtures/report-v6.hex`
from ignored `.localnet/rehearsal-report.hex`, then from repo root run:

```sh
forge test --match-path 'test/unit/solana/*.t.sol'
```

`NativeRehearsalTest` decodes the real native-produced 2176-byte report using
`ReportCodecV6`, round-trips identical bytes, and checks two positions, TSLAx
unit-multiplier witness and the credited inbound transit. Rust independently
matches both Hub golden vectors (1280 and 1792 bytes).

## Measured transactions

Final passing run: `/tmp/sol-t8a-acceptance.log`; machine-readable signatures,
simulation compute units and serialized signed versioned transaction sizes:
`.localnet/rehearsal-metrics.json`. CU is pre-send simulation `unitsConsumed`;
successful sends and final state assertions separately establish execution.

| Step | CU | Signed bytes |
| --- | ---: | ---: |
| Initialize dual consent and sealed config | 180087 | 1206 |
| CCTP V2 receive and exact credit | 266142 | 952 |
| Initialize sealed Kamino admission | 43515 | 278 |
| Kamino supply | 134626 | 296 |
| Jupiter recorded V1 ratio leg — replace with T5b | 113566 | 438 |
| Initialize sealed Raydium admission | 29466 | 278 |
| Raydium TSLAx/USDC open | 197254 | 461 |
| Refresh valuations and publish finalized v6 report | 286866 | 410 |
| Raydium collect fees | 279271 | 313 |
| Raydium close position | 325189 | 332 |
| Kamino withdraw all recorded collateral | 125958 | 304 |
| CCTP V2 burn remaining USDC principal home | 131589 | 450 |
| Sealed Hub arrival ACK — local guardian fixture | 24990 | 272 |

All measured transactions fit the 1232-byte packet limit. Initializer has only
26 bytes of spare capacity; additional signed config needs fresh packet-fit
evidence. Maximum observed step was 325189 CU; there is no proof of maximum
registry occupancy fitting a transaction/report memory budget.

## Assertions and negatives

- Exact inbound principal is 49999900 raw USDC after a 100-unit executed fee.
- Reinitialization, unbound signer, wrong CCTP sender and wrong Hub emitter reject.
- Separate core test rejects consent/PDA substitution, then proves a rent-dusted
  legitimate PDA can still initialize; Rust proves Mandate-qualified isolation.
- Final active positions are zero; remaining USDC principal is zero; vault SOL
  is zero. Outbound transit remains a persistent account and retires only on ACK.
- The inbound arrived receipt remains in the exhaustive registry (count one).
- Stock unit/current-next multiplier, pause/freeze/hook negatives pass in Rust.
- Core/report localnet suite: 7/7 pass; added rent-squatting negative: 1/1 pass.
- Default Rust: 44/44; rehearsal feature: 46/46; offline Node: 36/36;
  TypeScript passes; Hub Solidity: 34/34 including two producer/connector tests.
- Default and feature SBF builds pass without stack-offset diagnostics.
- Arbitrum composed fork could not instantiate: provider HTTP 429 capacity
  exhausted. No fork assertions ran; Robinhood fork was not run in this pass.

## Release gates — do not claim a full three-chain production lifecycle

1. **TODO(decision), DEC-200:** EVM Mandate includes native emitter identity,
   while Fund PDA uses that Mandate hash and emitter derives from Fund PDA.
   Resolve the commitment/address derivation cycle before creating a real Fund.
   This rehearsal uses a fixture Mandate hash, not jointly deployed Hub consent.
2. **TODO(decision), DEC-202/LC-173:** signer/domain/oracle policy, stock streams
   and nonce persistence are not sealed in this creation ABI. Production V2
   `swap_to_ratio` stays `IntegrationPending`. T5b pricing/decoder were not altered.
3. Hub unwind/close/collect execution and result dispatch remain fail-closed.
   ACK is implemented; Manager LP close is not a Hub close-order implementation.
4. The recorded 15-USDC ratio leg is not an optimal-ratio planner. Residual TSLAx
   and possible income are not swapped back or sent home. USDC-principal burn
   is not proof of complete Fund liquidation, income settlement or Fund closure.
5. This composed run invokes collection but does not manufacture trades to prove
   nonzero fees. Do not infer yield evidence from a successful collection CPI.
6. NVDAx is not admitted in this cohort; changed/nonunit witnesses fail closed.
   Four ATA derivations are signed, but only USDC/TSLAx/WSOL custody is initialized.
7. Registry retention/GC and direction-qualified transit IDs remain undecided.
   Bounds fail closed; no receipt sweep/write-off. Large exhaustive snapshots
   need CU, heap, forwarded-account and report-size stress evidence.
8. Rebuild with plain `anchor build` before any separately approved deployment.
   Never deploy the `rehearsal-v1-swap` feature binary. Deployment remains unapproved.

An earlier run completed every transaction but was cancelled by its test timer;
the final bounded two-hour timer run passed. Another run exposed a missing
mutable Fund account on Raydium collection/close; the counter persistence fix
is included and verified by the final zero-active-position assertion.
