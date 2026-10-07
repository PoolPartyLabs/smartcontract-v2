import assert from "node:assert/strict";
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { AbiCoder, Interface, SigningKey, computeAddress, keccak256, getBytes } from "ethers";
import { Keypair, PublicKey, SystemProgram, TransactionInstruction, AddressLookupTableProgram, TransactionMessage, VersionedTransaction, ComputeBudgetProgram } from "@solana/web3.js";
import { createHash } from "node:crypto";
import { ADDRESSES, publicKey, fundAddresses, derive } from "../tests/helpers/addresses.ts";
import { integer, word, hash, stageSwapPolicy } from "../tests/core/fixtures.ts";
import { discriminator } from "../tests/helpers/layouts.ts";
import { testAta, localConnection, requireLoopback, fundSol, sendLocal } from "../tests/helpers/localnet.ts";
import { SOL_PRICE, USDC_PRICE, SOL_FEED, USDC_FEED, NVDA, policyDigest } from "../tests/swap/production-client.ts";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const output = resolve(root, "cache/sol-t11");
const abi = AbiCoder.defaultAbiCoder();
const configType = "tuple(bytes32 program,bytes32 spoke,bytes32 usdcMint,bytes32 managerKey,uint256 chainId,tuple(bytes32 mint,address accountingId,bool stock)[] assets,tuple(bytes32 program,bytes32 pool,bytes32 reserve,bytes32 token0,bytes32 token1)[] venues,tuple(address hubUsdc,address tokenMessenger,address messageTransmitter,uint32 destinationDomain,bytes32 mintRecipient,bytes32 destinationCaller,bytes32 remoteTokenMessenger,bytes32 remoteVaultAuthority,uint256 fastFeeCeiling) transport,bytes32 swapPolicyHash)";
const zero = "0x" + "00".repeat(32);
const hex = (value: Uint8Array) => "0x" + Buffer.from(value).toString("hex");
const keyHex = (value: string) => hex(publicKey(value).toBuffer());
const buffer = (value: string) => Buffer.from(getBytes(value));

function wallets() {
  try {
    const manager = new SigningKey(process.env.DEPLOYER_PRIVATE_KEY!);
    const encoded = process.env.SOLANA_DEPLOYER_PRIVATE_KEY!;
    const secret = encoded.startsWith("[") ? Uint8Array.from(JSON.parse(encoded)) : bufferToSecret(encoded);
    const solana = Keypair.fromSecretKey(secret);
    assert.equal(solana.publicKey.toBase58(), "6VTveiPVZVM7H9BWEsUsu4ivsrPjKw9ePrLQqHaFgJaA");
    return { manager, solana };
  } catch { throw new Error("R4.2/R8 wallet parameters missing or invalid; values suppressed"); }
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
  const { manager, solana } = wallets();
  const plan = JSON.parse(readFileSync(resolve(output, "creation.json"), "utf8"));
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
  if (process.argv[2] !== "accept-local") throw new Error("Only export or accept-local supported");
  const connection = localConnection(); requireLoopback(connection.rpcEndpoint);
  assert.equal(process.env.PP_LOCALNET_RPC_PORT, "8998");
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
