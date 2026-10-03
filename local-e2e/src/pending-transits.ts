import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";

export interface PendingTransit {
  key: string;
  coreVault: string;
  spokeVault: string;
  receiver: string;
  spokeIndex: number;
  transitId: string;
  attempts: number;
  nextAttemptAt: number;
  acknowledgement?: { payload: string; sequence: string; nonce: number; consistencyLevel: number; timestamp: number };
}

export class PendingTransits {
  readonly entries = new Map<string, PendingTransit>();
  private readonly completed = new Set<string>();
  private draining = false;

  constructor(private readonly file: string, private readonly deployment: string, private readonly now = Date.now) {
    if (!existsSync(file)) return;
    const saved = JSON.parse(readFileSync(file, "utf8"));
    if (saved.deployment !== deployment) return;
    for (const entry of saved.pending) this.entries.set(entry.key, entry);
    for (const key of saved.completed) this.completed.add(key);
  }

  add(entry: Omit<PendingTransit, "attempts" | "nextAttemptAt">) {
    if (this.entries.has(entry.key) || this.completed.has(entry.key)) return;
    this.entries.set(entry.key, { ...entry, attempts: 0, nextAttemptAt: 0 });
    this.save();
  }

  save() {
    const temporary = `${this.file}.tmp`;
    writeFileSync(temporary, JSON.stringify({ deployment: this.deployment, pending: [...this.entries.values()], completed: [...this.completed] }));
    renameSync(temporary, this.file);
  }

  async drain(attempt: (entry: PendingTransit) => Promise<boolean>, onError: (error: unknown) => void) {
    if (this.draining) return;
    this.draining = true;
    try {
      for (const entry of this.entries.values()) {
        if (this.now() < entry.nextAttemptAt) continue;
        try {
          if (await attempt(entry)) {
            this.entries.delete(entry.key);
            this.completed.add(entry.key);
            this.save();
            continue;
          }
        } catch (error) {
          onError(error);
        }
        entry.attempts++;
        entry.nextAttemptAt = this.now() + Math.min(30_000, 500 * 2 ** Math.min(entry.attempts - 1, 6));
        this.save();
      }
    } finally {
      this.draining = false;
    }
  }
}
