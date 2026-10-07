# Solana v6 deployment rehearsal — founder approval packet

Measured October 7, 2026, 11:40–11:48 UTC; integration baseline `c8be6be`.
**NOT APPROVED FOR MAINNET. No mainnet transactions were submitted.**
This packet has verified factory dry runs and local loader deployment costs,
not a complete three-chain production acceptance or exact total launch budget.
DEC-188/189/190/191/192/193/194/195/196/198/199/200/201/202 apply.

## Reproducible tooling

| Path | Responsibility |
| --- | --- |
| `script/SolanaV6Deployment.sol` | Shared tested new-version factory deployment, explicit v6 linking and EIP-170 checks |
| `script/DeploySolanaV6.s.sol` | Factory simulation on Arbitrum and Robinhood |
| `script/DeploySolanaFundV6.s.sol` | Arbitrum per-Fund simulation using externally reviewed Manager-signed calldata |
| `script/solana-v6-dry-run.sh` | Public, pinned, throttled RPCs; no broadcast/key arguments |
| `script/solana-v6-budget.mjs` | Integer gas × sampled gas-price execution-cost arithmetic |
| `script/solana-v6-addresses.json` | Research-verified protocol candidates; unresolved program identity/oracle explicitly not admitted |
| `script/solana-three-chain-rehearsal.sh` | Separate EVM/native legs, NOT a correlated shared Fund |
| `solana/scripts/deploy-local.mjs` | Local-only buffer → deploy, deployer authority and ELF verification |
| `solana/scripts/deploy-budget.mjs` | Local validator rent measurements for 1×/2× capacity |
| `test/fork/deployment/SolanaV6Deployment.fork.t.sol` | Same factory/predicted spoke identities on both public forks |

Existing legacy deployment scripts remain unchanged. New factory salt is
`keccak256("pool-party.v2.solana-v6.FundFactory")`; use the SAME operator address
on both EVM chains. v6 creation-code stores and linked library identities must
match the final approved build. The unchanged legacy `FactoryDeployment` helper
provides venue wiring, library linking and code stores, not the legacy factory.
The v6 factory constructor requires native registry creation code on BOTH chains.
Do not deploy CCTP connector/adapter as standalone shared contracts: the factory
creates them per Fund, atomically with Core v6, registry and receiver (DEC-191/199).

```sh
git submodule update --init --recursive
forge build
ARBITRUM_FORK_BLOCK=512553166 ROBINHOOD_FORK_BLOCK=82445811 \
  bash script/solana-v6-dry-run.sh
node script/solana-v6-budget.mjs
node --test script/solana-deployment-safety.test.mjs
```

The public RPC endpoints are the ones in `docs/INTEGRATIONS.md`. Foundry uses its
default on-disk RPC cache; do not disable storage caching or rate limiting.
The runner sets 30 assumed provider compute units/second and 3-second retry
backoff. Never silently replace a pinned block with `latest`.
The original Arbitrum pin 512239244 failed with `missing trie node`; Robinhood
82439071 failed with `historical state ... is not available`. Explicit recent
pins above passed; Foundry's existing local cache also allowed older Hub tests.
Cold public archive availability is NOT guaranteed by those passing cached tests.

## EVM cost evidence

Sampled `eth_gasPrice` during the successful public dry runs:

| Chain / pin | Foundry estimated gas | Sampled gas price (wei) | Gas × price (ETH) | Foundry required ETH |
| --- | ---: | ---: | ---: | ---: |
| Arbitrum / 512553166 | 94,389,550 | 20,052,000 | 0.001892699256600000 | 0.003792949771589550 |
| Robinhood / 82445811 | 55,651,352 | 20,038,000 | 0.001115141791376000 | 0.002238965249315352 |

Post-fetch final replay at 11:47–11:48 UTC also passed both scripts. Gas estimates
were unchanged. New samples were 20,000,000 wei (Arbitrum) and 20,120,000 wei
(Robinhood), giving **0.001887791000000000 ETH** and
**0.001119705202240000 ETH** respectively. This observed drift is why the
October 9 funding packet must be refreshed rather than treating one quote as fixed.

Both commands printed **SIMULATION COMPLETE** without `--broadcast`.
Foundry's estimate includes its default gas-estimate multiplier; these are
simulation estimates, not transaction receipts or final execution-gas invoices.
The final column uses Foundry's own script gas-price estimate, not the separate
single RPC sample used for the arithmetic column. These prices are observations,
not a promise of October 9 prices. USD conversion is deliberately omitted.

**Incomplete exact total:** the table excludes Manager Fund-creation calldata,
Robinhood `createSpoke`, USDC approval, binding/acceptance, allocations, keeper
relays, capital returns and both chains' L1 data fees. Arbitrum-family execution
gas × L2 gas price alone is not a complete transaction fee budget. Refresh the
whole packet and obtain L1-inclusive estimates on the final signed transaction
bytes before requesting a precise ETH funding amount. Do not fund from this
partial subtotal as though it covered launch.

`DeploySolanaFundV6` requires `SOLANA_V6_FACTORY` plus
`SOLANA_V6_CREATION_CALLDATA_FILE` containing hex ABI calldata for `createFundV6`.
It validates the destination code and selector and does not construct a guessed
Mandate or binding. Simulate it with the actual Manager as `--sender`; final
calldata is blocked by the coordinator's DEC-200 commitment/address issue below.
The per-Fund script therefore has **no successful dry-run evidence yet**.

Measured runtime sizes (repository optimizer; no code-size override):
CoreVaultV6 23,021; FundFactoryV6 22,760; ValueReportReceiverV6 15,333;
CctpBridgeAdapter 4,230; CctpReceiveConnector 4,521 bytes.
Recheck linked runtime AND constructor-inclusive EIP-3860 sizes after integration.

## Solana rent and deployer funding

Plain `anchor build` succeeded, no rehearsal-only feature. Local ELF:

- Size: **1,055,688 bytes**.
- SHA-256: `65c351f82fa7a181b56accee4d281934a8ceb8568b360ce984bfb65d8bcbf829`.
- Production program identity is still the coordinator's scaffold placeholder.
  Replacing the identity/rebuilding invalidates this binary hash and funding packet.

`getMinimumBalanceForRentExemption` on the local Agave 2.3.0 validator:

| Component | 1× max-len (SOL) | 2× max-len (SOL) |
| --- | ---: | ---: |
| Program account (36 bytes) | 0.001141440 | 0.001141440 |
| ProgramData (45-byte header + capacity) | 7.348792560 | 14.696381040 |
| CLI-funded buffer, measured balance | 7.348792560 | 14.696381040 |
| Conservative simultaneous rent sum | 14.698726560 | 29.393903520 |
| Actual successful deployer total debit | **7.355174000** | **14.702762480** |
| Actual fees above final Program + ProgramData rent | 0.005240000 | 0.005240000 |

Capacity is 1,055,688 or 2,111,376 bytes. Both modes submitted actual LOCAL
`write-buffer` and `deploy` transactions and verified loader-v3 ownership,
executable status, stored deployer upgrade authority and every ELF byte.
The actual buffer data length was 1,055,725 bytes for both modes (37-byte buffer
header + ELF). Agave funded it using the larger ProgramData rent/capacity amount;
using just the minimum 37-byte header formula underbudgets this CLI path.
Deployment consumed/reused buffer funds, so the conservative simultaneous sum
is NOT the actual amount debited. No priority fees were added in these runs.
Rent/base-fee policies and final binary may change: rerun against the final build.

No production secret file was opened. Validation used generated local deployers
passed in memory as `SOLANA_DEPLOYER_PRIVATE_KEY`. The local script rejects an
empty variable, malformed key, credentials in URLs and every non-loopback RPC.
It writes temporary 0600 signer files, deletes the variable from CLI child env,
suppresses CLI failure output, verifies authority, and deletes files in `finally`.
On failure, a buffer may remain on LOCAL validator; restart that owned validator
instead of assuming its rent was recovered. Mainnet automation is intentionally
not enabled. An approved future script must retain/recover failed buffer identity.

Rafael may LOAD `.env.solana` through a non-echoing wrapper after separate approval;
do not print/source-display secrets or pass key bytes in command arguments.
Never test mainnet reachability by sending a transaction.

## Manager and keeper wallets — remaining budget gate

DEC-195: Manager pays own SOL transactions/position rent, keeper pays transport
receives and Wormhole posts; Fund vault holds zero spendable SOL, rent refunds
return to the payer, never NAV. No Fund-owned SOL reserve is proposed.

Core/report localnet measured two Wormhole posts at 61,123 CU each and a
**100-lamport message fee** each at the cloned state. That is not the entire
keeper cost: transaction signatures, priority fees, CCTP rent/receives, retries
and report-account rent remain separate. The full composed program lifecycle is
not production-ready on this build. Exact Manager/keeper funding is therefore
**UNVERIFIED**, not zero and not a made-up fixed wallet balance.

Before funding, record each action's actual payer balance delta and refunded
rent, configured number of reports/receives, maximum retry count, priority-fee
cap and safety margin. Sum per payer, not into NAV. No founder DEC fixes counts
or funding margin; those are operational inputs requiring approval. Refresh
the deployer totals above after the final program identity/ELF is fixed.

## What the tests actually establish

| Check | Result |
| --- | --- |
| Repository Foundry build | PASS, existing warnings |
| Plain native SBF/IDL build | PASS, existing warnings; no rehearsal feature |
| Deployment safety | 4/4 PASS |
| Offline scaffold Node | 7/7 PASS |
| Hub Solidity native v6 unit suites | 34/34 PASS |
| Same v6 factories/identity predictions across two public forks | 1/1 PASS |
| Arbitrum CCTP/native accounting composed suite | 4/4 PASS |
| Arbitrum TSLA/NVDA/SOL Chainlink proxy suite | 2/2 PASS |
| Robinhood Across return/finalized report/live-V3 income suite | 3/3 PASS |
| Prepared native core/report, cloned mainnet localnet | 8/8 PASS |
| Unprepared global native discovery | 37 PASS / 21 FAIL; incompatible genesis fixtures/absent probe accounts |
| Local buffer + deploy + authority/ELF equality | 1× and 2× PASS |

Native clone harness: 62 base accounts from slots 454212179–454212424, then
documented core/report fixture extension; loopback RPC 8995, faucet 9995,
gossip 19500, dynamic 19501–19560. Snapshot collection is not atomic at one slot.
Core/report fixture preparation and tests use generated local Manager/keeper
keys; finalized report consistency is 32. The owned validator was stopped.

The existing Arbitrum composed suite creates/seeds a two-spoke Mandate, sends
to Solana through real Circle code on the fork, accepts local-guardian native
reports, tracks capped transit NAV and receives a local-attester return. Its
Robinhood spoke is declared but is not exercised in that same Fund. Separately,
Robinhood tests exercise Across and report publishing. **There is no proof here
of one Fund allocating to BOTH spokes, accepting BOTH correlated reports and
receiving both returns.** No genuine Circle attestation was fabricated or
represented as live: local attester overrides/generated fixtures are explicit.
Recorded native report bytes are existing fixtures, not correlated fresh native
transactions into this deployment. `solana-three-chain-rehearsal.sh` says this
explicitly and never claims a complete three-chain lifecycle.

Do not run the global discovery runner as acceptance: track fixtures and swap
probe/verifier genesis requirements differ. The documented prepared core/report
suite passes independently. The existing full native rehearsal requires a
`rehearsal-v1-swap` build; it is NOT DEC-201/202 production V2 acceptance and
must NEVER become the deployment artifact.

## Coordinator requests / TODO(decision)

1. **DEC-200:** resolve the Fund PDA/Mandate/emitter commitment cycle, finalize
   EVM/native bootstrap consent, and provide reviewed Fund-creation calldata.
   No invented hash/PDA substitution is permitted by these scripts.
2. **DEC-202 / LC-173:** select and seal Solana reference-oracle and API-signed
   quote policy. Pyth candidates in the manifest are research facts, NOT approval.
   Production V2 swap remains a release gate; Manager price is not a substitute.
3. **DEC-198:** finish verified NVDAx admission/multiplier and three admitted LP
   choices in the final program/Mandate; current stock candidates are not evidence.
4. **DEC-189:** coordinator must replace scaffold program identity, rebuild and
   remeasure rent; actual upgrade authority remains Rafael's deployer until the
   pre-client-capital revocation gate. No shared program/contract files changed here.
5. Complete the shared three-chain Fund acceptance and Fund/Spoke deployment
   dry runs, L1-inclusive costs, Manager/keeper payer deltas and API/manual claim
   fallback before founder funding approval. T8b/T8c own logic fixes.
6. **TODO(decision):** retain existing fail-closed stock session handling; durable
   holiday/DST/off-hours exit valuation remains undecided. Current script session
   inputs are explicit, not an automatic market-calendar authority.

## Ordered mainnet runbook — approval required before ANY execution

1. Coordinator merges reviewed tracks, freezes final source/toolchains, resolves
   the gates above and runs a complete correlated rehearsal. Record source SHA,
   ELF hash, linked EVM creation/runtime hashes and all verified protocol accounts.
2. Rafael approves the updated FULL funding packet and wallet roles. Funding:
   approximately 50 USDC seed, EVM operator/Manager native gas, dedicated Solana
   deployer, bound Manager Solana Key and keeper. Pre-launch wallet check must
   prove connected key, binding and sufficient SOL (DEC-190/195).
3. Rafael's EVM operator signs new v6 stack deployment on Arbitrum, then same
   operator deploys Robinhood v6 factory using identical approved build/salt.
   Verify factory identity, every code store/library and immutable wiring.
4. Rafael's Solana deployer signs buffer writes and deployment of the APPROVED
   program identity; deployer is upgrade authority (DEC-189). Verify ELF and
   authority on-chain; recover/close failed buffers to their payer if necessary.
5. Team Manager EOA signs USDC approval and exact reviewed Hub creation/seed
   with immutable Manager Solana Key commitment and all three chains. This
   creates per-Fund CCTP adapter/connector, receiver and native registry; hard
   Fast ceiling is 5 bps (DEC-199), management cap stays 500 bps (DEC-196).
6. Same Manager EOA signs Robinhood `createSpoke` with the emitted Mandate hash;
   Manager Solana Key countersigns native initializer plus EIP-712 consent over
   approved Fund PDA/ATAs, nonce/expiry and sealed routes/emitter (DEC-200).
7. Verify receiver/emitter registration and routes BEFORE capital allocation.
   Manager signs allocation to Robinhood Across and Solana CCTP V2 Fast.
   Keeper signs receive-and-credit and finalized reports; verify actual balances,
   `amount - maxFee` pending claims and no write-off (DEC-191/192).
8. Manager Solana Key signs Kamino supply, approved API-signed Jupiter V2 ratio
   swaps and existing Raydium positions. Manager pays rent/gas; no Fund SOL.
   Keeper relays both chains' reports; verify one reconciled share price/NAV.
9. Manager signs exits and capital returns. Keeper receives/credits, reports
   return state and retries; manager/API manual fallback remains available.
   Preserve pending claims, credit unused fee cap as principal and never write off.
10. Save signed transaction hashes, protocol receipts and decoded reports for
    judging. Closed-team upgradeable demo only; revoke upgrade authority BEFORE
    client capital, never claim present immutability (DEC-189).

This runbook describes signers/order; it is not an authorization or a supplied
mainnet command. Safe local scripts cannot be switched to mainnet via an env var.
