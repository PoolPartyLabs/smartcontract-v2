// RPC clients for the two forks, anvil cheat methods, and a transaction helper that simulates, sends, waits and
// explains failures (revert names, and a hint when the upstream RPC no longer serves the fork's state).
import {
  BaseError,
  ContractFunctionRevertedError,
  createPublicClient,
  createWalletClient,
  decodeErrorResult,
  http,
  type Abi,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type PublicClient,
  type TransactionReceipt,
  type WalletClient,
} from "viem";
import { allErrorsAbi } from "./abis.ts";
import { actors, arbitrumFork, robinhoodFork, type ActorName } from "./config.ts";

export type Side = "arbitrum" | "robinhood";
export const SIDES: Side[] = ["arbitrum", "robinhood"];

export interface Node {
  side: Side;
  label: string;
  chain: Chain;
  rpc: string;
  client: PublicClient;
}

function makeNode(side: Side, chain: Chain, label: string): Node {
  const rpc = chain.rpcUrls.default.http[0];
  return {
    side,
    label,
    chain,
    rpc,
    client: createPublicClient({ chain, transport: http(rpc, { retryCount: 2, timeout: 120_000 }), pollingInterval: 250 }),
  };
}

export const nodes: Record<Side, Node> = {
  arbitrum: makeNode("arbitrum", arbitrumFork, "Arbitrum One (hub)"),
  robinhood: makeNode("robinhood", robinhoodFork, "Robinhood Chain (spoke)"),
};

const wallets = new Map<string, WalletClient>();

export function wallet(side: Side, who: ActorName | Account): WalletClient {
  const account = typeof who === "string" ? actors[who] : who;
  const key = `${side}:${account.address}`;
  let w = wallets.get(key);
  if (!w) {
    const node = nodes[side];
    w = createWalletClient({ account, chain: node.chain, transport: http(node.rpc, { timeout: 120_000 }) });
    wallets.set(key, w);
  }
  return w;
}

// ---------------------------------------------------------------------------------------------------------------------
// anvil cheat methods
// ---------------------------------------------------------------------------------------------------------------------

export async function rpc<T = unknown>(side: Side, method: string, params: unknown[] = []): Promise<T> {
  // viem's typed request only knows standard methods; anvil's are plain JSON-RPC.
  return (await nodes[side].client.request({ method: method as never, params: params as never })) as T;
}

const hex = (value: bigint | number) => `0x${BigInt(value).toString(16)}` as Hex;

export const anvil = {
  setBalance: (side: Side, address: Address, wei: bigint) => rpc(side, "anvil_setBalance", [address, hex(wei)]),
  setStorageAt: (side: Side, address: Address, slot: Hex, value: Hex) =>
    rpc(side, "anvil_setStorageAt", [address, slot, value]),
  setCode: (side: Side, address: Address, code: Hex) => rpc(side, "anvil_setCode", [address, code]),
  impersonate: (side: Side, address: Address) => rpc(side, "anvil_impersonateAccount", [address]),
  stopImpersonating: (side: Side, address: Address) => rpc(side, "anvil_stopImpersonatingAccount", [address]),
  mine: (side: Side) => rpc(side, "evm_mine", []),
  setNextBlockTimestamp: (side: Side, timestamp: bigint) => rpc(side, "evm_setNextBlockTimestamp", [hex(timestamp)]),
  snapshot: (side: Side) => rpc<Hex>(side, "evm_snapshot", []),
  revert: (side: Side, id: Hex) => rpc<boolean>(side, "evm_revert", [id]),
  nodeInfo: (side: Side) =>
    rpc<{
      currentBlockNumber: string;
      currentBlockTimestamp: number;
      hardFork: string;
      forkConfig?: { forkUrl?: string; forkBlockNumber?: number };
    }>(side, "anvil_nodeInfo", []),
};

export async function latestTimestamp(side: Side): Promise<bigint> {
  return (await nodes[side].client.getBlock({ blockTag: "latest" })).timestamp;
}

/** Whether both nodes answer with their chain ids. */
export async function nodesUp(): Promise<Record<Side, boolean>> {
  const check = async (side: Side) => {
    try {
      return (await nodes[side].client.getChainId()) === nodes[side].chain.id;
    } catch {
      return false;
    }
  };
  return { arbitrum: await check("arbitrum"), robinhood: await check("robinhood") };
}

// ---------------------------------------------------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------------------------------------------------

const PRUNED_STATE =
  /missing trie node|state (is )?not available|historical state|pruned|header not found|failed to get (account|storage)|could not fetch/i;

export const PRUNED_STATE_HINT =
  "hint: the upstream RPC no longer serves the state at the fork block. Public Arbitrum and Robinhood RPCs keep only " +
  "about 1 hour and 10 minutes of state, so a fork on them can only read storage it cached early. Restart with " +
  "`pnpm down && pnpm run up` (it forks at latest and warms the cache), or set ARBITRUM_RPC_URL / ROBINHOOD_RPC_URL " +
  "to an archive endpoint (Alchemy or dRPC for Arbitrum, QuickNode or Chainstack for Robinhood) for long sessions.";

/** The revert name and arguments of a failed call, when an ABI knows the error. */
export function revertOf(err: unknown): { name: string; args: readonly unknown[] } | undefined {
  if (!(err instanceof BaseError)) return undefined;
  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as
    | ContractFunctionRevertedError
    | null;
  if (reverted?.data?.errorName) return { name: reverted.data.errorName, args: reverted.data.args ?? [] };
  const raw = reverted?.raw ?? findRevertData(err);
  if (raw && raw !== "0x") {
    try {
      const decoded = decodeErrorResult({ abi: allErrorsAbi, data: raw });
      return { name: decoded.errorName, args: decoded.args ?? [] };
    } catch {
      return { name: `unknown error ${raw.slice(0, 10)}`, args: [] };
    }
  }
  return undefined;
}

function findRevertData(err: BaseError): Hex | undefined {
  let found: Hex | undefined;
  err.walk((e) => {
    const data = (e as { data?: unknown }).data;
    if (typeof data === "string" && data.startsWith("0x")) found = data as Hex;
    else if (data && typeof data === "object" && typeof (data as { data?: unknown }).data === "string") {
      found = (data as { data: Hex }).data;
    }
    return false;
  });
  return found;
}

/** A one-line explanation of a failure, with the pruned-state hint when it applies. */
export function explain(err: unknown): string {
  const revert = revertOf(err);
  const text = err instanceof BaseError ? err.shortMessage + "\n" + err.message : String(err);
  const lines: string[] = [];
  if (revert) {
    lines.push(`reverted: ${revert.name}(${revert.args.map((a) => (typeof a === "bigint" ? a.toString() : JSON.stringify(a))).join(", ")})`);
  } else {
    lines.push(err instanceof BaseError ? err.shortMessage : String(err));
  }
  if (PRUNED_STATE.test(text) && !lines.join("\n").includes(PRUNED_STATE_HINT)) lines.push(PRUNED_STATE_HINT);
  return lines.join("\n");
}

/** Runs a script's entry point: any failure prints its explanation (with the pruned-state hint) and exits 1. */
export async function runMain(task: () => Promise<unknown>): Promise<void> {
  try {
    await task();
  } catch (err) {
    console.error(explain(err));
    process.exit(1);
  }
}

export function isPrunedStateError(err: unknown): boolean {
  const text = err instanceof BaseError ? err.message : String(err);
  return PRUNED_STATE.test(text);
}

// ---------------------------------------------------------------------------------------------------------------------
// Transactions
// ---------------------------------------------------------------------------------------------------------------------

export interface Call {
  address: Address;
  abi: Abi;
  functionName: string;
  args?: readonly unknown[];
  value?: bigint;
}

export interface Sent<T = unknown> {
  receipt: TransactionReceipt;
  result: T;
  hash: Hex;
}

/** Transactions per (chain, sender) go one at a time, so concurrent callers never race on nonces. */
const queues = new Map<string, Promise<unknown>>();

function serialize<T>(key: string, task: () => Promise<T>): Promise<T> {
  const previous = queues.get(key) ?? Promise.resolve();
  const next = previous.then(task, task);
  queues.set(
    key,
    next.catch(() => undefined),
  );
  return next;
}

function withErrors(abi: Abi): Abi {
  return [...abi, ...allErrorsAbi] as Abi;
}

/** Simulates `call` from `who`, sends it signed by `who`'s key, waits for the receipt and requires success. */
export async function send<T = unknown>(side: Side, who: ActorName | Account, call: Call): Promise<Sent<T>> {
  const account = typeof who === "string" ? actors[who] : who;
  return serialize(`${side}:${account.address}`, async () => {
    const node = nodes[side];
    const abi = withErrors(call.abi);
    const { request, result } = await node.client.simulateContract({
      account,
      address: call.address,
      abi,
      functionName: call.functionName,
      args: call.args ?? [],
      value: call.value,
    } as never);
    const hash = await wallet(side, account).writeContract(request as never);
    const receipt = await node.client.waitForTransactionReceipt({ hash, pollingInterval: 100 });
    if (receipt.status !== "success") throw new Error(`transaction ${hash} reverted on ${node.label}`);
    return { receipt, result: result as T, hash };
  });
}

/** Reads a view function, at `blockNumber` when given (reads pinned to one block see one consistent state). */
export async function read<T = unknown>(
  side: Side,
  call: Omit<Call, "value">,
  account?: Address,
  blockNumber?: bigint,
): Promise<T> {
  return (await nodes[side].client.readContract({
    address: call.address,
    abi: withErrors(call.abi),
    functionName: call.functionName,
    args: call.args ?? [],
    account,
    blockNumber,
  } as never)) as T;
}

/** Simulates `call` from `who` and returns the revert name it fails with (undefined when it succeeds). */
export async function simulateRevert(side: Side, who: ActorName | Account, call: Call): Promise<string | undefined> {
  const account = typeof who === "string" ? actors[who] : who;
  try {
    await nodes[side].client.simulateContract({
      account,
      address: call.address,
      abi: withErrors(call.abi),
      functionName: call.functionName,
      args: call.args ?? [],
      value: call.value,
    } as never);
    return undefined;
  } catch (err) {
    const revert = revertOf(err);
    if (!revert) throw err;
    return revert.name;
  }
}

/** Deploys `bytecode` (creation code with constructor arguments appended) from `who`; returns the address. */
export async function deploy(side: Side, who: ActorName, bytecode: Hex): Promise<Address> {
  const account = actors[who];
  return serialize(`${side}:${account.address}`, async () => {
    const node = nodes[side];
    const hash = await wallet(side, who).sendTransaction({ account, chain: node.chain, data: bytecode });
    const receipt = await node.client.waitForTransactionReceipt({ hash, pollingInterval: 100 });
    if (receipt.status !== "success" || !receipt.contractAddress) throw new Error(`deployment ${hash} failed`);
    return receipt.contractAddress;
  });
}
