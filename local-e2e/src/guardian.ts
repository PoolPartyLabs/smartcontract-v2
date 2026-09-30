// The local Wormhole guardian: replaces the guardian set of the Arbitrum Core Bridge on the hub node with one key the
// harness holds (the storage writes of lib/wormhole-solidity-sdk/src/testing/WormholeOverride.sol), and turns a
// message published on Robinhood into a VAA that guardian signs, which the real Arbitrum Core verifies.
//
// Standalone: `pnpm exec tsx src/guardian.ts` applies the override (idempotent) and verifies a signed test VAA.
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
import { anvil, latestTimestamp, read, type Side } from "./chain.ts";
import { ARBITRUM, GUARDIAN_PRIVATE_KEY, WORMHOLE_ROBINHOOD, guardian, isMain } from "./config.ts";
import { logger, type Logger } from "./log.ts";

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

/** Makes the local guardian the whole current guardian set of `core` on `side` (quorum 1 of 1), as a guardian set
 *  transition would: the current set expires in a day, the index moves to a new set holding only the local key.
 *  Idempotent: a Core already governed by the local guardian is left as is. Returns the guardian set index. */
export async function overrideGuardianSet(
  log: Logger,
  side: Side = "arbitrum",
  core: Address = ARBITRUM.wormholeCore,
): Promise<number> {
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
  log.info("guardian set replaced", { core, previous: `${current} (${set.keys.length} guardians)`, index: next, guardian: guardian.address });
  return next;
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
export async function verifyVaa(vaa: Hex, side: Side = "arbitrum", core: Address = ARBITRUM.wormholeCore) {
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

/** Signs a throwaway message with the local guardian and requires the hub Core to accept it. */
export async function selfTest(guardianSetIndex: number, log: Logger): Promise<void> {
  const vaa = await signVaa(
    {
      timestamp: Number(await latestTimestamp("arbitrum")),
      nonce: 0,
      emitterChainId: WORMHOLE_ROBINHOOD,
      emitterAddress: universal(guardian.address),
      sequence: 0n,
      consistencyLevel: 1,
      payload: numberToHex(42, { size: 32 }),
    },
    guardianSetIndex,
  );
  const { valid, reason } = await verifyVaa(vaa);
  if (!valid) throw new Error(`the hub Core rejects a VAA signed by the local guardian: ${reason}`);
  log.info("parseAndVerifyVM accepts VAAs signed by the local guardian", { guardianSetIndex });
}

if (isMain(import.meta.url)) {
  const log = logger("guardian");
  const index = await overrideGuardianSet(log);
  await selfTest(index, log);
}
