# PR #26 round-3 URL redaction and alpha rehearsal — 2026-10-03

## Summary

HTTP(S)/WS(S) URLs are consumed as complete non-whitespace tokens and replaced with
`<redacted-url>`, without parsing or retaining upstream hosts or userinfo. Only literal
`127.0.0.1`, `localhost`, or `[::1]` endpoints with an optional numeric port and no userinfo
may remain whole. Loopback tokens containing another HTTP(S)/WS(S) URL fail closed too.
Adjacent closing punctuation may be consumed deliberately; this is conservative redaction.

The shell fork logger and alpha-safe wrapper use the same rule as TypeScript. All local-e2e
console call sites use the shared safe console, including object, formatted-string, and Error
arguments. Structured logs, status, forwarded RPC failures, API JSON string values, and run
reports use the shared redactor. Rehearsal and local API startup failures pass through runMain
rather than Node's unfiltered uncaught-error printer. Perl is an explicit shell prerequisite.

## Requirements

- DEC-134: protect internal-alpha operational output; no mainnet broadcasts performed.
- DEC-131: every production contract and linked library remains below 24,576 bytes.
- DEC-159: preserve rehearsal report publication and keeper startup checks.
- The round-2 durable transaction journal/reconciliation behavior is unchanged.

## Validation

- URL regressions: **42 cases**, including all 13 earlier cases, the exact reviewer input,
  percent-encoded/Unicode/punycode hosts, userinfo-only and empty URLs, scoped IPv6,
  IPv4-mapped IPv6, loopback lookalikes, mixed-case schemes, and nested URLs.
- Shell stdout and persisted log, C locale, failing wrapper stdout/stderr and exit 17,
  five failing synthetic cast commands, TypeScript idempotence, explain/runMain errors,
  all logger levels, child logger, and safe-console formatting/object/Error arguments pass.
- Alpha tests: **11/11**; verification tooling: **2/2**; TypeScript no-emit check passes.
- forge build --sizes and forge fmt --check pass; size tests **3/3**, 1 suite.
- Non-fork tests **1,433/1,433**, 183 suites; complete fork tests **222/222**, 56 suites,
  four workers, with the archive RPC helper sourced in the same shell command.
- Shell syntax and git diff --check pass.

## Short alpha-sized rehearsal

The existing script/rehearse-alpha.sh passed on private ports **18645/18646/18787** at
Arbitrum pin **511007613** and Robinhood pin **78293056** in approximately 58 seconds.
Minimum first deposit **2 USDC**, seed **5 USDC**, Spoke Cap **100 USDC**, deposit/send
**5 USDC**, Instant Payout and Aave allocation **1 USDC**, second investor **2 USDC**.
Both deployment checkers, capital/payout/income smoke, second-fund closure/frozen exit,
**5 API checks**, report publication and durable keeper cursor pass. Retained spoke
income dust **2,594 base units** stays below the **500,000-unit** COLLECT minimum;
**80 USDC base units** of Attributed Income settle. All owned Anvil/API/keeper processes
stop on exit; all three private ports are confirmed without listeners.

Ignored evidence: local-e2e/.state/round3/{sizes,size-tests,non-fork,fork,rehearsal}.log;
local-e2e/.state/alpha-rehearsal/smoke.jsonl. No credentials are committed.

## Sizes

Production before = after; no Solidity changes. Every executable margin exceeds 1,000
bytes; tightest is SpokeUnwindLib at **23,449 bytes / 1,127 bytes margin**. Full CodeStore
data chunks intentionally have zero margin and are not executable production contracts.

| Contract / linked library | Before bytes | After bytes | Margin bytes |
|---|---:|---:|---:|
| AaveV3Adapter | 9893 | 9893 | 14683 |
| AcrossBridgeAdapter | 6713 | 6713 | 17863 |
| UniswapV3SwapAdapter | 10586 | 10586 | 13990 |
| UniswapV4Adapter | 14369 | 14369 | 10207 |
| CoreVault | 22862 | 22862 | 1714 |
| CoreVaultClosureLogic | 16085 | 16085 | 8491 |
| ManagerFeeVault | 1077 | 1077 | 23499 |
| ManagerRegistry | 1603 | 1603 | 22973 |
| ShareToken | 1822 | 1822 | 22754 |
| TransitEscrow | 894 | 894 | 23682 |
| Create3Deployer | 1342 | 1342 | 23234 |
| FundFactory | 18347 | 18347 | 6229 |
| ChainlinkPriceSource | 1709 | 1709 | 22867 |
| ValueReportReceiver | 8080 | 8080 | 16496 |
| SpokeVault | 22887 | 22887 | 1689 |
| CoreVaultLogic | 13684 | 13684 | 10892 |
| CoreVaultTransitLogic | 15596 | 15596 | 8980 |
| CoreVaultIncomeLogic | 12101 | 12101 | 12475 |
| CoreVaultIncomeCollectionLogic | 16816 | 16816 | 7760 |
| CoreVaultPayoutLogic | 22256 | 22256 | 2320 |
| SpokeCrossChainLib | 12199 | 12199 | 12377 |
| SpokeUnwindLib | 23449 | 23449 | 1127 |
| SpokeCloseLib | 5875 | 5875 | 18701 |
| SpokeIncomeLib | 11631 | 11631 | 12945 |

## Deviations, divergences, remaining gates

No new specification divergence or work-package deviation. Operating Cash remains zero
under the October 2 ruling. Loopback output is deliberately permitted by this review request;
upstream identity is no longer preserved. Mainnet broadcasts, explorer verification, and real
external guardian/relayer acceptance remain release gates, not claims of this fork rehearsal.
The existing manual Principal-return restriction is unchanged. Pre-existing lib symlink status
is untouched and unstaged; neither lib nor .env is committed.

