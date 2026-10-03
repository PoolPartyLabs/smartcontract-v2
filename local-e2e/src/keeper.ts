// The keeper: what production gets from Across relayers, the Wormhole guardians and the API's keeper, on the two
// local forks.
//
//   (a) Across relayer: watches `FundsDeposited` on both SpokePools for deposits whose recipient is one of the known
//       funds' vaults on the other node, and fills them there by calling the live SpokePool's own
//       `fillRelay(V3RelayData, repaymentChainId, repaymentAddress)` as a funded relayer (the keeper account): the pool
//       transfers the output token and calls `handleV3AcrossMessage` itself. If that path fails for a reason other
//       than "already filled" or "expired", it falls back to a simulated fill (the SpokePool impersonated: output
//       token dealt to the recipient, handler called from the pool address) and says so.
//   (b) Wormhole guardians and relayer, both ways: every `LogMessagePublished` from a fund emitter becomes a VAA the
//       local guardian signs, delivered to its consumer:
//       - a spoke report (emitter: a known Robinhood Spoke Vault, finalized) after KEEPER_VAA_DELAY_SECONDS (default
//         3; production is 15 to 20 minutes of finality) to `ValueReportReceiver.deliver(vaa)` on the hub (DEC-086);
//       - a Hub order (emitter: a known Core Vault on Arbitrum, instant consistency) after KEEPER_ORDER_DELAY_SECONDS
//         (default 1) to the fund's Robinhood `SpokeVault.executeOrder(vaa)`, paying the Robinhood Core's message fee
//         for the report it publishes in the same transaction (DEC-120, DEC-139). An order whose kind the Spoke Vault
//         does not execute yet (its executor reverts `OrderKindNotSupported` until the unwind, closure and collection
//         orders land) is logged as not yet supported and counted, never retried or treated as a failure.
//   (c) optional `--auto-report <seconds>`: calls `SpokeVault.report()` on every known spoke on a cadence, as the
//       production keeper would (the hub refuses mints once the last report is older than maxReportAge, 1588 s).
//   plus: re-stamps the Chainlink ETH / USD round when it gets old (see price-feed.ts).
//
// Every fund, the deployment's own included, is discovered from the factories' `FundCreated` and `SpokeCreated` events,
// so funds created by the frontend or by `pnpm scenario --new-fund` are served too. Each poll reads both chains and
// registers both chains' creations before it relays anything, so a Hub order always finds its fund's Spoke Vault, on a
// live run as on a restart. Every action is idempotent (fill status and last delivered sequence are checked first), so
// a restart rescans from the fork block safely.
//
// Usage: pnpm keeper [--auto-report <seconds>] [--vaa-delay <seconds>] [--order-delay <seconds>] [--fill-delay <seconds>]
import { existsSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import {
  decodeEventLog,
  encodeAbiParameters,
  encodeFunctionData,
  getAddress,
  keccak256,
  pad,
  type Address,
  type Hex,
  type Log,
} from "viem";
import {
  acrossSpokePoolAbi,
  coreVaultAbi,
  erc20Abi,
  fundFactoryAbi,
  orderChannelAbi,
  spokeVaultAbi,
  valueReportReceiverAbi,
  wormholeCoreAbi,
} from "./abis.ts";
import {
  anvil,
  explain,
  isPrunedStateError,
  nodes,
  read,
  simulateRevert,
  revertOf,
  send,
  type Side,
} from "./chain.ts";
import {
  ARBITRUM,
  KEEPER_PID_FILE,
  ROBINHOOD,
  STATE_DIR,
  WORMHOLE_ARBITRUM,
  WORMHOLE_ROBINHOOD,
  actors,
  isMain,
} from "./config.ts";
import { mappingSlot, setTokenBalance } from "./fund-accounts.ts";
import { guardianSetIndexOf, signVaa, universal } from "./guardian.ts";
import { safeConsole as console, logger, units, type Logger } from "./log.ts";
import { ORDER_KIND_NAME, decodeOrder, orderId } from "./orders.ts";
import {decodeSpokeReport} from "./spoke-report.ts";
import { ensureFeedFresh } from "./price-feed.ts";
import { readState, type BalanceLayout, type DeploymentState } from "./state.ts";
import { PendingTransits, type PendingTransit } from "./pending-transits.ts";

export interface KeeperOptions {
  /** Seconds between a published report and its delivery (production: 15 to 20 minutes of finality). */
  vaaDelaySeconds: number;
  /** Seconds between a published Hub order and its execution on the spoke (instant consistency: seconds). */
  orderDelaySeconds: number;
  /** Seconds between a deposit and its fill (production: seconds to minutes, relayer dependent). */
  fillDelaySeconds: number;
  /** Cadence of `SpokeVault.report()` on every known spoke; 0 disables it. */
  autoReportSeconds: number;
  /** `real` fills through SpokePool.fillRelay; `simulated` impersonates the pool; `auto` tries real first. */
  fillMode: "auto" | "real" | "simulated";
  pollMs: number;
  /** Re-stamp the Chainlink round once it is older than this on the hub clock. */
  feedMaxAgeSeconds: bigint;
  quiet: boolean;
}

export const DEFAULT_KEEPER_OPTIONS: KeeperOptions = {
  vaaDelaySeconds: Number(process.env.KEEPER_VAA_DELAY_SECONDS ?? 3),
  orderDelaySeconds: Number(process.env.KEEPER_ORDER_DELAY_SECONDS ?? 1),
  fillDelaySeconds: Number(process.env.KEEPER_FILL_DELAY_SECONDS ?? 1),
  autoReportSeconds: Number(process.env.KEEPER_AUTO_REPORT_SECONDS ?? 0),
  fillMode: (process.env.KEEPER_FILL_MODE as KeeperOptions["fillMode"]) ?? "auto",
  pollMs: Number(process.env.KEEPER_POLL_MS ?? 500),
  feedMaxAgeSeconds: BigInt(process.env.KEEPER_FEED_MAX_AGE_SECONDS ?? 1800),
  quiet: false,
};

/** One fund as the keeper knows it. */
interface FundEntry {
  fundId: Hex;
  coreVault: Address;
  receiver: Address;
  hubSpokeVault: Address;
  /** Robinhood Spoke Vault, once `SpokeCreated` was seen. */
  spokeVault?: Address;
  spokeIndex: number;
}

export interface KeeperStats {
  fills: number;
  simulatedFills: number;
  deliveries: number;
  /** Hub orders executed on a Spoke Vault. */
  orders: number;
  /** Hub orders the Spoke Vault refused with `OrderKindNotSupported`: their kind's executor is still a stub. The order
   *  checks passed (they run first), and the refusal reverted the whole call, so the order cursor did not move. */
  ordersUnsupported: number;
  reports: number;
  errors: number;
}

export interface Keeper {
  stats: KeeperStats;
  /** Whether the Hub order `sequence` of the Core Vault `emitter` reached its Spoke Vault: executed, already executed,
   *  expired, or refused as a kind the vault does not execute yet. */
  handledOrder(emitter: Address, sequence: bigint): boolean;
  /** Stops polling, cancels scheduled work that has not started, and waits for what is running. */
  stop(): Promise<void>;
}

const OTHER: Record<Side, Side> = { arbitrum: "robinhood", robinhood: "arbitrum" };
const POOL_OF: Record<Side, Address> = { arbitrum: ARBITRUM.acrossSpokePool, robinhood: ROBINHOOD.acrossSpokePool };

const FUND_CREATED = fundFactoryAbi.find((e) => e.type === "event" && e.name === "FundCreated")!;
const SPOKE_CREATED = fundFactoryAbi.find((e) => e.type === "event" && e.name === "SpokeCreated")!;
const FUNDS_DEPOSITED = acrossSpokePoolAbi.find((e) => e.type === "event" && e.name === "FundsDeposited")!;
const MESSAGE_PUBLISHED = wormholeCoreAbi.find((e) => e.type === "event" && e.name === "LogMessagePublished")!;

type DecodedLog = Log & { eventName: string; args: Record<string, any> };

interface RelayData {
  depositor: Hex;
  recipient: Hex;
  exclusiveRelayer: Hex;
  inputToken: Hex;
  outputToken: Hex;
  inputAmount: bigint;
  outputAmount: bigint;
  originChainId: bigint;
  depositId: bigint;
  fillDeadline: number;
  exclusivityDeadline: number;
  message: Hex;
}

const RELAY_DATA_TYPE = {
  type: "tuple",
  components: [
    { name: "depositor", type: "bytes32" },
    { name: "recipient", type: "bytes32" },
    { name: "exclusiveRelayer", type: "bytes32" },
    { name: "inputToken", type: "bytes32" },
    { name: "outputToken", type: "bytes32" },
    { name: "inputAmount", type: "uint256" },
    { name: "outputAmount", type: "uint256" },
    { name: "originChainId", type: "uint256" },
    { name: "depositId", type: "uint256" },
    { name: "fillDeadline", type: "uint32" },
    { name: "exclusivityDeadline", type: "uint32" },
    { name: "message", type: "bytes" },
  ],
} as const;

/** The SpokePool's relay hash: `keccak256(abi.encode(relayData, destinationChainId))`. */
export function relayHash(relay: RelayData, destinationChainId: bigint): Hex {
  return keccak256(encodeAbiParameters([RELAY_DATA_TYPE, { type: "uint256" }], [relay, destinationChainId]));
}

const toAddress = (b: Hex): Address => getAddress(`0x${b.slice(26)}`);

export async function startKeeper(state: DeploymentState, options: KeeperOptions, parent?: Logger): Promise<Keeper> {
  const log = parent ?? logger("keeper", options.quiet);
  const acrossLog = log.child("across");
  const wormholeLog = log.child("wormhole");
  const keeper = actors.keeper;
  const stats: KeeperStats = { fills: 0, simulatedFills: 0, deliveries: 0, orders: 0, ordersUnsupported: 0, reports: 0, errors: 0 };

  const funds = new Map<Hex, FundEntry>();
  const byVault = new Map<string, FundEntry>(); // lowercased Core Vault or Robinhood Spoke Vault -> fund
  const pending = new Set<Promise<unknown>>();
  let stopped = false;
  // The receiving Core's guardian set: Arbitrum for reports, Robinhood for orders.
  const guardianSets: Partial<Record<Side, number>> = {};
  const guardianSetOf = async (side: Side) => (guardianSets[side] ??= await guardianSetIndexOf(side));

  // One entry per fund, updated in place: work scheduled earlier (an order waiting out its delay) reads what discovery
  // learned since, such as the Spoke Vault.
  const register = (entry: FundEntry) => {
    const known = funds.get(entry.fundId);
    const merged = known ? Object.assign(known, Object.fromEntries(Object.entries(entry).filter(([, v]) => v !== undefined))) : entry;
    funds.set(merged.fundId, merged);
    byVault.set(merged.coreVault.toLowerCase(), merged);
    if (merged.spokeVault) byVault.set(merged.spokeVault.toLowerCase(), merged);
    return merged;
  };
  /** `${Core Vault}:${sequence}` of every Hub order that reached its Spoke Vault. */
  const handledOrders = new Set<string>();
  const orderKey = (emitter: Address, sequence: bigint) => `${emitter.toLowerCase()}:${sequence}`;

  const track = <T>(task: Promise<T>) => {
    pending.add(task);
    task.finally(() => pending.delete(task)).catch(() => undefined);
    return task;
  };
  // Delayed work; stop() cancels what has not started yet (a production-like VAA delay can be many minutes).
  const cancels = new Set<() => void>();
  const later = (seconds: number, task: () => Promise<void>) =>
    track(
      new Promise<void>((resolve) => {
        const cancel = () => {
          clearTimeout(timer);
          cancels.delete(cancel);
          resolve();
        };
        const timer = setTimeout(async () => {
          cancels.delete(cancel);
          if (!stopped) {
            try {
              await task();
            } catch (err) {
              stats.errors++;
              log.error(explain(err));
            }
          }
          resolve();
        }, Math.max(0, seconds) * 1000);
        cancels.add(cancel);
      }),
    );

  // --------------------------------------------------------------------------------------------------------------
  // Probe-or-zero-fill: a slot the fork never read needs upstream state at the fork block, which a public RPC
  // prunes after minutes. A mapping entry for a key that only exists on the local fork (a new relay hash, a new
  // vault's balance) is zero upstream, so when the upstream read fails it is written as zero locally instead.
  // --------------------------------------------------------------------------------------------------------------
  async function readOrZeroFill<T>(side: Side, target: Address, slot: Hex, reader: () => Promise<T>, zero: T): Promise<T> {
    try {
      return await reader();
    } catch (err) {
      if (!isPrunedStateError(err)) throw err;
      await anvil.setStorageAt(side, target, slot, pad("0x0"));
      log.warn("upstream state pruned; zero-filled a fresh mapping slot", { chain: nodes[side].chain.id, target, slot });
      return zero;
    }
  }

  function balanceLayout(side: Side, token: Address): BalanceLayout | undefined {
    return state.storage.balances[side].find((l) => l.token.toLowerCase() === token.toLowerCase());
  }

  async function tokenBalance(side: Side, token: Address, holder: Address): Promise<bigint> {
    const layout = balanceLayout(side, token);
    const reader = () => read<bigint>(side, { address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] });
    if (!layout) return reader();
    return readOrZeroFill(side, token, mappingSlot(holder, BigInt(layout.mappingSlot)), reader, 0n);
  }

  // --------------------------------------------------------------------------------------------------------------
  // (a) Across fills
  // --------------------------------------------------------------------------------------------------------------

  async function fillStatus(side: Side, hash: Hex): Promise<bigint> {
    const index = state.storage.acrossFillStatusesSlot[side];
    const reader = () =>
      read<bigint>(side, { address: POOL_OF[side], abi: acrossSpokePoolAbi, functionName: "fillStatuses", args: [hash] });
    if (!index) return reader();
    return readOrZeroFill(side, POOL_OF[side], mappingSlot(hash, BigInt(index)), reader, 0n);
  }

  async function ensureInventory(side: Side, token: Address, amount: bigint) {
    const held = await tokenBalance(side, token, keeper.address);
    if (held >= amount) return;
    const layout = balanceLayout(side, token);
    if (!layout) throw new Error(`relayer holds ${held} of ${token} and the harness cannot mint it`);
    await setTokenBalance(side, layout, keeper.address, amount + 1_000_000n * 10n ** 6n);
    acrossLog.info("relayer inventory topped up", { chain: nodes[side].chain.id, token });
  }

  async function fillReal(destination: Side, relay: RelayData) {
    const pool = POOL_OF[destination];
    const token = toAddress(relay.outputToken);
    await ensureInventory(destination, token, relay.outputAmount);
    const allowance = await read<bigint>(destination, {
      address: token,
      abi: erc20Abi,
      functionName: "allowance",
      args: [keeper.address, pool],
    });
    if (allowance < relay.outputAmount) {
      await send(destination, "keeper", { address: token, abi: erc20Abi, functionName: "approve", args: [pool, 2n ** 255n] });
    }
    return send(destination, "keeper", {
      address: pool,
      abi: acrossSpokePoolAbi,
      functionName: "fillRelay",
      args: [relay, BigInt(nodes[destination].chain.id), universal(keeper.address)],
    });
  }

  /** Fallback: what the fork suites do (docs/INTEGRATIONS.md): the pool's address delivers the output token and calls
   *  the handler. Used only when the real fill path is unavailable. */
  async function fillSimulated(destination: Side, relay: RelayData) {
    const pool = POOL_OF[destination];
    const token = toAddress(relay.outputToken);
    const recipient = toAddress(relay.recipient);
    await ensureInventory(destination, token, relay.outputAmount);
    await send(destination, "keeper", { address: token, abi: erc20Abi, functionName: "transfer", args: [recipient, relay.outputAmount] });
    await anvil.setBalance(destination, pool, 10n ** 20n);
    await anvil.impersonate(destination, pool);
    try {
      const hash = await nodes[destination].client.request({
        method: "eth_sendTransaction",
        params: [
          {
            from: pool,
            to: recipient,
            data: encodeFunctionData({
              abi: spokeVaultAbi,
              functionName: "handleV3AcrossMessage",
              args: [token, relay.outputAmount, keeper.address, relay.message],
            }),
          },
        ],
      } as never);
      const receipt = await nodes[destination].client.waitForTransactionReceipt({ hash: hash as Hex });
      if (receipt.status !== "success") throw new Error(`simulated fill ${hash} reverted`);
      return { hash: hash as Hex };
    } finally {
      await anvil.stopImpersonating(destination, pool);
    }
  }

  async function fill(origin: Side, deposit: DecodedLog) {
    const destination = OTHER[origin];
    const a = deposit.args;
    const relay: RelayData = {
      depositor: a.depositor,
      recipient: a.recipient,
      exclusiveRelayer: a.exclusiveRelayer,
      inputToken: a.inputToken,
      outputToken: a.outputToken,
      inputAmount: a.inputAmount,
      outputAmount: a.outputAmount,
      originChainId: BigInt(nodes[origin].chain.id),
      depositId: a.depositId,
      fillDeadline: Number(a.fillDeadline),
      exclusivityDeadline: Number(a.exclusivityDeadline),
      message: a.message,
    };
    const hash = relayHash(relay, BigInt(nodes[destination].chain.id));
    const fields = { origin: nodes[origin].chain.id, depositId: relay.depositId, relayHash: hash.slice(0, 18) };
    if ((await fillStatus(destination, hash)) === 2n) {
      acrossLog.info("already filled", fields);
      return;
    }
    const now = (await nodes[destination].client.getBlock()).timestamp;
    if (BigInt(relay.fillDeadline) < now) {
      acrossLog.warn("fill deadline passed; the deposit will be refunded to its escrow on the origin chain", fields);
      return;
    }
    const exclusive = toAddress(relay.exclusiveRelayer);
    const noExclusive = BigInt(relay.exclusiveRelayer) === 0n;
    if (!noExclusive && BigInt(relay.exclusivityDeadline) >= now && exclusive !== keeper.address) {
      acrossLog.warn("deposit is exclusive to another relayer until its exclusivity deadline; not filling", { ...fields, exclusive });
      return;
    }
    if (options.fillMode !== "simulated") {
      try {
        const sent = await fillReal(destination, relay);
        stats.fills++;
        acrossLog.info("filled through SpokePool.fillRelay", { ...fields, chain: nodes[destination].chain.id, tx: sent.hash });
        return;
      } catch (err) {
        const revert = revertOf(err)?.name;
        if (revert === "RelayFilled" || revert === "ExpiredFillDeadline" || options.fillMode === "real") throw err;
        acrossLog.warn(`real fill failed (${explain(err).split("\n")[0]}); falling back to a simulated fill`, fields);
      }
    }
    const sent = await fillSimulated(destination, relay);
    stats.fills++;
    stats.simulatedFills++;
    acrossLog.warn("filled by SIMULATION (SpokePool impersonated, handler called from the pool address)", {
      ...fields,
      tx: sent.hash,
    });
  }

  function onDeposit(origin: Side, deposit: DecodedLog) {
    const destination = OTHER[origin];
    const a = deposit.args;
    if (BigInt(a.destinationChainId) !== BigInt(nodes[destination].chain.id)) return;
    // Only deposits to a known fund's vault on the destination: its Spoke Vault on Robinhood, its Core Vault on the hub.
    const recipient = toAddress(a.recipient).toLowerCase();
    const fund = byVault.get(recipient);
    const vault = destination === "robinhood" ? fund?.spokeVault : fund?.coreVault;
    if (!fund || vault?.toLowerCase() !== recipient) return;
    acrossLog.info("deposit seen", {
      origin: nodes[origin].chain.id,
      destination: nodes[destination].chain.id,
      depositId: a.depositId,
      recipient: toAddress(a.recipient),
      output: units(a.outputAmount),
      fillIn: `${options.fillDelaySeconds}s`,
    });
    later(options.fillDelaySeconds, () => fill(origin, deposit));
  }

  // --------------------------------------------------------------------------------------------------------------
  // (b) Wormhole deliveries, in sequence order per emitter
  // --------------------------------------------------------------------------------------------------------------

  const deliveryChains = new Map<string, Promise<void>>();

  /** Runs `task` after `delaySeconds`, after every earlier delivery of the same emitter (sequence order). */
  function inSequence(emitter: Address, delaySeconds: number, task: () => Promise<void>) {
    const key = emitter.toLowerCase();
    const deliverAt = Date.now() + delaySeconds * 1000;
    const previous = deliveryChains.get(key) ?? Promise.resolve();
    const next = previous.then(() => later((deliverAt - Date.now()) / 1000, task));
    deliveryChains.set(key, next);
    track(next);
  }

  const transits = new PendingTransits(join(STATE_DIR, "pending-transits.json"), state.createdAt);

  async function acknowledgePrincipal(fund: FundEntry) {
    const [report] = await read<readonly [any, bigint, bigint]>("arbitrum", { address: fund.receiver, abi: valueReportReceiverAbi, functionName: "latestReport", args: [BigInt(fund.spokeIndex)] });
    for (const transit of report.inFlightToHub) {
      if (Number(transit.kind) !== 0) continue;
      queueTransit(fund, transit.transitId);
    }
  }

  function queueTransit(fund: FundEntry, transitId: Hex) {
    if (!fund.spokeVault) return;
    transits.add({ key: `${fund.coreVault.toLowerCase()}:${transitId}`, coreVault: fund.coreVault, spokeVault: fund.spokeVault, receiver: fund.receiver, spokeIndex: fund.spokeIndex, transitId });
  }

  async function retryTransit(entry: PendingTransit): Promise<boolean> {
    const fund = byVault.get(entry.coreVault.toLowerCase());
    if (!fund?.spokeVault) return false;
    const transit = await read<any>("robinhood", { address: fund.spokeVault, abi: spokeVaultAbi, functionName: "hubBoundTransit", args: [entry.transitId] });
    if ([2, 3].includes(Number(transit.state))) return true;
    const currentBlock = await nodes.robinhood.client.getBlock();
    if (Number(transit.state) === 1 && currentBlock.timestamp > BigInt(transit.fillDeadline) + 3n * 86_400n) return true;
    if (!entry.acknowledgement) {
      const value = await read<bigint>("arbitrum", { address: ARBITRUM.wormholeCore, abi: wormholeCoreAbi, functionName: "messageFee" });
      const call = { address: fund.coreVault, abi: coreVaultAbi, functionName: "acknowledgeSpokeTransit", args: [BigInt(fund.spokeIndex), entry.transitId], value };
      if (await simulateRevert("arbitrum", "keeper", call)) return false;
      const sent = await send("arbitrum", "keeper", call);
      const published = sent.receipt.logs.find((event) => event.address.toLowerCase() === ARBITRUM.wormholeCore.toLowerCase());
      if (!published) throw new Error("ACK receipt has no Wormhole message");
      const decoded = decodeEventLog({ abi: wormholeCoreAbi, ...published }) as any;
      const block = await nodes.arbitrum.client.getBlock({ blockNumber: sent.receipt.blockNumber });
      entry.acknowledgement = { payload: decoded.args.payload, sequence: String(decoded.args.sequence), nonce: Number(decoded.args.nonce), consistencyLevel: Number(decoded.args.consistencyLevel), timestamp: Number(block.timestamp) };
      transits.save();
    }
    const acknowledgement = entry.acknowledgement;
    const order = decodeOrder(acknowledgement.payload as Hex);
    const block = await nodes.robinhood.client.getBlock();
    if (order && block.timestamp > order.deadline) {
      delete entry.acknowledgement;
      return false;
    }
    const message = { args: { ...acknowledgement, sender: fund.coreVault, sequence: BigInt(acknowledgement.sequence) } };
    const emitter = fund.coreVault.toLowerCase();
    const previous = deliveryChains.get(emitter) ?? Promise.resolve();
    const execution = previous.then(() => executeOrder(fund, message, acknowledgement.timestamp, true));
    deliveryChains.set(emitter, execution.then(() => {}, () => {}));
    let executed: boolean;
    try {
      executed = await execution;
    } catch (error) {
      if (["OrderSequenceTooLow", "OrderExpired"].includes(revertOf(error)?.name ?? "")) delete entry.acknowledgement;
      throw error;
    }
    if (executed) handledOrders.add(orderKey(fund.coreVault, BigInt(acknowledgement.sequence)));
    return executed;
  }

  async function deliver(fund: FundEntry, message: DecodedLog, blockTimestamp: number) {
    const a = message.args;
    decodeSpokeReport(a.payload);
    const sequence = a.sequence as bigint;
    const fields = { emitter: fund.spokeVault, sequence };
    const [hasReport, last] = await Promise.all([
      read<boolean>("arbitrum", { address: fund.receiver, abi: valueReportReceiverAbi, functionName: "hasReport", args: [BigInt(fund.spokeIndex)] }),
      read<bigint>("arbitrum", { address: fund.receiver, abi: valueReportReceiverAbi, functionName: "lastWormholeSequence", args: [BigInt(fund.spokeIndex)] }),
    ]);
    if (hasReport && last >= sequence) {
      wormholeLog.info("already delivered", fields);
      await acknowledgePrincipal(fund);
      return;
    }
    const hubHeader = await nodes.arbitrum.client.getBlock();
    const maxAge = BigInt(await read<number>("arbitrum", { address: fund.receiver, abi: valueReportReceiverAbi, functionName: "maxReportAge", args: [BigInt(fund.spokeIndex)] }));
    if (hubHeader.timestamp > BigInt(blockTimestamp) + maxAge) {
      wormholeLog.warn("report made stale by a harness warp; waiting for the fresh report", fields);
      return;
    }
    const vaa = await signVaa(
      {
        timestamp: blockTimestamp,
        nonce: Number(a.nonce),
        emitterChainId: WORMHOLE_ROBINHOOD,
        emitterAddress: universal(a.sender),
        sequence,
        consistencyLevel: Number(a.consistencyLevel),
        payload: a.payload,
      },
      await guardianSetOf("arbitrum"),
    );
    try {
      const sent = await send<readonly [bigint, bigint]>("arbitrum", "keeper", {
        address: fund.receiver,
        abi: valueReportReceiverAbi,
        functionName: "deliver",
        args: [vaa],
      });
      stats.deliveries++;
      wormholeLog.info("VAA delivered to ValueReportReceiver", {
        ...fields,
        reportSequence: sent.result[1],
        receiver: fund.receiver,
        tx: sent.hash,
      });
      await acknowledgePrincipal(fund);
    } catch (err) {
      const revert = revertOf(err)?.name;
      if (revert === "SequenceNotIncreasing" || revert === "ReportSequenceNotIncreasing") {
        wormholeLog.info("superseded by a later report", fields);
        return;
      }
      throw err;
    }
  }

  async function onReportMessage(message: DecodedLog) {
    const fund = byVault.get((message.args.sender as Address).toLowerCase());
    if (!fund || fund.spokeVault?.toLowerCase() !== (message.args.sender as Address).toLowerCase()) return;
    const block = await nodes.robinhood.client.getBlock({ blockNumber: message.blockNumber! });
    wormholeLog.info("report published", {
      emitter: fund.spokeVault,
      sequence: message.args.sequence,
      consistency: message.args.consistencyLevel,
      deliverIn: `${options.vaaDelaySeconds}s`,
    });
    // Deliveries of one emitter run in sequence order, each no earlier than its own publication plus the delay.
    inSequence(fund.spokeVault!, options.vaaDelaySeconds, () => deliver(fund, message, Number(block.timestamp)));
  }

  /** DEC-120 items 1-2, DEC-139: the order VAA, signed for the Robinhood Core, executed on the fund's Spoke Vault by
   *  the keeper (any address may), paying the message fee of the report `executeOrder` publishes. Returns whether the
   *  order reached the Spoke Vault. */
  async function executeOrder(fund: FundEntry, message: Pick<DecodedLog, "args">, blockTimestamp: number, retryAcknowledgement = false): Promise<boolean> {
    const a = message.args;
    const order = decodeOrder(a.payload);
    const fields = {
      emitter: fund.coreVault,
      sequence: a.sequence as bigint,
      kind: order ? ORDER_KIND_NAME[order.kind] ?? order.kind : "undecodable",
      orderId: order ? orderId(order).slice(0, 18) : undefined,
      spokeVault: fund.spokeVault,
    };
    // Both chains' creations are registered before any order is dispatched, so this is a fund whose Robinhood spoke
    // was never created.
    if (!fund.spokeVault) {
      wormholeLog.warn("Hub order for a fund with no Robinhood Spoke Vault; not relayed", fields);
      return false;
    }
    const vaa = await signVaa(
      {
        timestamp: blockTimestamp,
        nonce: Number(a.nonce),
        emitterChainId: WORMHOLE_ARBITRUM,
        emitterAddress: universal(a.sender),
        sequence: a.sequence,
        consistencyLevel: Number(a.consistencyLevel),
        payload: a.payload,
      },
      await guardianSetOf("robinhood"),
    );
    const fee = await read<bigint>("robinhood", { address: ROBINHOOD.wormholeCore, abi: wormholeCoreAbi, functionName: "messageFee" });
    try {
      const sent = await send<bigint>("robinhood", "keeper", {
        address: fund.spokeVault,
        abi: orderChannelAbi,
        functionName: "executeOrder",
        args: [vaa],
        value: fee,
      });
      stats.orders++;
      wormholeLog.info("Hub order executed on the Spoke Vault", { ...fields, reportSequence: sent.result, tx: sent.hash });
    } catch (err) {
      const revert = revertOf(err)?.name;
      if (revert === "OrderSequenceTooLow") {
        if (retryAcknowledgement) throw err;
        wormholeLog.info("order already executed or superseded by a later one", fields);
        return true;
      }
      if (revert === "OrderExpired") {
        if (retryAcknowledgement) throw err;
        wormholeLog.warn("order expired before delivery; the request's retry republishes it (DEC-151)", fields);
        return true;
      }
      if (revert === "OrderKindNotSupported") {
        // The order checks passed and the kind's executor is still a stub (the spoke unwind, closure and collection
        // orders land with WP-12, WP-13 and WP-10). Not a failure: logged, counted and not retried, since the same
        // code refuses the same VAA the same way; the whole call reverted, so the order cursor did not move.
        stats.ordersUnsupported++;
        wormholeLog.warn("Hub order not yet supported by the Spoke Vault (OrderKindNotSupported): not executed", fields);
        return true;
      }
      throw err;
    }
    return true;
  }

  async function onOrderMessage(message: DecodedLog) {
    const sender = (message.args.sender as Address).toLowerCase();
    const fund = byVault.get(sender);
    if (!fund || fund.coreVault.toLowerCase() !== sender) return;
    const block = await nodes.arbitrum.client.getBlock({ blockNumber: message.blockNumber! });
    const sequence = message.args.sequence as bigint;
    const order = decodeOrder(message.args.payload);
    if (order?.kind === 4) {
      queueTransit(fund, order.requestId);
      const entry = transits.entries.get(`${fund.coreVault.toLowerCase()}:${order.requestId}`);
      if (entry && (!entry.acknowledgement || BigInt(entry.acknowledgement.sequence) < sequence)) {
        entry.acknowledgement = { payload: message.args.payload, sequence: String(sequence), timestamp: Number(block.timestamp), nonce: Number(message.args.nonce), consistencyLevel: Number(message.args.consistencyLevel) };
        transits.save();
      }
      return;
    }
    wormholeLog.info("Hub order published", {
      emitter: fund.coreVault,
      sequence,
      consistency: message.args.consistencyLevel,
      executeIn: `${options.orderDelaySeconds}s`,
    });
    inSequence(fund.coreVault, options.orderDelaySeconds, async () => {
      for (let attempt = 0; attempt < 3; attempt++) {
        try {
          if (await executeOrder(fund, message, Number(block.timestamp))) handledOrders.add(orderKey(fund.coreVault, sequence));
          return;
        } catch (err) {
          if (attempt === 2) throw err;
          wormholeLog.warn("order delivery will retry", { sequence, attempt: attempt + 1, error: explain(err) });
          await later(attempt + 1, async () => {});
        }
      }
    });
  }

  // --------------------------------------------------------------------------------------------------------------
  // Discovery
  // --------------------------------------------------------------------------------------------------------------

  async function spokeIndexOf(coreVault: Address, spokeVault: Address | undefined): Promise<number> {
    if (!spokeVault) return 0;
    const mandate = await read<{ spokes: readonly { chainId: bigint; spokeVault: Hex }[] }>("arbitrum", {
      address: coreVault,
      abi: coreVaultAbi,
      functionName: "mandate",
    });
    const index = mandate.spokes.findIndex((s) => s.spokeVault.toLowerCase() === universal(spokeVault).toLowerCase());
    return index < 0 ? 0 : index;
  }

  async function onFundCreated(event: DecodedLog) {
    const a = event.args.addresses;
    const hub = (a.chains as any[]).find((c) => Number(c.chainId) === nodes.arbitrum.chain.id);
    const known = funds.get(event.args.fundId);
    const entry = register({
      fundId: event.args.fundId,
      coreVault: a.coreVault,
      receiver: a.valueReportReceiver,
      hubSpokeVault: hub?.spokeVault,
      spokeVault: known?.spokeVault,
      spokeIndex: known?.spokeIndex ?? 0,
    });
    if (!known) log.info("fund discovered on the hub", { fundId: entry.fundId, coreVault: entry.coreVault });
  }

  async function onSpokeCreated(event: DecodedLog) {
    const fundId = event.args.fundId as Hex;
    const spokeVault = event.args.addresses.spokeVault as Address;
    const known = funds.get(fundId);
    if (known?.spokeVault?.toLowerCase() === spokeVault.toLowerCase()) return;
    if (!known) {
      log.warn("spoke created for a fund the hub has not shown yet; waiting for FundCreated", { fundId, spokeVault });
      orphanSpokes.set(fundId, spokeVault);
      return;
    }
    const entry = register({ ...known, spokeVault, spokeIndex: await spokeIndexOf(known.coreVault, spokeVault) });
    log.info("spoke discovered on Robinhood", { fundId, spokeVault: entry.spokeVault, spokeIndex: entry.spokeIndex });
  }
  const orphanSpokes = new Map<Hex, Address>();

  // --------------------------------------------------------------------------------------------------------------
  // Polling
  // --------------------------------------------------------------------------------------------------------------

  const cursor: Record<Side, bigint> = {
    arbitrum: BigInt(state.nodes.arbitrum.forkBlockNumber) + 1n,
    robinhood: BigInt(state.nodes.robinhood.forkBlockNumber) + 1n,
  };

  async function logsOf(side: Side, from: bigint, to: bigint): Promise<DecodedLog[]> {
    const client = nodes[side].client;
    const address =
      side === "arbitrum"
        ? [state.protocol.arbitrum.fundFactory, ARBITRUM.acrossSpokePool, ARBITRUM.wormholeCore]
        : [state.protocol.robinhood.fundFactory, ROBINHOOD.acrossSpokePool, ROBINHOOD.wormholeCore];
    const events =
      side === "arbitrum" ? [FUND_CREATED, FUNDS_DEPOSITED, MESSAGE_PUBLISHED] : [SPOKE_CREATED, FUNDS_DEPOSITED, MESSAGE_PUBLISHED];
    const logs = await client.getLogs({ address, events: events as never, fromBlock: from, toBlock: to, strict: true } as never);
    return logs as unknown as DecodedLog[];
  }

  /** The logs of `side` past its cursor, up to its latest block (the cursor moves once both chains were read). */
  async function newLogs(side: Side): Promise<{ logs: DecodedLog[]; next: bigint }> {
    const latest = await nodes[side].client.getBlockNumber();
    if (latest < cursor[side] - 1n) {
      // A snapshot revert took the chain back: rescan from the fork block (every action is idempotent).
      log.warn("chain went back (snapshot revert?); rescanning from the fork block", { chain: nodes[side].chain.id });
      cursor[side] = BigInt(state.nodes[side].forkBlockNumber) + 1n;
    }
    if (latest < cursor[side]) return { logs: [], next: cursor[side] };
    return { logs: await logsOf(side, cursor[side], latest), next: latest + 1n };
  }

  /** One poll of both chains. Arbitrum is read first, and both chains' creations are registered before anything is
   *  relayed: a Spoke Vault created before a Hub order was published is in the Robinhood logs read after it, so the
   *  order finds it, whether the keeper follows the chains live or rescans them from the fork block after a restart. */
  async function poll() {
    const hub = await newLogs("arbitrum");
    const spoke = await newLogs("robinhood");
    cursor.arbitrum = hub.next;
    cursor.robinhood = spoke.next;
    for (const entry of hub.logs.filter((l) => l.eventName === "FundCreated")) await onFundCreated(entry);
    for (const entry of spoke.logs.filter((l) => l.eventName === "SpokeCreated")) await onSpokeCreated(entry);
    for (const [fundId, spokeVault] of orphanSpokes) {
      if (!funds.has(fundId)) continue;
      orphanSpokes.delete(fundId);
      const known = funds.get(fundId)!;
      register({ ...known, spokeVault, spokeIndex: await spokeIndexOf(known.coreVault, spokeVault) });
    }
    for (const entry of hub.logs) {
      if (entry.eventName === "FundsDeposited") onDeposit("arbitrum", entry);
      else if (entry.eventName === "LogMessagePublished") await onOrderMessage(entry);
    }
    for (const entry of spoke.logs) {
      if (entry.eventName === "FundsDeposited") onDeposit("robinhood", entry);
      else if (entry.eventName === "LogMessagePublished") await onReportMessage(entry);
    }
    for (const fund of funds.values()) {
      if (!fund.spokeVault) continue;
      const sends = await nodes.robinhood.client.getContractEvents({ address: fund.spokeVault, abi: spokeVaultAbi, eventName: "SentToHub", fromBlock: BigInt(state.nodes.robinhood.forkBlockNumber) + 1n });
      for (const sent of sends) if (Number((sent.args as any).transit.kind) === 0) queueTransit(fund, (sent.args as any).transitId);
    }
    await transits.drain(retryTransit, (error) => {
      stats.errors++;
      wormholeLog.warn("pending transit will retry", { error: explain(error) });
    });
  }

  let lastReportAt = 0;
  async function autoReport() {
    if (options.autoReportSeconds <= 0 || Date.now() - lastReportAt < options.autoReportSeconds * 1000) return;
    lastReportAt = Date.now();
    for (const fund of funds.values()) {
      if (!fund.spokeVault) continue;
      try {
        const sent = await send<readonly [bigint, bigint]>("robinhood", "keeper", {
          address: fund.spokeVault,
          abi: spokeVaultAbi,
          functionName: "report",
        });
        stats.reports++;
        log.info("auto-report", { spokeVault: fund.spokeVault, reportSequence: sent.result[0], wormholeSequence: sent.result[1] });
      } catch (err) {
        stats.errors++;
        log.error(`auto-report failed: ${explain(err)}`);
      }
    }
  }

  let lastFeedCheck = 0;
  async function feed() {
    if (Date.now() - lastFeedCheck < 10_000) return;
    lastFeedCheck = Date.now();
    await ensureFeedFresh(log.child("chainlink"), options.feedMaxAgeSeconds);
  }

  let loopDone: Promise<void> = Promise.resolve();
  let wake: (() => void) | undefined;
  async function loop() {
    let failures = 0;
    while (!stopped) {
      try {
        await poll();
        await autoReport();
        await feed();
        failures = 0;
      } catch (err) {
        failures++;
        stats.errors++;
        if (failures === 1 || failures % 20 === 0) log.error(`poll failed: ${explain(err)}`);
      }
      await new Promise<void>((resolve) => {
        wake = resolve;
        setTimeout(resolve, options.pollMs);
      });
    }
  }

  log.info("watching", {
    fillMode: options.fillMode,
    fillDelay: `${options.fillDelaySeconds}s`,
    vaaDelay: `${options.vaaDelaySeconds}s`,
    orderDelay: `${options.orderDelaySeconds}s`,
    autoReport: options.autoReportSeconds > 0 ? `${options.autoReportSeconds}s` : "off",
    relayer: keeper.address,
  });
  loopDone = loop();

  return {
    stats,
    handledOrder: (emitter, sequence) => handledOrders.has(orderKey(emitter, sequence)),
    async stop() {
      stopped = true;
      wake?.();
      await loopDone;
      for (const cancel of [...cancels]) cancel();
      await Promise.allSettled([...pending]);
      log.info("stopped", { ...stats });
    },
  };
}

function parseArgs(argv: string[]): KeeperOptions {
  const options = { ...DEFAULT_KEEPER_OPTIONS };
  for (let i = 0; i < argv.length; i++) {
    const flag = argv[i];
    const value = () => {
      const v = argv[++i];
      if (v === undefined) throw new Error(`${flag} needs a value`);
      return v;
    };
    if (flag === "--auto-report") options.autoReportSeconds = Number(value());
    else if (flag === "--vaa-delay") options.vaaDelaySeconds = Number(value());
    else if (flag === "--order-delay") options.orderDelaySeconds = Number(value());
    else if (flag === "--fill-delay") options.fillDelaySeconds = Number(value());
    else if (flag === "--fill-mode") options.fillMode = value() as KeeperOptions["fillMode"];
    else if (flag === "--quiet") options.quiet = true;
    else if (flag === "--help" || flag === "-h") {
      console.log(
        "pnpm keeper [--auto-report <seconds>] [--vaa-delay <seconds>] [--order-delay <seconds>] [--fill-delay <seconds>] [--fill-mode auto|real|simulated]",
      );
      process.exit(0);
    } else throw new Error(`unknown flag ${flag}`);
  }
  return options;
}

/** The pid of a running standalone keeper, if any. */
export function runningKeeperPid(): number | undefined {
  if (!existsSync(KEEPER_PID_FILE)) return undefined;
  const pid = Number(readFileSync(KEEPER_PID_FILE, "utf8").trim());
  try {
    process.kill(pid, 0);
    return pid;
  } catch {
    return undefined;
  }
}

if (isMain(import.meta.url)) {
  const options = parseArgs(process.argv.slice(2));
  const state = readState();
  const other = runningKeeperPid();
  if (other && other !== process.pid) {
    console.error(`a keeper is already running (pid ${other}); stop it first (Ctrl-C in its terminal, or pnpm down)`);
    process.exit(1);
  }
  writeFileSync(KEEPER_PID_FILE, String(process.pid));
  const k = await startKeeper(state, options);
  let stopping = false;
  const shutdown = async (signal: string) => {
    if (stopping) return;
    stopping = true;
    logger("keeper").info(`${signal}: finishing scheduled work`);
    await k.stop();
    try {
      unlinkSync(KEEPER_PID_FILE);
    } catch {
      // already gone
    }
    process.exit(0);
  };
  process.on("SIGINT", () => void shutdown("SIGINT"));
  process.on("SIGTERM", () => void shutdown("SIGTERM"));
}
