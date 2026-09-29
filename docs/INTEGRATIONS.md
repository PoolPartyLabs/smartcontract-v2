# External integrations (verified on chain, 2026-09-29)

Every address below was probed with `cast` against the public RPCs on 2026-09-29. Re-verify before any
mainnet deployment. All chain ids are EVM chain ids unless marked as Wormhole chain ids.

## Chains

| Role | Chain | EVM chain id | Wormhole chain id | Public RPC |
|---|---|---:|---:|---|
| Hub Chain | Arbitrum One | 42161 | 23 | `https://arb1.arbitrum.io/rpc` |
| Spoke Chain | Robinhood Chain (Arbitrum Orbit L2, settles on Ethereum) | 4663 | 72 | `https://rpc.mainnet.chain.robinhood.com` |

Robinhood Chain explorer: `https://robinhoodchain.blockscout.com` (Blockscout; API sits behind Cloudflare,
`forge verify-contract --verifier blockscout` may need retries).

## Arbitrum One (Hub Chain)

| Contract | Address | Notes |
|---|---|---|
| USDC (native) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` | 6 decimals; the only deposit and payout asset |
| WETH | `0x82aF49447D8a07e3bd95BD0d56f35241523fBab1` | |
| Uniswap V3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` | canonical |
| Uniswap V3 NonfungiblePositionManager | `0xC36442b4a4522E871399CD717aBDD847Ab11FE88` | canonical |
| Uniswap V3 WETH/USDC 0.05% pool | `0xC6962004f452bE9203591991D15f6b388e09E8D0` | toolchain smoke test only |
| Uniswap V4 PoolManager | `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` | official deployment |
| Uniswap V4 PositionManager | `0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869` | `poolManager()` verified |
| Uniswap V4 StateView | `0x76fd297e2d437cd7f76d50f01afe6160f86e9990` | `poolManager()` verified |
| Uniswap V4 WETH/USDC 0.05% pool (tick spacing 10, no hooks) | poolId `0xfc7b3ad139daaf1e9c3637ed921c154d1b04286f8a82b805a6c352da57028653` | fork-test pool, liquidity present |
| Aave V3 PoolAddressesProvider | `0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb` | `Pool.ADDRESSES_PROVIDER()` |
| Aave V3 aUSDC (`aArbUSDCn`) | `0x724dc807b04555b71ed48a6896b6F41593b8C637` | from `Pool.getReserveData(USDC)` |
| Wormhole Core | `0xa5f208e072434bC67592E4C49C1B991BA79BCA46` | guardian set index 7, message fee 0 |
| Across SpokePool | `0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A` | `fillDeadlineBuffer` 21600 s, `depositQuoteTimeBuffer` 3600 s |
| Aave V3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` | pool revision 11; supply only (DEC-018, DEC-028) |

## Robinhood Chain (Spoke Chain)

| Contract | Address | Notes |
|---|---|---|
| USDG (Paxos Global Dollar) | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | 6 decimals; what Across delivers when USDC is sent from Arbitrum |
| WETH9 | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | |
| Uniswap V3 Factory | `0x1f7d7550B1b028f7571E69A784071F0205FD2EfA` | official Uniswap deployment |
| Uniswap V3 NonfungiblePositionManager | `0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3` | |
| Uniswap V3 SwapRouter02 | `0xCaf681a66D020601342297493863E78C959E5cb2` | |
| Uniswap V3 WETH/USDG 0.05% pool | `0x69BfaF19C9f377BB306a89aEd9F6B07e2c1a8d9a` | fork-test pool |
| Uniswap V3 WETH/USDG 0.3% pool | `0xa9188730Fe85Be88ad499D7d52B099e800fB0334` | |
| Uniswap V4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | official deployment |
| Uniswap V4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` | `poolManager()` verified |
| Uniswap V4 StateView | `0xf3334192d15450cdd385c8b70e03f9a6bd9e673b` | `poolManager()` verified |
| Uniswap V4 WETH/USDG 0.05% pool (tick spacing 10, no hooks) | poolId `0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593` | fork-test pool, liquidity present |
| Uniswap V4 WETH/USDG 0.3% pool (tick spacing 60, no hooks) | poolId `0x77c25b9386d47de62e0155c393696e9f43f7e6d036c6ca52f66735ccbb8808a7` | liquidity present |
| Wormhole Core | `0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB` | guardian set index 7, message fee 0 |
| Across SpokePool | `0xD29C85F15DF544bA632C9E25829fd29d767d7978` | `fillDeadlineBuffer` 21600 s; no MulticallHandler on this chain |

Not available on Robinhood Chain: native USDC, CCTP, Aave (so the Aave adapter exists only on the hub), Across MulticallHandler, Wormhole `WormholeRelayer`
(the Wormhole Executor and self-relay both work; see the spike results in the spec repo).

## Interfaces used

- **Across**: `depositV3(address depositor, address recipient, address inputToken, address outputToken, uint256
  inputAmount, uint256 outputAmount, uint256 destinationChainId, address exclusiveRelayer, uint32 quoteTimestamp,
  uint32 fillDeadline, uint32 exclusivityDeadline, bytes message)` on the origin SpokePool. A contract recipient
  implements `handleV3AcrossMessage(address tokenSent, uint256 amount, address relayer, bytes message)`, which the
  destination SpokePool calls after transferring `outputAmount` of the output token. On expiry (no fill before
  `fillDeadline`) the input amount is refunded to `depositor` on the origin chain by the Across dataworker bundle.
  Both live SpokePools expose the legacy `depositV3` and the bytes32 `deposit` entry points.
- **Wormhole**: `publishMessage(uint32 nonce, bytes payload, uint8 consistencyLevel)` on the Core (consistency 1 =
  finalized) and `parseAndVerifyVM(bytes)` on the Hub Core. The VAA carries `(emitterChainId, emitterAddress,
  sequence)`; the Core does not deduplicate application messages, so replay protection is ours.
- **Uniswap V4**: `IPositionManager.modifyLiquidities` with `Actions` (MINT_POSITION, INCREASE_LIQUIDITY,
  DECREASE_LIQUIDITY, BURN_POSITION, SETTLE_PAIR, TAKE_PAIR); pool ids are `keccak256(abi.encode(PoolKey))` with
  `PoolKey{currency0, currency1, fee, tickSpacing, hooks}`; state read through `StateView` (`getSlot0`,
  `getPositionInfo`, `getFeeGrowthInside`) or `StateLibrary` on the PoolManager. MVP pools are hookless.
- **Aave V3**: `IPool.supply`, `IPool.withdraw`, `IPool.getReserveData` and `IAToken.scaledBalanceOf` plus
  `IPool.getReserveNormalizedIncome` for the Exact-Value Position ledger (DEC-068).

## Testing on forks

`wormhole-solidity-sdk` v1.0.0 ships `WormholeOverride`, which replaces the guardian set on a forked Core with
keys the test controls, so tests can craft VAAs that the real Arbitrum Core verifies. `test/fork/Toolchain.t.sol`
proves the setup. Across fills are simulated by dealing the output token to the recipient and calling
`handleV3AcrossMessage` from the SpokePool address.
