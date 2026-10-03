import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { logger, redactUrls, safeConsole } from "../src/log.ts";
import { explain } from "../src/chain.ts";

const cases = [
  ["https://rpc.example.invalid/v2/SYNTHETIC_PATH", "<redacted-url>"],
  ["https://rpc.example.invalid?apiKey=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://rpc.example.invalid#SYNTHETIC_FRAGMENT", "<redacted-url>"],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid/rpc?apiKey=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid", "<redacted-url>"],
  ["http://SYNTHETIC_USER:p%40SYNTHETIC_PASSWORD@[::1]:8545", "<redacted-url>"],
  ["HTTPS://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid:443#SYNTHETIC_FRAGMENT", "<redacted-url>"],
  ["https://rpc.example.invalid/rpc(foo)?apiKey=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://rpc.example.invalid/rpc'foo\"bar`baz?apiKey=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://rpc.example.invalid/rpc[foo]{bar}?apiKey=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://rpc.example.invalid/rpc(foo)?apiKey=SYNTHETIC_QUERY#SYNTHETIC_FRAGMENT).,;!", "<redacted-url>"],
  ["wss://SYNTHETIC_USER:SYNTHETIC_PASSWORD@[::1]:8545/rpc(foo)?key=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://USER:PASS@%65xample.com/a?key=SECRET", "<redacted-url>"],
  ["https://%65xample.com/a?key=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://例え.テスト/a?key=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@例え.テスト/a", "<redacted-url>"],
  ["https://xn--r8jz45g.xn--zckzah/a", "<redacted-url>"],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@", "<redacted-url>"],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD", "<redacted-url>"],
  ["ws://SYNTHETIC_USER@/a?key=SYNTHETIC_QUERY", "<redacted-url>"],
  ["https://", "<redacted-url>"],
  ["https://localhost.evil.invalid/a", "<redacted-url>"],
  ["http://127.0.0.1.evil.invalid/a", "<redacted-url>"],
  ["https://%6cocalhost/a", "<redacted-url>"],
  ["http://[::1%25lo0]/a", "<redacted-url>"],
  ["https://SYNTHETIC_USER:SYNTHETIC_PASSWORD@[fe80::1%25en0]/a", "<redacted-url>"],
  ["http://[::ffff:127.0.0.1]:8545/a", "<redacted-url>"],
  ["http://[::1]:8545@evil.invalid/a", "<redacted-url>"],
  ["http://SYNTHETIC_USER@localhost:8545/a", "<redacted-url>"],
  ["https://localhost:443evil/a", "<redacted-url>"],
  ["https://localhost:443\\@evil.invalid/a", "<redacted-url>"],
  ["WS://rpc.example.invalid/a", "<redacted-url>"],
  ["WSS://rpc.example.invalid/a", "<redacted-url>"],
  ["https://rpc.example.invalid/a\u001b[0m", "<redacted-url>"],
  ["http://localhost:8545/http://SYNTHETIC_USER:PASS@evil.invalid/a", "<redacted-url>"],
  ["http://127.0.0.1:8545", "http://127.0.0.1:8545"],
  ["http://localhost", "http://localhost"],
  ["https://localhost:443/a?key=local#debug", "https://localhost:443/a?key=local#debug"],
  ["ws://[::1]:8545/a", "ws://[::1]:8545/a"],
  ["WSS://LOCALHOST:9999/a", "WSS://LOCALHOST:9999/a"],
  ["http://127.0.0.1/a", "http://127.0.0.1/a"],
  ["https://[::1]", "https://[::1]"],
] as const;
const input = cases.map(([url]) => `Endpoint: ${url}`).join("\n") + "\n";
const expected = cases.map(([, url]) => `Endpoint: ${url}`).join("\n") + "\n";
assert.equal(redactUrls(input), expected);
assert.equal(redactUrls(expected), expected);
assert.equal(explain(new Error(cases[12][0])), "Error: <redacted-url>");
assert.equal(redactUrls(`'${cases[0][0]}' (${cases[0][0]}) "${cases[0][0]}"`),
  "'<redacted-url> (<redacted-url> \"<redacted-url>");

const directory = mkdtempSync(join(tmpdir(), "local-e2e-redaction-"));
try {
  const script = fileURLToPath(new URL("./redact-urls.sh", import.meta.url));
  const logfile = join(directory, "fork.log");
  const result = spawnSync("bash", ["-c", 'source "$1"; redact_urls | tee "$2"', "check", script, logfile], {
    input,
    encoding: "utf8",
  });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, expected);
  assert.equal(readFileSync(logfile, "utf8"), expected);
  const cLocale = spawnSync("bash", ["-c", 'source "$1"; redact_urls', "check", script], {
    input, encoding: "utf8", env: {...process.env, LC_ALL: "C"},
  });
  assert.equal(cLocale.status, 0, cLocale.stderr);
  assert.equal(cLocale.stdout, expected);
  const wrapper = fileURLToPath(new URL("../../script/alpha-safe.sh", import.meta.url));
  const failed = spawnSync("bash", [wrapper, "node", "-e", `console.log(${JSON.stringify(input)}); console.error(${JSON.stringify(input)}); process.exit(17)`], {encoding: "utf8"});
  assert.equal(failed.status, 17);
  assert.equal(failed.stdout, expected + "\n" + expected + "\n");
  assert.equal(failed.stderr, "");
  for (const path of ["/v2/SYNTHETIC_PATH", "/rpc(foo)", "/rpc'foo\"bar", "/rpc[foo]", "/rpc(foo).,;!"]) {
    const castFailure = spawnSync("bash", [wrapper, "cast", "chain-id", "--rpc-url", `http://SYNTHETIC_USER:SYNTHETIC_PASSWORD@rpc.example.invalid:1${path}?key=SYNTHETIC_QUERY#SYNTHETIC_FRAGMENT`], {encoding: "utf8"});
    assert.notEqual(castFailure.status, 0);
    assert.ok(!`${castFailure.stdout}${castFailure.stderr}`.includes("SYNTHETIC_"));
  }
  const runtimeFailure = spawnSync(process.execPath, ["--import", "tsx", "--input-type=module", "-e",
    `import {runMain} from ${JSON.stringify(fileURLToPath(new URL("../src/chain.ts", import.meta.url)))}; await runMain(async () => {throw new Error(${JSON.stringify(input)});});`], {encoding: "utf8", cwd: fileURLToPath(new URL("..", import.meta.url))});
  assert.equal(runtimeFailure.status, 1);
  assert.equal(runtimeFailure.stderr, `Error: ${expected}\n`);
} finally {
  rmSync(directory, { recursive: true, force: true });
}

const output: string[] = [];
const original = { log: console.log, warn: console.warn, error: console.error };
try {
  console.log = console.warn = console.error = (line: string) => { output.push(line); };
  const log = logger("check");
  log.info(input, { rpc: cases[3][0] });
  log.warn(input, { rpc: cases[4][0] });
  log.error(input, { rpc: cases[6][0] });
  log.child("child").info(input);
  safeConsole.log("%s", input);
  safeConsole.warn({ rpc: cases[12][0] });
  safeConsole.error(new Error(cases[12][0]));
} finally {
  Object.assign(console, original);
}
assert.equal(output.length, 7);
assert.ok(output.every((line) => !/SYNTHETIC_|USER|PASS|SECRET/.test(line)));
console.log(`PASS: ${cases.length} URL cases; shell stdout/disk, wrapper exit status, TypeScript, errors, and all console/logger levels`);
