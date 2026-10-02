# WP-15a verification (2026-10-02)

## Scope and design

This ports the existing scenario to contract main `1db9a9d`; all changes are in
`local-e2e/`. It does not implement the later WP-15b income, proportional unwind,
spoke order execution, closure finalization, or closed-fund exit phases.

- Manager swaps use the fund's Mandate swap adapters (DEC-136, DEC-142,
  DEC-143, DEC-153), with direct and signed-route coverage.
- The API probe simulates `swap(fundAdapter, USDC, WETH, 1000e6, 1, "0x")`
  and requires `InsufficientOutput`. A successful simulation fails the probe.
- Zero API slippage retains the full signed quote/oracle minimum. The documented
  `maxLossBps = 0` sentinel disables only the additional pool-mid bound (DEC-142).
- Sends home use the three-argument `sendToHub`; the bridge adapter fixes its
  terms (DEC-158, DEC-162, DEC-176).
- Arrivals are linked to origin deposits through the actual `FilledRelay`,
  including relay-field and message checks, rather than transit ids alone
  (DEC-090, OQ-09).
- Exported vault ABIs include linked-library events and errors (DEC-131).
- Operating Cash is credited only below its floor; the default floor and top-up
  are zero (DEC-096, DEC-100; ruling 2026-10-02, DEC-187).
- The interim unwind asserts Aave-first only when Aave paid. If Aave was exhausted,
  it instead checks removal from the registry and reduced V4 liquidity (DEC-137).
- The keeper calls `executeOrder` and records `OrderKindNotSupported` as not yet
  supported, without retries or errors; a restarted keeper rescans old orders
  (DEC-120, DEC-139). This is stub coverage, not completed spoke unwinds.
- Fork output is redacted before reaching disk. Shutdown checks executable names,
  never process command lines containing archive credentials.

## Two-fork harness

Archive RPC helper sourced in each fork command; no credentials were persisted.
Private ports: Arbitrum `48545`, Robinhood `48546`, API `48787`.
Fork pins: Arbitrum `511007613`, Robinhood `78293056`.
Existing `node_modules` was present, so installation was not needed.

| Command | Result |
|---|---|
| `pnpm run up --warm-up none` | PASS |
| `pnpm scenario --keeper inprocess` | PASS: 47 steps, 302 assertions, 50 transactions |
| `pnpm api:probe` | PASS: 18 concepts; strict swap reverted `InsufficientOutput` |
| `pnpm down` | PASS; neither fork nor API port remains listening |

Both keepers stopped with zero errors. The scenario filled two deposits through
the live `SpokePool.fillRelay`, with no simulated fills, and linked each via
`FilledRelay`.

Run reports (local, gitignored; paths relative to the repository):

- `local-e2e/reports/2026-10-02T19-32-06Z-scenario.md`
- `local-e2e/reports/2026-10-02T19-32-06Z-scenario.json`
- `local-e2e/reports/2026-10-02T19-32-59Z-api-probe.md`
- `local-e2e/reports/2026-10-02T19-32-59Z-api-probe.json`

The reports identify tested code commit `d7b7d26f0e06`; subsequent changes only
record this verification evidence.

## Foundry green bar

| Command | Result |
|---|---|
| `forge build --sizes` | PASS |
| `forge fmt --check` | PASS |
| `forge test --match-path test/size/ContractSizes.t.sol -vv` | 1 suite, 3 passed |
| `forge test --no-match-path "test/{fork/**,review/**/*Fork*}"` | 166 suites, 1,173 passed |
| `forge test --match-path "test/{fork/**,review/**/*Fork*}" -j 4` | 51 suites, 216 passed |

The full fork suite was run even though no Solidity or shared fork fixture changed.
The 3 size tests are also included in the 1,173 non-fork tests, not additional tests.
No failed or skipped tests; no new fork test file or CI suite registration needed.

## Runtime sizes and margins

No Solidity source or compiler setting changed, so before and after sizes are
identical. The size suite checks every production contract and linked library
against the 24,576-byte limit (DEC-131). No margin is below 1,000 bytes.

| Contract or linked library | Before / after bytes | Margin bytes |
|---|---:|---:|
| AaveV3Adapter | 10,158 / 10,158 | 14,418 |
| AcrossBridgeAdapter | 6,713 / 6,713 | 17,863 |
| UniswapV3SwapAdapter | 10,586 / 10,586 | 13,990 |
| UniswapV4Adapter | 18,079 / 18,079 | 6,497 |
| CoreVault | 20,996 / 20,996 | 3,580 |
| ManagerFeeVault | 1,077 / 1,077 | 23,499 |
| ManagerRegistry | 1,603 / 1,603 | 22,973 |
| ShareToken | 1,822 / 1,822 | 22,754 |
| TransitEscrow | 894 / 894 | 23,682 |
| Create3Deployer | 1,342 / 1,342 | 23,234 |
| FundFactory | 18,347 / 18,347 | 6,229 |
| ChainlinkPriceSource | 1,709 / 1,709 | 22,867 |
| ValueReportReceiver | 8,080 / 8,080 | 16,496 |
| SpokeVault | 22,304 / 22,304 | 2,272 |
| CoreVaultLogic | 13,739 / 13,739 | 10,837 |
| CoreVaultTransitLogic | 14,227 / 14,227 | 10,349 |
| CoreVaultIncomeLogic | 5,929 / 5,929 | 18,647 |
| CoreVaultPayoutLogic | 9,098 / 9,098 | 15,478 |
| SpokeCrossChainLib | 11,904 / 11,904 | 12,672 |
| SpokeUnwindLib | 10,985 / 10,985 | 13,591 |
| SpokeIncomeLib | 698 / 698 | 23,878 |

## Deviations and spec divergences

- WP-15a is deliberately the current-main port, not the complete original WP-15
  flow. Later WP-15b coverage waits for WP-09/10/12/13 as directed by the handoff.
- Archive endpoints and fixed pins from the helper supersede the original plan's
  rolling public-fork pins.
- Zero-slippage sentinel semantics are documented rather than changing the fixed
  contract ABI; the signed minimum remains enforced.
- Unused, untracked duplicate scenario scaffolding from the interrupted attempt
  was removed. Existing `lib/` and `.env` symlinks were left untouched and unstaged.
- No new spec divergence found. Existing interim unwind ordering, unsupported
  order kinds, and Operating Cash deferral remain explicit limitations.
