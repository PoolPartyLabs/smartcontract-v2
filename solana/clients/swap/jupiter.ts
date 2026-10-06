export class RateLimitedError extends Error {
  readonly retryInSeconds: number;
  constructor(milliseconds: number) {
    const seconds = Math.max(1, Math.ceil(milliseconds / 1000));
    super(`Jupiter rate limited, retry in ${seconds}s`);
    this.retryInSeconds = seconds;
  }
}

type Clock = { now: () => number; sleep: (milliseconds: number) => Promise<void>; random: () => number };
const realClock: Clock = { now: Date.now, sleep: milliseconds => new Promise(resolve => setTimeout(resolve, milliseconds)), random: Math.random };

export class TokenBucket {
  private tokens = 1;
  private updated: number;
  private blockedUntil = 0;
  private queue: Promise<void> = Promise.resolve();
  private intervalMs: number;
  private clock: Clock;
  constructor(intervalMs: number, clock: Clock = realClock) {
    this.intervalMs = intervalMs;
    this.clock = clock;
    if (!Number.isFinite(intervalMs) || intervalMs < 1000) throw new Error('MVP rate must not exceed Free 1 RPS');
    this.updated = clock.now();
  }
  block(milliseconds: number): void {
    this.blockedUntil = Math.max(this.blockedUntil, this.clock.now() + milliseconds);
  }
  take(): Promise<void> {
    const task = this.queue.then(async () => {
      const blocked = this.blockedUntil - this.clock.now();
      if (blocked > 0) await this.clock.sleep(blocked);
      this.tokens = Math.min(1, this.tokens + (this.clock.now() - this.updated) / this.intervalMs);
      const wait = (1 - this.tokens) * this.intervalMs;
      if (wait > 0) await this.clock.sleep(Math.ceil(wait));
      this.tokens = 0;
      this.updated = this.clock.now();
    });
    this.queue = task.catch(() => {});
    return task;
  }
}

export type Quote = {
  inputMint: string; outputMint: string; inAmount: string; outAmount: string;
  otherAmountThreshold: string; slippageBps: number; swapMode: string;
  routePlan: { swapInfo: { label: string; ammKey: string } }[];
};
export type ApiInstruction = { programId: string; accounts: { pubkey: string; isSigner: boolean; isWritable: boolean }[]; data: string };
export type SwapInstructions = {
  swapInstruction: ApiInstruction; addressLookupTableAddresses: string[];
  setupInstructions: ApiInstruction[]; cleanupInstruction?: ApiInstruction | null;
  otherInstructions?: ApiInstruction[];
};

export class JupiterClient {
  private bucket: TokenBucket;
  private cache = new Map<string, { expires: number; quote: Quote }>();
  private apiKey?: string;
  private transport: typeof fetch;
  private clock: Clock;
  constructor(
    apiKey?: string,
    transport: typeof fetch = fetch,
    clock: Clock = realClock,
  ) {
    this.apiKey = apiKey;
    this.transport = transport;
    this.clock = clock;
    this.bucket = new TokenBucket(apiKey ? 1100 : 2100, clock);
  }

  private async request(path: string, init?: RequestInit): Promise<any> {
    for (let attempt = 0; attempt < 3; attempt++) {
      await this.bucket.take();
      let response: Response;
      try {
        response = await this.transport(`https://api.jup.ag/swap/v1/${path}`, {
          ...init, signal: AbortSignal.timeout(15_000),
          headers: { 'content-type': 'application/json', ...(this.apiKey ? { 'x-api-key': this.apiKey } : {}) },
        });
      } catch { throw new Error('Jupiter request failed; retry manually'); }
      const reset = response.headers.get('x-ratelimit-reset');
      const resetDelay = reset ? Math.max(0, Number(reset) * 1000 - this.clock.now()) : 0;
      const retryAfter = response.headers.get('retry-after');
      const retryDelay = retryAfter ? (/^\d+(\.\d+)?$/.test(retryAfter)
        ? Number(retryAfter) * 1000 : Math.max(0, Date.parse(retryAfter) - this.clock.now())) : 0;
      if (response.status === 429) {
        const delay = Math.max(2100 * 2 ** attempt, Number.isFinite(resetDelay) ? resetDelay : 0,
          Number.isFinite(retryDelay) ? retryDelay : 0) + Math.floor(this.clock.random() * 500);
        this.bucket.block(delay);
        if (attempt === 2 || delay > 10_000) throw new RateLimitedError(delay);
        continue;
      }
      const remaining = response.headers.get('x-ratelimit-remaining');
      if (remaining !== null && Number(remaining) <= 0 && Number.isFinite(resetDelay)) this.bucket.block(resetDelay);
      if (!response.ok) throw new Error(`Jupiter returned HTTP ${response.status}; refresh route manually`);
      return response.json();
    }
    throw new RateLimitedError(2100);
  }

  async quote(inputMint: string, outputMint: string, amount: bigint, slippageBps: number, maxAccounts = 32): Promise<Quote> {
    if (amount <= 0n || amount >= 1n << 64n || !Number.isInteger(slippageBps) || slippageBps < 0 || slippageBps >= 10_000
        || !Number.isInteger(maxAccounts) || maxAccounts < 8 || maxAccounts > 48) throw new Error('Invalid bounded quote request');
    const params = new URLSearchParams({ inputMint, outputMint, amount: amount.toString(), slippageBps: String(slippageBps),
      maxAccounts: String(maxAccounts), dexes: 'Raydium CLMM', onlyDirectRoutes: 'true', instructionVersion: 'V1' });
    const key = params.toString();
    const cached = this.cache.get(key);
    if (cached && cached.expires > this.clock.now()) return structuredClone(cached.quote);
    const result = await this.request(`quote?${key}`) as Quote;
    if (result.inputMint !== inputMint || result.outputMint !== outputMint || result.inAmount !== amount.toString()
        || result.slippageBps !== slippageBps || result.swapMode !== 'ExactIn'
        || result.routePlan?.length !== 1 || result.routePlan[0].swapInfo.label !== 'Raydium CLMM'
        || !/^\d+$/.test(result.outAmount) || !/^\d+$/.test(result.otherAmountThreshold)
        || BigInt(result.outAmount) <= 0n || BigInt(result.otherAmountThreshold) <= 0n) throw new Error('Unsupported Jupiter quote');
    if (this.cache.size >= 128) this.cache.delete(this.cache.keys().next().value!);
    this.cache.set(key, { expires: this.clock.now() + 2500, quote: structuredClone(result) });
    return result;
  }

  async instructions(quote: Quote, vault: string, outputAta: string): Promise<SwapInstructions> {
    return this.request('swap-instructions', { method: 'POST', body: JSON.stringify({
      quoteResponse: quote, userPublicKey: vault, destinationTokenAccount: outputAta,
      wrapAndUnwrapSol: false, useSharedAccounts: false, skipUserAccountsRpcCalls: true,
      instructionVersion: 'V1',
    }) });
  }
}
