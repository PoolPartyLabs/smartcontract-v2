// A fund's history read back from the chain: the Share Price at every hub block where the Core Vault emitted an event
// (DEC-084, DEC-103: the Share Price is the published number), and the fee ledger summed from the vaults' events. The
// API's GET /share-price/history serves the first; the run reports print both.
import type { Abi, Address } from "viem";
import { coreVaultAbi, shareTokenAbi, spokeVaultAbi } from "./abis.ts";
import { nodes, read, type Side } from "./chain.ts";
import type { FundRecord } from "./state.ts";

export interface SharePricePoint {
  block: bigint;
  timestamp: bigint;
  /** USDC base units per whole share, times 1e18 (ShareMath.PRICE_SCALE). */
  sharePrice: bigint;
  shareAssets: bigint;
  totalShares: bigint;
  /** The Core Vault events of the block, in log order. */
  events: string[];
}

interface DecodedEvent {
  blockNumber: bigint;
  eventName: string;
  args: Record<string, any>;
}

async function eventsOf(side: Side, address: Address, abi: Abi, fromBlock: bigint, toBlock?: bigint): Promise<DecodedEvent[]> {
  const logs = await nodes[side].client.getContractEvents({ address, abi, fromBlock, toBlock: toBlock ?? "latest" });
  return logs.map((l) => ({ blockNumber: l.blockNumber, eventName: (l as { eventName: string }).eventName, args: (l as { args: Record<string, any> }).args }));
}

/** One point per hub block with a Core Vault event since `fromBlock` (default: the fund's creation block), with the
 *  Share Price, Share Assets and total shares read at that block. */
export async function sharePriceHistory(fund: FundRecord, fromBlock?: bigint, toBlock?: bigint): Promise<SharePricePoint[]> {
  const core = fund.hub.coreVault;
  const events = await eventsOf("arbitrum", core, coreVaultAbi, fromBlock ?? BigInt(fund.hub.createdInBlock), toBlock);
  const blocks = new Map<bigint, string[]>();
  for (const e of events) blocks.set(e.blockNumber, [...(blocks.get(e.blockNumber) ?? []), e.eventName]);
  const points: SharePricePoint[] = [];
  for (const [block, names] of blocks) {
    const at = (functionName: string) => read<bigint>("arbitrum", { address: core, abi: coreVaultAbi, functionName }, undefined, block);
    const [sharePrice, shareAssets, totalShares, header] = await Promise.all([
      at("sharePrice"),
      at("shareAssets"),
      read<bigint>("arbitrum", { address: fund.hub.shareToken, abi: shareTokenAbi, functionName: "totalSupply" }, undefined, block),
      nodes.arbitrum.client.getBlock({ blockNumber: block }),
    ]);
    points.push({ block, timestamp: header.timestamp, sharePrice, shareAssets, totalShares, events: names });
  }
  return points;
}

/** Per-token sums of the performance fee charged at collection (ruling 2026-09-29; DEC-106, DEC-107, DEC-109). */
export interface PerformanceFeeLine {
  token: Address;
  /** Income collected, gross. */
  collected: bigint;
  /** The whole performance fee: the manager's part plus the protocol slice. */
  performanceFee: bigint;
  /** To the ManagerFeeVault. */
  managerPart: bigint;
  /** To the Protocol Recipient (DEC-106, DEC-110). */
  protocolSlice: bigint;
  /** Net to the holders. */
  toHolders: bigint;
}

export interface FeeLedger {
  /** DEC-106: the flow fee of the seed, the deposits and the payouts, to the Protocol Recipient (USDC). */
  flowFee: { seed: bigint; deposits: bigint; payouts: bigint; total: bigint };
  /** DEC-102, DEC-144: Payout Fees, kept in Idle for the holders who stay (USDC). */
  payoutFee: bigint;
  performanceFee: PerformanceFeeLine[];
  /** DEC-108, DEC-114: management fee accrued; null while the Core Vault has no accrual (WP-07). */
  managementFeeAccrued: bigint | null;
  /** DEC-085, DEC-162: what the bridge adapters left to relayers per direction (amount sent minus amount to arrive),
   *  and the number of sends. */
  bridgeFees: { toSpokes: bigint; toSpokesSends: number; toHub: bigint; toHubSends: number };
}

/** The fund's fee ledger from its creation: Core Vault events on the hub and the Robinhood Spoke Vault's sends home. */
export async function feeLedger(fund: FundRecord): Promise<FeeLedger> {
  const core = fund.hub.coreVault;
  const hubEvents = await eventsOf("arbitrum", core, coreVaultAbi, BigInt(fund.hub.createdInBlock));
  const spokeEvents = await eventsOf("robinhood", fund.spoke.spokeVault, spokeVaultAbi, BigInt(fund.spoke.createdInBlock));
  const ledger: FeeLedger = {
    flowFee: { seed: 0n, deposits: 0n, payouts: 0n, total: 0n },
    payoutFee: 0n,
    performanceFee: [],
    managementFeeAccrued: null,
    bridgeFees: { toSpokes: 0n, toSpokesSends: 0, toHub: 0n, toHubSends: 0 },
  };
  const perToken = new Map<string, PerformanceFeeLine>();
  for (const e of hubEvents) {
    const a = e.args;
    if (e.eventName === "FundSeeded") ledger.flowFee.seed += a.flowFee as bigint;
    else if (e.eventName === "Deposited") ledger.flowFee.deposits += a.flowFee as bigint;
    else if (e.eventName === "PayoutExecuted" || e.eventName === "PartialPayoutExecuted") {
      ledger.flowFee.payouts += a.receipt.flowFee as bigint;
      ledger.payoutFee += a.receipt.payoutFee as bigint;
    } else if (e.eventName === "CollectedIncomeReceived") {
      const token = a.token as Address;
      const line = perToken.get(token.toLowerCase()) ?? {
        token,
        collected: 0n,
        performanceFee: 0n,
        managerPart: 0n,
        protocolSlice: 0n,
        toHolders: 0n,
      };
      line.collected += a.amount as bigint;
      line.managerPart += a.managerFee as bigint;
      line.protocolSlice += a.protocolSlice as bigint;
      line.performanceFee = line.managerPart + line.protocolSlice;
      line.toHolders = line.collected - line.performanceFee;
      perToken.set(token.toLowerCase(), line);
    } else if (e.eventName === "SentToSpoke") {
      ledger.bridgeFees.toSpokes += (a.transit.amountSent as bigint) - (a.transit.amountToArrive as bigint);
      ledger.bridgeFees.toSpokesSends++;
    }
  }
  for (const e of spokeEvents) {
    if (e.eventName !== "SentToHub") continue;
    ledger.bridgeFees.toHub += (e.args.transit.amountSent as bigint) - (e.args.transit.amountToArrive as bigint);
    ledger.bridgeFees.toHubSends++;
  }
  ledger.flowFee.total = ledger.flowFee.seed + ledger.flowFee.deposits + ledger.flowFee.payouts;
  ledger.performanceFee = [...perToken.values()];
  if (coreVaultAbi.some((item) => item.type === "function" && item.name === "managementFeeAccrued")) {
    ledger.managementFeeAccrued = await read<bigint>("arbitrum", { address: core, abi: coreVaultAbi, functionName: "managementFeeAccrued" });
  }
  return ledger;
}
