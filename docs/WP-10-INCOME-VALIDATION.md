# WP-10: Income through the Hub dollar index

Validated on October 2, 2026, after merging `origin/main` at `1db9a9d`.

## Design

- Recognition runs before balance changes through `onValuation`, and on accepted spoke reports. `afterMint` excludes
  pre-mint interval income; `afterBurn` preserves the burned shares' income and pays already-converted dollars on a full exit.
- Source 0 is the Hub; source `1 + i` is Mandate spoke `i`. Each source has token interval indices and a dollar index.
  Independent source intervals preserve the actual conversion rate of each asynchronous collection.
- Performance fees accrue in token units at recognition. Collection divides the sale between holders and fees at the same
  rate, pays USDC to the Protocol Recipient and ManagerFeeVault, and reserves holders' USDC outside Share Assets.
- An Income Withdrawal request collects Hub positions and broadcasts a COLLECT order when accepted reports show spoke
  income. Requests piggy-back on pending rounds; expired orders can be published again. Anyone settles only to the holder.
- Spokes collect every position, sell non-base income through the Mandate swap adapter, bridge as Income, and report token
  sales and the transit identifier. The Hub freezes the recognized claims and fee units when the authenticated sale
  result is first read, before later recognition or balance changes can mix intervals. Holder claims are captured before
  each subsequent balance change, including full exits; delayed dollars finalize only that sale's claims. The Hub converts
  only after the entire authenticated arrival amount is credited. Partial or
  front-run dust arrivals cannot close a collection or change its conversion rate.
- Dust sales wait in the collected bucket until a bridge can deliver positive value. Refunded sends retain their sale
  record and are sent again. Refund recognition reserves their dollars independently of the report window. Reports carry
  at most eight results; resends are included immediately, and anyone can call `refreshIncomeResults(uint64[])` with up to
  eight retained result ids, then publish a report to recover an evicted result. Result ids are discoverable from events.
  The result also authenticates its expected arrival amount after in-flight retention expires.
- Unlisted recovery holds dollars outside Idle while recognized Income or a collection remains unresolved. Authenticated
  Income metadata reconciles the recovery exactly once; an authenticated Principal listing releases it to Idle. An Across
  message's unauthenticated kind never establishes Income ownership.
- Failed holder transfers emit `IncomeTransferOwed`, not `IncomeWithdrawn`, and remain claimable through `claimOwedFees`.
- Conversion happens at collection; removed APIs include in-kind withdrawal, manager income swaps and forwarding.

## Decisions

- DEC-014: attribution stays with holders present at recognition, not collection.
- DEC-045: full exits pay converted income and preserve unconverted interval claims.
- DEC-112: protocol performance-fee slice is clamped to 500–5,000 bps; failed registry reads use 5,000 bps.
- DEC-117: income recognition, fee reservation, and withdrawal independent of fund state.
- DEC-122: Income Withdrawal requests collect Hub and spoke income; pending requests share collections.
- DEC-124: collection converts income and fees; withdrawals pay USDC without flow or Payout Fees.
- DEC-128: fees pay the Protocol Recipient and ManagerFeeVault at collection.
- DEC-138: recognition at every mint, burn and accepted report.
- DEC-152: token-based attribution with conversion at each collection's rate.
- DEC-161: token interval indices, stored conversion rates, and the Hub dollar index; no average-price payment.
- DEC-166: sale and bridge costs lower the collection rate for all beneficiaries proportionally; no request minimum.
- DEC-172: Hub-position income sells to USDC through the swap adapter in the same collection workflow.
- DEC-175: MVP callers pay gas and Wormhole message fees; the fund pays sale and bridge costs.
- DEC-178 item 5: manager conversion at arbitrary times is superseded by collection-time conversion.

## Sizes

Fresh main baseline and final deployed runtime sizes, in bytes. Limit: 24,576. Unchanged contracts and linked libraries
also pass the size test. No production margin is below 1,000 bytes.

| Contract/library | Main before | After | Margin |
| --- | ---: | ---: | ---: |
| CoreVault | 20,996 | 21,914 | 2,662 |
| CoreVaultIncomeLogic | 5,929 | 12,101 | 12,475 |
| CoreVaultIncomeCollectionLogic | New | 16,530 | 8,046 |
| CoreVaultLogic | 13,739 | 13,684 | 10,892 |
| CoreVaultTransitLogic | 14,227 | 14,744 | 9,832 |
| CoreVaultPayoutLogic | 9,098 | 9,095 | 15,481 |
| SpokeVault | 22,304 | 22,748 | 1,828 |
| SpokeIncomeLib | 698 | 11,577 | 12,999 |
| SpokeCrossChainLib | 11,904 | 12,112 | 12,464 |
| SpokeUnwindLib | 10,985 | 10,985 | 13,591 |
| FundFactory | 18,347 | 18,347 | 6,229 |
| ManagerFeeVault | 1,077 | 1,077 | 23,499 |

## Validation

- `forge build --sizes`: passes, unchanged optimizer configuration.
- `forge fmt --check`: passes.
- `forge test --match-path test/size/ContractSizes.t.sol -vv`: 3/3, all 22 production contracts and linked libraries fit.
- `forge test --no-match-path "test/{fork/**,review/**/*Fork*}"`: 1,238 tests, 170 suites, no failures or skips.
- `forge test --match-path "test/{fork/**,review/**/*Fork*}" -j 4`: 218 tests, 51 suites, no failures or skips.
- Doc 10 worked examples run through the Core Vault, net of the mandatory 10% performance fee: 119.70 then 170.10 USDC
  for the two-collection example, and 50.40/50.40/25.20 USDC for the mid-interval entrant example, within rounding bounds.
- Vault/reference-model parity runs 512 fuzz cases across entry and distinct collection prices.
- Collection executor tests prove sale limits, custody rollback, dust accumulation, refunds, eight-result reporting and
  caller-funded Wormhole fees. Fork tests sell WETH through live V3 adapters on both chains; Robinhood executes a signed
  COLLECT order against the real Wormhole Core and sends through Across.
- No new fork file calls `_createForks()`; the existing CI scenario-suite list remains sufficient.

## Plan deviations and integration boundaries

- One source index per spoke, rather than one aggregate spoke index, avoids mixing independently timed conversions.
- Hub `collectIncomeAll(uint16)` is Core Vault-only; permissionless collection is exposed by `requestIncomeWithdrawal` so
  recognition always precedes sale. The result is returned rather than using a reentrant collection callback.
- The owned collection library split follows the plan's allowed deployment/size-list extension.
- Minimal constructor/USDC-ledger updates in CoreVaultBase, Gross Assets accounting in CoreVaultLogic, and rejection of
  manual Income sends in SpokeVault are necessary integration changes outside the narrow income files. Payout and unwind
  production files are unchanged. Existing payout tests only migrate the removed income APIs.
- DEC-145 entry-time eligibility, native Operating Cash and gas refunds remain deferred as instructed.
- Closed-state withdrawal is tested by setting the lifecycle state in an isolated test: production closure is WP-13.
- No local-e2e harness process was started; harness scenario porting is WP-15.

## Spec divergences and residual limitations

- DEC-175 and the October 2 ruling explicitly permit caller-paid gas/Wormhole fees in the MVP; reimbursement is deferred.
- Round-1 findings are corrected: delayed conversion freezes ownership, refund accounting survives report eviction, and
  recovered Income reconciles without becoming principal or leaving a permanent settlement blocker. The three original
  regression tests fail on the reviewed implementation (including the 39.749999 USDC entrant allocation) and pass after
  the fixes. Additional tests cover partial sales, full exits, two delayed collections filled out of order, metadata-only
  arrival authentication, and permissionless republishing of evicted results.
- Report serialization remains bounded at eight results, but retained financial metadata is no longer evicted. After a
  multi-day outage the keeper must republish missing result ids in bounded batches. This extends the plan's last-eight
  behavior with a recovery path rather than accepting loss of financial metadata.
- Collection data is trusted only from this fund's authenticated, Mandate-matched Spoke Vault. Arbitrarily malformed ABI
  blobs are not a supported report input; the canonical executor produces bounded, well-formed collection results.

Independent PR review and merge remain the orchestrator's responsibility.

## PR #18 round-1 fix validation

The full green bar passes on October 2, 2026: build with sizes, formatting, 3 size tests, 1,238 non-fork tests in 170
suites, and 218 fork tests in 51 suites. No tests fail or skip. The complete fork suite uses the handoff archive RPC
environment and fixed pins. No shared fork fixture or new fork file is added; CI shard routing is unchanged.

| Changed runtime | Reviewed PR | Round-1 fix | Margin to 24,576 |
| --- | ---: | ---: | ---: |
| CoreVault | 21,914 | 21,914 | 2,662 |
| SpokeVault | 22,355 | 22,748 | 1,828 |
| CoreVaultIncomeCollectionLogic | 13,627 | 16,530 | 8,046 |
| CoreVaultIncomeLogic | 10,517 | 12,101 | 12,475 |
| CoreVaultTransitLogic | 14,225 | 14,744 | 9,832 |
| SpokeIncomeLib | 8,709 | 11,577 | 12,999 |
| SpokeCrossChainLib | 11,904 | 12,112 | 12,464 |

Every production contract and linked library remains within the limit; none has less than 1,000 bytes of margin.
The fixes retain the compiler settings. The Core Vault's runtime is unchanged; the Spoke Vault adds only the thin
permissionless refresh entry, with bookkeeping and serialization in linked libraries.

No finding is declined. No separate low finding is listed in the review; cheap adjacent fixes validate result-array
lengths before marking results seen, and recheck repeated results for closure instead of returning early. The plan
deviation is bounded report refresh with permanently retained sale metadata rather than a last-eight-only recovery
window. DEC-145 and the other handoff deferrals are unchanged; no new spec divergence is adopted.
