// Chainlink ETH / USD on the hub fork. Nobody posts new rounds on a fork, so the feed's `updatedAt` ages with the node
// clock and, past the price source's `maxPriceAge` (1 hour), every mint reverts with `StalePrice` (OQ-10). The harness
// re-stamps the latest round with the current block time and keeps its answer, as the next Chainlink round would
// (the fork scenario does the same with a mocked call, test/fork/e2e/EndToEndBase.sol `_refreshEthUsdFeed`).
//
// The feed is an OCR2 aggregator behind a proxy: its latest round is a storage word
// `transmissionTimestamp (uint32) | observationsTimestamp (uint32) | answer (int192)`, found by tracing
// `latestRoundData` and matching the answer and timestamp it returned.
import { hexToBigInt, pad, toHex, type Address, type Hex } from "viem";
import { chainlinkAggregatorAbi } from "./abis.ts";
import { anvil, latestTimestamp, nodes, read, type Side } from "./chain.ts";
import { ARBITRUM } from "./config.ts";
import { storageRead } from "./fund-accounts.ts";
import type { Logger } from "./log.ts";

const MASK_192 = (1n << 192n) - 1n;
const MASK_32 = (1n << 32n) - 1n;

interface RoundData {
  answer: bigint;
  startedAt: bigint;
  updatedAt: bigint;
}

export async function latestRound(side: Side = "arbitrum", feed: Address = ARBITRUM.ethUsdFeed): Promise<RoundData> {
  const [, answer, startedAt, updatedAt] = await read<readonly [bigint, bigint, bigint, bigint, bigint]>(side, {
    address: feed,
    abi: chainlinkAggregatorAbi,
    functionName: "latestRoundData",
  });
  return { answer, startedAt, updatedAt };
}

/** The aggregator and the storage slot that holds the latest round's answer and timestamps. */
async function transmissionSlot(side: Side, feed: Address): Promise<{ aggregator: Address; slot: Hex }> {
  const aggregator = await read<Address>(side, { address: feed, abi: chainlinkAggregatorAbi, functionName: "aggregator" });
  const round = await latestRound(side, feed);
  const keys = await storageRead(side, aggregator, "0xfeaf968c"); // latestRoundData()
  for (const slot of keys) {
    const value = hexToBigInt((await nodes[side].client.getStorageAt({ address: aggregator, slot })) ?? "0x0");
    const answer = BigInt.asIntN(192, value & MASK_192);
    const updatedAt = (value >> 224n) & MASK_32;
    if (answer === round.answer && updatedAt === round.updatedAt) return { aggregator, slot };
  }
  throw new Error(`could not locate the latest round of the Chainlink feed ${feed}`);
}

/** Re-stamps the latest round with `timestamp` (default: the latest block), keeping the answer. */
export async function restampFeed(
  log: Logger,
  side: Side = "arbitrum",
  feed: Address = ARBITRUM.ethUsdFeed,
  timestamp?: bigint,
): Promise<void> {
  const at = timestamp ?? (await latestTimestamp(side));
  const { aggregator, slot } = await transmissionSlot(side, feed);
  const value = hexToBigInt((await nodes[side].client.getStorageAt({ address: aggregator, slot })) ?? "0x0");
  const next = (at << 224n) | (at << 192n) | (value & MASK_192);
  await anvil.setStorageAt(side, aggregator, slot, pad(toHex(next)));
  const round = await latestRound(side, feed);
  if (round.updatedAt !== at) throw new Error(`Chainlink re-stamp did not stick (updatedAt ${round.updatedAt})`);
  log.info("Chainlink ETH / USD re-stamped", { answer: round.answer, updatedAt: at });
}

/** Re-stamps the feed when its round is older than `maxAgeSeconds` on the node clock. */
export async function ensureFeedFresh(log: Logger, maxAgeSeconds: bigint, side: Side = "arbitrum"): Promise<boolean> {
  const [round, now] = await Promise.all([latestRound(side), latestTimestamp(side)]);
  if (now - round.updatedAt <= maxAgeSeconds) return false;
  await restampFeed(log, side);
  return true;
}
