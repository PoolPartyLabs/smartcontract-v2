import {type Hex} from "viem";

export interface AlphaWork {
  transitId: Hex;
  kind: number;
  expected: string;
  attempts: number;
  retryAt: number;
  acknowledged?: boolean;
  acknowledgedAt?: number;
}

export function transitResolved(state: number): boolean {
  return state === 2 || state === 4;
}

export function createAlphaTransitResolver(dependencies: {
  state: (work: AlphaWork) => Promise<number>;
  credited: (work: AlphaWork) => Promise<bigint>;
  acknowledge: (work: AlphaWork) => Promise<void>;
  save: () => void;
  now?: () => number;
}) {
  const now = dependencies.now ?? Date.now;
  return async (work: AlphaWork): Promise<boolean> => {
    if (transitResolved(await dependencies.state(work))) return true;
    if (await dependencies.credited(work) < BigInt(work.expected)) return false;
    if (!work.acknowledged || now() - (work.acknowledgedAt ?? 0) >= 60000) {
      await dependencies.acknowledge(work);
      work.acknowledged = true;
      work.acknowledgedAt = now();
      dependencies.save();
    }
    return false;
  };
}

export async function drainAlphaWork(
  cursor: {work: AlphaWork[]},
  resolve: (work: AlphaWork) => Promise<boolean>,
  save: () => void,
  now = Date.now(),
) {
  for (const work of [...cursor.work]) {
    if (work.retryAt > now) continue;
    let completed = false;
    try {completed = await resolve(work);} catch {}
    if (completed) cursor.work = cursor.work.filter((entry) => entry !== work);
    else {
      work.attempts++;
      work.retryAt = now + Math.min(60000, 1000 * 2 ** Math.min(work.attempts, 6));
    }
    save();
  }
}

export function collectAllowed(value: bigint, minimum: bigint, quotedArrival: bigint): boolean {
  return minimum > 0n && value >= minimum && quotedArrival > 0n;
}
