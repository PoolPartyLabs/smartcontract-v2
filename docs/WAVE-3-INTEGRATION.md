# Wave-3 integration: WP-09 and WP-10

Validated October 2, 2026 on `chore/pp-sc-chore-wave3-integration`.
This is an integration base for WP-12 and WP-13, not a release or a merge into main. No PR is opened.

## Integrated sources

- Main: `d187b51d5e526468c0303869d7c3eef2b3769f5a`, including reviewed harness groundwork PR #16.
- WP-09 / PR #19: `bf3078f09915e3ba754aeb96a4ad2e50dd49fe60`.
- WP-10 / PR #18: `8fd891bfa9d9b0efdb5f33534d276dc40c2e41de`.
- All integrations use merge commits, never rebases. The source tips were fetched again after validation and
  were already ancestors of this branch. The source PRs remain under review; later changes must be merged again.

## Merge resolutions

WP-09 merged without conflicts. WP-10 had six conflicted test/mock files:

- `test/mocks/core/MockHubSpokeVault.sol`: keep proportional unwind and dollar collection behavior/documentation.
- `test/security/invariants/FundSystemHandler.sol`: keep inline Instant Payout receipts and measure converted
  income paid from the change in held USDC, including the income-taken ghost counter.
- `test/unit/core/CoreVaultAdversarial.t.sol`: use the dollar-only no-in-kind-transfer regression instead of obsolete
  token withdrawals, retaining the payout regressions.
- `test/unit/core/CoreVaultIncome.t.sol`: preserve interval recognition and dollar collection tests rather than
  the superseded in-kind index cases.
- `test/unit/core/CoreVaultIncomeHooks.t.sol`: combine dollar collection setup with the inline Instant receipt.
- `test/unit/core/CoreVaultPayout.t.sol`: retain payout/loss/retry/freshness cases and USDC income/owed-transfer
  expectations, executing Instant Payout inside its request.

Production files merged automatically. Both ownership domains, interfaces, valuation hooks, shared fixtures,
the new income collection library and size-test entry remain present. Main's harness groundwork merged cleanly.
Each merge message records its resolutions.

## Extra commits

- `f723570`: remove three obsolete second claims from income burn tests (DEC-120, DEC-138).
- `27bc699`: inspect executable names during shutdown without reading archive RPC command arguments (DEC-187).
- `147bc89`: merge the newly reviewed main harness groundwork; no feature logic changes.
- `2f982b2`: regenerate combined vault/adapter ABIs, including linked-library events.
- `5223afe`: port the scenario and API to loss bounds, inline Instant Payout, proportional Aave/V4 exits,
  post-unwind Market Costs, report freshness, all-chain collection and USDC Income Withdrawal
  (DEC-105, DEC-118, DEC-120, DEC-137, DEC-140, DEC-141, DEC-160, DEC-161, DEC-172).
- `a32604e`: read dollar collection events in the fee report instead of removed in-kind forwarding events.
- This report and the two deliberately staged harness reports are the final evidence commit.
- A documentation-only follow-up trims the generated Markdown reports' extra EOF blank lines.

## Runtime sizes

Limit: 24,576 bytes. Main baseline is `1db9a9d`; subsequent harness-only main changes do not alter production sizes.
Compiler settings remain Solidity 0.8.28, optimizer 800, no via-IR. No pure-move size commit was necessary.

| Contract or linked library | Bytes | Margin |
| --- | ---: | ---: |
| CoreVault | 22,240 | 2,336 |
| SpokeVault | 23,149 | 1,427 |
| CoreVaultLogic | 13,684 | 10,892 |
| CoreVaultTransitLogic | 14,227 | 10,349 |
| CoreVaultIncomeLogic | 10,517 | 14,059 |
| CoreVaultIncomeCollectionLogic | 13,627 | 10,949 |
| CoreVaultPayoutLogic | 11,085 | 13,491 |
| SpokeCrossChainLib | 11,904 | 12,672 |
| SpokeUnwindLib | 11,530 | 13,046 |
| SpokeIncomeLib | 8,709 | 15,867 |
| FundFactory | 18,347 | 6,229 |
| AaveV3Adapter | 9,893 | 14,683 |
| AcrossBridgeAdapter | 6,713 | 17,863 |
| UniswapV3SwapAdapter | 10,586 | 13,990 |
| UniswapV4Adapter | 14,369 | 10,207 |
| ManagerFeeVault | 1,077 | 23,499 |
| ManagerRegistry | 1,603 | 22,973 |
| ShareToken | 1,822 | 22,754 |
| TransitEscrow | 894 | 23,682 |
| Create3Deployer | 1,342 | 23,234 |
| ChainlinkPriceSource | 1,709 | 22,867 |
| ValueReportReceiver | 8,080 | 16,496 |

Core Vault grows from 20,996 bytes (+1,244); Spoke Vault grows from 22,304 bytes (+845).
All 22 deployable production contracts/libraries fit; none has a margin below 1,000 bytes.
Spoke Vault remains the tightest and WP-12 should budget its 1,427-byte reserve carefully.

## Green bar

- `forge build --sizes`: passes.
- `forge fmt --check`: passes.
- `forge test --match-path test/size/ContractSizes.t.sol -vv`: 3/3 tests, one suite.
- `forge test --no-match-path "test/{fork/**,review/**/*Fork*}"`: 1,192/1,192 tests, 169 suites, no skips.
- `forge test --match-path "test/{fork/**,review/**/*Fork*}" -j 4`: 218/218 tests, 52 suites, no skips.
- CI `SCENARIO_SUITES` matches exactly all 14 test files calling `_createForks()`; both branches' fork coverage remains.
- `pnpm run check:urls`: eight synthetic URL cases pass across shell stdout/disk and TypeScript logger levels.
- Shell syntax checks and `git diff --check`: pass.
- Optional `pnpm exec tsc --noEmit` remains blocked by the existing absence of Node type definitions and resulting
  implicit-any errors. No new non-Node-type errors remain; no unrelated dependency change is introduced.

Archive environment sourced in the same shell before every fork invocation and harness start. Pins: Arbitrum
511007613, Robinhood 78293056. Private ports: 28645 / 28646 / 28787. No credentials are recorded.

## Harness

- `pnpm run up --warm-up none`: passes; real linked factory and fund deployment on both forks.
- `pnpm scenario --keeper inprocess`: passes, 46 steps / 294 assertions, repeated on fresh funds.
  Hub and spoke income sells through the swap adapters; COLLECT executes and bridges income home.
  Both Aave and V4 deliver proportional Hub unwind principal; Market Costs and a partial request are checked.
  Two Principal fills and the Income fill use real `SpokePool.fillRelay`; no simulated fill, no keeper errors.
- `pnpm api:probe`: passes, 19 concepts / 19 assertions, including stale-report burn rejection, exact fresh
  Standard Payout quote, swap loss rejection, signed routes, bridge quotes, indexer events and Share Price history.
- `pnpm down`: passes; both tracked anvil processes stopped, no keeper/API process left running.
  Ports 28645, 28646 and 28787 were checked and have no listener.
- Evidence: `local-e2e/reports/2026-10-02T20-16-10Z-scenario.{md,json}` and
  `local-e2e/reports/2026-10-02T20-15-34Z-api-probe.{md,json}`.
  The scenario report records 1.184152 USDC of collections and 0.236829 USDC of performance fees.

## Boundaries, deviations and inherited divergences

- WP-12 UNWIND/CLOSE execution and cross-chain payout settlement remain stubs; partial Hub-only requests are
  expected until WP-12. WP-13 finalized closure, frozen exits and late-value handling are not implemented here.
- No new production deviation or spec divergence is introduced by integration. The harness port removes
  superseded in-kind income and registry-order unwind assumptions, including PR #12 carry-over L-1.
- Preserve WP-09's typed unwind ABI, D-17 Market Cost add-back, D-18 position-price manipulation residual,
  D-19 mid-value absorption basis and guarded Hub report fallback. See `docs/WP-09-HUB-UNWIND.md`.
- Preserve WP-10's per-spoke source indices and Core Vault-only Hub collection, eight-result retention bound,
  and the inherited outage/recovery limitation that can reclassify Income as Principal before collection closure.
  See `docs/WP-10-INCOME-VALIDATION.md`; WP-12/WP-13 must not silently discard these rules.
- DEC-145 entry-time eligibility, Operating Cash spending, gas refunds and DEC-185 remain deferred.
  DEC-175 explicitly permits caller-paid gas/Wormhole fees in the MVP; DEC-187 manager gas stays self-funded.
- Shared `lib/` and `.env` are symlinks and were never staged. Apparent deleted gitlinks in working-tree status
  reflect the required symlink, not committed dependency changes.
