// Drives the minimal API (src/api.ts) over HTTP against the two forks and checks each concept the API guide relies
// on, from a fresh `pnpm run up`: quotes are exact, the API's transactions do what they say, freshness gates mints
// and not payouts, every operation ends with an event a server can index, and the off-chain swap guard that stands in
// for the open S-8 ruling. Run: `pnpm run up && pnpm api:probe; pnpm run down`.
import type { Address, Hex } from "viem";
import { coreVaultAbi, erc20Abi, spokeVaultAbi } from "./abis.ts";
import { nodes, read, send, wallet, type Side } from "./chain.ts";
import { actors, ARBITRUM, isMain, type ActorName } from "./config.ts";
import { DEFAULT_KEEPER_OPTIONS, startKeeper, type Keeper } from "./keeper.ts";
import { bold, green, logger, red, units } from "./log.ts";
import { readState } from "./state.ts";
import { API_PORT, startApi, type UnsignedTx } from "./api.ts";
import { warp } from "./warp.ts";

const BASE = `http://127.0.0.1:${API_PORT}`;
const results: { concept: string; ok: boolean; detail: string }[] = [];

function record(concept: string, ok: boolean, detail: string) {
  results.push({ concept, ok, detail });
  console.log(`${ok ? green("ok  ") : red("FAIL")} ${concept}: ${detail}`);
}

async function get<T = any>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`);
  const body = await res.json();
  if (!res.ok) throw Object.assign(new Error(`GET ${path}: ${res.status} ${JSON.stringify(body)}`), { status: res.status, body });
  return body as T;
}

async function post<T = any>(path: string, payload: Record<string, string>): Promise<{ status: number; body: T }> {
  const res = await fetch(`${BASE}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload) });
  return { status: res.status, body: (await res.json()) as T };
}

/** Signs and sends the API's unsigned transactions with the actor's key, in order; returns the receipts. */
async function signAndSend(side: Side, who: ActorName, txs: UnsignedTx[]) {
  const receipts = [];
  for (const tx of txs) {
    const hash = await wallet(side, who).sendTransaction({ to: tx.to, data: tx.data, account: actors[who], chain: nodes[side].chain } as never);
    const receipt = await nodes[side].client.waitForTransactionReceipt({ hash, pollingInterval: 100 });
    if (receipt.status !== "success") throw new Error(`${tx.description} reverted (${hash})`);
    receipts.push(receipt);
  }
  return receipts;
}

export async function probe() {
  const log = logger("api-probe");
  const state = readState();
  const server = await startApi();
  let keeper: Keeper | undefined;
  try {
    keeper = await startKeeper(state, { ...DEFAULT_KEEPER_OPTIONS, autoReportSeconds: 0, quiet: true }, log.child("keeper"));
    const core = state.fund.hub.coreVault;
    const ana = actors.ana.address;
    const bruno = actors.bruno.address;
    const startBlock = await nodes.arbitrum.client.getBlockNumber();

    // 1. Health: both forks answer; a fund whose spoke never reported is open for mints.
    let h = await get("/health");
    record("health", h.nodes.arbitrum && h.nodes.robinhood && h.mintsOpen === true, `nodes up, spoke report ${h.spokeReport.hasReport ? "present" : "none yet"}, mints ${h.mintsOpen ? "open" : "closed"}`);

    // 2. Deposit through the API: the quote by eth_call is exact, the built transactions do it.
    const amount = 5_000_000_000n; // 5,000 USDC
    let q = await get(`/quote/deposit?from=${ana}&amount=${amount}`);
    if (q.needsApproval) {
      const { body } = await post<UnsignedTx[]>("/tx/deposit", { from: ana, amount: amount.toString() });
      await signAndSend("arbitrum", "ana", body.slice(0, body.length - 1)); // the approval only
      q = await get(`/quote/deposit?from=${ana}&amount=${amount}`);
    }
    const { body: depositTxs } = await post<UnsignedTx[]>("/tx/deposit", { from: ana, amount: amount.toString(), minShares: q.shares });
    await signAndSend("arbitrum", "ana", depositTxs);
    const anaAfter = await get(`/holders/${ana}`);
    record("deposit quote is exact", BigInt(anaAfter.shares) === BigInt(q.shares), `quoted ${BigInt(q.shares) / 10n ** 18n} shares for ${units(BigInt(q.usdcCharged))} USDC, minted ${BigInt(anaAfter.shares) / 10n ** 18n}`);

    // 3. A first spoke report (the keeper signs and delivers): the gate of the first send (S-14) and of freshness.
    await warp(60n, { log: log.child("warp"), report: true, deliverer: "keeper" });
    h = await get("/health");
    record("report delivered by the keeper", h.spokeReport.hasReport === true && h.spokeReport.fresh === true, `report ${h.spokeReport.reportSequence}, age ${h.spokeReport.ageSeconds}s of ${h.spokeReport.maxReportAge}s`);

    // 4. Freshness gates mints, not payouts (Q57 reading, OQ-10): past the report lifetime with no new report the API
    //    refuses to build a deposit and the chain agrees; a payout from Idle still goes through.
    await warp(BigInt(h.spokeReport.maxReportAge) + 1n, { log: log.child("warp"), report: false, deliverer: "keeper" });
    h = await get("/health");
    const bruno1 = 1_000_000_000n;
    await send("arbitrum", "bruno", { address: ARBITRUM.usdc, abi: erc20Abi, functionName: "approve", args: [core, bruno1] });
    const staleQuote = await get(`/quote/deposit?from=${bruno}&amount=${bruno1}`);
    const staleBuild = await post("/tx/deposit", { from: bruno, amount: bruno1.toString() });
    record(
      "stale report closes mints",
      h.mintsOpen === false && staleQuote.ok === false && staleQuote.revert?.error === "StaleSpokeReport" && staleBuild.status === 409,
      `health mintsOpen=${h.mintsOpen}; chain says ${staleQuote.revert?.error}; API answers ${staleBuild.status}`,
    );
    const { body: requestTxs } = await post<UnsignedTx[]>("/tx/request", { amount: "1000000000", mode: "instant" });
    await signAndSend("arbitrum", "ana", requestTxs);
    const claimQuote = await get(`/quote/claim?from=${ana}`);
    const { body: claimTxs } = await post<UnsignedTx[]>("/tx/claim", {});
    const [claimReceipt] = await signAndSend("arbitrum", "ana", claimTxs);
    const executed = (await get(`/events?fromBlock=${claimReceipt.blockNumber}`)).find((e: any) => e.event === "PayoutExecuted" || e.event === "PartialPayoutExecuted");
    record(
      "payout works on a stale report; its quote is exact",
      claimQuote.ok === true && executed && executed.args.receipt.usdcPaid === claimQuote.receipt.usdcPaid,
      `quoted ${units(BigInt(claimQuote.receipt.usdcPaid))} USDC, paid ${executed ? units(BigInt(executed.args.receipt.usdcPaid)) : "?"} (${executed?.event})`,
    );

    // 5. The keeper brings mints back with a fresh report.
    await warp(30n, { log: log.child("warp"), report: true, deliverer: "keeper" });
    h = await get("/health");
    record("a fresh report reopens mints", h.mintsOpen === true, `report ${h.spokeReport.reportSequence}, age ${h.spokeReport.ageSeconds}s`);

    // 6. Manager swap guard (security review S-8, open): the chain accepts any minimum; the API only builds swaps with
    //    the oracle value less its slippage, and a minimum the pool cannot meet reverts by name.
    await send("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "allocateToHubSpokeVault", args: [2_000_000_000n] });
    const swapQuote = await get(`/quote/swap?tokenIn=${ARBITRUM.usdc}&amountIn=1000000000`);
    const wethBefore = await read<bigint>("arbitrum", { address: state.fund.hub.spokeVault, abi: spokeVaultAbi, functionName: "unallocatedBalance", args: [ARBITRUM.weth] });
    const { body: swapTxs } = await post<UnsignedTx[]>("/tx/swap", { tokenIn: ARBITRUM.usdc, amountIn: "1000000000" });
    await signAndSend("arbitrum", "manager", swapTxs);
    const wethOut = (await read<bigint>("arbitrum", { address: state.fund.hub.spokeVault, abi: spokeVaultAbi, functionName: "unallocatedBalance", args: [ARBITRUM.weth] })) - wethBefore;
    const { body: tightTxs } = await post<UnsignedTx[]>("/tx/swap", { tokenIn: ARBITRUM.usdc, amountIn: "1000000000", slippageBps: "0" });
    let tightRevert = "none";
    try {
      await signAndSend("arbitrum", "manager", tightTxs);
    } catch {
      const sim = await nodes.arbitrum.client.call({ account: actors.manager.address, to: tightTxs[0].to, data: tightTxs[0].data }).catch((e) => e);
      tightRevert = (await import("./api.ts")).decodeRevert(sim)?.error ?? "reverted";
    }
    record(
      "swap guard off chain",
      wethOut >= BigInt(swapQuote.minAmountOut),
      `1,000 USDC -> ${units(wethOut, 18, 6)} WETH, API minimum ${units(BigInt(swapQuote.minAmountOut), 18, 6)} (oracle ${units(BigInt(swapQuote.oracleAmountOut), 18, 6)}); at 0 bps slippage the swap reverts ${tightRevert}`,
    );

    // 7. Indexer: every operation above ended with an event the API can serve.
    const events = await get<any[]>(`/events?fromBlock=${startBlock}`);
    const names = new Set(events.map((e) => e.event));
    const expected = ["Deposited", "ReportAccepted", "PayoutRequested", "PayoutExecuted", "AllocatedToHubSpokeVault"];
    const missing = expected.filter((n) => !names.has(n) && !(n === "PayoutExecuted" && names.has("PartialPayoutExecuted")));
    record("indexer sees every operation", missing.length === 0, `${events.length} Core Vault events (${[...names].join(", ")})${missing.length ? `; missing ${missing.join(", ")}` : ""}`);

    // 8. Holder view after the exit: shares and value consistent with the Share Price.
    const fund = await get("/fund");
    const anaEnd = await get(`/holders/${ana}`);
    const expectedValue = (BigInt(anaEnd.shares) * BigInt(fund.sharePrice.raw)) / 10n ** 36n;
    record("holder value follows the Share Price", BigInt(anaEnd.value) === expectedValue, `${BigInt(anaEnd.shares) / 10n ** 18n} shares at ${fund.sharePrice.usdcPerShare} = ${units(BigInt(anaEnd.value))} USDC`);
  } finally {
    await keeper?.stop();
    server.close();
  }
  const failed = results.filter((r) => !r.ok);
  console.log(failed.length === 0 ? green(bold(`PASS ${results.length} concepts`)) : red(bold(`FAIL ${failed.length} of ${results.length}`)));
  return { results, failed: failed.length };
}

if (isMain(import.meta.url)) {
  probe()
    .then(({ failed }) => process.exit(failed === 0 ? 0 : 1))
    .catch((err) => {
      console.error(red(`probe failed: ${(err as Error).message}`));
      process.exit(1);
    });
}
