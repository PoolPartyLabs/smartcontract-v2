# T8b policy commitments and lifecycle gates

October 7, 2026. DEC-188/190/191/192/200 and the coordinator's POO-2263
non-circular commitment refinement apply. **Partial implementation, not a
release or full-liquidation acceptance. No mainnet transactions authorized.**

## Commitment construction

1. Predict the Hub Core using the factory's existing CREATE3 Fund id.
2. Hash the Hub Mandate with only the native spoke's `spokeVault` zeroed.
   Other EVM spoke identities remain committed; they are not Solana-derived.
3. Hash the native Config with `spoke`, `mintRecipient`, `destinationCaller`
   and `remoteVaultAuthority` zeroed. Manager key, program, assets, venue
   identities and all transport policy remain committed.
4. `policyHash = keccak256(abi.encode(keccak256("PoolParty/SolanaPolicy/v6"),
   hubPolicyHash, nativePolicyHash))`.
5. Native Fund seeds are `[b"fund", hubChain_u64_le, core_20_bytes,
   spokeIndex_u16_le, policyHash_32_bytes]`. Vault/emitter and canonical ATAs
   derive from that Fund. The native init payload appends `hub_policy_hash`
   and `policy_hash` after transport.
6. Fill the native Config and Hub Mandate with the derived identities. Sign
   the exact `SolanaBootstrap` EIP-712 type declared by `BOOTSTRAP_TYPEHASH`
   in `FundFactoryV6` and native `bootstrap_digest`.
7. Call `createFundV6Committed`; Hub recomputes policy and native identities,
   enforces Manager EOA/nonce/expiry, and stores `fullSolanaCommitment` over
   the complete Hub/native hashes and derived commitment tuple. Native init
   independently recomputes its policy and PDA, checks the same signature
   and requires the bound Solana transaction signer.

Legacy `createFundV6` and `bindingDigest` now explicitly revert. Existing
deployed Funds and the legacy Mandate struct are unchanged. The full envelope
is factory storage, not a changed Core `mandateHash`: reports still commit the
Hub and native hashes separately. This distinction needs coordinator review.
Deployment must link `SolanaPolicyV6` and `SolanaPdaV6`; deployment-script edits
belong to T8d, not this track.

Shared Hub/native PDA golden vector: Hub 42161, Core `0x02` repeated 20 bytes,
index 1, policy `0x03` repeated 32 bytes, scaffold program:
Fund `59196f6ece881da9abd0e61ea5a6cdac8c533accd9f6c553f9db86832c36eb11`.
The scaffold program identity is not an approved deployment identity.

## Command ABI and EVM parity references

`execute_unwind_order`, `execute_close_order`, `execute_collect_order` accept
only the sealed canonical Hub PostedVAA and an empty local payload. Append
writable canonical command PDA and canonical USDC ledger as remaining accounts.
The command seeds are `[b"command", fund, OrderCodec.orderId]`. Acceptance
reserves the proportional USDC principal or USDC collected income, records the
exact Hub payload, and consumes the Wormhole sequence. It is not completion.

| Reference | Native behavior / remaining gap |
| --- | --- |
| `src/libraries/OrderCodec.sol:65` | Same ABI order id over kind/Fund/request/attempt; full-width words that cannot be sized safely are rejected, not truncated. |
| `src/spoke/SpokeUnwindLib.sol:46` | One active command retains custody reservations; no concurrent Manager adapter operations while active. Multiple concurrent EVM payout requests are not implemented. |
| `src/spoke/SpokeUnwindLib.sol:316` | Per-position delivery records survive retries. Kamino illiquidity retains pending units; failed CPI rolls back the step. EVM catch-and-exclude semantics are not implemented. |
| `src/spoke/SpokeCloseLib.sol:71` | Close requires nonzero nonfuture closing timestamp and all exposure returned; no early `closed=true`. Signed exact-in residual sale remains disabled. |
| `src/spoke/SpokeCrossChainLib.sol:34` | Result bytes carry actual reserved send/net CCTP claim. Native result fixtures decode through authenticated Hub receiver. No invented swap costs are accepted. |
| `src/spoke/SpokeIncomeTypes.sol:29` | Native collection results retain full-width mints and project to Hub aliases. USDC-only results are supported; multi-asset income finalization is blocked. |

`resume_command` accounts: Manager signer, Fund, command, USDC ledger,
current executable program; remaining accounts are the exact public adapter
entry's account list. Payload is an opcode followed by adapter payload:

- 0: finalize, without discarding pending exposure. Close requires complete
  snapshot inventory and zero positions/non-USDC/USDC principal/income/claims.
- 1: close Kamino units; payload minimum USDC u64 LE; sizes all units from the
  authenticated close 1/1. Proportional unwind is disabled pending Market Cost
  evidence.
- 2: close Raydium; payload the existing public close payload. Position record
  is the sixth public account, not the program placeholder.
- 3: collect Raydium fees; payload the existing collect payload. Kamino collect
  is still a public stub and cannot be claimed as income parity.
- 4: residual exact-in through `swap_exact_in`; current public entry is disabled
  and atomically rejects. Asset remains recognized and close remains pending.

Adapter self-CPI temporarily clears the Fund's command guard, invokes only a
fixed public entry, reloads canonical state, and restores it within the same
transaction. Nested adapter execution, compute and packet budgets are **not
localnet-proved**. Do not deploy this as verified command execution.

For an active command `send_to_hub` appends its writable command as the last
remaining account after the Circle CPI graph. It sends exactly the reserved
amount and records the actual gross/net claim. Income burns use TransferKind 1,
principal burns 0. A command currently permits one send only: close principal
plus USDC interest requires separate-bucket progress before full closure can
complete. That missing interface is an explicit release blocker.

The final `publish_report` posts consistency 32 and sets `Fund.closed` only
after the completed close command has no remaining recognized exposure or
unacknowledged outbound claims. Donations remain excess, not NAV. Closed-Fund
arrival allocation still needs a sealed garbage collector; receives stay
fail-closed when closed. No arrival is intentionally written off.

## Transit and retention

Outbound input `transit_id` is now a business nonce. The emitted/wire id is
`keccak256(namespace || fundId || sourceDomain_abi_word || destinationDomain_abi_word || nonce)`
with namespace `PoolParty/CCTPTransit/v2`, domains 5 -> 3. Receipt seeds are
`[b"transit_out", fund, nonce]`; the nonce is retained in `Transit.nonce`.
Inbound receipts use `[b"transit_in", fund, authenticatedHubTransitId]` and
retain Circle's nonce. Equal input bytes cannot squat the opposite direction.
Hub ACK checks outbound canonical PDA and emitted id before retiring the net
claim. Transport kind is retained in Transit and reports.

`prune_registry` removes only zero-principal/zero-units/zero-pending Kamino or
fully closed zero-liquidity Raydium position entries. It never closes the
position account, destroys replay evidence, refunds Fund assets as rent or
prunes pending claims. Reusing a pruned Kamino account requires adapter
re-registration, which is a coordinator request. Inbound receipt GC, closed
receipt account rent reclamation and command result ACK/GC remain blocked;
their bounded registries can still exhaust. **Item 4 is not fully delivered.**

## Coordinator requests / release blockers

1. Migrate Kamino `supply/refresh/redeem` and swap-to-ratio Fund seed constraints
   to Hub-chain/Core/index/policyHash. T8b did not edit their owned paths.
2. Update shared fixture helpers, scaffold entry count (28), CCTP fixtures,
   Raydium/rehearsal clients and T8d composed forks to the new ABI. The old
   composed rehearsal currently fails at native init, before lifecycle legs.
3. Link the two new Solidity libraries in T8d deployment code; use committed
   creation and the common typed tuple, not legacy bindingDigest.
4. Provide signed public exact-in liquidation, multi-bucket/multi-send close
   progress, Kamino collect and proportional Raydium/Market Cost interfaces.
5. Approve/authenticate result ACK and inbound-receipt retirement, sealed
   garbage collector for late closed arrivals, receipt rent GC, and safe
   reactivation/re-registration for pruned Kamino admissions.
6. Add native command/ACK/send/zero-fund-close localnet acceptance tests and
   repeat composed Arbitrum/Robinhood fork settlement after fixture migration.
7. Golden PDA/result vectors and cloned bootstrap are evidence, not cross-chain
   deployment, production signatures, full liquidation or worst-case resource
   acceptance. Max registries and native self-CPI require additional tests.

## Verification

Actual logs are under `/tmp/sol-t8b-*.log`; the handoff result report records
final counts. Cloned policy test passed with a 1057-byte versioned init on ports
8980/9980/18000/18001-18060. Mainnet preparation performed finalized read-only
clones (62 base accounts plus 21 rehearsal reads); sends were loopback only.
The composed legacy rehearsal was attempted and failed at `InvalidConfiguration`
7002. Do not label that failure a passing rehearsal.
