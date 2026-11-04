// AI relay tests — Node's built-in runner, a fake Apple and fake providers. Run: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { appleNotification, handle, publicSellable, purgeOld, type Env, type Deps } from "../src/index.ts";
import { MemoryStore } from "../src/store.ts";
import {
  ANTHROPIC_RATES, APPLE_STATUS, PLANS, PRODUCTS, accountToken, allowancePeriod, anthropicCost, creditsFor, dayKey,
  grantedTier, monthKey, refundSplit, sellable, usd,
} from "../src/policy.ts";

const NOW = new Date("2026-11-15T10:00:00Z");
const DAY = 86_400_000;
const SUB = "2000000123456789";
const OPUS = ANTHROPIC_RATES["claude-opus-5"];

async function pkcs8Pem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = ""; for (const b of der) s += String.fromCharCode(b);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(s)}\n-----END PRIVATE KEY-----`;
}
const fakeJWS = (payload: object) => `e30.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.sig`;

interface Pack { productId: string; purchaseDate: number; revocationDate?: number; appAccountToken?: string }
interface World {
  appleCalls: number;
  providerBodies: string[];
  subs: { status: number; productId: string; purchaseDate: number; expires: number }[];
  productionHasIt: boolean;
  providerStatus: number;
  usage: Record<string, unknown>;
  packs: Record<string, Pack>;
  now: Date;
}

function world(over: Partial<World> = {}): World {
  return { appleCalls: 0, providerBodies: [], productionHasIt: true, providerStatus: 200, now: NOW,
           subs: [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly, purchaseDate: NOW.getTime() - DAY, expires: NOW.getTime() + 20 * DAY }],
           usage: { input_tokens: 1000, output_tokens: 500 }, packs: {}, ...over };
}

async function setup(w: World, envOver: Partial<Env> = {}) {
  const store = new MemoryStore();
  const env: Env = { DB: undefined as never, ANTHROPIC_API_KEY: "sk-test", GEMINI_API_KEY: "g-test", APPLE_ISSUER_ID: "iss",
                     APPLE_KEY_ID: "kid", APPLE_PRIVATE_KEY: await pkcs8Pem(), BUNDLE_ID: "ecosanskritiinnovation.Kalsmritikosh", ...envOver };
  const fetcher = async (url: string, init?: RequestInit): Promise<Response> => {
    if (url.includes("storekit")) {
      w.appleCalls += 1;
      if (!w.productionHasIt && !url.includes("sandbox")) return new Response("", { status: 404 });
      const tx = url.match(/transactions\/([^/?]+)/);
      if (tx) {
        const id = decodeURIComponent(tx[1]);
        const t = w.packs[id];
        if (!t) return new Response("", { status: 404 });
        return Response.json({ signedTransactionInfo: fakeJWS({ ...t, transactionId: id, originalTransactionId: id }) });
      }
      return Response.json({ data: [{ lastTransactions: w.subs.map((s) => ({ status: s.status,
        signedTransactionInfo: fakeJWS({ productId: s.productId, originalTransactionId: SUB, transactionId: SUB, expiresDate: s.expires, purchaseDate: s.purchaseDate }) })) }] });
    }
    w.providerBodies.push(String(init?.body ?? ""));
    if (url.includes("anthropic")) {
      return new Response(JSON.stringify({ content: [{ type: "text", text: "ok" }], usage: w.usage }), { status: w.providerStatus });
    }
    return new Response(JSON.stringify({ candidates: [], usageMetadata: { promptTokenCount: 2000, candidatesTokenCount: 800 } }), { status: w.providerStatus });
  };
  const deps: Deps = { store, fetcher, now: () => w.now };
  return { store, env, deps };
}

const post = (path: string, body: object, headers: Record<string, string> = {}, sub = SUB) =>
  new Request(`https://relay.test${path}`, { method: "POST", headers: { "x-kals-subscription": sub, ...headers }, body: JSON.stringify(body) });
const ask = (body: object, sub = SUB, headers: Record<string, string> = {}) => post("/v1/messages", body, headers, sub);
const question = { max_tokens: 9000, messages: [{ role: "user", content: "When was the invoice paid?" }] };
const kals = async (r: Response) => ((await r.json()) as { kals: Record<string, number> }).kals;
const period = (w: World) => allowancePeriod(w.subs[0].purchaseDate, w.subs[0].expires, w.now.getTime()).key;
const status = (s: Awaited<ReturnType<typeof setup>>) => handle(post("/v1/status", {}), s.env, s.deps);

test("no AI plan, Workbench only, a malformed id or an expired/billing-retry/revoked status: refused, nothing forwarded", async () => {
  for (const over of [{ status: APPLE_STATUS.expired }, { status: APPLE_STATUS.billingRetry }, { status: APPLE_STATUS.revoked },
                      { productId: PRODUCTS.workbenchMonthly }]) {
    const w = world(); w.subs = [{ ...w.subs[0], ...over }]; const s = await setup(w);
    assert.equal((await handle(ask(question), s.env, s.deps)).status, 402);
    assert.equal(w.providerBodies.length, 0);
  }
  const w = world(); const s = await setup(w);
  assert.equal((await handle(ask(question, "abc; drop table"), s.env, s.deps)).status, 402);
  assert.equal(w.appleCalls, 0);
});

test("forwarded with the relay's model and output ceiling; the ACTUAL cost is charged in whole credits and the rest refunded", async () => {
  const w = world(); const s = await setup(w);
  const res = await handle(ask({ ...question, max_tokens: 100000, model: "some-expensive-model", output_config: { effort: "medium", format: { x: 1 } }, tools: [{ name: "t" }] }), s.env, s.deps);
  assert.equal(res.status, 200);
  const sent = JSON.parse(w.providerBodies[0]);
  assert.equal(sent.model, "claude-opus-5");
  assert.equal(sent.max_tokens, 24000);
  assert.deepEqual(sent.output_config, { effort: "medium" }, "only the effort is forwarded");
  assert.equal(sent.tools, undefined);
  const body = await res.json() as { content: unknown[]; kals: Record<string, number> };
  assert.ok(Array.isArray(body.content), "Anthropic's reply is passed through");
  // 1,000 in × $5/MTok + 500 out × $25/MTok = $0.0175 → 2 credits (rounded up).
  assert.equal(body.kals.charged, 2);
  assert.ok(body.kals.reserved > body.kals.charged, "the worst case was reserved, then the rest refunded");
  assert.equal(body.kals.allowanceLeft, PLANS.ai.monthlyCredits - 2);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 1000 * 5 + 500 * 25, "the cap counts real micro-dollars");
});

test("the price table: cache writes 1.25×/2×, reads 0.1×, thinking billed as output, batch half; at least one credit", () => {
  assert.equal(anthropicCost({ input_tokens: 1_000_000 }, OPUS), usd(5));
  assert.equal(anthropicCost({ output_tokens: 1_000_000 }, OPUS), usd(25));
  assert.equal(anthropicCost({ cache_creation_input_tokens: 1_000_000, cache_creation: { ephemeral_5m_input_tokens: 1_000_000, ephemeral_1h_input_tokens: 0 } }, OPUS), usd(6.25));
  assert.equal(anthropicCost({ cache_creation_input_tokens: 1_000_000, cache_creation: { ephemeral_5m_input_tokens: 0, ephemeral_1h_input_tokens: 1_000_000 } }, OPUS), usd(10));
  assert.equal(anthropicCost({ cache_creation_input_tokens: 1_000_000 }, OPUS), usd(10), "no split: the dearer 1-hour rate");
  assert.equal(anthropicCost({ cache_read_input_tokens: 1_000_000 }, OPUS), usd(0.5));
  assert.equal(anthropicCost({ input_tokens: 1_000_000, output_tokens: 1_000_000 }, OPUS, true), usd(15));
  assert.equal(creditsFor(1), 1);
  assert.equal(creditsFor(10_000), 1);
  assert.equal(creditsFor(10_001), 2);
});

test("a reply with cache usage is charged by the real split", async () => {
  const w = world({ usage: { input_tokens: 2_000, cache_read_input_tokens: 100_000, cache_creation_input_tokens: 20_000,
                             cache_creation: { ephemeral_5m_input_tokens: 20_000, ephemeral_1h_input_tokens: 0 }, output_tokens: 3_000 } });
  const s = await setup(w);
  const big = { max_tokens: 9000, messages: [{ role: "user", content: [{ type: "text", text: "x".repeat(100_000), cache_control: { type: "ephemeral" } }] }] };
  const k = await kals(await handle(ask(big), s.env, s.deps));
  // 2,000×5 + 100,000×0.5 + 20,000×6.25 + 3,000×25 = 260,000 µ$ = 26 credits.
  assert.equal(k.charged, 26);
});

test("a provider failure refunds everything — credits and the cap", async () => {
  const w = world({ providerStatus: 500 }); const s = await setup(w);
  const res = await handle(ask(question), s.env, s.deps);
  assert.equal(res.status, 500);
  assert.equal(((await res.json()) as { kals: { charged: number } }).kals.charged, 0);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 0);
  const b = await s.store.balance(SUB, period(w), dayKey(NOW));
  assert.deepEqual([b.allowanceUsed, b.dailyUsed], [0, 0]);
});

test("the allowance first, then credit packs oldest first; refused with a clear code when the worst case does not fit", async () => {
  const token = await accountToken(SUB);
  const w = world({ packs: { "9001": { productId: PRODUCTS.credits500, purchaseDate: NOW.getTime() - 3 * DAY, appAccountToken: token },
                             "9002": { productId: PRODUCTS.credits2000, purchaseDate: NOW.getTime() - DAY, appAccountToken: token } } });
  const s = await setup(w);
  s.store.allowance.set(`${SUB}|${period(w)}`, PLANS.ai.monthlyCredits);   // the month's allowance is used up
  const refused = await handle(ask(question), s.env, s.deps);
  assert.equal(refused.status, 402);
  const err = (await refused.json() as { error: { code: string; estimate: number; balance: number } }).error;
  assert.equal(err.code, "credits-used");
  assert.ok(err.estimate > 0 && err.balance === 0 && w.providerBodies.length === 0, "nothing was sent");
  for (const id of ["9001", "9002"]) {
    const r = await (await handle(post("/v1/topup", { transactionId: id }), s.env, s.deps)).json() as { credited: boolean };
    assert.equal(r.credited, true);
  }
  const again = await (await handle(post("/v1/topup", { transactionId: "9001" }), s.env, s.deps)).json() as { credited: boolean };
  assert.equal(again.credited, false, "a pack is credited once");
  const k = await kals(await handle(ask(question), s.env, s.deps));
  assert.equal(k.charged, 2);
  assert.equal(k.topUps, 2500 - 2);
  assert.equal(s.store.topups.get("9001")!.remaining, 498, "the oldest pack is spent first");
  assert.equal(s.store.topups.get("9002")!.remaining, 2000, "the refund went back to the pack it came from");
});

test("credit packs never expire, belong to the subscription they were bought for, and a refunded pack loses its credits", async () => {
  const token = await accountToken(SUB);
  const w = world({ packs: {
    "7001": { productId: PRODUCTS.credits2000, purchaseDate: NOW.getTime() - 3 * 365 * DAY, appAccountToken: token },
    "7002": { productId: PRODUCTS.credits500, purchaseDate: NOW.getTime() - DAY, appAccountToken: await accountToken("999") },
    "7003": { productId: PRODUCTS.credits500, purchaseDate: NOW.getTime() - DAY, appAccountToken: token, revocationDate: NOW.getTime() },
  } });
  const s = await setup(w);
  assert.equal(((await (await handle(post("/v1/topup", { transactionId: "7001" }), s.env, s.deps)).json()) as { credited: boolean }).credited, true,
               "a three-year-old pack is still credited");
  assert.equal((await handle(post("/v1/topup", { transactionId: "7002" }), s.env, s.deps)).status, 400, "another subscription's pack");
  const rev = await (await handle(post("/v1/topup", { transactionId: "7003" }), s.env, s.deps)).json() as { revoked: boolean };
  assert.equal(rev.revoked, true);
  assert.equal((await s.store.balance(SUB, period(w), dayKey(NOW))).topUps, 2000);
  // Years later, through renewals: still there, still spendable.
  w.now = new Date(NOW.getTime() + 2 * 365 * DAY);
  w.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly, purchaseDate: w.now.getTime() - DAY, expires: w.now.getTime() + 29 * DAY }];
  await purgeOld(s.deps);
  s.store.status.clear();
  assert.equal((await kals(await status(s))).topUps, 2000, "retention never deletes a pack with credits left");
  // Apple refunds pack 7001: the notification is re-checked with Apple and the pack's credits are removed.
  w.packs["7001"].revocationDate = w.now.getTime();
  const note = { signedPayload: fakeJWS({ notificationType: "REFUND", data: { signedTransactionInfo: fakeJWS({ transactionId: "7001", originalTransactionId: "7001" }) } }) };
  assert.equal((await appleNotification(new Request("https://relay.test/v1/apple-notifications", { method: "POST", body: JSON.stringify(note) }), s.env, s.deps)).status, 200);
  assert.equal((await s.store.balance(SUB, period(w), dayKey(w.now))).topUps, 0);
  // A forged notification about an unrefunded pack changes nothing (Apple is asked, not believed).
  const s2 = await setup(world({ packs: { "8001": { productId: PRODUCTS.credits500, purchaseDate: NOW.getTime(), appAccountToken: token } } }));
  await handle(post("/v1/topup", { transactionId: "8001" }), s2.env, s2.deps);
  const forged = { signedPayload: fakeJWS({ notificationType: "REFUND", data: { signedTransactionInfo: fakeJWS({ transactionId: "8001" }) } }) };
  await appleNotification(new Request("https://relay.test/x", { method: "POST", body: JSON.stringify(forged) }), s2.env, s2.deps);
  assert.equal(s2.store.topups.get("8001")!.remaining, 500);
});

test("the global cap is never exceeded under 40 concurrent requests; refusals cost nothing; at 90 % reservations and sales stop", async () => {
  const w = world({ usage: { input_tokens: 100, output_tokens: 100 } });
  const s = await setup(w, { GLOBAL_CAP_USD: "5" });
  const inner = s.deps.fetcher;
  s.deps.fetcher = async (u, i) => { if (!u.includes("storekit")) await new Promise((r) => setTimeout(r, 30)); return inner(u, i); };
  await status(s); // warm the status cache
  const results = await Promise.all(Array.from({ length: 40 }, () => handle(ask(question), s.env, s.deps)));
  const ok = results.filter((r) => r.status === 200).length, paused = results.filter((r) => r.status === 503).length;
  assert.ok(ok > 0 && paused > 0, `${ok} ok, ${paused} paused`);
  assert.ok(await s.store.spent(monthKey(NOW), "anthropic") <= usd(5));
  assert.equal((await s.store.balance(SUB, period(w), dayKey(NOW))).allowanceUsed, ok * 1, "paused requests were charged nothing");
  // 90 %: no new reservation, AI plans not sold.
  assert.equal(sellable(usd(17), usd(20)), true);
  assert.equal(sellable(usd(18), usd(20)), false);
  const t = await setup(world());
  t.store.spend.set(`${monthKey(NOW)}|anthropic`, usd(18));
  assert.equal(((await (await publicSellable(t.env, t.deps)).json()) as { sellable: boolean }).sellable, false);
  const r = await handle(ask(question), t.env, t.deps);
  assert.equal(r.status, 503);
  assert.equal(((await r.json()) as { error: { code: string } }).error.code, "capacity-paused");
  // The owner raises the cap: open again.
  const u = await setup(world(), { GLOBAL_CAP_USD: "500" });
  u.store.spend.set(`${monthKey(NOW)}|anthropic`, usd(18));
  assert.equal((await handle(ask(question), u.env, u.deps)).status, 200);
});

test("the daily abuse limit and the per-request ceiling; a confirmed large read may use up to the plan's case limit", async () => {
  const w = world(); const s = await setup(w);
  s.store.daily.set(`${SUB}|${dayKey(NOW)}`, PLANS.ai.dailyCredits - 5);
  const r = await handle(ask(question), s.env, s.deps);
  assert.equal(r.status, 429);
  assert.equal(((await r.json()) as { error: { code: string } }).error.code, "daily-limit");
  // Tomorrow it resets.
  w.now = new Date(NOW.getTime() + DAY);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200);
  // A request whose worst case exceeds 400 credits: refused unless confirmed as a large read.
  const whole = { max_tokens: 20000, messages: [{ role: "user", content: "x".repeat(1_000_000) }] }; // ≈ 333k tokens → about 217 credits at worst
  const huge = { max_tokens: 20000, messages: [{ role: "user", content: [{ type: "text", text: "x".repeat(2_000_000), cache_control: { type: "ephemeral", ttl: "1h" } }] }] };
  const plain = await handle(ask(whole), s.env, s.deps);
  assert.equal(plain.status, 413, "an ordinary request is capped at 120,000 characters");
  const big = await handle(ask(whole, SUB, { "x-kals-large-read": "confirmed" }), s.env, s.deps);
  assert.equal(big.status, 200, "confirmed: within AI Included's case limit");
  const tooBig = await handle(ask(huge, SUB, { "x-kals-large-read": "confirmed" }), s.env, s.deps);
  assert.equal(tooBig.status, 413);
  const e = ((await tooBig.json()) as { error: { code: string; estimate: number } }).error;
  assert.equal(e.code, "too-costly");
  assert.ok(e.estimate > PLANS.ai.caseReadCredits);
  // AI Pro reads more at once.
  const pw = world(); pw.subs = [{ ...pw.subs[0], productId: PRODUCTS.proMonthly }];
  const p = await setup(pw);
  assert.equal((await handle(ask(huge, SUB, { "x-kals-large-read": "confirmed" }), p.env, p.deps)).status, 200);
});

test("yearly plans: the same monthly allowance every month from the purchase anniversary; grace never opens a new month", async () => {
  const start = Date.UTC(2026, 0, 31, 12);   // 31 January: months end on the 28th/30th/31st
  const exp = Date.UTC(2027, 0, 31, 12);
  assert.equal(allowancePeriod(start, exp, Date.UTC(2026, 1, 10)).key, "2026-01-31T12:00:00.000Z");
  assert.equal(allowancePeriod(start, exp, Date.UTC(2026, 1, 28, 12)).key, "2026-02-28T12:00:00.000Z");
  assert.equal(allowancePeriod(start, exp, Date.UTC(2026, 2, 31, 13)).key, "2026-03-31T12:00:00.000Z");
  assert.equal(allowancePeriod(start, exp, Date.UTC(2027, 0, 30)).key, "2026-12-31T12:00:00.000Z");
  assert.equal(allowancePeriod(start, exp, Date.UTC(2027, 1, 2)).key, "2026-12-31T12:00:00.000Z", "in grace: still the last month");
  const mStart = NOW.getTime() - 40 * DAY, mExp = NOW.getTime() - 10 * DAY;   // monthly, in grace
  assert.equal(allowancePeriod(mStart, mExp, NOW.getTime()).startsAt, mStart);

  const w = world(); w.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiAnnual, purchaseDate: NOW.getTime() - 45 * DAY, expires: NOW.getTime() + 320 * DAY }];
  const s = await setup(w);
  s.store.allowance.set(`${SUB}|${period(w)}`, PLANS.ai.monthlyCredits);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 402, "this month's allowance is used");
  w.now = new Date(NOW.getTime() + 31 * DAY); s.store.status.clear();
  const k = await kals(await handle(ask(question), s.env, s.deps));
  assert.equal(k.allowanceLeft, PLANS.ai.monthlyCredits - k.charged, "a new month: a fresh 2,000");
});

test("upgrade to AI Pro: 6,000 credits from the upgrade; Apple's grace keeps AI; Apple is asked once per ten minutes; sandbox fallback", async () => {
  const w = world(); w.subs = [
    { status: APPLE_STATUS.expired, productId: PRODUCTS.aiMonthly, purchaseDate: NOW.getTime() - 20 * DAY, expires: NOW.getTime() - DAY },
    { status: APPLE_STATUS.active, productId: PRODUCTS.proMonthly, purchaseDate: NOW.getTime() - DAY, expires: NOW.getTime() + 29 * DAY },
  ];
  const s = await setup(w);
  const k = await kals(await status(s));
  assert.deepEqual([k.plan, k.monthlyCredits, k.caseReadCredits], ["pro", 6000, 3000] as unknown[]);
  const g = world({ productionHasIt: false }); g.subs = [{ ...g.subs[0], status: APPLE_STATUS.gracePeriod, expires: NOW.getTime() - DAY }];
  const gs = await setup(g);
  assert.equal((await handle(ask(question), gs.env, gs.deps)).status, 200);
  const calls = g.appleCalls;
  assert.equal((await handle(ask(question), gs.env, gs.deps)).status, 200);
  assert.equal(g.appleCalls, calls, "cached");
});

test("transcription: Gemini's own cap, metered in credits", async () => {
  const w = world(); const s = await setup(w);
  const audio = Buffer.alloc(200_000, 1).toString("base64");
  const tr = () => post("/v1/transcribe", { audioBase64: audio, mimeType: "audio/m4a" });
  const res = await handle(tr(), s.env, s.deps);
  assert.equal(res.status, 200);
  assert.equal((await kals(res)).charged, 2, "2,000×3 + 800×10 = 14,000 µ$ → 2 credits");
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 0);
  assert.ok(await s.store.spent(monthKey(NOW), "gemini") > 0);
  const small = await setup(world(), { GEMINI_BUDGET_USD: "0.001" });
  assert.equal((await handle(tr(), small.env, small.deps)).status, 503);
});

test("nothing a request contains is stored — the store holds counts only", async () => {
  const w = world(); const s = await setup(w);
  const secret = "Meera Iyer was the source who handed over the ledger";
  await handle(ask({ messages: [{ role: "user", content: secret }] }), s.env, s.deps);
  const dump = JSON.stringify([...s.store.spend, ...s.store.allowance, ...s.store.daily, ...s.store.topups, ...s.store.status]);
  assert.ok(!dump.includes("Meera") && !dump.includes("ledger"));
});

test("A3: a request from a blocked country is refused before Apple or a provider is asked; blocked storefronts grant nothing", async () => {
  const w = world(); const s = await setup(w);
  const res = await handle(ask(question, SUB, { "cf-ipcountry": "ru" }), s.env, s.deps);
  assert.equal(res.status, 451);
  assert.equal(w.appleCalls + w.providerBodies.length, 0);
  const tx = { productId: PRODUCTS.aiAnnual, originalTransactionId: "1", transactionId: "1", purchaseDate: 0, expiresDate: NOW.getTime() + 1 };
  assert.equal(grantedTier(APPLE_STATUS.active, tx, NOW), "ai");
  assert.equal(grantedTier(APPLE_STATUS.active, { ...tx, productId: PRODUCTS.proAnnual }, NOW), "pro");
  assert.equal(grantedTier(APPLE_STATUS.active, { ...tx, productId: PRODUCTS.workbenchAnnual }, NOW), null);
  assert.equal(grantedTier(APPLE_STATUS.active, { ...tx, expiresDate: NOW.getTime() - 1 }, NOW), null);
  assert.equal(grantedTier(APPLE_STATUS.active, { ...tx, revocationDate: 1 }, NOW), null);
  assert.equal(grantedTier(APPLE_STATUS.active, { ...tx, storefront: "CHN" }, NOW), null);
  assert.equal(grantedTier(APPLE_STATUS.active, { ...tx, storefront: "IND" }, NOW), "ai");
});

test("settlement keeps the charge on the allowance first and refunds packs in reverse order", () => {
  assert.deepEqual(refundSplit(10, [{ id: "a", n: 5 }, { id: "b", n: 5 }], 12), { allowance: 0, topUps: [{ id: "b", n: 5 }, { id: "a", n: 3 }] });
  assert.deepEqual(refundSplit(10, [], 4), { allowance: 6, topUps: [] });
  assert.deepEqual(refundSplit(0, [{ id: "a", n: 7 }], 7), { allowance: 0, topUps: [] });
});

test("retention: counts older than 13 months, day counts after 40 days, empty old packs and day-old status answers are deleted", async () => {
  const s = await setup(world());
  s.store.allowance.set(`${SUB}|2025-09-03T00:00:00.000Z`, 5); s.store.allowance.set(`${SUB}|2025-10-03T00:00:00.000Z`, 7);
  s.store.spend.set("2025-09|anthropic", 100); s.store.spend.set(`${monthKey(NOW)}|anthropic`, 10);
  s.store.daily.set(`${SUB}|2026-09-01`, 3); s.store.daily.set(`${SUB}|${dayKey(NOW)}`, 3);
  s.store.topups.set("empty", { sub: SUB, productId: PRODUCTS.credits500, purchasedAt: NOW.getTime() - 800 * DAY, credits: 500, remaining: 0, revoked: false });
  s.store.topups.set("old-with-credits", { sub: SUB, productId: PRODUCTS.credits500, purchasedAt: NOW.getTime() - 800 * DAY, credits: 500, remaining: 3, revoked: false });
  s.store.status.set("x", { tier: "ai", anchor: 0, expires: 0, checkedAt: NOW.getTime() - 2 * DAY });
  await purgeOld(s.deps);
  assert.deepEqual([...s.store.allowance.keys()], [`${SUB}|2025-10-03T00:00:00.000Z`]);
  assert.deepEqual([...s.store.spend.keys()], [`${monthKey(NOW)}|anthropic`]);
  assert.deepEqual([...s.store.daily.keys()], [`${SUB}|${dayKey(NOW)}`]);
  assert.deepEqual([...s.store.topups.keys()], ["old-with-credits"]);
  assert.equal(s.store.status.size, 0);
});

test("the pack token is a stable RFC 4122 UUID derived from the subscription number", async () => {
  const t = await accountToken(SUB);
  assert.match(t, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
  assert.equal(t, await accountToken(SUB));
  assert.notEqual(t, await accountToken("2000000123456780"));
  console.log(`accountToken(${SUB}) = ${t}`);
});
