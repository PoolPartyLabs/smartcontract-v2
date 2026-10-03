import assert from "node:assert/strict";
import {appendFileSync, mkdirSync} from "node:fs";
import {createPublicClient, createWalletClient, defineChain, http, getAddress, decodeEventLog, decodeAbiParameters, keccak256, type Address, type Hex, type Abi} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {coreVaultAbi, spokeVaultAbi, erc20Abi, acrossSpokePoolAbi, wormholeCoreAbi} from "./abis.ts";
import {ARBITRUM, ROBINHOOD, actors, guardian} from "./config.ts";
import {alphaAmounts} from "./alpha-amounts.ts";
import {collectAllowed} from "./alpha-work.ts";
import {parseAbi} from "viem";

async function main() {
  const mode = process.argv[2];
  assert.ok(["capital", "income", "closure"].includes(mode!));
  const account = privateKeyToAccount(process.env.ALPHA_MANAGER_KEY as Hex);
  assert.equal(account.address, getAddress(process.env.MANAGER!));
  assert.ok(![...Object.values(actors), guardian].some((entry) => entry.address === account.address), "Public test keys refused");
  assert.ok(!process.env.ALPHA_ALLOW_LOCAL_TEST_KEYS && !process.env.ALPHA_REHEARSAL_LOCAL_VAA);
  const core = getAddress(process.env.ALPHA_CORE_VAULT!);
  const spoke = getAddress(process.env.ALPHA_SPOKE_VAULT!);
  const directory = process.env.ALPHA_RECORD_DIR!;
  assert.ok(directory);
  mkdirSync(directory, {recursive: true});
  const chains = Object.fromEntries((["hub", "spoke"] as const).map((side) => {
    const id = side === "hub" ? 42161 : 4663;
    const rpc = process.env[side === "hub" ? "ARBITRUM_RPC_URL" : "ROBINHOOD_RPC_URL"]!;
    const chain = defineChain({id, name: side, nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18}, rpcUrls: {default: {http: [rpc]}}});
    return [side, {client: createPublicClient({chain, transport: http(rpc)}), wallet: createWalletClient({chain, account, transport: http(rpc)})}];
  }));
  for (const [side, node] of Object.entries(chains)) {
    assert.equal(await node.client.getChainId(), side === "hub" ? 42161 : 4663);
    assert.ok(!/anvil/i.test(await node.client.request({method: "web3_clientVersion"})));
  }
  const record = (value: unknown) => appendFileSync(`${directory}/continuation.jsonl`, JSON.stringify(value, (_, entry) => typeof entry === "bigint" ? entry.toString() : entry) + "\n");
  const read = (side: string, address: Address, abi: Abi, functionName: string, args: unknown[] = []): Promise<any> =>
    chains[side]!.client.readContract({address, abi, functionName, args} as never);
  async function send(side: string, address: Address, abi: Abi, functionName: string, args: unknown[] = [], value = 0n) {
    const node = chains[side]!;
    const {request} = await node.client.simulateContract({account, address, abi, functionName, args, value} as never);
    const hash = await node.wallet.writeContract(request as never);
    const receipt = await node.client.waitForTransactionReceipt({hash});
    assert.equal(receipt.status, "success");
    record({side, functionName, hash, gasUsed: receipt.gasUsed});
    return receipt;
  }
  async function wait(check: () => Promise<boolean>, label: string) {
    const deadline = Date.now() + 30 * 60 * 1000;
    while (!await check()) {
      if (Date.now() >= deadline) throw new Error(`Unresolved ${label}; reconcile saved receipts, never blindly rerun capital`);
      await new Promise((done) => setTimeout(done, 5000));
    }
  }
  const mandate = await read("hub", core, coreVaultAbi, "mandate");
  assert.equal(mandate.spokes.length, 1);
  assert.equal(Number(mandate.spokes[0].chainId), 4663);
  const quoteAbi = parseAbi(["function quoteSend(address,uint256,uint256,bytes) view returns (uint256,uint256)"]);
  const adapter = (side: string) => getAddress(mandate.bridgeAdapters.find((entry: any) => Number(entry.chainId) === (side === "hub" ? 42161 : 4663)).adapter);
  const fee = () => read("hub", ARBITRUM.wormholeCore, wormholeCoreAbi, "messageFee");
  async function report() {
    const response = await fetch(`http://127.0.0.1:${process.env.ALPHA_API_PORT ?? "8787"}/report`, {method: "POST", headers: {authorization: `Bearer ${process.env.ALPHA_API_TOKEN}`}});
    assert.equal(response.status, 200);
    assert.equal((await response.json() as any).delivered, true);
  }
  async function terms(side: string, amount: bigint) {
    const originChainId = side === "hub" ? 42161 : 4663;
    const destinationChainId = side === "hub" ? 4663 : 42161;
    const token = side === "hub" ? ARBITRUM.usdc : ROBINHOOD.usdg;
    const url = new URL("https://app.across.to/api/suggested-fees");
    for (const [key, value] of Object.entries({originChainId, destinationChainId, token, amount: amount.toString()})) url.searchParams.set(key, String(value));
    const response = await fetch(url, {signal: AbortSignal.timeout(15000)});
    assert.ok(response.ok, "Across route terms unavailable: STOP");
    const terms = await response.json() as any;
    assert.ok(terms.limits?.minDeposit && terms.totalRelayFee?.total, "Missing route limits/fees: STOP");
    assert.ok(!terms.isAmountTooLow && amount >= BigInt(terms.limits.minDeposit) && amount <= BigInt(terms.limits.maxDepositInstant), "Outside live route limits: STOP");
    const [arrival, rate] = await read(side, adapter(side), quoteAbi, "quoteSend", [token, BigInt(destinationChainId), amount, "0x"]);
    assert.ok(arrival > 0n && amount - arrival >= BigInt(terms.totalRelayFee.total), "Adapter fee below current relay terms: STOP; caller cannot widen fees");
    record({side, functionName: "routeTerms", amount, arrival, rate, limits: terms.limits, relayFee: terms.totalRelayFee.total});
    return arrival as bigint;
  }
  async function waitFill(origin: string, deposit: any, vault: Address, abi: Abi, eventName: string, fromBlock: bigint) {
    const destination = origin === "hub" ? "spoke" : "hub";
    const config = destination === "hub" ? ARBITRUM : ROBINHOOD;
    const event = acrossSpokePoolAbi.find((entry: any) => entry.name === "FilledRelay") as any;
    const [version, fundId, originChainId, transitId] = decodeAbiParameters([{type: "uint256"}, {type: "bytes32"}, {type: "uint256"}, {type: "bytes32"}, {type: "uint8"}], deposit.message);
    assert.equal(version, 1n);
    assert.equal(fundId, await read("hub", core, coreVaultAbi, "fundId"));
    assert.equal(originChainId, origin === "hub" ? 42161n : 4663n);
    await wait(async () => {
      const logs = await chains[destination]!.client.getLogs({address: config.acrossSpokePool, event, fromBlock,
        args: {originChainId: origin === "hub" ? 42161n : 4663n, depositId: deposit.depositId}} as never) as any[];
      const fill = logs.find((entry) => ["inputToken", "outputToken", "depositor", "recipient", "exclusiveRelayer"].every((key) => entry.args[key].toLowerCase() === deposit[key].toLowerCase())
        && ["inputAmount", "outputAmount", "fillDeadline", "exclusivityDeadline"].every((key) => BigInt(entry.args[key]) === BigInt(deposit[key])) && entry.args.messageHash === keccak256(deposit.message));
      if (!fill) return false;
      const receipt = await chains[destination]!.client.getTransactionReceipt({hash: fill.transactionHash});
      assert.equal(receipt.status, "success");
      const arrivals = receipt.logs.filter((entry) => getAddress(entry.address) === vault).flatMap((entry) => {
        try {const decoded = decodeEventLog({abi, ...entry}); return decoded.eventName === eventName ? [decoded.args as any] : [];} catch {return [];}
      });
      assert.equal(arrivals.length, 1);
      assert.equal(arrivals[0].amount, deposit.outputAmount);
      assert.equal(arrivals[0].transitId, transitId);
      assert.equal(arrivals[0].originChainId, originChainId);
      record({functionName: "matchedFill", hash: receipt.transactionHash, deposit, arrival: arrivals[0]});
      return true;
    }, "full relay-data match and vault arrival");
  }
  await report();
  if (mode === "capital") {
    assert.ok(BigInt(process.env.SEED_AMOUNT!) <= 5000000n && BigInt(process.env.SPOKE_CAP!) <= 100000000n);
    await send("hub", ARBITRUM.usdc, erc20Abi, "approve", [core, alphaAmounts.deposit]);
    await send("hub", core, coreVaultAbi, "deposit", [alphaAmounts.deposit, 1n]);
    await report();
    const arrival = await terms("hub", alphaAmounts.send);
    const head = await chains.spoke!.client.getBlockNumber();
    const receipt = await send("hub", core, coreVaultAbi, "sendToSpoke", [0n, alphaAmounts.send, 0n, "0x"]);
    const deposit = receipt.logs.filter((entry) => getAddress(entry.address) === getAddress(ARBITRUM.acrossSpokePool))
      .map((entry) => decodeEventLog({abi: acrossSpokePoolAbi, ...entry})).find((entry) => entry.eventName === "FundsDeposited")!.args as any;
    assert.equal(deposit.outputAmount, arrival);
    await waitFill("hub", deposit, spoke, spokeVaultAbi, "TransitArrived", head);
    await report();
    const sent = receipt.logs.filter((entry) => getAddress(entry.address) === core).flatMap((entry) => {
      try {const decoded = decodeEventLog({abi: coreVaultAbi, ...entry}); return decoded.eventName === "SentToSpoke" ? [decoded.args as any] : [];} catch {return [];}
    })[0];
    assert.equal(Number((await read("hub", core, coreVaultAbi, "transit", [sent.transitId])).state), 2);
    await send("hub", core, coreVaultAbi, "requestPayout", [alphaAmounts.payout, 0, 100]);
    await report();
    assert.equal(Number(await read("hub", core, coreVaultAbi, "fundState")), 0);
  } else if (mode === "income") {
    const positions = await read("spoke", spoke, spokeVaultAbi, "positions");
    for (const position of positions) await send("spoke", spoke, spokeVaultAbi, "collectIncome", [position.adapter, position.positionKey]);
    const value = await read("spoke", spoke, spokeVaultAbi, "collectedIncome", [ROBINHOOD.usdg]);
    if (value < alphaAmounts.collectMinimum) {record({functionName: "deferredCOLLECT", value, minimum: alphaAmounts.collectMinimum}); console.log("COLLECT deferred: retained base income below configured minimum"); return;}
    const arrival = await terms("spoke", value);
    assert.ok(collectAllowed(value, alphaAmounts.collectMinimum, arrival));
    await report();
    const head = await chains.spoke!.client.getBlockNumber();
    const hubHead = await chains.hub!.client.getBlockNumber();
    await send("hub", core, coreVaultAbi, "requestIncomeWithdrawal", [100], await fee());
    const depositEvent = acrossSpokePoolAbi.find((entry: any) => entry.name === "FundsDeposited") as any;
    let deposit: any;
    await wait(async () => {
      const logs = await chains.spoke!.client.getLogs({address: ROBINHOOD.acrossSpokePool, event: depositEvent, fromBlock: head}) as any[];
      deposit = logs.find((entry) => entry.args.recipient.toLowerCase().endsWith(core.slice(2).toLowerCase()))?.args;
      return !!deposit;
    }, "COLLECT bridge deposit");
    await waitFill("spoke", deposit, core, coreVaultAbi, "TransitReceived", hubHead);
    await report();
    await wait(async () => {const state = await read("hub", core, coreVaultAbi, "incomeCollection"); return state.pendingSpokes === 0n && state.openResults === 0n;}, "Income results credited");
    await send("hub", core, coreVaultAbi, "settleIncomeWithdrawal", [account.address]);
  } else {
    const head = await chains.spoke!.client.getBlockNumber();
    const hubHead = await chains.hub!.client.getBlockNumber();
    assert.equal(Number(await read("hub", core, coreVaultAbi, "fundState")), 0);
    await send("hub", core, coreVaultAbi, "closeFund");
    await send("hub", core, coreVaultAbi, "unwindAllAfterDeadline", [], await fee());
    const event = spokeVaultAbi.find((entry: any) => entry.name === "OrderExecuted") as any;
    await wait(async () => (await chains.spoke!.client.getLogs({address: spoke, event, fromBlock: head}) as any[]).some((entry) => Number(entry.args.kind) === 2), "CLOSE execution");
    const deposits = await chains.spoke!.client.getLogs({address: ROBINHOOD.acrossSpokePool, event: acrossSpokePoolAbi.find((entry: any) => entry.name === "FundsDeposited") as any, fromBlock: head}) as any[];
    for (const entry of deposits.filter((entry) => entry.args.recipient.toLowerCase().endsWith(core.slice(2).toLowerCase()))) await waitFill("spoke", entry.args, core, coreVaultAbi, "TransitReceived", hubHead);
    await report();
    const returns = await chains.spoke!.client.getLogs({address: spoke, event: spokeVaultAbi.find((entry: any) => entry.name === "SentToHub") as any, fromBlock: head}) as any[];
    for (const entry of returns.filter((entry) => Number(entry.args.transit.kind) === 0)) {
      await wait(async () => Number((await read("spoke", spoke, spokeVaultAbi, "hubBoundTransit", [entry.args.transitId])).state) === 2, "Principal acknowledgement delivered by durable keeper");
    }
    await send("hub", core, coreVaultAbi, "finalizeClosure");
    assert.equal(Number(await read("hub", core, coreVaultAbi, "fundState")), 2);
    const supply = await read("hub", core, coreVaultAbi, "closedSupply");
    const idle = await read("hub", core, coreVaultAbi, "closedIdle");
    const shares = await read("hub", getAddress(process.env.ALPHA_SHARE_TOKEN!), erc20Abi, "balanceOf", [account.address]);
    assert.equal(shares, 0n, "Finalization pays and burns the manager");
    const holder = process.env.ALPHA_EXIT_HOLDER ? getAddress(process.env.ALPHA_EXIT_HOLDER) : undefined;
    if (supply === 0n) {
      assert.equal(idle, 0n);
      record({functionName: "closedNoRemainingHolders", supply, idle});
      console.log("Mainnet closure passed: manager paid at finalization; no remaining holders");
      return;
    }
    assert.ok(holder, "Remaining holders: set ALPHA_EXIT_HOLDER to the approved investor wallet");
    const holderShares = await read("hub", getAddress(process.env.ALPHA_SHARE_TOKEN!), erc20Abi, "balanceOf", [holder]);
    assert.ok(holderShares > 0n);
    const expectedGross = holderShares * idle / supply;
    const receipt = await send("hub", core, coreVaultAbi, "exitClosedFund", [holder]);
    const exit = receipt.logs.flatMap((entry) => {
      try {const decoded = decodeEventLog({abi: coreVaultAbi, ...entry}); return decoded.eventName === "ClosedFundExited" ? [decoded.args as any] : [];} catch {return [];}
    })[0];
    assert.equal(exit.gross, expectedGross);
    assert.equal(await read("hub", core, coreVaultAbi, "closedSupply"), supply);
  }
  console.log(`Mainnet ${mode} continuation passed; receipts retained`);
}

main().catch(() => {console.error("Mainnet continuation stopped: inspect redacted receipts and chain state; do not blindly repeat sends"); process.exitCode = 1;});
