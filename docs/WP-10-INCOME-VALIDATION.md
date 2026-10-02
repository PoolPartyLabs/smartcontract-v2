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
  sales and the transit identifier. The Hub converts only after the entire report-listed arrival is credited. Partial or
  front-run dust arrivals cannot close a collection or change its conversion rate.
- Dust sales wait in the collected bucket until a bridge can deliver positive value. Refunded sends retain their sale
  record and are sent again. Reports carry the last eight results.
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
| CoreVaultIncomeLogic | 5,929 | 10,517 | 14,059 |
| CoreVaultIncomeCollectionLogic | New | 13,627 | 10,949 |
| CoreVaultLogic | 13,739 | 13,684 | 10,892 |
| CoreVaultTransitLogic | 14,227 | 14,225 | 10,351 |
| CoreVaultPayoutLogic | 9,098 | 9,098 | 15,478 |
| SpokeVault | 22,304 | 22,355 | 2,221 |
| SpokeIncomeLib | 698 | 8,709 | 15,867 |
| SpokeCrossChainLib | 11,904 | 11,904 | 12,672 |
| SpokeUnwindLib | 10,985 | 10,985 | 13,591 |
| FundFactory | 18,347 | 18,347 | 6,229 |
| ManagerFeeVault | 1,077 | 1,077 | 23,499 |

## Validation

- `forge build --sizes`: passes, unchanged optimizer configuration.
- `forge fmt --check`: passes.
- `forge test --match-path test/size/ContractSizes.t.sol -vv`: 3/3, all 22 production contracts and linked libraries fit.
- `forge test --no-match-path "test/{fork/**,review/**/*Fork*}"`: 1,192 tests, 168 suites, no failures or skips.
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
- Existing unlisted-arrival recovery can reclassify Income as Principal after a multi-day report outage. If a collection's
  send is recovered this way before its result is accepted, that result cannot receive the income credit needed to close.
  The existing transit recovery path is not changed by WP-10; lifecycle/transit integration must address this limitation.
- Results outside the last-eight report window cannot be rediscovered after an extended report outage; refund resends are
  also bounded by that window. This is the plan's explicit retention bound, not an unbounded catch-up guarantee.
- Collection data is trusted only from this fund's authenticated, Mandate-matched Spoke Vault. Arbitrarily malformed ABI
  blobs are not a supported report input; the canonical executor produces bounded, well-formed collection results.

Independent PR review and merge remain the orchestrator's responsibility.
