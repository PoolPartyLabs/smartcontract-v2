// BPF upgradeable loader (v3) layouts, read-only preflight and the pre-funded program-id recovery.
// Shared by deploy-mainnet.mjs, programdata-watch.mjs and the loopback regression tests, so the
// code exercised on localnet is the code the mainnet wrapper runs. SP-C1/C11, CR-10, CR-22.
import { createRequire } from 'node:module';
import { createHash } from 'node:crypto';
import { assertGenesis } from './ops-common.mjs';
import { sendInstructions } from './guarded-send.mjs';

const require = createRequire(import.meta.url);
const { PublicKey, SystemProgram, TransactionInstruction, SYSVAR_RENT_PUBKEY, SYSVAR_CLOCK_PUBKEY } = require('@solana/web3.js');

export const LOADER_V3 = new PublicKey('BPFLoaderUpgradeab1e11111111111111111111111');
export const PROGRAM_ACCOUNT_BYTES = 36;
export const BUFFER_HEADER_BYTES = 37;
export const PROGRAMDATA_HEADER_BYTES = 45;

export function programDataAddress(programId) {
  return PublicKey.findProgramAddressSync([new PublicKey(programId).toBuffer()], LOADER_V3)[0];
}

// absent | prefunded (system-owned, no data: third-party lamports) | recovery-prepared (loader-owned,
// allocated, Uninitialized) | deployed | foreign. Only absent may take the CLI initial deploy.
export function classifyProgramAccount(info) {
  if (!info) return { state: 'absent' };
  const base = { lamports: info.lamports, owner: info.owner.toBase58(), dataLength: info.data.length, executable: info.executable };
  if (info.owner.equals(SystemProgram.programId) && info.data.length === 0 && !info.executable) return { ...base, state: 'prefunded' };
  if (info.owner.equals(LOADER_V3) && info.data.length === PROGRAM_ACCOUNT_BYTES) {
    const tag = info.data.readUInt32LE(0);
    if (tag === 0 && !info.executable && info.data.subarray(4).equals(Buffer.alloc(32))) return { ...base, state: 'recovery-prepared' };
    if (tag === 2) return { ...base, state: info.executable ? 'deployed' : 'foreign', programData: new PublicKey(info.data.subarray(4)).toBase58() };
  }
  return { ...base, state: 'foreign' };
}

export function parseBuffer(info) {
  if (!info || !info.owner.equals(LOADER_V3) || info.data.length < BUFFER_HEADER_BYTES || info.data.readUInt32LE(0) !== 1) return null;
  return { authority: info.data[4] === 1 ? new PublicKey(info.data.subarray(5, 37)).toBase58() : null,
    capacity: info.data.length - BUFFER_HEADER_BYTES, data: info.data.subarray(BUFFER_HEADER_BYTES), lamports: info.lamports };
}

export function parseProgramData(info) {
  if (!info || !info.owner.equals(LOADER_V3) || info.data.length < PROGRAMDATA_HEADER_BYTES || info.data.readUInt32LE(0) !== 3) return null;
  return { slot: Number(info.data.readBigUInt64LE(4)),
    authority: info.data[12] === 1 ? new PublicKey(info.data.subarray(13, 45)).toBase58() : null,
    capacity: info.data.length - PROGRAMDATA_HEADER_BYTES, data: info.data.subarray(PROGRAMDATA_HEADER_BYTES), lamports: info.lamports };
}

export const sha256 = bytes => createHash('sha256').update(bytes).digest('hex');

// Conservative computed floor when no approved walletMinimumLamports exists yet: both rents plus every
// loader transaction (create + ceil(bytes/960) writes + deploy) at 10,000 lamports each. Budget numbers
// for approval come only from deploy-mainnet-budget.mjs (CR-32); this is a preflight sanity floor.
export async function computedDeployFloor(connection, binaryBytes, commitment = 'finalized') {
  const programRent = await connection.getMinimumBalanceForRentExemption(PROGRAM_ACCOUNT_BYTES, commitment);
  const programDataRent = await connection.getMinimumBalanceForRentExemption(PROGRAMDATA_HEADER_BYTES + binaryBytes, commitment);
  const transactions = Math.ceil(binaryBytes / 960) + 2;
  return { programRent, programDataRent, transactions, lamports: programRent + programDataRent + transactions * 10_000 };
}

// Read-only. Never throws on a failed check; returns every row so the operator sees the whole picture.
export async function preflight({ connection, cluster, programId, bufferAddress, deployer, minimumLamports, binaryBytes,
  commitment = 'finalized' }) {
  const checks = [];
  const record = (name, ok, detail) => checks.push({ name, ok, detail });
  try {
    await assertGenesis(connection, cluster);
    record('genesis', true, cluster === 'mainnet' ? 'mainnet genesis' : 'non-mainnet loopback genesis');
  } catch (error) {
    record('genesis', false, error.message);
    return { ok: false, checks };
  }
  const program = classifyProgramAccount(await connection.getAccountInfo(new PublicKey(programId), commitment));
  const programDetail = {
    absent: 'program id unused and not pre-funded',
    prefunded: `program id pre-funded by a third party (${program.lamports} lamports, system-owned); run --recover-prefunded`,
    'recovery-prepared': 'program id allocated/assigned by an earlier recovery; resume with --recover-prefunded',
    deployed: 'program already deployed; run --verify, never redeploy',
    foreign: `program id holds an unexpected account (owner ${program.owner}, ${program.dataLength} bytes); NO-GO`,
  }[program.state];
  record('programId', program.state === 'absent', programDetail);
  if (bufferAddress) {
    const info = await connection.getAccountInfo(new PublicKey(bufferAddress), commitment);
    const buffer = parseBuffer(info);
    record('buffer', !info, !info ? 'buffer address unused'
      : buffer ? `buffer exists (authority ${buffer.authority}, capacity ${buffer.capacity}); review/resume or close it, never overwrite`
        : `buffer address holds a non-buffer account (owner ${info.owner.toBase58()}); use a fresh buffer signer`);
  } else {
    record('buffer', false, 'buffer address unknown; supply PP_DEPLOY_BUFFER_KEYPAIR or PP_DEPLOY_BUFFER_ADDRESS');
  }
  const balance = await connection.getBalance(new PublicKey(deployer), commitment);
  let minimum = minimumLamports;
  let source = 'approved walletMinimumLamports';
  if (!Number.isSafeInteger(minimum) || minimum < 1) {
    if (Number.isSafeInteger(binaryBytes) && binaryBytes > 0) {
      minimum = (await computedDeployFloor(connection, binaryBytes, commitment)).lamports;
      source = 'computed rent + loader-fee floor (no approved minimum yet)';
    } else {
      minimum = null;
    }
  }
  record('deployerBalance', minimum !== null && balance >= minimum,
    minimum === null ? `balance ${balance} lamports; no minimum available (no approved minimum and no ELF)`
      : `balance ${balance} lamports vs minimum ${minimum} (${source})`);
  return { ok: checks.every(check => check.ok), checks, deployerBalanceLamports: balance, minimumLamports: minimum };
}

export function deployWithMaxDataLenInstruction({ payer, programId, buffer, authority, maxLen }) {
  const data = Buffer.alloc(12);
  data.writeUInt32LE(2, 0);
  data.writeBigUInt64LE(BigInt(maxLen), 4);
  const key = (pubkey, isWritable, isSigner) => ({ pubkey: new PublicKey(pubkey), isWritable, isSigner });
  return new TransactionInstruction({ programId: LOADER_V3, data, keys: [
    key(payer, true, true), key(programDataAddress(programId), true, false), key(programId, true, false), key(buffer, true, false),
    key(SYSVAR_RENT_PUBKEY, false, false), key(SYSVAR_CLOCK_PUBKEY, false, false), key(SystemProgram.programId, false, false),
    key(authority, false, true)] });
}

// Recovery for a griefed program id (SP-C1): the program keypair signs allocate(36) + assign(loader v3),
// the payer tops the account up to rent exemption, then a raw DeployWithMaxDataLen consumes the fully
// written buffer. Resumable: each stage is chosen from on-chain state, never from local memory.
export async function recoverPrefundedProgram({ connection, payer, programKeypair, bufferAddress, binary, maxLen,
  priorityMicroLamports, commitment = 'finalized', log = () => {} }) {
  const programId = programKeypair.publicKey;
  if (maxLen !== binary.length) throw new Error('Recovery requires exactly 1x capacity (maxLen equals ELF bytes)');
  let program = classifyProgramAccount(await connection.getAccountInfo(programId, commitment));
  if (!['prefunded', 'recovery-prepared'].includes(program.state)) {
    throw new Error(`Recovery applies only to a pre-funded or recovery-prepared program id; found ${program.state}`);
  }
  const buffer = parseBuffer(await connection.getAccountInfo(bufferAddress, commitment));
  if (!buffer || buffer.authority !== payer.publicKey.toBase58() || buffer.capacity !== maxLen || !buffer.data.equals(binary)) {
    throw new Error('Buffer must be a fully written loader buffer of the reviewed ELF with the deployer as authority');
  }
  const signatures = {};
  const rent = await connection.getMinimumBalanceForRentExemption(PROGRAM_ACCOUNT_BYTES, commitment);
  const topUp = Math.max(0, rent - program.lamports);
  if (program.state === 'prefunded' || topUp > 0) {
    const instructions = [];
    const signers = [payer];
    if (program.state === 'prefunded') {
      instructions.push(SystemProgram.allocate({ accountPubkey: programId, space: PROGRAM_ACCOUNT_BYTES }),
        SystemProgram.assign({ accountPubkey: programId, programId: LOADER_V3 }));
      signers.push(programKeypair);
    }
    // Rent must be met in the same transaction as allocate (no RentPaying transition).
    if (topUp > 0) instructions.unshift(SystemProgram.transfer({ fromPubkey: payer.publicKey, toPubkey: programId, lamports: topUp }));
    log('recovery-prepare', 'start', `state=${program.state} topUpLamports=${topUp}`);
    signatures.prepare = await sendInstructions(connection, instructions, signers,
      { commitment, computeUnitLimit: 10_000, priorityMicroLamports });
    log('recovery-prepare', 'ok', `signature=${signatures.prepare}`);
    program = classifyProgramAccount(await connection.getAccountInfo(programId, commitment));
    if (program.state !== 'recovery-prepared' || program.lamports < rent) throw new Error('Program id did not reach the recovery-prepared state');
  }
  log('recovery-deploy', 'start', `programData=${programDataAddress(programId).toBase58()} maxLen=${maxLen}`);
  signatures.deploy = await sendInstructions(connection,
    [deployWithMaxDataLenInstruction({ payer: payer.publicKey, programId, buffer: bufferAddress, authority: payer.publicKey, maxLen })],
    [payer], { commitment, computeUnitLimit: 20_000, priorityMicroLamports });
  log('recovery-deploy', 'ok', `signature=${signatures.deploy}`);
  return signatures;
}

// Reads the deployed program and its parsed ProgramData (slot, authority, capacity, ELF bytes); returns
// programData null unless the program id is a deployed loader-v3 program. Comparison is the caller's job.
export async function readDeployedProgram(connection, programId, commitment = 'finalized') {
  const program = classifyProgramAccount(await connection.getAccountInfo(new PublicKey(programId), commitment));
  if (program.state !== 'deployed') return { program, programData: null };
  const programData = parseProgramData(await connection.getAccountInfo(new PublicKey(program.programData), commitment));
  return { program, programData };
}
