// Gives every actor ETH and the tokens they need on both nodes, deterministically and idempotently: balances are
// topped up to a target (never lowered), ERC-20 balances are written into the token's balance mapping (its slot found
// once by tracing `balanceOf`), WETH is wrapped from ETH, and the approvals the harness relies on are set once.
//
// Standalone: `pnpm exec tsx src/fund-accounts.ts` tops everything up again on the running nodes.
import { encodeAbiParameters, keccak256, maxUint256, pad, toHex, type Address, type Hex } from "viem";
import { erc20Abi } from "./abis.ts";
import { anvil, nodes, read, rpc, runMain, send, type Side } from "./chain.ts";
import { ARBITRUM, ROBINHOOD, actors, isMain, type ActorName } from "./config.ts";
import { logger, units, type Logger } from "./log.ts";
import { readState, type BalanceLayout, type DeploymentState } from "./state.ts";

const EIP1967_SLOTS = new Set([
  "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc", // implementation
  "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103", // admin
  "0xa3f0ad74e5423aebfd80d3ef4346578335a9a72aeaee59ff6cb3582b35133d50", // beacon
]);

/** `keccak256(abi.encode(key, mappingSlot))`: the storage slot of `key` in a Solidity mapping at `mappingSlot`. */
export function mappingSlot(key: Hex, slot: bigint): Hex {
  const isAddress = key.length === 42;
  return keccak256(
    encodeAbiParameters([{ type: isAddress ? "address" : "bytes32" }, { type: "uint256" }], [key as never, slot]),
  );
}

/** The storage keys a call reads on `target` (anvil's prestate tracer; the target's own storage, proxies included). */
export async function storageRead(side: Side, target: Address, data: Hex, from?: Address): Promise<Hex[]> {
  const trace = await rpc<Record<string, { storage?: Record<string, Hex> }>>(side, "debug_traceCall", [
    { to: target, data, from },
    "latest",
    { tracer: "prestateTracer" },
  ]);
  const account = trace[target.toLowerCase()];
  return Object.keys(account?.storage ?? {}) as Hex[];
}

/** Finds the Solidity mapping slot `index` of `token`'s balances: traces `balanceOf(probe)`, matches the storage key
 *  it read against `keccak256(abi.encode(probe, index))`, and confirms by writing a marker. */
export async function discoverBalanceLayout(side: Side, token: Address, probe: Address): Promise<BalanceLayout> {
  const data = `0x70a08231${probe.slice(2).toLowerCase().padStart(64, "0")}` as Hex;
  const keys = new Set((await storageRead(side, token, data)).filter((k) => !EIP1967_SLOTS.has(k)));
  for (let index = 0n; index < 1024n; index++) {
    const slot = mappingSlot(probe, index);
    if (!keys.has(slot)) continue;
    const before = await nodes[side].client.getStorageAt({ address: token, slot });
    const marker = 123_456_789n;
    await anvil.setStorageAt(side, token, slot, pad(toHex(marker)));
    const seen = await read<bigint>(side, { address: token, abi: erc20Abi, functionName: "balanceOf", args: [probe] });
    await anvil.setStorageAt(side, token, slot, before ?? pad("0x0"));
    if (seen === marker) return { token, mappingSlot: index.toString() };
  }
  throw new Error(`could not find the balance mapping of ${token} on ${nodes[side].label}`);
}

/** The Solidity mapping slot index `n` such that `data` (a call on `target` taking `key` as its mapping key) reads
 *  `keccak256(abi.encode(key, n))`. */
export async function discoverMappingSlot(side: Side, target: Address, data: Hex, key: Hex, maxIndex = 5000n): Promise<string> {
  const keys = new Set(await storageRead(side, target, data));
  for (let index = 0n; index < maxIndex; index++) {
    if (keys.has(mappingSlot(key, index))) return index.toString();
  }
  throw new Error(`no mapping slot below ${maxIndex} matches the storage ${target} read on ${nodes[side].label}`);
}

export async function balanceOf(side: Side, token: Address, holder: Address): Promise<bigint> {
  return read<bigint>(side, { address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] });
}

/** Writes `amount` into `holder`'s balance slot (totalSupply is left alone: a dev fork, not an accounting system). */
export async function setTokenBalance(side: Side, layout: BalanceLayout, holder: Address, amount: bigint): Promise<void> {
  const slot = mappingSlot(holder, BigInt(layout.mappingSlot));
  await anvil.setStorageAt(side, layout.token, slot, pad(toHex(amount)));
  const seen = await balanceOf(side, layout.token, holder);
  if (seen !== amount) throw new Error(`balance write of ${layout.token} for ${holder} did not stick (${seen})`);
}

export async function topUpToken(side: Side, layout: BalanceLayout, holder: Address, target: bigint): Promise<boolean> {
  if ((await balanceOf(side, layout.token, holder)) >= target) return false;
  await setTokenBalance(side, layout, holder, target);
  return true;
}

export async function topUpEth(side: Side, holder: Address, target: bigint): Promise<void> {
  const balance = await nodes[side].client.getBalance({ address: holder });
  if (balance < target) await anvil.setBalance(side, holder, target);
}

/** Wraps ETH into WETH until `actor` holds `target` WETH (backed, so unwrapping works). */
export async function topUpWeth(side: Side, weth: Address, actor: ActorName, target: bigint): Promise<boolean> {
  const holder = actors[actor].address;
  const balance = await balanceOf(side, weth, holder);
  if (balance >= target) return false;
  const missing = target - balance;
  await topUpEth(side, holder, missing + 10n ** 21n);
  await send(side, actor, { address: weth, abi: erc20Abi, functionName: "deposit", value: missing });
  return true;
}

export async function approveMax(side: Side, actor: ActorName, token: Address, spender: Address): Promise<void> {
  const allowance = await read<bigint>(side, {
    address: token,
    abi: erc20Abi,
    functionName: "allowance",
    args: [actors[actor].address, spender],
  });
  if (allowance >= maxUint256 / 2n) return;
  await send(side, actor, { address: token, abi: erc20Abi, functionName: "approve", args: [spender, maxUint256] });
}

const ETH = 10n ** 18n;
const USD = 10n ** 6n;

/** Target balances per actor (topped up, never lowered). */
export const TARGETS = {
  eth: 10_000n * ETH,
  traderEth: 30_000n * ETH,
  arbitrum: {
    usdc: { ana: 100_000n * USD, bruno: 100_000n * USD, manager: 10_000n * USD, stranger: 10_000n * USD, keeper: 1_000_000n * USD, trader: 50_000_000n * USD },
    weth: { trader: 10_000n * ETH },
  },
  robinhood: {
    usdg: { manager: 10_000n * USD, stranger: 10_000n * USD, keeper: 1_000_000n * USD, trader: 50_000_000n * USD },
    weth: { trader: 10_000n * ETH },
  },
} as const;

/** Finds the balance mappings of USDC (hub) and USDG (spoke) once, for this run and for the keeper. */
export async function discoverLayouts(): Promise<DeploymentState["storage"]["balances"]> {
  const probe = actors.keeper.address;
  return {
    arbitrum: [await discoverBalanceLayout("arbitrum", ARBITRUM.usdc, probe)],
    robinhood: [await discoverBalanceLayout("robinhood", ROBINHOOD.usdg, probe)],
  };
}

export function layoutOf(state: DeploymentState, side: Side, token: Address): BalanceLayout {
  const layout = state.storage.balances[side].find((l) => l.token.toLowerCase() === token.toLowerCase());
  if (!layout) throw new Error(`no balance layout for ${token} on ${side}`);
  return layout;
}

/** anvil's default keys are public, and on mainnet their accounts carry an EIP-7702 delegation (to a sweeper). On the
 *  forks the actors must be plain EOAs, so a delegation is cleared. */
export async function clearDelegation(side: Side, holder: Address): Promise<Hex | undefined> {
  const code = await nodes[side].client.getCode({ address: holder });
  if (!code || code === "0x") return undefined;
  await anvil.setCode(side, holder, "0x");
  return code;
}

export async function fundAccounts(state: DeploymentState, log: Logger): Promise<void> {
  for (const side of ["arbitrum", "robinhood"] as Side[]) {
    const cleared = new Map<string, Hex>();
    for (const [name, account] of Object.entries(actors) as [ActorName, (typeof actors)[ActorName]][]) {
      const delegation = await clearDelegation(side, account.address);
      if (delegation) cleared.set(name, delegation);
      await topUpEth(side, account.address, name === "trader" ? TARGETS.traderEth : TARGETS.eth);
    }
    if (cleared.size > 0) {
      log.info("cleared the EIP-7702 delegations anvil's public keys carry on mainnet", {
        chain: nodes[side].chain.id,
        actors: [...cleared.keys()].join(","),
        delegation: [...new Set(cleared.values())].join(","),
      });
    }
  }
  const usdc = layoutOf(state, "arbitrum", ARBITRUM.usdc);
  for (const [name, amount] of Object.entries(TARGETS.arbitrum.usdc) as [ActorName, bigint][]) {
    if (await topUpToken("arbitrum", usdc, actors[name].address, amount)) log.info(`USDC ${units(amount, 6, 0)} to ${name}`);
  }
  const usdg = layoutOf(state, "robinhood", ROBINHOOD.usdg);
  for (const [name, amount] of Object.entries(TARGETS.robinhood.usdg) as [ActorName, bigint][]) {
    if (await topUpToken("robinhood", usdg, actors[name].address, amount)) log.info(`USDG ${units(amount, 6, 0)} to ${name}`);
  }
  if (await topUpWeth("arbitrum", ARBITRUM.weth, "trader", TARGETS.arbitrum.weth.trader)) log.info("WETH 10,000 to trader (hub)");
  if (await topUpWeth("robinhood", ROBINHOOD.weth, "trader", TARGETS.robinhood.weth.trader)) log.info("WETH 10,000 to trader (spoke)");

  // The trader swaps through the harness's V4SwapRouter on each chain; the keeper fills Across deposits.
  await approveMax("arbitrum", "trader", ARBITRUM.usdc, state.helpers.arbitrumSwapRouter);
  await approveMax("arbitrum", "trader", ARBITRUM.weth, state.helpers.arbitrumSwapRouter);
  await approveMax("robinhood", "trader", ROBINHOOD.usdg, state.helpers.robinhoodSwapRouter);
  await approveMax("robinhood", "trader", ROBINHOOD.weth, state.helpers.robinhoodSwapRouter);
  await approveMax("arbitrum", "keeper", ARBITRUM.usdc, ARBITRUM.acrossSpokePool);
  await approveMax("robinhood", "keeper", ROBINHOOD.usdg, ROBINHOOD.acrossSpokePool);
  log.info("actors funded", { eth: units(TARGETS.eth, 18, 0), actors: Object.keys(actors).length });
}

if (isMain(import.meta.url)) {
  await runMain(() => fundAccounts(readState(), logger("funding")));
}
