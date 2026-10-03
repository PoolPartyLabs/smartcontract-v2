# Conformance blocker validation — 2026-10-03

Base: fetched `origin/main` `2b04b28`, newer than the handoff's `1db9a9d`.
Validated source/test head: `c947edd`. This report changes documentation only.

## Findings and regression evidence

- B-01: actual Hub Spoke Vault exposure reads Core Fund State. Closing allows only base-token unwind swaps;
  Closed allows no swap. All three `HubClosureExposure` tests fail before the gate and pass after it.
- B-02: terminal Principal/Income below 0.50 base-token units is recorded in exclusion events, removed from
  ledgers/reservations and left to `sweepExcess`. Closed-spoke Income sold units convert at zero dollars;
  prior converted entitlements remain intact. Principal/Income dust tests fail before the fix. A three-USDC
  unit fund and a five-USDC real Across-adapter/Wormhole two-fork CLOSE flow finalize and sweep terminal dust.
  See `docs/security/CLOSURE-DUST.md` for the versioned threshold and DEC-163 narrowing.
- B-03: reject nonzero Mandate floor/top-up, revert live setters including `(0, 0)`, and disable top-up hooks.
  Creation/setter tests fail before enforcement. Former sink PoCs now assert prevention; shared fixtures use
  zero cash. Native Operating Cash is not implemented: ruling 2026-10-02, DEC-187.
- G-05: Closed check precedes recovered-dollar release; an aggregate tracks creation, Principal release and
  Income reconciliation. Outstanding reservations block finalization. Closed recovery fails before the fix;
  Closing recovery then finalization and late Closed release both pass.
- B-04: private-port deployment of final runtime passes. Local forks are not production guardian/relayer
  liveness certification. No mainnet broadcast is performed.
- G-01/G-02/G-03/G-04/G-06/G-07: unchanged; documented with reasons in `docs/security/KNOWN-LIMITATIONS.md`.
  DEC-145 remains founder-pending; exceptions are internal-alpha-only.

## Final green bar

| Validation | Result |
|---|---|
| `forge build --sizes` | PASS |
| `forge fmt --check` | PASS |
| ContractSizes suite | 3/3, 1 suite; minimum runtime reserve enforced |
| Full non-fork suite | 1,497/1,497, 188 suites, 0 skipped |
| Whole fork suite, `-j 4` | 223/223, 56 suites, 0 skipped |
| Two-fork closure suite | 2/2, existing CLOSE flow and five-USDC dust flow |
| `CI=true pnpm install --frozen-lockfile` | PASS |
| `pnpm run up --warm-up none` + `pnpm status` | PASS, real factory/library/fund/spoke deployment |
| `pnpm down` and private-port listener check | PASS, no harness processes left running |

RPC helper is sourced in the same shell before every fork-test/harness-start invocation. Archive pins:
Arbitrum 511007613, Robinhood 78293056. Private ports: 19545/19546, reserved API port 19787.
Final runtime harness rehearsal at `2c6af67` (later `c947edd` adds only a test): factory
`0x408EBd63EC5DdB000471452253A73DB682590E5c`, Core Vault `0x3D010D998E19d52CE7be47021a3000e3eAa12F8E`,
Robinhood Spoke Vault `0x3a0Ef4d68EDDd9821593472ac84a75741bBcf3cf`. Status: both nodes up, seeded Idle
99 USDC, Share Price 1.00, no keeper. Both anvils subsequently stopped.

## Runtime sizes

| Contract / linked library | Before bytes | Before margin | After bytes | After margin |
|---|---:|---:|---:|---:|
| AaveV3Adapter | 9893 | 14683 | 9893 | 14683 |
| AcrossBridgeAdapter | 6713 | 17863 | 6713 | 17863 |
| UniswapV3SwapAdapter | 10586 | 13990 | 10586 | 13990 |
| UniswapV4Adapter | 14369 | 10207 | 14369 | 10207 |
| CoreVault | 22862 | 1714 | 22358 | 2218 |
| CoreVaultClosureLogic | 16085 | 8491 | 16749 | 7827 |
| CoreVaultIncomeCollectionLogic | 16816 | 7760 | 17645 | 6931 |
| CoreVaultIncomeLogic | 12101 | 12475 | 12101 | 12475 |
| CoreVaultLogic | 13684 | 10892 | 13684 | 10892 |
| CoreVaultPayoutLogic | 22256 | 2320 | 22258 | 2318 |
| CoreVaultTransitLogic | 15596 | 8980 | 15788 | 8788 |
| Create3Deployer | 1342 | 23234 | 1342 | 23234 |
| FundFactory | 18347 | 6229 | 18347 | 6229 |
| ManagerFeeVault | 1077 | 23499 | 1077 | 23499 |
| ManagerRegistry | 1603 | 22973 | 1603 | 22973 |
| ShareToken | 1822 | 22754 | 1822 | 22754 |
| SpokeCloseLib | 5875 | 18701 | 5875 | 18701 |
| SpokeCrossChainLib | 12199 | 12377 | 16429 | 8147 |
| SpokeIncomeLib | 11631 | 12945 | 12563 | 12013 |
| SpokeUnwindLib | 23449 | 1127 | 21229 | 3347 |
| SpokeVault | 22887 | 1689 | 22905 | 1671 |
| TransitEscrow | 894 | 23682 | 894 | 23682 |
| ChainlinkPriceSource | 1709 | 22867 | 1709 | 22867 |
| ValueReportReceiver | 8080 | 16496 | 8080 | 16496 |

Every production executable and linked library has at least 1,000 B margin. Tightest: SpokeVault, 1,671 B.
Inlined library stubs are 85 B. CodeStore chunks now have at most 23,576 B runtime and exactly 1,000 B minimum
margin instead of full-limit 24,576 B chunks. Its reserve regression fails before the fix; all 17 Create3 tests pass.
Compiler settings unchanged. Pure send-result move: SpokeUnwindLib 23,449 -> 21,229 B; isolated non-fork run
1,438/1,438 before subsequent dust/MVP changes.

## Deviations and divergences

- Use fetched main `2b04b28`; no pushed-history rewrite or main push.
- Reuse existing linked SpokeCrossChainLib for the pure move; no new deployment library or compiler tuning.
- Apply requested margin to non-executable CodeStore chunks too; preserve their storage format.
- Task-authorized terminal dust narrows DEC-163's literal empty-spoke requirement. Recheck the versioned 0.50
  threshold against the release Across route minimum; it is not an on-chain API oracle. USDC/USDG use six decimals.
- Enforce ruling 2026-10-02/DEC-187, rather than implementing deferred native cash, DEC-164/165 refunds or DEC-185.
- Add the new two-fork test in the already registered closure suite; no new SCENARIO_SUITES entry required.
- Do not change pending/accepted G findings. No external audit, production VAA/fill/refund certification,
  `pnpm scenario` or `api:probe` is claimed by the requested deploy-path smoke check.
