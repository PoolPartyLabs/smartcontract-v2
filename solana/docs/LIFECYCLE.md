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
Deployment links `SolanaPdaV6`, then `SolanaPolicyV6`, then `FundFactoryV6`.
The factory's authorization runs in the linked policy library to preserve the
mandatory 1,000-byte runtime reserve without weakening signature checks.

For packet fit, init also accepts compact version 1: a one-byte version followed
by the full payload with `spoke_chain_id` and `native_mandate_hash` omitted.
The native chain is fixed to 1 and the native hash is recomputed from the signer,
derived emitter and sealed configuration before checking the identical signed
bootstrap tuple. No consent field is removed from the signature.

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
Unwind/collect acceptance currently requires USDC-only inventory and no
registered positions; unsupported shapes reject before locking custody.

| Reference | Native behavior / remaining gap |
| --- | --- |
| `src/libraries/OrderCodec.sol:106` | Same ABI order id over kind/Fund/request/attempt; full-width words that cannot be sized safely are rejected, not truncated. |
| `src/spoke/SpokeUnwindLib.sol:46` | One active command retains custody reservations; no concurrent Manager adapter operations while active. Multiple concurrent EVM payout requests are not implemented. |
| `src/spoke/SpokeUnwindLib.sol:316` | Per-position delivery records survive retries. Kamino illiquidity retains pending units; failed CPI rolls back the step. EVM catch-and-exclude semantics are not implemented. |
| `src/spoke/SpokeCloseLib.sol:68` | Close requires nonzero nonfuture closing timestamp and all exposure returned; no early `closed=true`. Signed exact-in residual sale remains disabled. |
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
unacknowledged outbound claims. Both close-command completion and the final
closed flag independently validate every registered CCTP receipt as received;
missing, substituted or pending inbound/outbound receipts reject (DEC-205).
The registry count includes retained arrived receipts, so a nonzero count alone
is not proof of pending capital. Donations remain excess, not NAV. Closed-Fund
arrival allocation still needs a sealed garbage collector; receives stay
fail-closed when closed. No arrival is intentionally written off.

DEC-206: principal and trading-fee exits permit incidental reward credits only
into canonical segregated reward quarantine accounts. Rewards never enter the
principal/income ledgers or NAV. If the external position still records rewards
after exiting all principal/fees, retain its NFT/account/rent evidence rather
than reverting the exit or attempting a reward claim. Reward-account GC remains
unimplemented; no arbitrary quarantine transfer or rent refund is added.

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

1. Kamino, Raydium and swap-to-ratio use Hub-chain/Core/index/policyHash seeds.
   Shared core/rehearsal bootstrap and direction-qualified transit fixtures are
   migrated; isolated legacy CCTP/Raydium/Kamino genesis suites remain pending.
2. The scaffold structural invariant expects 28 entrypoints. Composed rehearsal
   uses the compact policy bootstrap, not a legacy init payload.
3. Deployment and composed Hub-fork creation use committed creation and linked
   policy/PDA libraries. Approved production factory identity remains unpinned.
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
The original legacy rehearsal failed at `InvalidConfiguration` 7002. The
policy-bootstrap final-source repeat passed 13 measured operations, 2,176 report
bytes, maximum 341,961 CU and 1,231 signed bytes on ports 8970/9970/17000.
Default native localnet passed 41/41; Rust passed 53/53 default and 55/55 feature.
The finish-work report `results/sol-finish-47-report.md` records the combined
EVM gate; historical failures are not counted as passing acceptance.
