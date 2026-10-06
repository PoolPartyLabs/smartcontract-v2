import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync, readdirSync, unlinkSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { Keypair } from '@solana/web3.js';
import { ADDRESSES, derive, publicKey } from '../tests/helpers/addresses.ts';
import { decodePool, decodeReserve, discriminator, readKey } from '../tests/helpers/layouts.ts';
import { testAta } from '../tests/helpers/localnet.ts';

const root = fileURLToPath(new URL('../.localnet/', import.meta.url));
const endpoint = process.env.SOLANA_MAINNET_RPC ?? 'https://api.mainnet-beta.solana.com';
const approvedMethods = new Set(['getAccountInfo', 'getSlot']);
const requestDelay = Number(process.env.SOLANA_CLONE_DELAY_MS ?? 350);
type RpcAccount = { data: [string, string]; executable: boolean; lamports: number; owner: string; rentEpoch: number; space?: number };
type Snapshot = { pubkey: string; account: RpcAccount };
const snapshots = new Map<string, Snapshot>();
const missing: string[] = [];
const slots: number[] = [];

async function rpc(method: string, params: unknown[]): Promise<any> {
  if (!approvedMethods.has(method)) throw new Error('Clone RPC is strictly read-only');
  for (let attempt = 0; attempt < 5; attempt++) {
    try {
      await new Promise(resolve => setTimeout(resolve, requestDelay * 2 ** attempt));
      const response = await fetch(endpoint, {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: 1, method, params }),
        signal: AbortSignal.timeout(30_000),
      });
      if (!response.ok) throw new Error(`HTTP ${response.status}`);
      const body = await response.json() as { error?: { code: number }; result: any };
      if (body.error) throw new Error(`RPC code ${body.error.code}`);
      return body.result;
    } catch {
      if (attempt === 4) throw new Error(`Read-only mainnet ${method} failed after five attempts; endpoint suppressed`);
    }
  }
}

async function clone(address: string, required = true): Promise<Buffer | null> {
  const cached = snapshots.get(address);
  if (cached) return Buffer.from(cached.account.data[0], 'base64');
  const result = await rpc('getAccountInfo', [address, { encoding: 'base64', commitment: 'finalized' }]);
  if (!result.value) {
    if (required) throw new Error(`Required clone account is absent: ${address}`);
    missing.push(address);
    return null;
  }
  slots.push(result.context.slot);
  const snapshot = { pubkey: address, account: { ...result.value, rentEpoch: 0 } as RpcAccount };
  if (!Number.isSafeInteger(snapshot.account.lamports)) throw new Error(`Unsafe lamport integer in account: ${address}`);
  snapshots.set(address, snapshot);
  const data = Buffer.from(snapshot.account.data[0], 'base64');
  if (snapshot.account.executable && snapshot.account.owner === ADDRESSES.loader) {
    if (data.length !== 36 || data.readUInt32LE(0) !== 2) throw new Error('Unexpected upgradeable program header');
    await clone(readKey(data, 4));
  }
  return data;
}

async function owned(address: string, owner: string): Promise<Buffer> {
  const data = await clone(address);
  if (snapshots.get(address)?.account.owner !== owner) throw new Error(`Unexpected clone owner: ${address}`);
  return data!;
}

function wallet(role: string): Keypair {
  const path = `${root}/${role}.json`;
  if (existsSync(path)) return Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path, 'utf8'))));
  const keypair = Keypair.generate();
  writeFileSync(path, JSON.stringify(Array.from(keypair.secretKey)), { mode: 0o600 });
  return keypair;
}

function fixtureWallet(keypair: Keypair, templates: Map<string, Snapshot>) {
  const native = { pubkey: keypair.publicKey.toBase58(), account: {
    data: ['', 'base64'] as [string, string], executable: false,
    lamports: 100_000_000_000, owner: '11111111111111111111111111111111', rentEpoch: 0,
  } };
  writeFileSync(`${root}/overrides/${native.pubkey}.json`, JSON.stringify(native));
  for (const [mint, template] of templates) {
    const data = Buffer.from(template.account.data[0], 'base64');
    if (data.length < 165) throw new Error('Unexpected token account template');
    publicKey(mint).toBuffer().copy(data, 0);
    keypair.publicKey.toBuffer().copy(data, 32);
    data.writeBigUInt64LE(mint === ADDRESSES.tslax ? 1000n * 100_000_000n : 100_000n * 1_000_000n, 64);
    data.fill(0, 72, 108);
    data[108] = 1;
    data.fill(0, 109, 165);
    const snapshot = { pubkey: testAta(mint, keypair.publicKey).toBase58(), account: {
      ...template.account, data: [data.toString('base64'), 'base64'], rentEpoch: 0,
      lamports: Math.max(template.account.lamports, 10_000_000),
    } };
    writeFileSync(`${root}/overrides/${snapshot.pubkey}.json`, JSON.stringify(snapshot));
  }
}

async function main() {
  mkdirSync(`${root}/accounts`, { recursive: true, mode: 0o700 });
  mkdirSync(`${root}/overrides`, { recursive: true, mode: 0o700 });
  const manager = wallet('manager');
  const keeper = wallet('keeper');
  for (const program of [ADDRESSES.raydium, ADDRESSES.kamino, ADDRESSES.cctpTransmitter,
    ADDRESSES.cctpMessenger, ADDRESSES.wormhole, ADDRESSES.token, ADDRESSES.token2022, ADDRESSES.ata]) {
    await clone(program);
    if (!snapshots.get(program)?.account.executable) throw new Error(`Program is not executable: ${program}`);
  }
  await owned(ADDRESSES.usdc, ADDRESSES.token);
  await owned(ADDRESSES.tslax, ADDRESSES.token2022);
  await owned(ADDRESSES.wsol, ADDRESSES.token);
  const pools = [];
  const templates = new Map<string, Snapshot>();
  for (const address of [ADDRESSES.tslaxPool, ADDRESSES.solPool]) {
    const pool = decodePool(await owned(address, ADDRESSES.raydium));
    const expected = address === ADDRESSES.tslaxPool ? ADDRESSES.tslax : ADDRESSES.wsol;
    if (![pool.mint0, pool.mint1].includes(expected) || ![pool.mint0, pool.mint1].includes(ADDRESSES.usdc)) {
      throw new Error('Selected pool has unexpected mints');
    }
    await owned(pool.config, ADDRESSES.raydium);
    await owned(pool.observation, ADDRESSES.raydium);
    for (const [mint, vault] of [[pool.mint0, pool.vault0], [pool.mint1, pool.vault1]]) {
      const token = mint === ADDRESSES.tslax ? ADDRESSES.token2022 : ADDRESSES.token;
      const data = await owned(vault, token);
      if (readKey(data, 0) !== mint || readKey(data, 32) !== address) throw new Error('Invalid pool token vault relation');
      if (mint !== ADDRESSES.wsol) templates.set(mint, snapshots.get(vault)!);
    }
    const bitmap = derive(ADDRESSES.raydium, Buffer.from('pool_tick_array_bitmap_extension'), publicKey(address).toBuffer());
    await clone(bitmap, false);
    const span = pool.tickSpacing * 60;
    const start = Math.floor(pool.tickCurrent / span) * span;
    const arrays: string[] = [];
    for (let distance = -3; distance <= 3; distance++) {
      const tick = Buffer.alloc(4);
      tick.writeInt32BE(start + distance * span);
      const array = derive(ADDRESSES.raydium, Buffer.from('tick_array'), publicKey(address).toBuffer(), tick);
      const data = await clone(array, false);
      if (data) {
        if (snapshots.get(array)?.account.owner !== ADDRESSES.raydium
            || !data.subarray(0, 8).equals(discriminator('account', 'TickArrayState'))
            || readKey(data, 8) !== address || data.readInt32LE(40) !== start + distance * span) {
          throw new Error('Tick array account relation is invalid');
        }
        arrays.push(array);
      }
    }
    if (!arrays.length) throw new Error('No initialized tick arrays around current price');
    pools.push({ address, ...pool, arrays, bitmap });
  }
  await owned(ADDRESSES.market, ADDRESSES.kamino);
  const reserve = decodeReserve(await owned(ADDRESSES.reserve, ADDRESSES.kamino));
  if (reserve.market !== ADDRESSES.market || reserve.mint !== ADDRESSES.usdc) throw new Error('Unexpected Kamino reserve relation');
  for (const address of [reserve.liquidityVault, reserve.feeVault, reserve.collateralMint, reserve.collateralVault]) {
    await owned(address, ADDRESSES.token);
  }
  await clone(ADDRESSES.scopePrices);
  const transmitter = derive(ADDRESSES.cctpTransmitter, Buffer.from('message_transmitter'));
  const messenger = derive(ADDRESSES.cctpMessenger, Buffer.from('token_messenger'));
  await owned(transmitter, ADDRESSES.cctpTransmitter);
  const messengerData = await owned(messenger, ADDRESSES.cctpMessenger);
  await owned(derive(ADDRESSES.cctpMessenger, Buffer.from('token_minter')), ADDRESSES.cctpMessenger);
  await owned(derive(ADDRESSES.cctpMessenger, Buffer.from('remote_token_messenger'), Buffer.from('3')), ADDRESSES.cctpMessenger);
  const localToken = derive(ADDRESSES.cctpMessenger, Buffer.from('local_token'), publicKey(ADDRESSES.usdc).toBuffer());
  const localData = await owned(localToken, ADDRESSES.cctpMessenger);
  await owned(readKey(localData, 8), ADDRESSES.token);
  const remoteUsdc = Buffer.from('000000000000000000000000af88d065e77c8cc2239327c5edb3a432268e5831', 'hex');
  await owned(derive(ADDRESSES.cctpMessenger, Buffer.from('token_pair'), Buffer.from('3'), remoteUsdc), ADDRESSES.cctpMessenger);
  const feeRecipient = publicKey(readKey(messengerData, 109));
  await owned(testAta(ADDRESSES.usdc, feeRecipient).toBase58(), ADDRESSES.token);
  const bridge = derive(ADDRESSES.wormhole, Buffer.from('Bridge'));
  const bridgeData = await owned(bridge, ADDRESSES.wormhole);
  if (bridgeData.length !== 24) throw new Error('Unexpected Wormhole BridgeData layout');
  const guardianIndex = bridgeData.readUInt32LE(0);
  const guardianSeed = Buffer.alloc(4);
  guardianSeed.writeUInt32BE(guardianIndex);
  const guardianSet = derive(ADDRESSES.wormhole, Buffer.from('GuardianSet'), guardianSeed);
  await owned(guardianSet, ADDRESSES.wormhole);
  await clone(derive(ADDRESSES.wormhole, Buffer.from('fee_collector')));
  const manifest = {
    generatedAt: new Date().toISOString(), source: 'mainnet-finalized-read-only',
    minSlot: Math.min(...slots), maxSlot: Math.max(...slots),
    warpSlot: Math.max(...slots), guardianIndex, guardianSet, missingOptional: missing,
    pools, reserve,
    accounts: [...snapshots.values()].map(snapshot => ({
      address: snapshot.pubkey, owner: snapshot.account.owner, executable: snapshot.account.executable,
      sha256: createHash('sha256').update(Buffer.from(snapshot.account.data[0], 'base64')).digest('hex'),
    })),
    syntheticOverrides: 'Local wallet SOL/USDC/TSLAx only; never mint or protocol state',
  };
  for (const directory of ['accounts', 'overrides']) {
    for (const file of readdirSync(`${root}/${directory}`).filter(name => name.endsWith('.json'))) {
      unlinkSync(`${root}/${directory}/${file}`);
    }
  }
  fixtureWallet(manager, templates);
  fixtureWallet(keeper, templates);
  for (const snapshot of snapshots.values()) {
    writeFileSync(`${root}/accounts/${snapshot.pubkey}.json`, JSON.stringify(snapshot));
  }
  writeFileSync(`${root}/manifest.json`, JSON.stringify(manifest, (_, value) => typeof value === 'bigint' ? value.toString() : value, 2));
  console.log(`Prepared ${snapshots.size} mainnet accounts; ${missing.length} uninitialized optional accounts; slots ${manifest.minSlot}-${manifest.maxSlot}.`);
}

main().catch(error => {
  const message = error instanceof Error ? error.message : 'Clone preparation failed';
  console.error(message.includes('://') ? 'Clone preparation failed; endpoint details suppressed.' : message);
  process.exitCode = 1;
});
