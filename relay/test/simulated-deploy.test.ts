// Unified path R2-E (SHIP-10, SHIP-13, PERF-12; owner 2026-11-22 round 2) — SIMULATED staging deploy of the relay,
// in-process: a fake Apple and a fake Anthropic (no network), a MemoryStore standing in for D1. It observes the paid
// plan's send and metering, rehearses deploy → rollback (the store's counts survive both; the schema is additive
// only), and checks the operator health counters are content-free. Real staging/production deploys, the host in the
// signed build and a real paid send are still needed for release. Run: npm test (Node's built-in runner).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { handle, type Env, type Deps } from "../src/index.ts";
import { HealthCounters, operatorAllowed } from "../src/health.ts";
import { MemoryStore } from "../src/store.ts";
import { SIGNED_TRANSACTION_HEADER, VerificationCache } from "../src/jws.ts";
import { APPLE_STATUS, PRODUCTS, monthKey } from "../src/policy.ts";

const NOW = new Date("2026-11-22T10:00:00Z");
const DAY = 86_400_000;
const SUB = "2000000123456789";
const BUNDLE = "ecosanskritiinnovation.Kalsmritikosh";
const CHAIN = JSON.parse(readFileSync(new URL("./fixtures/test-signing-chain.json", import.meta.url), "utf8")) as Record<string, string>;
const fakeJWS = (payload: object) => `e30.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.sig`;

async function pkcs8Pem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = ""; for (const b of der) s += String.fromCharCode(b);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(s)}\n-----END PRIVATE KEY-----`;
}

async function signTx(): Promise<string> {
  const header = { alg: "ES256", x5c: [CHAIN.leaf, CHAIN.intermediate, CHAIN.root] };
  const payload = { originalTransactionId: SUB, transactionId: "2000000999999999", bundleId: BUNDLE, environment: "Production",
                    productId: PRODUCTS.aiMonthly, purchaseDate: NOW.getTime() - DAY, expiresDate: NOW.getTime() + 20 * DAY,
                    signedDate: NOW.getTime() - 3_600_000 };
  const input = `${Buffer.from(JSON.stringify(header)).toString("base64url")}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}`;
  const key = await crypto.subtle.importKey("pkcs8", Buffer.from(CHAIN.leafKeyPkcs8, "base64"), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${Buffer.from(sig).toString("base64url")}`;
}

/** One simulated deployment: a version label, its env, and the shared store (D1 survives a worker rollback). */
async function deployment(version: string, store: MemoryStore, forwarded: string[]) {
  const env: Env = { DB: undefined as never, ANTHROPIC_API_KEY: "sk-sim", GEMINI_API_KEY: "g-sim", APPLE_ISSUER_ID: "iss", APPLE_KEY_ID: "kid",
                     APPLE_PRIVATE_KEY: await pkcs8Pem(), BUNDLE_ID: BUNDLE, OPERATOR_TOKEN: "op-secret-sim" };
  const fetcher = async (url: string, init?: RequestInit): Promise<Response> => {
    if (url.includes("storekit")) {
      return Response.json({ data: [{ lastTransactions: [{ status: APPLE_STATUS.active,
        signedTransactionInfo: fakeJWS({ productId: PRODUCTS.aiMonthly, originalTransactionId: SUB, transactionId: SUB,
                                         expiresDate: NOW.getTime() + 20 * DAY, purchaseDate: NOW.getTime() - DAY }) }] }] });
    }
    forwarded.push(`${version}:${String(init?.body ?? "").length}`);
    return new Response(JSON.stringify({ content: [{ type: "text", text: "SIMULATED reply" }], usage: { input_tokens: 1000, output_tokens: 500 } }), { status: 200 });
  };
  const deps: Deps = { store, fetcher, now: () => NOW, appleRoots: [CHAIN.root], verified: new VerificationCache() };
  return { version, env, deps };
}

const ask = (cred: string) => new Request("https://relay.simulated.invalid/v1/messages", {
  method: "POST", headers: { [SIGNED_TRANSACTION_HEADER]: cred },
  body: JSON.stringify({ max_tokens: 2000, messages: [{ role: "user", content: "SIMULATED question about the ledger" }] }),
});

test("SIMULATED staging: a paid-plan send is forwarded once and metered; deploy then rollback keeps the counts", async () => {
  const store = new MemoryStore();
  const forwarded: string[] = [];
  const cred = await signTx();
  const v1 = await deployment("v1", store, forwarded);
  const r1 = await handle(ask(cred), v1.env, v1.deps);
  assert.equal(r1.status, 200, "v1 answers");
  const spentAfterV1 = await store.spent(monthKey(NOW), "anthropic");
  assert.ok(spentAfterV1 > 0, "the send was metered");

  const v2 = await deployment("v2", store, forwarded);            // the rollout
  assert.equal((await handle(ask(cred), v2.env, v2.deps)).status, 200, "v2 answers");
  const spentAfterV2 = await store.spent(monthKey(NOW), "anthropic");
  assert.ok(spentAfterV2 > spentAfterV1);

  const back = await deployment("v1-rollback", store, forwarded); // wrangler rollback: same store, older code
  assert.equal((await handle(ask(cred), back.env, back.deps)).status, 200, "the rolled-back version still answers");
  assert.ok(await store.spent(monthKey(NOW), "anthropic") > spentAfterV2, "no count was lost across deploy and rollback");
  assert.equal(forwarded.length, 3, "exactly one forward per send");
});

test("SIMULATED rollout safety: the relay's schema is additive only (a rollback never needs a destructive migration)", () => {
  const sql = readFileSync(new URL("../schema.sql", import.meta.url), "utf8");
  assert.ok(!/\bdrop\s+(table|index|column)\b/i.test(sql), "no DROP");
  assert.ok(!/\balter\s+table\b[^;]*\b(drop|rename)\b/i.test(sql), "no destructive ALTER");
  for (const m of sql.matchAll(/\bcreate\s+(table|index)\s+(?!if\s+not\s+exists\b)\w+/gi)) assert.fail(`CREATE without IF NOT EXISTS: ${m[0]}`);
});

test("SIMULATED operator health: counts only, no body, credential or account; the route needs the operator token", () => {
  const h = new HealthCounters(NOW);
  h.begin(); h.end("/v1/messages", 200, 420);
  h.begin(); h.end("/v1/messages/../secret?account=2000000123456789", 402, 12);
  const text = JSON.stringify(h.snapshot());
  assert.ok(!text.includes(SUB) && !text.includes("secret"), "no account or path content");
  assert.equal(h.snapshot().routes["other"].count, 1, "unknown paths are folded into 'other'");
  assert.ok(operatorAllowed("op-secret-sim", "op-secret-sim"));
  assert.ok(!operatorAllowed("op-secret-sin", "op-secret-sim") && !operatorAllowed(null, "op-secret-sim") && !operatorAllowed("x", undefined));
});
