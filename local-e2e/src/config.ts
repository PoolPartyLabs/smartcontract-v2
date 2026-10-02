// Chains, protocol addresses, ports and named actors of the local-e2e harness.
// Addresses are the verified values of docs/INTEGRATIONS.md and script/FactoryDeployment.sol.
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { defineChain, type Address, type Hex } from "viem";
import { privateKeyToAccount, type PrivateKeyAccount } from "viem/accounts";

export const HARNESS_DIR = resolve(dirname(fileURLToPath(import.meta.url)), "..");
export const REPO_DIR = resolve(HARNESS_DIR, "..");
export const STATE_DIR = join(HARNESS_DIR, ".state");
export const DEPLOYMENT_FILE = join(STATE_DIR, "deployment.json");
export const KEEPER_PID_FILE = join(STATE_DIR, "keeper.pid");
export const ABI_DIR = join(HARNESS_DIR, "abis");

// ---------------------------------------------------------------------------------------------------------------------
// Chains
// ---------------------------------------------------------------------------------------------------------------------

export const ARBITRUM_CHAIN_ID = 42161;
export const ROBINHOOD_CHAIN_ID = 4663;
export const WORMHOLE_ARBITRUM = 23;
export const WORMHOLE_ROBINHOOD = 72;

export const ARBITRUM_PORT = Number(process.env.LOCAL_E2E_ARBITRUM_PORT ?? 8545);
export const ROBINHOOD_PORT = Number(process.env.LOCAL_E2E_ROBINHOOD_PORT ?? 8546);
export const ARBITRUM_RPC = `http://127.0.0.1:${ARBITRUM_PORT}`;
export const ROBINHOOD_RPC = `http://127.0.0.1:${ROBINHOOD_PORT}`;

export const arbitrumFork = defineChain({
  id: ARBITRUM_CHAIN_ID,
  name: "Arbitrum One (local fork)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [ARBITRUM_RPC] } },
});

export const robinhoodFork = defineChain({
  id: ROBINHOOD_CHAIN_ID,
  name: "Robinhood Chain (local fork)",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [ROBINHOOD_RPC] } },
});

// ---------------------------------------------------------------------------------------------------------------------
// Protocol addresses (docs/INTEGRATIONS.md)
// ---------------------------------------------------------------------------------------------------------------------

/** Arbitrum One (Hub Chain). */
export const ARBITRUM = {
  usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
  weth: "0x82aF49447D8a07e3bd95BD0d56f35241523fBab1",
  acrossSpokePool: "0xe35e9842fceaCA96570B734083f4a58e8F7C5f2A",
  wormholeCore: "0xa5f208e072434bC67592E4C49C1B991BA79BCA46",
  v4PoolManager: "0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32",
  v4PositionManager: "0xd88F38F930b7952f2DB2432Cb002E7abbF3dD869",
  v4StateView: "0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990",
  aaveV3Pool: "0x794a61358D6845594F94dc1DB02A252b5b4814aD",
  aaveV3AddressesProvider: "0xa97684ead0e402dC232d5A977953DF7ECBaB3CDb",
  aUsdc: "0x724dc807b04555b71ed48a6896b6F41593b8C637",
  ethUsdFeed: "0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  deterministicDeployer: "0x4e59b44847b379578588920cA78FbF26c0B4956C",
} as const satisfies Record<string, Address>;

/** Robinhood Chain (Spoke Chain). */
export const ROBINHOOD = {
  usdg: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168",
  weth: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73",
  acrossSpokePool: "0xD29C85F15DF544bA632C9E25829fd29d767d7978",
  wormholeCore: "0x141fBa8AD5D61bdaB45A047cF60b5Ad9784987FB",
  v4PoolManager: "0x8366a39CC670B4001A1121B8F6A443A643e40951",
  v4PositionManager: "0x58daec3116aae6D93017bAAea7749052E8a04fA7",
  v4StateView: "0xF3334192D15450CdD385c8B70e03f9A6bD9E673b",
  permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  deterministicDeployer: "0x4e59b44847b379578588920cA78FbF26c0B4956C",
} as const satisfies Record<string, Address>;

/** Uniswap V4 PoolKey as the contracts encode it. */
export interface PoolKey {
  currency0: Address;
  currency1: Address;
  fee: number;
  tickSpacing: number;
  hooks: Address;
}

const NO_HOOKS: Address = "0x0000000000000000000000000000000000000000";

/** Hub WETH/USDC 0.05% (tick spacing 10, hookless): WETH sorts below USDC, so it is currency0. */
export const HUB_POOL_KEY: PoolKey = {
  currency0: ARBITRUM.weth,
  currency1: ARBITRUM.usdc,
  fee: 500,
  tickSpacing: 10,
  hooks: NO_HOOKS,
};
export const HUB_POOL_ID: Hex = "0xfc7b3ad139daaf1e9c3637ed921c154d1b04286f8a82b805a6c352da57028653";

/** Spoke WETH/USDG 0.05% (tick spacing 10, hookless): WETH is currency0. */
export const SPOKE_POOL_KEY: PoolKey = {
  currency0: ROBINHOOD.weth,
  currency1: ROBINHOOD.usdg,
  fee: 500,
  tickSpacing: 10,
  hooks: NO_HOOKS,
};
export const SPOKE_POOL_ID: Hex = "0xfcfae8fa0bd6da961bcf5d990f27690932deac4f093e99bf3e871691c6586593";

/** The Aave V3 "pool key" of the Mandate: the reserve asset as bytes32. */
export const AAVE_USDC_POOL_KEY: Hex = `0x${ARBITRUM.usdc.slice(2).toLowerCase().padStart(64, "0")}`;

// ---------------------------------------------------------------------------------------------------------------------
// Actors: anvil's default mnemonic ("test test test test test test test test test test test junk")
// ---------------------------------------------------------------------------------------------------------------------

/** Keys of anvil's default accounts 0..7. Public test keys: never use them on a real network. */
export const ACTOR_KEYS = {
  /** Account 0: the protocol operator, deploys the factories (same key and salt on both chains, docs/DEPLOYMENT.md);
   *  also the adapter guardian and the ManagerRegistry owner. */
  operator: "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
  /** Account 1: the fund Manager (DEC-001: the creator is the Manager). */
  manager: "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
  /** Account 2: Shareholder Ana. */
  ana: "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a",
  /** Account 3: Shareholder Bruno. */
  bruno: "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6",
  /** Account 4: the keeper; also the Across relayer that fills deposits on both nodes. */
  keeper: "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a",
  /** Account 5: a stranger (permissionless calls, donations). */
  stranger: "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba",
  /** Account 6: the Protocol Recipient (flow fee, protocol slice, swept excess; DEC-106). */
  protocolRecipient: "0x92db14e403b83dfe3df233f83dfa3a0d7096f21ca9b0d6d6b8d88b2b4ec1564e",
  /** Account 7: a third-party trader who swaps in the Uniswap V4 pools to generate fees. */
  trader: "0x4bbbf85ce3377467afe5d46f804f221813b2bb87f24d81f60f1fcdbf7cbf4356",
} as const satisfies Record<string, Hex>;

export type ActorName = keyof typeof ACTOR_KEYS;
export const ACTOR_NAMES = Object.keys(ACTOR_KEYS) as ActorName[];

export const actors: Record<ActorName, PrivateKeyAccount> = Object.fromEntries(
  ACTOR_NAMES.map((name) => [name, privateKeyToAccount(ACTOR_KEYS[name])]),
) as Record<ActorName, PrivateKeyAccount>;

/** The single local Wormhole guardian that replaces the Arbitrum Core's guardian set on the hub node: the Wormhole
 *  SDK's devnet guardian key (lib/wormhole-solidity-sdk/src/testing/Constants.sol), address
 *  0xbeFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe. */
export const GUARDIAN_PRIVATE_KEY: Hex = "0xcfb12303a19cde580bb4dd771639b0d26bc68353645571a8cff516ab2ee113a0";
export const guardian = privateKeyToAccount(GUARDIAN_PRIVATE_KEY);

// ---------------------------------------------------------------------------------------------------------------------
// Fund plan defaults (script/CreateFund.s.sol reads these from the environment)
// ---------------------------------------------------------------------------------------------------------------------

/** Mandate rule values passed to script/CreateFund.s.sol, overridable through the same environment variables. The
 *  defaults are the end-to-end fork scenario's (test/fork/e2e/EndToEndBase.sol): a Spoke Cap of 40% of Ana's first
 *  deposit and the manager's seed at the Mandate minimum. `MAX_BRIDGE_FEE_BPS` is a dead Mandate field since the
 *  Across adapter fixes every send (DEC-156, DEC-162) until Mandate v2 removes it. */
export const FUND_PLAN = {
  SPOKE_CAP: process.env.SPOKE_CAP ?? "4000000000", // 4,000 USDC (DEC-037, DEC-095)
  MIN_FIRST_DEPOSIT: process.env.MIN_FIRST_DEPOSIT ?? "100000000", // 100 USDC (DEC-061)
  // DEC-127: the manager's seed at creation, in USDC base units; the script approves the factory for it.
  SEED_AMOUNT: process.env.SEED_AMOUNT ?? process.env.MIN_FIRST_DEPOSIT ?? "100000000",
  PERFORMANCE_FEE_BPS: process.env.PERFORMANCE_FEE_BPS ?? "2000", // 20% (DEC-107)
  MAX_BRIDGE_FEE_BPS: process.env.MAX_BRIDGE_FEE_BPS ?? "4", // dead field (DEC-156, DEC-162)
} as const;

/** Whether the module at `url` (`import.meta.url`) is the script node was started with. */
export function isMain(url: string): boolean {
  return process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(url);
}
