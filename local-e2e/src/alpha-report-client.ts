import {request} from "node:http";

/**
 * POSTs the loopback alpha API `/report`. A mainnet report waits for Robinhood finality plus a guardian-signed VAA
 * (~15 minutes measured), longer than the global fetch's fixed 300 s headers timeout, so this uses node:http with an
 * explicit deadline above the API's own 30-minute wait.
 */
export function postReport(): Promise<{status: number; body: any}> {
  return new Promise((resolve, reject) => {
    const call = request({
      host: "127.0.0.1",
      port: Number(process.env.ALPHA_API_PORT ?? "8787"),
      path: "/report",
      method: "POST",
      headers: {authorization: `Bearer ${process.env.ALPHA_API_TOKEN}`},
      timeout: 35 * 60 * 1000,
    }, (response) => {
      let text = "";
      response.setEncoding("utf8");
      response.on("data", (chunk) => text += chunk);
      response.on("end", () => {
        try {resolve({status: response.statusCode ?? 0, body: JSON.parse(text)});} catch {resolve({status: response.statusCode ?? 0, body: undefined});}
      });
    });
    call.on("timeout", () => call.destroy(new Error("report request timed out")));
    call.on("error", reject);
    call.end();
  });
}
