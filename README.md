# Arbitrum Open House Singapore

<p align="center">
  <img src="docs/assets/pool-party-logo.png" alt="Pool Party logo" width="96">
</p>

## Pool Party V2: live on mainnet

**A source-available On-Chain Asset Management System (OAMS), built during the Arbitrum Open House Singapore Buildathon and deployed on Arbitrum One, Robinhood Chain and Solana mainnet.** Managers create funds, commit to an immutable Mandate and operate DeFi positions. Investors access the fund through USDC-denominated shares on Arbitrum.

**This is a live mainnet internal alpha with real capital and confirmed transactions.** The evidence includes manager-funded creation, investor deposits, Aave supply, Uniswap swaps and liquidity positions, Across transfers and Wormhole value reports. The external security audit is planned next, followed by the public V2 launch. V2 has not yet been audited by an independent third party.

Pool Party already serves **more than 4,000 users** across its existing product, as reported by the founding team on October 4, 2026. This product-wide figure is separate from the number of participants in the V2 mainnet alpha.

![Arbitrum Open House Singapore: Pool Party Fund Contracts V2](docs/assets/arbitrum-open-house-singapore.jpeg)

[Live application](https://v2.dev.pool-party.xyz/en/manager/new) · [Public frontend](https://github.com/PoolPartyLabs/pool-party-v2-frontend) · [Latest strategy: transaction walkthrough](docs/evidence/2026-10-04-mainnet-fund-7.md) · [Machine-readable evidence](docs/evidence/fund-7-mainnet-2026-10-04.json)

The application uses the **V2** contract-family selector. Its mainnet alpha availability and the upcoming public launch are separate milestones. The banner is event artwork; the transaction links below are the execution evidence.

## Source availability and licensing

**All Pool Party-authored V2 contracts, factories, core/spoke libraries, adapters,
own interfaces, tests, scripts, harness, documentation and original assets,
including current work and future changes, follow
[Pool Party Source-Available License 1.0](LICENSE).** Study, local testing, paid
or unpaid audits, contribution forks and documented use of official deployments
are permitted. Independent adapters can interoperate with the official platform.
Separate production forks and commercial products/redistribution using restricted
material require prior express written authorization.

**All valid earlier MIT grants and third-party rights survive.** A changed SPDX
notice cannot revoke them. The current restricted license is not OSI-approved
open source. The [scope/history map](LICENSING.md),
[third-party notices](THIRD_PARTY_NOTICES.md) and [contribution policy](CONTRIBUTING.md)
identify the precise boundaries, including upstream code that retains its license.

This repository is public. The Solana program (Rust, Anchor) is in `solana/programs/pp_spoke` on the branch `feat/pp-sc-feat-solana-spoke`. See the [Solana source](https://github.com/PoolPartyLabs/smartcontract-v2/tree/feat/pp-sc-feat-solana-spoke/solana).

## Which parts of your code have been produced during the Buildathon?

**The new Pool Party V2 fund-contract system delivered in this repository was developed during the Buildathon window, September 14 to October 4, 2026.** Implementation started in this public repository on **September 29, 2026**. The first root commit is [`0943a185`](https://github.com/PoolPartyLabs/smartcontract-v2/commit/0943a185512fc7d0b7297dbcee06bf65e6f33b8c), timestamp **2026-09-29 19:55:57 UTC**. The mainnet alpha was deployed on **October 3, 2026**, from release [`797d592`](https://github.com/PoolPartyLabs/smartcontract-v2/commit/797d592).

| Developed during this Buildathon | What the code delivers | Public implementation |
| --- | --- | --- |
| Immutable fund Mandate | Fixed chains, tokens, position/swap adapters, pools, bridge routes and fund rules at creation; operations check the selected Mandate. | [Mandate](src/mandate/Mandate.sol), [factory](src/factory/) |
| Hub-and-spoke fund architecture | Core Vault and share accounting on Arbitrum; a Spoke Vault on each participating chain; deterministic factory deployment. | [Core](src/core/), [spokes](src/spoke/), [factory](src/factory/) |
| Protocol adapters | Uniswap V4 liquidity positions, Uniswap V3 execution swaps, Aave V3 supply and the Across bridge. | [Adapters](src/adapters/), [public interfaces](src/interfaces/) |
| Cross-chain accounting and messaging | Across moves capital between USDC and USDG. Wormhole carries authenticated value reports and order messages. | [Across adapter](src/adapters/AcrossBridgeAdapter.sol), [reporting](src/report/), [spoke execution](src/spoke/) |
| Fund lifecycle | Manager seed, deposits, whole-share accounting, fee limits, proportional payouts, income accounting and irreversible closure with frozen exits. | [Core implementation](src/core/), [tests](test/) |
| Validation and operating tools | Unit/fuzz/invariant and mainnet-fork tests, a two-chain local environment, deployment/verification scripts and dated execution reports. | [Test suite](test/), [local environment](local-e2e/), [deployment scripts](script/), [reports](docs/reports/) |
| New V2 frontend and API integration | Mandate → Build → Review → Launch, configuration panels, serial wallet signing/recovery, fund views and investor V2 presentation in the existing app. | [Public frontend V2 implementation](https://github.com/PoolPartyLabs/pool-party-v2-frontend/tree/main/src/features/manager/fund), [typed API integration](https://github.com/PoolPartyLabs/pool-party-v2-frontend/tree/main/src/lib/api/v2) |

The V2 code was written using established open-source dependencies, including OpenZeppelin, Uniswap, Wormhole and Foundry. Their upstream code is credited in [the dependency manifest](.gitmodules); it is not claimed as original hackathon work. Pool Party's existing app shell, wallet/auth, design system and provisioning foundation also predate this submission. The frontend's first public V2 implementation commit is [`ab884b4b`, October 3](https://github.com/PoolPartyLabs/pool-party-v2-frontend/commit/ab884b4b6c93542ab46054a5f19a352fbee5dad6).

## Mainnet integrations actually used

| Integration | Role in this Buildathon | Mainnet evidence |
| --- | --- | --- |
| **Arbitrum One, chain ID 42161** | Hub Core Vault, shares, USDC entry, Aave supply and fund accounting. | [Fund #7 creation](https://arbiscan.io/tx/0x7430f891fa244cbf10ff8b9d365a2af11399f657def8f3e70498e21741f5453d) |
| **Robinhood Chain, chain ID 4663** | Remote Spoke Vault, USDG capital and Uniswap liquidity operations. | [Fund #7 spoke creation](https://robinhoodchain.blockscout.com/tx/0x1785bd91cca6c955fbb12e65cba360128a425dc652ac9ed473b3993628c3d76d) |
| **Aave V3** | Supply USDC on Arbitrum. | [Fund #7 supplies 9.5 USDC](https://arbiscan.io/tx/0x070023ec9aa8ab89d13a5fa7d6f96bc56770c555ef9a85b17a4931aa9181c9b2) |
| **Uniswap V3** | Execution swaps through a dedicated swap adapter. | [Fund #1 USDG/WETH swap](https://robinhoodchain.blockscout.com/tx/0x25cb4e4d2ee294251af5b62a448bbba5561bce16bb39af2ef4f4f091cf333c2c) |
| **Uniswap V4** | Concentrated-liquidity positions through the position adapter. | [Fund #1 opens a WETH/USDG position](https://robinhoodchain.blockscout.com/tx/0x80a46b594efacc7566eb4b9d25bc0f6419d237847b13a374cb0c55736ce5129c) |
| **Across** | Capital transport: USDC on Arbitrum to USDG on Robinhood. | [Fund #7 send](https://arbiscan.io/tx/0x96f43b187fa38a88b333bbea45804f76aac6088305c216784a68d1399f0f171b), [fill](https://robinhoodchain.blockscout.com/tx/0x819a2ad0d17276b5d282b8498ff9e76148110614b1e9846404afe6ffca8d3679) |
| **Wormhole** | Cross-chain value reports; capital itself travels through Across. | [Report publication](https://robinhoodchain.blockscout.com/tx/0x9fdcf3cf38b17ba3ab28270f91ad9399ab0d7c32b89aa6a50837ab8b8ccb1dbc), [hub acceptance and arrival reconciliation](https://arbiscan.io/tx/0xbf96e721ef13520d38d67073cd74dffaeb62e21c85462483da1c7f2ea31b9c45) |
| **Circle CCTP V2** | USDC transfer from Arbitrum to Solana and back. | [Arbitrum burn](https://arbiscan.io/tx/0x658d7997329727e096568bc4a594db5d74c99178cadef63d9c67b282f3464e65), [Solana receive_and_credit](https://solscan.io/tx/2Z5ZhtDzmgncVg22hUp5kBJUa8FBffbfiz4RztUhgmru4vQoAtsjZ5QVGyDFVpPhQGHefWDMMvbj24CUhTN3FA93), [Solana send_to_hub](https://solscan.io/tx/2qeuNc6fZLKptk3Ky1de56JEJpVUBR2k9FHUs3UrFnmbwMGmxMcsjEeQccR68jwbrUaL6qihDsqrDVqe6k1B8wLk) |
| **Wormhole (Solana spoke)** | The Solana spoke reports its value to the Arbitrum hub. | [First report](https://solscan.io/tx/3ioETGECBDSxyWwBU5QWwBXvDPiro6F7C477zcUn5HHSQYi8cNNBwu1BBC4J5qSPtvoypivjkuASmhvYqgkKC2Zp), [Latest report read](https://solscan.io/tx/TCRYGSoYHwpEudRPKaLQp5c4TbnhQgFWgwYt44KcHyMgyc7K5KE1mjEmLvJushZUqfpZzr5g8F3Aqax61cq1ZrA) |
| **Kamino** | USDC lending on Solana. | [Supply 8.0 USDC](https://solscan.io/tx/3PBTvdAmr7paMBMC44W7fBqPqvjSVXVtWA3C3modpovtG16bpg2FM8KCaBRQotNqDqRHhhtk4R9KyTKbaXsBoNEC), [Redeem](https://solscan.io/tx/4Earaxom9uEon87hMJrYQkVgxjVtgYn6L5wKVi1Er2kvJtQNzfgXq684drTvYqZuJui1AeZfChvWoJ229ZrFRCho) |
| **Jupiter** | Swap to the pool ratio on Solana, and the reverse swap at unwind. | [Swap to ratio](https://solscan.io/tx/5EzNbYeYNmjkyZiN386dXWDDW4Hxonr8kRqJhEpAA3WJ4MMJ2w6WhT3F36R1WtRKGePWkqyKdNbiMyYXB3m6NBEF), [Reverse swap](https://solscan.io/tx/4rU3WuDuch9sPQ22Zdf2wcHUqYBojJ8Gp73ePWev2EnqjBw1ADdcfXQTMoX8ff1enoLn5hSss4Vp47ZnaKBo918E) |
| **Raydium CLMM** | SOL/USDC concentrated liquidity on Solana. | [open_position](https://solscan.io/tx/3HVhuV6cfQ4FEbr7goGFXEUVgprgcELxzLgCPBS15d5hnA3kB5f2sQKsYsgsDQX9DwX8V63VRcxayH78AyD3XXEN), [close_position](https://solscan.io/tx/31ytxodRuQUxvz2Y5kP4gPEFgRMV1WZCi3R9vXrYi6QnswP4sMFPqiv1SSYYgTecBHaADX6FK7qQcyzCFqz687cx) |
| **USDC, USDG and WETH** | Hub entry/accounting, spoke capital, and the paired asset used by liquidity positions. | Amounts, token identities and chain-specific roles are in the [evidence walkthrough](docs/evidence/2026-10-04-mainnet-fund-7.md). |

Uniswap V3 is used for **swaps**, not V3 liquidity positions. Aave is **supply-only on Arbitrum**. These are the integrations demonstrated during this Buildathon; roadmap protocols are not included in the delivered feature list.

### Latest created strategy: fund #7

The public factory scan found seven created funds and `nextCreationNumber() = 8`. **Fund #7 was created on October 4, 2026 at 14:23:03 UTC**. At the recorded October 4 observation bound:

1. The manager funded creation with **19.05 USDC**: **19 shares** minted and **0.05 USDC** paid to the protocol recipient.
2. **9.5 USDC** was allocated and supplied to Aave V3 on Arbitrum.
3. **3.8 USDC** was sent through Across; **3.766960 USDG** arrived in the fund's Robinhood Spoke Vault.
4. Wormhole reports were published and accepted on Arbitrum, including confirmation of the bridge arrival.
5. The fund was **Open**. Its Core Vault held **5.700000 USDC**, its Aave adapter **9.500043 aUSDC**, and its Robinhood vault **3.766960 USDG**.

These are recorded observations at **Arbitrum block 511654340 / Robinhood block 80049217**, not a continuously updating balance feed. Fund #7 had not executed a Uniswap V3 swap or V4 position at that bound. Those mainnet operations are independently demonstrated by fund #1, alongside a [second investor's real deposit](https://arbiscan.io/tx/0x05599c50c2c03cee9742451fa818177f5904aa2850dbb696eef09e5e9eb959e2).

**Read the [full 13-step transaction walkthrough](docs/evidence/2026-10-04-mainnet-fund-7.md)** for hashes, timestamps, contracts, snapshot bounds and the historical fund #1 evidence. The [JSON manifest](docs/evidence/fund-7-mainnet-2026-10-04.json) exposes the same facts for automated review.

### Solana spoke: first full cycle on mainnet

The Solana spoke ran one full cycle on October 12 and 13, 2026. All times are UTC.

1. The program was deployed on **2026-10-12 20:01:06 UTC**, slot 456,170,705 ([`48Cd7NaB…Cb1V`](https://solscan.io/tx/48Cd7NaBTWWCTsctRHzyfM4XPzPiuoMAho8ymtgFnXqMUJtLC1vBttEcjuLd3pvrrhp1u8DDp3gB8UvZEFG2Cb1V)).
2. The fund was initialized at **22:22:24 UTC** ([`5u1hNcBH…ahuB`](https://solscan.io/tx/5u1hNcBHWAYuYh5vcby62yhrk91HXVrPS6DZ5MbxFqyzXLyyDvXRxmNffvV7yF2PR372BwHpRapa4p7aJAp6ahuB)).
3. The Kamino and Raydium adapters were initialized at **23:12:42** and **23:12:56 UTC** ([Kamino](https://solscan.io/tx/2w4mmwsFDQjitRB2abek5WCjZgh5eFRsjfx9TRkFHd4nVSK3wexfbpVDA7o95GkmcSeawq27M9HUmWKF11rnCpAx), [Raydium](https://solscan.io/tx/4B77h4MHWVECnivgFAa2KozF12cTwNuC3vdochtQXnKdvaw914n8Eg1aKx9ToxXXWDW5pjeBvWqNkL912CwzzkGS)). The API built both transactions, and the guarded CLI signed them.
4. The Arbitrum hub burned **25 USDC** through Circle CCTP V2 at **23:13:21 UTC** ([`0x658d79…4e65`](https://arbiscan.io/tx/0x658d7997329727e096568bc4a594db5d74c99178cadef63d9c67b282f3464e65)). The booked maximum fee was 0.0125 USDC. The destination domain was 5.
5. `receive_and_credit` ran at **2026-10-13 00:05:51 UTC**, slot 456,237,897 ([`2Z5ZhtDz…FA93`](https://solscan.io/tx/2Z5ZhtDzmgncVg22hUp5kBJUa8FBffbfiz4RztUhgmru4vQoAtsjZ5QVGyDFVpPhQGHefWDMMvbj24CUhTN3FA93)). The Solana vault received **24.9965 USDC** (25 minus the Circle fee of 0.0035). The 0.009 USDC difference against the booked maximum fee goes back to the fund as fee surplus.
6. Kamino supply at **00:06:59 UTC**: 8.0 USDC in, 6,638,311 cTokens out ([`3PBTvdAm…oNEC`](https://solscan.io/tx/3PBTvdAmr7paMBMC44W7fBqPqvjSVXVtWA3C3modpovtG16bpg2FM8KCaBRQotNqDqRHhhtk4R9KyTKbaXsBoNEC)).
7. The Jupiter swap to the pool ratio ran at **00:25:51 UTC** ([`5EzNbYeY…NBEF`](https://solscan.io/tx/5EzNbYeYNmjkyZiN386dXWDDW4Hxonr8kRqJhEpAA3WJ4MMJ2w6WhT3F36R1WtRKGePWkqyKdNbiMyYXB3m6NBEF)). Raydium `open_position` ran at **00:26:03 UTC** with 0.078140903 SOL and 8.110584 USDC ([`3HVhuV6c…XXEN`](https://solscan.io/tx/3HVhuV6cfQ4FEbr7goGFXEUVgprgcELxzLgCPBS15d5hnA3kB5f2sQKsYsgsDQX9DwX8V63VRcxayH78AyD3XXEN)).
8. Wormhole: the spoke publishes a guardian-signed report about every 5 minutes. There were 56 reports, from 22:48:59 UTC on 2026-10-12 to 04:32:27 UTC on 2026-10-13 ([first report](https://solscan.io/tx/3ioETGECBDSxyWwBU5QWwBXvDPiro6F7C477zcUn5HHSQYi8cNNBwu1BBC4J5qSPtvoypivjkuASmhvYqgkKC2Zp), [latest report read](https://solscan.io/tx/TCRYGSoYHwpEudRPKaLQp5c4TbnhQgFWgwYt44KcHyMgyc7K5KE1mjEmLvJushZUqfpZzr5g8F3Aqax61cq1ZrA)). Shares mint and burn on the hub only on a fresh report.
9. The unwind ran from **02:15 to 02:16 UTC**: Raydium `collect_fees` (+39,421 lamports of wSOL, +0.004594 USDC) ([`5vcaSWjR…B6sw`](https://solscan.io/tx/5vcaSWjR5zPDQGnvEyQ1ia6u2pLg9HtS9iwxQbXB3WAwB8YzNwVbef1MU4xtRw7memfZuxxoez1EjnPdF6NXB6sw)), `close_position` ([`31ytxodR…87cx`](https://solscan.io/tx/31ytxodRuQUxvz2Y5kP4gPEFgRMV1WZCi3R9vXrYi6QnswP4sMFPqiv1SSYYgTecBHaADX6FK7qQcyzCFqz687cx)), the Jupiter reverse swap ([`4rU3WuDu…918E`](https://solscan.io/tx/4rU3WuDuch9sPQ22Zdf2wcHUqYBojJ8Gp73ePWev2EnqjBw1ADdcfXQTMoX8ff1enoLn5hSss4Vp47ZnaKBo918E)) and Kamino redeem (+8.0001 USDC) ([`4Earaxom…RCho`](https://solscan.io/tx/4Earaxom9uEon87hMJrYQkVgxjVtgYn6L5wKVi1Er2kvJtQNzfgXq684drTvYqZuJui1AeZfChvWoJ229ZrFRCho)).
10. `send_to_hub` ran at **02:16:25 UTC**. It burned 25.111857 USDC through Circle CCTP V2 back to Arbitrum ([`2qeuNc6f…8wLk`](https://solscan.io/tx/2qeuNc6fZLKptk3Ky1de56JEJpVUBR2k9FHUs3UrFnmbwMGmxMcsjEeQccR68jwbrUaL6qihDsqrDVqe6k1B8wLk)).

All 73 `pp_spoke` transactions finished without error. After the unwind, the vault holds 0.004694 USDC and 39,606 lamports of wSOL.

## Independent adapters for the official Pool Party platform

**Any developer can independently implement, test and contribute an adapter for
the official Pool Party platform.** Required interface/example use is permitted
by the license; the developer's independent code remains theirs. Previously
MIT-published interface portions retain their MIT grants. The current first-party
policy also covers our own interface changes and does not grant unrestricted
reuse of future restricted implementations. The integration contracts are public:

- [`IAdapter`](src/interfaces/IAdapter.sol): position operations, valuation, income collection and unwind parameters.
- [`ISwapAdapter`](src/interfaces/ISwapAdapter.sol): token swaps and execution bounds.
- [`IBridgeAdapter`](src/interfaces/IBridgeAdapter.sol): bridge quotes, send calldata and route behavior.
- [`IAdapterGuard`](src/interfaces/IAdapterGuard.sol): adapter pause/deprecation interface.

Start from the shipped [Uniswap V4](src/adapters/UniswapV4Adapter.sol), [Aave V3](src/adapters/AaveV3Adapter.sol), [Uniswap V3 swap](src/adapters/UniswapV3SwapAdapter.sol) or [Across](src/adapters/AcrossBridgeAdapter.sol) adapter. Add unit and mainnet-fork tests for the new integration, including valuation, destination restrictions and failure behavior, then submit a pull request.

A new adapter is a new integration, not an automatic change to existing funds. Each fund pins its approved adapters and pools in its **immutable Mandate at creation**. Extending the adapter ecosystem does not grant a developer permission to alter a live fund's Mandate or move its assets.

## Validation, audit and public launch

| Evidence | Recorded result | Scope |
| --- | --- | --- |
| Contract tests | **1,548 non-fork tests + 227 mainnet-fork tests, zero failures/skips** | Dated code baseline `334eae6`, in the [MVP report](docs/reports/2026-10-03-MVP-REPORT.md). Size tests are already included. |
| Two-fork end-to-end lifecycle | **55 steps, 319 assertions, 103 receipts** | Historical [PR #24](https://github.com/PoolPartyLabs/smartcontract-v2/pull/24) run. Local mainnet forks exercise the lifecycle; they are separate from the real mainnet receipts above. |
| Mainnet source verification | **24/24 Arbitrum, 11/11 Robinhood** | [Deployment record](docs/reports/2026-10-03-MVP-REPORT.md#deployment-checks-verification-and-report-timing): Arbiscan and Sourcify. Verification means source matching, not a security audit. |
| Live execution | Manager activity, investor deposit/payout, Aave supply, V3 swap, V4 position, Across fill and Wormhole report acceptance | [Transaction evidence](docs/evidence/2026-10-04-mainnet-fund-7.md) distinguishes the latest fund and the earlier smoke. |

The test counts are the published historical validation results for their stated commits. This documentation update does not claim a new suite run or treat local-fork receipts as mainnet transactions. Full closure, asynchronous payouts and income return paths have test coverage but are not claimed as completed mainnet demonstrations in this README.

**Next: independent external security audit, remediation and public V2 launch.** The team plans the audit soon; no auditor or completion date is announced here. Current contracts are live in an internal alpha. See [SECURITY.md](SECURITY.md), [known limitations](docs/security/KNOWN-LIMITATIONS.md) and the [threat model](docs/security/THREAT-MODEL.md).

## Deployed contract addresses

The alpha infrastructure below is deployed on mainnet. These are factory, implementation and library addresses, **not instructions to transfer funds directly**. Individual funds have separate vaults, adapters and share tokens; fund #7's complete inventory is in the [evidence document](docs/evidence/2026-10-04-mainnet-fund-7.md).

### Same address on Arbitrum One and Robinhood Chain


| Contract | Address | Explorers |
| --- | --- | --- |
| FundFactory | `0x2CDB1f3fa95F8A65495D01D20AD53cF980728534` | [Arbitrum](https://arbiscan.io/address/0x2CDB1f3fa95F8A65495D01D20AD53cF980728534) · [Robinhood](https://robinhoodchain.blockscout.com/address/0x2CDB1f3fa95F8A65495D01D20AD53cF980728534) |
| Create3Deployer | `0x1Da47CED247a6776329281836600283b033f8e41` | [Arbitrum](https://arbiscan.io/address/0x1Da47CED247a6776329281836600283b033f8e41) · [Robinhood](https://robinhoodchain.blockscout.com/address/0x1Da47CED247a6776329281836600283b033f8e41) |
| TransitEscrow implementation | `0xfFDc3EdE1D43678dDe55E98fb924a81dCA26383F` | [Arbitrum](https://arbiscan.io/address/0xfFDc3EdE1D43678dDe55E98fb924a81dCA26383F) · [Robinhood](https://robinhoodchain.blockscout.com/address/0xfFDc3EdE1D43678dDe55E98fb924a81dCA26383F) |
| SpokeCrossChainLib | `0x3341467fd9F8Ce784D77348bEa276cE80EB57693` | [Arbitrum](https://arbiscan.io/address/0x3341467fd9F8Ce784D77348bEa276cE80EB57693) · [Robinhood](https://robinhoodchain.blockscout.com/address/0x3341467fd9F8Ce784D77348bEa276cE80EB57693) |
| SpokeUnwindLib | `0xfea626E44de1d2d7A01935A485399e992725351D` | [Arbitrum](https://arbiscan.io/address/0xfea626E44de1d2d7A01935A485399e992725351D) · [Robinhood](https://robinhoodchain.blockscout.com/address/0xfea626E44de1d2d7A01935A485399e992725351D) |
| SpokeCloseLib | `0xFCADfa1b5bCD4eDCa95220E07661795Efa883035` | [Arbitrum](https://arbiscan.io/address/0xFCADfa1b5bCD4eDCa95220E07661795Efa883035) · [Robinhood](https://robinhoodchain.blockscout.com/address/0xFCADfa1b5bCD4eDCa95220E07661795Efa883035) |
| SpokeIncomeLib | `0xCB8Ece6A3A1FCB80083eD1c8B7c7b6e85B14Dc5B` | [Arbitrum](https://arbiscan.io/address/0xCB8Ece6A3A1FCB80083eD1c8B7c7b6e85B14Dc5B) · [Robinhood](https://robinhoodchain.blockscout.com/address/0xCB8Ece6A3A1FCB80083eD1c8B7c7b6e85B14Dc5B) |

### Arbitrum One only

| Contract | Address / Arbiscan |
| --- | --- |
| ManagerRegistry | [`0xd6671dc995e6d5F2F7f65ea05a513738907737cE`](https://arbiscan.io/address/0xd6671dc995e6d5F2F7f65ea05a513738907737cE) |
| ChainlinkPriceSource | [`0xd1E43765FCb66515cd8Cf0Ede73dFF2E4bF249bF`](https://arbiscan.io/address/0xd1E43765FCb66515cd8Cf0Ede73dFF2E4bF249bF) |
| CoreVaultLogic | [`0x43Ddb24ac75Cffa09f0849DDD71a78F7e9C3068d`](https://arbiscan.io/address/0x43Ddb24ac75Cffa09f0849DDD71a78F7e9C3068d) |
| CoreVaultTransitLogic | [`0x6E6b2461628008C5E496c480860C675c33fe957D`](https://arbiscan.io/address/0x6E6b2461628008C5E496c480860C675c33fe957D) |
| CoreVaultIncomeLogic | [`0x593BF11bf8e3b2F795bbC538AEe1d59f8D4D55B8`](https://arbiscan.io/address/0x593BF11bf8e3b2F795bbC538AEe1d59f8D4D55B8) |
| CoreVaultIncomeCollectionLogic | [`0x4a0ae1f3017F6869Bc3B24CD69d0b501BA93FACa`](https://arbiscan.io/address/0x4a0ae1f3017F6869Bc3B24CD69d0b501BA93FACa) |
| CoreVaultPayoutLogic | [`0xFaa7d44e670570CaB3346522f55D1b25408D05e8`](https://arbiscan.io/address/0xFaa7d44e670570CaB3346522f55D1b25408D05e8) |
| CoreVaultClosureLogic | [`0x75997F8b180e20695c58fF519D672CFA9274E028`](https://arbiscan.io/address/0x75997F8b180e20695c58fF519D672CFA9274E028) |


### Latest fund #7: primary contracts

| Contract | Network | Address / explorer |
| --- | --- | --- |
| Core Vault | Arbitrum One | [`0xa653f620ea8f5539ed4bb55be2977262fba1f2dc`](https://arbiscan.io/address/0xa653f620ea8f5539ed4bb55be2977262fba1f2dc) |
| Share token | Arbitrum One | [`0x25f02c58e916ec7796771105c7dbd65d1993d83d`](https://arbiscan.io/address/0x25f02c58e916ec7796771105c7dbd65d1993d83d) |
| Hub Spoke Vault | Arbitrum One | [`0x78cda460e51dcd2b7fe94969e1664cb923608041`](https://arbiscan.io/address/0x78cda460e51dcd2b7fe94969e1664cb923608041) |
| Value report receiver | Arbitrum One | [`0xd003f922067f42cafab9e3ba89c6bceb9b444a05`](https://arbiscan.io/address/0xd003f922067f42cafab9e3ba89c6bceb9b444a05) |
| Remote Spoke Vault | Robinhood Chain | [`0x1d34f28e8687aeecc3fdb0c5518b5bcc5af54e59`](https://robinhoodchain.blockscout.com/address/0x1d34f28e8687aeecc3fdb0c5518b5bcc5af54e59) |

### Solana mainnet

These accounts belong to the Solana spoke. Solscan links open each account.

| Account | Address / explorer |
| --- | --- |
| Program | [`7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx`](https://solscan.io/account/7PptZ653uyn5eoAFKqs4DXR1ijxH6sf49f2YAGMLTfCx) |
| ProgramData | [`3PNTSFuKVmy9Ysiem7WktJFaYF7Z9DzdHA98VCsCopuh`](https://solscan.io/account/3PNTSFuKVmy9Ysiem7WktJFaYF7Z9DzdHA98VCsCopuh) |
| Upgrade authority (manager signer) | [`6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA`](https://solscan.io/account/6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA) |
| Keeper | [`8VLSQNmrHGyWzzoTKXZYjegPRbCm8UY7AmPyUUqzZe1x`](https://solscan.io/account/8VLSQNmrHGyWzzoTKXZYjegPRbCm8UY7AmPyUUqzZe1x) |
| Config PDA | [`4fhgX4FhW8Gvq5cnt7QJq9d4uTDhQdYc8ZMRULWkRWnu`](https://solscan.io/account/4fhgX4FhW8Gvq5cnt7QJq9d4uTDhQdYc8ZMRULWkRWnu) |
| Vault authority PDA | [`AXnN1ihCoy6bCwqcii6eDLT74abAwzDrn1AmgN57wNK6`](https://solscan.io/account/AXnN1ihCoy6bCwqcii6eDLT74abAwzDrn1AmgN57wNK6) |
| Vault USDC account | [`HEkWhruKWari9tepXfcKCTpS2YYfbYCWfoJtKmzqRw8b`](https://solscan.io/account/HEkWhruKWari9tepXfcKCTpS2YYfbYCWfoJtKmzqRw8b) |
| Vault wSOL account | [`CasmZzg4uAJYMCNMKcuKGcrZLP2Hj234ADCoEQ7Vv2Rs`](https://solscan.io/account/CasmZzg4uAJYMCNMKcuKGcrZLP2Hj234ADCoEQ7Vv2Rs) |
| Kamino cToken account | [`2tgxEJ963kND3J22aLUky417c9YMrJ8wzREiMCBYYF6B`](https://solscan.io/account/2tgxEJ963kND3J22aLUky417c9YMrJ8wzREiMCBYYF6B) |
| Position NFT | [`99Zuv8w4fWwzsUvM1u5CvKFEp5af1KS7TU4UfeGEoKrH`](https://solscan.io/token/99Zuv8w4fWwzsUvM1u5CvKFEp5af1KS7TU4UfeGEoKrH) |

Third-party accounts used:

| Account | Address / explorer |
| --- | --- |
| Kamino reserve (USDC) | [`D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59`](https://solscan.io/account/D6q6wuQSrifJKZYpR1M8R4YawnLDtDsMmWM1NbBmgJ59) |
| Kamino market | [`GFiB49BSouib5vZuRERpzLLNXMEDkU4JagAEdeF1Ms6H`](https://solscan.io/account/GFiB49BSouib5vZuRERpzLLNXMEDkU4JagAEdeF1Ms6H) |
| Kamino cToken mint | [`B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D`](https://solscan.io/token/B8V6WVjPxW1UGwVDfxH2d2r8SyT4cqn7dQRK6XneVa7D) |
| Raydium SOL/USDC pool | [`3ucNos4NbumPLZNWztqGHNFFgkHeRMBQAVemeeomsUxv`](https://solscan.io/account/3ucNos4NbumPLZNWztqGHNFFgkHeRMBQAVemeeomsUxv) |
| Raydium CLMM program | [`CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK`](https://solscan.io/account/CAMMCzo5YL8w4VFF8KVHrK22GGUsp5VTaW7grrKgrWqK) |
| Arbitrum TokenMessengerV2 | [`0x28b5a0e9c621a5badaa536219b3a228c8168cf5d`](https://arbiscan.io/address/0x28b5a0e9c621a5badaa536219b3a228c8168cf5d) |

## Build, inspect and contribute

Toolchain: **Solidity 0.8.28, EVM Cancun and Foundry**. Pinned dependencies are recorded in [foundry.lock](foundry.lock) and [.gitmodules](.gitmodules).

Solana program: **Rust 1.88.0, Anchor 0.31.1, Solana 2.3.0**, on branch `feat/pp-sc-feat-solana-spoke`.

```bash
git clone --recurse-submodules https://github.com/PoolPartyLabs/smartcontract-v2.git
cd smartcontract-v2
forge build
forge test --no-match-path 'test/{fork/**,review/**/*Fork*}'
forge fmt --check
```

For mainnet-fork tests, configure `ARBITRUM_RPC_URL` and `ROBINHOOD_RPC_URL` plus explicit block pins as described in [.env.example](.env.example). The [two-fork environment](local-e2e/README.md) supports integration development without sending mainnet transactions.

| Source | Purpose |
| --- | --- |
| [Architecture](docs/ARCHITECTURE.md) | Vaults, shares, adapters and cross-chain boundaries. |
| [Decision digest](docs/DECISIONS.md) | Implemented rules, decisions and current constraints. |
| [Integrations](docs/INTEGRATIONS.md) | External protocol addresses and interfaces. |
| [Deployment](docs/DEPLOYMENT.md) | Deployment architecture and dependencies. |
| [Security documentation](docs/security/) | Internal reviews, regression findings and known limitations. |
| [Public frontend](https://github.com/PoolPartyLabs/pool-party-v2-frontend) | Manager and investor application, typed API clients and frontend history. |

Code, tests, reports and public PR history are available for human and automated review. Claude Code and Codex assisted implementation, testing and documentation under the team's direction. Claims about live execution are tied to chain receipts; test results are tied to dated reports and commits.

## Existing product and earlier hackathons

Pool Party's existing product and community predate this V2 architecture. Earlier frontend work included Universal Funding, Active Reserve, hook analysis and Cash+. Those earlier projects are retained in the [public frontend](https://github.com/PoolPartyLabs/pool-party-v2-frontend) and are not claimed as new Arbitrum Open House Singapore work. The new V2 contracts, adapters, cross-chain accounting and fund builder described above are this Buildathon's delivery.

## Licensing

The current first-party distribution uses
[Pool Party Source-Available License 1.0](LICENSE), with custom SPDX notices and
explicit legacy-grant preservation. External interface subsets and unresolved
adaptation boundaries retain their original notices; dependencies keep their
upstream licenses. See [LICENSING.md](LICENSING.md),
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) and
[CONTRIBUTING.md](CONTRIBUTING.md) for scope, permissions and contribution rights.

This notice change does not replace the deployed release sources or claim a new
mainnet deployment. SPDX/comment edits can alter compiler metadata hashes; the
existing verification evidence stays tied to its original commits.
