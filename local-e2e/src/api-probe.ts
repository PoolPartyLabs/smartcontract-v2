// Drives the minimal API (src/api.ts) over HTTP against the two forks and checks each concept the API guide relies
// on, on a fund whose spoke never reported (the deployed one if unused, else a fresh one): quotes are exact, the API's
// transactions do what they say, a report follows each deposit and only one (DEC-159), freshness gates mints and not
// payouts, the bridge quote is what the adapter fixes (DEC-162), the API signs routes only within its limits, a signed
// swap route executes on the live V3 pools, direct and in two hops, and a tampered one is refused, the fund's own swap
// adapters are the Mandate's (Mandate v2) and the API signs for them, every operation ends with an event a server can
// index, and the Share Price history follows the mints. Each run writes a run report.
// Run: `pnpm run up && pnpm api:probe; pnpm run down`.
import { type Address, type Hex, type TransactionReceipt } from "viem";
import { coreVaultAbi, erc20Abi, spokeVaultAbi, uniswapV3SwapAdapterAbi } from "./abis.ts";
import { explain, nodes, read, recordTransaction, send, simulateRevert, wallet, type Side } from "./chain.ts";
import { actors, ARBITRUM, ROBINHOOD, isMain, type ActorName } from "./config.ts";
import { freshFund } from "./deploy.ts";
import { DEFAULT_KEEPER_OPTIONS, startKeeper, type Keeper } from "./keeper.ts";
import { bold, green, logger, red, units } from "./log.ts";
import { RunReport } from "./report.ts";
import { readState } from "./state.ts";
import { API_PORT, startApi, type UnsignedTx } from "./api.ts";
import { encodeRoute, type ApiRoute } from "./swap-route.ts";
import { warp } from "./warp.ts";

const BASE = `http://127.0.0.1:${API_PORT}`;
const results: { concept: string; ok: boolean; detail: string }[] = [];
let report: RunReport | undefined;

function record(concept: string, ok: boolean, detail: string) {
  results.push({ concept, ok, detail });
  report?.step(`${ok ? "ok" : "FAIL"} ${concept}: ${detail}`);
  console.log(`${ok ? green("ok  ") : red("FAIL")} ${concept}: ${detail}`);
}

async function get<T = any>(path: string): Promise<T> {
  const res = await fetch(`${BASE}${path}`);
  const body = await res.json();
  if (!res.ok) throw Object.assign(new Error(`GET ${path}: ${res.status} ${JSON.stringify(body)}`), { status: res.status, body });
  return body as T;
}

/** The HTTP status of a GET (for the routes that must refuse). */
async function statusOf(path: string): Promise<number> {
  const res = await fetch(`${BASE}${path}`);
  await res.text();
  return res.status;
}

async function post<T = any>(path: string, payload: Record<string, string>): Promise<{ status: number; body: T }> {
  const res = await fetch(`${BASE}${path}`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(payload) });
  return { status: res.status, body: (await res.json()) as T };
}

/** Signs and sends the API's unsigned transactions with the actor's key, in order; returns the receipts. */
async function signAndSend(side: Side, who: ActorName, txs: UnsignedTx[]): Promise<TransactionReceipt[]> {
  const receipts = [];
  for (const tx of txs) {
    const hash = await wallet(side, who).sendTransaction({ to: tx.to, data: tx.data, account: actors[who], chain: nodes[side].chain } as never);
    const receipt = await nodes[side].client.waitForTransactionReceipt({ hash, pollingInterval: 100 });
    if (receipt.status !== "success") throw new Error(`${tx.description} reverted (${hash})`);
    recordTransaction(side, tx.description, receipt);
    receipts.push(receipt);
  }
  return receipts;
}

async function waitFor(what: string, probe: () => Promise<boolean>, seconds = 120): Promise<void> {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    if (await probe()) return;
    await new Promise((r) => setTimeout(r, 250));
  }
  throw new Error(`timed out after ${seconds}s waiting for ${what}`);
}

/** Executes a signed route through the harness's swap adapter of the chain as its vault (the manager's wallet: the
 *  fund's own adapter takes `swap` only from its Spoke Vault, which step 6 drives), and checks that a tampered copy is
 *  refused. `hops` asks the API for a path of that many hops; `twoHopCandidates` requires two-hop
 *  paths among those quoted. */
async function signedRoute(
  side: Side,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
  label: string,
  expect: { hops?: 1 | 2; twoHopCandidates?: boolean } = {},
) {
  const hopsQuery = expect.hops ? `&hops=${expect.hops}` : "";
  const quote = await get(`/quote/swap-route?chain=${side}&tokenIn=${tokenIn}&tokenOut=${tokenOut}&amountIn=${amountIn}${hopsQuery}`);
  const adapter = quote.adapter as Address;
  await send(side, "manager", { address: tokenIn, abi: erc20Abi, functionName: "approve", args: [adapter, amountIn] });
  const swapped = await send<readonly [bigint, bigint]>(side, "manager", {
    address: adapter,
    abi: uniswapV3SwapAdapterAbi,
    functionName: "swap",
    args: [tokenIn, tokenOut, amountIn, 0, quote.encodedRoute],
  });
  const [amountOut] = swapped.result;
  // The same route with a looser minimum and the API's signature: the adapter must refuse it.
  const route = quote.route as Record<string, any>;
  const tampered: ApiRoute = {
    paths: route.paths,
    weightsBps: route.weightsBps,
    quotedAmountIn: BigInt(route.quotedAmountIn),
    minAmountOut: BigInt(route.minAmountOut) - 1n,
    deadline: BigInt(route.deadline),
    signature: route.signature,
  };
  await send(side, "manager", { address: tokenIn, abi: erc20Abi, functionName: "approve", args: [adapter, amountIn] });
  const refused = await simulateRevert(side, "manager", {
    address: adapter,
    abi: uniswapV3SwapAdapterAbi,
    functionName: "swap",
    args: [tokenIn, tokenOut, amountIn, 0, encodeRoute(tampered)],
  });
  await send(side, "manager", { address: tokenIn, abi: erc20Abi, functionName: "approve", args: [adapter, 0n] });
  const hops = (quote.path.tokens as string[]).length - 1;
  const twoHops = (quote.candidates as { tokens: string[] }[]).filter((c) => c.tokens.length === 3).length;
  record(
    `signed swap route (${label})`,
    amountOut >= BigInt(route.minAmountOut) &&
      amountOut === BigInt(quote.quotedAmountOut) &&
      refused === "InvalidRouteSignature" &&
      (!expect.twoHopCandidates || twoHops > 0) &&
      (!expect.hops || hops === expect.hops),
    `best of ${quote.candidates.length} quoted paths (${twoHops} through another Mandate token): ${hops} hop(s), fees ` +
      `${quote.path.fees.join("/")}; executed ${amountOut} for a quote of ${quote.quotedAmountOut} (minimum ${route.minAmountOut}); ` +
      `a tampered minimum reverts ${refused ?? "nothing"}`,
  );
}

export async function probe() {
  const log = logger("api-probe");
  const state = readState();
  const fresh = await freshFund(state, log.child("deploy"));
  const fund = fresh.fund;
  if (fresh.created) console.log(`the deployed fund was used: fresh fund ${fund.shareSymbol} (Core Vault ${fund.hub.coreVault})`);
  report = new RunReport("api-probe", state, fund);
  const server = await startApi(API_PORT, { fund, keeperInProcess: true });
  let keeper: Keeper | undefined;
  let failure: string | undefined;
  try {
    keeper = await startKeeper({ ...state, fund }, { ...DEFAULT_KEEPER_OPTIONS, autoReportSeconds: 0, quiet: true }, log.child("keeper"));
    const core = fund.hub.coreVault;
    const ana = actors.ana.address;
    const bruno = actors.bruno.address;
    const startBlock = await nodes.arbitrum.client.getBlockNumber();

    // 1. Health: both forks answer; a fund whose spoke never reported is open for mints.
    report.phase("health and deposits");
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
    const sharesBefore = BigInt((await get(`/holders/${ana}`)).shares);
    const { body: depositTxs } = await post<UnsignedTx[]>("/tx/deposit", { from: ana, amount: amount.toString(), minShares: q.shares });
    const depositReceipts = await signAndSend("arbitrum", "ana", depositTxs);
    const anaAfter = await get(`/holders/${ana}`);
    record(
      "deposit quote is exact",
      BigInt(anaAfter.shares) - sharesBefore === BigInt(q.shares),
      `quoted ${BigInt(q.shares) / 10n ** 18n} shares for ${units(BigInt(q.usdcCharged))} USDC, minted ${(BigInt(anaAfter.shares) - sharesBefore) / 10n ** 18n}`,
    );

    // 3. DEC-159: the API publishes a report on the spoke right after the deposit; the keeper delivers it on the Hub.
    //    It is the fund's first report, so it also opens the first send (S-14) and starts the freshness clock.
    const depositTx = depositReceipts[depositReceipts.length - 1];
    const after = await post<any>("/report/after-deposit", { txHash: depositTx.transactionHash });
    const published = after.body.reports?.[0];
    h = await get("/health");
    record(
      "a report after each deposit (DEC-159)",
      after.status === 200 &&
        published?.hubReportSequence === published?.reportSequence &&
        published?.deliveredBy === "keeper" &&
        Number(published?.reportTimestamp) >= Number((await nodes.arbitrum.client.getBlock({ blockNumber: depositTx.blockNumber })).timestamp) &&
        h.spokeReport.fresh === true,
      `report ${published?.reportSequence} published by the API signer after deposit block ${depositTx.blockNumber}, delivered by the ${published?.deliveredBy}; the Hub holds report ${published?.hubReportSequence}`,
    );

    // The same deposit again: the first answer and no second report, which the API signer would pay.
    const spokeSequence = () => read<bigint>("robinhood", { address: fund.spoke.spokeVault, abi: spokeVaultAbi, functionName: "reportSequence" });
    const sequenceBefore = await spokeSequence();
    const replay = await post<any>("/report/after-deposit", { txHash: depositTx.transactionHash });
    const sequenceAfter = await spokeSequence();
    record(
      "one report per deposit",
      replay.status === 200 && replay.body.reports?.[0]?.reportSequence === published?.reportSequence && sequenceAfter === sequenceBefore,
      `a replay of the deposit answers report ${replay.body.reports?.[0]?.reportSequence} again; the spoke's report sequence stays ${sequenceAfter}`,
    );

    // 4. Freshness gates mints, not payouts (Q57 reading, OQ-10): past the report lifetime with no new report the API
    //    refuses to build a deposit and the chain agrees; a payout from Idle still goes through.
    report.phase("freshness, payouts and the manager's swap guard");
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

    // 6. Manager swap guard (security review S-8, open): the vault's `swap` through the fund's swap adapter holds a swap
    //    only to the manager's loss bound and a signed route's minimum (DEC-142); the API only builds swaps on a route
    //    it signs with the oracle value less its slippage, and a minimum the pool cannot meet reverts by name.
    await send("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "allocateToHubSpokeVault", args: [2_000_000_000n] });
    const swapQuote = await get(`/quote/swap?tokenIn=${ARBITRUM.usdc}&amountIn=1000000000`);
    const wethBefore = await read<bigint>("arbitrum", { address: fund.hub.spokeVault, abi: spokeVaultAbi, functionName: "unallocatedBalance", args: [ARBITRUM.weth] });
    const { body: swapTxs } = await post<UnsignedTx[]>("/tx/swap", { tokenIn: ARBITRUM.usdc, amountIn: "1000000000" });
    await signAndSend("arbitrum", "manager", swapTxs);
    const wethOut = (await read<bigint>("arbitrum", { address: fund.hub.spokeVault, abi: spokeVaultAbi, functionName: "unallocatedBalance", args: [ARBITRUM.weth] })) - wethBefore;
    let tightRevert = "none";
    try {
      await nodes.arbitrum.client.simulateContract({
        account: actors.manager.address,
        address: fund.hub.spokeVault,
        abi: spokeVaultAbi,
        functionName: "swap",
        args: [fund.hub.uniswapV3SwapAdapter, ARBITRUM.usdc, ARBITRUM.weth, 1_000_000_000n, 1, "0x"],
      });
    } catch (error) {
      tightRevert = (await import("./api.ts")).decodeRevert(error)?.error ?? "reverted";
    }
    record(
      "swap guard off chain",
      wethOut >= BigInt(swapQuote.minAmountOut) && tightRevert !== "none" && tightRevert === "InsufficientOutput",
      `1,000 USDC -> ${units(wethOut, 18, 6)} WETH, API minimum ${units(BigInt(swapQuote.minAmountOut), 18, 6)} (oracle ${units(BigInt(swapQuote.oracleAmountOut), 18, 6)}); at a 1 bps loss bound without an API route the swap reverts ${tightRevert}`,
    );

    // 7. DEC-158, DEC-162: the bridge quote is what the fund's Across adapter fixes; nobody passes it to the vault.
    report.phase("bridge quotes and signed swap routes");
    const toSpoke = await get(`/quote/bridge?direction=to-spoke&amount=1000000000`);
    const sent = await send<Hex>("arbitrum", "manager", { address: core, abi: coreVaultAbi, functionName: "sendToSpoke", args: [0n, 1_000_000_000n, 0n, "0x"] });
    const transit = await read<{ amountToArrive: bigint }>("arbitrum", { address: core, abi: coreVaultAbi, functionName: "transit", args: [sent.result] });
    await waitFor("the Across fill on Robinhood", () =>
      read<boolean>("robinhood", { address: fund.spoke.spokeVault, abi: spokeVaultAbi, functionName: "hasArrived", args: [sent.result] }),
    );
    const toHub = await get(`/quote/bridge?direction=to-hub&amount=200000000`);
    const home = await send<Hex>("robinhood", "manager", { address: fund.spoke.spokeVault, abi: spokeVaultAbi, functionName: "sendToHub", args: [200_000_000n, 0, 0n] });
    const homeTransit = await read<{ amountToArrive: bigint }>("robinhood", { address: fund.spoke.spokeVault, abi: spokeVaultAbi, functionName: "hubBoundTransit", args: [home.result] });
    record(
      "the bridge quote is what the adapter fixes",
      BigInt(toSpoke.amountToArrive) === transit.amountToArrive && BigInt(toHub.amountToArrive) === homeTransit.amountToArrive && toSpoke.signed === false,
      `to Robinhood: quoted ${units(BigInt(toSpoke.amountToArrive))} for 1,000 USDC (rate ${units(BigInt(toSpoke.rateWad), 16, 3)}%), sent ${units(transit.amountToArrive)}; ` +
        `home: quoted ${units(BigInt(toHub.amountToArrive))} for 200 USDG, sent ${units(homeTransit.amountToArrive)}; unsigned until WP-11`,
    );

    // 8. Founder chat 1, DEC-143, DEC-153: a route the API signs executes on the live V3 pools; a tampered one reverts.
    //    The API signs only within its limits: never a minimum looser than the vault's 5% floor, never for an adapter
    //    it does not serve (every production adapter accepts its signature, D-01; DEC-142).
    const routeQuery = `/quote/swap-route?chain=robinhood&tokenIn=${ROBINHOOD.usdg}&tokenOut=${ROBINHOOD.weth}&amountIn=1000000000`;
    const looseStatus = await statusOf(`${routeQuery}&slippageBps=10000`);
    const foreignStatus = await statusOf(`${routeQuery}&adapter=${actors.stranger.address}`);
    record(
      "the API signs routes only within its limits",
      looseStatus === 400 && foreignStatus === 422,
      `slippageBps 10000 (a zero minimum) answers ${looseStatus}; an adapter the API does not serve answers ${foreignStatus}`,
    );
    await signedRoute("arbitrum", ARBITRUM.usdc, ARBITRUM.weth, 1_000_000_000n, "Arbitrum USDC -> WETH");
    await signedRoute("robinhood", ROBINHOOD.usdg, ROBINHOOD.weth, 1_000_000_000n, "Robinhood USDG -> WETH");
    await signedRoute("robinhood", ROBINHOOD.usdg, ROBINHOOD.nvda, 1_000_000_000n, "Robinhood USDG -> NVDA, direct or through WETH", { twoHopCandidates: true });
    // Two hops through WETH, a Mandate token: the packed path with two fees and the adapter's check of every hop.
    await signedRoute("robinhood", ROBINHOOD.usdg, ROBINHOOD.nvda, 1_000_000_000n, "Robinhood USDG -> WETH -> NVDA, two hops", { hops: 2 });

    // Mandate v2 (DEC-136 and its closing note, D-01): the factory deployed one swap adapter per chain at the address
    // the Mandate lists; its vault is that chain's Spoke Vault, which pins it, its route signer is the API key, and it
    // swaps only that chain's Mandate tokens, so the API signs USDG -> WETH for it and refuses USDG -> NVDA.
    const fundSwap = { arbitrum: { adapter: fund.hub.uniswapV3SwapAdapter, vault: fund.hub.spokeVault }, robinhood: { adapter: fund.spoke.uniswapV3SwapAdapter, vault: fund.spoke.spokeVault } };
    const wiring: string[] = [];
    let wired = true;
    for (const side of ["arbitrum", "robinhood"] as const) {
      const { adapter, vault } = fundSwap[side];
      const at = <T>(functionName: string, args: unknown[] = []) => read<T>(side, { address: adapter, abi: uniswapV3SwapAdapterAbi, functionName, args });
      const [adapterVault, signer, pinned] = await Promise.all([
        at<Address>("vault"),
        at<Address>("routeSigner"),
        read<Address[]>(side, { address: vault, abi: spokeVaultAbi, functionName: "swapAdapters" }),
      ]);
      const ok = adapterVault === vault && signer === actors.apiSigner.address && pinned.length === 1 && pinned[0] === adapter;
      wired &&= ok;
      wiring.push(`${side} ${adapter}: vault ${adapterVault === vault ? "its Spoke Vault" : adapterVault}, signer ${signer === actors.apiSigner.address ? "the API key" : signer}, pinned ${pinned.join("/")}`);
    }
    const fundRoute = await get(`${routeQuery}&adapter=${fund.spoke.uniswapV3SwapAdapter}`);
    const outsideMandate = await statusOf(
      `/quote/swap-route?chain=robinhood&tokenIn=${ROBINHOOD.usdg}&tokenOut=${ROBINHOOD.nvda}&amountIn=1000000000&adapter=${fund.spoke.uniswapV3SwapAdapter}`,
    );
    record(
      "the fund's swap adapters are the Mandate's (Mandate v2)",
      wired && fundRoute.adapter === fund.spoke.uniswapV3SwapAdapter && BigInt(fundRoute.quotedAmountOut) > 0n && outsideMandate === 422,
      `${wiring.join("; ")}; the API signed USDG -> WETH for the fund's Robinhood adapter (${fundRoute.path.fees.join("/")}) and answers ${outsideMandate} for NVDA, outside its Mandate`,
    );

    // 9. Indexer: every operation above ended with an event the API can serve.
    report.phase("indexer, Share Price history and holders");
    const events = await get<any[]>(`/events?fromBlock=${startBlock}`);
    const names = new Set(events.map((e) => e.event));
    const expected = ["Deposited", "ReportAccepted", "PayoutRequested", "PayoutExecuted", "AllocatedToHubSpokeVault", "SentToSpoke"];
    const missing = expected.filter((n) => !names.has(n) && !(n === "PayoutExecuted" && names.has("PartialPayoutExecuted")));
    record("indexer sees every operation", missing.length === 0, `${events.length} Core Vault events (${[...names].join(", ")})${missing.length ? `; missing ${missing.join(", ")}` : ""}`);

    // 10. Share Price history: a point at every block with a Core Vault event; at every mint it is the mint's price
    //     (rounding only), from the seed at 1.00 on.
    const history = await get<any[]>("/share-price/history");
    const allEvents = await get<any[]>(`/events?fromBlock=${fund.hub.createdInBlock}`);
    const mints = allEvents.filter((e) => e.event === "Deposited" || e.event === "FundSeeded");
    const pointAt = (block: string) => history.find((p) => p.block === block);
    const mintsMatch = mints.every((m) => {
      const point = pointAt(m.block);
      if (!point) return false;
      const minted = m.event === "FundSeeded" ? 10n ** 24n : BigInt(m.args.sharePrice);
      const diff = BigInt(point.sharePrice) - minted;
      return (diff < 0n ? -diff : diff) <= minted / 10n ** 9n;
    });
    const ordered = history.every((p, i) => i === 0 || BigInt(p.block) > BigInt(history[i - 1].block));
    record(
      "Share Price history follows the mints",
      mintsMatch && ordered && history.length > 0,
      `${history.length} points from block ${history[0]?.block}; ${mints.length} mints at their price (seed at 1.000000)`,
    );

    // 11. Holder view after the exit: shares and value consistent with the Share Price.
    const fundView = await get("/fund");
    const anaEnd = await get(`/holders/${ana}`);
    const expectedValue = (BigInt(anaEnd.shares) * BigInt(fundView.sharePrice.raw)) / 10n ** 36n;
    record("holder value follows the Share Price", BigInt(anaEnd.value) === expectedValue, `${BigInt(anaEnd.shares) / 10n ** 18n} shares at ${fundView.sharePrice.usdcPerShare} = ${units(BigInt(anaEnd.value))} USDC`);
  } catch (err) {
    failure = explain(err);
    throw err;
  } finally {
    await keeper?.stop();
    server.close();
    const failed = results.filter((r) => !r.ok);
    report.assertions = results.length;
    const files = await report.write({
      passed: !failure && failed.length === 0,
      error: failure ?? (failed.length ? failed.map((f) => `${f.concept}: ${f.detail}`).join("\n") : undefined),
      extra: { concepts: results, keeperStats: keeper?.stats },
    });
    console.log(`run report: local-e2e/${files.md} (and .json)`);
  }
  const failed = results.filter((r) => !r.ok);
  console.log(failed.length === 0 ? green(bold(`PASS ${results.length} concepts`)) : red(bold(`FAIL ${failed.length} of ${results.length}`)));
  return { results, failed: failed.length };
}

if (isMain(import.meta.url)) {
  probe()
    .then(({ failed }) => process.exit(failed === 0 ? 0 : 1))
    .catch((err) => {
      console.error(red(`probe failed: ${explain(err)}`));
      process.exit(1);
    });
}
