// Structured, readable console logs: `HH:MM:SS component  message  key=value ...`.

const COLORS = process.stdout.isTTY && !process.env.NO_COLOR;
const paint = (code: number, text: string) => (COLORS ? `\x1b[${code}m${text}\x1b[0m` : text);

export const dim = (text: string) => paint(2, text);
export const bold = (text: string) => paint(1, text);
export const green = (text: string) => paint(32, text);
export const red = (text: string) => paint(31, text);
export const yellow = (text: string) => paint(33, text);
export const cyan = (text: string) => paint(36, text);

type Fields = Record<string, unknown>;

function formatValue(value: unknown): string {
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "string") return value;
  return JSON.stringify(value, (_, v) => (typeof v === "bigint" ? v.toString() : v));
}

function formatFields(fields?: Fields): string {
  if (!fields) return "";
  return Object.entries(fields)
    .filter(([, v]) => v !== undefined)
    .map(([k, v]) => `${dim(`${k}=`)}${formatValue(v)}`)
    .join(" ");
}

function clock(): string {
  return new Date().toISOString().slice(11, 19);
}

export interface Logger {
  info(message: string, fields?: Fields): void;
  warn(message: string, fields?: Fields): void;
  error(message: string, fields?: Fields): void;
  child(component: string): Logger;
}

export function logger(component: string, quiet = false): Logger {
  const tag = cyan(component.padEnd(9));
  const line = (level: string, message: string, fields?: Fields) =>
    `${dim(clock())} ${tag} ${level}${message} ${formatFields(fields)}`.trimEnd();
  return {
    info: (message, fields) => {
      if (!quiet) console.log(line("", message, fields));
    },
    warn: (message, fields) => console.warn(line(yellow("warn "), message, fields)),
    error: (message, fields) => console.error(line(red("error "), message, fields)),
    child: (name) => logger(name, quiet),
  };
}

/** USDC-style fixed point for logs: 6 decimals by default. */
export function units(value: bigint, decimals = 6, digits = decimals): string {
  const negative = value < 0n;
  const abs = negative ? -value : value;
  const base = 10n ** BigInt(decimals);
  const whole = abs / base;
  const fraction = (abs % base).toString().padStart(decimals, "0").slice(0, digits);
  return `${negative ? "-" : ""}${whole.toLocaleString("en-US")}${digits > 0 ? `.${fraction}` : ""}`;
}
