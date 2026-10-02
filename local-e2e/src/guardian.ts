// The local Wormhole guardian: replaces the guardian set of the Core Bridge on BOTH nodes with one key the harness
// holds (the storage writes of lib/wormhole-solidity-sdk/src/testing/WormholeOverride.sol), and turns a published
// message into a VAA that guardian signs: a spoke report published on Robinhood is verified by the real Arbitrum Core
// (DEC-086), and a Hub order published by the Core Vault on Arbitrum is verified by the real Robinhood Core (DEC-120,
// DEC-139).
//
// Standalone: `pnpm exec tsx src/guardian.ts` applies both overrides (idempotent) and verifies a signed test VAA in
// each direction.
import {
  concat,
  encodeAbiParameters,
  encodePacked,
  hexToBigInt,
  keccak256,
  numberToHex,
  pad,
  toHex,
  type Address,
  type Hex,
} from "viem";
import { sign } from "viem/accounts";
import { wormholeCoreAbi } from "./abis.ts";
import { SIDES, anvil, latestTimestamp, read, runMain, type Side } from "./chain.ts";
import { ARBITRUM, GUARDIAN_PRIVATE_KEY, ROBINHOOD, WORMHOLE_ARBITRUM, WORMHOLE_ROBINHOOD, guardian, isMain } from "./config.ts";
import { logger, type Logger } from "./log.ts";

/** The live Wormhole Core Bridge of each node. */
export const CORES: Record<Side, Address> = { arbitrum: ARBITRUM.wormholeCore, robinhood: ROBINHOOD.wormholeCore };

/** Each node's Wormhole chain id: Arbitrum 23 (the Hub, emitter of orders), Robinhood 72 (emitter of reports). */
export const WORMHOLE_CHAIN: Record<Side, number> = { arbitrum: WORMHOLE_ARBITRUM, robinhood: WORMHOLE_ROBINHOOD };

// Core Bridge storage (WormholeOverride's table, from wormhole/ethereum/contracts/State.sol):
//   slot 2: mapping(uint32 => GuardianSet) guardianSets   (GuardianSet { address[] keys; uint32 expirationTime; })
//   slot 3: uint32 guardianSetIndex (packed with the unused uint32 guardianSetExpiry)
//   slot 4: mapping(address => uint64) sequences
const GUARDIAN_SETS_SLOT = 2n;
const GUARDIAN_SET_INDEX_SLOT = 3n;
export const WORMHOLE_SEQUENCES_SLOT = 4n;

function guardianSetSlot(index: number): bigint {
  return hexToBigInt(keccak256(encodeAbiParameters([{ type: "uint32" }, { type: "uint256" }], [index, GUARDIAN_SETS_SLOT])));
}

function arraySlot(slot: bigint): bigint {
  return hexToBigInt(keccak256(encodeAbiParameters([{ type: "uint256" }], [slot])));
}

const word = (value: bigint) => pad(toHex(value));

/** The current guardian set index of the Core on `side`. */
export function guardianSetIndexOf(side: Side): Promise<number> {
  return read<number>(side, { address: CORES[side], abi: wormholeCoreAbi, functionName: "getCurrentGuardianSetIndex" });
}

/** Makes the local guardian the whole current guardian set of `core` on `side` (quorum 1 of 1), as a guardian set
 *  transition would: the current set expires in a day, the index moves to a new set holding only the local key.
 *  Idempotent: a Core already governed by the local guardian is left as is. Returns the guardian set index. */
export async function overrideGuardianSet(log: Logger, side: Side, core: Address = CORES[side]): Promise<number> {
  const current = await read<number>(side, { address: core, abi: wormholeCoreAbi, functionName: "getCurrentGuardianSetIndex" });
  const set = await read<{ keys: readonly Address[] }>(side, {
    address: core,
    abi: wormholeCoreAbi,
    functionName: "getGuardianSet",
    args: [current],
  });
  if (set.keys.length === 1 && set.keys[0].toLowerCase() === guardian.address.toLowerCase()) {
    log.info("guardian set already local", { index: current, guardian: guardian.address });
    return current;
  }
  const now = await latestTimestamp(side);
  const next = current + 1;
  const currentSlot = guardianSetSlot(current);
  const nextSlot = guardianSetSlot(next);
  await anvil.setStorageAt(side, core, word(currentSlot + 1n), word(now + 86_400n)); // expire the live set
  await anvil.setStorageAt(side, core, word(GUARDIAN_SET_INDEX_SLOT), word(BigInt(next)));
  await anvil.setStorageAt(side, core, word(nextSlot), word(1n)); // keys.length
  await anvil.setStorageAt(side, core, word(arraySlot(nextSlot)), word(hexToBigInt(guardian.address)));
  const index = await read<number>(side, { address: core, abi: wormholeCoreAbi, functionName: "getCurrentGuardianSetIndex" });
  if (index !== next) throw new Error(`guardian set index is ${index}, expected ${next}`);
  log.info("guardian set replaced", { side, core, previous: `${current} (${set.keys.length} guardians)`, index: next, guardian: guardian.address });
  return next;
}

/** The local guardian on both Cores: Arbitrum verifies spoke reports, Robinhood verifies Hub orders. */
export async function overrideBothCores(log: Logger): Promise<Record<Side, number>> {
  return { arbitrum: await overrideGuardianSet(log, "arbitrum"), robinhood: await overrideGuardianSet(log, "robinhood") };
}

/** A message as `LogMessagePublished` carries it, plus the emitter chain and the block timestamp guardians attest. */
export interface PublishedMessage {
  timestamp: number;
  nonce: number;
  emitterChainId: number;
  emitterAddress: Hex; // universal (bytes32) address
  sequence: bigint;
  consistencyLevel: number;
  payload: Hex;
}

/** VAA v1 body: timestamp, nonce, emitter chain, emitter, sequence, consistency level, payload (no length prefix). */
export function vaaBody(m: PublishedMessage): Hex {
  return encodePacked(
    ["uint32", "uint32", "uint16", "bytes32", "uint64", "uint8", "bytes"],
    [m.timestamp, m.nonce, m.emitterChainId, m.emitterAddress, m.sequence, m.consistencyLevel, m.payload],
  );
}

/** Encodes and signs a VAA v1 with the local guardian: signature over keccak256(keccak256(body)) (the EVM Core's
 *  double hash), raw secp256k1 without a message prefix, recovery id 0/1, one signature at guardian index 0. */
export async function signVaa(m: PublishedMessage, guardianSetIndex: number): Promise<Hex> {
  const body = vaaBody(m);
  const hash = keccak256(keccak256(body));
  const signature = await sign({ hash, privateKey: GUARDIAN_PRIVATE_KEY });
  const recoveryId = signature.yParity ?? Number(signature.v! - 27n);
  const header = encodePacked(
    ["uint8", "uint32", "uint8", "uint8", "bytes32", "bytes32", "uint8"],
    [1, guardianSetIndex, 1, 0, signature.r, signature.s, recoveryId],
  );
  return concat([header, body]);
}

/** `parseAndVerifyVM` on the node's real Core Bridge. */
export async function verifyVaa(vaa: Hex, side: Side, core: Address = CORES[side]) {
  const [vm, valid, reason] = await read<readonly [{ sequence: bigint; emitterChainId: number }, boolean, string]>(side, {
    address: core,
    abi: wormholeCoreAbi,
    functionName: "parseAndVerifyVM",
    args: [vaa],
  });
  return { vm, valid, reason };
}

/** The universal (bytes32) form of an EVM address. */
export const universal = (address: Address): Hex => pad(address.toLowerCase() as Hex);

/** Signs a throwaway message in each direction with the local guardian and requires the receiving Core to accept it:
 *  a Robinhood-emitted message on Arbitrum (the report path) and an Arbitrum-emitted one on Robinhood (the order
 *  path, with the orders' instant consistency). */
export async function selfTest(indexes: Record<Side, number>, log: Logger): Promise<void> {
  for (const side of SIDES) {
    const from: Side = side === "arbitrum" ? "robinhood" : "arbitrum";
    const vaa = await signVaa(
      {
        timestamp: Number(await latestTimestamp(from)),
        nonce: 0,
        emitterChainId: WORMHOLE_CHAIN[from],
        emitterAddress: universal(guardian.address),
        sequence: 0n,
        consistencyLevel: from === "arbitrum" ? 200 : 1,
        payload: numberToHex(42, { size: 32 }),
      },
      indexes[side],
    );
    const { valid, reason } = await verifyVaa(vaa, side);
    if (!valid) throw new Error(`the ${side} Core rejects a VAA signed by the local guardian: ${reason}`);
    log.info("parseAndVerifyVM accepts VAAs signed by the local guardian", { side, emitterChain: WORMHOLE_CHAIN[from], guardianSetIndex: indexes[side] });
  }
}

if (isMain(import.meta.url)) {
  await runMain(async () => {
    const log = logger("guardian");
    await selfTest(await overrideBothCores(log), log);
  });
}
