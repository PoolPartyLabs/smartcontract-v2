# Solana spoke architecture and EVM parity map

## Scope and authority

One shared `pp_spoke` program, with a distinct Fund state and vault authority per
new Fund (DEC-188). Existing Arbitrum/Robinhood Funds are untouched. Upgradeable
only for the closed demo; Rafael's dedicated deployer is the upgrade authority,
and revocation is a pre-client-capital gate (DEC-189). No deployment is authorized
by T0. A code hash is not immutability while that authority exists.

The EVM Manager stays the Fund's identity. Initialization must verify EOA EIP-712
authorization plus Solana acceptance, bound to Fund, Hub Core, spoke index,
Mandate hash, Manager key, domain and replay protection. The commitment is fixed
at creation, reusable only through separate per-Fund authorizations (DEC-190).
No rotate-manager instruction or live-Mandate setter exists. DEC-200 bootstrap
verifies the native EIP-712 tuple and the bound Solana transaction signer, with
the Mandate hash in Fund PDA seeds. No extra Hub message is required. Capital
and commands remain independently gated by the sealed transport/emitter.
Payloads use bounded instruction-specific encodings. Non-ACK Hub commands,
income-result dispatch and production swap execution still fail closed.

## Accounts and derivations

Engineering seed convention (not a new economic DEC), all under `pp_spoke`:

| Account | Seeds / purpose | Owner track |
| --- | --- | --- |
| `FundState` | `[b"fund", hub_core_20_bytes, spoke_index_u16_le, mandate_hash_32_bytes]` | T1 |
| Fund vault authority | `[b"vault", fund_state_pubkey]` | T1 |
| Wormhole emitter authority | `[b"emitter", fund_state_pubkey]` | T1 |
| Immutable Mandate/config | Embedded and sealed in `FundState`; no separate Mandate PDA | T1/T8a |
| Token ledger | `[b"ledger", fund_state_pubkey, mint]`; principal/income/excess separated | T1 |
| Transit | `[b"transit", fund_state_pubkey, transit_id_32_bytes]`; persistent pending claim | T1b |
| Position record | `[b"position", fund_state_pubkey, venue_position_key]`; recorded units/checkpoints | T3/T4 |
| Order/result | `[b"order", fund_state_pubkey, hub_order_id]`; replay and completed step/result book | T1 |

FundState persists up to 32 position records and 64 transit records. Reports
require every registered record, including closed/received records; supplied
account subsets are not exhaustive snapshots. Confirmed outbound arrival ACKs
retire claims, not their accounts. No expiry, sweep or write-off is enabled.
Order/result PDAs in the table remain reserved, not implemented execution.

USDC and WSOL use legacy SPL Token; TSLAx uses Token-2022 (DEC-194). Fund vault
PDA owns their ATAs; derive each ATA with the correct token-program ID. Kamino
cTokens and Raydium position NFTs are also vault-owned, never Manager-owned.
The Fund has **no spendable native SOL**; mandatory rent lamports on accounts
are not NAV or Operating Cash. Manager pays operations/position rent; keeper
pays receives/posts; tracked rent refunds go to the original payer (DEC-195).
WSOL in the strategy is a token position, not a gas treasury. Never unwrap Fund
WSOL to pay fees. Economic USD NAV pricing remains on the Hub. T5b provides
Solana reference-price and verifier primitives for swap safety, but production
swap remains disabled pending sealed policy and founder oracle decisions.

## Why adapters are modules, not programs

T3/T4/T5 implement internal modules of `pp_spoke`, not separately deployed
adapters. The typical legacy four-CPI-level budget is then available to
`pp_spoke -> venue -> token/ATA`, instead of spending another level on a
Pool Party adapter; current runtime features may permit more depth, but the
MVP must not depend on them. This reduces compute/account forwarding and avoids
new upgrade authorities. CPI allowlists and validation still live in separate
modules; same program does **not** mean arbitrary CPI privileges. Lean encoders
need source-pinned discriminators and exact account-order tests. T3/T4 must
measure CU/stack and prove Token-2022 flows against cloned deployed binaries.
An immutable program in the consumer release also freezes these modules;
third-party venue upgradeability remains an external risk (DEC-053, DEC-189).

## Instruction map

| EVM entrypoint / behavior | Solana instruction / account read | Decisions |
| --- | --- | --- |
| `SpokeVaultBase` constructor, `_pin*`, factory deterministic deployment | `initialize_fund`; immutable Mandate, key binding, vault ATAs | DEC-053, DEC-188, DEC-190 |
| `openPosition`, Aave `openPosition` | `kamino_supply` for USDC exact-value positions | DEC-068, DEC-193 |
| `increasePosition`, Aave increase | `kamino_supply` or `raydium_increase_position` | DEC-080, DEC-193 |
| `decreasePosition`, Aave decrease | `kamino_redeem` or `raydium_decrease_position` | DEC-080, DEC-193 |
| `closePosition`, Aave close | `kamino_redeem` (all recorded cTokens) or `raydium_close_position` | DEC-080, DEC-193 |
| Uniswap V4 open/increase/decrease/close | `raydium_open_position`, `raydium_increase_position`, `raydium_decrease_position`, `raydium_close_position` | DEC-193, DEC-194 |
| `collectIncome`, adapter `collectIncome` | `kamino_collect_income` or `raydium_collect_fees`; never farm rewards | DEC-079, DEC-193 |
| `collectIncomeAll` / income library dispatch | `collect_income_all`; bounded per-position work and separated buckets | DEC-122, DEC-193 |
| `refreshIncomeResults` | `refresh_income_results`; result account updates, not arbitrary accounting | DEC-122, DEC-161 |
| `swap`, V3 swap adapter execution | `swap_exact_in`; signed/fallback route authorization unresolved | DEC-136, DEC-193 |
| V3 swap-before-LP orchestration | `swap_to_ratio`; validated min-outs/deadlines and final balances before LP | DEC-136, DEC-193 |
| `sendToHub`, Across outbound transport | `send_to_hub`; native USDC, Fast, destination caller connector, transit PDA | DEC-085, DEC-191 |
| `handleV3AcrossMessage`, arrival ledger credit | `receive_and_credit`; Circle CPI mint plus recorded-credit atomically | DEC-090, DEC-191 |
| keeper/manual arrival retry | `retry_receive`; same receive-and-credit path, no alternate credit bypass | DEC-191 |
| `recognizeRefund`, cross-chain refund book | `recognize_refund`; placeholder fails closed, CCTP is not Across | DEC-066, DEC-191 |
| `report`, `_publishReport` | `publish_report`; build/refresh validated state, emitter signed CPI, keeper-paid fee | DEC-093, DEC-192, DEC-195 |
| `buildReport`, report codec encode | `build_report`; owner chooses bounded report account/return data without truncation | DEC-083, DEC-093, DEC-192 |
| `executeOrder`, `OrderVerifier` | `execute_order`; authenticated Hub emitter VAA, Fund/Mandate/sequence replay checks | DEC-120, DEC-121, DEC-122 |
| `_executeUnwindOrder`, proportional position unwind | `execute_unwind_order`; authenticated order account, proceeds reserved and sent home | DEC-120, DEC-137, DEC-139 |
| `_executeCloseOrder`, irrevocable close/all home | `execute_close_order`; authenticated order, closure/result state | DEC-121, DEC-147, DEC-149 |
| `_executeCollectOrder` | `execute_collect_order`; authenticated order, segregated income to Hub | DEC-122, DEC-161 |
| `sweepExcess` / donations | `sweep_excess`; explicit recipient policy, never ledger credit from balance alone | DEC-055, DEC-080 |
| Kamino exact-value interest freshness | `kamino_refresh`; supply-only reserve refresh may skip prices | DEC-068, DEC-193 |

`execute_*_order` wrappers must NOT become Manager bypasses for Hub commands:
they consume a verified Hub order PDA and share replay/step state with
`execute_order`. Decide atomic vs resumable work by tested transaction limits;
success is only recorded after the complete result is committed. Keepers/manual
submitters are transport executors, never economic authorities.

## EVM view functions and internal libraries

All `SpokeVaultBase` getters become validated account reads, not extra transaction
entrypoints: `adapters`, `swapAdapters`, `bridgeAdapters`, `bridgeTarget`,
`adapterCodehash`, `isMandateToken`, `poolTokens` read the immutable Mandate;
`unallocatedBalance`, `ledgerTokens`, `collectedIncome`, `cumulativeIncome` read
ledger accounts; `positions` reads position accounts; `cumulativeReceived`,
`cumulativeSentHome`, `reportSequence`, `hubBoundTransit`, `hasArrived`,
`arrivals`, `inFlightTransitIds` read Fund/transit/report state. An executable
program's bytecode hash is not interchangeable with an EVM adapter codehash.

`operatingCash`, `operatingCashFloor`, `operatingCashTopUp` are zero/not applicable
under DEC-195; `setOperatingCashParameters` has no Solana equivalent. No Fund
native-fee top-up instruction exists. `spokeClosed`, `closureCost`,
`unwindDelivered` become close/order-result reads. `unwindStep`, `unwindSend`
are internal bounded adapter/CCTP dispatch; **never expose EVM self-call guards
as public signer-authorized functions**. `receiveFromCoreVault`,
`returnToCoreVault`, `unwindForPayout` are Hub-chain-only EVM functions and stay
EVM; remote effects enter through authenticated orders/CCTP.

`SpokeLedger` token registration, debit/credit principal and income, arrival and
sent/refund tracking move into T1 ledger and T1b transit helpers. Token account
balances are observations; donations are excess, not Share Assets (DEC-055,
DEC-080). `SpokeIncomeLib`/`SpokeIncomeTypes`/`SpokeVaultIncome` move into T1
collection/result accounts with T3/T4 collection dispatch. `SpokeUnwindLib`,
`SpokeUnwindTypes`, `SpokeVaultUnwind`, `SpokeCloseLib` map to T1 verified-order
execution/results and T3/T4 unwind helpers. `SpokeCrossChainLib` maps to T1b
send/credit/transit state. `SpokeVaultTypes` maps to Fund/Mandate/ledger accounts.

## Hub-facing functions and report encoding

`CoreVaultTransit`/`CoreVaultTransitLogic`: `sendToSpoke`, route/arrival getters,
reconciliation, returned-principal recognition and timeout handling remain
EVM. Solana supplies receipt totals/transit IDs and sends USDC to the approved
Arbitrum receive-and-credit connector. In-flight is `amount - maxFee`; unused
fee allowance arriving is **principal**, never yield. Retry is not write-off
(DEC-191). No expiry-based ledger decrement is permitted.

`CoreVault`, `CoreVaultLogic` and `src/report/*` acceptance/valuation remain Hub
logic: emitter/Fund/Mandate/sequence, slot/timestamp and common max-age validation,
separated position quantities, independent Hub USD valuation and reconciliation.
`CoreVaultIncome*` request/recognize/credit/read-report/collect-spokes/finalize map
to Hub income accounting plus Solana collect orders/results and Income transits.
`CoreVaultPayout*` and `CoreVaultClosureLogic` unwind/close/finalize wait for the
authenticated Solana order results and arrival state. Shares, fee vaults,
Manager registry, deposits, investor payouts and settlement stay EVM. Cap stays
500 bps in this build (DEC-196), not a new fee-policy interpretation.

`ReportCodec.sol` version 5 is ABI encoded and contains 20-byte token/adapter
addresses. Never truncate Solana pubkeys into it. T1 and EVM integration must
agree a chain-qualified, versioned 32-byte identity mapping before reports can
be accepted: **TODO(decision)** for final wire schema and asset aliases. Carry
all v5 semantics: Fund/Mandate, sequence, chain namespace, slot/time,
unallocated principal, position principal and uncollected income, monotonic
cumulative income, collected income, zero native Operating Cash, cumulative
received/sent, arrived transit totals, in-flight IDs/amounts/kinds, unwind and
collection results, refund IDs. Wormhole chain 1, CCTP domain 5 and internal
Solana chain identifier are separate namespaces. Wormhole Finalized VAA byte
is 32; `post_message`'s enum encoding is **not** necessarily 32 (DEC-192).

## Safe unresolved defaults

- **TODO(decision):** swap venue, deterministic/API route authorization and
  DEC-136 swap/LP pool overlap. Keep both swap handlers disabled until resolved.
- **TODO(decision):** final EIP-712 type/domain, Hub proof of creation/EOA check,
  and acceptance commitment transport. Never trust caller-supplied Manager data.
- **TODO(decision):** versioned cross-VM report/order schema, bounded payload
  handling, canonical identity/decimal aliases and approved Hub emitter.
- **TODO(decision):** CCTP pending-claim recovery/refund proof model; no Across
  refund semantics, timeout write-off or Standard-mode downgrade by inference.
- **TODO(decision):** excess/late-arrival recipient wiring and TSLAx issuer
  seizure/paused handling; follow existing Fund rules, no Manager sweep bypass.
- Real program identity, immutable peer commitments, account sizing, CU budgets,
  transfer-extension handling and deployed-binary ABI verification are engineering
  integration gates. Scaffold is **not safe for capital** until owners implement
  and test these checks. Accepted issuer powers do not authorize ignoring them.
