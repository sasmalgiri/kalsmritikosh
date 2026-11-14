// AI relay (Cloudflare Worker) for the AI Included and AI Pro plans. The owner's provider keys live here
// as secrets and never in the app. Each request: (0) the app's StoreKit signed transaction is verified to
// Apple's root (jws.ts — a bare transaction number is refused), (1) Apple confirms an active AI plan (and which),
// (2) the request's WORST-CASE cost is reserved against the global monthly safety cap, (3) the same
// worst case, in credits, is reserved from the subscriber (the day's limit, the month's allowance,
// then credit packs), refusing with a clear code when it does not fit — never truncating, (4) the
// request is forwarded with the model and the output ceiling fixed here, (5) the ACTUAL cost from the
// provider's `usage` is charged (whole credits, at least 1) and the rest given back. A provider failure
// gives everything back. The reply carries a `kals` receipt (credits charged, balance left). Nothing a
// request or answer contains is stored or logged — counts only.

import {
  AI_BLOCKED_REQUEST_COUNTRIES, SANDBOX_DAILY_CREDITS, LARGE_READ_MAX_INPUT_CHARS, MAX_INPUT_CHARS, MAX_OUTPUT_TOKENS, PLANS, REFUSALS, SELL_STOP_SHARE,
  TOPUP_CREDITS, accountToken, allowancePeriod, anthropicCost, creditsFor, dayKey, grantedTier, higherTier, maxInputTokens,
  monthKey, monthlyAllowance, ratesFor, refundSplit, reservationRates, effortFor, DEFAULT_ANTHROPIC_MODEL, sellable, statusFor, tokenCost, usd, validTopUp, worstCaseCost, YEARLY_PRODUCTS,
  type AnthropicUsage, type CacheUse, type Micro, type Refusal, type Tier,
} from "./policy.ts";
import { D1Store, type D1Like, type PlanStatus, type Provider, type Store } from "./store.ts";
import { type AppleConfig, type Fetch, decodeJWSPayload, subscriptionStatuses, transactionInfo } from "./apple.ts";
import { LEGACY_SUBSCRIPTION_HEADER, SIGNED_TRANSACTION_HEADER, VerificationCache, verifySignedTransaction } from "./jws.ts";

export interface Env {
  DB: D1Like;
  ANTHROPIC_API_KEY: string;
  GEMINI_API_KEY: string;
  APPLE_ISSUER_ID: string;
  APPLE_KEY_ID: string;
  APPLE_PRIVATE_KEY: string;
  BUNDLE_ID: string;
  /** Global monthly safety cap on Anthropic spend over ALL subscribers (default 20 until launch). */
  GLOBAL_CAP_USD?: string;
  GEMINI_BUDGET_USD?: string;      // default 5
  ANTHROPIC_MODEL?: string;        // default claude-opus-5-5 (must be in ANTHROPIC_RATES)
  GEMINI_MODEL?: string;           // default gemini-2.5-flash
  /** Conservative Gemini prices in micro-dollars per token (input incl. audio, output). */
  GEMINI_INPUT_MICRO_PER_TOKEN?: string;  // default 3
  GEMINI_OUTPUT_MICRO_PER_TOKEN?: string; // default 10
  /** Optional override of every plan's daily credit limit. */
  DAILY_CREDIT_LIMIT?: string;
  /** SEC-05: App Store environments a signed transaction may come from (default "Production,Sandbox"). */
  APPLE_ENVIRONMENTS?: string;
  /** Sandbox (TestFlight, App Review) subscriptions renew every few minutes: they get ONE allowance per
   *  UTC day of this many credits, which is also their daily limit (default SANDBOX_DAILY_CREDITS). */
  SANDBOX_DAILY_CREDITS?: string;
}

/** `appleRoots` (DER, base64) replaces Apple Root CA - G3 in tests only; `verified` remembers verified
 *  signed transactions for a few minutes (per originalTransactionId). */
export interface Deps { store: Store; fetcher: Fetch; now: () => Date; appleRoots?: readonly string[]; verified?: VerificationCache }

/** Per isolate: a verified credential is re-checked at most every VERIFY_TTL_MS. */
const VERIFIED = new VerificationCache();

const STATUS_TTL_MS = 10 * 60_000;
/** Audio bytes per token, conservatively (Gemini bills ~32 tokens a second; 128 kbps ≈ 500 bytes/token). */
const AUDIO_BYTES_PER_TOKEN = 200;
const MAX_AUDIO_BYTES = 18 * 1024 * 1024;
const TRANSCRIPT_OUTPUT_TOKENS = 8_192;
/** The header the app sets only after the person confirmed the estimate of a whole-case read. */
export const LARGE_READ_HEADER = "x-kals-large-read";

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });
const refuse = (r: Refusal) => json({ error: r }, statusFor(r));

function caps(env: Env): Record<Provider, Micro> {
  return { anthropic: usd(Number(env.GLOBAL_CAP_USD ?? "20")), gemini: usd(Number(env.GEMINI_BUDGET_USD ?? "5")) };
}
/** Anthropic reservations stop at 90 % of the global cap (the same point AI plans stop being sold). */
function stopAt(env: Env, provider: Provider): Micro {
  const cap = caps(env)[provider];
  return provider === "anthropic" ? Math.floor(cap * SELL_STOP_SHARE) : cap;
}
function appleConfig(env: Env): AppleConfig {
  return { issuerId: env.APPLE_ISSUER_ID, keyId: env.APPLE_KEY_ID, privateKeyPem: env.APPLE_PRIVATE_KEY, bundleId: env.BUNDLE_ID };
}
function dailyLimit(env: Env, tier: Tier): number {
  const o = Number(env.DAILY_CREDIT_LIMIT ?? "");
  return Number.isFinite(o) && o > 0 ? o : PLANS[tier].dailyCredits;
}
/** Sandbox's credits per UTC day (an unset or unreadable setting: the safe default; never above the plan's). */
function sandboxDailyCredits(env: Env, tier: Tier): number {
  const raw = env.SANDBOX_DAILY_CREDITS?.trim() ?? "";
  const o = raw === "" ? NaN : Number(raw);
  const n = Number.isFinite(o) && o >= 0 ? Math.floor(o) : SANDBOX_DAILY_CREDITS;
  return Math.min(n, dailyLimit(env, tier), PLANS[tier].monthlyCredits);
}

/** Which AI plan Apple says this subscriber has now, and its current period (cached ten minutes). */
async function planStatus(sub: string, environment: string, env: Env, d: Deps): Promise<PlanStatus> {
  const now = d.now();
  const cached = await d.store.cachedStatus(sub);
  if (cached && now.getTime() - cached.checkedAt < STATUS_TTL_MS) return cached;
  const statuses = await subscriptionStatuses(sub, appleConfig(env), d.fetcher, now, environment);
  let best: PlanStatus = { tier: null, anchor: 0, expires: 0, checkedAt: now.getTime() };
  for (const s of statuses) {
    // Only the subscription the credential names: Apple answers for every group of the customer.
    if (s.transaction.originalTransactionId !== sub) continue;
    const tier = grantedTier(s.status, s.transaction, now);
    if (tier && higherTier(best.tier, tier) === tier && tier !== best.tier) {
      best = { tier, anchor: s.transaction.purchaseDate, expires: s.transaction.expiresDate ?? s.transaction.purchaseDate, checkedAt: now.getTime(),
               yearly: YEARLY_PRODUCTS.includes(s.transaction.productId) };
    }
  }
  await d.store.cacheStatus(sub, best);
  return best;
}

interface Account { sub: string; environment: string; tier: Tier; period: { key: string; startsAt: number; endsAt: number }; day: string; monthlyCredits: number; dailyLimit: number }

/** The account a verified subscriber spends from. Production: the plan's anniversary month. Sandbox
 *  (TestFlight, App Review): its periods last minutes, so the allowance period is the UTC day — one
 *  allowance per real day however often it renews — capped at SANDBOX_DAILY_CREDITS. */
function accountFor(sub: string, environment: string, status: PlanStatus & { tier: Tier }, env: Env, now: Date): Account {
  const day = dayKey(now);
  if (environment === "Sandbox") {
    const startsAt = Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate());
    const credits = sandboxDailyCredits(env, status.tier);
    return { sub, environment, tier: status.tier, period: { key: new Date(startsAt).toISOString(), startsAt, endsAt: startsAt + 86_400_000 },
             day, monthlyCredits: credits, dailyLimit: credits };
  }
  return { sub, environment, tier: status.tier, period: allowancePeriod(status.anchor, status.expires, now.getTime()), day,
           monthlyCredits: monthlyAllowance(status.tier, status.yearly === true), dailyLimit: dailyLimit(env, status.tier) };
}

async function receipt(a: Account, env: Env, d: Deps, extra: Record<string, unknown> = {}) {
  const b = await d.store.balance(a.sub, a.period.key, a.day);
  const plan = PLANS[a.tier];
  return {
    plan: a.tier, monthlyCredits: a.monthlyCredits,
    allowanceUsed: Math.min(a.monthlyCredits, b.allowanceUsed),
    allowanceLeft: Math.max(0, a.monthlyCredits - b.allowanceUsed),
    topUps: b.topUps,
    dailyUsed: b.dailyUsed, dailyLimit: a.dailyLimit,
    perRequestCredits: plan.perRequestCredits, caseReadCredits: plan.caseReadCredits,
    periodStartsAt: new Date(a.period.startsAt).toISOString(), periodEndsAt: new Date(a.period.endsAt).toISOString(),
    ...extra,
  };
}

/** The content block types the relay forwards: what the app sends (text, and page images). Anything
 *  else (a `document` — a whole PDF billed per page — tool results, search results…) cannot be sized
 *  before it is sent, so it is refused. */
export const FORWARDED_BLOCK_TYPES: readonly string[] = ["text", "image"];

/** Input size of a Messages request: text characters, images counted at their token ceiling, and the
 *  dearest cache write it asks for. `unsupported` names a content block type that is not forwarded. */
export function estimateMessagesInput(body: { system?: unknown; messages?: unknown[] }): { chars: number; images: number; cache: CacheUse; unsupported?: string } {
  let chars = typeof body.system === "string" ? body.system.length : JSON.stringify(body.system ?? "").length;
  let images = 0;
  let unsupported: string | undefined;
  for (const m of body.messages ?? []) {
    const content = (m as { content?: unknown }).content;
    if (typeof content === "string") { chars += content.length; continue; }
    if (!Array.isArray(content)) { unsupported ??= "content"; continue; }
    for (const block of content as { type?: unknown; text?: string }[]) {
      const type = typeof block?.type === "string" ? block.type : "";
      if (!FORWARDED_BLOCK_TYPES.includes(type)) { unsupported ??= type || "untyped"; continue; }
      if (type === "text") chars += (block.text ?? "").length;
      else images += 1;
    }
  }
  const raw = JSON.stringify(body);
  const cache: CacheUse = !raw.includes("cache_control") ? "none" : /"ttl"\s*:\s*"1h"/.test(raw) ? "1h" : "5m";
  return { chars, images, cache, ...(unsupported !== undefined ? { unsupported } : {}) };
}

/** Reserve, call, settle — one provider call. `call` returns the reply and its actual cost (null =
 *  unreadable, the worst case is kept). */
async function metered(a: Account, provider: Provider, worstMicro: Micro, ceiling: number, large: boolean, env: Env, d: Deps,
                       call: () => Promise<{ status: number; text: string; cost: Micro | null }>): Promise<Response> {
  const month = monthKey(d.now());
  const reserved = creditsFor(worstMicro);
  if (reserved > ceiling) return refuse(REFUSALS.tooCostly(reserved, ceiling, large));
  if (!(await d.store.reserveSpend(month, provider, worstMicro, caps(env)[provider], stopAt(env, provider)))) {
    return refuse(REFUSALS.capacityPaused());
  }
  const held = await d.store.reserveCredits(a.sub, a.period.key, a.monthlyCredits, a.day, a.dailyLimit, reserved);
  if (!held.ok) {
    await d.store.adjustSpend(month, provider, -worstMicro);
    return refuse(held.reason === "daily" ? REFUSALS.dailyLimit(a.dailyLimit) : REFUSALS.creditsUsed(reserved, held.balance));
  }
  let out: { status: number; text: string; cost: Micro | null };
  try { out = await call(); } catch {
    // The provider did not answer (the request may have reached it): every reserved credit is given back.
    await d.store.adjustSpend(month, provider, -worstMicro);
    await d.store.releaseCredits(a.sub, a.period.key, a.day, held.fromAllowance, held.fromTopUps);
    return refuse(REFUSALS.providerUnavailable());
  }
  const ok = out.status >= 200 && out.status < 300;
  const actualMicro = ok ? (out.cost ?? worstMicro) : 0;
  // The subscriber is never charged more than was reserved; the cap counts the real cost.
  const charged = ok ? Math.min(reserved, creditsFor(actualMicro)) : 0;
  await d.store.adjustSpend(month, provider, actualMicro - worstMicro);
  const back = refundSplit(held.fromAllowance, held.fromTopUps, charged);
  await d.store.releaseCredits(a.sub, a.period.key, a.day, back.allowance, back.topUps);
  const kals = await receipt(a, env, d, { charged, reserved });
  let body: string = out.text;
  try {
    const parsed = JSON.parse(out.text);
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) body = JSON.stringify({ ...parsed, kals });
  } catch { /* not JSON: passed through as it came */ }
  return new Response(body, { status: out.status, headers: { "content-type": "application/json" } });
}

async function messages(req: Request, a: Account, env: Env, d: Deps): Promise<Response> {
  const large = req.headers.get(LARGE_READ_HEADER) === "confirmed";
  const raw = await req.text();
  if (raw.length > (large ? 16 : 8) * 1024 * 1024) return refuse(REFUSALS.tooLarge());
  let body: { system?: unknown; messages?: unknown[]; max_tokens?: number; output_config?: { effort?: unknown } };
  try { body = JSON.parse(raw); } catch { return refuse(REFUSALS.badRequest("not JSON")); }
  if (!Array.isArray(body.messages) || body.messages.length === 0) return refuse(REFUSALS.badRequest("no messages"));
  const size = estimateMessagesInput(body);
  if (size.unsupported !== undefined) return refuse(REFUSALS.badRequest(`content of type "${size.unsupported.slice(0, 40)}" is not accepted (text and images only)`));
  if (size.chars > (large ? LARGE_READ_MAX_INPUT_CHARS : MAX_INPUT_CHARS) || size.images > 20) return refuse(REFUSALS.tooLarge());
  const maxOut = Math.min(MAX_OUTPUT_TOKENS, Math.max(1024, Number(body.max_tokens ?? MAX_OUTPUT_TOKENS) || MAX_OUTPUT_TOKENS));
  const model = env.ANTHROPIC_MODEL ?? DEFAULT_ANTHROPIC_MODEL;
  const inputTokens = maxInputTokens(size.chars, size.images);
  // Reserved at the dearest rate the request may be billed at (the model, or a fallback model).
  const worst = worstCaseCost(inputTokens, maxOut, reservationRates(model), size.cache);
  const plan = PLANS[a.tier];
  // Only these fields are forwarded; the model and the ceiling are the relay's. Opus 5.5: thinking is
  // always on (no `thinking` field is ever sent — "disabled" is a 400), forced tool use is a 400 (no
  // `tools`/`tool_choice` are forwarded), and the effort is always sent explicitly (its default changed).
  // Effort only lowers or keeps the thinking (and cost) within the reserved max_tokens.
  const effort = effortFor(body.output_config?.effort);
  const forward = { model, max_tokens: maxOut, messages: body.messages, fallbacks: "default",
                    ...(body.system !== undefined ? { system: body.system } : {}),
                    output_config: { effort } };
  return metered(a, "anthropic", worst, large ? plan.caseReadCredits : plan.perRequestCredits, large, env, d, async () => {
    const res = await d.fetcher("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01",
                 "anthropic-beta": "server-side-fallback-2026-07-01" },
      body: JSON.stringify(forward),
    });
    const text = await res.text();
    let cost: Micro | null = null;
    try {
      // Charged at the rates of the model that answered (a fallback model has its own price).
      const reply = JSON.parse(text) as { usage?: AnthropicUsage; model?: unknown };
      const served = typeof reply.model === "string" && reply.model ? reply.model : model;
      if (reply.usage) cost = anthropicCost(reply.usage, ratesFor(served));
    } catch { /* an unreadable reply keeps the worst case */ }
    return { status: res.status, text, cost };
  });
}

async function transcribe(req: Request, a: Account, env: Env, d: Deps): Promise<Response> {
  let body: { audioBase64?: string; mimeType?: string };
  try { body = await req.json(); } catch { return refuse(REFUSALS.badRequest("not JSON")); }
  const audio = body.audioBase64 ?? "";
  const bytes = Math.floor(audio.length * 3 / 4);
  if (!audio || !body.mimeType?.startsWith("audio/") && !body.mimeType?.startsWith("video/")) return refuse(REFUSALS.badRequest("no audio"));
  if (bytes > MAX_AUDIO_BYTES) return refuse(REFUSALS.tooLarge());
  const pin = Number(env.GEMINI_INPUT_MICRO_PER_TOKEN ?? "3"), pout = Number(env.GEMINI_OUTPUT_MICRO_PER_TOKEN ?? "10");
  const worst = tokenCost(Math.ceil(bytes / AUDIO_BYTES_PER_TOKEN) + 256, TRANSCRIPT_OUTPUT_TOKENS, pin, pout);
  const model = env.GEMINI_MODEL ?? "gemini-2.5-flash";
  const prompt = "Transcribe this recording verbatim. Label each turn with a speaker label (Speaker 1, Speaker 2, …) and a start time [mm:ss]. Do not summarise, translate, correct or add anything; mark inaudible parts as [inaudible].";
  return metered(a, "gemini", worst, PLANS[a.tier].perRequestCredits, false, env, d, async () => {
    const res = await d.fetcher(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: prompt }, { inline_data: { mime_type: body.mimeType, data: audio } }] }],
        generationConfig: { maxOutputTokens: TRANSCRIPT_OUTPUT_TOKENS, temperature: 0 },
      }),
    });
    const text = await res.text();
    let cost: Micro | null = null;
    try {
      const u = (JSON.parse(text) as { usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number } }).usageMetadata;
      if (u) cost = tokenCost(u.promptTokenCount ?? 0, (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0), pin, pout);
    } catch { /* keep the worst case */ }
    return { status: res.status, text, cost };
  });
}

/** Credit a pack the app bought for this subscription (re-checked with Apple), or remove a refunded one. */
async function topUp(req: Request, a: Account, env: Env, d: Deps): Promise<Response> {
  let body: { transactionId?: string };
  try { body = await req.json(); } catch { return refuse(REFUSALS.badRequest("not JSON")); }
  if (!body.transactionId || !/^[0-9]{1,32}$/.test(body.transactionId)) return refuse(REFUSALS.badRequest("no transactionId"));
  const tx = await transactionInfo(body.transactionId, appleConfig(env), d.fetcher, d.now(), a.environment);
  if (!tx || TOPUP_CREDITS[tx.productId] === undefined) return refuse(REFUSALS.badRequest("not a credit pack"));
  if (tx.revocationDate) {
    const revoked = await d.store.revokeTopUp(tx.transactionId);
    return json({ credited: false, revoked: true, wasOnRecord: revoked, kals: await receipt(a, env, d) });
  }
  // A pack belongs to the subscription it was bought for: the app sets this token at purchase.
  if ((tx.appAccountToken ?? "").toLowerCase() !== await accountToken(a.sub)) return refuse(REFUSALS.badRequest("this credit pack was bought for another subscription"));
  if (!validTopUp(tx)) return refuse(REFUSALS.badRequest("not a valid credit pack"));
  const credited = await d.store.creditTopUp(tx.transactionId, a.sub, tx.productId, tx.purchaseDate, TOPUP_CREDITS[tx.productId]);
  return json({ credited, revoked: false, kals: await receipt(a, env, d) });
}

export async function handle(req: Request, env: Env, d: Deps): Promise<Response> {
  const url = new URL(req.url);
  // A3 — refused by where the request comes from (Cloudflare's country), as well as by the App Store storefront.
  const from = req.headers.get("cf-ipcountry")?.toUpperCase() ?? "";
  if (AI_BLOCKED_REQUEST_COUNTRIES.includes(from)) return refuse(REFUSALS.regionUnavailable());
  // SEC-05 — the credential is the StoreKit signed transaction (JWS), verified to Apple's root before
  // Apple is asked anything. A bare transaction number (the old header) is not proof of anything: refused.
  if (req.headers.has(LEGACY_SUBSCRIPTION_HEADER) && !req.headers.has(SIGNED_TRANSACTION_HEADER)) return refuse(REFUSALS.notSubscribed());
  const credential = req.headers.get(SIGNED_TRANSACTION_HEADER)?.trim() ?? "";
  const verified = await verifySignedTransaction(credential, {
    bundleId: env.BUNDLE_ID, now: d.now(), roots: d.appleRoots, cache: d.verified ?? VERIFIED,
    environments: env.APPLE_ENVIRONMENTS ? env.APPLE_ENVIRONMENTS.split(",").map((e) => e.trim()).filter(Boolean) : undefined,
  });
  if (!verified.ok) return refuse(REFUSALS.notSubscribed());
  const sub = verified.tx.originalTransactionId;
  let status: PlanStatus;
  try { status = await planStatus(sub, verified.tx.environment, env, d); } catch { return refuse(REFUSALS.storeUnavailable()); }
  if (!status.tier) return refuse(REFUSALS.notSubscribed());
  const now = d.now();
  const a = accountFor(sub, verified.tx.environment, { ...status, tier: status.tier }, env, now);
  // GET or POST: the app's network helper sends POST only.
  if (url.pathname === "/v1/status") {
    const spentA = await d.store.spent(monthKey(now), "anthropic");
    return json({ active: true, paused: spentA >= stopAt(env, "anthropic"), sellable: sellable(spentA, caps(env).anthropic),
                  kals: await receipt(a, env, d) });
  }
  if (req.method !== "POST") return refuse(REFUSALS.badRequest("method"));
  if (url.pathname === "/v1/messages") return messages(req, a, env, d);
  if (url.pathname === "/v1/transcribe") return transcribe(req, a, env, d);
  if (url.pathname === "/v1/topup") return topUp(req, a, env, d);
  return refuse(REFUSALS.badRequest("unknown path"));
}

/** Whether new buyers may be offered AI plans this month (no subscription needed to ask). */
export async function publicSellable(env: Env, d: Deps): Promise<Response> {
  const spentA = await d.store.spent(monthKey(d.now()), "anthropic");
  return json({ sellable: sellable(spentA, caps(env).anthropic) });
}

/** App Store Server Notifications V2 (set this URL in App Store Connect). The notification is only a
 *  hint: whatever it names is re-read from Apple's own API before anything changes. A refunded or revoked
 *  credit pack loses its remaining credits; a subscription change drops the cached status. Always 200. */
export async function appleNotification(req: Request, env: Env, d: Deps): Promise<Response> {
  try {
    const { signedPayload } = await req.json() as { signedPayload?: string };
    const payload = decodeJWSPayload<{ notificationType?: string; data?: { signedTransactionInfo?: string } }>(signedPayload ?? "");
    const hinted = decodeJWSPayload<{ transactionId?: string; originalTransactionId?: string }>(payload.data?.signedTransactionInfo ?? "");
    if (!hinted.transactionId || !/^[0-9]{1,32}$/.test(hinted.transactionId)) return json({ ok: true });
    if (hinted.originalTransactionId && /^[0-9]{1,32}$/.test(hinted.originalTransactionId)) await d.store.forgetStatus(hinted.originalTransactionId);
    const tx = await transactionInfo(hinted.transactionId, appleConfig(env), d.fetcher, d.now());
    if (tx && TOPUP_CREDITS[tx.productId] !== undefined && tx.revocationDate) await d.store.revokeTopUp(tx.transactionId);
  } catch { /* malformed or Apple unreachable: Apple retries; the app also reports refunded packs */ }
  return json({ ok: true });
}

/** Retention, as the privacy policy states: monthly counts for 13 months, day counts for 40 days, empty
 *  credit packs 25 months after purchase (a pack with credits left is never deleted), Apple's status
 *  answers for a day. Runs daily (wrangler.toml cron). */
export async function purgeOld(d: Deps): Promise<void> {
  const now = d.now();
  const oldest = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - 13, 1));
  await d.store.purge(monthKey(oldest), oldest.toISOString(), dayKey(new Date(now.getTime() - 40 * 86_400_000)),
                      now.getTime() - 25 * 30 * 86_400_000, now.getTime() - 86_400_000);
}

interface Ctx { waitUntil(p: Promise<unknown>): void }

export default {
  async scheduled(_event: unknown, env: Env): Promise<void> {
    await purgeOld({ store: new D1Store(env.DB), fetcher: (u, i) => fetch(u, i), now: () => new Date() });
  },
  async fetch(req: Request, env: Env, ctx?: Ctx): Promise<Response> {
    const deps: Deps = { store: new D1Store(env.DB), fetcher: (u, i) => fetch(u, i), now: () => new Date() };
    const path = new URL(req.url).pathname;
    const work = path === "/v1/sellable" ? publicSellable(env, deps)
      : path === "/v1/apple-notifications" ? appleNotification(req, env, deps)
      : handle(req, env, deps);
    // Settlement finishes even if the app disconnects mid-request (a reservation is never left behind).
    ctx?.waitUntil(work);
    return work;
  },
};
