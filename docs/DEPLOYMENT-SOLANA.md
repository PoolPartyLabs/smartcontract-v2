# Solana v6 deployment rehearsal — founder approval packet

## fix-sp candidate ELF — October 11, 2026 (POO-2263)

Supersedes the 995,384-byte / `6b1d78f7…3ed2` ELF below; that hash is no longer
the release candidate. Program fixes: CR-03 (Raydium reward quarantine created
PDA-signed on first collect/close, Manager-paid), CR-16 (first Hub order at
Wormhole sequence 0), CR-17 (Kamino supply books the measured debit within one
cToken of rounding), CR-28 (`prune_registry` Manager-bound; localnet DEC-205
close-with-pending test), CR-33 (`swap_exact_in` typed Fund; harness fixes),
CR-12 Solana side (R9.1: no stock market-session gate; staleness only).

- Production ELF **1,002,944 bytes**, SHA-256
  `7653083a23a7932ac5934cce6b61c42cb67c79b89a6194a11b1c6817a907866d`,
  features `no-idl,no-log-ix-name`, opt-level z; program source
  `26fb7a112d23a28f1ae63f4851f9f8ab0bcc75f0`. Rebuilt byte-identical after a
  `rehearsal-v1-swap` feature build. The IDL top-level `errors` list alternates
  between error enums across builds (observed `ad649e46…` / `0034f06c…`):
  approve the IDL bytes of the approval build, never a historical hash.
- `script/solana-mainnet-approval.json` stays `NOT_APPROVED` with null top-level
  hashes; the candidate is recorded under `candidate` for founder review.
- GO-2 on a fresh mainnet clone (2026-10-11, slots 455,748,903–455,749,032 plus
  per-suite oracle refreshes): core 43/43, signed production 1/1 + DEC-205
  close 1/1, Scope 9/9, legacy composed 1/1 (15 tx, 2,176-byte report), 27/27
  named negatives (`tests/swap/negatives.localnet.test.ts`), local loader
  rehearsal with the real program keypair and R8 authority (1,048 tx; on-chain
  ELF equals file; authority R8).
- Read-only mainnet repricing at finalized slot 455,756,330: successful initial
  deploy **5.101940754 SOL** (ProgramData rent 5.095834360 + Program 0.000833120
  + 1,047 tx fees 0.005273274). R8 held 0 lamports and `7Ppt…` was unused at
  2026-10-11T18:51:33Z.
- Heaviest measured spoke transaction 498,777 CU (`raydium_close_position`,
  55.4% of the 900k builder cap); largest packet 952 bytes (CCTP receive).

## Hub fixes — October 11, 2026 (POO-2256)

> **Never call `closeFund` on a v6 Fund until CR-02 G1-G3 land.** `finalizeClosure`
> cannot complete: G1 collected Solana income has no route home (multi-asset Funds),
> G2 non-USDC residue cannot be liquidated under CLOSE, G3 the Hub ACK drops the EVM
> spoke's CLOSE result (G3 is also on `main`, so alpha Funds carry it). Holders of a
> Closing Fund can exit only after Closed. Closure is post-demo (R9.2) and stays
> fail-closed; while a Fund is Open, holders exit by payout (see CR-36 below).

### Native feed max ages (CR-12, R9.1)

Stock pricing is 24/7 (R9.1): no session window; each feed's max age is the only
time guard. `DeploySolanaV6` takes two explicit parameters, and
`SolanaPriceSourceV6` refuses zero or anything above its measured ceilings:

| Parameter | Feeds | Value | Ceiling in code |
| --- | --- | ---: | --- |
| `SOLANA_STOCK_PRICE_MAX_AGE` | TSLA/USD, NVDA/USD | 90,000 s (25 h) | `MAX_STOCK_PRICE_AGE` |
| `SOLANA_SOL_PRICE_MAX_AGE` | SOL/USD | 7,200 s (2 h) | `MAX_SOL_PRICE_AGE` |

Data, read 2026-10-11 17:31 UTC from `arb1.arbitrum.io` at Arbitrum block
513,882,670 (head-100, block time Sun 17:31:01 UTC), one Multicall3
`getRoundData` batch per feed; Chainlink directory metadata fetched the same minute:

| Feed | Rounds | Window (UTC) | Median gap | Gaps > 1 h | Max gap | Heartbeat / deviation |
| --- | ---: | --- | ---: | ---: | ---: | --- |
| TSLA/USD `0x3609…C3E3` | 200 | Sep 16 15:02 → Oct 11 15:43 | 960 s | 47 | **86,429 s** (Tue Oct 6 13:40 → Wed 13:40) | 86,400 s / 0.5% |
| NVDA/USD `0x4881…262F` | 200 | Aug 31 13:33 → Oct 11 15:58 | 3,242 s | 96 | **86,430 s** (Sat Sep 26 19:55 → Sun 19:56) | 86,400 s / 0.5% |
| SOL/USD `0x24ce…590c` | 1,000 | Oct 8 10:52 → Oct 11 17:27 | 150 s | 1 | **3,692 s** (Sat Oct 10 23:22) | 86,400 s / 0.1% |

The equity feeds do update on weekends (heartbeat only), so the previous shared
3,600 s blocked mint/burn/exit for most of every weekend and for long in-session
gaps (NVDA 96 of 199 gaps exceeded it). 90,000 s is the 24 h heartbeat plus one
hour; the largest observed gap overshoots the heartbeat by 30 s. SOL stays tight at
about twice its largest observed gap (3,600 s would have failed closed once in
the sample). No incomplete round (`updatedAt == 0` or `answeredInRound < roundId`)
was observed. Trade-off accepted by R9.1: a stock price up to 25 h old can price
a mint or burn when the feed is quiet (weekends, holidays); a missed heartbeat
fails closed (`UnsafeStockState`), never silently. Under a stale stock feed every
v6 share mint/burn path (deposit, Instant request, claim, settle, closed exit)
reverts until the next round; a Standard payout *request* still books.

### Payout liveness (CR-36)

The payout-liveness fallback covers the valuation only (price-source and hub-read
failures use last-known values). Burning a share additionally needs every accepted
spoke report fresh (DEC-160, both modes) and, on v6, every admitted stock feed within
its max age. On a stale report or stock feed, an Instant payout reverts
(`StaleSpokeReport` / `UnsafeStockState`); a **Standard request stays live**: it books
its reserve and 72 h term without burning, and its claim pays once state is fresh.
Proven on the composed v6 fork path (`ComposedSolanaFund.fork.t.sol`).

### Fund creation gas (CR-18)

Fitness test (`testFundCreationFitsThirtyMillionGasAtLargestMandate`): creation as
one Arbitrum transaction (21,000 + calldata + cold execution) must stay <= 30M of
Nitro's 32M per-transaction cap at the largest mandate the Hub admits. The factory no
longer stages the native config in storage (-0.65M to -1.15M gas). Measured at 3
native assets, every venue a Mandate pool:

| Native venues | 2 | 3 | 4 | 5 | 6 | 8 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Creation gas | 28.85M | 29.31M | **29.40M** | 29.86M | 29.79M | 30.00M |

`SolanaSpokeRegistryV6` admits at most 3 assets (Solana's own bound) and **4 venues**
(Solana accepts 8). The demo uses 2. Raising the venue bound is a founder decision
(D10) that needs more creation-gas headroom first (e.g. CoreVaultV6 creation code
through CodeStore, about -0.69M calldata gas). Arbitrum's L1 data component (~0.30M
gas units on 2026-10-09) is outside the 30M and grows with L1 fees.

### Fork pins and test gas (CR-19)

Fork tests read `ARBITRUM_FORK_BLOCK` / `ROBINHOOD_FORK_BLOCK` (CCTP suites:
`CCTP_ARBITRUM_FORK_BLOCK`, then the Arbitrum pin); unset, they fork at head-100
(`test/fork/ForkPins.sol`). No pin or stock session remains in test source.
`foundry.toml` sets `gas_limit = max` for the whole-stack deployment tests. The
Solana creation builder's fixed localnet port (8998) is owned by the `solana/` track.

## Deploy-day runbook S0–S12 (current; supersedes every older ordering below)

Status 2026-10-11: **NO-GO** until every S0 box is ticked. Nothing in this file
authorizes a mainnet transaction; **every S-step needs its own founder
authorization**, and any unticked box is NO-GO. Source: `results/e2e-sweep/risk-review.md`
§6, updated for the 2026-10-11 founder rulings: stock value is on-chain and 24/7 with
price staleness as the only guard (R9.1); closure is not a demo blocker and stays
fail-closed (R9.2); CCTP must work for the demo (R9.3). DEC-188..206 apply.

Tools (all refuse to send without their approval file; all logs are sanitized):

| Purpose | Command | Gate |
| --- | --- | --- |
| Read-only deploy preflight | `node solana/scripts/deploy-mainnet.mjs --preflight` | none (read-only) |
| Program deploy / verify | `deploy-mainnet.mjs --broadcast` · `--verify` | `FOUNDER_APPROVED` copy, clean commit |
| Griefed program id | `deploy-mainnet.mjs --recover-prefunded` | same as `--broadcast` |
| ProgramData watch | `node solana/scripts/programdata-watch.mjs` (cron) | none (read-only) |
| EVM factories / Fund | `bash script/solana-evm-deploy.sh <chain> <module> --dry-run\|--broadcast` | `PP_EVM_FOUNDER_APPROVED`, approved commit, keystore/Ledger |
| Native bootstrap | `node solana/scripts/three-chain-creation.ts broadcast` | `script/solana-manager-approval.json` copy, plan SHA, landed Hub tx |
| API-built Manager txs | `node solana/scripts/manager-sign.mjs inspect\|send` | same approval copy, reviewed intent hash |
| Budgets | `node solana/scripts/deploy-mainnet-budget.mjs` · `node script/solana-evm-budget.mjs` | read-only |

| Step | Action | NO-GO checkpoint (all must hold) | Failure → rollback / recovery |
| --- | --- | --- | --- |
| **S0** Pre-flight (read-only) | Decisions recorded; providers provisioned; keys split; funding landed | ☐ D1 asset set recorded. R9.1: no market-hours premise; the only guard is price age. Read TSLA/NVDA `latestRoundData` right before S4 and S6: the sealed max price age must exceed the observed gap or every stock read reverts (2026-10-11 18:09 UTC, Sunday: TSLA/USD 8,785 s, NVDA/USD 7,854 s old). Confirm the approved commit contains the session-gating removal; otherwise seal a no-stock Fund ☐ RPC: chain ids 42161/4663 and Solana mainnet genesis on key-less or paid providers that allow about 1,100 sends ☐ `deploy-mainnet.mjs --preflight` exits 0 (id unused and not pre-funded, buffer unused, R8 ≥ approved minimum, genesis). 2026-10-11 17:50 UTC: id unused, **R8 0 lamports → NO-GO** ☐ Role split done (CR-11 table): new keeper key on the dev host, R8 absent from it ☐ Program keypair backed up encrypted on two media (CR-22) ☐ Manager approval copy pins `managerSolanaKey` (sealed per Fund, DEC-190) ☐ `closeFund` out of scope (R9.2) | Nothing sent. Rollback = NO-GO. |
| **S1** Freeze | Record approved commit, ELF, IDL, toolchains | ☐ Clean checkout equals the approval file ☐ `bash solana/scripts/deploy-build.sh` byte-identical: ELF 1,002,944 B `7653083a…866d` (fix-sp candidate, program source `26fb7a1`; IDL hash = the approval build's, see fix-sp section) | NO-GO |
| **S2** Gates | Suites at fresh pins (head − 100 taken immediately before) | ☐ All PASS without cache-served stale pins ☐ `node --test script/solana-deployment-safety.test.mjs script/solana-release-safety.test.mjs` ☐ `node --test --test-concurrency=1 script/solana-ops.localnet.test.mjs` | NO-GO |
| **S3** EVM factory dry run | `solana-evm-deploy.sh arbitrum\|robinhood factory-v6 --dry-run` with the REAL deployer address | ☐ 27 / 15 transactions ☐ Pin = head − 100 ☐ Deployer nonce unchanged until S4 ☐ Role addresses and the `maxFeeBps = 50,000` constant in the artifacts | NO-GO |
| **S4** BROADCAST factories | Arbitrum, then Robinhood, keystore or Ledger signer | ☐ Runtime hashes, owner/wiring, price source, Circle pins verified against the dry-run artifact ☐ Addresses recorded and `approvedFactory` set | Immutable. Partial (Arbitrum OK, Robinhood failed): retry Robinhood with the same signer; if the nonce drifted, addresses change → redeploy and update manifests. |
| **S5** Solana program | `--preflight` → `--broadcast` → `--verify`; start the watcher | ☐ `7Ppt…` still unused ☐ Buffer address unused ☐ `--verify` exact ELF, authority, 1× capacity ☐ (D3) authority moved to the cold key, `expectedAuthority` set, `--verify` again ☐ Watcher cron OK | Partial upload keeps the buffer (≈ 5.057 SOL): resume with `--recover-prefunded` if the id was griefed, or `solana program close <BUFFER>`. Griefed id → `--recover-prefunded`. After success roll back only by **upgrade of the same id; never `program close`**. |
| **S6** Create Fund | USDC approve + `createFundV6Committed` (`solana-evm-deploy.sh arbitrum fund-v6`) | ☐ Builder input equals the decisions (assets, Manager Solana Key, api_signer, swap policy, aliases, max report age 1,600) ☐ Dry run at a fresh pin with the actual Manager as sender ☐ Gas ≤ 30M ☐ Record tx hash, Hub core, factory, plan SHA-256 and Fund PDA in the Manager approval copy | **Irreversible.** Wrong config: do not allocate; holders exit by Instant payout while Open. |
| **S7** Robinhood `createSpoke` | Manager EOA | ☐ SpokeVault equals the mandate's spoke | Do not allocate to Robinhood; deposits stay frozen until the spoke reports. |
| **S8** Native bootstrap | 7 Manager-signed transactions: `three-chain-creation.ts broadcast` (or API `bootstrap` + `manager-sign.mjs` per chunk) | ☐ Fund PDA equals the commitment ☐ SwapConfig bytes equal the policy ☐ Every signature journaled; initializer landed | Rerun resumes from the journal; an uncertain signature is reconciled, never re-signed. No cancel: abandoned stage rent is stuck. |
| **S9** Routes, emitters, keeper | Hub emitter (consistency 32), equal max ages, API discovers the v6 Fund, keeper funded | ☐ One Solana **and** one Robinhood report delivered before any capital ☐ API discovery of the three-chain Fund | NO-GO for capital; the Fund idles with its seed. |
| **S10** CCTP probe (R9.3) | 1 USDC Arb→Sol with `maxFee` at the cap; keeper receive; report; then 1 USDC Sol→Arb | ☐ In-flight = amount − maxFee ☐ Credited ☐ Unspent fee booked as principal ☐ No pending claim. **Fast only:** `CctpBridgeAdapter.sol:18,114` and `wire.rs:7,116` hard-code finality 1000; a Standard route needs a code change, a new ELF and new factories — it is not an operational cut | A pending claim is never written off: retry the keeper, then manual `build-receive` signed with `manager-sign.mjs`. Do not proceed while any transit is pending. |
| **S11** Venues | Kamino supply; Raydium position (demo scope) via API `build/:action` + `manager-sign.mjs` | ☐ Report delivered after each action ☐ Manager SOL ≥ reserve | `UnexpectedDelta`: re-simulate and retry. Positions exit only by the Manager. |
| **S12** Unwind to the Hub | Kamino redeem / LP close → `send_to_hub` (5 bps cap) → Hub credit → report | ☐ Fund stays Open; holders exit by Instant payout ☐ No `closeFund` (R9.2, G1–G3 fixed post-demo) | Pending claims persist; any closure attempt traps capital. |

### Funding — repriced live 2026-10-11

Budget numbers come **only** from `deploy-mainnet-budget.mjs` (mainnet rent,
5,080 lamports/byte with overhead) and `script/solana-evm-budget.mjs` (Nitro
L1-inclusive). Local-validator rent (6,960 lamports/byte) in older sections
overstates mainnet by ≈ 1.87 SOL and is never a funding figure.

| Wallet / role | Measured now | Recommended envelope | Source |
| --- | ---: | ---: | --- |
| R8 deployer (Solana) | 5.101940754 SOL for the fix-sp ELF: Program 0.000833120 + ProgramData 5.095834360 + 1,047 tx fees 0.005273274 (finalized slot 455,756,330, 18:51 UTC, 10,000 µlamports/CU floor, p75 = 0; was 5.063495738 for the superseded 995,384 B ELF) | **5.30 SOL** (one full-retry and fee margin; a failed buffer is recoverable by `program close <BUFFER>`) | `deploy-mainnet-budget.mjs` |
| Manager Solana Key | modeled peak 0.168 SOL per lifecycle (sweep) | **0.25 SOL** | solana-program lane |
| Keeper (new key, CR-11) | ≈ 0.011 SOL permanent rent per Solana report | **1.0 SOL** at a 20-min demo heartbeat; cadence is D6/CR-15 | risk-review R07 |
| Arbitrum deployer / Manager | v6 factory 27 tx **0.001986161 ETH** L1-inclusive at 0.020004 gwei (pin 513,890,045, 18:08 UTC); creation ≈ 29.6M gas ≈ 0.00059 ETH | **0.02 ETH** (stress 0.018) | `solana-evm-budget.mjs`, evm-hub lane |
| Arbitrum keeper / delivery signer | ≈ 0.0124 ETH/day of Hub deliveries at a 10-min cadence | **0.015 ETH/day** | risk-review RR12, CR-26 |
| Robinhood deployer / Manager | v6 factory 15 tx **0.001185643 ETH** at 0.02021 gwei (pin 86,031,040, 18:08 UTC) | **0.012 ETH** | `solana-evm-budget.mjs` |
| Seed | — | **50 USDC** (49 principal after the 2% flow fee) | DEC-195 |

Total Solana ≈ 6.55 SOL. Set `walletMinimumLamports` in the approval copy to the
R8 figure the founder approves; `--preflight` then checks it.

### Port registry — the single source of truth for local validators

Every lane, script and brief takes its block from this table; a port in use is
never killed, the run stops instead. API dev servers use the port in their own
brief; a lane header and a coordinator matrix must not disagree with this table.

| RPC / faucet / gossip / dynamic | Owner |
| --- | --- |
| 8899 / 9900 / 1024 / 1025–1065 | `localnet.sh` defaults (single-run only) |
| 8910 / 9910 / 11000 / 11001–11060 | fix-sp lane (program fixes) |
| 8920 / 9920 / 12000 / 12001–12060 | CCTP track |
| 8930 / 9930 / 13000 / 13001–13060 | fix-api lane (API e2e contracts); formerly the Kamino track — never run both |
| 8940 / 9940 / 14000 / 14001–14060 | fix-ops lane; `script/solana-ops.localnet.test.mjs` defaults |
| 8950 / 9950 / 15000 / 15001–15060 | swap track |
| 8960 / 9960 / 16000 / 16001–16060 | integration track (T8a); the e2e sweep coordinator matrix also used it |
| 8970 / 9970 / 17000 / 17001–17060 | finish-work default suite; `deploy-local.mjs` default 8970 |
| 8990 / 9990 / 19000 / 19001–19060 | NVDAx swap track (T8c) |
| 8983 / 9983 / 18300 / 18301–18360 | `solana-release-rehearsal.sh`; `deploy-loader-rehearsal.mjs` |
| 8995 / 9995 / 19500 / 19501–19560 | native clone harness evidence |
| 8996 / 9996 / 19700 / 19701–19760 | size-optimization track |
| 8997 / 9997 / 19800 / 19801–19860 | Scope track |
| 8998 / 9998 / 19900 / 19901–19960 | `solana-three-chain-creation.sh` (`accept-local` asserts 8998) |

Blocks are reusable only after their owner finished; a new lane is added here
before it starts, never assigned from memory in a brief.

## Key roles and the keeper split (CR-11)

R8 was deployer, upgrade authority, keeper and test Manager at once, with a copy
on the dev host: a dev-host compromise could upgrade the program and drain every
vault. Every keeper instruction is permissionless, so the keeper needs no special
key and no code change: `receive_and_credit.rs:8` ("permissionless relaying"),
`publish_report.rs:15-17` (any `authority: Signer`, which only pays) and
`kamino_refresh.rs:9` ("anyone may pay").

**Prepared 2026-10-11:** a new keeper keypair at the founder-machine
`smartcontract-v2/.keys/keeper.json` (file 0600, directory 0700, excluded from Git,
never printed). Public key **`8VLSQNmrHGyWzzoTKXZYjegPRbCm8UY7AmPyUUqzZe1x`**,
balance 0: fund it per the table above (1.0 SOL envelope, cadence D6).

| Role | Key | Lives on | Power | Rotation |
| --- | --- | --- | --- | --- |
| Solana deployer, initial upgrade authority | R8 `6VTvei…FgJaA` | founder machine only, **never the dev host** | deploy; upgrade until moved | move to the cold key right after `--verify` (D3) |
| Upgrade authority after `--verify` | cold key (hardware/offline) | offline | upgrade | `--final` before client capital (DEC-189) |
| Program id signer | `7Ppt…` keypair | `.keys/` + two encrypted offline copies | none after deploy | n/a |
| Solana keeper | `8VLSQ…Ze1x` | dev host, `V2_SOLANA_KEEPER_PRIVATE_KEY` | pays receives, reports, refreshes | any time; no on-chain change |
| Manager Solana Key | founder Phantom/hardware (or R8, kept off servers) | founder | Manager actions; sealed per Fund (DEC-190) | cannot rotate; new Fund |
| EVM deployer | `.env.alpha` deployer imported into a Foundry keystore | founder machine | factory deploys | n/a |
| API quote signer | dedicated hot EVM key | dev host, `V2_API_SIGNER_KEY` | quote signatures; sealed in factory wiring and `SwapPolicy.api_signer` | choose **before** the factory deploy; new Fund to rotate |
| EVM keeper / delivery payer | dedicated hot EVM key | dev host, `V2_KEEPER_KEY` | pays Hub deliveries (CR-26 moves them off the quote signer) | any time |
| Protocol recipient, adapter guardian, registry owner | cold (founder wallet or Safe) | offline | fees, guardian, registry | immutable per factory |

Dev-host install (separately approved; nothing here was done on the host). Copy
the file without printing it, write a separate 0600 env file, restart the API,
then remove R8 from the host and from any backup or log copy:

```sh
scp .keys/keeper.json devhost:/srv/pool-party/secrets/solana-keeper.json   # 0600 on arrival
ssh devhost 'umask 077; printf "V2_SOLANA_KEEPER_PRIVATE_KEY=%s\n" "$(cat /srv/pool-party/secrets/solana-keeper.json)" \
  > /srv/pool-party/secrets/solana-keeper.env && rm /srv/pool-party/secrets/solana-keeper.json'
```

Verify by public key only, never by echoing the variable: run
`solana-keygen pubkey` on the local file before copying, and check that the fee
payer of the first keeper transaction on an explorer is `8VLSQ…Ze1x`.

## Upgrade authority, ProgramData watch and program-key custody (CR-22)

**Rule — never close the program.** Never run `solana program close` on the spoke
program while any Fund exists, has ever held capital, or has a pending CCTP claim.
Closing refunds only ProgramData rent, the program id can never be redeployed, and
every Fund PDA, vault ATA, position NFT and in-flight CCTP mint (whose
`destinationCaller` is the vault PDA) becomes permanently unreachable. Rollback is
always an upgrade of the same id (risk-review R09). `solana program close` is
acceptable only for a **buffer** account (`solana program close <BUFFER>`).

**Authority.** `script/solana-mainnet-approval.json` carries two fields:

| Field | Meaning | Used by |
| --- | --- | --- |
| `authority` | R8 deployer and initial upgrade authority; pinned in code | `--broadcast`, `--recover-prefunded`, the post-deploy verify |
| `expectedAuthority` | Current upgrade authority after a reviewed move (D3), or `"none"` once revoked (DEC-189); `null` means "same as `authority`" | `--verify`, `programdata-watch.mjs` |

After `deploy-mainnet.mjs --verify` passes, the founder may move the authority to a
cold key (separately approved transaction):

```sh
solana program set-upgrade-authority 7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx \
  --upgrade-authority "$R8_SIGNER_FILE" --new-upgrade-authority <COLD_PUBKEY> \
  --skip-new-upgrade-authority-signer-check   # only for a hardware/offline key
```

Then set `expectedAuthority` to `<COLD_PUBKEY>` in the out-of-repo approval copy and
rerun `--verify`. Revocation before client capital (DEC-189) is
`solana program set-upgrade-authority <PROGRAM_ID> --final`, recorded as
`expectedAuthority: "none"`; it is irreversible and needs its own approval.

**Watcher.** `solana/scripts/programdata-watch.mjs` is read-only. It checks that the
program is present and executable, the ProgramData authority equals the expected
authority, the deploy slot is unchanged since the recorded baseline, and the ELF
bytes hash to `release.json` `binarySha256`. It prints one JSON line and exits 0
(OK), 2 (ALERT) or 1 (could not check). An upgrade alerts once; the new slot then
becomes the baseline. Run it on the dev host every 5 minutes and page on exit 2:

```cron
*/5 * * * * cd /srv/pool-party/smartcontract-v2 && SOLANA_MAINNET_RPC="$KEYLESS_SOLANA_RPC" \
  node solana/scripts/programdata-watch.mjs >> /var/log/pp-programdata-watch.jsonl 2>&1 || pp-alert programdata
```

Archive the approved ELF, IDL and `pp_spoke.release.json` (SHA-256 recorded)
alongside the approval copy. Before deploy, a mainnet run reports
`programState: "absent"` and exits 2 (measured 2026-10-11 18:02 UTC).

**Encrypted offline backup of the program keypair.** `.keys/pp_spoke-program-keypair.json`
exists as one copy. Losing it before deploy forces a new program id, a rebuild and
every derivation again; a leak before deploy lets anyone squat `7Ppt…` with their
own code. After deploy it has no power. Back it up before funding R8:

```sh
umask 077
# 1. Encrypt to each of TWO offline media (USB keys kept in different places).
#    gpg prompts for the passphrase through pinentry; it never appears on argv.
gpg --symmetric --cipher-algo AES256 --s2k-digest-algo SHA512 --s2k-count 65011712 \
  --no-symkey-cache --output /Volumes/<OFFLINE_1>/pp_spoke-program-keypair.json.gpg \
  .keys/pp_spoke-program-keypair.json
# 2. Verify each copy without writing plaintext: same hash and same public key.
gpg --decrypt --no-symkey-cache /Volumes/<OFFLINE_1>/pp_spoke-program-keypair.json.gpg | shasum -a 256
shasum -a 256 .keys/pp_spoke-program-keypair.json
solana-keygen pubkey <(gpg --decrypt --no-symkey-cache /Volumes/<OFFLINE_1>/pp_spoke-program-keypair.json.gpg)
#    -> 7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx
```

Keep the passphrase in the founder's password manager, never next to a medium,
never in Slack, a repository or the dev host. Use the same procedure for R8 and for
any cold upgrade-authority key file. Record the date and media labels (not the
passphrase) in the deploy log.

## Secrets off argv and key-less RPC (CR-27)

Nothing secret appears on a command line (`ps`, shell history, CI logs):

- **EVM broadcast signer.** `script/solana-evm-deploy.sh --broadcast` no longer
  accepts `--private-key`. It signs with a Foundry keystore (default) or a Ledger
  and refuses when the signer address differs from `EVM_DEPLOYER_ADDRESS`:

  ```sh
  cast wallet import pp-evm-deployer --interactive   # prompts; stored encrypted in ~/.foundry/keystores
  export EVM_KEYSTORE_ACCOUNT=pp-evm-deployer
  export EVM_KEYSTORE_PASSWORD_FILE="$HOME/.pp/evm-keystore.pass"   # optional, mode 0600; else forge prompts
  # or: export EVM_SIGNER=ledger
  ```

- **EVM endpoints.** argv carries only the `foundry.toml` `[rpc_endpoints]` alias
  (`arbitrum`, `robinhood`); Foundry resolves it from `ARBITRUM_RPC_URL` /
  `ROBINHOOD_RPC_URL` in the environment (`--fork-url arbitrum`,
  `cast chain-id --rpc-url arbitrum`).
- **Solana endpoint.** `deploy-mainnet.mjs` hands the Solana CLI a 0600 config file
  (`--config`) inside its 0700 temporary directory, next to the 0600 temporary payer
  file; both are deleted in `finally`. Node-side reads use the environment only.
- **Key-less providers.** Prefer endpoints whose URL is not a credential: IP- or
  origin-allowlisted, or header-authenticated. Treat any keyed URL as a secret:
  never paste it into Slack, reports, evidence or a browser bundle.
- **Out of this package (API repo):** add `V2_API_SIGNER_KEY`, `V2_KEEPER_KEY`,
  `V2_SOLANA_KEEPER_PRIVATE_KEY` and `V2_JUPITER_API_KEY` to the Sentry exact-value
  redaction list, and allow `http` for Iris/VAA only on loopback mocks.

> **Historical evidence below (October 7–9).** The runbook, funding table and port
> registry above supersede every ordering, budget, funding proposal and port listed
> further down. Keep the sections below for provenance only.

## Post-Scope integration review — October 7, 2026

PR #49 is integrated. The production ELF is now **995,384 bytes**, SHA-256
`6b1d78f7add9f932d065f06b15fb41de94b1b4fe1d931412d849f5c5a4be3ed2`,
with persistent program `7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx` and
features `no-idl,no-log-ix-name`. The source-qualified release manifest and exact
IDL hash are rebuilt under `solana/target/deploy/pp_spoke.release.json`; raw IDL
JSON order can vary, so approve the actual final bytes, never a historical hash.
Earlier 984,208-byte deployment/action/rent budgets are historical, not a budget
for this release. Reprice them before founder approval. Approval remains
`NOT_APPROVED`; Scope and stock swaps remain OFF in the creation builder.

Local acceptance after integration: core/default 43 tests, signed production
one lifecycle, Scope nine tests, and separate legacy-feature composed native
one lifecycle (15 transactions, 2,176-byte report), all pass. The latter is not
a correlated production three-chain Fund. Production was rebuilt afterward.
An initial signed-production attempt reached stale cloned oracle rejection;
fresh read-only clones passed without relaxing any guard or assertion.

Security review pins mainnet upgrade authority to the R8 public key, disables
inherited shell tracing before wallet/RPC parameter access, and excludes root
`.keys/` in every clone. Scope's dedicated launcher uses the persistent identity;
its fixture/probe-dependent suite is separated from default core acceptance.
The full EVM suite still has public-provider archive/connection failures. The
four touched composed Hub tests pass at block 512609390 using Foundry cache.
Genuine wallet-backed creation cannot be repeated without separately supplied
wallet parameters; synthetic-key fork attempts are not genuine-wallet evidence.
These are preparation limits, never mainnet authorization or a claim of GO.

## T11 blocker update — October 7, 2026

This section supersedes T9 identity/creation blocker statements, not founder
approval. **Still NO-GO:** the supplied Alchemy Robinhood provider returns HTTP
429 / monthly capacity exhausted. No mainnet transaction was submitted.

- Persistent program: `7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx`.
  Its founder-machine key is outside worktrees at root `.keys/pp_spoke-program-keypair.json`
  (directory 0700, file 0600, tracked Git exclusion; never distribute/commit).
- `script/solana-three-chain-creation.sh` builds real Manager EIP-712 consent,
  sealed swap config, policyHash-qualified identities, Hub creation (50 USDC),
  Robinhood `createSpoke` and native staged acceptance. It has no broadcast mode
  (superseded 2026-10-11: `three-chain-creation.ts broadcast` is approval-gated, see S8);
  native sends require loopback port 8998 (other ports 9998/19900/19901-19960).
- `cache/sol-t11/creation.json` contains exact EVM calldata;
  `signer-prompts.json` contains ordered signers and native account/data lists.
  These are expiring local fork artifacts, **not approved deployment requests**.
- Genuine actual-wallet Arbitrum creation and native acceptance pass. Native
  acceptance takes seven transactions: three staged chunks, one ALT creation,
  two ALT extensions, one initializer. Initializer is 303 bytes; last measured
  simulation 363,113 CU; local payer debit 65,646,920 lamports before priority.
- Composed same-Fund tests: four PASS at Arbitrum block 512609390. Removed a
  backwards timestamp warp that made real feeds future-dated (`TokenNotPriced`);
  pricing validation is unchanged. Factory staging now retains `swapPolicyHash`.
- Supplied Alchemy Arbitrum and Robinhood both report monthly quota exhaustion;
  Arbitrum evidence uses a fresh public fork, not an unreported provider substitute.
  Genuine Robinhood completion remains blocked; wrapper exits nonzero even when
  Hub/native checkpoints pass. Do not retry the exhausted provider repeatedly.

Load `.env.alpha` / `.env.solana` in a shell with tracing disabled and export
parameters without printing. Source the handoff `tools/rpc-env.sh` for approved
providers. Explicit `ARBITRUM_FORK_BLOCK`, `ROBINHOOD_FORK_BLOCK`, and `PP_SWAP_MAX_AGE`,
`PP_SWAP_CONFIDENCE_BPS`, `PP_SWAP_CROSS_CHECK_BPS`, `PP_SWAP_SLIPPAGE_BPS`
are required. Tested **proposal** limits were 300 seconds / 100 / 50 / 200 bps;
they are not a founder ruling. Scope OFF and stock swaps unavailable are sealed
as the two final zero bytes of the swap policy; Manager impact has no default.
Prepare mainnet clones using the existing README harness before the wrapper.
DEC-188/189/190/195/196/200/202/203 and R4.2/R8 apply.

### Funding proposal — founder approval required (superseded by the 2026-10-11 repricing at the top)

Propose **5.75 SOL**, **0.015 ETH Arbitrum**, **0.010 ETH Robinhood**,
and **50 USDC seed** (49 USDC initial Fund principal after existing 2% flow fee).
These are wallet funding envelopes, not exact transaction invoices or rulings.

| Wallet role/action | Proposed count and reserve |
| --- | --- |
| Solana deployer | One 1x program deployment, 1,026 buffer writes + create/deploy = 1,028 transactions; read-only mainnet model 5.006666361 SOL at finalized slot 454269380 |
| Manager Solana Key | Exact creation seven transactions above; then Kamino supply/refresh/redeem, one SOL ratio swap, one SOL/USDC open/collect/close = seven more, total 14; reserve 0.20 SOL including native initialization, LP/cToken rents and ALT setup |
| Keeper | N=2 CCTP receives (allocation + one retry); M=4 finalized report posts, each refresh/build/publish = 12 transactions; total 14; reserve 0.10 SOL including nonce/message rent |
| Solana contingency | 0.443333639 SOL above deploy + Manager + keeper allocations, including failed-buffer/retry headroom; R8 combines roles in the one founder wallet but budgets remain logically separate |
| Arbitrum operator/Manager | One v6 stack: 27 prior measured deployment transactions; approval + creation: 2; Across out + CCTP out + receive return + two report deliveries + closure: 6; total 35, reserve 0.015 ETH including Nitro L1 data and retries |
| Robinhood operator/Manager | One v6 stack: 15 prior dry-run transactions; createSpoke + Across claim + open/collect/close + report + return = 7; total 22, reserve 0.010 ETH including Nitro L1 data and retries |

Prior Arbitrum factory-only L1-inclusive model was 0.002141790546254 ETH;
do not treat either EVM envelope as a final fee quote. Robinhood provider blocks
fresh gas/L1 estimates and the genuine creation repeat. Before approval, reprice
the exact exported transactions on both chains, correlate native lifecycle
steps with this same Fund, and measure keeper rents for this action plan.
The production T9 independent session's 0.166578 SOL Manager peak and
0.040934420 SOL keeper peak inform reserves but are not this exact demo.
Do not add legacy and production independent rehearsals together.

### Remaining review and downstream propagation

- **TODO(decision):** canonical EVM role aliases for a single native program
  are not specified. Builder uses domain-separated swap/CCTP accounting aliases
  solely to satisfy existing disjoint adapter namespaces; no new callable EVM
  contracts are implied. Coordinator review required before production calldata.
- Current max-three-assets permits USDC/WSOL/NVDAx in this tested creation;
  TSLAx ATA is initialized but not admitted. All three stock/SOL LP choices
  cannot be represented simultaneously with four assets. Coordinator must
  settle the release asset bound/admission, not silently advertise all choices.
- PR #49 rebuild and local acceptance are complete; see the post-Scope update.
  Scope OFF policy is unchanged. Final deployment budgets still need repricing.
- API/indexer and frontend manifests must update program id, off-chain IDL,
  all Fund/vault/emitter/ledger/config/ATA derivations, CCTP destinationCaller
  and mintRecipient, Hub native config/signature domains and report emitter
  registration. No API/frontend repositories were modified by this track.
- Approval file remains `NOT_APPROVED`; program identity is not upgrade authority.
  R8 wallet holds upgrade authority for MVP; revoke before client capital (DEC-189).


## T9 release package — October 7, 2026 (POO-2263)

**NO-GO until every gate below passes. No mainnet transactions are authorized by
this preparation task.** The commands marked BROADCAST are for a subsequent,
separately approved founder session only. Historical evidence later in this file
is not evidence for integration #48. DEC-188 through DEC-206 and R8 apply.

### Build and identities

Run from a clean checkout of the approved integration merge, not another track's
worktree. Keep the pinned Anchor 0.31.1, Agave 2.3.0 and locked dependencies.

```sh
git submodule update --init --recursive
cargo test --manifest-path solana/Cargo.toml --locked
cargo test --manifest-path solana/Cargo.toml --locked --features rehearsal-v1-swap
npm ci --prefix solana
npm test --prefix solana
bash solana/scripts/deploy-build.sh
node --test script/solana-deployment-safety.test.mjs script/solana-release-safety.test.mjs
forge build
```

The release profile uses `opt-level="z"`, checked overflow, fat LTO, one codegen
unit, no debug info and stripped symbols. The builder has no feature argument:
only `no-idl,no-log-ix-name` enters the production ELF. `default=[]` is unchanged.
Do not deploy `rehearsal-v1-swap`, `idl-build`, `anchor-debug`, `cpi` or
`no-entrypoint`. `anchor build` still generates `solana/target/idl/pp_spoke.json`
and `solana/target/types/pp_spoke.ts`; the builder validates IDL instructions and
events and writes `solana/target/deploy/pp_spoke.release.json` with source commit,
ELF/IDL hashes, bytes and features. No command initializes an on-chain IDL account;
`no-idl` makes Anchor's IDL management dispatch fail closed. Distribute the JSON
and TypeScript to API/frontend without calling `anchor idl init/upgrade`.

Indexer inputs are Anchor business-event `Program data:` payloads decoded with
this exact IDL, transaction success and finalized reports, not removed
`Instruction: <name>` strings. External CPI programs may still log instruction
names; those strings are not Pool Party event evidence. Wormhole Solana reports
require consistency **32** (DEC-192); read the same committed max-age rule for
each chain, never introduce a Solana-specific tolerance.

Measured #48 production ELF: **984,208 bytes**, SHA-256
`071686e3ef1483f0ee707b6589f2e4cdc657f91f2793af902c79dfbdbf0c1649`.
The earlier size study's 788,688-byte ELF predates #48's signed swap/oracle work;
it is not the artifact to deploy. Rebuild and replace measurements after any
identity/source change. The current program id is still the scaffold placeholder.
**Coordinator must bind a persistent founder-owned program signer, update
`declare_id!`/Anchor configuration and fixtures, then rerun all gates.** T9 does
not rewrite track-owned program identities or generate a mainnet identity.

One key `6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA` is deployer, upgrade
authority, keeper and test Manager for the closed hackathon (R8). This is NOT the
program-id signer. Keep the program and buffer signer files separately, outside
the repository, owner-only mode 0600. DEC-189 still requires upgrade-authority
revocation before client capital; never use `--final` for this upgradeable demo.

### Read-only costs and rehearsals

Load approved environment files as shell parameters; never use `cat`, `env`,
`set -x`, `echo "$RPC"`, `printenv`, or secret-bearing command transcripts. Start
a fresh non-traced shell. Environment-file paths may point outside this worktree.

```sh
set +x
set -a; . "$SOLANA_ENV_FILE"; set +a
node solana/scripts/deploy-mainnet-budget.mjs > cache/sol-t9/solana-budget.json
set -a; . "$EVM_ENV_FILE"; set +a
source /Users/rafaelzochling/gitrepos/code-docs/pool-party-sc-v2-handoff/tools/rpc-env.sh
# Set explicit ARBITRUM_FORK_BLOCK and ROBINHOOD_FORK_BLOCK; record them.
# EVM_DEPLOYER_ADDRESS is the .env.alpha deployer's PUBLIC address.
# Supply reviewed recipients, guardian, API signer, registry owner,
# SOLANA_STOCK_PRICE_MAX_AGE and SOLANA_SOL_PRICE_MAX_AGE (CR-12, see "Native feed
# max ages"). Test placeholders are never launch config.
bash script/solana-evm-rehearsal-all.sh
node script/solana-evm-budget.mjs
bash script/solana-release-rehearsal.sh core
bash script/solana-release-rehearsal.sh production
bash script/solana-release-rehearsal.sh legacy
bash solana/scripts/deploy-build.sh
```

The three native runs have independent genesis and own ports
8983/9983/18300/18301–18360 by default. Builders explicitly cap requested compute
at **900,000 CU**, preserving existing lower limits. This leaves 500,000 CU below
the runtime maximum of 1,400,000; it does not waive a requirement to measure the
heaviest operation. `cache/sol-t9/<mode>-compute-metrics.jsonl` records simulation CU and
event-data counts. Operation-budget JSON enumerates local payer debit, fees,
failure/ALT overhead and modeled priority fees. Legacy mode includes the V1
fixture-only swap; it never substitutes for signed V2 production acceptance.
Rebuild the production ELF immediately after legacy mode.

Solana read-only mainnet sample, October 7, 2026 15:08:04 UTC, finalized slot
454258587, exactly 1× capacity:

| Item | Lamports | SOL |
| --- | ---: | ---: |
| Program account, 36 bytes | 833,120 | 0.000833120 |
| ProgramData, 984,253 bytes | 5,000,655,480 | 5.000655480 |
| Modeled successful upload/deploy fees, 1,028 transactions | 5,177,761 | 0.005177761 |
| Modeled initial deploy funding | 5,006,666,361 | **5.006666361** |

Priority price is an operational sample, not a protocol rule: 10,000
micro-lamports/CU, exceeding the sampled unlocked-account 75th percentile (zero,
150 recent samples). Resample account contention before go. `getFeeForMessage`
quotes representative unsigned loader messages with measured Agave CU limits;
960-byte chunks and shared payer/authority match the earlier loader study. The
funded Buffer rent is **reused** as ProgramData funding, not added twice. This
is a reproducible fee model, not a guarantee of exact future expenditure; failed
uploads, resigns, congestion and CLI changes add fees. CLI deployment requests
explicit `--max-len`, `--with-compute-unit-price`, `--use-rpc` and no auto-extend.

**Combined key funding is not complete:** add measured peak Manager/keeper
operational rents and priority fees, then a founder-approved retry reserve.
Fixture airdrops/USDC seed capital are not fee budgets. At this priority price,
one single-signature 900k-CU action costs 14,000 lamports before rent or protocol
message fees. The Fund holds no SOL, rent refunds go to payer, never NAV
(DEC-195). `TODO(decision)`: approve demo action counts, retry reserve and total
funding; do not silently invent a 0.3-SOL or other allowance.

Fresh EVM fork pins used for factory evidence: Arbitrum **512600742**, Robinhood
**82566955**. Each deploy script is invoked without Foundry `--broadcast`:
`DeploySolanaV6`, `DeploySolanaFundV6`, `DeployFactory`, `CreateFund` and
`CheckAlphaDeployment`, on both chains. Unsupported Fund/verification invocations
fail closed when approved factory/calldata/Manager inputs are absent. Legacy
factory rehearsal is comparison evidence, NOT an additional required deployment.

| Required factory | Estimated script gas | Current L1-inclusive funding model |
| --- | ---: | ---: |
| Arbitrum v6, 27 transactions | 100,400,891 | 0.002063923586226 ETH |
| Robinhood v6, 15 transactions | 58,949,436 | 0.001203711353302 ETH |

Both chains use Nitro NodeInterface `gasEstimateL1Component` at `0x...00c8`.
Use each transaction's calldata/create flag and sampled base price; add the
L1-only quote to the dry-run gas-limit cost. Gas limits may already include an
L1 buffer, so this is conservative funding, **not exact L1-inclusive receipt
cost**. Legacy comparison models: Arbitrum 0.001610932325048 ETH; Robinhood
0.000910664223844 ETH. Do not sum legacy and v6. Per-Fund v6 creation/seed and
Robinhood new-Fund creation remain unverified pending signed commitments and
approved factories. No complete exact EVM launch total can be claimed yet.

### Ordered founder runbook — only after separate authorization

1. **Freeze source and approve configuration.** Merge the reviewed integration
   and record its full commit; pin both fork blocks, CLI/compiler versions,
   EVM public signer, API signer/registry owner, protocol recipient/guardian,
   finalized report max age, stock pricing max ages (24/7, R9.1) and Solana identity.
   API-only keys remain server-side (DEC-201/202). Review TSLA/NVDA/SOL feeds and
   effective multipliers (DEC-198); stock swaps remain unavailable without an
   admitted fresh Solana oracle (DEC-203/204). Preserve 500-bps management cap
   for this MVP; production correction is separate (DEC-196).
2. **Build and run every gate above.** Archive hashes, release manifest,
   complete successful/failed logs, clone slots and budgets. No broadcast. A
   failed production/composed gate is NO-GO, not a warning to ignore.
3. **EVM factory dry run with the REAL public deployer address.** Use the same
   signer on Arbitrum and Robinhood; deterministic linked libraries/code stores
   and factory addresses depend on signer/nonce. The T9 `0x...14` simulation
   identities are test-only. Set `PRIVATE_KEY` from `.env.alpha` only for the
   separately authorized send. Use both new-version factories, not legacy.
4. **BROADCAST EVM factories**, signed by the `.env.alpha` deployer:

   ```sh
   export PP_EVM_FOUNDER_APPROVED=YES
   export PP_EVM_APPROVED_COMMIT="$APPROVED_SOURCE_COMMIT"
   bash script/solana-evm-deploy.sh arbitrum factory-v6 --broadcast
   bash script/solana-evm-deploy.sh robinhood factory-v6 --broadcast
   ```

   The wrapper refuses sends without the flag, approval parameter, exact clean
   source commit and verified destination chain.
   After each receipt: verify chain id, deployed runtime hashes, EIP-170 sizes,
   factory owner/wiring, linked libraries, creation-code stores/hashes,
   `CoreVaultCctpLogic`, `ManagerRegistry` and `SolanaPriceSourceV6` feeds. Compare
   read-only RPC code to the exact linked dry-run artifact; record all addresses
   in a reviewed public runtime manifest. No module may point at old factory
   code by accident. Output to API: factory, registry owner/address, price source,
   Core logic/code hash, chain/RPC configuration; frontend: chain ids and factory
   addresses, not signing keys or authenticated RPC credentials.
5. **Approve Solana release**, after identity correction and production rebuild.
   Copy `script/solana-mainnet-approval.json` to a founder-controlled file outside
   the repo. Populate `FOUNDER_APPROVED`, approver/timestamp, source commit,
   program id, ELF/IDL hashes, exact bytes as `maxLen`, authority, sampled priority
   price and combined wallet funding minimum. A clean source checkout and matching
   build provenance are mandatory. Do not commit approval into a source commit
   that then invalidates the approved source hash.
6. **BROADCAST initial Solana program**, signed by `.env.solana` key; program-id
   signer supplies the persistent deployment identity, Buffer signer permits
   recovery. No random/mainnet signer is generated by this package:

   ```sh
   set -a; . "$SOLANA_ENV_FILE"; set +a
   export PP_DEPLOY_APPROVAL_FILE="$FOUNDER_APPROVAL_FILE"
   export PP_DEPLOY_PROGRAM_KEYPAIR="$PROGRAM_SIGNER_FILE"
   export PP_DEPLOY_BUFFER_KEYPAIR="$BUFFER_SIGNER_FILE"
   node solana/scripts/deploy-mainnet.mjs --broadcast
   node solana/scripts/deploy-mainnet.mjs --verify
   ```

   `SOLANA_MAINNET_RPC` must be explicit HTTPS and have mainnet genesis hash.
   `SOLANA_DEPLOYER_PRIVATE_KEY` accepts 64-byte JSON/base58 keypair parameters,
   is never printed, and is removed from CLI child environment. Temporary payer
   file is 0600 and deleted; program/buffer files are retained externally. The
   script refuses existing programs/buffers, scaffold id, mismatched bytes/hash,
   source, IDL, authority, funding or capacity. Verification reads the loader-v3
   Program and ProgramData owners/layouts, executable bit, exact ELF/capacity and
   upgrade authority. No on-chain IDL account is created. Output to API/keeper:
   program id, ProgramData address, deployment hash/authority, IDL JSON/types;
   frontend: program id, IDL, network and public Manager key only.
7. **Create the new three-chain Fund**, after approved factory addresses are
   pinned. Obtain genuine EOA EIP-712 consent plus fixed per-Fund Solana acceptance
   over the creation-committed mandate/policy, derived PDA/ATAs, nonce and expiry
   (DEC-190/200). The API must produce reviewed committed creation calldata,
   never substitute fixture signatures. Dry-run `arbitrum fund-v6` first; then
   send with the Manager signer required by the reviewed calldata. A deployer
   signature alone is not a Manager authorization. The current `CreateFund`
   script is legacy and is **not** a three-chain v6 Robinhood creation builder;
   coordinator must provide/verify the committed Robinhood path before this step.
   The factory atomically creates Core v6, native registry, receiver and per-Fund
   CCTP adapter/receive connector; never deploy those as unattached shared contracts.
8. **Initialize/seal/register all spokes.** Verify Hub Core/fund id, full Mandate
   and policy hashes, fixed Manager key, spoke indices, all derived vault/ATAs,
   adapter admissions, canonical ledgers, CCTP domain/sender/caller and Hub emitter.
   Verify Hub native emitter registration and Solana consistency 32; verify the
   5-bps immutable Fast ceiling (scaled Hub `maxFeeBps=50000`), no silent fallback
   and receive-and-credit wrapper caller both ways (DEC-191/199). Do not expose
   capital/orders/reports until the sealed-route/emitter checks pass. API/keeper
   config: all per-Fund Core/spoke/receiver/connector/registry addresses, CCTP
   domains, Wormhole chain/emitter, policy/mandate, signer public keys, ledgers,
   ATAs, report max age, per-action CU/priority budget. Frontend: public Fund
   discovery, Manager wallet binding, available admissions and manual receive
   trigger. No API secret, private key or provider URL enters the frontend.
9. **Configure relays and demo capital only after go.** Keeper pays CCTP receives
   and Wormhole relays; Manager pays actions/rent (R8 one key, DEC-195). Persist
   transit ids/nonce/message/attestation/status before retries; manual API/UI
   fallback calls the same atomic wrapper. In-flight remains amount minus maxFee,
   credits unspent fee on arrival, is never written off and blocks closure while
   pending (DEC-191/205). Indexer must consume successful business events and
   finalized v6 reports. Observe nonzero fees separately from principal; quarantine
   farm rewards (DEC-193/206). Zero Fund SOL remains mandatory.

### Recovery and rollback

- Before any send, rollback is simply NO-GO; keep immutable manifests/evidence.
- Partial initial upload: preserve Buffer signer/address; inspect loader owner,
  authority, funded bytes and ELF before explicitly resuming the same buffer or
  closing it. The initial-send wrapper intentionally refuses implicit resume;
  `--recover-prefunded` (2026-10-11) resumes only from a complete reviewed-ELF buffer.
  `solana program close "$BUFFER_PUBLIC_ADDRESS" --authority "$PAYER_SIGNER_FILE"`
  can recover funded Buffer rent to the authorized recipient; fees are spent.
- Program rollback: prefer reviewed upgrade of the same persistent id. At 1×,
  a larger ELF requires explicit finalized `solana program extend`, rent delta,
  then upgrade in a later slot. Buffer funding is temporarily needed while old
  ProgramData rent stays locked; successful upgrade spills/refunds Buffer rent.
  Do not assume extension delta alone is enough liquid SOL. Reverify bytes,
  authority, code hash, IDL/config and indexer after any change. A prior ELF may
  not be ABI/state-compatible with accounts already initialized; review first.
- Destructive `solana program close "$PROGRAM_ID" --authority "$PAYER_SIGNER_FILE"`
  recovers ProgramData rent, **not** transaction fees or the 36-byte Program
  account's rent. Closed loader-v3 identity cannot simply be redeployed; this
  strands operational callers. Never close a program with capital or pending
  CCTP. Closing does not recover vault tokens; route their principal through
  authenticated exits and complete every transit first (DEC-205).
- EVM deployments are immutable: do not relabel or mutate existing Funds.
  Stop API/keepers from admitting new capital; preserve pending claims and
  receipts; use a reviewed new-version deployment and new-Fund creation. Never
  infer a migration rule for existing capital (DEC-188).
- Recoveries/authority changes are transactions and require separate founder
  approval. Revocation before clients is irreversible; do it only after that
  explicit gate and verification (DEC-189).

### Go/no-go checklist

- [ ] Approved persistent Solana identity; exact clean source, ELF/IDL hashes,
      toolchain, 1× capacity and public authority verified.
- [ ] Rust, SBF, npm, TypeScript, default clone, signed V2 production and full
      composed gates pass on final source; heaviest CU comfortably below 1.4M
      with explicit budget; transaction packets fit including budget instructions.
- [ ] Genuine same-Fund three-chain consent/creation correlation; EVM composed
      pricing test passes; v6 Robinhood creation path exists and is rehearsed.
- [ ] Both factory and actual per-Fund scripts succeed on explicit fresh forks
      with real public signers; complete L1-inclusive and SOL role funding approved.
- [ ] CCTP Fast 5 bps, receive caller, sealed routes/emitter registration,
      consistency 32, common max age and fixed Manager key verified.
- [ ] Feed/multiplier/oracle admissions reviewed; unavailable stock swaps have no
      placeholder price/impact, no disabled security check (DEC-203/204).
- [ ] API/keeper/frontend manifests complete; event-data indexer works with
      no instruction-name logging and no on-chain IDL account.
- [ ] Retry/manual arrival recovery and nonzero-fee/principal segregation tested;
      no pending claim is discarded and Fund cannot close while in flight.
- [ ] Founder separately authorizes mainnet commands/funding; closed-team demo
      only, no client capital; upgrade revocation recorded as pre-client gate.

### T9 verified gate results

The optimized legacy composed clone completed **15 measured operations**, a
2,176-byte report and zero assertion failures. Heaviest: Raydium close
**497,949 CU**, 35.57% of 1.4M, with **902,051 CU** runtime headroom and
402,051 CU below the explicit 900k builder limit. Largest measured packet:
952 bytes. This uses a fixture-only V1 ratio leg; it is not production V2 proof.
Production SBF rebuilt afterward to the same 984,208-byte ELF. Default clone
first run: 42/42. The release IDL smoke verifies an absent on-chain IDL account
and `IdlInstructionStub` rejection while JSON/types remain generated.

Signed V2 first run failed unsigned simulation with an invalid ALT index.
The fresh final retry **PASS** includes signed swap + open at **448,247 CU /
799 bytes**, collection of **10 raw USDC fees with principal unchanged**,
a **1,952-byte report with NVDAx multiplier witness**, and position close.
Maximum production CU is **497,519**, below the explicit 900k limit. Bounded
warm-up retry only retries the exact unsigned ALT failure. Hub composed fork failed setup
with `TokenNotPriced`; factory and TSLA/NVDA/SOL feed forks passed. These are
NO-GO gates, not authorization to skip a test.

`TODO(decision)`: demo retry/reserve budget and unresolved stock oracle source.
Coordinator requests: persistent program identity; signed creation and approved
factory manifests; production ALT harness readiness; composed Hub pricing fix;
v6 Robinhood builder; jointly correlated three-chain acceptance. Do not interpret
this runbook or a passing factory simulation as closing these gates.

Primary-source reference locators (no authenticated endpoints):

```text
https://docs.arbitrum.io/arbitrum-essentials/nodeinterface/reference
https://docs.robinhood.com/chain/gas-and-fees/
https://solana.com/docs/programs/deploying
```

## Finish-work safety and default suite

Local deployment is opt-in: `node solana/scripts/deploy-local.mjs --broadcast`.
Without that explicit flag, even a valid supplied key cannot submit transactions.
It remains loopback-only; this flag does not authorize any mainnet deployment.
Per-Fund creation refuses an unapproved destination: `arbitrum.approvedFactory`
in the committed manifest is the zero address until a reviewed deployment identity
is pinned, and `DeploySolanaFundV6` reverts `FactoryNotApproved()` on it (CR-35;
`FactoryNotPinned(supplied, approved)` for any other address).
Never substitute an arbitrary environment address for that approval.

Default cloned tests require `node tests/core/prepare-fixtures.ts` before starting
the plain-build validator. `npm run test:localnet` excludes the explicitly named
pending set in `solana/scripts/pending-localnet-tests.ts`, printing every path and
reason. Coverage is preserved unchanged; `node scripts/run-localnet-tests.ts --pending`
runs it separately, but is NOT acceptance. Legacy CCTP/Kamino/Raydium genesis lacks
the sealed assets/transport fields; T8b must reconcile it. V1 composed/probe and
Streams fixtures require separate genesis/builds and T8c V2 replacement. They
must not be claimed green or silently mixed into the core/report genesis.
Use isolated ports 8970/9970/17000/17001–17060 for this run.
The core fixture send helper retries only unsigned preflight failures reporting
`Program cache hit max limit`, bounded to 20 attempts and five-second backoff;
it never retries a submitted transaction or masks an economic/ABI failure.
Replaying stateful local tests requires restarting the owned validator from
genesis; a second discovery run against mutated state is not an independent gate.

Later founder rulings DEC-203/204 seal the on-chain reference mode and prohibit
placeholder impact; only stock oracle source admission remains open. DEC-205
requires all CCTP transits credited before closure; DEC-206 quarantines farm
rewards on exit. T8b/T8c still own implementation and acceptance; none of these
decisions is invented or implemented by deployment tooling.
The full EVM gate uses `forge test --threads 1`: legacy deployment tests call
`vm.setEnv` on process-global operator settings and can race at default suite
concurrency. All suites still execute; none is excluded. Supply an explicit
`CCTP_ARBITRUM_FORK_BLOCK` as well as both chain fork pins. Public providers can
expire historical state; refresh pins explicitly and record them, never use latest.

Measured October 7, 2026, 11:40–11:48 UTC; integration baseline `c8be6be`.
**NOT APPROVED FOR MAINNET. No mainnet transactions were submitted.**
This packet has verified factory dry runs and local loader deployment costs,
not a complete three-chain production acceptance or exact total launch budget.
DEC-188/189/190/191/192/193/194/195/196/198/199/200/201/202 apply.

## Reproducible tooling

| Path | Responsibility |
| --- | --- |
| `script/SolanaV6Deployment.sol` | Shared tested new-version factory deployment, explicit v6 linking and EIP-170 checks |
| `script/DeploySolanaV6.s.sol` | Factory simulation on Arbitrum and Robinhood |
| `script/DeploySolanaFundV6.s.sol` | Arbitrum per-Fund simulation using externally reviewed Manager-signed calldata |
| `script/solana-v6-dry-run.sh` | Public, pinned, throttled RPCs; no broadcast/key arguments |
| `script/solana-v6-budget.mjs` | Integer gas × sampled gas-price execution-cost arithmetic |
| `script/solana-v6-addresses.json` | Research-verified protocol candidates; unresolved program identity/oracle explicitly not admitted |
| `script/solana-three-chain-rehearsal.sh` | Separate EVM/native legs, NOT a correlated shared Fund |
| `solana/scripts/deploy-local.mjs` | Local-only buffer → deploy, deployer authority and ELF verification |
| `solana/scripts/deploy-budget.mjs` | Local validator rent measurements for 1×/2× capacity |
| `test/fork/deployment/SolanaV6Deployment.fork.t.sol` | Same factory/predicted spoke identities on both public forks |

Existing legacy deployment scripts remain unchanged. New factory salt is
`keccak256("pool-party.v2.solana-v6.FundFactory")`; use the SAME operator address
on both EVM chains. v6 creation-code stores and linked library identities must
match the final approved build. The unchanged legacy `FactoryDeployment` helper
provides venue wiring, library linking and code stores, not the legacy factory.
The v6 factory constructor requires native registry creation code on BOTH chains.
Do not deploy CCTP connector/adapter as standalone shared contracts: the factory
creates them per Fund, atomically with Core v6, registry and receiver (DEC-191/199).

```sh
git submodule update --init --recursive
forge build
ARBITRUM_FORK_BLOCK=512553166 ROBINHOOD_FORK_BLOCK=82445811 \
  bash script/solana-v6-dry-run.sh
node script/solana-v6-budget.mjs
node --test script/solana-deployment-safety.test.mjs
```

The public RPC endpoints are the ones in `docs/INTEGRATIONS.md`. Foundry uses its
default on-disk RPC cache; do not disable storage caching or rate limiting.
The runner sets 30 assumed provider compute units/second and 3-second retry
backoff. Never silently replace a pinned block with `latest`.
The original Arbitrum pin 512239244 failed with `missing trie node`; Robinhood
82439071 failed with `historical state ... is not available`. Explicit recent
pins above passed; Foundry's existing local cache also allowed older Hub tests.
Cold public archive availability is NOT guaranteed by those passing cached tests.

## EVM cost evidence

Sampled `eth_gasPrice` during the successful public dry runs:

| Chain / pin | Foundry estimated gas | Sampled gas price (wei) | Gas × price (ETH) | Foundry required ETH |
| --- | ---: | ---: | ---: | ---: |
| Arbitrum / 512553166 | 94,389,550 | 20,052,000 | 0.001892699256600000 | 0.003792949771589550 |
| Robinhood / 82445811 | 55,651,352 | 20,038,000 | 0.001115141791376000 | 0.002238965249315352 |

Post-fetch final replay at 11:47–11:48 UTC also passed both scripts. Gas estimates
were unchanged. New samples were 20,000,000 wei (Arbitrum) and 20,120,000 wei
(Robinhood), giving **0.001887791000000000 ETH** and
**0.001119705202240000 ETH** respectively. This observed drift is why the
October 9 funding packet must be refreshed rather than treating one quote as fixed.

Both commands printed **SIMULATION COMPLETE** without `--broadcast`.
Foundry's estimate includes its default gas-estimate multiplier; these are
simulation estimates, not transaction receipts or final execution-gas invoices.
The final column uses Foundry's own script gas-price estimate, not the separate
single RPC sample used for the arithmetic column. These prices are observations,
not a promise of October 9 prices. USD conversion is deliberately omitted.

**Incomplete exact total:** the table excludes Manager Fund-creation calldata,
Robinhood `createSpoke`, USDC approval, binding/acceptance, allocations, keeper
relays, capital returns and both chains' L1 data fees. Arbitrum-family execution
gas × L2 gas price alone is not a complete transaction fee budget. Refresh the
whole packet and obtain L1-inclusive estimates on the final signed transaction
bytes before requesting a precise ETH funding amount. Do not fund from this
partial subtotal as though it covered launch.

`DeploySolanaFundV6` requires `SOLANA_V6_FACTORY` plus
`SOLANA_V6_CREATION_CALLDATA_FILE` containing hex ABI calldata for `createFundV6`.
It validates the destination code and selector and does not construct a guessed
Mandate or binding. Simulate it with the actual Manager as `--sender`; final
calldata is blocked by the coordinator's DEC-200 commitment/address issue below.
The per-Fund script therefore has **no successful dry-run evidence yet**.

Measured runtime sizes (repository optimizer; no code-size override):
CoreVaultV6 23,021; FundFactoryV6 22,760; ValueReportReceiverV6 15,333;
CctpBridgeAdapter 4,230; CctpReceiveConnector 4,521 bytes.
Recheck linked runtime AND constructor-inclusive EIP-3860 sizes after integration.

## Solana rent and deployer funding (local-validator rent — historical, never a mainnet budget)

Plain `anchor build` succeeded, no rehearsal-only feature. Local ELF:

- Size: **1,055,688 bytes**.
- SHA-256: `65c351f82fa7a181b56accee4d281934a8ceb8568b360ce984bfb65d8bcbf829`.
- Production program identity is still the coordinator's scaffold placeholder.
  Replacing the identity/rebuilding invalidates this binary hash and funding packet.

`getMinimumBalanceForRentExemption` on the local Agave 2.3.0 validator:

| Component | 1× max-len (SOL) | 2× max-len (SOL) |
| --- | ---: | ---: |
| Program account (36 bytes) | 0.001141440 | 0.001141440 |
| ProgramData (45-byte header + capacity) | 7.348792560 | 14.696381040 |
| CLI-funded buffer, measured balance | 7.348792560 | 14.696381040 |
| Conservative simultaneous rent sum | 14.698726560 | 29.393903520 |
| Actual successful deployer total debit | **7.355174000** | **14.702762480** |
| Actual fees above final Program + ProgramData rent | 0.005240000 | 0.005240000 |

Capacity is 1,055,688 or 2,111,376 bytes. Both modes submitted actual LOCAL
`write-buffer` and `deploy` transactions and verified loader-v3 ownership,
executable status, stored deployer upgrade authority and every ELF byte.
The actual buffer data length was 1,055,725 bytes for both modes (37-byte buffer
header + ELF). Agave funded it using the larger ProgramData rent/capacity amount;
using just the minimum 37-byte header formula underbudgets this CLI path.
Deployment consumed/reused buffer funds, so the conservative simultaneous sum
is NOT the actual amount debited. No priority fees were added in these runs.
Rent/base-fee policies and final binary may change: rerun against the final build.

No production secret file was opened. Validation used generated local deployers
passed in memory as `SOLANA_DEPLOYER_PRIVATE_KEY`. The local script rejects an
empty variable, malformed key, credentials in URLs and every non-loopback RPC.
It writes temporary 0600 signer files, deletes the variable from CLI child env,
suppresses CLI failure output, verifies authority, and deletes files in `finally`.
On failure, a buffer may remain on LOCAL validator; restart that owned validator
instead of assuming its rent was recovered. Mainnet automation is intentionally
not enabled. An approved future script must retain/recover failed buffer identity.

Rafael may LOAD `.env.solana` through a non-echoing wrapper after separate approval;
do not print/source-display secrets or pass key bytes in command arguments.
Never test mainnet reachability by sending a transaction.

## Manager and keeper wallets — remaining budget gate

DEC-195: Manager pays own SOL transactions/position rent, keeper pays transport
receives and Wormhole posts; Fund vault holds zero spendable SOL, rent refunds
return to the payer, never NAV. No Fund-owned SOL reserve is proposed.

Core/report localnet measured two Wormhole posts at 61,123 CU each and a
**100-lamport message fee** each at the cloned state. That is not the entire
keeper cost: transaction signatures, priority fees, CCTP rent/receives, retries
and report-account rent remain separate. The full composed program lifecycle is
not production-ready on this build. Exact Manager/keeper funding is therefore
**UNVERIFIED**, not zero and not a made-up fixed wallet balance.

Before funding, record each action's actual payer balance delta and refunded
rent, configured number of reports/receives, maximum retry count, priority-fee
cap and safety margin. Sum per payer, not into NAV. No founder DEC fixes counts
or funding margin; those are operational inputs requiring approval. Refresh
the deployer totals above after the final program identity/ELF is fixed.

## What the tests actually establish

| Check | Result |
| --- | --- |
| Repository Foundry build | PASS, existing warnings |
| Plain native SBF/IDL build | PASS, existing warnings; no rehearsal feature |
| Deployment safety | 4/4 PASS |
| Offline scaffold Node | 7/7 PASS |
| Hub Solidity native v6 unit suites | 34/34 PASS |
| Same v6 factories/identity predictions across two public forks | 1/1 PASS |
| Arbitrum CCTP/native accounting composed suite | 4/4 PASS |
| Arbitrum TSLA/NVDA/SOL Chainlink proxy suite | 2/2 PASS |
| Robinhood Across return/finalized report/live-V3 income suite | 3/3 PASS |
| Prepared native core/report, cloned mainnet localnet | 8/8 PASS |
| Unprepared global native discovery | 37 PASS / 21 FAIL; incompatible genesis fixtures/absent probe accounts |
| Local buffer + deploy + authority/ELF equality | 1× and 2× PASS |

Native clone harness: 62 base accounts from slots 454212179–454212424, then
documented core/report fixture extension; loopback RPC 8995, faucet 9995,
gossip 19500, dynamic 19501–19560. Snapshot collection is not atomic at one slot.
Core/report fixture preparation and tests use generated local Manager/keeper
keys; finalized report consistency is 32. The owned validator was stopped.

The existing Arbitrum composed suite creates/seeds a two-spoke Mandate, sends
to Solana through real Circle code on the fork, accepts local-guardian native
reports, tracks capped transit NAV and receives a local-attester return. Its
Robinhood spoke is declared but is not exercised in that same Fund. Separately,
Robinhood tests exercise Across and report publishing. **There is no proof here
of one Fund allocating to BOTH spokes, accepting BOTH correlated reports and
receiving both returns.** No genuine Circle attestation was fabricated or
represented as live: local attester overrides/generated fixtures are explicit.
Recorded native report bytes are existing fixtures, not correlated fresh native
transactions into this deployment. `solana-three-chain-rehearsal.sh` says this
explicitly and never claims a complete three-chain lifecycle.

Do not run the global discovery runner as acceptance: track fixtures and swap
probe/verifier genesis requirements differ. The explicitly named pending runner
preserves that coverage separately; the default runner executes only compatible
core/report, smoke and offline swap tests. The documented prepared core/report
suite passes independently. The existing full native rehearsal requires a
`rehearsal-v1-swap` build; it is NOT DEC-201/202 production V2 acceptance and
must NEVER become the deployment artifact.

## Coordinator requests / TODO(decision)

1. **DEC-200:** resolve the Fund PDA/Mandate/emitter commitment cycle, finalize
   EVM/native bootstrap consent, and provide reviewed Fund-creation calldata.
   No invented hash/PDA substitution is permitted by these scripts.
2. **DEC-202 / LC-173:** select and seal Solana reference-oracle and API-signed
   quote policy. Pyth candidates in the manifest are research facts, NOT approval.
   Production V2 swap remains a release gate; Manager price is not a substitute.
3. **DEC-198:** finish verified NVDAx admission/multiplier and three admitted LP
   choices in the final program/Mandate; current stock candidates are not evidence.
4. **DEC-189:** coordinator must replace scaffold program identity, rebuild and
   remeasure rent; actual upgrade authority remains Rafael's deployer until the
   pre-client-capital revocation gate. No shared program/contract files changed here.
5. Complete the shared three-chain Fund acceptance and Fund/Spoke deployment
   dry runs, L1-inclusive costs, Manager/keeper payer deltas and API/manual claim
   fallback before founder funding approval. T8b/T8c own logic fixes.
6. **R9.1 (founder, 2026-10-11):** stock pricing is 24/7. The on-chain value of the
   tokenized stock is what counts; there is no market-hours/session gate and no
   session input. The stock feeds' max age is the only time guard (stale fails closed).

## Ordered mainnet runbook — approval required before ANY execution

1. Coordinator merges reviewed tracks, freezes final source/toolchains, resolves
   the gates above and runs a complete correlated rehearsal. Record source SHA,
   ELF hash, linked EVM creation/runtime hashes and all verified protocol accounts.
2. Rafael approves the updated FULL funding packet and wallet roles. Funding:
   approximately 50 USDC seed, EVM operator/Manager native gas, dedicated Solana
   deployer, bound Manager Solana Key and keeper. Pre-launch wallet check must
   prove connected key, binding and sufficient SOL (DEC-190/195).
3. Rafael's EVM operator signs new v6 stack deployment on Arbitrum, then same
   operator deploys Robinhood v6 factory using identical approved build/salt.
   Verify factory identity, every code store/library and immutable wiring.
4. Rafael's Solana deployer signs buffer writes and deployment of the APPROVED
   program identity; deployer is upgrade authority (DEC-189). Verify ELF and
   authority on-chain; recover/close failed buffers to their payer if necessary.
5. Team Manager EOA signs USDC approval and exact reviewed Hub creation/seed
   with immutable Manager Solana Key commitment and all three chains. This
   creates per-Fund CCTP adapter/connector, receiver and native registry; hard
   Fast ceiling is 5 bps (DEC-199), management cap stays 500 bps (DEC-196).
6. Same Manager EOA signs Robinhood `createSpoke` with the emitted Mandate hash;
   Manager Solana Key countersigns native initializer plus EIP-712 consent over
   approved Fund PDA/ATAs, nonce/expiry and sealed routes/emitter (DEC-200).
7. Verify receiver/emitter registration and routes BEFORE capital allocation.
   Manager signs allocation to Robinhood Across and Solana CCTP V2 Fast.
   Keeper signs receive-and-credit and finalized reports; verify actual balances,
   `amount - maxFee` pending claims and no write-off (DEC-191/192).
8. Manager Solana Key signs Kamino supply, approved API-signed Jupiter V2 ratio
   swaps and existing Raydium positions. Manager pays rent/gas; no Fund SOL.
   Keeper relays both chains' reports; verify one reconciled share price/NAV.
9. Manager signs exits and capital returns. Keeper receives/credits, reports
   return state and retries; manager/API manual fallback remains available.
   Preserve pending claims, credit unused fee cap as principal and never write off.
10. Save signed transaction hashes, protocol receipts and decoded reports for
    judging. Closed-team upgradeable demo only; revoke upgrade authority BEFORE
    client capital, never claim present immutability (DEC-189).

This runbook describes signers/order; it is not an authorization or a supplied
mainnet command. Safe local scripts cannot be switched to mainnet via an env var.
