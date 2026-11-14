// AI relay tests — Node's built-in runner, a fake Apple and fake providers. Run: npm test
import { test } from "node:test";
import assert from "node:assert/strict";
import { appleNotification, handle, publicSellable, purgeOld, type Env, type Deps } from "../src/index.ts";
import { MemoryStore } from "../src/store.ts";
import { readFileSync } from "node:fs";
import { APPLE_ROOT_CA_G3, GRACE_TOLERANCE_MS, LEGACY_SUBSCRIPTION_HEADER, SIGNED_TRANSACTION_HEADER, VERIFY_TTL_MS, VerificationCache,
         verifySignedTransaction } from "../src/jws.ts";
import {
  ANTHROPIC_RATES, APPLE_STATUS, DEFAULT_ANTHROPIC_MODEL, FALLBACK_MODELS, dearestRates, ratesFor, reservationRates, CHARS_PER_TOKEN, IMAGE_TOKENS, LARGE_READ_MAX_INPUT_CHARS, MAX_OUTPUT_TOKENS, PLANS, PRODUCTS,
  TOKEN_OVERHEAD, accountToken, allowancePeriod, anthropicCost, creditsFor, dayKey, grantedTier, maxInputTokens, maxTokensForText,
  monthKey, monthlyAllowance, refundSplit, sellable, usd, worstCaseCost, SANDBOX_DAILY_CREDITS,
} from "../src/policy.ts";

const NOW = new Date("2026-11-15T10:00:00Z");
const DAY = 86_400_000;
const SUB = "2000000123456789";
/** Claude Opus 5 — the dearest fallback model: every reservation is made at these rates. */
const OPUS = ANTHROPIC_RATES["claude-opus-5"];
/** Claude Opus 5.5 — the relay's model: replies it answers are charged at these rates. */
const OPUS55 = ANTHROPIC_RATES["claude-opus-5-5"];

async function pkcs8Pem(): Promise<string> {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey));
  let s = ""; for (const b of der) s += String.fromCharCode(b);
  return `-----BEGIN PRIVATE KEY-----\n${btoa(s)}\n-----END PRIVATE KEY-----`;
}
const fakeJWS = (payload: object) => `e30.${Buffer.from(JSON.stringify(payload)).toString("base64url")}.sig`;

// SEC-05 — the app's credential: a StoreKit signed transaction. Tests sign with a TEST-ONLY chain
// (test/fixtures/test-signing-chain.json, made with openssl; never Apple's) whose root is injected as the
// trusted root; production trusts Apple Root CA - G3 only.
const CHAIN = JSON.parse(readFileSync(new URL("./fixtures/test-signing-chain.json", import.meta.url), "utf8")) as Record<string, string>;
const BUNDLE = "ecosanskritiinnovation.Kalsmritikosh";
async function signTx(over: Record<string, unknown> = {}, opts: { x5c?: string[]; key?: string } = {}): Promise<string> {
  const header = { alg: "ES256", x5c: opts.x5c ?? [CHAIN.leaf, CHAIN.intermediate, CHAIN.root] };
  const payload = { originalTransactionId: SUB, transactionId: "2000000999999999", bundleId: BUNDLE, environment: "Production",
                    productId: PRODUCTS.aiMonthly, purchaseDate: NOW.getTime() - DAY, expiresDate: NOW.getTime() + 20 * DAY,
                    signedDate: NOW.getTime() - 3_600_000, ...over };
  const input = `${Buffer.from(JSON.stringify(header)).toString("base64url")}.${Buffer.from(JSON.stringify(payload)).toString("base64url")}`;
  const key = await crypto.subtle.importKey("pkcs8", Buffer.from(opts.key ?? CHAIN.leafKeyPkcs8, "base64"), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(input));
  return `${input}.${Buffer.from(sig).toString("base64url")}`;
}
const CRED = await signTx();

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
  const deps: Deps = { store, fetcher, now: () => w.now, appleRoots: [CHAIN.root], verified: new VerificationCache() };
  return { store, env, deps };
}

const post = (path: string, body: object, headers: Record<string, string> = {}, cred = CRED) =>
  new Request(`https://relay.test${path}`, { method: "POST", headers: { [SIGNED_TRANSACTION_HEADER]: cred, ...headers }, body: JSON.stringify(body) });
const ask = (body: object, cred = CRED, headers: Record<string, string> = {}) => post("/v1/messages", body, headers, cred);
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
  assert.equal(sent.model, "claude-opus-5-5");
  assert.equal(sent.max_tokens, 24000);
  assert.deepEqual(sent.output_config, { effort: "medium" }, "only the effort is forwarded");
  assert.equal(sent.tools, undefined);
  const body = await res.json() as { content: unknown[]; kals: Record<string, number> };
  assert.ok(Array.isArray(body.content), "Anthropic's reply is passed through");
  // Opus 5.5: 1,000 in × $4/MTok + 500 out × $20/MTok = $0.014 → 2 credits (rounded up).
  assert.equal(body.kals.charged, 2);
  assert.ok(body.kals.reserved > body.kals.charged, "the worst case was reserved, then the rest refunded");
  assert.equal(body.kals.allowanceLeft, PLANS.ai.monthlyCredits - 2);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 1000 * 4 + 500 * 20, "the cap counts real micro-dollars");
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
  // Opus 5.5: 2,000×4 + 100,000×0.2 + 20,000×5 + 3,000×20 = 188,000 µ$ = 19 credits.
  assert.equal(k.charged, 19);
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
  // The app sends the renewed period's signed transaction (the old one has long expired and is refused).
  assert.equal((await status(s)).status, 402, "a two-year-old signed transaction is no credential");
  const renewed = await signTx({ purchaseDate: w.now.getTime() - DAY, expiresDate: w.now.getTime() + 29 * DAY, signedDate: w.now.getTime() - 3_600_000 });
  assert.equal((await kals(await handle(post("/v1/status", {}, {}, renewed), s.env, s.deps))).topUps, 2000, "retention never deletes a pack with credits left");
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
  const big = await handle(ask(whole, CRED, { "x-kals-large-read": "confirmed" }), s.env, s.deps);
  assert.equal(big.status, 200, "confirmed: within AI Included's case limit");
  const tooBig = await handle(ask(huge, CRED, { "x-kals-large-read": "confirmed" }), s.env, s.deps);
  assert.equal(tooBig.status, 413);
  const e = ((await tooBig.json()) as { error: { code: string; estimate: number } }).error;
  assert.equal(e.code, "too-costly");
  assert.ok(e.estimate > PLANS.ai.caseReadCredits);
  // AI Pro reads more at once.
  const pw = world(); pw.subs = [{ ...pw.subs[0], productId: PRODUCTS.proMonthly }];
  const p = await setup(pw);
  assert.equal((await handle(ask(huge, CRED, { "x-kals-large-read": "confirmed" }), p.env, p.deps)).status, 200);
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
  // A Sandbox (TestFlight / App Review) transaction is checked with the sandbox API only.
  const sandbox = await signTx({ environment: "Sandbox", expiresDate: NOW.getTime() - DAY });
  assert.equal((await handle(ask(question, sandbox), gs.env, gs.deps)).status, 200);
  const calls = g.appleCalls;
  assert.equal((await handle(ask(question, sandbox), gs.env, gs.deps)).status, 200);
  assert.equal(g.appleCalls, calls, "cached");
});

test("AI Pro yearly: 5,400 credits a month (owner decision 2026-11-04); AI Pro monthly 6,000; AI Included yearly 2,000", async () => {
  assert.equal(monthlyAllowance("pro", true), 5_400);
  assert.equal(monthlyAllowance("pro", false), 6_000);
  assert.equal(monthlyAllowance("ai", true), 2_000);
  assert.equal(monthlyAllowance("ai", false), 2_000);
  const y = world(); y.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.proAnnual, purchaseDate: NOW.getTime() - DAY, expires: NOW.getTime() + 364 * DAY }];
  const ys = await setup(y);
  const k = await kals(await status(ys));
  assert.deepEqual([k.plan, k.monthlyCredits, k.allowanceLeft], ["pro", 5400, 5400] as unknown[]);
  // The yearly allowance is what is reserved against: 5,400 used up refuses the next request.
  const used = await setup(y);
  used.store.allowance.set(`${SUB}|${period(y)}`, 5_400);
  assert.equal((await handle(ask(question), used.env, used.deps)).status, 402);
  const ai = world(); ai.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiAnnual, purchaseDate: NOW.getTime() - DAY, expires: NOW.getTime() + 364 * DAY }];
  assert.equal((await kals(await status(await setup(ai)))).monthlyCredits, 2000);
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
  const res = await handle(ask(question, CRED, { "cf-ipcountry": "ru" }), s.env, s.deps);
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

// The app sizes a request with the SAME estimator (Kalsmritikosh/Routing/Providers/Online/AIPricing.swift,
// checked by ci/guards/relay-host-match.sh); the golden numbers below are asserted on both sides
// (KalsmritikoshTests/AICreditsTests.swift, "estimator agrees with the relay").
test("the size estimator: 3 characters a token + 64, images at 1,600; golden reservations the app's mirror reproduces", () => {
  assert.equal(CHARS_PER_TOKEN, 3); assert.equal(TOKEN_OVERHEAD, 64); assert.equal(IMAGE_TOKENS, 1_600);
  assert.equal(maxTokensForText(0), 64);
  assert.equal(maxTokensForText(900_000), 300_064);
  assert.equal(maxInputTokens(10_000, 2), 3_334 + 64 + 3_200);
  assert.equal(creditsFor(worstCaseCost(maxInputTokens(900_000, 0), 24_000, OPUS, "1h")), 361);
  assert.equal(creditsFor(worstCaseCost(maxInputTokens(10_000, 2), 4_000, OPUS, "none")), 14);
  assert.equal(creditsFor(worstCaseCost(maxInputTokens(1, 0), 1_024, OPUS, "5m")), 3);
});

test("near the limit: the largest whole-case read the app offers on each plan is accepted, never too-large or too-costly", async () => {
  // The app's margin (AIPricing.caseReadMaskGrowth, caseReadTaskAllowanceCharacters): masking may grow the
  // case text by 5 %, the task after it is at most 20,000 characters, the output at the relay's ceiling.
  const maskGrowth = 1.05, taskAllowance = 20_000;
  for (const [tier, product] of [["ai", PRODUCTS.aiMonthly], ["pro", PRODUCTS.proMonthly]] as const) {
    const plan = PLANS[tier];
    // The most case text whose estimate is within the plan's whole-case limit: (limit − 64) × 3 characters.
    const caseChars = (plan.caseReadTokens - TOKEN_OVERHEAD) * CHARS_PER_TOKEN;
    assert.equal(maxTokensForText(caseChars), plan.caseReadTokens);
    const sentChars = Math.ceil(caseChars * maskGrowth) + taskAllowance;
    assert.ok(sentChars <= LARGE_READ_MAX_INPUT_CHARS, `${tier}: ${sentChars} characters fit the large-read size limit`);
    const worst = creditsFor(worstCaseCost(maxTokensForText(sentChars), MAX_OUTPUT_TOKENS, OPUS, "1h"));
    assert.ok(worst <= plan.caseReadCredits, `${tier}: worst case ${worst} credits fits ${plan.caseReadCredits}`);
    const w = world(); w.subs = [{ ...w.subs[0], productId: product }];
    const s = await setup(w);
    const body = { max_tokens: MAX_OUTPUT_TOKENS, messages: [{ role: "user", content: [
      { type: "text", text: "x".repeat(Math.ceil(caseChars * maskGrowth)), cache_control: { type: "ephemeral", ttl: "1h" } },
      { type: "text", text: "q".repeat(taskAllowance) }] }] };
    const r = await handle(ask(body, CRED, { "x-kals-large-read": "confirmed" }), s.env, s.deps);
    assert.equal(r.status, 200, `${tier}: the read the app offers is accepted`);
    const k = await kals(r);
    assert.equal(k.reserved, worst, `${tier}: the relay reserves what the app's mirror computes`);
  }
  // Past the size limit the relay still refuses (the app never offers such a read).
  const s = await setup(world());
  const over = { max_tokens: 4_000, messages: [{ role: "user", content: [{ type: "text", text: "x".repeat(LARGE_READ_MAX_INPUT_CHARS + 1) }] }] };
  const r = await handle(ask(over, CRED, { "x-kals-large-read": "confirmed" }), s.env, s.deps);
  assert.equal(r.status, 413);
});

// Package B (2026-11-06) — Claude Opus 5.5 on the relay.
test("Opus 5.5: the relay's model; $4 / $20, cache writes 1.25× / 2×, cache reads $0.20 (0.05×)", () => {
  assert.equal(DEFAULT_ANTHROPIC_MODEL, "claude-opus-5-5");
  assert.equal(anthropicCost({ input_tokens: 1_000_000 }, OPUS55), usd(4));
  assert.equal(anthropicCost({ output_tokens: 1_000_000 }, OPUS55), usd(20));
  assert.equal(anthropicCost({ cache_creation_input_tokens: 1_000_000, cache_creation: { ephemeral_5m_input_tokens: 1_000_000, ephemeral_1h_input_tokens: 0 } }, OPUS55), usd(5));
  assert.equal(anthropicCost({ cache_creation_input_tokens: 1_000_000 }, OPUS55), usd(8), "no split: the dearer 1-hour rate");
  assert.equal(anthropicCost({ cache_read_input_tokens: 1_000_000 }, OPUS55), usd(0.2));
  assert.equal(anthropicCost({ input_tokens: 1_000_000, output_tokens: 1_000_000 }, OPUS55, true), usd(12));
});

test("reservations are made at the dearest rate a request may be billed at (the model or a fallback model)", () => {
  assert.deepEqual([...FALLBACK_MODELS], ["claude-opus-5", "claude-opus-4-8"]);
  assert.deepEqual(reservationRates("claude-opus-5-5"), OPUS, "Opus 5 is dearer than Opus 5.5, so it sets the reservation");
  assert.deepEqual(ratesFor("claude-unknown"), dearestRates([]), "an unknown answering model is charged at the dearest rates");
  assert.equal(dearestRates(["claude-opus-5-5"]).cacheRead, 0.05);
});

test("Opus 5.5 request shape: effort always sent (default high), never a thinking or tool_choice field", async () => {
  const w = world(); const s = await setup(w);
  await handle(ask({ ...question, thinking: { type: "disabled" }, tool_choice: { type: "any" }, tools: [{ name: "t" }] }), s.env, s.deps);
  await handle(ask({ ...question, output_config: { effort: "low" } }), s.env, s.deps);
  await handle(ask({ ...question, output_config: { effort: "max" } }), s.env, s.deps);
  const [first, low, max] = w.providerBodies.map((b) => JSON.parse(b));
  assert.deepEqual(first.output_config, { effort: "high" }, "no effort asked: high (Opus 5's default), never Opus 5.5's medium by omission");
  assert.equal(first.thinking, undefined); assert.equal(first.tool_choice, undefined); assert.equal(first.tools, undefined);
  assert.deepEqual(low.output_config, { effort: "low" });
  assert.deepEqual(max.output_config, { effort: "high" }, "only low/medium/high pass; anything else is high");
  for (const b of [first, low, max]) assert.deepEqual(Object.keys(b).sort(), ["fallbacks", "max_tokens", "messages", "model", "output_config"]);
});

test("a reply answered by a fallback model is charged at that model's rates, never above the reservation", async () => {
  const w = world(); const s = await setup(w);
  const realFetch = s.deps.fetcher;
  s.deps.fetcher = async (url, init) => {
    if (!url.includes("anthropic")) return realFetch(url, init);
    w.providerBodies.push(String(init?.body ?? ""));
    return new Response(JSON.stringify({ model: "claude-opus-5", content: [{ type: "text", text: "ok" }], usage: { input_tokens: 10_000, output_tokens: 2_000 } }), { status: 200 });
  };
  const k = await kals(await handle(ask(question), s.env, s.deps));
  // Opus 5 rates: 10,000×5 + 2,000×25 = 100,000 µ$ = 10 credits (at Opus 5.5 it would have been 8).
  assert.equal(k.charged, 10);
  assert.ok(k.reserved >= k.charged);
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 100_000);
});

// MARK: - SEC-05 signed-transaction credential

test("SEC-05: a bare transaction number is refused in either header — knowing the number spends nothing", async () => {
  const w = world(); const s = await setup(w);
  const legacy = new Request("https://relay.test/v1/messages", { method: "POST", headers: { [LEGACY_SUBSCRIPTION_HEADER]: SUB }, body: JSON.stringify(question) });
  assert.equal((await handle(legacy, s.env, s.deps)).status, 402);
  assert.equal((await handle(ask(question, SUB), s.env, s.deps)).status, 402, "the number in the new header is not a signed transaction");
  assert.equal((await handle(post("/v1/status", {}, {}, ""), s.env, s.deps)).status, 402);
  assert.equal(w.appleCalls + w.providerBodies.length, 0, "refused before Apple or a provider is asked");
  assert.equal((await s.store.balance(SUB, period(w), dayKey(NOW))).allowanceUsed, 0);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200, "the signed transaction of the same subscription is accepted");
});

test("SEC-05: forged, re-signed, tampered, foreign or stale signed transactions are refused before Apple is asked", async () => {
  const w = world(); const s = await setup(w);
  const [sigH, sigP] = CRED.split(".");
  const tampered = `${sigH}.${Buffer.from(JSON.stringify({ ...JSON.parse(Buffer.from(sigP, "base64url").toString()), originalTransactionId: "2000000555555555" })).toString("base64url")}.${CRED.split(".")[2]}`;
  const cases: [string, string][] = [
    ["a whole chain under another root", await signTx({}, { x5c: [CHAIN.rogueLeaf, CHAIN.rogueIntermediate, CHAIN.rogueRoot], key: CHAIN.rogueLeafKeyPkcs8 })],
    ["the trusted root's bytes ending a chain it did not sign", await signTx({}, { x5c: [CHAIN.rogueLeaf, CHAIN.rogueIntermediate, CHAIN.root], key: CHAIN.rogueLeafKeyPkcs8 })],
    ["the right chain, signed with another key", await signTx({}, { key: CHAIN.rogueLeafKeyPkcs8 })],
    ["leaf and intermediate swapped", await signTx({}, { x5c: [CHAIN.intermediate, CHAIN.leaf, CHAIN.root] })],
    ["a payload edited after signing", tampered],
    ["another app's transaction", await signTx({ bundleId: "com.example.other" })],
    ["local Xcode StoreKit testing", await signTx({ environment: "Xcode" })],
    ["a refunded / revoked transaction", await signTx({ revocationDate: NOW.getTime() - DAY })],
    ["expired beyond Apple's longest billing grace", await signTx({ expiresDate: NOW.getTime() - GRACE_TOLERANCE_MS - 1 })],
    ["signed before its certificates were valid", await signTx({ signedDate: Date.UTC(2001, 0, 1) })],
    ["signed in the future", await signTx({ signedDate: NOW.getTime() + DAY })],
    ["a non-number subscription", await signTx({ originalTransactionId: "abc; drop table" })],
    ["no x5c", `${Buffer.from(JSON.stringify({ alg: "ES256" })).toString("base64url")}.${sigP}.${CRED.split(".")[2]}`],
    ["alg none", `${Buffer.from(JSON.stringify({ alg: "none", x5c: [CHAIN.leaf, CHAIN.intermediate, CHAIN.root] })).toString("base64url")}.${sigP}.x`],
  ];
  for (const [what, cred] of cases) {
    assert.equal((await handle(ask(question, cred), s.env, s.deps)).status, 402, what);
  }
  assert.equal(w.appleCalls + w.providerBodies.length, 0, "nothing asked of Apple or a provider");
  assert.equal(s.deps.verified?.size, 0, "nothing refused is remembered");
});

test("SEC-05: production trusts Apple Root CA - G3 only (pinned bytes); the test root is never trusted by default", async () => {
  const fp = Buffer.from(await crypto.subtle.digest("SHA-256", Buffer.from(APPLE_ROOT_CA_G3, "base64"))).toString("hex");
  assert.equal(fp, "63343abfb89a6a03ebb57e9b3f5fa7be7c4f5c756f3017b3a8c488c3653e9179");
  const r = await verifySignedTransaction(CRED, { bundleId: BUNDLE, now: NOW });
  assert.equal(r.ok, false, "a chain under the test root is refused without injection");
  const ok = await verifySignedTransaction(CRED, { bundleId: BUNDLE, now: NOW, roots: [CHAIN.root] });
  assert.ok(ok.ok && ok.tx.originalTransactionId === SUB && ok.tx.environment === "Production");
  const strict = await verifySignedTransaction(await signTx({ environment: "Sandbox" }), { bundleId: BUNDLE, now: NOW, roots: [CHAIN.root], environments: ["Production"] });
  assert.equal(strict.ok, false, "APPLE_ENVIRONMENTS can exclude Sandbox");
});

test("SEC-05: a verified credential is cached per originalTransactionId for a few minutes; another token naming the number is verified afresh", async () => {
  const cache = new VerificationCache();
  const o = { bundleId: BUNDLE, now: NOW, roots: [CHAIN.root], cache };
  const first = await verifySignedTransaction(CRED, o);
  const second = await verifySignedTransaction(CRED, o);
  assert.ok(first.ok && !first.cached && second.ok && second.cached);
  const forged = await signTx({}, { key: CHAIN.rogueLeafKeyPkcs8 });   // same originalTransactionId, not Apple-signed
  assert.equal((await verifySignedTransaction(forged, o)).ok, false, "the cache never vouches for a different token");
  const later = await verifySignedTransaction(CRED, { ...o, now: new Date(NOW.getTime() + VERIFY_TTL_MS + 1) });
  assert.ok(later.ok && !later.cached, "re-verified after the TTL");
  // Production credentials ask only the production API; nothing falls through to sandbox.
  const w = world({ productionHasIt: false }); const s = await setup(w);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 402);
  assert.equal(w.appleCalls, 1, "one production call, no sandbox fallback for a Production transaction");
});

// MARK: - Deep dive 2026-11-14 batch 4 (the relay's money path)

test("batch 4: a credit pack's or a Workbench signed transaction is no credential; the AI subscription's is", async () => {
  const w = world(); const s = await setup(w);
  const pack = await signTx({ productId: PRODUCTS.credits500, originalTransactionId: "2000000777777777", transactionId: "2000000777777777", expiresDate: undefined });
  const packWithExpiry = await signTx({ productId: PRODUCTS.credits2000, originalTransactionId: "2000000777777778", transactionId: "2000000777777778" });
  const workbench = await signTx({ productId: PRODUCTS.workbenchMonthly, originalTransactionId: "2000000666666666" });
  const noExpiry = await signTx({ expiresDate: undefined });
  for (const [what, cred] of [["a credit pack", pack], ["a credit pack with a date", packWithExpiry], ["Workbench", workbench], ["a subscription with no expiry", noExpiry]] as const) {
    const r = await handle(ask(question, cred), s.env, s.deps);
    assert.equal(r.status, 402, what);
    assert.equal(((await r.json()) as { error: { code: string } }).error.code, "not-subscribed", what);
  }
  assert.equal(w.appleCalls + w.providerBodies.length, 0, "refused before Apple or a provider is asked");
  assert.equal(s.store.allowance.size, 0, "no account was opened");
  const ok = await handle(ask(question), s.env, s.deps);
  assert.equal(ok.status, 200, "the AI subscription's own signed transaction is accepted");
  assert.equal((await kals(ok)).monthlyCredits, PLANS.ai.monthlyCredits);
});

test("batch 4: of Apple's answer only the subscription the credential names counts (another subscription opens no account)", async () => {
  // A verified AI-product transaction of ANOTHER subscription number, while Apple's statuses are SUB's:
  // before the fix the AI plan of SUB was granted to a fresh account keyed by the other number.
  const w = world(); const s = await setup(w);
  const other = await signTx({ originalTransactionId: "2000000444444444", transactionId: "2000000444444445" });
  assert.equal((await handle(ask(question, other), s.env, s.deps)).status, 402);
  assert.equal(w.providerBodies.length, 0);
  assert.equal(s.store.allowance.size, 0);
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200, "SUB's own credential still works");
});

test("batch 4: only text and image content blocks are forwarded; a document block is refused, unsized and unforwarded", async () => {
  const w = world(); const s = await setup(w);
  const doc = { type: "document", source: { type: "base64", media_type: "application/pdf", data: "JVBERi0=" } };
  for (const block of [doc, { type: "tool_result", tool_use_id: "x", content: "y" }, { type: "search_result", source: "s", title: "t", content: [] }, { text: "no type" }]) {
    const r = await handle(ask({ max_tokens: 2000, messages: [{ role: "user", content: [block, { type: "text", text: "summarise" }] }] }), s.env, s.deps);
    assert.equal(r.status, 400, JSON.stringify(block));
    const e = ((await r.json()) as { error: { code: string; message: string } }).error;
    assert.equal(e.code, "bad-request");
    assert.match(e.message, /text and images only/);
  }
  assert.equal(w.providerBodies.length, 0, "nothing forwarded");
  assert.equal((await s.store.balance(SUB, period(w), dayKey(NOW))).allowanceUsed, 0, "nothing reserved");
  const image = { type: "image", source: { type: "base64", media_type: "image/png", data: "iVBORw0KGgo=" } };
  const ok = await handle(ask({ max_tokens: 2000, messages: [{ role: "user", content: [image, { type: "text", text: "read the page" }] }] }), s.env, s.deps);
  assert.equal(ok.status, 200, "what the app sends — page images, then the instruction — is forwarded");
  assert.equal((await handle(ask(question), s.env, s.deps)).status, 200, "plain string content is forwarded");
});

test("batch 4: a provider that does not answer is provider-unavailable (never 'Nothing was sent'); every reserved credit is given back", async () => {
  const w = world(); const s = await setup(w);
  const real = s.deps.fetcher;
  s.deps.fetcher = async (u, i) => { if (u.includes("anthropic")) throw new Error("connection reset"); return real(u, i); };
  const r = await handle(ask(question), s.env, s.deps);
  assert.equal(r.status, 502);
  const e = ((await r.json()) as { error: { code: string; message: string } }).error;
  assert.equal(e.code, "provider-unavailable");
  assert.ok(!e.message.includes("Nothing was sent"), "the request may have reached the provider");
  assert.match(e.message, /no credits were charged/);
  const b = await s.store.balance(SUB, period(w), dayKey(NOW));
  assert.deepEqual([b.allowanceUsed, b.dailyUsed], [0, 0], "exactly as the words say: nothing charged");
  assert.equal(await s.store.spent(monthKey(NOW), "anthropic"), 0);
  // Apple not answering before anything is sent stays store-unavailable ("Nothing was sent" is true there).
  const t = await setup(world());
  const appleReal = t.deps.fetcher;
  t.deps.fetcher = async (u, i) => { if (u.includes("storekit")) return new Response("", { status: 500 }); return appleReal(u, i); };
  assert.equal(((await (await handle(ask(question), t.env, t.deps)).json()) as { error: { code: string } }).error.code, "store-unavailable");
});

test("batch 4: Sandbox subscriptions get one allowance per UTC day at the sandbox ceiling, however often they renew; Production is unchanged", async () => {
  const MIN = 60_000;
  const w = world(); w.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly, purchaseDate: NOW.getTime() - 2 * MIN, expires: NOW.getTime() + 3 * MIN }];
  const s = await setup(w);
  const sandboxCred = (at: number) => signTx({ environment: "Sandbox", purchaseDate: at - 2 * MIN, expiresDate: at + 3 * MIN, signedDate: at - MIN });
  const first = await kals(await handle(ask(question, await sandboxCred(NOW.getTime())), s.env, s.deps));
  assert.deepEqual([first.monthlyCredits, first.dailyLimit], [SANDBOX_DAILY_CREDITS, SANDBOX_DAILY_CREDITS]);
  let used = first.charged;
  // Twelve sandbox "months" (five-minute renewals) in one hour of the same day: no new allowance.
  for (let i = 1; i <= 12; i++) {
    const at = NOW.getTime() + i * 5 * MIN;
    w.now = new Date(at);
    w.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly, purchaseDate: at - 2 * MIN, expires: at + 3 * MIN }];
    s.store.status.clear();
    const k = await kals(await handle(ask(question, await sandboxCred(at)), s.env, s.deps));
    used += k.charged;
    assert.equal(k.allowanceLeft, SANDBOX_DAILY_CREDITS - used, `renewal ${i}: the same day's allowance`);
  }
  // Used up today: still refused after another renewal.
  const today = new Date(Date.UTC(NOW.getUTCFullYear(), NOW.getUTCMonth(), NOW.getUTCDate())).toISOString();
  s.store.allowance.set(`${SUB}|${today}`, SANDBOX_DAILY_CREDITS);
  w.now = new Date(NOW.getTime() + 70 * MIN); s.store.status.clear();
  w.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly, purchaseDate: w.now.getTime() - 2 * MIN, expires: w.now.getTime() + 3 * MIN }];
  assert.equal((await handle(ask(question, await sandboxCred(w.now.getTime())), s.env, s.deps)).status, 402, "one allowance a day");
  // The next UTC day: a fresh (small) allowance.
  const tomorrow = Date.UTC(NOW.getUTCFullYear(), NOW.getUTCMonth(), NOW.getUTCDate() + 1, 9);
  w.now = new Date(tomorrow); s.store.status.clear();
  w.subs = [{ status: APPLE_STATUS.active, productId: PRODUCTS.aiMonthly, purchaseDate: tomorrow - 2 * MIN, expires: tomorrow + 3 * MIN }];
  const next = await kals(await handle(ask(question, await sandboxCred(tomorrow)), s.env, s.deps));
  assert.equal(next.allowanceLeft, SANDBOX_DAILY_CREDITS - next.charged);
  // The owner's setting changes the ceiling; an unreadable one keeps the safe default.
  const set = await setup(world(), { SANDBOX_DAILY_CREDITS: "30" });
  assert.equal((await kals(await handle(post("/v1/status", {}, {}, await signTx({ environment: "Sandbox" })), set.env, set.deps))).monthlyCredits, 30);
  const bad = await setup(world(), { SANDBOX_DAILY_CREDITS: "lots" });
  assert.equal((await kals(await handle(post("/v1/status", {}, {}, await signTx({ environment: "Sandbox" })), bad.env, bad.deps))).monthlyCredits, SANDBOX_DAILY_CREDITS);
  const none = await setup(world(), { SANDBOX_DAILY_CREDITS: "0" });
  assert.ok([402, 429].includes((await handle(ask(question, await signTx({ environment: "Sandbox" })), none.env, none.deps)).status), "0: Sandbox gets no credits");
  // Production: the anniversary month and the plan's limits, as before.
  const p = await setup(world());
  const pk = await kals(await handle(ask(question), p.env, p.deps));
  assert.deepEqual([pk.monthlyCredits, pk.dailyLimit, pk.allowanceLeft], [PLANS.ai.monthlyCredits, PLANS.ai.dailyCredits, PLANS.ai.monthlyCredits - pk.charged]);
  assert.ok(p.store.allowance.has(`${SUB}|${period(world())}`), "keyed by the anniversary month");
});
