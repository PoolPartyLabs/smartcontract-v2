// Uniswap V4 helpers for the scenario: TickMath.getSqrtPriceAtTick, the adapter's parameter encodings
// (src/adapters/UniswapV4Adapter.sol), and the trader's price swings through the harness's V4SwapRouter
// (test/mocks/v4/V4SwapRouter.sol), as test/fork/e2e/EndToEndBase.sol does them.
import { encodeAbiParameters, maxUint128, type Address, type Hex } from "viem";
import { stateViewAbi, v4SwapRouterAbi } from "./abis.ts";
import { read, send, type Side } from "./chain.ts";
import type { PoolKey } from "./config.ts";

const MAX_UINT256 = (1n << 256n) - 1n;

/** v4-core TickMath.getSqrtPriceAtTick (Q64.96). */
export function sqrtPriceAtTick(tick: number): bigint {
  const absTick = BigInt(Math.abs(tick));
  if (absTick > 887_272n) throw new Error(`tick ${tick} out of range`);
  let ratio = (absTick & 0x1n) !== 0n ? 0xfffcb933bd6fad37aa2d162d1a594001n : 0x100000000000000000000000000000000n;
  const factors: [bigint, bigint][] = [
    [0x2n, 0xfff97272373d413259a46990580e213an],
    [0x4n, 0xfff2e50f5f656932ef12357cf3c7fdccn],
    [0x8n, 0xffe5caca7e10e4e61c3624eaa0941cd0n],
    [0x10n, 0xffcb9843d60f6159c9db58835c926644n],
    [0x20n, 0xff973b41fa98c081472e6896dfb254c0n],
    [0x40n, 0xff2ea16466c96a3843ec78b326b52861n],
    [0x80n, 0xfe5dee046a99a2a811c461f1969c3053n],
    [0x100n, 0xfcbe86c7900a88aedcffc83b479aa3a4n],
    [0x200n, 0xf987a7253ac413176f2b074cf7815e54n],
    [0x400n, 0xf3392b0822b70005940c7a398e4b70f3n],
    [0x800n, 0xe7159475a2c29b7443b29c7fa6e889d9n],
    [0x1000n, 0xd097f3bdfd2022b8845ad8f792aa5825n],
    [0x2000n, 0xa9f746462d870fdf8a65dc1f90e061e5n],
    [0x4000n, 0x70d869a156d2a1b890bb3df62baf32f7n],
    [0x8000n, 0x31be135f97d08fd981231505542fcfa6n],
    [0x10000n, 0x9aa508b5b7a84e1c677de54f3e99bc9n],
    [0x20000n, 0x5d6af8dedb81196699c329225ee604n],
    [0x40000n, 0x2216e584f5fa1ea926041bedfe98n],
    [0x80000n, 0x48a170391f7dc42444e8fa2n],
  ];
  for (const [bit, factor] of factors) {
    if ((absTick & bit) !== 0n) ratio = (ratio * factor) >> 128n;
  }
  if (tick > 0) ratio = MAX_UINT256 / ratio;
  return (ratio >> 32n) + (ratio % (1n << 32n) === 0n ? 0n : 1n);
}

const Q96 = 1n << 96n;

/** OpenZeppelin Math.sqrt: the floor of the square root. */
function sqrt(n: bigint): bigint {
  if (n < 2n) return n;
  let x = n;
  let y = (x + 1n) >> 1n;
  while (y < x) {
    x = y;
    y = (x + n / x) >> 1n;
  }
  return x;
}

/** v4-core SqrtPriceMath.getAmount0Delta with roundUp = false. */
function amount0Delta(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return ((liquidity << 96n) * (sqrtB - sqrtA)) / sqrtB / sqrtA;
}

/** v4-core SqrtPriceMath.getAmount1Delta with roundUp = false. */
function amount1Delta(sqrtA: bigint, sqrtB: bigint, liquidity: bigint): bigint {
  if (sqrtA > sqrtB) [sqrtA, sqrtB] = [sqrtB, sqrtA];
  return (liquidity * (sqrtB - sqrtA)) / Q96;
}

/**
 * The token amounts a range position holds at the price-source price (security review S-1,
 * `CoreVaultLogic._oracleComposition`): recomputed from `liquidity` and the ticks at
 * sqrtPriceX96 = sqrt(price0 / price1) * 2^96, rounded down as on removal. `price0`, `price1` are the unit prices
 * in USDC (18 decimals of precision, as IPriceSource.priceInUsdc returns them; 1e18 for USDC itself).
 */
export function oracleAmounts(tickLower: number, tickUpper: number, liquidity: bigint, price0: bigint, price1: bigint): [bigint, bigint] {
  const sqrtPrice = sqrt((price0 * Q96) / price1) << 48n;
  const lower = sqrtPriceAtTick(tickLower);
  const upper = sqrtPriceAtTick(tickUpper);
  if (sqrtPrice <= lower) return [amount0Delta(lower, upper, liquidity), 0n];
  if (sqrtPrice < upper) return [amount0Delta(sqrtPrice, upper, liquidity), amount1Delta(lower, sqrtPrice, liquidity)];
  return [0n, amount1Delta(lower, upper, liquidity)];
}

export async function currentTick(side: Side, stateView: Address, poolId: Hex): Promise<number> {
  const [, tick] = await read<readonly [bigint, number, number, number]>(side, {
    address: stateView,
    abi: stateViewAbi,
    functionName: "getSlot0",
    args: [poolId],
  });
  return Number(tick);
}

/** The current tick rounded toward zero to the tick spacing (EndToEndBase `_center`). */
export async function centerTick(side: Side, stateView: Address, poolId: Hex, spacing = 10): Promise<number> {
  const tick = await currentTick(side, stateView, poolId);
  return tick - (tick % spacing);
}

/** `abi.encode(UniswapV4Adapter.OpenParams)`: a range of `halfRange` ticks on each side of `center`. */
export function openParams(center: number, halfRange: number, amount0: bigint, amount1: bigint, deadline: bigint): Hex {
  return encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "tickLower", type: "int24" },
          { name: "tickUpper", type: "int24" },
          { name: "liquidity", type: "uint128" },
          { name: "amount0Max", type: "uint128" },
          { name: "amount1Max", type: "uint128" },
          { name: "amount0Min", type: "uint128" },
          { name: "amount1Min", type: "uint128" },
          { name: "deadline", type: "uint256" },
        ],
      },
    ],
    [
      {
        tickLower: center - halfRange,
        tickUpper: center + halfRange,
        liquidity: 0n,
        amount0Max: amount0,
        amount1Max: amount1,
        amount0Min: 0n,
        amount1Min: 0n,
        deadline,
      },
    ],
  );
}

/** `abi.encode(UniswapV4Adapter.SwapExactInputParams{sqrtPriceLimitX96: 0, deadline})`. */
export function swapParams(deadline: bigint): Hex {
  return encodeAbiParameters(
    [{ type: "tuple", components: [{ name: "sqrtPriceLimitX96", type: "uint160" }, { name: "deadline", type: "uint256" }] }],
    [{ sqrtPriceLimitX96: 0n, deadline }],
  );
}

/** The trader moves the pool to `target` with a price-limited exact-input swap (EndToEndBase `_swapToTick`). */
export async function swapToTick(side: Side, router: Address, key: PoolKey, stateView: Address, poolId: Hex, target: number) {
  const tick = await currentTick(side, stateView, poolId);
  if (tick === target) return tick;
  const zeroForOne = target < tick;
  await send(side, "trader", {
    address: router,
    abi: v4SwapRouterAbi,
    functionName: "swap",
    args: [key, zeroForOne, -BigInt(maxUint128), sqrtPriceAtTick(target)],
  });
  return currentTick(side, stateView, poolId);
}

/** Swings the price `swing` ticks down and back up through the fund's range, then back to `center`, so a position
 *  around `center` earns fees in both tokens (EndToEndBase `_generateFees`). Returns the ticks reached. */
export async function generateFees(
  side: Side,
  router: Address,
  key: PoolKey,
  stateView: Address,
  poolId: Hex,
  center: number,
  swing: number,
): Promise<number[]> {
  const reached: number[] = [];
  for (const target of [center - swing, center + swing, center]) {
    reached.push(await swapToTick(side, router, key, stateView, poolId, target));
  }
  return reached;
}
