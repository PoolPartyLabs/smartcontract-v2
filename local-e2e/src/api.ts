// A minimal API over the two forks: what the product API needs from the contracts, in one file, so its concepts can
// be exercised against the real protocols before the product API is written. It reads chain state and builds
// unsigned transactions for the user to sign. It holds one key, the API signer's (reading D-01, DEC-170), with which
// it signs swap routes (EIP-712, founder chat 1 of 2026-10-02) and publishes the report after each deposit (DEC-159).
// Run: `pnpm api` (after `pnpm run up`).
//
//   GET  /health                         nodes, clocks, report and price freshness, whether mints are open
//   GET  /fund                           identity, value bases, Share Price, Spoke Cap usage, latest spoke report
//   GET  /holders/:address               shares, value, Attributed Income per token, open Payout Request, owed transfers
//   GET  /quote/deposit?from=&amount=    exact deposit outcome by eth_call (shares, USDC charged) or the decoded revert
//   GET  /quote/claim?from=              exact claim outcome by eth_call (the receipt) or the decoded revert
//   GET  /quote/swap?amountIn=&tokenIn=  hub swap minimum from the oracle less the API's slippage (security review S-8)
//   GET  /quote/swap-route?chain=&tokenIn=&tokenOut=&amountIn=&slippageBps=&adapter=&hops=
//                                        the best V3 path by QuoterV2, signed for a swap adapter (DEC-136, DEC-153)
//   GET  /quote/bridge?direction=to-spoke|to-hub&amount=
//                                        what the fund's Across adapter fixes for a send (DEC-158, DEC-162)
//   GET  /share-price/history?fromBlock=&toBlock=
//                                        the Share Price at every hub block with a Core Vault event (DEC-084, DEC-103)
//   POST /tx/deposit      {from, amount, minShares?}      approve + deposit, unsigned
//   POST /tx/request      {from, amount, mode}            requestPayout, unsigned
//   POST /tx/claim        {from}                          claimPayout with the unwind route hints the API computes
//   POST /tx/swap         {amountIn, tokenIn, slippageBps?} manager swap on the hub Spoke Vault through the fund's swap
//                                        adapter, on a route the API signs with an oracle minimum
//   POST /report/after-deposit {txHash}                  DEC-159: a report published on every spoke and delivered
//   GET  /events?fromBlock=                 Core Vault events, decoded (the indexer a server would run)
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import {
  decodeErrorResult,
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  type Abi,
  type Address,
  type Hex,
  type TransactionReceipt,
} from "viem";
import {
  acrossBridgeAdapterAbi,
  allErrorsAbi,
  chainlinkPriceSourceAbi,
  coreVaultAbi,
  erc20Abi,
  spokeVaultAbi,
  uniswapV3SwapAdapterAbi,
  valueReportReceiverAbi,
} from "./abis.ts";
import { latestTimestamp, nodes, nodesUp, read, type Side } from "./chain.ts";
import { ARBITRUM, HUB_POOL_ID, ROBINHOOD, SWAP_ADAPTER_TOKENS, actors, isMain } from "./config.ts";
import { sharePriceHistory } from "./history.ts";
import { runningKeeperPid } from "./keeper.ts";
import { redactUrls } from "./log.ts";
import { readState, type DeploymentState, type FundRecord } from "./state.ts";
import { encodeRoute, legsHash, quotePaths, signRoute } from "./swap-route.ts";
import { deliverDirectly, publishReport, waitForDelivery, type SpokeRef } from "./warp.ts";

export const API_PORT = Number(process.env.LOCAL_E2E_API_PORT ?? 8787);

/** The API's own slippage bound on manager swaps and unwind routes, tighter than the vault's 5% floor (QA3, S-2). */
export const API_SLIPPAGE_BPS = 100n;

const SHARE = 10n ** 18n;
const PRICE_SCALE = 10n ** 18n;

export interface UnsignedTx {
  chainId: number;
  to: Address;
  data: Hex;
  description: string;
}

class HttpError extends Error {
  constructor(
    readonly status: number,
    message: string,
    readonly detail?: unknown,
  ) {
    super(message);
  }
}

function hub(state: DeploymentState) {
  return state.fund;
}

function addressParam(value: string | undefined, name: string): Address {
  if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) throw new HttpError(400, `${name} must be an address`);
  return value as Address;
}

function amountParam(value: string | undefined, name: string): bigint {
  if (!value || !/^[0-9]+$/.test(value)) throw new HttpError(400, `${name} must be an integer in base units`);
  return BigInt(value);
}

function hopsParam(value: string | undefined): 1 | 2 | undefined {
  if (value === undefined) return undefined;
  if (value === "1" || value === "2") return Number(value) as 1 | 2;
  throw new HttpError(400, "hops must be 1 or 2");
}

function sideParam(value: string | undefined): Side {
  if (value === "arbitrum" || value === "robinhood") return value;
  throw new HttpError(400, "chain must be arbitrum or robinhood");
}

/** USDC base units as a decimal string, for humans; every value is also returned in base units. */
function usdc(value: bigint): string {
  const whole = value / 1_000_000n;
  const frac = (value % 1_000_000n).toString().padStart(6, "0");
  return `${whole}.${frac}`;
}

/** A revert as the API returns it: the custom error's name and arguments, decoded against every protocol ABI. */
export function decodeRevert(err: unknown): { error: string; args: unknown[] } | undefined {
  let cursor: unknown = err;
  for (let i = 0; cursor && i < 8; ++i) {
    const data = (cursor as { data?: unknown }).data;
    const raw = typeof data === "string" ? data : (data as { data?: unknown } | undefined)?.data;
    if (typeof raw === "string" && raw.startsWith("0x") && raw.length >= 10) {
      try {
        const decoded = decodeErrorResult({ abi: [...coreVaultAbi, ...spokeVaultAbi, ...allErrorsAbi] as Abi, data: raw as Hex });
        return { error: decoded.errorName, args: [...(decoded.args ?? [])] };
      } catch {
        return { error: "unknown", args: [raw] };
      }
    }
    const name = (cursor as { data?: { errorName?: string; args?: unknown[] } }).data?.errorName;
    if (name) return { error: name, args: [...((cursor as { data?: { args?: unknown[] } }).data?.args ?? [])] };
    cursor = (cursor as { cause?: unknown }).cause;
  }
  return undefined;
}

async function simulate<T>(
  side: Side,
  from: Address,
  address: Address,
  abi: Abi,
  functionName: string,
  args: unknown[],
): Promise<{ ok: true; result: T } | { ok: false; revert: { error: string; args: unknown[] } | undefined }> {
  try {
    const { result } = await nodes[side].client.simulateContract({
      account: from,
      address,
      abi: [...abi, ...allErrorsAbi] as Abi,
      functionName,
      args,
    } as never);
    return { ok: true, result: result as T };
  } catch (err) {
    return { ok: false, revert: decodeRevert(err) };
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Reads
// ---------------------------------------------------------------------------------------------------------------------

/** Freshness of everything a mint depends on (Q57 reading, OQ-10): the spoke report against its lifetime, the WETH
 *  price against its feed's bound. Payouts depend on neither. */
export async function health(state: DeploymentState) {
  const fund = hub(state);
  const up = await nodesUp();
  const now = {
    arbitrum: (await nodes.arbitrum.client.getBlock()).timestamp,
    robinhood: (await nodes.robinhood.client.getBlock()).timestamp,
  };
  const receiver = fund.hub.valueReportReceiver;
  const spokeIndex = BigInt(fund.spoke.spokeIndex);
  const hasReport = await read<boolean>("arbitrum", { address: receiver, abi: valueReportReceiverAbi, functionName: "hasReport", args: [spokeIndex] });
  const maxReportAge = await read<number>("arbitrum", { address: receiver, abi: valueReportReceiverAbi, functionName: "maxReportAge", args: [spokeIndex] });
  let reportAge: bigint | undefined;
  let reportSequence: bigint | undefined;
  if (hasReport) {
    const [r] = await read<readonly [{ timestamp: bigint; sequence: bigint }, bigint, bigint]>("arbitrum", {
      address: receiver,
      abi: valueReportReceiverAbi,
      functionName: "latestReport",
      args: [spokeIndex],
    });
    reportAge = now.arbitrum > r.timestamp ? now.arbitrum - r.timestamp : 0n;
    reportSequence = r.sequence;
  }
  const priceSource = state.protocol.arbitrum.priceSource;
  const [, updatedAt] = await read<readonly [bigint, bigint]>("arbitrum", { address: priceSource, abi: chainlinkPriceSourceAbi, functionName: "priceInUsdc", args: [ARBITRUM.weth] });
  const maxPriceAge = await read<bigint>("arbitrum", { address: priceSource, abi: chainlinkPriceSourceAbi, functionName: "maxPriceAge", args: [ARBITRUM.weth] });
  const priceAge = now.arbitrum - updatedAt;
  // A spoke with no accepted report counts nothing on the hub, so it never closes mints (CoreVaultLogic._spokeValue).
  const reportFresh = !hasReport || (reportAge !== undefined && reportAge <= BigInt(maxReportAge));
  const priceFresh = priceAge <= maxPriceAge;
  return {
    nodes: up,
    clocks: now,
    spokeReport: { hasReport, reportSequence, ageSeconds: reportAge, maxReportAge, fresh: reportFresh },
    wethPrice: { ageSeconds: priceAge, maxPriceAge, fresh: priceFresh },
    mintsOpen: reportFresh && priceFresh,
    payoutsOpen: true,
  };
}

export async function fundState(state: DeploymentState) {
  const fund = hub(state);
  const core = fund.hub.coreVault;
  const view = <T>(functionName: string, args: unknown[] = []) => read<T>("arbitrum", { address: core, abi: coreVaultAbi, functionName, args });
  const [shareAssets, sharePrice, grossAssets, idle, freeIdle, payoutReserve, inFlightValue, operatingCash, unmatched] =
    await Promise.all([
      view<bigint>("shareAssets"),
      view<bigint>("sharePrice"),
      view<bigint>("grossAssets"),
      view<bigint>("idle"),
      view<bigint>("freeIdle"),
      view<bigint>("payoutReserve"),
      view<bigint>("inFlightValue"),
      view<bigint>("operatingCash"),
      view<bigint>("unmatchedArrivals"),
    ]);
  const [spokeValue, inFlightSent, inFlightToHub, cap] = await view<readonly [bigint, bigint, bigint, bigint]>("spokeCapUsage", [BigInt(fund.spoke.spokeIndex)]);
  const supply = await read<bigint>("arbitrum", { address: fund.hub.shareToken, abi: erc20Abi, functionName: "totalSupply" });
  return {
    fundId: fund.fundId,
    coreVault: core,
    shareToken: fund.hub.shareToken,
    // DEC-084, DEC-098, DEC-103: the published price is the Share Price; Gross Assets, never AUM or TVL.
    sharePrice: { raw: sharePrice, usdcPerShare: usdc(sharePrice / PRICE_SCALE) },
    totalShares: supply,
    bases: { shareAssets, grossAssets, idle, freeIdle, payoutReserve, inFlightValue, operatingCash, unmatchedArrivals: unmatched },
    spokeCap: { spokeValue, inFlightSent, inFlightToHub, cap, used: spokeValue + inFlightSent + inFlightToHub },
    fees: {
      performanceFeeBps: await view<number>("performanceFeeBps"),
      flowFeeBps: await view<number>("flowFeeBps"),
      payoutFeeBps: await view<number>("payoutFeeBps"),
      standardPayoutTermSeconds: await view<number>("standardPayoutTerm"),
    },
  };
}

export async function holderState(state: DeploymentState, holder: Address) {
  const fund = hub(state);
  const core = fund.hub.coreVault;
  const view = <T>(functionName: string, args: unknown[] = []) => read<T>("arbitrum", { address: core, abi: coreVaultAbi, functionName, args });
  const shares = await read<bigint>("arbitrum", { address: fund.hub.shareToken, abi: erc20Abi, functionName: "balanceOf", args: [holder] });
  const price = await view<bigint>("sharePrice");
  const tokens = await view<readonly Address[]>("incomeTokens");
  const income: Record<string, { attributed: bigint; owedTransfer: bigint }> = {};
  for (const token of tokens) {
    income[token] = {
      attributed: await view<bigint>("attributedIncome", [holder, token]),
      owedTransfer: await view<bigint>("owedFees", [token, holder]),
    };
  }
  const request = await view<Record<string, unknown>>("payoutRequest", [holder]);
  return {
    holder,
    shares,
    // Whole shares times the Share Price (USDC base units x 1e18 per whole share), rounded down.
    value: (shares * price) / (SHARE * PRICE_SCALE),
    attributedIncome: income,
    payoutRequest: request,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Quotes: exact, by simulation against the fork's state
// ---------------------------------------------------------------------------------------------------------------------

export async function quoteDeposit(state: DeploymentState, from: Address, amount: bigint) {
  const core = hub(state).hub.coreVault;
  const allowance = await read<bigint>("arbitrum", { address: ARBITRUM.usdc, abi: erc20Abi, functionName: "allowance", args: [from, core] });
  if (allowance < amount) {
    // The simulation needs the allowance the approve transaction would give; state overrides are not used so the
    // quote reflects the real contracts only. Report the missing approval instead.
    const fresh = await health(state);
    return { needsApproval: true, mintsOpen: fresh.mintsOpen };
  }
  const sim = await simulate<readonly [bigint, bigint]>("arbitrum", from, core, coreVaultAbi, "deposit", [amount, 0n]);
  if (!sim.ok) return { ok: false, revert: sim.revert };
  const [shares, charged] = sim.result;
  return { ok: true, shares, wholeShares: shares / SHARE, usdcCharged: charged, leftInWallet: amount - charged };
}

export async function quoteClaim(state: DeploymentState, from: Address) {
  const core = hub(state).hub.coreVault;
  const hints = await unwindHints(state);
  const sim = await simulate<Record<string, bigint | boolean>>("arbitrum", from, core, coreVaultAbi, "claimPayout", [hints]);
  if (!sim.ok) return { ok: false, revert: sim.revert };
  return { ok: true, receipt: sim.result, hints };
}

/** A manager swap minimum the API will sign off on: the oracle value of `amountIn` less the API slippage. The vault
 *  holds a swap only to the manager's optional loss bound against the pool mid and, with a signed route, the API's
 *  minimum (DEC-142; security review S-8 stays open), so the API signs this bound into the routes it builds. */
export async function quoteSwap(state: DeploymentState, tokenIn: Address, amountIn: bigint, slippageBps = API_SLIPPAGE_BPS) {
  const priceSource = state.protocol.arbitrum.priceSource;
  const [value] = await read<readonly [bigint, bigint]>("arbitrum", { address: priceSource, abi: chainlinkPriceSourceAbi, functionName: "usdcValue", args: [tokenIn, amountIn] });
  if (tokenIn.toLowerCase() === ARBITRUM.usdc.toLowerCase()) {
    // USDC in: the minimum is in WETH, the oracle value of amountIn in WETH less the slippage.
    const [wethPrice] = await read<readonly [bigint, bigint]>("arbitrum", { address: priceSource, abi: chainlinkPriceSourceAbi, functionName: "priceInUsdc", args: [ARBITRUM.weth] });
    const wethOut = (amountIn * 10n ** 18n) / wethPrice;
    return { tokenOut: ARBITRUM.weth, oracleAmountOut: wethOut, minAmountOut: (wethOut * (10_000n - slippageBps)) / 10_000n, slippageBps };
  }
  return { tokenOut: ARBITRUM.usdc, oracleAmountOut: value, minAmountOut: (value * (10_000n - slippageBps)) / 10_000n, slippageBps };
}

/** Unwind hints for a claim. The vault sizes and floors every step itself; a hint is needed only to give a route to
 *  a position whose own pool does not pair its token with USDC (a single-asset non-USDC reserve, plan T14). The
 *  MVP Mandate has none (hub V4 WETH/USDC pairs with USDC, Aave is USDC), so the hints are empty; the function shows
 *  where the API would add them. */
async function unwindHints(state: DeploymentState): Promise<Hex> {
  const positions = await read<readonly { adapter: Address; positionKey: Hex; poolKey: Hex }[]>("arbitrum", {
    address: hub(state).hub.spokeVault,
    abi: spokeVaultAbi,
    functionName: "positions",
  });
  const needsRoute = positions.some((p) => p.adapter.toLowerCase() !== hub(state).hub.uniswapV4Adapter.toLowerCase() && p.poolKey.toLowerCase() !== `0x${ARBITRUM.usdc.slice(2).toLowerCase().padStart(64, "0")}`);
  if (!needsRoute) return "0x";
  // One hint per position visited, routing a non-USDC single asset through the hub WETH/USDC pool.
  const hints = positions.map(() => ({ swaps: [{ adapter: hub(state).hub.uniswapV4Adapter, poolKey: HUB_POOL_ID, tokenIn: ARBITRUM.weth, minAmountOut: 0n, params: "0x" as Hex }] }));
  return encodeAbiParameters(
    [{ type: "tuple[]", components: [{ name: "swaps", type: "tuple[]", components: [{ name: "adapter", type: "address" }, { name: "poolKey", type: "bytes32" }, { name: "tokenIn", type: "address" }, { name: "minAmountOut", type: "uint256" }, { name: "params", type: "bytes" }] }] }],
    [hints],
  );
}

// ---------------------------------------------------------------------------------------------------------------------
// Transaction builders: unsigned, the client signs
// ---------------------------------------------------------------------------------------------------------------------

export async function buildDeposit(state: DeploymentState, from: Address, amount: bigint, minShares: bigint): Promise<UnsignedTx[]> {
  const core = hub(state).hub.coreVault;
  const fresh = await health(state);
  if (!fresh.mintsOpen) throw new HttpError(409, "mints are closed: a spoke report or a price is stale; the keeper must deliver first", fresh);
  const txs: UnsignedTx[] = [];
  const allowance = await read<bigint>("arbitrum", { address: ARBITRUM.usdc, abi: erc20Abi, functionName: "allowance", args: [from, core] });
  if (allowance < amount) {
    txs.push({ chainId: nodes.arbitrum.chain.id, to: ARBITRUM.usdc, data: encodeFunctionData({ abi: erc20Abi, functionName: "approve", args: [core, amount] }), description: "approve USDC for the Core Vault" });
  }
  txs.push({ chainId: nodes.arbitrum.chain.id, to: core, data: encodeFunctionData({ abi: coreVaultAbi, functionName: "deposit", args: [amount, minShares] }), description: "deposit" });
  return txs;
}

export function buildRequest(state: DeploymentState, amount: bigint, mode: "instant" | "standard"): UnsignedTx[] {
  const core = hub(state).hub.coreVault;
  return [{ chainId: nodes.arbitrum.chain.id, to: core, data: encodeFunctionData({ abi: coreVaultAbi, functionName: "requestPayout", args: [amount, mode === "instant" ? 0 : 1] }), description: `requestPayout (${mode})` }];
}

export async function buildClaim(state: DeploymentState): Promise<UnsignedTx[]> {
  const core = hub(state).hub.coreVault;
  return [{ chainId: nodes.arbitrum.chain.id, to: core, data: encodeFunctionData({ abi: coreVaultAbi, functionName: "claimPayout", args: [await unwindHints(state)] }), description: "claimPayout" }];
}

/** The manager's swap on the hub Spoke Vault (`SpokeVault.swap`, WP-07C) through the fund's own swap adapter (Mandate
 *  v2, DEC-136): a route the API signs whose minimum is the stricter of the quote and the oracle value, each less
 *  `slippageBps` (`quoteSwap`), with `slippageBps` also as the manager's loss bound against the pool mid (DEC-142: the
 *  stricter applies). At zero slippage the ABI's `maxLossBps = 0` sentinel disables only the pool-mid bound;
 *  the signed route still enforces the full quote/oracle minimum, so zero slippage is not an unbounded swap. */
export async function buildSwap(state: DeploymentState, tokenIn: Address, amountIn: bigint, slippageBps: bigint): Promise<UnsignedTx[]> {
  const fund = hub(state);
  const quote = await quoteSwap(state, tokenIn, amountIn, slippageBps);
  const routed = await quoteSwapRoute(state, "arbitrum", tokenIn, quote.tokenOut, amountIn, slippageBps, fund.hub.uniswapV3SwapAdapter, undefined, quote.minAmountOut);
  return [
    {
      chainId: nodes.arbitrum.chain.id,
      to: fund.hub.spokeVault,
      data: encodeFunctionData({ abi: spokeVaultAbi, functionName: "swap", args: [routed.adapter, tokenIn, quote.tokenOut, amountIn, Number(slippageBps), routed.encodedRoute] }),
      description: `swap ${amountIn} of ${tokenIn} through the fund's swap adapter, signed minimum ${routed.route.minAmountOut} (quote and oracle less ${slippageBps} bps); pool-mid loss bound ${slippageBps === 0n ? "disabled (maxLossBps = 0 sentinel)" : `${slippageBps} bps`}`,
    },
  ];
}

// ---------------------------------------------------------------------------------------------------------------------
// Indexer
// ---------------------------------------------------------------------------------------------------------------------

export async function coreEvents(state: DeploymentState, fromBlock: bigint) {
  const logs = await nodes.arbitrum.client.getContractEvents({ address: hub(state).hub.coreVault, abi: coreVaultAbi as Abi, fromBlock, toBlock: "latest" });
  return logs.map((l) => ({ block: l.blockNumber, tx: l.transactionHash, logIndex: l.logIndex, event: l.eventName, args: l.args }));
}

// ---------------------------------------------------------------------------------------------------------------------
// Signed swap routes (founder chat 1 of 2026-10-02; DEC-136, DEC-142, DEC-143, DEC-153; readings D-01, D-02, D-52)
// ---------------------------------------------------------------------------------------------------------------------

/** How long a signed route stays valid: long enough for the manager or an executor to send it. */
const ROUTE_LIFETIME_SECONDS = 600n;

/** The loosest minimum the API signs: the Spoke Vault's own unwind floor (`MAX_UNWIND_SLIPPAGE_BPS`, 5%). The API's
 *  minimum is one of the two the adapter applies (DEC-142: the stricter wins), so it never signs a near-zero one for
 *  whoever asks. */
export const MAX_ROUTE_SLIPPAGE_BPS = 500n;

/** The swap adapter routes are signed for: by default the harness's instance on that chain (its vault is the manager's
 *  wallet, so a signed route can be executed from a wallet); `adapter` may name it or the fund's own swap adapter on
 *  that chain, which the factory deployed from the Mandate (Mandate v2, DEC-136). The API never signs for any other
 *  address, since every production adapter accepts the API signer's routes (D-01). */
function swapAdapterOf(state: DeploymentState, side: Side, adapter?: string): Address {
  const helper = state.helpers.swapAdapters[side];
  if (adapter === undefined) return helper;
  const fundAdapter = side === "arbitrum" ? hub(state).hub.uniswapV3SwapAdapter : hub(state).spoke.uniswapV3SwapAdapter;
  const served = [helper, fundAdapter].filter((a): a is Address => a !== undefined);
  const named = addressParam(adapter, "adapter");
  const match = served.find((a) => a.toLowerCase() === named.toLowerCase());
  if (!match) throw new HttpError(422, `the API signs routes only for the swap adapters it serves on ${side} (${served.join(", ")})`);
  return match;
}

/** The best single V3 path for the swap, direct or through another Mandate token of the adapter (D-52: the API never
 *  signs a hop the adapter would refuse), quoted by QuoterV2 on the fork and signed by the API signer; `hops` (1 or 2)
 *  restricts it to direct or two-hop paths. The minimum is the quote less `slippageBps`, or `minimumFloor` when that
 *  is stricter; the adapter scales it to the amount it actually sells. */
export async function quoteSwapRoute(
  state: DeploymentState,
  side: Side,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  slippageBps: bigint,
  adapterParam?: string,
  hops?: 1 | 2,
  minimumFloor = 0n,
) {
  if (amountIn === 0n) throw new HttpError(400, "amountIn must be above zero");
  if (slippageBps > MAX_ROUTE_SLIPPAGE_BPS) throw new HttpError(400, `slippageBps must be at most ${MAX_ROUTE_SLIPPAGE_BPS}`);
  const adapter = swapAdapterOf(state, side, adapterParam);
  const isMandateToken = (token: Address) =>
    read<boolean>(side, { address: adapter, abi: uniswapV3SwapAdapterAbi, functionName: "isMandateToken", args: [token] });
  if (!(await isMandateToken(tokenIn)) || !(await isMandateToken(tokenOut))) {
    throw new HttpError(422, "tokenIn and tokenOut must be Mandate tokens of the swap adapter (DEC-136 item 2)");
  }
  const mandateTokens: Address[] = [];
  for (const token of SWAP_ADAPTER_TOKENS[side]) if (await isMandateToken(token)) mandateTokens.push(token);
  const quotes = await quotePaths(side, tokenIn, tokenOut, amountIn, mandateTokens);
  const best = quotes.find((q) => hops === undefined || q.fees.length === hops);
  if (!best) throw new HttpError(422, `no Uniswap V3 path${hops ? ` of ${hops} hop(s)` : ""} quotes this swap`);
  const quotedMinimum = (best.amountOut * (10_000n - slippageBps)) / 10_000n;
  const unsigned = {
    paths: [best.path],
    weightsBps: [10_000],
    quotedAmountIn: amountIn,
    minAmountOut: quotedMinimum > minimumFloor ? quotedMinimum : minimumFloor,
    deadline: (await latestTimestamp(side)) + ROUTE_LIFETIME_SECONDS,
  };
  const chainId = nodes[side].chain.id;
  const route = { ...unsigned, signature: await signRoute(adapter, chainId, tokenIn, tokenOut, unsigned) };
  return {
    chainId,
    adapter,
    signer: actors.apiSigner.address,
    tokenIn,
    tokenOut,
    amountIn,
    quotedAmountOut: best.amountOut,
    path: { tokens: best.tokens, fees: best.fees, packed: best.path },
    legsHash: legsHash(route.paths, route.weightsBps),
    slippageBps,
    candidates: quotes.map((q) => ({ tokens: q.tokens, fees: q.fees, amountOut: q.amountOut, gasEstimate: q.gasEstimate })),
    route,
    /** `abi.encode(ApiRoute)`: the `route` argument of the adapter's `swap`. */
    encodedRoute: encodeRoute(route),
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// Bridge quote (DEC-156, DEC-158, DEC-162)
// ---------------------------------------------------------------------------------------------------------------------

/** What the fund's Across adapter would fix for a send of `amount` now: the amount to arrive and the rate of its fee
 *  rule (the same rule `buildSend` applies), with the route's fee state. Nobody passes these to the vault (DEC-158);
 *  the API shows them before the manager sends, or before a payout or a collection reaches a spoke. */
export async function quoteBridge(state: DeploymentState, direction: "to-spoke" | "to-hub", amount: bigint) {
  const fund = hub(state);
  const toSpoke = direction === "to-spoke";
  const side: Side = toSpoke ? "arbitrum" : "robinhood";
  const adapter = toSpoke ? fund.hub.acrossBridgeAdapter : fund.spoke.acrossBridgeAdapter;
  const inputToken = toSpoke ? ARBITRUM.usdc : ROBINHOOD.usdg;
  const destinationChainId = BigInt(toSpoke ? fund.spoke.chainId : fund.hub.chainId);
  const call = <T>(functionName: string, args: unknown[]) => read<T>(side, { address: adapter, abi: acrossBridgeAdapterAbi, functionName, args });
  let quote: readonly [bigint, bigint];
  try {
    quote = await call<readonly [bigint, bigint]>("quoteSend", [inputToken, destinationChainId, amount, "0x"]);
  } catch (err) {
    throw new HttpError(422, "the bridge adapter refuses this amount", decodeRevert(err));
  }
  const [amountToArrive, rateWad] = quote;
  const [nextRateWad, referenceRateWad, expiredRateWad] = await call<readonly [bigint, bigint, bigint]>("feeState", [destinationChainId]);
  return {
    direction,
    chainId: nodes[side].chain.id,
    adapter,
    inputToken,
    destinationChainId,
    amountSent: amount,
    amountToArrive,
    fee: amount - amountToArrive,
    rateWad,
    feeState: { nextRateWad, referenceRateWad, expiredRateWad },
    // R-162-B (WP-11): a quote the API signs and anyone relays; the Across adapter refuses one today.
    signed: false,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// The report after each deposit (DEC-159)
// ---------------------------------------------------------------------------------------------------------------------

/** Deposits this API process has answered (or is answering), by block and transaction hash (a fork started again can
 *  mine the same transaction hash): a replay gets the first answer, never another report paid by the API signer. A
 *  failed attempt is forgotten, so it can be retried. */
const answeredDeposits = new Map<string, ReturnType<typeof publishReportsAfter>>();

/** DEC-159: after a deposit a report is published on every spoke of the fund and delivered on the Hub, so the new
 *  shares start earning spoke income from the next report (DEC-145). The API publishes with its own key; the VAA is
 *  delivered by the keeper (the guardians and relayer of production) or, when none runs, by the API with the harness's
 *  guardian. Anyone may do both; a depositor who skips it only delays his own income. Once per deposit: a replayed
 *  hash gets the first answer, and a spoke whose report accepted on the Hub is already later than the deposit gets no
 *  new one (an API restart, the keeper's cadence or another publisher already covered it). */
export async function reportAfterDeposit(state: DeploymentState, txHash: Hex, deliverer: "keeper" | "api") {
  const receipt = await nodes.arbitrum.client.getTransactionReceipt({ hash: txHash }).catch(() => undefined);
  if (!receipt) throw new HttpError(404, `no transaction ${txHash} on the hub`);
  const key = `${receipt.blockHash}:${receipt.transactionHash}`.toLowerCase();
  let answer = answeredDeposits.get(key);
  if (!answer) {
    answer = publishReportsAfter(state, receipt, deliverer);
    answeredDeposits.set(key, answer);
    answer.catch(() => answeredDeposits.delete(key));
  }
  return answer;
}

async function publishReportsAfter(state: DeploymentState, receipt: TransactionReceipt, deliverer: "keeper" | "api") {
  const fund = hub(state);
  const deposits = receipt.logs
    .filter((l) => l.address.toLowerCase() === fund.hub.coreVault.toLowerCase())
    .map((l) => {
      try {
        return decodeEventLog({ abi: coreVaultAbi, data: l.data, topics: l.topics }) as unknown as { eventName: string; args: Record<string, any> };
      } catch {
        return undefined;
      }
    })
    .filter((e) => e?.eventName === "Deposited");
  if (deposits.length === 0) throw new HttpError(422, "the transaction is not a deposit into this fund");
  const depositTime = (await nodes.arbitrum.client.getBlock({ blockNumber: receipt.blockNumber })).timestamp;
  const spokes: SpokeRef[] = [
    { fundId: fund.fundId, spokeVault: fund.spoke.spokeVault, receiver: fund.hub.valueReportReceiver, spokeIndex: fund.spoke.spokeIndex },
  ];
  const reports = [];
  for (const spoke of spokes) {
    const accepted = async () => {
      const args = [BigInt(spoke.spokeIndex)];
      if (!(await read<boolean>("arbitrum", { address: spoke.receiver, abi: valueReportReceiverAbi, functionName: "hasReport", args }))) return undefined;
      const [latest] = await read<readonly [{ sequence: bigint; timestamp: bigint }, bigint, bigint]>("arbitrum", {
        address: spoke.receiver,
        abi: valueReportReceiverAbi,
        functionName: "latestReport",
        args,
      });
      return latest;
    };
    const covering = await accepted();
    if (covering && covering.timestamp > depositTime) {
      reports.push({
        chainId: nodes.robinhood.chain.id,
        spokeVault: spoke.spokeVault,
        published: false,
        reportSequence: covering.sequence,
        reportTimestamp: covering.timestamp,
        deliveredBy: "nobody: the Hub had already accepted a report later than the deposit",
        hubReportSequence: covering.sequence,
      });
      continue;
    }
    const published = await publishReport(spoke, "apiSigner");
    let deliveredBy: string;
    if (deliverer === "keeper") {
      await waitForDelivery(spoke, published.wormholeSequence, 120);
      deliveredBy = "keeper";
    } else {
      await deliverDirectly(spoke, published.message, "apiSigner");
      deliveredBy = "api (no keeper running: VAA signed by the harness guardian)";
    }
    reports.push({
      chainId: nodes.robinhood.chain.id,
      spokeVault: spoke.spokeVault,
      published: true,
      reportSequence: published.reportSequence,
      wormholeSequence: published.wormholeSequence,
      publishTx: published.tx,
      reportTimestamp: published.message.timestamp,
      deliveredBy,
      hubReportSequence: (await accepted())!.sequence,
    });
  }
  const d = deposits[0]!.args;
  return {
    deposit: { tx: receipt.transactionHash, block: receipt.blockNumber, shareholder: d.shareholder, shares: d.shares, sharePrice: d.sharePrice },
    reports,
  };
}

// ---------------------------------------------------------------------------------------------------------------------
// HTTP
// ---------------------------------------------------------------------------------------------------------------------

export interface ApiOptions {
  /** Serve this fund instead of the state file's default fund. */
  fund?: FundRecord;
  /** A keeper runs in this process (the probe's), so reports are left to it to deliver. */
  keeperInProcess?: boolean;
}

type Handler = (state: DeploymentState, m: RegExpMatchArray, url: URL, body: Record<string, string>, options: ApiOptions) => Promise<unknown>;

const routes: { method: string; pattern: RegExp; handler: Handler }[] = [
  { method: "GET", pattern: /^\/health$/, handler: (s) => health(s) },
  { method: "GET", pattern: /^\/fund$/, handler: (s) => fundState(s) },
  { method: "GET", pattern: /^\/holders\/(0x[0-9a-fA-F]{40})$/, handler: (s, m) => holderState(s, m[1] as Address) },
  { method: "GET", pattern: /^\/quote\/deposit$/, handler: (s, _m, u) => quoteDeposit(s, addressParam(u.searchParams.get("from") ?? undefined, "from"), amountParam(u.searchParams.get("amount") ?? undefined, "amount")) },
  { method: "GET", pattern: /^\/quote\/claim$/, handler: (s, _m, u) => quoteClaim(s, addressParam(u.searchParams.get("from") ?? undefined, "from")) },
  { method: "GET", pattern: /^\/quote\/swap$/, handler: (s, _m, u) => quoteSwap(s, addressParam(u.searchParams.get("tokenIn") ?? undefined, "tokenIn"), amountParam(u.searchParams.get("amountIn") ?? undefined, "amountIn")) },
  { method: "POST", pattern: /^\/tx\/deposit$/, handler: (s, _m, _u, b) => buildDeposit(s, addressParam(b.from, "from"), amountParam(b.amount, "amount"), b.minShares ? amountParam(b.minShares, "minShares") : 0n) },
  { method: "POST", pattern: /^\/tx\/request$/, handler: async (s, _m, _u, b) => buildRequest(s, amountParam(b.amount, "amount"), b.mode === "standard" ? "standard" : "instant") },
  { method: "POST", pattern: /^\/tx\/claim$/, handler: (s) => buildClaim(s) },
  { method: "POST", pattern: /^\/tx\/swap$/, handler: (s, _m, _u, b) => buildSwap(s, addressParam(b.tokenIn, "tokenIn"), amountParam(b.amountIn, "amountIn"), b.slippageBps ? amountParam(b.slippageBps, "slippageBps") : API_SLIPPAGE_BPS) },
  {
    method: "GET",
    pattern: /^\/quote\/swap-route$/,
    handler: (s, _m, u) =>
      quoteSwapRoute(
        s,
        sideParam(u.searchParams.get("chain") ?? undefined),
        addressParam(u.searchParams.get("tokenIn") ?? undefined, "tokenIn"),
        addressParam(u.searchParams.get("tokenOut") ?? undefined, "tokenOut"),
        amountParam(u.searchParams.get("amountIn") ?? undefined, "amountIn"),
        u.searchParams.has("slippageBps") ? amountParam(u.searchParams.get("slippageBps") ?? undefined, "slippageBps") : API_SLIPPAGE_BPS,
        u.searchParams.get("adapter") ?? undefined,
        hopsParam(u.searchParams.get("hops") ?? undefined),
      ),
  },
  {
    method: "GET",
    pattern: /^\/quote\/bridge$/,
    handler: (s, _m, u) => {
      const direction = u.searchParams.get("direction");
      if (direction !== "to-spoke" && direction !== "to-hub") throw new HttpError(400, "direction must be to-spoke or to-hub");
      return quoteBridge(s, direction, amountParam(u.searchParams.get("amount") ?? undefined, "amount"));
    },
  },
  {
    method: "GET",
    pattern: /^\/share-price\/history$/,
    handler: (s, _m, u) =>
      sharePriceHistory(
        hub(s),
        u.searchParams.has("fromBlock") ? amountParam(u.searchParams.get("fromBlock") ?? undefined, "fromBlock") : undefined,
        u.searchParams.has("toBlock") ? amountParam(u.searchParams.get("toBlock") ?? undefined, "toBlock") : undefined,
      ),
  },
  {
    method: "POST",
    pattern: /^\/report\/after-deposit$/,
    handler: (s, _m, _u, b, o) => {
      if (!b.txHash || !/^0x[0-9a-fA-F]{64}$/.test(b.txHash)) throw new HttpError(400, "txHash must be a transaction hash");
      return reportAfterDeposit(s, b.txHash as Hex, o.keeperInProcess || runningKeeperPid() ? "keeper" : "api");
    },
  },
  { method: "GET", pattern: /^\/events$/, handler: (s, _m, u) => coreEvents(s, BigInt(u.searchParams.get("fromBlock") ?? hub(s).hub.createdInBlock)) },
];

function json(res: ServerResponse, status: number, payload: unknown) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(payload, (_k, v) => (typeof v === "bigint" ? v.toString() : v), 2));
}

async function readBody(req: IncomingMessage): Promise<Record<string, string>> {
  const chunks: Buffer[] = [];
  for await (const chunk of req) chunks.push(chunk as Buffer);
  if (chunks.length === 0) return {};
  try {
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  } catch {
    throw new HttpError(400, "body must be JSON");
  }
}

export function startApi(port = API_PORT, options: ApiOptions = {}) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", `http://127.0.0.1:${port}`);
    const route = routes.find((r) => r.method === req.method && r.pattern.test(url.pathname));
    if (!route) return json(res, 404, { error: "not found" });
    try {
      const state = options.fund ? { ...readState(), fund: options.fund } : readState();
      const body = req.method === "POST" ? await readBody(req) : {};
      json(res, 200, await route.handler(state, url.pathname.match(route.pattern)!, url, body, options));
    } catch (err) {
      if (err instanceof HttpError) return json(res, err.status, { error: err.message, detail: err.detail });
      json(res, 500, { error: redactUrls((err as Error).message), revert: decodeRevert(err) });
    }
  });
  return new Promise<typeof server>((resolve) => server.listen(port, "127.0.0.1", () => resolve(server)));
}

if (isMain(import.meta.url)) {
  startApi().then(() => console.log(`local-e2e API on http://127.0.0.1:${API_PORT}`));
}
