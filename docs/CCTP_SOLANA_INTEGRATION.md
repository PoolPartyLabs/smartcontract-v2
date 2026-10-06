# CCTP V2 Fast — new Hub Core integration

Scope: DEC-188 new Funds only; DEC-191 native USDC, Fast both ways, atomic
receive-and-credit, capped-fee accounting, persistent claims. DEC-192 requires
finalized source reports independently of Circle's Fast capital attestation.
Existing `CoreVault` and the Robinhood Across route remain available unchanged.
No deployment or broadcast is authorized by this document.

## Components and custody

- `CctpBridgeAdapter`: `IBridgeAdapter` builder, `CCTP_V2` protocol id, no custody
  or approvals. Outbound native USDC, Circle destination domain 5, minimum finality
  1000, immutable full-width Fund USDC ATA and spoke receive authority. Hooks use
  the existing 160-byte `TransitMessage` v1 ABI encoding, including the business id.
- `CctpReceiveConnector`: immutable, permissionless
  `receiveCctpAndCredit(bytes message, bytes attestation)`. The keeper, API and
  Manager UI use the same entry. Circle header/body version **1** is the deployed
  V2 wire version; header length 148, body prefix 228, hook length 160. The connector
  checks both Circle messenger identity and the distinct Solana Fund custody PDA,
  native mint, domains, Fund/id, finality, caller and Core recipient. It never holds
  tokens. Circle verifies attestations and expiration; the wrapper checks exact
  `amount - feeExecuted` mint delta directly in Core custody.
- `CoreVaultCctp`: separate opt-in Core version, constructor-bound adapter and
  connector. `sendToSolana(uint256 amount, bytes feeData)` is Manager-only;
  `creditCctp(...)` is connector-only. The same Core still uses the existing
  `sendToSpoke` entry for Robinhood Across. The CCTP adapter must be listed in the
  Hub side of the Mandate's Solana bridge route.
- `CoreVaultCctpLogic`: linked accounting library. Keeps Core runtime below the
  EIP-170 limit and preserves payout/income hooks.

Arbitrum One deployment wiring verified in the supplied research and fork tests:

| Component | Address |
| --- | --- |
| Native USDC | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| TokenMessengerV2 | `0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d` |
| MessageTransmitterV2 | `0x81D40F21F12A8F0E3252Bccb954D722d4c464B64` |

The factory must pin these deployed targets, not accept arbitrary Manager-supplied
Circle lookalikes. Constructors accept targets explicitly to support local tests
and factory-specific deployment wiring; they are not a substitute for factory
validation. Do not query newer `minFee()` ABI on this historical Arbitrum deployment.

## Fee data and claim accounting

`feeData = abi.encode(uint256 feeBpsScaled)`; the scale is **10,000 units per bp**,
so Circle's 1.4 bps quote is `14_000`. This preserves fractional bps without floats.
The immutable `maxFeeBps` ceiling uses the same units. The authorized sender fixes
the quoted rate at send; the adapter calculates
`maxFee = ceil(amount * feeBpsScaled / 100_000_000)` and books `amount - maxFee`.
Amount is bounded to `uint64` for Solana. Above-bound, malformed, unsupported-route
and zero-net sends fail before custody debit. The adapter does not authenticate an
off-chain API quote; the ceiling is the on-chain protection, as requested.

`TODO(decision)`: select the numeric deployment fee ceiling. The 2 bps value in
tests is a fixture choice, **not** a product ruling or production default. Operational
quote freshness and alerts must be supplied by the keeper; no unsupported signed
Circle quote verification or default SLA is invented.

Outbound transits have `fillDeadline = 0`, `escrow = address(0)` and retain gross
Spoke Cap / net In-flight Value until an authenticated report confirms arrival.
Core's expiry, refund and non-arrival-proof paths explicitly reject deadline-free
transits. Never substitute a large timestamp sentinel or Across escrow for this.
Across still uses its existing deadline, escrow, fee rule and refund paths.

On return, the connector supplies `(originChainId, transitId, kind, grossAmount,
maxFee, feeExecuted)` to Core after minting. Core holds receipts that precede a
source report outside Idle/NAV. It matches the report's listed amount exactly to
`grossAmount - maxFee` and checks kind. The capped minimum is classified by the
source report; the unused fee `maxFee - feeExecuted` enters **principal**, including
for a reported Income transfer. Listed-kind mismatch or minimum mismatch fails
closed atomically. Repeated business ids revert even with a different Circle nonce.
If Core credit fails, the mint, Circle nonce and wrapper receipt all roll back.

Solana unlisted arrivals cannot use the old timed recovery entry. An authenticated
listing is required: report silence cannot prove that a CCTP source claim was retired.
Closed-Fund receipts retain DEC-167 behavior: tokens are excess, no shares reopen.
The connector records a consumed receipt; existing excess handling is still used.

## Required coordination with T2a / Solana sender

1. Factory/Mandate/codec/pricing are **not modified** by this patch. Commit all
   `CctpRoute` fields, bridge component addresses, configured target wiring and fee
   bound in the new-Fund Mandate/hash. Validate the official full-width Solana USDC
   mint, program, custody PDA, ATA and receive authority at creation. The old
   `SpokeConfig` EVM token fields are not sufficient; the unit fixture placeholders
   are not valid production Solana identities.
2. Precompute Core's CREATE3 address; deploy its adapter and connector against that
   address before Core. Keep the connector as the Solana burn `destinationCaller`.
   Feed those instances into `CoreVaultCctp`'s constructor. Link the additional
   `CoreVaultCctpLogic` library and include this version in the new factory CodeStore
   path only. Legacy factory does **not** deploy this Core automatically.
3. New reports must list return amounts at the capped minimum, retain pending CCTP
   ids indefinitely and preserve Principal/Income classification. Deliver through
   `onReportAccepted` so receipt-first fee-surplus settlement runs. Wormhole finalized
   report verification/codec v6 and full-width token valuation remain T2a-owned.
4. Outbound Solana receive must use the same hook encoding and book actual mint
   delta. Report arrival at least at the capped minimum and reflect the unused fee
   in principal. Current Hub confirmations retire the minimum; the spoke report
   must include actual source custody so surplus is counted once.
5. Use `sendToSolana` for CCTP; existing `sendToSpoke` enforces an Across-style
   deadline and must not dispatch to this deadline-free adapter without explicit
   new-version routing integration. Report/receipt acknowledgement and persistent
   Solana record retirement belong to the other agents; no timed pruning is added.

Runtime measured with repository optimizer settings: **24,405 bytes**, leaving only
171 bytes below EIP-170. Creation bytecode is checked against EIP-3860 (constructor
argument size must also be included by factory integration). T2a must recheck sizes
after its factory/report integration; do not silently raise code-size limits.

`TODO(decision)`: if source report evidence conflicts with an already received
receipt, no impairment, forced credit or governance resolution was authorized.
Safest implementation blocks settlement and preserves backing. The legacy first
listing is immutable, so a conflicting first listing may require a separately
authorized recovery/version change rather than an ordinary replacement report.
Long-lived claim unavailability likewise has no write-off
or expiry operation under DEC-191.

## Reproducible local verification

Unit tests:

```sh
forge test --match-path 'test/unit/cctp/*.t.sol' -vv
forge test --match-path 'test/unit/across/*.t.sol' -vv
forge test --match-path 'test/unit/core/CoreVaultTransit.t.sol' -vv
```

Fork tests (load RPC variables without printing them; no broadcast):

```sh
source /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
export CCTP_ARBITRUM_FORK_BLOCK=500000000
forge test --match-path 'test/fork/cctp/*.t.sol' -vv
forge test --match-path 'test/fork/core/CoreVaultAcross.t.sol' -vv
```

The CCTP suite impersonates the deployed transmitter's attester manager **on the
local fork only**, enables a synthetic local attester and signs generated messages.
It executes real deployed Circle receive/mint and burn paths. It is not a real
Circle attestation or evidence of cross-chain mainnet execution. The opt-in Core
accounting composition is separately tested against a deterministic local protocol
double, including three-chain coexistence and 512-run fee/order fuzzing.
