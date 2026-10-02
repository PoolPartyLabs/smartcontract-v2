// Signed swap routes, built the way the Pool Party API will build them (founder chat 1 of 2026-10-02: "receive the
// route from uniswap api that we'll send via our api's signed interaction"; DEC-136, DEC-142, DEC-143, DEC-153;
// readings D-01, D-02, D-52): the best single Uniswap V3 path QuoterV2 finds on the fork, direct in one of the four fee
// tiers or two hops through another Mandate token, signed by the API signer as the EIP-712 `SwapRoute` of
// src/adapters/UniswapV3SwapAdapter.sol (WP-03) for one swap adapter. The adapter verifies the signature, checks
// every hop and scales the minimum to the amount it actually sells. The production API takes its paths from the Uniswap
// Trading API's CLASSIC quote with `protocols: ["V3"]` (swap research §3); the signed shape is the same.
import { concat, encodeAbiParameters, keccak256, numberToHex, parseAbi, zeroAddress, type Address, type Hex } from "viem";
import { nodes, read, type Side } from "./chain.ts";
import { ARBITRUM, ROBINHOOD, actors } from "./config.ts";

/** The four Uniswap V3 fee tiers, in hundredths of a bip (DEC-153). */
export const FEE_TIERS = [100, 500, 3000, 10_000] as const;

const V3: Record<Side, { factory: Address; quoterV2: Address }> = {
  arbitrum: { factory: ARBITRUM.v3Factory, quoterV2: ARBITRUM.v3QuoterV2 },
  robinhood: { factory: ROBINHOOD.v3Factory, quoterV2: ROBINHOOD.v3QuoterV2 },
};

const v3FactoryAbi = parseAbi(["function getPool(address tokenA, address tokenB, uint24 fee) view returns (address pool)"]);
const quoterV2Abi = parseAbi([
  "function quoteExactInput(bytes path, uint256 amountIn) returns (uint256 amountOut, uint160[] sqrtPriceX96AfterList, uint32[] initializedTicksCrossedList, uint256 gasEstimate)",
]);

/** EIP-712 type of a route (`UniswapV3SwapAdapter.ROUTE_TYPEHASH`). */
export const ROUTE_TYPES = {
  SwapRoute: [
    { name: "tokenIn", type: "address" },
    { name: "tokenOut", type: "address" },
    { name: "legsHash", type: "bytes32" },
    { name: "quotedAmountIn", type: "uint256" },
    { name: "minAmountOut", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

/** `ISwapAdapter.ApiRoute`. */
export interface ApiRoute {
  paths: Hex[];
  weightsBps: number[];
  quotedAmountIn: bigint;
  minAmountOut: bigint;
  deadline: bigint;
  signature: Hex;
}

const API_ROUTE_TUPLE = {
  type: "tuple",
  components: [
    { name: "paths", type: "bytes[]" },
    { name: "weightsBps", type: "uint16[]" },
    { name: "quotedAmountIn", type: "uint256" },
    { name: "minAmountOut", type: "uint256" },
    { name: "deadline", type: "uint256" },
    { name: "signature", type: "bytes" },
  ],
} as const;

/** A packed V3 path: `token | fee (3 bytes) | token ...`. */
export function packPath(tokens: Address[], fees: number[]): Hex {
  const parts: Hex[] = [tokens[0]];
  fees.forEach((fee, i) => parts.push(numberToHex(fee, { size: 3 }), tokens[i + 1]));
  return concat(parts);
}

/** `keccak256(abi.encode(paths, weightsBps))`, the route's legs as the signature binds them. */
export function legsHash(paths: Hex[], weightsBps: number[]): Hex {
  return keccak256(encodeAbiParameters([{ type: "bytes[]" }, { type: "uint16[]" }], [paths, weightsBps]));
}

/** `abi.encode(ApiRoute)`, the `route` argument of `ISwapAdapter.swap`. */
export function encodeRoute(route: ApiRoute): Hex {
  return encodeAbiParameters([API_ROUTE_TUPLE], [route]);
}

export interface PathQuote {
  tokens: Address[];
  fees: number[];
  path: Hex;
  amountOut: bigint;
  gasEstimate: bigint;
}

/** Every direct path and every two-hop path through another of `mandateTokens` whose pools exist, quoted by QuoterV2
 *  for `amountIn` (by `eth_call`); the best first. A path whose quote reverts (no liquidity in range) is dropped. */
export async function quotePaths(side: Side, tokenIn: Address, tokenOut: Address, amountIn: bigint, mandateTokens: Address[]): Promise<PathQuote[]> {
  const { factory, quoterV2 } = V3[side];
  const exists = async (a: Address, b: Address, fee: number) =>
    (await read<Address>(side, { address: factory, abi: v3FactoryAbi, functionName: "getPool", args: [a, b, fee] })) !== zeroAddress;
  const routes: { tokens: Address[]; fees: number[] }[] = [];
  for (const fee of FEE_TIERS) if (await exists(tokenIn, tokenOut, fee)) routes.push({ tokens: [tokenIn, tokenOut], fees: [fee] });
  const mids = mandateTokens.filter((t) => ![tokenIn.toLowerCase(), tokenOut.toLowerCase()].includes(t.toLowerCase()));
  for (const mid of mids) {
    const first = [];
    for (const fee of FEE_TIERS) if (await exists(tokenIn, mid, fee)) first.push(fee);
    const second = [];
    for (const fee of FEE_TIERS) if (await exists(mid, tokenOut, fee)) second.push(fee);
    for (const f1 of first) for (const f2 of second) routes.push({ tokens: [tokenIn, mid, tokenOut], fees: [f1, f2] });
  }
  const quotes: PathQuote[] = [];
  for (const r of routes) {
    const path = packPath(r.tokens, r.fees);
    try {
      const { result } = await nodes[side].client.simulateContract({
        address: quoterV2,
        abi: quoterV2Abi,
        functionName: "quoteExactInput",
        args: [path, amountIn],
      });
      quotes.push({ ...r, path, amountOut: result[0], gasEstimate: result[3] });
    } catch {
      // a pool without liquidity in range for this amount
    }
  }
  return quotes.sort((a, b) => (a.amountOut === b.amountOut ? 0 : a.amountOut > b.amountOut ? -1 : 1));
}

/** Signs `route` (without its signature) for `adapter` on `chainId` with the API signer (EIP-712, domain
 *  `("Pool Party Swap Adapter", "1", chainId, adapter)`). */
export function signRoute(
  adapter: Address,
  chainId: number,
  tokenIn: Address,
  tokenOut: Address,
  route: Omit<ApiRoute, "signature">,
): Promise<Hex> {
  return actors.apiSigner.signTypedData({
    domain: { name: "Pool Party Swap Adapter", version: "1", chainId, verifyingContract: adapter },
    types: ROUTE_TYPES,
    primaryType: "SwapRoute",
    message: {
      tokenIn,
      tokenOut,
      legsHash: legsHash(route.paths, route.weightsBps),
      quotedAmountIn: route.quotedAmountIn,
      minAmountOut: route.minAmountOut,
      deadline: route.deadline,
    },
  });
}
