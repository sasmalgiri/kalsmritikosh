// AI Included relay tests — Node's built-in runner, a fake Apple and fake providers. Run: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { handle, publicSellable, purgeOld, type Env, type Deps } from "../src/index.ts";
import { MemoryStore } from "../src/store.ts";
import { APPLE_STATUS, MONTHLY_QUESTIONS, PRODUCTS, grantsAI, monthKey, sellable, usd } from "../src/policy.ts";

const NOW = new Date("2026-11-15T10:00:00Z");
const SUB = "2000000123456789";

async function pkcs8Pem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = ""; for (const b of der) s += String.fromCharCode(b);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(s)}\n-----END PRIVATE KEY-----`;
}
const fakeJWS = (payload: object) => `e30.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.sig`;

interface World {
  appleCalls: number;
  providerBodies: string[];
  appleStatus: number;
  productId: string;
  expires: number;
  productionHasIt: boolean;
  providerStatus: number;
  usage: { input_tokens: number; output_tokens: number };
  topUps: Record<string, { productId: string; purchaseDate: number; revocationDate?: number }>;
}

function world(over: Partial<World> = {}): World {
  return { appleCalls: 0, providerBodies: [], appleStatus: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly,
           expires: NOW.getTime() + 20 * 86_400_000, productionHasIt: true, providerStatus: 200,
           usage: { input_tokens: 1000, output_tokens: 500 }, topUps: {}, ...over };
}

async function setup(w: World, envOver: Partial<Env> = {}) {
  const store = new MemoryStore();
  const env: Env = { DB: undefined as never, ANTHROPIC_API_KEY: "sk-test", GEMINI_API_KEY: "g-test", APPLE_ISSUER_ID: "iss",
                     APPLE_KEY_ID: "kid", APPLE_PRIVATE_KEY: await pkcs8Pem(), BUNDLE_ID: "ecosanskritiinnovation.Kalsmritikosh", ...envOver };
  const fetcher = async (url: string, init?: RequestInit): Promise<Response> => {
    if (url.includes("storekit")) {
      w.appleCalls += 1;
      const sandbox = url.includes("sandbox");
      if (!w.productionHasIt && !sandbox) return new Response("", { status: 404 });
      const tx = url.match(/transactions\/([^/?]+)/);
      if (tx) {
        const t = w.topUps[decodeURIComponent(tx[1])];
        if (!t) return new Response("", { status: 404 });
        return Response.json({ signedTransactionInfo: fakeJWS({ ...t, transactionId: decodeURIComponent(tx[1]), originalTransactionId: tx[1] }) });
      }
      return Response.json({ data: [{ lastTransactions: [{ status: w.appleStatus,
        signedTransactionInfo: fakeJWS({ productId: w.productId, originalTransactionId: SUB, transactionId: SUB, expiresDate: w.expires, purchaseDate: NOW.getTime() - 86_400_000 }) }] }] });
    }
    w.providerBodies.push(String(init?.body ?? ""));
    if (url.includes("anthropic")) {
      return new Response(JSON.stringify({ content: [{ type: "text", text: "ok" }], usage: w.usage }), { status: w.providerStatus });
    }
    return new Response(JSON.stringify({ candidates: [], usageMetadata: { promptTokenCount: 2000, candidatesTokenCount: 800 } }), { status: w.providerStatus });
  };
  const deps: Deps = { store, fetcher, now: () => NOW };
  return { store, env, deps };
}

const ask = (body: object, sub = SUB) => new Request("https://relay.test/v1/messages", { method: "POST", headers: { "x-kals-subscription": sub }, body: JSON.stringify(body) });
const question = { max_tokens: 100000, messages: [{ role: "user", content: "When was the invoice paid?" }] };

test("no subscription, a malformed id or an expired/billing-retry/revoked status: refused, nothing forwarded", async () => {
  for (const over of [{ appleStatus: APPLE_STATUS.expired }, { appleStatus: APPLE_STATUS.billingRetry }, { appleStatus: APPLE_STATUS.revoked },
                      { productId: "ecosanskritiinnovation.Kalsmritikosh.edition.monthly" }]) {
    const w = world(over); const s = await setup(w);
    assert.equal((await handle(ask(question), s.env, s.deps)).status, 402);
    assert.equal(w.providerBodies.length, 0);
  }
  const w = world(); const s = await setup(w);
  assert.equal((await handle(ask(question, "abc; drop table"), s.env, s.deps)).status, 402);
  assert.equal(w.appleCalls, 0);
});

test("an active subscriber is forwarded with the relay's model and output ceiling, and the actual cost is kept", async () => {
  const w = world(); const s = await setup(w);
  const res = await handle(ask({ ...question, model: "some-expensive-model" }), s.env, s.deps);
  assert.equal(res.status, 200);
  assert.equal(res.headers.get("x-kals-remaining"), String(MONTHLY_QUESTIONS - 1));
  const sent = JSON.parse(w.providerBodies[0]);
  assert.equal(sent.model, "claude-opus-5");
  assert.equal(sent.max_tokens, 4096);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 1000 * 5 + 500 * 25);
});

test("grace period still grants AI Included; production 404 falls back to sandbox; Apple is asked once per ten minutes", async () => {
  const w = world({ appleStatus: APPLE_STATUS.gracePeriod, productionHasIt: false }); const s = await setup(w);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200);
  const calls = w.appleCalls;
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200);
  assert.equal(w.appleCalls, calls, "cached");
});

test("300 a month, then a refusal; a verified top-up adds 200 once; a refunded top-up adds nothing", async () => {
  const w = world({ topUps: { "9001": { productId: PRODUCTS.aiTopUp200, purchaseDate: NOW.getTime() - 1000 },
                              "9002": { productId: PRODUCTS.aiTopUp200, purchaseDate: NOW.getTime() - 1000, revocationDate: NOW.getTime() } } });
  const s = await setup(w);
  s.store.usage.set(`${monthKey(NOW)}|${SUB}`, MONTHLY_QUESTIONS);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 429);
  const top = (id: string) => new Request("https://relay.test/v1/topup", { method: "POST", headers: { "x-kals-subscription": SUB }, body: JSON.stringify({ transactionId: id }) });
  const r1 = await (await handle(top("9001"), s.env, s.deps)).json() as { credited: boolean; remaining: { topUps: number } };
  assert.deepEqual([r1.credited, r1.remaining.topUps], [true, 200]);
  const r2 = await (await handle(top("9001"), s.env, s.deps)).json() as { credited: boolean };
  assert.equal(r2.credited, false, "a top-up is credited once");
  assert.equal((await handle(top("9002"), s.env, s.deps)).status, 400, "a refunded top-up is refused");
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200, "the top-up is used once the month's 300 are gone");
});

test("the hard cap is never exceeded, even with many requests at once; a refused request costs the subscriber nothing", async () => {
  const w = world({ usage: { input_tokens: 100, output_tokens: 100 } });
  const s = await setup(w, { ANTHROPIC_BUDGET_USD: "0.5" }); // room for a few worst cases only
  // A slow provider: every request has reserved before any has finished — the real concurrency case.
  const inner = s.deps.fetcher;
  s.deps.fetcher = async (u, i) => { if (!u.includes("storekit")) await new Promise((r) => setTimeout(r, 30)); return inner(u, i); };
  await handle(new Request("https://relay.test/v1/status", { headers: { "x-kals-subscription": SUB } }), s.env, s.deps); // warm the status cache
  const results = await Promise.all(Array.from({ length: 40 }, () => handle(ask(question), s.env, s.deps)));
  const ok = results.filter((r) => r.status === 200).length, paused = results.filter((r) => r.status === 503).length;
  assert.ok(ok > 0 && paused > 0, `${ok} ok, ${paused} paused`);
  assert.ok(await s.store.spent(monthKey(NOW), "anthropic") <= usd(0.5));
  const left = await s.store.remaining(monthKey(NOW), SUB, NOW);
  assert.equal(left.monthly, MONTHLY_QUESTIONS - ok, "paused requests gave their question back");
});

test("a provider failure gives the question and the money back", async () => {
  const w = world({ providerStatus: 500 }); const s = await setup(w);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 500);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 0);
  assert.equal((await s.store.remaining(monthKey(NOW), SUB, NOW)).monthly, MONTHLY_QUESTIONS);
});

test("transcription draws on the separate Gemini budget, which also has a hard cap", async () => {
  const w = world(); const s = await setup(w, { GEMINI_BUDGET_USD: "5" });
  const audio = Buffer.alloc(200_000, 1).toString("base64");
  const tr = () => new Request("https://relay.test/v1/transcribe", { method: "POST", headers: { "x-kals-subscription": SUB }, body: JSON.stringify({ audioBase64: audio, mimeType: "audio/m4a" }) });
  assert.equal((await handle(tr(), s.env, s.deps)).status, 200);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 0);
  assert.ok(await s.store.spent(monthKey(NOW), "gemini") > 0);
  const small = await setup(world(), { GEMINI_BUDGET_USD: "0.001" });
  assert.equal((await handle(tr(), small.env, small.deps)).status, 503);
});

test("nothing a request contains is stored — the store holds counts only", async () => {
  const w = world(); const s = await setup(w);
  const secret = "Meera Iyer was the source who handed over the ledger";
  await handle(ask({ messages: [{ role: "user", content: secret }] }), s.env, s.deps);
  const dump = JSON.stringify([...s.store.spend, ...s.store.usage, ...s.store.topups, ...s.store.status]);
  assert.ok(!dump.includes("Meera") && !dump.includes("ledger"));
});

test("new buyers are not offered AI Included once 90% of the month's budget is spent", async () => {
  assert.equal(sellable(usd(17), usd(20)), true);
  assert.equal(sellable(usd(18), usd(20)), false);
  const s = await setup(world());
  await s.store.reserveSpend(monthKey(NOW), "anthropic", usd(19), usd(20));
  const r = await (await publicSellable(s.env, s.deps)).json() as { sellable: boolean };
  assert.equal(r.sellable, false);
});

test("A3: a request from a blocked country is refused before Apple or a provider is asked", async () => {
  const w = world(); const s = await setup(w);
  const r = new Request("https://relay.test/v1/messages", { method: "POST", headers: { "x-kals-subscription": SUB, "cf-ipcountry": "ru" }, body: JSON.stringify(question) });
  const res = await handle(r, s.env, s.deps);
  assert.equal(res.status, 451);
  assert.equal(w.appleCalls + w.providerBodies.length, 0);
});

test("the subscription rules: only AI Included products grant it, revoked never does", () => {
  const tx = { productId: PRODUCTS.aiAnnual, originalTransactionId: "1", transactionId: "1", purchaseDate: 0, expiresDate: NOW.getTime() + 1 };
  assert.equal(grantsAI(APPLE_STATUS.active, tx, NOW), true);
  assert.equal(grantsAI(APPLE_STATUS.active, { ...tx, expiresDate: NOW.getTime() - 1 }, NOW), false);
  assert.equal(grantsAI(APPLE_STATUS.active, { ...tx, revocationDate: 1 }, NOW), false);
  assert.equal(grantsAI(APPLE_STATUS.active, { ...tx, storefront: "CHN" }, NOW), false, "A3: no AI where the storefront blocks it");
  assert.equal(grantsAI(APPLE_STATUS.active, { ...tx, storefront: "IND" }, NOW), true);
});

test("retention: counts older than 13 months, expired top-ups and day-old status answers are deleted", async () => {
  const s = await setup(world());
  s.store.usage.set(`2025-09|${SUB}`, 5); s.store.usage.set(`2025-10|${SUB}`, 7); s.store.usage.set(`${monthKey(NOW)}|${SUB}`, 1);
  s.store.spend.set("2025-09|anthropic", 100); s.store.spend.set(`${monthKey(NOW)}|anthropic`, 10);
  s.store.topups.set("old", { sub: SUB, purchasedAt: NOW.getTime() - 800 * 86_400_000, remaining: 3 });
  s.store.topups.set("new", { sub: SUB, purchasedAt: NOW.getTime() - 10 * 86_400_000, remaining: 200 });
  s.store.status.set("x", { active: true, checkedAt: NOW.getTime() - 2 * 86_400_000 });
  await purgeOld(s.deps);
  assert.deepEqual([...s.store.usage.keys()].sort(), [`2025-10|${SUB}`, `${monthKey(NOW)}|${SUB}`]);
  assert.deepEqual([...s.store.spend.keys()], [`${monthKey(NOW)}|anthropic`]);
  assert.deepEqual([...s.store.topups.keys()], ["new"]);
  assert.equal(s.store.status.size, 0);
});
