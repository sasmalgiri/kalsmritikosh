// AI relay (Cloudflare Worker) for the AI Included and AI Pro plans. The owner's provider keys live here
// as secrets and never in the app. Each request: (1) Apple confirms an active AI plan (and which),
// (2) the request's WORST-CASE cost is reserved against the global monthly safety cap, (3) the same
// worst case, in credits, is reserved from the subscriber (the day's limit, the month's allowance,
// then credit packs), refusing with a clear code when it does not fit — never truncating, (4) the
// request is forwarded with the model and the output ceiling fixed here, (5) the ACTUAL cost from the
// provider's `usage` is charged (whole credits, at least 1) and the rest given back. A provider failure
// gives everything back. The reply carries a `kals` receipt (credits charged, balance left). Nothing a
// request or answer contains is stored or logged — counts only.

import {
  AI_BLOCKED_REQUEST_COUNTRIES, LARGE_READ_MAX_INPUT_CHARS, MAX_INPUT_CHARS, MAX_OUTPUT_TOKENS, PLANS, REFUSALS, SELL_STOP_SHARE,
  TOPUP_CREDITS, accountToken, allowancePeriod, anthropicCost, creditsFor, dayKey, grantedTier, higherTier, maxTokensForText,
  monthKey, ratesFor, refundSplit, sellable, statusFor, tokenCost, usd, validTopUp, worstCaseCost,
  type AnthropicUsage, type CacheUse, type Micro, type Refusal, type Tier,
} from "./policy.ts";
import { D1Store, type D1Like, type PlanStatus, type Provider, type Store } from "./store.ts";
import { type AppleConfig, type Fetch, decodeJWSPayload, subscriptionStatuses, transactionInfo } from "./apple.ts";

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
  ANTHROPIC_MODEL?: string;        // default claude-opus-5 (must be in ANTHROPIC_RATES)
  GEMINI_MODEL?: string;           // default gemini-2.5-flash
  /** Conservative Gemini prices in micro-dollars per token (input incl. audio, output). */
  GEMINI_INPUT_MICRO_PER_TOKEN?: string;  // default 3
  GEMINI_OUTPUT_MICRO_PER_TOKEN?: string; // default 10
  /** Optional override of every plan's daily credit limit. */
  DAILY_CREDIT_LIMIT?: string;
}

export interface Deps { store: Store; fetcher: Fetch; now: () => Date }

const STATUS_TTL_MS = 10 * 60_000;
/** Claude bills an image at most ~1,600 tokens after its own resizing; counted at that ceiling. */
const IMAGE_TOKENS = 1_600;
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

/** Which AI plan Apple says this subscriber has now, and its current period (cached ten minutes). */
async function planStatus(sub: string, env: Env, d: Deps): Promise<PlanStatus> {
  const now = d.now();
  const cached = await d.store.cachedStatus(sub);
  if (cached && now.getTime() - cached.checkedAt < STATUS_TTL_MS) return cached;
  const statuses = await subscriptionStatuses(sub, appleConfig(env), d.fetcher, now);
  let best: PlanStatus = { tier: null, anchor: 0, expires: 0, checkedAt: now.getTime() };
  for (const s of statuses) {
    const tier = grantedTier(s.status, s.transaction, now);
    if (tier && higherTier(best.tier, tier) === tier && tier !== best.tier) {
      best = { tier, anchor: s.transaction.purchaseDate, expires: s.transaction.expiresDate ?? s.transaction.purchaseDate, checkedAt: now.getTime() };
    }
  }
  await d.store.cacheStatus(sub, best);
  return best;
}

interface Account { sub: string; tier: Tier; period: { key: string; startsAt: number; endsAt: number }; day: string }

async function receipt(a: Account, env: Env, d: Deps, extra: Record<string, unknown> = {}) {
  const b = await d.store.balance(a.sub, a.period.key, a.day);
  const plan = PLANS[a.tier];
  return {
    plan: a.tier, monthlyCredits: plan.monthlyCredits,
    allowanceUsed: Math.min(plan.monthlyCredits, b.allowanceUsed),
    allowanceLeft: Math.max(0, plan.monthlyCredits - b.allowanceUsed),
    topUps: b.topUps,
    dailyUsed: b.dailyUsed, dailyLimit: dailyLimit(env, a.tier),
    perRequestCredits: plan.perRequestCredits, caseReadCredits: plan.caseReadCredits,
    periodStartsAt: new Date(a.period.startsAt).toISOString(), periodEndsAt: new Date(a.period.endsAt).toISOString(),
    ...extra,
  };
}

/** Input size of a Messages request: text characters, images counted at their token ceiling, and the
 *  dearest cache write it asks for. */
export function estimateMessagesInput(body: { system?: unknown; messages?: unknown[] }): { chars: number; images: number; cache: CacheUse } {
  let chars = typeof body.system === "string" ? body.system.length : JSON.stringify(body.system ?? "").length;
  let images = 0;
  for (const m of body.messages ?? []) {
    const content = (m as { content?: unknown }).content;
    if (typeof content === "string") { chars += content.length; continue; }
    for (const block of (Array.isArray(content) ? content : []) as { type?: string; text?: string }[]) {
      if (block.type === "text") chars += (block.text ?? "").length;
      else if (block.type === "image" || block.type === "document") images += 1;
      else chars += JSON.stringify(block).length;
    }
  }
  const raw = JSON.stringify(body);
  const cache: CacheUse = !raw.includes("cache_control") ? "none" : /"ttl"\s*:\s*"1h"/.test(raw) ? "1h" : "5m";
  return { chars, images, cache };
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
  const plan = PLANS[a.tier];
  const held = await d.store.reserveCredits(a.sub, a.period.key, plan.monthlyCredits, a.day, dailyLimit(env, a.tier), reserved);
  if (!held.ok) {
    await d.store.adjustSpend(month, provider, -worstMicro);
    return refuse(held.reason === "daily" ? REFUSALS.dailyLimit(dailyLimit(env, a.tier)) : REFUSALS.creditsUsed(reserved, held.balance));
  }
  let out: { status: number; text: string; cost: Micro | null };
  try { out = await call(); } catch {
    await d.store.adjustSpend(month, provider, -worstMicro);
    await d.store.releaseCredits(a.sub, a.period.key, a.day, held.fromAllowance, held.fromTopUps);
    return refuse(REFUSALS.storeUnavailable());
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
  if (size.chars > (large ? LARGE_READ_MAX_INPUT_CHARS : MAX_INPUT_CHARS) || size.images > 20) return refuse(REFUSALS.tooLarge());
  const maxOut = Math.min(MAX_OUTPUT_TOKENS, Math.max(1024, Number(body.max_tokens ?? MAX_OUTPUT_TOKENS) || MAX_OUTPUT_TOKENS));
  const model = env.ANTHROPIC_MODEL ?? "claude-opus-5";
  const rates = ratesFor(model);
  const inputTokens = maxTokensForText(size.chars) + size.images * IMAGE_TOKENS;
  const worst = worstCaseCost(inputTokens, maxOut, rates, size.cache);
  const plan = PLANS[a.tier];
  // Only these fields are forwarded; the model and the ceiling are the relay's.
  // Effort only lowers or keeps the thinking (and cost) within the reserved max_tokens.
  const effort = typeof body.output_config?.effort === "string" && ["low", "medium", "high"].includes(body.output_config.effort) ? body.output_config.effort : undefined;
  const forward = { model, max_tokens: maxOut, messages: body.messages, fallbacks: "default",
                    ...(body.system !== undefined ? { system: body.system } : {}),
                    ...(effort ? { output_config: { effort } } : {}) };
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
      const u = (JSON.parse(text) as { usage?: AnthropicUsage }).usage;
      if (u) cost = anthropicCost(u, rates);
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
  const tx = await transactionInfo(body.transactionId, appleConfig(env), d.fetcher, d.now());
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
  const sub = req.headers.get("x-kals-subscription")?.trim() ?? "";
  // A3 — refused by where the request comes from (Cloudflare's country), as well as by the App Store storefront.
  const from = req.headers.get("cf-ipcountry")?.toUpperCase() ?? "";
  if (AI_BLOCKED_REQUEST_COUNTRIES.includes(from)) return refuse(REFUSALS.regionUnavailable());
  if (!/^[0-9]{1,32}$/.test(sub)) return refuse(REFUSALS.notSubscribed());
  let status: PlanStatus;
  try { status = await planStatus(sub, env, d); } catch { return refuse(REFUSALS.storeUnavailable()); }
  if (!status.tier) return refuse(REFUSALS.notSubscribed());
  const now = d.now();
  const a: Account = { sub, tier: status.tier, period: allowancePeriod(status.anchor, status.expires, now.getTime()), day: dayKey(now) };
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
