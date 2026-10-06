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
