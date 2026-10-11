import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { AbiCoder, Interface, SigningKey, computeAddress, keccak256, getBytes, TypedDataEncoder } from "ethers";
import { Keypair, PublicKey, SystemProgram, TransactionInstruction, AddressLookupTableProgram, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from "@solana/web3.js";
import { createHash } from "node:crypto";
import { spawnSync } from "node:child_process";
import { Connection } from "@solana/web3.js";
import { ADDRESSES, publicKey, fundAddresses, derive } from "../tests/helpers/addresses.ts";
import { integer, word, hash, stageSwapPolicy } from "../tests/core/fixtures.ts";
import { discriminator } from "../tests/helpers/layouts.ts";
import { testAta, localConnection, requireLoopback, fundSol, sendLocal } from "../tests/helpers/localnet.ts";
import { SOL_PRICE, USDC_PRICE, SOL_FEED, USDC_FEED, NVDA, policyDigest } from "../tests/swap/production-client.ts";
import { checkedEndpoint, assertGenesis, stepLogger } from "./ops-common.mjs";
import { guardedSend, lockJournal, latestRecord } from "./guarded-send.mjs";
import { classifyProgramAccount } from "./loader-v3.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const output = resolve(root, "cache/sol-t11");
const abi = AbiCoder.defaultAbiCoder();
const configType = "tuple(bytes32 program,bytes32 spoke,bytes32 usdcMint,bytes32 managerKey,uint256 chainId,tuple(bytes32 mint,address accountingId,bool stock)[] assets,tuple(bytes32 program,bytes32 pool,bytes32 reserve,bytes32 token0,bytes32 token1)[] venues,tuple(address hubUsdc,address tokenMessenger,address messageTransmitter,uint32 destinationDomain,bytes32 mintRecipient,bytes32 destinationCaller,bytes32 remoteTokenMessenger,bytes32 remoteVaultAuthority,uint256 fastFeeCeiling) transport,bytes32 swapPolicyHash)";
const zero = "0x" + "00".repeat(32);
const hex = (value: Uint8Array) => "0x" + Buffer.from(value).toString("hex");
const keyHex = (value: string) => hex(publicKey(value).toBuffer());
const buffer = (value: string) => Buffer.from(getBytes(value));

// Local modes pin R8; broadcast pins the founder-approved managerSolanaKey (DEC-190, sealed per Fund).
function wallets(expectedSolana = "6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA") {
  try {
    const manager = new SigningKey(process.env.DEPLOYER_PRIVATE_KEY!);
    const encoded = (process.env.SOLANA_MANAGER_PRIVATE_KEY || process.env.SOLANA_DEPLOYER_PRIVATE_KEY)!.trim();
    const secret = encoded.startsWith("[") ? Uint8Array.from(JSON.parse(encoded)) : bufferToSecret(encoded);
    const solana = Keypair.fromSecretKey(secret);
    assert.equal(solana.publicKey.toBase58(), expectedSolana);
    return { manager, solana };
  } catch { throw new Error("R4.2/R8 wallet parameters missing or invalid; values suppressed"); }
}

const log = stepLogger("three-chain-creation");
const sha256 = (bytes: Buffer) => createHash("sha256").update(bytes).digest("hex");

async function evmCall(endpoint: string, method: string, params: unknown[]) {
  const response = await fetch(endpoint, { method: "POST", signal: AbortSignal.timeout(30000), headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const body = await response.json();
  if (!response.ok || body.error) throw new Error(`Arbitrum read ${method} failed; endpoint suppressed`);
  return body.result;
}

// CR-07 / R02: every gate runs BEFORE any key is parsed. The plan must be the founder-approved file whose
// exact createFundV6Committed calldata already landed on Arbitrum mainnet (never the fork-only cache plan).
async function broadcastGate() {
  const approval = JSON.parse(readFileSync(process.env.PP_MANAGER_APPROVAL_FILE ?? resolve(root, "script/solana-manager-approval.json"), "utf8"));
  if (approval.status !== "FOUNDER_APPROVED" || !approval.approvedBy || !Number.isFinite(Date.parse(approval.approvedAt))
      || !/^[a-f0-9]{40}$/.test(approval.sourceCommit ?? "") || !approval.managerSolanaKey) {
    throw new Error("Founder-approved Manager signing file with exact source commit and managerSolanaKey required; no transaction signed");
  }
  if (approval.programId !== ADDRESSES.spoke) throw new Error("Approved program id differs from the builder program id");
  const head = spawnSync("git", ["rev-parse", "HEAD"], { cwd: root, encoding: "utf8" });
  const clean = spawnSync("git", ["status", "--porcelain", "--untracked-files=no"], { cwd: root, encoding: "utf8" });
  if (head.status !== 0 || head.stdout.trim() !== approval.sourceCommit || clean.status !== 0 || clean.stdout.trim()) {
    throw new Error("Approval source does not match a clean checkout");
  }
  const planPath = process.env.PP_CREATION_PLAN_FILE;
  if (!planPath || resolve(planPath) === resolve(output, "creation.json")) throw new Error("Approved mainnet PP_CREATION_PLAN_FILE required; the fork cache plan is never broadcast");
  const planBytes = readFileSync(planPath);
  const creation = approval.creation ?? {};
  if (sha256(planBytes) !== creation.planSha256) throw new Error("Creation plan differs from the approved planSha256");
  const plan = JSON.parse(planBytes.toString("utf8"));
  if (plan.core?.toLowerCase() !== creation.hubCore?.toLowerCase() || plan.factory?.toLowerCase() !== creation.hubFactory?.toLowerCase()) {
    throw new Error("Plan Hub core/factory differ from the approval");
  }
  const arbitrum = checkedEndpoint("mainnet", process.env.ARBITRUM_RPC_URL);
  if (await evmCall(arbitrum, "eth_chainId", []) !== "0xa4b1") throw new Error("Arbitrum endpoint is not chain 42161");
  const sent = await evmCall(arbitrum, "eth_getTransactionByHash", [creation.hubCreationTx]);
  const receipt = await evmCall(arbitrum, "eth_getTransactionReceipt", [creation.hubCreationTx]);
  if (!sent || !receipt || receipt.status !== "0x1" || sent.to?.toLowerCase() !== plan.factory.toLowerCase()
      || sent.input?.toLowerCase() !== plan.calldata.toLowerCase()) {
    throw new Error("Approved hubCreationTx is not the successful mainnet createFundV6Committed of this plan");
  }
  if ((await evmCall(arbitrum, "eth_getCode", [plan.core, "latest"])) === "0x") throw new Error("Hub core has no code on Arbitrum");
  log("hub-creation", "verified", `tx=${creation.hubCreationTx} core=${plan.core}`);
  const connection = new Connection(checkedEndpoint("mainnet", process.env.SOLANA_MAINNET_RPC), "confirmed");
  await assertGenesis(connection, "mainnet");
  if (classifyProgramAccount(await connection.getAccountInfo(publicKey(ADDRESSES.spoke), "finalized")).state !== "deployed") {
    throw new Error("Spoke program is not deployed on mainnet; run deploy-mainnet.mjs --verify first");
  }
  const priority = approval.priorityMicroLamportsPerCU;
  if (priority !== null && priority !== undefined && (!Number.isSafeInteger(priority) || priority < 1 || priority > 1000000)) {
    throw new Error("Approved priorityMicroLamportsPerCU must be null or 1..1000000");
  }
  log("gate", "ok", `fund=${creation.fundPda ?? "unpinned"}`);
  return { approval, plan, connection, priority: priority ?? 0 };
}

// Seven Manager-signed native steps with a fsync'ed journal: the signature is persisted before send, a
// landed step is skipped on rerun, an uncertain one is reconciled and never re-signed (guarded-send.mjs).
async function broadcastNative(gate: any, solana: Keypair, stage: any, operation: TransactionInstruction, sealed: Buffer, target: any) {
  const { connection, approval, priority } = gate;
  if (approval.creation?.fundPda && approval.creation.fundPda !== target.fund) throw new Error("Derived Fund PDA differs from the approved fundPda");
  const fund = publicKey(target.fund);
  const journalPath = resolve(root, `cache/manager-sign/mainnet-creation-${target.fund}.jsonl`);
  if (await connection.getAccountInfo(fund, "finalized") && !latestRecord(journalPath, "initialize")) {
    throw new Error("Fund PDA already exists without a journaled initializer; inspect before any signature");
  }
  const flags = { retryExpired: process.argv.includes("--retry-expired"), retryFailed: process.argv.includes("--retry-failed") };
  const send = (key: string, build: (blockhash: string) => Promise<any>) => guardedSend({ connection, journalPath, key, build, commitment: "finalized", log, ...flags });
  const withPrice = (instructions: TransactionInstruction[]) => priority ? [ComputeBudgetProgram.setComputeUnitPrice({ microLamports: priority }), ...instructions] : instructions;
  const legacy = (instructions: TransactionInstruction[]) => async (blockhash: string) => {
    const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: solana.publicKey, recentBlockhash: blockhash, instructions: withPrice(instructions) }).compileToLegacyMessage());
    transaction.sign([solana]);
    return { transaction };
  };
  const unlock = lockJournal(journalPath);
  try {
    const signatures: Record<string, string> = {};
    for (const [index, instruction] of stage.instructions.entries()) signatures[`stage-${index + 1}`] = (await send(`stage-${index + 1}`, legacy([instruction]))).signature;
    const alt = await send("alt-create", async blockhash => {
      const recentSlot = await connection.getSlot("finalized");
      const [create, table] = AddressLookupTableProgram.createLookupTable({ authority: solana.publicKey, payer: solana.publicKey, recentSlot });
      return { ...(await legacy([create])(blockhash)), meta: { table: table.toBase58(), recentSlot } };
    });
    signatures["alt-create"] = alt.signature;
    const tableAddress = new PublicKey(alt.meta.table);
    const accounts = [...new Map(operation.keys.filter(meta => !meta.isSigner).map(meta => [meta.pubkey.toBase58(), meta.pubkey])).values()];
    for (let offset = 0, chunk = 1; offset < accounts.length; offset += 20, chunk++) {
      signatures[`alt-extend-${chunk}`] = (await send(`alt-extend-${chunk}`, legacy([AddressLookupTableProgram.extendLookupTable({ authority: solana.publicKey,
        payer: solana.publicKey, lookupTable: tableAddress, addresses: accounts.slice(offset, offset + 20) })]))).signature;
    }
    let table: any;
    for (let attempt = 0; ; attempt++) {
      table = (await connection.getAddressLookupTable(tableAddress, { commitment: "finalized" })).value;
      if (table && accounts.every(account => table.state.addresses.some((entry: PublicKey) => entry.equals(account)))
          && await connection.getSlot("finalized") > table.state.lastExtendedSlot) break;
      if (attempt > 120) throw new Error("Lookup table did not activate with every initializer account");
      await new Promise(done => setTimeout(done, 1000));
    }
    const init = await send("initialize", async blockhash => {
      const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: solana.publicKey, recentBlockhash: blockhash,
        instructions: withPrice([ComputeBudgetProgram.setComputeUnitLimit({ units: 900000 }), operation]) }).compileToV0Message([table]));
      transaction.sign([solana]);
      if (transaction.serialize().length > 1232) throw new Error("Initializer exceeds 1232 bytes");
      return { transaction };
    });
    signatures.initialize = init.signature;
    const state = (await connection.getAccountInfo(fund, "finalized"))!;
    assert.equal(state.owner.toBase58(), ADDRESSES.spoke);
    const config = (await connection.getAccountInfo(operation.keys[18].pubkey, "finalized"))!;
    assert.ok(config.data.subarray(72, 72 + sealed.length).equals(sealed));
    writeFileSync(resolve(output, "native-broadcast.json"), JSON.stringify({ status: "PASS", cluster: "mainnet", fund: target.fund,
      lookupTable: tableAddress.toBase58(), signatures, journal: journalPath, scopeEnabled: false }, null, 2));
    console.log("Manager native bootstrap landed on mainnet; signatures journaled.");
  } finally { unlock(); }
}

function bufferToSecret(encoded: string): Uint8Array {
  const alphabet = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
  let value = 0n;
  for (const character of encoded) {
    const digit = alphabet.indexOf(character);
    if (digit < 0) throw new Error("Invalid base58 key parameter");
    value = value * 58n + BigInt(digit);
  }
  const bytes = Buffer.from(value.toString(16).padStart(128, "0"), "hex");
  if (bytes.length !== 64) throw new Error("Expected 64-byte key parameter");
  return bytes;
}

function policy() {
  const signer = process.env.API_SIGNER;
  if (!signer || /^0x0{40}$/i.test(signer)) throw new Error("Explicit nonzero API signer required");
  const values = ["PP_SWAP_MAX_AGE", "PP_SWAP_CONFIDENCE_BPS", "PP_SWAP_CROSS_CHECK_BPS", "PP_SWAP_SLIPPAGE_BPS"].map(name => {
    const value = Number(process.env[name]);
    if (!Number.isSafeInteger(value) || value < 0) throw new Error("Explicit reviewed swap-policy limits required");
    return value;
  });
  if (values[0] < 1 || values[0] > 300 || values[1] < 1 || values.slice(1).some(value => value >= 10000)) throw new Error("Invalid sealed swap policy");
  return Buffer.concat([buffer(signer), publicKey(SOL_PRICE).toBuffer(), publicKey(USDC_PRICE).toBuffer(), SOL_FEED, USDC_FEED,
    integer(values[0], 8), ...values.slice(1).map(value => integer(value, 2)), Buffer.from([0, 0])]);
}

function prepare() {
  const { manager, solana } = wallets();
  const sealed = policy();
  const mints = [ADDRESSES.usdc, ADDRESSES.wsol, NVDA];
  const assets = mints.map(mint => ({ mint: keyHex(mint), accountingId: "0x" + keccak256(abi.encode(["string", "uint16", "bytes32"], ["PoolParty/SolanaAsset/v6", 1, keyHex(mint)])).slice(-40), stock: mint === NVDA }));
  const venues = [
    { program: keyHex(ADDRESSES.kamino), pool: zero, reserve: keyHex(ADDRESSES.reserve), token0: keyHex(ADDRESSES.usdc), token1: zero },
    { program: keyHex(ADDRESSES.raydium), pool: keyHex(ADDRESSES.solPool), reserve: zero, token0: keyHex(ADDRESSES.wsol), token1: keyHex(ADDRESSES.usdc) },
  ];
  const config = { program: keyHex(ADDRESSES.spoke), spoke: zero, usdcMint: keyHex(ADDRESSES.usdc), managerKey: hex(solana.publicKey.toBuffer()), chainId: 1,
    assets, venues, transport: { hubUsdc: "0xaf88d065e77c8cc2239327c5edb3a432268e5831", tokenMessenger: "0x28b5a0e9c621a5badaa536219b3a228c8168cf5d", messageTransmitter: "0x81d40f21f12a8f0e3252bccb954d722d4c464b64", destinationDomain: 5, mintRecipient: zero, destinationCaller: zero, remoteTokenMessenger: keyHex(ADDRESSES.cctpMessenger), remoteVaultAuthority: zero, fastFeeCeiling: 50000 }, swapPolicyHash: hex(hash(sealed)) };
  mkdirSync(output, { recursive: true });
  writeFileSync(resolve(output, "native-config.hex"), abi.encode([configType], [config]));
  writeFileSync(resolve(output, "builder-input.json"), JSON.stringify({ manager: computeAddress(manager), managerSolana: solana.publicKey.toBase58(), config, policy: hex(sealed), scopeEnabled: false, stockSwapsAvailable: false, approval: "NOT_APPROVED", policyLimits: "Explicit engineering proposal; founder approval required" }, null, 2));
  console.log("Real wallet public commitments prepared; no transaction submitted.");
}

async function accept() {
  const gate = process.argv[2] === "broadcast" ? await broadcastGate() : null;
  const { manager, solana } = gate ? wallets(gate.approval.managerSolanaKey) : wallets();
  const plan = gate ? gate.plan : JSON.parse(readFileSync(resolve(output, "creation.json"), "utf8"));
  const artifact = JSON.parse(readFileSync(resolve(root, "out/FundFactoryV6.sol/FundFactoryV6.json"), "utf8"));
  const factory = new Interface(artifact.abi);
  const [mandate, params, native, commitment, binding] = factory.decodeFunctionData("createFundV6Committed", plan.calldata);
  assert.equal(mandate.manager.toLowerCase(), computeAddress(manager).toLowerCase());
  assert.equal(native.managerKey, hex(solana.publicKey.toBuffer()));
  assert.equal(params.seedAmount, 50000000n);
  assert.equal(native.program, keyHex(ADDRESSES.spoke));
  const mandateType = factory.getFunction("createFundV6Committed")!.inputs[0];
  const mandateHash = buffer(keccak256(abi.encode([mandateType], [mandate])));
  const nativeHash = buffer(keccak256(abi.encode(["uint256", configType], [6, native])));
  const parsed = abi.decode([configType], abi.encode([configType], [native]))[0].toObject(true);
  parsed.spoke = zero;
  for (const field of ["mintRecipient", "destinationCaller", "remoteVaultAuthority"]) parsed.transport[field] = zero;
  const nativePolicyHash = hash(buffer(abi.encode(["uint256", configType], [6, parsed])));
  const mandatePolicy = mandate.toObject(true);
  mandatePolicy.operatingCash = Array.from(mandate.operatingCash);
  mandatePolicy.spokes[1].spokeVault = zero;
  const hubPolicyHash = hash(buffer(abi.encode([mandateType], [mandatePolicy])));
  assert.equal(hex(hash(Buffer.concat([hash(Buffer.from("PoolParty/SolanaPolicy/v6")), hubPolicyHash, nativePolicyHash]))), commitment.policyHash);
  const target = fundAddresses(buffer(plan.core), Number(commitment.spokeIndex), buffer(commitment.policyHash));
  assert.equal(keyHex(target.fund), commitment.fundPda);
  assert.equal(keyHex(target.emitter), native.spoke);
  const sealed = policy();
  assert.equal(hex(hash(sealed)), native.swapPolicyHash);
  const digest = buffer(plan.bindingDigest);
  const bootstrapTypes = { SolanaBootstrap: [
    ["hubChain", "uint256"], ["core", "address"], ["mandateHash", "bytes32"], ["policyHash", "bytes32"], ["spokeIndex", "uint16"], ["program", "bytes32"], ["fundPda", "bytes32"], ["solanaKey", "bytes32"], ["usdcAta", "bytes32"], ["tslaxAta", "bytes32"], ["nvdaxAta", "bytes32"], ["wsolAta", "bytes32"], ["nativeMandateHash", "bytes32"], ["fundId", "bytes32"], ["nonce", "uint256"], ["expiry", "uint256"],
  ].map(([name, type]) => ({ name, type })) };
  const expectedDigest = TypedDataEncoder.hash({ name: "PoolParty Solana Fund", version: "6", chainId: 42161, verifyingContract: plan.factory }, bootstrapTypes,
    { hubChain: 42161, core: plan.core, mandateHash: hex(mandateHash), policyHash: commitment.policyHash, spokeIndex: commitment.spokeIndex, program: native.program, fundPda: commitment.fundPda, solanaKey: native.managerKey, usdcAta: commitment.usdcAta, tslaxAta: commitment.stockAta, nvdaxAta: commitment.nvdaxAta, wsolAta: commitment.wsolAta, nativeMandateHash: hex(nativeHash), fundId: plan.fundId, nonce: binding.nonce, expiry: binding.expiry });
  assert.equal(expectedDigest, plan.bindingDigest);
  assert.equal(manager.sign(digest).serialized, binding.signature);
  const consent = buffer(manager.sign(policyDigest(sealed, digest, publicKey(target.fund), buffer(plan.core))).serialized);
  const transport = native.transport;
  const payload = Buffer.concat([buffer(plan.core), integer(commitment.spokeIndex, 2), buffer(plan.fundId), mandateHash, buffer(mandate.manager), buffer(plan.factory), integer(42161, 8), integer(1, 8), nativeHash, word(binding.nonce), integer(binding.expiry, 8), buffer(binding.signature), integer(native.assets.length, 4),
    ...native.assets.map((asset: any) => Buffer.concat([buffer(asset.mint), buffer(asset.accountingId), Buffer.from([Number(asset.stock)])])),
    integer(native.venues.length, 4), ...native.venues.map((venue: any) => Buffer.concat([venue.program, venue.pool, venue.reserve, venue.token0, venue.token1].map(buffer))),
    ...[transport.hubUsdc, transport.tokenMessenger, transport.messageTransmitter].map(buffer), integer(transport.destinationDomain, 4), ...[transport.mintRecipient, transport.destinationCaller, transport.remoteTokenMessenger, transport.remoteVaultAuthority].map(buffer), integer(transport.fastFeeCeiling, 8), hubPolicyHash, buffer(commitment.policyHash), buffer(native.swapPolicyHash), sealed, consent]);
  const fund = publicKey(target.fund); const vault = publicKey(target.vault);
  const stage = stageSwapPolicy(solana.publicKey, fund, buffer(commitment.policyHash), payload);
  const key = (pubkey: PublicKey, isWritable = false, isSigner = false) => ({ pubkey, isWritable, isSigner });
  const mints = [ADDRESSES.usdc, ADDRESSES.tslax, ADDRESSES.wsol];
  const operation = new TransactionInstruction({ programId: publicKey(ADDRESSES.spoke), keys: [key(solana.publicKey, true, true), key(fund, true), key(vault),
    ...mints.map(mint => key(publicKey(mint))), ...mints.map(mint => key(testAta(mint, vault), true)),
    ...mints.map(mint => key(publicKey(derive(ADDRESSES.spoke, Buffer.from("ledger"), fund.toBuffer(), publicKey(mint).toBuffer())), true)),
    ...["cctp_route", "cctp_ledger"].map(seed => key(publicKey(derive(ADDRESSES.spoke, Buffer.from(seed), fund.toBuffer())), true)),
    ...[ADDRESSES.token, ADDRESSES.token2022, ADDRESSES.ata].map(program => key(publicKey(program))), key(SystemProgram.programId),
    key(publicKey(derive(ADDRESSES.spoke, Buffer.from("swap_config"), fund.toBuffer())), true), key(stage.stage, true), key(publicKey(NVDA)), key(testAta(NVDA, vault), true), key(publicKey(derive(ADDRESSES.spoke, Buffer.from("ledger"), fund.toBuffer(), publicKey(NVDA).toBuffer())), true)],
    data: Buffer.concat([discriminator("global", "initialize_fund"), integer(1, 4), Buffer.from([2])]) });
  const instructions = [...stage.instructions, operation];
  const exportInstruction = (instruction: TransactionInstruction) => ({ programId: instruction.programId.toBase58(), dataBase64: instruction.data.toString("base64"), accounts: instruction.keys.map(meta => ({ ...meta, pubkey: meta.pubkey.toBase58() })) });
  writeFileSync(resolve(output, "signer-prompts.json"), JSON.stringify({ approval: "NOT_APPROVED", seedUsdc: 50, scopeEnabled: false, stockSwapsAvailable: false,
    ordered: ["EVM operator: deploy reviewed v6 factories on Arbitrum then Robinhood", "EVM Manager: sign exact SolanaBootstrap EIP-712 commitment", "EVM Manager: sign sealed SolanaSwapPolicy EIP-712 commitment", "EVM Manager: approve 50 USDC to Hub factory", "EVM Manager: createFundV6Committed on Arbitrum", "EVM Manager: createSpoke on Robinhood", ...stage.instructions.map((_, index) => `Manager Solana Key: stage immutable chunk ${index + 1}/${stage.instructions.length}`), "Manager Solana Key: create lookup table", "Manager Solana Key: extend lookup table (20 accounts/chunk)", "Manager Solana Key: sign initialize_fund acceptance"],
    evmTransactions: [{ chainId: 42161, to: mandate.usdc, data: plan.approveCalldata }, { chainId: 42161, to: plan.factory, data: plan.calldata }, { chainId: 4663, to: plan.factory, data: plan.robinhoodCalldata }], solanaInstructions: instructions.map(exportInstruction), payloadSha256: createHash("sha256").update(payload).digest("hex"), fund: target.fund }, null, 2));
  if (process.argv[2] === "export") { console.log("Exact EVM calldata and native instruction list exported; NOT_APPROVED."); return; }
  if (gate) { await broadcastNative(gate, solana, stage, operation, sealed, target); return; }
  if (process.argv[2] !== "accept-local") throw new Error("Only prepare, export, accept-local or approval-gated broadcast supported");
  assert.equal(readFileSync(resolve(output, "hub-created"), "utf8"), "PASS");
  const connection = localConnection(); requireLoopback(connection.rpcEndpoint);
  assert.equal(process.env.PP_LOCALNET_RPC_PORT, "8998");
  const idl = JSON.parse(readFileSync(resolve(root, "solana/target/idl/pp_spoke.json"), "utf8"));
  assert.equal(idl.address, ADDRESSES.spoke);
  await fundSol(connection, solana.publicKey, 10);
  const before = await connection.getBalance(solana.publicKey);
  const signatures = [];
  for (const instruction of stage.instructions) signatures.push(await sendLocal(connection, solana, [instruction]));
  const [create, tableAddress] = AddressLookupTableProgram.createLookupTable({ authority: solana.publicKey, payer: solana.publicKey, recentSlot: await connection.getSlot("finalized") });
  signatures.push(await sendLocal(connection, solana, [create]));
  const accounts = [...new Map(operation.keys.filter(meta => !meta.isSigner).map(meta => [meta.pubkey.toBase58(), meta.pubkey])).values()];
  for (let offset = 0; offset < accounts.length; offset += 20) signatures.push(await sendLocal(connection, solana, [AddressLookupTableProgram.extendLookupTable({ authority: solana.publicKey, payer: solana.publicKey, lookupTable: tableAddress, addresses: accounts.slice(offset, offset + 20) })]));
  const extended = await connection.getSlot();
  while (await connection.getSlot() <= extended) await new Promise(resolve => setTimeout(resolve, 100));
  const table = (await connection.getAddressLookupTable(tableAddress)).value!;
  const block = await connection.getLatestBlockhash();
  const transaction = new VersionedTransaction(new TransactionMessage({ payerKey: solana.publicKey, recentBlockhash: block.blockhash, instructions: [ComputeBudgetProgram.setComputeUnitLimit({ units: 900000 }), operation] }).compileToV0Message([table]));
  transaction.sign([solana]);
  assert.ok(transaction.serialize().length <= 1232);
  const simulation = await connection.simulateTransaction(transaction);
  if (simulation.value.err) throw new Error("Native acceptance simulation failed: " + JSON.stringify(simulation.value.err) + " " + simulation.value.logs?.slice(-8).join(" "));
  const signature = await connection.sendRawTransaction(transaction.serialize());
  const confirmation = await connection.confirmTransaction({ signature, ...block });
  assert.equal(confirmation.value.err, null);
  signatures.push(signature);
  const state = (await connection.getAccountInfo(fund))!;
  assert.equal(state.owner.toBase58(), ADDRESSES.spoke);
  const config = (await connection.getAccountInfo(operation.keys[18].pubkey))!;
  assert.ok(config.data.subarray(72, 72 + sealed.length).equals(sealed));
  writeFileSync(resolve(output, "native-acceptance.json"), JSON.stringify({ status: "PASS", fund: target.fund, signatures, transactionCount: signatures.length, initializerBytes: transaction.serialize().length, initializerCU: simulation.value.unitsConsumed, managerDebitLamports: before - await connection.getBalance(solana.publicKey), scopeEnabled: false, stockSwapsAvailable: false, mainnetTransactions: 0 }, null, 2));
  console.log("Genuine Manager native acceptance PASS on cloned loopback localnet.");
}

try {
  if (process.argv[2] === "prepare") prepare(); else await accept();
} catch (error) {
  let message = error instanceof Error ? error.message : "Creation builder failed";
  for (const [name, value] of Object.entries(process.env)) if (/KEY|SECRET|RPC/.test(name) && value && value.length > 4) message = message.replaceAll(value, "<suppressed>");
  console.error(message.replace(/https?:\/\/[^\s]+/g, "<endpoint>")); process.exitCode = 1;
}
