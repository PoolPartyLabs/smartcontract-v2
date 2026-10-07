# Solana Hub v6 integration contract

New Funds only: DEC-188. Existing `FundFactory`, `CoreVault`, `ReportCodec` v5,
Robinhood spoke code and deployed Funds are unchanged. This document defines an
engineering wire ABI, not a new economic ruling.

## Deployment and launch gates

Deploy `FundFactoryV6` with separately stored registry creation code and v6 receiver
creation code. Pin **linked** `CoreVaultV6` creation code in `ProtocolWiring`.
Use `createFundV6`, not the deliberately disabled legacy `createFund` entry.
The factory retains the existing CREATE3 fund/address/salt scheme. Deploy the same
factory address on Robinhood to use its unchanged EVM `createSpoke` deployment
path; never call that path for Wormhole chain 1. Solana init is a separate program
instruction and must require the bound Solana key's acceptance (DEC-190).

The Core exposes `nativeRegistry`, `nativeMandateHash`, and `managerSolanaKey`.
The registry has no setter and commits complete mints/programs/pools/reserves.
Position accounts are created later within approved venues and travel losslessly
in reports, rather than being predicted as EVM CREATE3 addresses.

**Not launch-ready on its own:** Core v6 currently inherits the unchanged legacy
transit implementation. T2b must integrate CCTP pending-claim/no-refund accounting
before the Core creation-code hash is pinned for deployment. The constructor
requires every native hub transport adapter to target Arbitrum TokenMessengerV2
`0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` and return a zero
`fillDeadlineSeconds()`. The legacy send logic rejects that zero deadline: this
is intentionally a blocked send, not a fake Across route. T2b's read-only surface
is declared in `src/interfaces/ISolanaTransportV6.sol`. No bridge adapter or Core
transit code was edited in this track. The local factory test uses a non-executing
transport wiring fixture, not a CCTP mint/burn.

### Final integration merge

The final fetch merged T2b's `CoreVaultCctp`, `CoreVaultCctpLogic`,
`CctpBridgeAdapter` and `CctpReceiveConnector`, plus the Solana scaffold. They are
not automatically substituted for this factory's Core v6. T2b's Core constructor
also requires a `CctpRoute`, adapter, connector and spoke index; that complete
route/fee configuration still needs an immutable commitment and factory deployment
composition. The scaffold does not yet supply a matching native report encoder;
Rust byte-for-byte parity remains a release blocker.

The size inventory includes those merged production declarations. The strict test
correctly fails for merged `CoreVaultCctp` (24405 bytes, only 171 spare), while
every T2a production contract meets the existing 1,000-byte-margin rule. That
failure is not hidden or weakened; T2b/coordinator must reduce its size.

## Manager binding: exact EIP-712 definition

Domain:

```text
name = "PoolParty Solana Fund"
version = "6"
chainId = EVM Hub chain ID (42161)
verifyingContract = new FundFactoryV6 address
```

Type string (exact order and spelling):

```text
ManagerSolanaBinding(bytes32 solanaKey,address fund,bytes32 spoke,uint256 spokeChainId,bytes32 nativeMandateHash,uint256 nonce,uint256 expiry)
```

`fund` is the predicted Core CREATE3 address. `spoke` is the full Wormhole emitter
PDA. `solanaKey` is the Manager's full Ed25519 public key, not an EVM address.
`spokeChainId` is the Mandate accounting chain ID, **not** Circle domain 5 or
implicitly Wormhole chain 1. Config must use the same ID as the report and spoke
registry. `nonce` equals the per-EVM-Manager factory counter; creation consumes it
atomically. `expiry` is Unix seconds (inclusive). ECDSA recovery uses OpenZeppelin
low-s enforcement and must recover the EOA Manager, who is also the caller. The
same Solana key can bind multiple Funds with separate signatures (DEC-190).

`nativeMandateHash = keccak256(abi.encode(uint256(6), Config))`, where:

```text
Config = (
 bytes32 program, bytes32 spoke, bytes32 usdcMint, bytes32 managerKey,
 uint256 chainId, Asset[] assets, Venue[] venues
)
Asset = (bytes32 mint, address accountingId, bool stock)
Venue = (bytes32 program, bytes32 pool, bytes32 reserve, bytes32 token0, bytes32 token1)
```

Exactly one of pool/reserve is nonzero. The mint set is limited to Solana native
USDC, WSOL and TSLAx; TSLAx must be marked stock. The hub's EVM `mandateHash`
remains the v5 Mandate hash; the Core separately immutably commits the native
hash. Both hashes must match the authenticated native report. The binding digest
is also stored in `factory.bindingCommitment(core)`.

The Solana init implementation must verify the domain, type hash, native hash,
Fund/spoke/key tuple and signed expiry, and require a Solana signer matching
`managerKey`. A Hub signature proves consent, not physical Fund deployment.
Bootstrap cannot become trusted unless it exactly matches the committed registry.

## Full-width identities and accounting aliases

All Solana keys on the wire are exactly 32 raw bytes in native public-key order;
base58 is display only. EVM addresses continue using their existing 20-byte ids.
For compatibility with unchanged Core valuation storage, native mints use an
internal synthetic address:

```text
address(uint160(uint256(keccak256(abi.encode(
    "PoolParty/SolanaAsset/v6", uint16(1), bytes32(mint)
)))))
```

This hashes the full key with a namespace, **never truncates the public key**.
The closed registry retains the reverse context and refuses alias collisions
among native assets; the factory also refuses collision with EVM Mandate tokens.
Aliases must not be used as token contracts, CCTP recipients, or Solana accounts.

## Wire layout: canonical Solidity ABI, version 6

Encode `abi.encode(uint256(6), Report)`. This is **not Borsh**, Anchor account data,
or a packed little-endian payload. Every ABI word is 32 bytes, big-endian.
Unsigned integers are left-zero-padded; signed ints are sign-extended; `bytes32`
is copied unchanged; bool is a full word 0 or 1. Arrays have a length word before
their elements. Dynamic offsets are in bytes relative to the enclosing tuple
head; array-element offsets, if any, start after the array length word. Dynamic
`bytes` has a length word plus data padded to a multiple of 32.

Outer word 0 = version 6, word 1 = report offset 64. Report's 18-word head is:

| Word | Field | ABI type |
| --- | --- | --- |
| 0 | fundId | bytes32 |
| 1 | mandateHash (EVM Mandate) | bytes32 |
| 2 | nativeMandateHash | bytes32 |
| 3 | sequence | uint64 |
| 4 | spokeChainId | uint256 |
| 5 | slot | uint64 |
| 6 | timestamp | uint64 |
| 7 | unallocated | offset to TokenAmount[] |
| 8 | positions | offset to Position[] |
| 9 | cumulativeIncome | offset to TokenAmount[] |
| 10 | collectedIncome | offset to TokenAmount[] |
| 11 | cumulativeReceived | uint256 |
| 12 | cumulativeSentHome | uint256 |
| 13 | arrivedTransits | offset to TransitAmount[] |
| 14 | inFlightToHub | offset to HubBoundAmount[] |
| 15 | unwindResults | offset to bytes |
| 16 | collectionResults | offset to bytes |
| 17 | mintStates | offset to MintState[] |

Nested fixed tuples, in exact field order:

```text
TokenAmount = (bytes32 mint, uint256 amount)                    // 2 words
Position = (
 bytes32 program, bytes32 pool, bytes32 reserve, bytes32 position,
 int24 tickLower, int24 tickUpper, uint128 liquidity,
 bytes32 token0, bytes32 token1,
 uint256 principal0, uint256 principal1, uint256 income0, uint256 income1
)                                                            // 13 words
TransitAmount = (bytes32 transitId, uint256 amount)             // 2 words
HubBoundAmount = (bytes32 transitId, uint256 amount, uint8 kind) // 3 words
MintState = (
 bytes32 mint, uint64 multiplierBits, uint64 newMultiplierBits,
 int64 effectiveAt, bool paused, bool frozen, bytes32 transferHook
)                                                            // 7 words
```

`kind`: Principal = 0; Income = 1, matching `FundTypes.TransferKind`. Transit
amounts are native USDC base units. DEC-191 requires `amount - maxFee` for Fast
in-flight value and indefinite pending claims; producers must not age out CCTP
entries using v5's Across retention constant. No refunded-transit field exists in
v6. Native operating cash is absent/zero (DEC-195); WSOL LP exposure is not native
SOL gas cash. Collected/cumulative income remains separate from principal.

`MintState` carries raw IEEE-754 f64 **bit patterns**, as numeric uint64 ABI words,
not a decimal-scaled scalar. Both multiplier bit patterns must be exactly
`0x3ff0000000000000` (1.0), with no paused/frozen/hooked state. This authenticates
the narrow TSLAx unit-multiplier demo path; non-unit or pending non-unit actions
are refused rather than composed with a potentially pre-split equity price.
Each admitted stock mint requires exactly one state entry, even if held amount
is zero. A changed issuer state cannot silently invalidate the guard by omitting
the witness. Additional supported multiplier rules need a new version.

Reserve positions are single-token exact-value reports: token1, liquidity, ticks,
principal1 and income1 are zero. CLMM positions require a registered token pair,
nonzero liquidity, and `-443636 <= lower < upper <= 443636`. Duplicate position
accounts or repeated mints within one token-amount bucket are refused.

## Receiver acceptance and accounting projection

Core Bridge cryptographically verifies VAAs first. Registered `(emitterChainId,
bytes32 emitterAddress)` lookup precedes source-specific consistency validation:
Wormhole chain 1 requires **32**, all registered EVM sources require **1**. Unknown
emitters and every other source consistency are refused (DEC-192), including
Solana 0/1/200 and EVM 32. Wormhole/report sequence counters are independently
strictly increasing after the first report. Fund/hash/chain, max age and future
clock skew checks use the existing rules. All spokes must have the same max age.
Callback failures roll back all payload/counter changes.

The native report must re-encode identically; alternate offsets, trailing bytes
and wrong versions are refused. `latestNativeReport()` returns exact accepted
bytes. `latestReport()` implements the existing interface as a v5 **accounting
projection**: mints map to closed aliases, pool/reserve stays bytes32, position
account becomes bytes32 poolId, program remains only in native bytes (projected
adapter = zero), slot maps to blockNumber. CLMM principal is still recomputed by
the existing Core oracle-composition code at independent Hub token prices;
reported pool-spot principal is not trusted. This reuses Uniswap Q96 valuation
math on the same tick/liquidity semantics; exact Raydium Q64 rounding parity is
not an executed CPI proof and needs composed test validation.

`unwindResults` and `collectionResults` must be **empty** for now. Their native
command codec/position identity integration is not implemented in this track;
accepting EVM result blobs would create an unsafe implicit command protocol.

## Pricing and caveats

Arbitrum TSLA/USD proxy: `0x3609baAa0a9b1f0FE4d6CC01884585d0e191C3E3`.
SOL/USD proxy: `0x24ceA4b8ce57cdA5058b924B9B9987992450590c`.
Real-fork tests read descriptions, 8 feed decimals and positive rounds at block
512239244. TSLAx has 8 raw decimals; WSOL 9; USDC 6. Underlying USD and USDC use
the existing 1:1 convention. For raw stock amount B, decimals d, multiplier m
and equity USD/share P, value = `(B / 10**d) * m * P` in USD, converted to USDC
base units. Here m is authenticated as exactly 1 **before** LP ratio math.

The immutable source permits one Oct 6–9, 2026 regular US session only (13:30–20:00
UTC; inclusive open, exclusive close). It rejects weekends/out-of-demo sessions
and must be deployed with that session's preflight-verified window. Refreshed
off-hours feed timestamps do not open stock valuation (DEC-194). This is not a
general market calendar. SOL and USDC remain available off hours.

The existing Core consumer checks feed/report staleness on mints and can use
cached prices on payouts. Off-hours fresh TSLA quotation is refused; this is not
proof of an authenticated off-hours exit price. Fail-closed mint policy and
cached-price payout policy need coordinated production review.

## Golden vectors and verification

- `test/fixtures/solana-report-v6.hex`: 1280-byte canonical report. Fund/hash/native
  hash = 1/2/3; sequence/chain = 1/1; slot 453978307; timestamp 1791286864;
  unallocated USDC 50,000,000; arrival id 900 amount 49,990,000; one TSLAx unit
  multiplier state. Other arrays empty and cumulative totals zero.
- `test/fixtures/check-solana-v6.py`: independently constructs the ABI in Python's
  standard library. Run `python3 test/fixtures/check-solana-v6.py`.
- `test/fixtures/solana-report-v6-position.hex`: 1792-byte companion with a full-width
  position account, signed ticks -100/100, liquidity 1000, principal 12/34, income
  56/78, and an Income home transit id 901 amount 48,000,000. The independent
  encoder and Solidity both compare this vector, including int24 sign extension.
- `ReportCodecV6Test.testGoldenVectorByteForByte`: Solidity must encode exactly
  the same bytes. The Solana encoder should import this fixture and compare
  **its own** output before any demo send; this track does not claim Rust parity.
- `test/fixtures/solana-finalized.vaa.hex`: 1048 real public signed VAA bytes from
  Wormholescan chain 1/emitter
  `ec7372995d5cc8732397fb0ad35c0121e0eaa90d26f828a534cab54391b3a4f5`,
  sequence 1428661. Version 1, Guardian set 7, 13 signatures, body offset 864,
  consistency byte offset 914 = 32. Payload is an existing external transfer,
  **not** a Pool Party report; the fixture test checks framing, not new report
  provenance or Guardian verification.
- `ValueReportReceiverV6ForkTest`: real Arbitrum Core verifies crafted v6 VAAs
  with the SDK's test-only Guardian override; no production Guardian set modified.

No repository gas snapshot exists. Unit-test gas output and production runtime
size checks provide measurements instead. Factory runtime has only about 1 KB
spare: any T2b integration must rerun the strict 1,000-byte-margin size suite.

## TODO(decision) / integration blockers

1. Canonical native accounting chain-ID namespace and PDA/genesis/program
   derivation inputs must be agreed with Solana init; the codec does not confuse
   EVM ID, Wormhole ID and Circle domain. No deployment address is invented here.
2. Durable holiday/DST calendar, corporate-action alignment, non-unit multiplier
   support and authenticated off-hours exits remain undefined; the demo uses the
   bounded immutable session and strict unit-state refusal.
3. Native unwind/collection result codec and complete permissionless closure/
   income settlement integration are absent: nonempty result blobs are refused.
4. Swap route/DEC-136 overlap remains pending in the founder record; no swap
   venue or pool-overlap exception is selected here.
5. Report payload/array size bounds and composed Solana report partitioning need
   producer/receiver agreement and gas/CU evidence before live report delivery.
6. T2b CCTP Fast pending claims, native return leg valuation and transit alias-to-
   real-USDC distinction must be integrated before funding. Constructor target
   gating alone does not implement that state machine.

Management fee cap remains **500 bps** (DEC-196 MVP exception). No mainnet
transactions, deployments, credential reads, or private-key loading occurred.

## T2c composed Hub contract (2026-10-06; supersedes foundation gaps)

CoreVaultV6 now inherits CoreVaultCctp. FundFactoryV6 deploys its Fund's CCTP
adapter and receive connector before Core, using linked SolanaDeploymentV6;
Robinhood Across remains an independent route in the same Mandate (DEC-188).
The native signature/hash commits the following **additional final Config field**:

```text
Config = (program, spoke, usdcMint, managerKey, chainId, Asset[], Venue[], Transport)
Transport = (
 address hubUsdc, address tokenMessenger, address messageTransmitter,
 uint32 destinationDomain, bytes32 mintRecipient, bytes32 destinationCaller,
 bytes32 remoteTokenMessenger, bytes32 remoteVaultAuthority,
 uint256 fastFeeCeiling
)
```

The hash remains `keccak256(abi.encode(uint256(6), Config))`; adding Transport
changes the hash and binding digest. T1 must use this complete tuple, not the
foundation-only definition earlier in this document. The existing report golden
vectors deliberately use a supplied illustrative hash; their outer ABI is unchanged.
`hubUsdc` is real Arbitrum USDC, never the native accounting alias. Factory
pins Circle's official Arbitrum messenger/transmitter, checks the on-chain remote
messenger for domain **5**, and requires `fastFeeCeiling = 50_000` in the adapter's
1/10,000-bps units (**5 bps**, DEC-199). Both adapter burns and connector return
receipts refuse higher fees, with conservative ceiling rounding. ATA, caller and
vault-authority keys are full-width immutable commitments; Solana init must
verify their derivation against the accepted Fund/program (never trust arbitrary
submitted accounts). Fee surplus is principal both outbound and returning,
bounded by the actual sent amount and credited monotonically once (DEC-191).

### Canonical Solana namespace and PDA seeds

For this v6 cohort, internal accounting `chainId = 1` names **Solana mainnet**;
Wormhole emitter chain is independently checked as `uint16(1)`, and Circle's
destination domain is independently fixed at `uint32(5)`. Equal numeric values
are not interchangeable types. Devnet cannot be registered as this mainnet peer.
The full native peer identity is `(Wormhole chain 1, program pubkey, emitter PDA)`;
the program is committed in Config and emitter in both Config and EVM Mandate.

PDA seed definitions match the current read-only `solana/docs/ARCHITECTURE.md`:

| Identity | Seeds under the committed program |
| --- | --- |
| FundState | `[b"fund", hub_core_20_bytes, spoke_index_u16_le, mandate_hash_32_bytes]` |
| Fund vault authority | `[b"vault", fund_state_pubkey]` |
| Wormhole emitter | `[b"emitter", fund_state_pubkey]` |
| Immutable mandate | `[b"mandate", fund_state_pubkey]` |
| Ledger | `[b"ledger", fund_state_pubkey, mint_32_bytes]` |
| Transit | `[b"transit", fund_state_pubkey, transit_id_32_bytes]` |
| Order/result | `[b"order", fund_state_pubkey, hub_order_id_32_bytes]` |

Use Solana's canonical PDA bump search, not EVM address truncation. Derive the
Fund USDC ATA from the vault authority, native USDC mint and **SPL Token** program;
stock ATAs use **Token-2022**. Hub commits these outputs, not a fabricated EVM
CREATE3 address. Receive-and-credit authority is the T1b-authorized CPI signer
committed as `destinationCaller`; its seed choice remains T1b's account-layout
integration gate, not an invented Hub seed. No Solana file is changed here.

### Native command-result ABI

The outer Report fields stay `bytes unwindResults`, `bytes collectionResults`.
`unwindResults` is canonical `abi.encode(OrderResult[])` with the same 13-word
fixed tuple as EVM (no native addresses in this tuple):

```text
OrderResult = (
 bytes32 orderId, bytes32 requestId, uint32 attempt, bytes32 transitId,
 uint256 amountSent, uint256 amountToArrive, uint256 spotOut,
 uint256 marketCost, uint256 leaverCost, uint256 delivered,
 uint256 excluded, bool refunded, uint256 closureExcessCost
)
```

At most 16 results, matching EVM. `refunded` must be false on CCTP. Closure,
unwind and payout results pass unchanged to the existing Core state machines;
order/request/transit ids retain their meaning, not Wormhole/Circle sequence ids.

`collectionResults` is canonical `abi.encode(NativeCollectionResult[])`:

```text
NativeCollectionResult = (
 uint64 resultId, uint64 round, bytes32 transitId, uint256 amountSent,
 bytes32[] mints, uint256[] sold, uint256[] obtained, uint256 amountToArrive
)
```

At most 8 results, matching EVM. Mints must be unique and admitted; all three
arrays have equal length. The receiver maps each full mint to its closed-registry
accounting alias, then invokes **unchanged** EVM income recognition, frozen-result
conversion, fee/protocol split and settlement. Base token first; sold is original
token units, obtained is native-USDC units. `amountToArrive` is `amountSent -
maxFee`, not executed-fee proceeds. Empty bytes means no results; canonical
encoded empty arrays are also valid. Result evidence does not itself mint USDC:
Circle receive-and-credit and source-report reconciliation remain required.

### NVDAx and share-pricing gate

DEC-198 adds mint `Xsc9qvGR1efVDFGLrVsmkzv3qi45LTBjeUKSPmx9qEh` (8 decimals)
and Arbitrum NVDA/USD proxy `0x4881A4418b5F2460B21d6F08CD5aA0678a7f262F`.
The real-feed fork checks code, decimals, description, positive answer, round
and timestamp. NVDAx's verified effective multiplier is **not 1**. The closed
demo pins the observed binary state:

```text
multiplierBits    = 0x3ff003c2ac1bf43f
newMultiplierBits = 0x3ff006f7d589fea9
effectiveAt      = 1789000200
price            = floor(equity_raw_unit_price * 0x1006f7d589fea9 / 2^52)
```

Every admitted stock requires its finalized witness, including zero holdings.
Changed state, pause/freeze/hook or missing witnesses fail closed. TSLAx retains
unit-multiplier guards. Share mint/burn preflight in CoreVaultV6 additionally
checks admitted stock pricing before deposits, instant payout requests, payout
claims/settlements and closed exits; legacy payout cached-price fallback cannot
bypass the native stock market-hours gate. Legacy Core's hook is a no-op.

**TODO(decision):** durable holiday/DST calendar, future multiplier/corporate-action
updates and off-hours exits still need a separately approved version. This
implementation supports only the immutable verified October 6–9 demo sessions.
DEC-197 resolves Jupiter/overlap policy; swap implementation is a Solana track,
not a remaining Hub venue decision. Producer report-size/CU bounds, real Solana
encoder/PDA/init acceptance and complete CPI flows remain release gates.

Evidence: composed Arbitrum fork creates a three-chain-shaped Fund with real
USDC, real Circle Fast burn/mint and real Wormhole verification under test-only
attester/guardian overrides. Seed NAV 49,000,000; outbound max-fee NAV 48,995,000;
actual-arrival NAV 48,999,000; return pending NAV 48,994,000; minted/credited NAV
48,998,000 and share price `48,998,000 * 1e18 / 49`. This does not prove live
Solana CPI execution or production attestation issuance. No mainnet transaction
is submitted.
