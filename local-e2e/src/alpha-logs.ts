export function alphaLogRange(value = "1000"): bigint {
  const range = Number(value);
  if (!Number.isSafeInteger(range) || range < 1) throw new Error("ALPHA_LOG_RANGE must be a positive safe integer");
  return BigInt(range);
}

export function logWindow(fromBlock: bigint, head: bigint, range: bigint) {
  if (range < 1n) throw new Error("Log range must be positive");
  if (fromBlock > head) return undefined;
  const end = fromBlock + range - 1n;
  return {fromBlock, toBlock: end < head ? end : head};
}

export interface AlphaCredits {
  credited: string;
  credits: Record<string, string>;
}

export function initializeAlphaCredits<Cursor extends object>(cursor: Cursor, startBlock: string): asserts cursor is Cursor & AlphaCredits {
  const state = cursor as Cursor & Partial<AlphaCredits>;
  state.credited ??= startBlock;
  state.credits ??= {};
}

export function recordAlphaCredits(cursor: AlphaCredits, events: readonly {
  args: {transitId?: string; originChainId?: bigint; matched?: boolean; amount?: bigint};
}[]) {
  for (const {args} of events) {
    if (args.originChainId !== 4663n || !args.matched || !args.transitId || args.amount === undefined) continue;
    const transitId = args.transitId.toLowerCase();
    cursor.credits[transitId] = (BigInt(cursor.credits[transitId] ?? "0") + args.amount).toString();
  }
}

export async function scanAlphaLogs<Side extends string>(dependencies: {
  sides: readonly Side[];
  cursor: Record<Side, string>;
  head: (side: Side) => Promise<bigint>;
  scan: (side: Side, window: {fromBlock: bigint; toBlock: bigint}) => Promise<void>;
  save: () => void;
  range: bigint;
  deadline: number;
  now?: () => number;
}) {
  const now = dependencies.now ?? Date.now;
  const heads = new Map<Side, bigint>();
  for (const side of dependencies.sides) heads.set(side, await dependencies.head(side));
  let progressed = true;
  while (progressed && now() < dependencies.deadline) {
    progressed = false;
    for (const side of dependencies.sides) {
      if (now() >= dependencies.deadline) break;
      const window = logWindow(BigInt(dependencies.cursor[side]), heads.get(side)!, dependencies.range);
      if (!window) continue;
      await dependencies.scan(side, window);
      dependencies.cursor[side] = (window.toBlock + 1n).toString();
      dependencies.save();
      progressed = true;
    }
  }
}
