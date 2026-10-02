// The Hub-to-spoke order of src/libraries/OrderCodec.sol (DEC-111, DEC-120, DEC-139): `abi.encode(uint256 version,
// Order)`, ten static words, published by the Core Vault on the Arbitrum Core at instant consistency and executed by
// any address on each Spoke Vault (`executeOrder`, checked by src/libraries/OrderVerifier.sol).
import { decodeAbiParameters, encodeAbiParameters, keccak256, type Hex } from "viem";

export const ORDER_VERSION = 1n;
export const ORDER_KIND = { UNWIND: 1, CLOSE: 2, COLLECT: 3 } as const;
export const ORDER_KIND_NAME: Record<number, string> = { 1: "UNWIND", 2: "CLOSE", 3: "COLLECT" };
/** DEC-120 item 1: orders travel at instant consistency; reports stay finalized (DEC-093). */
export const ORDER_CONSISTENCY = 200;
/** `OrderCodec.ORDER_LIFETIME`: a Spoke Vault refuses an order one hour after the Hub published it (OPEN). */
export const ORDER_LIFETIME = 3600n;

export interface Order {
  kind: number;
  fundId: Hex;
  requestId: Hex;
  attempt: number;
  deadline: bigint;
  fracNum: bigint;
  fracDen: bigint;
  maxLossBps: number;
  payoutMode: number;
}

const ORDER_TUPLE = {
  type: "tuple",
  components: [
    { name: "kind", type: "uint8" },
    { name: "fundId", type: "bytes32" },
    { name: "requestId", type: "bytes32" },
    { name: "attempt", type: "uint32" },
    { name: "deadline", type: "uint64" },
    { name: "fracNum", type: "uint256" },
    { name: "fracDen", type: "uint256" },
    { name: "maxLossBps", type: "uint16" },
    { name: "payoutMode", type: "uint8" },
  ],
} as const;

/** `OrderCodec.encode` without its checks (the publisher on the Hub runs them). */
export function encodeOrder(o: Order): Hex {
  return encodeAbiParameters([{ type: "uint256" }, ORDER_TUPLE], [ORDER_VERSION, o]);
}

/** The order a payload carries, or undefined when it is not a version-1 order. */
export function decodeOrder(payload: Hex): Order | undefined {
  try {
    const [version, o] = decodeAbiParameters([{ type: "uint256" }, ORDER_TUPLE], payload);
    return version === ORDER_VERSION ? { ...o } : undefined;
  } catch {
    return undefined;
  }
}

/** `OrderCodec.orderId`: one id per (kind, fund, request, attempt); a Spoke Vault executes an id once. */
export function orderId(o: Pick<Order, "kind" | "fundId" | "requestId" | "attempt">): Hex {
  return keccak256(
    encodeAbiParameters(
      [{ type: "uint8" }, { type: "bytes32" }, { type: "bytes32" }, { type: "uint32" }],
      [o.kind, o.fundId, o.requestId, o.attempt],
    ),
  );
}
