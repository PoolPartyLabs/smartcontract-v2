import { safeConsole as console } from "./log.ts";
import {createServer} from "node:http";
import {mkdirSync, readFileSync, writeFileSync, renameSync, existsSync} from "node:fs";
import {dirname, resolve} from "node:path";
import {
  createPublicClient, createWalletClient, defineChain, http, parseAbi, decodeEventLog,
  numberToHex, concat, getAddress, zeroAddress,
  type Abi, type Address, type Hex,
} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {coreVaultAbi, spokeVaultAbi, valueReportReceiverAbi, wormholeCoreAbi} from "./abis.ts";
import {ROUTE_TYPES, encodeRoute, legsHash} from "./swap-route.ts";
import {actors, guardian} from "./config.ts";
import {createAlphaDelivery, drainAlphaPending, type AlphaMessage} from "./alpha-relay.ts";
import {collectAllowed, drainAlphaWork, type AlphaWork} from "./alpha-work.ts";
import {decodeSpokeReport, SPOKE_REPORT_VERSION} from "./spoke-report.ts";

function required(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing ${name}`);
  return value;
}

async function main() {
const mode = process.argv[2];
if (mode !== "keeper" && mode !== "api") throw new Error("Use: tsx src/alpha.ts keeper|api");
const account = privateKeyToAccount(required(mode === "keeper" ? "ALPHA_KEEPER_KEY" : "ALPHA_API_SIGNER_KEY") as Hex);
const publicTestAccounts = [...Object.values(actors), guardian].map((entry) => entry.address.toLowerCase());
if (publicTestAccounts.includes(account.address.toLowerCase()) && process.env.ALPHA_ALLOW_LOCAL_TEST_KEYS !== "1") {
  throw new Error("Public test key refused; local rehearsal requires ALPHA_ALLOW_LOCAL_TEST_KEYS=1");
}
const core = getAddress(required("ALPHA_CORE_VAULT"));
const spoke = getAddress(required("ALPHA_SPOKE_VAULT"));
const receiver = getAddress(required("ALPHA_REPORT_RECEIVER"));
const share = getAddress(required("ALPHA_SHARE_TOKEN"));
const stateFile = resolve(process.env.ALPHA_STATE_FILE ?? ".state/alpha-keeper.json");
const pollMs = Number(process.env.ALPHA_POLL_MS ?? "5000");
const reportSeconds = Number(process.env.ALPHA_REPORT_SECONDS ?? "300");
const collectMinimum = BigInt(process.env.ALPHA_MIN_COLLECT_USDC ?? "500000");
if (collectMinimum < 500000n) throw new Error("COLLECT minimum must be at least 0.50 USDC");
if (!Number.isInteger(pollMs) || pollMs < 1000 || !Number.isInteger(reportSeconds) || reportSeconds < 10 || reportSeconds > 600) {
  throw new Error("Invalid polling/report interval");
}
const vaaBase = process.env.ALPHA_VAA_API ?? "https://api.wormholescan.io/api/v1/vaas";
if (!vaaBase.startsWith("https://")) throw new Error("VAA service must use HTTPS");
const identity = parseAbi([
  "function wormholeCore() view returns (address)",
  "function coreBridge() view returns (address)",
  "function coreVault() view returns (address)",
  "function shareToken() view returns (address)",
  "function reportReceiver() view returns (address)",
  "function mandateHash() view returns (bytes32)",
  "function routeSigner() view returns (address)",
  "function v3Factory() view returns (address)",
  "function quoterV2() view returns (address)",
  "function isMandateToken(address token) view returns (bool)",
  "function vault() view returns (address)",
]);
const sides = {
  hub: {id: 42161, rpc: required("ARBITRUM_RPC_URL"), wormhole: 23, emitter: core},
  spoke: {id: 4663, rpc: required("ROBINHOOD_RPC_URL"), wormhole: 72, emitter: spoke},
} as const;
type Side = keyof typeof sides;
const nodes = Object.fromEntries(Object.entries(sides).map(([side, config]) => {
  const chain = defineChain({id: config.id, name: side, nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18}, rpcUrls: {default: {http: [config.rpc]}}});
  return [side, {client: createPublicClient({chain, transport: http(config.rpc)}), wallet: createWalletClient({chain, account, transport: http(config.rpc)})}];
})) as unknown as Record<Side, {client: ReturnType<typeof createPublicClient>; wallet: ReturnType<typeof createWalletClient>}>;

async function read(side: Side, address: Address, functionName: string, args: unknown[] = [], abi: Abi = identity): Promise<any> {
  return nodes[side].client.readContract({address, abi, functionName, args} as never);
}

async function send(side: Side, address: Address, abi: any, functionName: string, args: unknown[], value = 0n) {
  const {request} = await nodes[side].client.simulateContract({account, address, abi, functionName, args, value} as never);
  const hash = await nodes[side].wallet.writeContract(request as never);
  const receipt = await nodes[side].client.waitForTransactionReceipt({hash});
  if (receipt.status !== "success") throw new Error("Transaction reverted");
  console.log(JSON.stringify({side, functionName, hash, gasUsed: receipt.gasUsed.toString()}));
  return receipt;
}

const bridges: Record<Side, Address> = {
  hub: await read("hub", core, "wormholeCore"),
  spoke: await read("spoke", spoke, "wormholeCore"),
};
for (const side of ["hub", "spoke"] as const) {
  if (await nodes[side].client.getChainId() !== sides[side].id) throw new Error("Wrong RPC chain");
  if (process.env.ALPHA_ALLOW_LOCAL_TEST_KEYS === "1" && !(await nodes[side].client.request({method: "web3_clientVersion"})).toLowerCase().includes("anvil")) {
    throw new Error("Test keys require Anvil on both RPCs");
  }
  if (Number(await read(side, bridges[side], "chainId", [], wormholeCoreAbi)) !== sides[side].wormhole) throw new Error("Wrong Wormhole chain");
  if (await nodes[side].client.getBalance({address: account.address}) === 0n) throw new Error("Fund this runner on both chains");
}
if (getAddress(await read("hub", receiver, "coreBridge")) !== getAddress(bridges.hub)
  || getAddress(await read("hub", receiver, "coreVault")) !== core
  || getAddress(await read("spoke", spoke, "coreVault")) !== core
  || getAddress(await read("hub", core, "reportReceiver")) !== receiver
  || getAddress(await read("hub", core, "shareToken")) !== share
  || await read("hub", core, "mandateHash") !== await read("spoke", spoke, "mandateHash")) throw new Error("Fund wiring mismatch");
if (mode === "api") {
  const mandate = await read("hub", core, "mandate", [], coreVaultAbi);
  for (const side of ["hub", "spoke"] as const) {
    const adapter = mandate.swapAdapters.find((entry: any) => Number(entry.chainId) === sides[side].id)?.adapter;
    if (!adapter || getAddress(await read(side, adapter, "routeSigner")) !== account.address) throw new Error("API signer mismatch");
  }
}

type Message = AlphaMessage;
interface Cursor {core: Address; spokeVault: Address; hub: string; spoke: string; pending: Message[]; work: AlphaWork[]; lastReport: number}
const initial: Cursor = {core, spokeVault: spoke, hub: required("ALPHA_HUB_START_BLOCK"), spoke: required("ALPHA_SPOKE_START_BLOCK"), pending: [], work: [], lastReport: 0};
let cursor: Cursor = existsSync(stateFile) ? JSON.parse(readFileSync(stateFile, "utf8")) : initial;
cursor.work ??= [];
if (cursor.core !== core || cursor.spokeVault !== spoke) throw new Error("Cursor belongs to another fund");
function save() {
  mkdirSync(dirname(stateFile), {recursive: true});
  writeFileSync(`${stateFile}.tmp`, JSON.stringify(cursor));
  renameSync(`${stateFile}.tmp`, stateFile);
}

let fetchVaa: typeof fetch | undefined;
if (process.env.ALPHA_REHEARSAL_LOCAL_VAA === "1") {
  if (process.env.ALPHA_ALLOW_LOCAL_TEST_KEYS !== "1") throw new Error("Local VAAs require rehearsal mode");
  for (const side of ["hub", "spoke"] as const) {
    if (new URL(sides[side].rpc).hostname !== "127.0.0.1") throw new Error("Local VAAs require loopback Anvil");
  }
  const {signVaa, universal, guardianSetIndexOf} = await import("./guardian.ts");
  fetchVaa = async (input) => {
    const parts = String(input).split("/");
    const sequence = BigInt(parts.at(-1)!);
    const side: Side = Number(parts.at(-3)) === sides.hub.wormhole ? "hub" : "spoke";
    const logs = await nodes[side].client.getLogs({address: bridges[side], event: wormholeCoreAbi.find((entry: any) => entry.type === "event") as any, fromBlock: BigInt(required(side === "hub" ? "ALPHA_HUB_START_BLOCK" : "ALPHA_SPOKE_START_BLOCK"))});
    const message = (logs as any[]).find((entry) => getAddress(entry.args.sender) === sides[side].emitter && entry.args.sequence === sequence);
    if (!message) return new Response(null, {status: 404});
    const block = await nodes[side].client.getBlock({blockNumber: message.blockNumber});
    const destination = side === "hub" ? "robinhood" : "arbitrum";
    const vaa = await signVaa({timestamp: Number(block.timestamp), nonce: message.args.nonce, emitterChainId: sides[side].wormhole, emitterAddress: universal(sides[side].emitter), sequence, consistencyLevel: message.args.consistencyLevel, payload: message.args.payload}, await guardianSetIndexOf(destination));
    return Response.json({data: {vaa: Buffer.from(vaa.slice(2), "hex").toString("base64")}});
  };
}
const deliver = createAlphaDelivery({sides, bridges, receiver, spoke, vaaBase, read, send, fetchVaa});

async function resolveTransit(work: AlphaWork) {
  const transit = await read("spoke", spoke, "hubBoundTransit", [work.transitId], spokeVaultAbi);
  if (Number(transit.state) === 2 || Number(transit.state) === 4) return true;
  const events = await nodes.hub.client.getLogs({address: core, event: coreVaultAbi.find((entry: any) => entry.name === "TransitReceived") as any,
    fromBlock: BigInt(required("ALPHA_HUB_START_BLOCK")), toBlock: (await nodes.hub.client.getBlock({blockTag: process.env.ALPHA_REHEARSAL_LOCAL_VAA === "1" ? "latest" : "finalized"})).number!});
  const credited = (events as any[]).filter((entry) => entry.args.transitId === work.transitId && entry.args.originChainId === 4663n && entry.args.matched)
    .reduce((total, entry) => total + entry.args.amount, 0n);
  if (credited < BigInt(work.expected)) return false;
  if (work.kind === 1) return true;
  if (!work.acknowledged || Date.now() - (work.acknowledgedAt ?? 0) >= 60000) {
    const fee = await read("hub", bridges.hub, "messageFee", [], wormholeCoreAbi);
    await send("hub", core, coreVaultAbi, "acknowledgeSpokeTransit", [0n, work.transitId], fee);
    work.acknowledged = true;
    work.acknowledgedAt = Date.now();
    save();
  }
  return false;
}

async function publish(): Promise<Message> {
  const fee = await read("spoke", bridges.spoke, "messageFee", [], wormholeCoreAbi);
  const receipt = await send("spoke", spoke, spokeVaultAbi, "report", [], fee);
  for (const log of receipt.logs) {
    if (getAddress(log.address) !== getAddress(bridges.spoke)) continue;
    try {
      const event = decodeEventLog({abi: wormholeCoreAbi, ...log}) as any;
      if (event.eventName === "LogMessagePublished" && getAddress(event.args.sender) === spoke) {
        decodeSpokeReport(event.args.payload);
        return {side: "spoke", sequence: event.args.sequence.toString(), payload: event.args.payload};
      }
    } catch {}
  }
  throw new Error("Report publication missing");
}

async function keeperTick() {
  let balanceChanged = false;
  for (const side of ["hub", "spoke"] as const) {
    const fromBlock = BigInt(cursor[side]);
    const head = (await nodes[side].client.getBlock({blockTag: process.env.ALPHA_REHEARSAL_LOCAL_VAA === "1" ? "latest" : "finalized"})).number!;
    if (fromBlock > head) continue;
    const toBlock = fromBlock + 999n < head ? fromBlock + 999n : head;
    const logs = await nodes[side].client.getLogs({address: bridges[side], event: wormholeCoreAbi.find((item: any) => item.type === "event") as any, fromBlock, toBlock});
    for (const log of logs as any[]) {
      if (getAddress(log.args.sender) === sides[side].emitter && !cursor.pending.some((entry) => entry.side === side && entry.sequence === log.args.sequence.toString())) {
        if (side === "spoke") decodeSpokeReport(log.args.payload);
        cursor.pending.push({side, sequence: log.args.sequence.toString(), payload: log.args.payload});
      }
    }
    if (side === "hub") {
      const transfers = await nodes.hub.client.getLogs({address: share, event: parseAbi(["event Transfer(address indexed from, address indexed to, uint256 value)"])[0] as any, fromBlock, toBlock});
      balanceChanged ||= transfers.some((log: any) => log.args.from === zeroAddress || log.args.to === zeroAddress);
    } else {
      const transits = await nodes.spoke.client.getLogs({address: spoke, event: spokeVaultAbi.find((entry: any) => entry.name === "SentToHub") as any, fromBlock, toBlock});
      for (const log of transits as any[]) {
        if (!cursor.work.some((work) => work.transitId === log.args.transitId)) cursor.work.push({transitId: log.args.transitId,
          kind: Number(log.args.transit.kind), expected: log.args.transit.amountToArrive.toString(), attempts: 0, retryAt: 0});
      }
    }
    cursor[side] = (toBlock + 1n).toString();
    save();
  }
  if (balanceChanged || Date.now() - cursor.lastReport >= reportSeconds * 1000) {
    await publish();
    cursor.lastReport = Date.now();
  }
  save();
  await drainAlphaPending(cursor, deliver, save, (message) => {
    console.error(`Relay pending: ${message.side} sequence ${message.sequence}; inspect VAA/expiry and fund state.`);
  }, Date.now());
  await drainAlphaWork(cursor, resolveTransit, save);
}

async function route(input: any) {
  const side: Side = input.side;
  if (side !== "hub" && side !== "spoke") throw new Error("Invalid side");
  const mandate = await read("hub", core, "mandate", [], coreVaultAbi);
  const adapter = mandate.swapAdapters.find((entry: any) => Number(entry.chainId) === sides[side].id)?.adapter as Address | undefined;
  if (!adapter || getAddress(await read(side, adapter, "routeSigner")) !== account.address) throw new Error("API signer mismatch");
  const vault = await read(side, adapter, "vault") as Address;
  const tokenIn = getAddress(input.tokenIn), tokenOut = getAddress(input.tokenOut);
  if (!await read(side, vault, "isMandateToken", [tokenIn]) || !await read(side, vault, "isMandateToken", [tokenOut])) throw new Error("Not Mandate tokens");
  const amount = BigInt(input.amountIn);
  const loss = Number(input.maxLossBps);
  if (amount <= 0n || !Number.isInteger(loss) || loss < 1 || loss > 500) throw new Error("Invalid amount or loss (1..500 bps)");
  const factory = await read(side, adapter, "v3Factory");
  const quoter = await read(side, adapter, "quoterV2");
  let best: {path: Hex; amount: bigint} | undefined;
  for (const fee of [100, 500, 3000, 10000]) {
    const pool = await read(side, factory, "getPool", [tokenIn, tokenOut, fee], parseAbi(["function getPool(address,address,uint24) view returns (address)"]));
    if (pool === zeroAddress) continue;
    const path = concat([tokenIn, numberToHex(fee, {size: 3}), tokenOut]);
    try {
      const {result} = await nodes[side].client.simulateContract({address: quoter, abi: parseAbi(["function quoteExactInput(bytes,uint256) returns (uint256,uint160[],uint32[],uint256)"]), functionName: "quoteExactInput", args: [path, amount]} as never) as any;
      if (!best || result[0] > best.amount) best = {path, amount: result[0]};
    } catch {}
  }
  if (!best) throw new Error("No direct V3 route");
  const block = await nodes[side].client.getBlock();
  const quoted = {paths: [best.path], weightsBps: [10000], quotedAmountIn: amount, minAmountOut: best.amount * BigInt(10000 - loss) / 10000n, deadline: block.timestamp + 120n};
  const signature = await account.signTypedData({domain: {name: "Pool Party Swap Adapter", version: "1", chainId: sides[side].id, verifyingContract: adapter}, types: ROUTE_TYPES, primaryType: "SwapRoute", message: {tokenIn, tokenOut, legsHash: legsHash(quoted.paths, quoted.weightsBps), quotedAmountIn: amount, minAmountOut: quoted.minAmountOut, deadline: quoted.deadline}});
  return {adapter, route: encodeRoute({...quoted, signature}), minAmountOut: quoted.minAmountOut.toString(), deadline: quoted.deadline.toString(), maxLossBps: loss};
}

if (mode === "keeper") {
  while (true) {
    try {await keeperTick();} catch {
      console.error("Alpha keeper tick failed; inspect on-chain state before retrying.");
      await drainAlphaPending(cursor, deliver, save, () => {}, Date.now());
      await drainAlphaWork(cursor, resolveTransit, save);
    }
    await new Promise((done) => setTimeout(done, pollMs));
  }
} else {
  const token = required("ALPHA_API_TOKEN");
  let busy = false;
  createServer(async (request, response) => {
    if (request.headers.authorization !== `Bearer ${token}`) {response.writeHead(401).end(); return;}
    if (request.method !== "POST" || !["/report", "/swap-route", "/income"].includes(request.url ?? "")) {response.writeHead(404).end(); return;}
    if (busy) {response.writeHead(409).end(); return;}
    busy = true;
    try {
      let body = "";
      for await (const chunk of request) {body += chunk; if (body.length > 8192) throw new Error("Too much input");}
      let result;
      if (request.url === "/report") {
        const message = await publish();
        const deadline = Date.now() + 30 * 60 * 1000;
        while (!await deliver(message)) {
          if (Date.now() > deadline) throw new Error("VAA timeout; keeper must retry");
          await new Promise((done) => setTimeout(done, pollMs));
        }
        result = {delivered: true, sequence: message.sequence, reportVersion: SPOKE_REPORT_VERSION.toString()};
      } else if (request.url === "/income") {
        const report = await read("spoke", spoke, "buildReport", [], spokeVaultAbi);
        const mandate = await read("hub", core, "mandate", [], coreVaultAbi);
        const base = mandate.spokes[0].spokeToken as Address;
        const adapter = mandate.bridgeAdapters.find((entry: any) => Number(entry.chainId) === 4663)?.adapter as Address;
        const value = report.collectedIncome.filter((entry: any) => getAddress(entry.token) === getAddress(base))
          .reduce((total: bigint, entry: any) => total + entry.amount, 0n);
        let arrival = 0n;
        try {arrival = (await read("spoke", adapter, "quoteSend", [base, 42161n, value, "0x"], parseAbi(["function quoteSend(address,uint256,uint256,bytes) view returns (uint256,uint256)"])))[0];} catch {}
        if (!collectAllowed(value, collectMinimum, arrival)) {
          response.writeHead(409).end(JSON.stringify({deferred: true, collectedBase: value.toString(), minimum: collectMinimum.toString()}));
          return;
        }
        const fee = await read("hub", bridges.hub, "messageFee", [], wormholeCoreAbi);
        const receipt = await send("hub", core, coreVaultAbi, "requestIncomeWithdrawal", [100], fee);
        result = {requested: true, transactionHash: receipt.transactionHash, shareholder: account.address};
      } else {result = await route(JSON.parse(body));}
      response.setHeader("Content-Type", "application/json");
      response.end(JSON.stringify(result));
    } catch {response.writeHead(503).end("Alpha request failed; inspect chain state.");}
    finally {busy = false;}
  }).listen(Number(process.env.ALPHA_API_PORT ?? "8787"), "127.0.0.1");
  console.log("Alpha API listening on loopback only");
}
}

main().catch(() => {
  console.error("Alpha runner preflight failed; check keys, funded balances, RPC chains and fund addresses.");
  process.exitCode = 1;
});
