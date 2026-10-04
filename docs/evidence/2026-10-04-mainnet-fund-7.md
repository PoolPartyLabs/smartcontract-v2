# Latest observed mainnet strategy: Pool Party fund #7

Observed on October 4, 2026. This is an evidence record of executed transactions, not instructions to deploy or transact. Fund #7 is the latest factory-created fund observed at the snapshot below. It is Open in the internal mainnet alpha; a completed full lifecycle is not established.

## Observation boundary

Arbitrum: block **511654340**, **2026-10-04 15:40:52 UTC**. Robinhood Chain: block **80049217**, **2026-10-04 15:40:53 UTC**. Public factory logs contained creation numbers 1 through 7 with no remaining page; `nextCreationNumber()` returned **8**. These latest-state balance reads occurred around this boundary and are not an atomic cross-chain snapshot.

Public sources: [Arbitrum RPC](https://arb1.arbitrum.io/rpc), [Robinhood RPC](https://rpc.mainnet.chain.robinhood.com), [factory event API](https://arbitrum.blockscout.com/api/v2/addresses/0x2CDB1f3fa95F8A65495D01D20AD53cF980728534/logs), and [factory event/structure ABI](https://github.com/PoolPartyLabs/smartcontract-v2/blob/main/src/interfaces/IFundFactory.sol). Robinhood evidence was read directly through its public RPC. The normalized [JSON manifest](fund-7-mainnet-2026-10-04.json) records the same identifiers, transactions and bounds.

## Identity and contracts

**Fund ID:** `0x00faff8442456da2305c0c9d973f480edbe2dad96f2a849d03c5b9226fba3ee4`  
**Manager:** `0xb1b546c3ce14bb02856b3056d448248bc8b34a1e`  
**Mandate hash:** `0x27f9871c8d1dc8841efe2c7297bfbc295efebec4501dd6a3c63982364fdc0284`

| Chain | Contract | Address |
|---|---|---|
| 42161 | factory | [`0x2CDB1f3fa95F8A65495D01D20AD53cF980728534`](https://arbiscan.io/address/0x2CDB1f3fa95F8A65495D01D20AD53cF980728534) |
| 42161 | coreVault | [`0xa653f620ea8f5539ed4bb55be2977262fba1f2dc`](https://arbiscan.io/address/0xa653f620ea8f5539ed4bb55be2977262fba1f2dc) |
| 42161 | shareToken | [`0x25f02c58e916ec7796771105c7dbd65d1993d83d`](https://arbiscan.io/address/0x25f02c58e916ec7796771105c7dbd65d1993d83d) |
| 42161 | managerFeeVault | [`0x6dcee34eacdf81016e1b362248266bc4525befe0`](https://arbiscan.io/address/0x6dcee34eacdf81016e1b362248266bc4525befe0) |
| 42161 | reportReceiver | [`0xd003f922067f42cafab9e3ba89c6bceb9b444a05`](https://arbiscan.io/address/0xd003f922067f42cafab9e3ba89c6bceb9b444a05) |
| 42161 | spokeVault | [`0x78cda460e51dcd2b7fe94969e1664cb923608041`](https://arbiscan.io/address/0x78cda460e51dcd2b7fe94969e1664cb923608041) |
| 42161 | uniswapV4Adapter | [`0xf1aa1d0032565a623db12674e76b7a097106c928`](https://arbiscan.io/address/0xf1aa1d0032565a623db12674e76b7a097106c928) |
| 42161 | aaveV3Adapter | [`0xe435325937f1c89f354f7829d3446e4427ddfccc`](https://arbiscan.io/address/0xe435325937f1c89f354f7829d3446e4427ddfccc) |
| 42161 | acrossAdapter | [`0x6cc531cf5f15d2cda19a863b3736f249cc0289ff`](https://arbiscan.io/address/0x6cc531cf5f15d2cda19a863b3736f249cc0289ff) |
| 42161 | uniswapV3SwapAdapter | [`0x8c8bd58ef8590880f8010f9a4aa073738fcf680f`](https://arbiscan.io/address/0x8c8bd58ef8590880f8010f9a4aa073738fcf680f) |
| 4663 | factory | [`0x2CDB1f3fa95F8A65495D01D20AD53cF980728534`](https://robinhoodchain.blockscout.com/address/0x2CDB1f3fa95F8A65495D01D20AD53cF980728534) |
| 4663 | spokeVault | [`0x1d34f28e8687aeecc3fdb0c5518b5bcc5af54e59`](https://robinhoodchain.blockscout.com/address/0x1d34f28e8687aeecc3fdb0c5518b5bcc5af54e59) |
| 4663 | uniswapV4Adapter | [`0x15a444e7bc51b254a0495412d8b487c39bc52edf`](https://robinhoodchain.blockscout.com/address/0x15a444e7bc51b254a0495412d8b487c39bc52edf) |
| 4663 | uniswapV3SwapAdapter | [`0x115c244ea702cd905b3f18ec8ffa63eb7873a7fd`](https://robinhoodchain.blockscout.com/address/0x115c244ea702cd905b3f18ec8ffa63eb7873a7fd) |
| 4663 | acrossAdapter | [`0xb5f37fbf160bf6912870aec92822ba02ea1c9b3a`](https://robinhoodchain.blockscout.com/address/0xb5f37fbf160bf6912870aec92822ba02ea1c9b3a) |

## Executed sequence

Times are UTC on October 4, 2026. Every listed transaction succeeded. The two cross-chain actions sharing a second are ordered by their functional relationship, not by a global blockchain order.

| Step | UTC | Chain / block | Transaction | Confirmed outcome |
|---|---|---|---|---|
| 1. Create fund and seed | 14:23:03 | 42161 / 511637332 | [0x7430f891fa…](https://arbiscan.io/tx/0x7430f891fa244cbf10ff8b9d365a2af11399f657def8f3e70498e21741f5453d) | 19.05 USDC transferred; 0.05 USDC protocol fee; 19 shares minted. |
| 2. Create matching spoke | 14:23:21 | 4663 / 80003147 | [0x1785bd91cc…](https://robinhoodchain.blockscout.com/tx/0x1785bd91cca6c955fbb12e65cba360128a425dc652ac9ed473b3993628c3d76d) | Matching fund ID in SpokeCreated; receipt succeeded. |
| 3. Allocate to hub Spoke Vault | 14:23:35 | 42161 / 511637446 | [0x61ffebe17d…](https://arbiscan.io/tx/0x61ffebe17df8e995e517683705a0cadc0b1adc79bf49c3a4b8104cf9599ad6f6) | 9.5 USDC received from Core Vault. |
| 4. Supply to Aave V3 | 14:23:44 | 42161 / 511637480 | [0x070023ec9a…](https://arbiscan.io/tx/0x070023ec9aa8ab89d13a5fa7d6f96bc56770c555ef9a85b17a4931aa9181c9b2) | Aave Supply event: 9.5 USDC on behalf of the fund adapter. |
| 5. Publish report 0 | 14:25:05 | 4663 / 80004175 | [0xc568577f06…](https://robinhoodchain.blockscout.com/tx/0xc568577f065894d8cc5e8fdeb2f874ed603f01793fb6de05242008e7ccc4a390) | Spoke report() and Wormhole publication. |
| 6. Deliver report 0 | 14:41:13 | 42161 / 511641255 | [0x103149c4dc…](https://arbiscan.io/tx/0x103149c4dc432a1429551a4cfdb8ae359b7bf73f817092278ffb642525a570e5) | Successful report receiver transaction. |
| 7. Publish report 1 | 14:43:07 | 4663 / 80014885 | [0xaee1cfaf2d…](https://robinhoodchain.blockscout.com/tx/0xaee1cfaf2df1ac4cd8bb4908a35759abfcf1c22bba9808442a1ed240d4d6480c) | Spoke report() and Wormhole publication. |
| 8. Send through Across | 14:44:27 | 42161 / 511641955 | [0x96f43b187f…](https://arbiscan.io/tx/0x96f43b187fa38a88b333bbea45804f76aac6088305c216784a68d1399f0f171b) | 3.8 USDC input; 3.766960 USDG expected output; deposit ID 4713839. |
| 9. Receive Across fill | 14:44:27 | 4663 / 80015674 | [0x819a2ad0d1…](https://robinhoodchain.blockscout.com/tx/0x819a2ad0d17276b5d282b8498ff9e76148110614b1e9846404afe6ffca8d3679) | 3.766960 USDG transferred to remote Spoke Vault; arrival event. |
| 10. Deliver report 1 | 15:00:15 | 42161 / 511645420 | [0x2ea654d09c…](https://arbiscan.io/tx/0x2ea654d09cf46432b1206d5bd6a6600f7d92026421e125abc6f4f56173971787) | Successful report receiver transaction. |
| 11. Publish report 2 | 15:02:10 | 4663 / 80026173 | [0x9fdcf3cf38…](https://robinhoodchain.blockscout.com/tx/0x9fdcf3cf38b17ba3ab28270f91ad9399ab0d7c32b89aa6a50837ab8b8ccb1dbc) | Spoke report() and Wormhole publication. |
| 12. Accept report 2 and reconcile arrival | 15:19:24 | 42161 / 511649626 | [0xbf96e721ef…](https://arbiscan.io/tx/0xbf96e721ef13520d38d67073cd74dffaeb62e21c85462483da1c7f2ea31b9c45) | Receiver/Core events confirm report 2 and 3.766960 USDG arrival. |
| 13. Publish report 3 | 15:21:14 | 4663 / 80037527 | [0x5879e7cb39…](https://robinhoodchain.blockscout.com/tx/0x5879e7cb39aeeed2a6d4a98c2c90716fbd11e99ea08b3dab5cf14cd54242e724) | Publication succeeded; delivery not observed by snapshot. |

## What the latest fund actually holds and uses

The creation receipt transferred **19.05 USDC** from manager to factory and Core Vault, paid **0.05 USDC** to the protocol recipient, and minted **19 shares**. These are receipt amounts, not a generalized fee formula. The Core then allocated **9.5 USDC** to its hub Spoke Vault, which supplied that amount to Aave V3.

The later Across send used **3.8 USDC** from remaining Core cash. There was no observed Aave partial withdrawal or close: hub Spoke Vault logs from creation through the observation contained only the allocation receipt and position opening. The bridge expected and delivered **3.766960 USDG**. The **0.033040** input-output gap is the selected send gap, not an assertion of the relayer's actual fee.

At the observation boundary, public balance reads showed **5.700000 USDC** in Core, **9.500043 aUSDC** at its Aave adapter, and **3.766960 USDG** at the Robinhood Spoke Vault. The aToken balance includes its balance at read time; it is not a promised return.

Actual execution proves **Aave V3 supply**, **Across deposit and fill**, and **Wormhole report publication and hub acceptance**. Report 2 acceptance reconciled the remote arrival. Report 3 was published, but its delivery was not observed.

Uniswap V4 pool identities and adapters, and Uniswap V3 swap adapters, are present in the decoded mandate and deployment. **No Uniswap V3 swap or Uniswap V4 position execution was observed for fund #7** by this boundary. Remote USDG was still held in the remote vault. Do not describe configured integrations as completed steps, infer original allocation proportions as current balances, or claim payout/close/unwind completion for this fund.

## Historical fund #1 integration evidence

The separate [October 3 public MVP report](https://github.com/PoolPartyLabs/smartcontract-v2/blob/main/docs/reports/2026-10-03-MVP-REPORT.md#mainnet-alpha-deployment) records an earlier mainnet smoke run for fund **#1**, ID `0xe49050db325f1963991d8b7fa591be9fe3fac1e7bfea0c34955c4f67893f6e46`. Those outcomes demonstrate integrations on that earlier fund, and are not steps performed by latest fund #7. The following amounts are attributed to that published report:

| Earlier fund #1 action | Public transaction | Reported receipt outcome |
|---|---|---|
| Uniswap V3 spoke swap | [Robinhood transaction](https://robinhoodchain.blockscout.com/tx/0x25cb4e4d2ee294251af5b62a448bbba5561bce16bb39af2ef4f4f091cf333c2c) | 925,757,908,345,888 wei WETH output. |
| Uniswap V4 position opening | [Robinhood transaction](https://robinhoodchain.blockscout.com/tx/0x80a46b594efacc7566eb4b9d25bc0f6419d237847b13a374cb0c55736ce5129c) | Token ID `0x365e57`; 925,757,908,345,535 wei WETH and 2,479,218 USDG base units. |
| Second investor deposit | [Arbitrum transaction](https://arbiscan.io/tx/0x05599c50c2c03cee9742451fa818177f5904aa2850dbb696eef09e5e9eb959e2) | One share minted; 1.003370 USDC charged. |

The report also records real Instant Payouts from Idle and a deferred income collection. It explicitly distinguishes these from Standard Payout/unwind tests. It does not prove latest fund #7 completed those stages.
