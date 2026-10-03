import assert from "node:assert/strict";
import {closeSync, existsSync, fsyncSync, openSync, readFileSync, writeSync} from "node:fs";
import {dirname} from "node:path";
import {type Address, type Hex, type TransactionReceipt} from "viem";

export interface AlphaTransaction {
  mode: string;
  side: string;
  address: Address;
  functionName: string;
  hash: Hex;
  status: "submitted" | "success" | "reverted";
  receiptOutcome?: "unknown";
  gasUsed?: string;
  blockNumber?: string;
}

export class AlphaTransactions {
  readonly transactions = new Map<Hex, AlphaTransaction>();

  constructor(readonly path: string) {
    if (existsSync(path)) {
      for (const line of readFileSync(path, "utf8").split("\n").filter(Boolean)) {
        const entry = JSON.parse(line) as AlphaTransaction;
        assert.ok(/^0x[0-9a-f]{64}$/i.test(entry.hash));
        assert.ok(["submitted", "success", "reverted"].includes(entry.status));
        assert.ok(["hub", "spoke"].includes(entry.side));
        assert.ok(["capital", "bridge", "income", "closure"].includes(entry.mode));
        this.transactions.set(entry.hash, entry);
      }
    }
    const descriptor = openSync(path, "a", 0o600);
    try {fsyncSync(descriptor);} finally {closeSync(descriptor);}
    const directory = openSync(dirname(path), "r");
    try {fsyncSync(directory);} finally {closeSync(directory);}
  }

  assertFreshMode(mode: string) {
    assert.ok([...this.transactions.values()].every((entry) => entry.status === "success"),
      "Unresolved or reverted prior broadcasts; reconcile and inspect chain state before any further writes");
    assert.ok(![...this.transactions.values()].some((entry) => entry.mode === mode),
      "This phase already broadcast transactions; run reconcile and inspect chain state, never resubmit automatically");
  }

  save(entry: AlphaTransaction) {
    const descriptor = openSync(this.path, "a", 0o600);
    try {
      const bytes = Buffer.from(JSON.stringify(entry) + "\n");
      let offset = 0;
      while (offset < bytes.length) offset += writeSync(descriptor, bytes, offset, bytes.length - offset);
      fsyncSync(descriptor);
    } finally {closeSync(descriptor);}
    this.transactions.set(entry.hash, entry);
  }

  receipt(entry: AlphaTransaction, receipt: TransactionReceipt) {
    assert.equal(receipt.transactionHash.toLowerCase(), entry.hash.toLowerCase());
    this.save({...entry, status: receipt.status, receiptOutcome: undefined,
      gasUsed: receipt.gasUsed.toString(), blockNumber: receipt.blockNumber.toString()});
  }
}

export async function sendAlphaTransaction(
  store: AlphaTransactions,
  details: Omit<AlphaTransaction, "hash" | "status">,
  broadcast: () => Promise<Hex>,
  waitReceipt: (hash: Hex) => Promise<TransactionReceipt>,
) {
  const hash = await broadcast();
  const entry: AlphaTransaction = {...details, hash, status: "submitted"};
  store.save(entry);
  let receipt: TransactionReceipt;
  try {receipt = await waitReceipt(hash);} catch (error) {
    store.save({...entry, receiptOutcome: "unknown"});
    throw error;
  }
  store.receipt(entry, receipt);
  assert.equal(receipt.status, "success", "Transaction reverted; reconcile saved hash, never automatically resubmit");
  return receipt;
}

export async function reconcileAlphaTransactions(
  store: AlphaTransactions,
  getReceipt: (entry: AlphaTransaction) => Promise<TransactionReceipt>,
) {
  for (const entry of [...store.transactions.values()]) {
    if (entry.status !== "submitted") continue;
    try {store.receipt(entry, await getReceipt(entry));} catch {
      store.save({...entry, receiptOutcome: "unknown"});
    }
  }
  return [...store.transactions.values()];
}
