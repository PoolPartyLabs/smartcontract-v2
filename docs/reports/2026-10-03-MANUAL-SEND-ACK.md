# Manual send-home acknowledgement regression (2026-10-03)

This fix is stacked on PR #28, `fix/pp-sc-fix-conformance-blockers`, baseline `ee1ff56`.

## Summary and design

- DEC-066/068/093: the authenticated Hub acknowledgement resolves any locally known send-home transit, not only
  one associated with an unwind request. It immediately removes the shared In-flight Value slot. Repeated
  acknowledgements do nothing, and unknown or inconsistent outcomes revert.
- DEC-080/104: the Hub requires full credit of the listed amount for both Principal and Income; publishing and
  delivering acknowledgements never credit a Hub bucket. Refund recognition retains its exactly-once ledger credit.
- DEC-139/151: unwind/CLOSE retry reservation and result retirement run only when the transit belongs to that book.
  Collection result ownership and conversion are unchanged.
- Report v5 appends `refundedTransits`, a chronological ring of the last 256 locally recognized refunds. An accepted
  report supplies explicit refund proof for manual or collection sends without inventing unwind results. The ring
  is informational, not a valuation bucket. Silence is not proof. A refund evicted before delivery loses this generic
  acknowledgement proof, but its slot was already released locally at recognition; unwind proof remains unchanged.
- New refund storage is appended after existing Spoke Vault state. Off-chain v4 decoders must rebuild against v5.
  The checked-in report ABIs and the Hub acknowledgement entry are updated without refreshing unrelated stale ABIs.

## Sizes

Fresh `forge build --sizes`, optimizer runs 800, no via-IR. Runtime bytes; margin to 24,576 bytes.

| Contract/library | Before | Before margin | After | After margin |
|---|---:|---:|---:|---:|
| CoreVault | 22,358 | 2,218 | 22,358 | 2,218 |
| SpokeVault | 22,905 | 1,671 | 22,907 | 1,669 |
| CoreVaultPayoutLogic | 22,258 | 2,318 | 22,547 | 2,029 |
| SpokeCrossChainLib | 16,429 | 8,147 | 16,790 | 7,786 |
| SpokeUnwindLib | 21,229 | 3,347 | 21,594 | 2,982 |
| ValueReportReceiver | 8,080 | 16,496 | 8,309 | 16,267 |
| CoreVaultClosureLogic | 16,749 | 7,827 | 17,052 | 7,524 |
| CoreVaultTransitLogic | 15,788 | 8,788 | 16,005 | 8,571 |
| CoreVaultIncomeLogic | 12,101 | 12,475 | 12,236 | 12,340 |
| CoreVaultIncomeCollectionLogic | 17,645 | 6,931 | 17,689 | 6,887 |
| CoreVaultLogic | 13,684 | 10,892 | 13,612 | 10,964 |

The report layout changes generated codec sizes even in unchanged consumers. Every production contract and linked
library passes the size inventory test; the smallest margin is 1,669 bytes. No margin is below 1,000 bytes.

## Validation

- `forge fmt --check`: passes.
- `forge build --sizes`: passes; existing compiler/lint warnings remain.
- `forge test --match-path test/size/ContractSizes.t.sol -vv`: 3/3, one suite.
- `forge test --no-match-path "test/{fork/**,review/**/*Fork*}"`: 1,543/1,543, 190 suites.
- `forge test --match-path "test/{fork/**,review/**/*Fork*}" -j 4`: 227/227, 57 suites; archive RPC environment sourced
  in the same command, with fixed pins from the handoff script. No RPC credentials are recorded here.
- Targeted unit files: 46/46 across two suites, including 11 new regressions and inherited settlement/closure coverage.
- New two-fork suite: 4/4. Live Across deposits and Wormhole guardian-quorum verification, with simulated bridge
  delivery/refund custody as in the existing fork suite. Delivery clocks derive from source message timestamps +
  one minute, never from the destination fork's independent pinned timestamp (PR #8).
- CI scenario fitness: all 18 files calling `_createForks()` match `SCENARIO_SUITES` exactly.

Coverage includes 24 individually acknowledged manual Principal sends over time; 24 acknowledged collection Income
sends; filling all 64 shared send slots and immediately reusing an acknowledged slot; mixed manual/unwind/CLOSE
sends; manual refund, repeat acknowledgement and repeat refund rejection; unknown/premature outcomes; bounded refund
history; full versus partial Hub credit; and unchanged collection conversion ownership on two forks.

## Deviations and divergences

- The task's sixteen-slot description is historical: PR #28's base has 64 shared send-home slots, while unwind result
  history is still 16. Both bounds are preserved; tests cover more than 16 sends and actual 64-slot exhaustion.
- The base rejects manual Income sends (`IncomeSentOnlyByCollection`), consistent with collection-driven Income
  Withdrawal. That permission is preserved and tested; Income acknowledgements are exercised through COLLECT.
- Report v5 is needed to authenticate manual-refund proof independently of unwind results. This is an engineering
  extension of DEC-066/093, not a change to payout, closure, bridge terms, fees or income attribution semantics.
- No new specification divergence was found. No alpha deployment or long-running harness process was started.
