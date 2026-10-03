# PR #29 main integration and off-chain v5 proof

Validated on October 3, 2026, implementation commit `88b955080cce5c52cf166805d4660846c2b09102`.
Main `e90e6a6` (including PR #28 late-dust commit `72cb46d`) was integrated without conflicts by merge commit
`b223487`. No pushed history was rewritten. Only this worktree was modified; shared `lib/` and `.env` were not staged.

## Summary and DECs

- DEC-066: a manual Principal send is acknowledged, becomes Arrived, and immediately leaves the shared send slots.
- DEC-093: harness and alpha runtimes decode finalized report v5 payloads and reject obsolete versions.
- DEC-120 / DEC-139: live Wormhole contracts verify locally signed report and acknowledgement VAAs in both flows.
- DEC-159: regenerated ABIs keep harness, API and alpha report consumers synchronized with the merged contracts.
- DEC-167: full scenario and separate alpha closure smoke remain green after the conformance late-dust merge.

The common decoder derives its tuple from the exported ABI and requires the final `refundedTransits` field. Unit
coverage round-trips a nonempty authenticated manual-refund proof and Principal transit, rejects v4, and rejects
malformed v5. ABI export validates both `buildReport` and `latestReport` tuples. The API exposes report version 5;
the alpha smoke consumers assert it. Only Core Vault and Spoke Vault generated ABIs changed on regeneration; the
ValueReportReceiver ABI already contained the v5 field.

## Off-chain evidence

Archive RPC helper sourced in each shell command before forks or harness starts. Fixed fork pins:
Arbitrum **511007613**, Robinhood **78293056**. No upstream URLs or keys are recorded.

- `pnpm scenario --keeper inprocess`: **56 steps / 323 assertions / 90 scenario transactions**, 94 seconds.
  Keeper: **6 real Across fills, 0 simulated fills, 17 report deliveries, 10 orders, 0 errors**. The historical
  scenario summary counts its two explicit directional fills; keeper statistics include four order-driven fills.
  Both directions link arrivals to deposits through `FilledRelay`.
- Conservation: **0 USDC base-unit residual**, **0 unexplained amount**, **6.577617 USDC bridge costs**.
- Scenario step 28 proves the acknowledged manual return leaves `inFlightTransitIds` and `buildReport.inFlightToHub`.
- `pnpm api:probe`: **31 concepts**, including report version 5; real loopback API and in-process keeper.
- `script/rehearse-alpha.sh`: capital/payout/income, runtime and second-fund closure smokes pass. Amounts: **5 USDC
  seed, 5 USDC deposit, 5 USDC spoke send, 1 USDC manual return, 1 USDC payout, 1 USDC Aave allocation**, Spoke Cap
  **100 USDC**, minimum first deposit **2 USDC**. The manual return delivers **0.969200 USDC**, reaches Arrived,
  leaves both the shared slot and durable retry queue. API reports decode v5. The runtime passes **5 API checks**.
- Alpha COLLECT retains unbridgeable dust rather than losing it; the income withdrawal settles. A second fund closes
  and exits at its frozen split. `pr29-alpha-smoke.jsonl` records transaction hashes and the slot-freed assertion.
- `pnpm test:harness`: **9/9**; `pnpm test:alpha`: **13/13** (the two codec tests run in both commands).
- TypeScript typecheck passes; URL redaction **42 cases**, lifecycle/layout **24 assertions**, verification scripts
  **2/2 tests**; shell syntax and `git diff --check` pass.

Private ports: harness **19645/19646**, API probe **19687**; alpha **19745/19746**, API **19787**. Cleanup traps stop
forks, and runtime children stop in `finally`. All six ports were checked clear. No deployment to mainnet occurred;
live Across/Wormhole contracts run on pinned forks with local relayer and guardian simulation. External guardian
service availability and real mainnet relayer behavior are not established by this rehearsal.

## Foundry green bar

- `forge build --sizes`: pass; existing compiler/lint warnings remain.
- `forge fmt --check`: pass.
- Size inventory: **3/3**, **1 suite**.
- Full non-fork `forge test --no-match-path "test/{fork/**,review/**/*Fork*}"`: **1,548/1,548**, **190 suites**.
- Whole fork `forge test --match-path "test/{fork/**,review/**/*Fork*}" -j 4`: **227/227**, **57 suites**.
- No new fork test files or shared fork fixtures were added by this integration; existing CI suite registration is
  unchanged. Full suite rerun covers the merged late-dust code and acknowledgement changes.

## Runtime sizes and margins

Bytes, optimizer runs 800, no via-IR; EIP-170 limit 24,576. Before is PR #29 head `b0a937d`, after is integrated
`88b9550`. Off-chain edits do not alter bytecode; the only additional runtime change is main's late-dust merge.

| Contract/library | Before | After | After margin |
|---|---:|---:|---:|
| CoreVault | 22,358 | 22,358 | 2,218 |
| SpokeVault | 22,907 | 22,907 | 1,669 |
| CoreVaultPayoutLogic | 22,547 | 22,547 | 2,029 |
| SpokeCrossChainLib | 16,790 | 16,953 | 7,623 |
| SpokeUnwindLib | 21,594 | 21,594 | 2,982 |
| ValueReportReceiver | 8,309 | 8,309 | 16,267 |
| CoreVaultClosureLogic | 17,052 | 17,052 | 7,524 |
| CoreVaultTransitLogic | 16,005 | 16,005 | 8,571 |
| CoreVaultIncomeLogic | 12,236 | 12,236 | 12,340 |
| CoreVaultIncomeCollectionLogic | 17,689 | 17,689 | 6,887 |
| CoreVaultLogic | 13,612 | 13,612 | 10,964 |

Every production contract and linked library passes the inventory size test. Tightest margin **1,669 bytes**;
**none below 1,000 bytes**. Remaining production sizes/margins: AaveV3Adapter 9,893/14,683; AcrossBridgeAdapter
6,713/17,863; UniswapV3SwapAdapter 10,586/13,990; UniswapV4Adapter 14,369/10,207; ManagerFeeVault 1,077/23,499;
ManagerRegistry 1,603/22,973; ShareToken 1,822/22,754; TransitEscrow 894/23,682; Create3Deployer 1,342/23,234;
FundFactory 18,347/6,229; ChainlinkPriceSource 1,709/22,867; SpokeCloseLib 5,875/18,701; SpokeIncomeLib 12,563/12,013.

## Deviations and divergences

- Preserve **64 shared send slots** and **16 unwind result entries**, as already documented by PR #29.
- Preserve the prohibition on manual Income sends; Principal manual return is the off-chain regression probe.
- First alpha rehearsal exposed fixture over-allocation after the new 1 USDC return. Corrected the LP sizing to
  use remaining Unallocated Balance, then reran the complete rehearsal successfully twice. No contract workaround.
- Reuse existing PR #29 instead of creating a duplicate PR. No PR was merged and main was not pushed.
- No new specification divergence. Accepted internal-alpha limitations remain unchanged.

🤖 Generated with Codex (GPT), orchestrated from Claude Code
