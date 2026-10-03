import { safeConsole as console } from "./log.ts";
import assert from "node:assert/strict";
import {appendFileSync} from "node:fs";
import {createPublicClient, createWalletClient, defineChain, http, getAddress, encodeAbiParameters, parseAbi, type Address, type Hex, type Abi} from "viem";
import {privateKeyToAccount} from "viem/accounts";
import {coreVaultAbi, spokeVaultAbi, erc20Abi, shareTokenAbi} from "./abis.ts";
import {ARBITRUM, ROBINHOOD, AAVE_USDC_POOL_KEY, SPOKE_POOL_ID} from "./config.ts";
import {openParams} from "./uniswap.ts";
import {postReport} from "./alpha-report-client.ts";

// Mainnet alpha manual steps not covered by alpha-mainnet-smoke.ts: open positions, second investor, status.
const mode = process.argv[2]!;
assert.ok(["spoke-position", "hub-aave", "investor-deposit", "investor-payout", "hub-batch", "status"].includes(mode));
const directory = process.env.ALPHA_RECORD_DIR!;
assert.ok(directory);
const core = getAddress(process.env.ALPHA_CORE_VAULT!);
const spoke = getAddress(process.env.ALPHA_SPOKE_VAULT!);
const hubSpoke = getAddress(process.env.ALPHA_HUB_SPOKE_VAULT!);
const shareToken = getAddress(process.env.ALPHA_SHARE_TOKEN!);
const investorMode = mode.startsWith("investor");
const manager = privateKeyToAccount(process.env.ALPHA_MANAGER_KEY as Hex);
const investor = process.env.ALPHA_INVESTOR_KEY ? privateKeyToAccount(process.env.ALPHA_INVESTOR_KEY as Hex) : undefined;
const account = investorMode ? investor! : manager;
const chains = Object.fromEntries((["hub", "spoke"] as const).map((side) => {
  const id = side === "hub" ? 42161 : 4663;
  const rpc = process.env[side === "hub" ? "ARBITRUM_RPC_URL" : "ROBINHOOD_RPC_URL"]!;
  const chain = defineChain({id, name: side, nativeCurrency: {name: "Ether", symbol: "ETH", decimals: 18}, rpcUrls: {default: {http: [rpc]}}});
  return [side, {client: createPublicClient({chain, transport: http(rpc)}), wallet: createWalletClient({chain, transport: http(rpc)})}];
}));
const json = (value: unknown) => JSON.stringify(value, (_, entry) => typeof entry === "bigint" ? entry.toString() : entry);
const record = (value: object) => appendFileSync(`${directory}/positions.jsonl`, json({mode, at: new Date().toISOString(), ...value}) + "\n");
const read = (side: string, address: Address, abi: Abi, functionName: string, args: unknown[] = []): Promise<any> =>
  chains[side]!.client.readContract({address, abi, functionName, args} as never);
async function send(side: string, address: Address, abi: Abi, functionName: string, args: unknown[] = [], signer = account) {
  const node = chains[side]!;
  const {request, result} = await node.client.simulateContract({account: signer, address, abi, functionName, args} as never);
  const hash = await node.wallet.writeContract(request as never);
  record({side, signer: signer.address, functionName, hash, status: "submitted"});
  const receipt = await node.client.waitForTransactionReceipt({hash});
  record({side, functionName, hash, status: receipt.status, gasUsed: receipt.gasUsed, result});
  assert.equal(receipt.status, "success", `${functionName} reverted`);
  console.log(json({side, functionName, hash, gasUsed: receipt.gasUsed, result}));
  return result;
}
async function report() {
  const {status, body} = await postReport();
  assert.equal(status, 200, "report failed");
  assert.equal(body.delivered, true);
  record({functionName: "report", sequence: body.sequence});
}

for (const [side, node] of Object.entries(chains)) assert.equal(await node.client.getChainId(), side === "hub" ? 42161 : 4663);
const mandate = await read("hub", core, coreVaultAbi, "mandate");
if (mode === "spoke-position") {
  const swapAdapter = getAddress(mandate.swapAdapters.find((entry: any) => Number(entry.chainId) === 4663).adapter);
  const v4 = getAddress(mandate.pools.find((entry: any) => Number(entry.chainId) === 4663).adapter);
  const balance: bigint = await read("spoke", spoke, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]);
  assert.ok(balance > 0n, "no unallocated USDG on the spoke");
  const half = balance / 2n;
  const weth: bigint = await send("spoke", spoke, spokeVaultAbi, "swap", [swapAdapter, ROBINHOOD.usdg, ROBINHOOD.weth, half, 100, "0x"]);
  const stateView = parseAbi(["function getSlot0(bytes32) view returns (uint160,int24,uint24,uint24)"]);
  const [, tick] = await read("spoke", ROBINHOOD.v4StateView, stateView, "getSlot0", [SPOKE_POOL_ID]);
  const center = Number(tick) - (Number(tick) % 10);
  const deadline = (await chains.spoke!.client.getBlock()).timestamp + 3600n;
  await send("spoke", spoke, spokeVaultAbi, "openPosition", [v4, SPOKE_POOL_ID, weth, half, openParams(center, 2000, weth, half, deadline)]);
} else if (mode === "hub-aave") {
  const aave = getAddress(mandate.pools.find((entry: any) => entry.poolKey.toLowerCase() === AAVE_USDC_POOL_KEY.toLowerCase()).adapter);
  const amount = BigInt(process.env.ALPHA_AAVE_AMOUNT ?? "1000000");
  await report();
  await send("hub", core, coreVaultAbi, "allocateToHubSpokeVault", [amount]);
  await send("hub", hubSpoke, spokeVaultAbi, "openPosition", [aave, AAVE_USDC_POOL_KEY, amount, 0n, encodeAbiParameters([{type: "uint256"}], [amount])]);
  await report();
} else if (mode === "investor-deposit") {
  const amount = BigInt(process.env.ALPHA_INVESTOR_DEPOSIT ?? "2000000");
  await report();
  await send("hub", ARBITRUM.usdc, erc20Abi, "approve", [core, amount]);
  await send("hub", core, coreVaultAbi, "deposit", [amount, 1n]);
  await report();
} else if (mode === "hub-batch") {
  // One report window for the hub writes: Aave allocation (manager) and a second investor's deposit, then the
  // investor's Instant exit after the post-mint report. Saves two ~15-minute report cycles versus separate modes.
  assert.ok(investor, "ALPHA_INVESTOR_KEY required");
  const aave = getAddress(mandate.pools.find((entry: any) => entry.poolKey.toLowerCase() === AAVE_USDC_POOL_KEY.toLowerCase()).adapter);
  const aaveAmount = BigInt(process.env.ALPHA_AAVE_AMOUNT ?? "1000000");
  const deposit = BigInt(process.env.ALPHA_INVESTOR_DEPOSIT ?? "2000000");
  await report();
  await send("hub", core, coreVaultAbi, "allocateToHubSpokeVault", [aaveAmount], manager);
  await send("hub", hubSpoke, spokeVaultAbi, "openPosition", [aave, AAVE_USDC_POOL_KEY, aaveAmount, 0n, encodeAbiParameters([{type: "uint256"}], [aaveAmount])], manager);
  await send("hub", ARBITRUM.usdc, erc20Abi, "approve", [core, deposit], investor);
  await send("hub", core, coreVaultAbi, "deposit", [deposit, 1n], investor);
  await report();
  await send("hub", core, coreVaultAbi, "requestPayout", [BigInt(process.argv[3] ?? "1000000"), 0, 100], investor);
  await report();
} else if (mode === "investor-payout") {
  const amount = BigInt(process.argv[3] ?? "1000000");
  await report();
  await send("hub", core, coreVaultAbi, "requestPayout", [amount, 0, 100]);
  await report();
}
const holders = [getAddress(process.env.MANAGER!), ...(process.env.ALPHA_INVESTOR_ADDRESS ? [getAddress(process.env.ALPHA_INVESTOR_ADDRESS)] : [])];
const status: Record<string, unknown> = {
  fundState: await read("hub", core, coreVaultAbi, "fundState"),
  sharePrice: await read("hub", core, coreVaultAbi, "sharePrice"),
  totalSupply: await read("hub", shareToken, shareTokenAbi, "totalSupply"),
  idle: await read("hub", core, coreVaultAbi, "idle"),
  spokeUnallocatedUsdg: await read("spoke", spoke, spokeVaultAbi, "unallocatedBalance", [ROBINHOOD.usdg]),
  spokePositions: (await read("spoke", spoke, spokeVaultAbi, "positions")).length,
  hubPositions: (await read("hub", hubSpoke, spokeVaultAbi, "positions")).length,
};
for (const holder of holders) {
  status[`shares:${holder}`] = await read("hub", shareToken, shareTokenAbi, "balanceOf", [holder]);
  status[`incomeOwed:${holder}`] = await read("hub", core, coreVaultAbi, "incomeOwed", [holder]);
}
record({functionName: "status", ...status});
console.log(json(status));
