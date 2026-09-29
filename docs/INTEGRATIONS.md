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
| Uniswap V3 WETH/USDC 0.05% pool | `0xC6962004f452bE9203591991D15f6b388e09E8D0` | fork-test pool |
| Wormhole Core | `0xa5f208e072434bC67592E4C49C1B991BA79BCA46` | guardian set index 7, message fee 0 |
| Across SpokePool | `0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A` | `fillDeadlineBuffer` 21600 s, `depositQuoteTimeBuffer` 3600 s |
| Aave V3 Pool | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` | out of buildathon scope; listed for the next milestone |

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
| Wormhole Core | `0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB` | guardian set index 7, message fee 0 |
| Across SpokePool | `0xD29C85F15DF544bA632C9E25829fd29d767d7978` | `fillDeadlineBuffer` 21600 s; no MulticallHandler on this chain |

Not available on Robinhood Chain: native USDC, CCTP, Aave, Across MulticallHandler, Wormhole `WormholeRelayer`
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
- **Uniswap V3**: `INonfungiblePositionManager` (mint, increaseLiquidity, decreaseLiquidity, collect, burn) and
  `IUniswapV3Pool` (slot0, positions, feeGrowth) from the `0.8` branches of `v3-core` and `v3-periphery`.

## Testing on forks

`wormhole-solidity-sdk` v1.0.0 ships `WormholeOverride`, which replaces the guardian set on a forked Core with
keys the test controls, so tests can craft VAAs that the real Arbitrum Core verifies. `test/fork/Toolchain.t.sol`
proves the setup. Across fills are simulated by dealing the output token to the recipient and calling
`handleV3AcrossMessage` from the SpokePool address.
