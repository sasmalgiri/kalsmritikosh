// AI Included relay (Cloudflare Worker). The owner's provider keys live here as secrets and never in
// the app. Each request: (1) Apple confirms an active AI Included subscription, (2) one question is
// taken from the subscriber's 300 (then from a top-up), (3) the request's WORST-CASE cost is reserved
// against the hard monthly cap, (4) the request is forwarded with the model and output ceiling fixed
// here, (5) the reservation is corrected to the actual cost. Any failure gives the question and the
// money back. Nothing a request or answer contains is stored or logged — counts only.

import {
  ANTHROPIC_OPUS5, MAX_INPUT_CHARS, MAX_OUTPUT_TOKENS, REFUSALS, type Prices, type Provider, type Refusal,
  actualCost, grantsAI, maxTokensForText, monthKey, sellable, statusFor, usd, validTopUp, PRODUCTS,
} from "./policy.ts";
import { D1Store, type D1Like, type QuestionSource, type Store } from "./store.ts";
import { type AppleConfig, type Fetch, subscriptionStatuses, transactionInfo } from "./apple.ts";

export interface Env {
  DB: D1Like;
  ANTHROPIC_API_KEY: string;
  GEMINI_API_KEY: string;
  APPLE_ISSUER_ID: string;
  APPLE_KEY_ID: string;
  APPLE_PRIVATE_KEY: string;
  BUNDLE_ID: string;
  ANTHROPIC_BUDGET_USD?: string;   // default 20
  GEMINI_BUDGET_USD?: string;      // default 5
  ANTHROPIC_MODEL?: string;        // default claude-opus-5
  GEMINI_MODEL?: string;           // default gemini-2.5-flash
  /** Conservative Gemini prices in micro-dollars per token (input incl. audio, output). */
  GEMINI_INPUT_MICRO_PER_TOKEN?: string;  // default 3
  GEMINI_OUTPUT_MICRO_PER_TOKEN?: string; // default 10
}

export interface Deps { store: Store; fetcher: Fetch; now: () => Date }

const STATUS_TTL_MS = 10 * 60_000;
/** Claude bills an image at most ~1,600 tokens after its own resizing; counted at that ceiling. */
const IMAGE_TOKENS = 1_600;
/** Audio bytes per token, conservatively (Gemini bills ~32 tokens a second; 128 kbps ≈ 500 bytes/token). */
const AUDIO_BYTES_PER_TOKEN = 200;
const MAX_AUDIO_BYTES = 18 * 1024 * 1024;
const TRANSCRIPT_OUTPUT_TOKENS = 8_192;

const json = (body: unknown, status = 200, extra: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", ...extra } });
const refuse = (r: Refusal) => json({ error: r }, statusFor(r));

function budgets(env: Env): Record<Provider, number> {
  return { anthropic: usd(Number(env.ANTHROPIC_BUDGET_USD ?? "20")), gemini: usd(Number(env.GEMINI_BUDGET_USD ?? "5")) };
}
function geminiPrices(env: Env): Prices {
  return { inputPerToken: Number(env.GEMINI_INPUT_MICRO_PER_TOKEN ?? "3"), outputPerToken: Number(env.GEMINI_OUTPUT_MICRO_PER_TOKEN ?? "10") };
}
function appleConfig(env: Env): AppleConfig {
  return { issuerId: env.APPLE_ISSUER_ID, keyId: env.APPLE_KEY_ID, privateKeyPem: env.APPLE_PRIVATE_KEY, bundleId: env.BUNDLE_ID };
}

/** Whether Apple says this subscriber has AI Included now (cached for ten minutes). */
async function subscribed(sub: string, env: Env, d: Deps): Promise<boolean> {
  const now = d.now();
  const cached = await d.store.cachedStatus(sub);
  if (cached && now.getTime() - cached.checkedAt < STATUS_TTL_MS) return cached.active;
  const statuses = await subscriptionStatuses(sub, appleConfig(env), d.fetcher, now);
  const active = statuses.some((s) => grantsAI(s.status, s.transaction, now));
  await d.store.cacheStatus(sub, active, now.getTime());
  return active;
}

/** Input size of a Messages request: text characters, and images counted at their token ceiling. */
export function estimateMessagesInput(body: { system?: unknown; messages?: unknown[] }): { chars: number; images: number } {
  let chars = typeof body.system === "string" ? body.system.length : 0;
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
  return { chars, images };
}

/** Steps 2–5 for one provider call. */
async function metered(sub: string, provider: Provider, worst: number, env: Env, d: Deps,
                       call: () => Promise<{ res: Response; cost: number | null }>): Promise<Response> {
  const now = d.now(), month = monthKey(now);
  const source: QuestionSource | null = await d.store.consumeQuestion(month, sub, now);
  if (!source) return refuse(REFUSALS.quotaUsed());
  if (!(await d.store.reserveSpend(month, provider, worst, budgets(env)[provider]))) {
    await d.store.refundQuestion(month, sub, source);
    return refuse(REFUSALS.capacityPaused());
  }
  let outcome: { res: Response; cost: number | null };
  try { outcome = await call(); } catch {
    await d.store.adjustSpend(month, provider, -worst);
    await d.store.refundQuestion(month, sub, source);
    return refuse(REFUSALS.storeUnavailable());
  }
  const kept = outcome.res.ok ? Math.min(worst, outcome.cost ?? worst) : 0;
  await d.store.adjustSpend(month, provider, kept - worst);
  if (!outcome.res.ok) await d.store.refundQuestion(month, sub, source);
  const left = await d.store.remaining(month, sub, now);
  const headers = new Headers(outcome.res.headers);
  headers.set("x-kals-remaining", String(left.monthly + left.topUps));
  return new Response(outcome.res.body, { status: outcome.res.status, headers });
}

async function messages(req: Request, sub: string, env: Env, d: Deps): Promise<Response> {
  const raw = await req.text();
  if (raw.length > 8 * 1024 * 1024) return refuse(REFUSALS.tooLarge());
  let body: { system?: unknown; messages?: unknown[]; max_tokens?: number };
  try { body = JSON.parse(raw); } catch { return refuse(REFUSALS.badRequest("not JSON")); }
  if (!Array.isArray(body.messages) || body.messages.length === 0) return refuse(REFUSALS.badRequest("no messages"));
  const size = estimateMessagesInput(body);
  if (size.chars > MAX_INPUT_CHARS || size.images > 8) return refuse(REFUSALS.tooLarge());
  const maxOut = Math.min(MAX_OUTPUT_TOKENS, Math.max(1024, Number(body.max_tokens ?? MAX_OUTPUT_TOKENS)));
  const worst = (maxTokensForText(size.chars) + size.images * IMAGE_TOKENS) * ANTHROPIC_OPUS5.inputPerToken + maxOut * ANTHROPIC_OPUS5.outputPerToken;
  // Only these fields are forwarded; the model and the ceiling are the relay's.
  const forward = { model: env.ANTHROPIC_MODEL ?? "claude-opus-5", max_tokens: maxOut, messages: body.messages, fallbacks: "default",
                    ...(typeof body.system === "string" ? { system: body.system } : {}) };
  return metered(sub, "anthropic", worst, env, d, async () => {
    const res = await d.fetcher("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "content-type": "application/json", "x-api-key": env.ANTHROPIC_API_KEY, "anthropic-version": "2023-06-01",
                 "anthropic-beta": "server-side-fallback-2026-07-01" },
      body: JSON.stringify(forward),
    });
    const text = await res.text();
    let cost: number | null = null;
    try {
      const u = (JSON.parse(text) as { usage?: { input_tokens?: number; output_tokens?: number } }).usage;
      if (u) cost = actualCost(u.input_tokens ?? 0, u.output_tokens ?? 0, ANTHROPIC_OPUS5);
    } catch { /* an unreadable reply keeps the worst case */ }
    return { res: new Response(text, { status: res.status, headers: { "content-type": "application/json" } }), cost };
  });
}

async function transcribe(req: Request, sub: string, env: Env, d: Deps): Promise<Response> {
  let body: { audioBase64?: string; mimeType?: string };
  try { body = await req.json(); } catch { return refuse(REFUSALS.badRequest("not JSON")); }
  const audio = body.audioBase64 ?? "";
  const bytes = Math.floor(audio.length * 3 / 4);
  if (!audio || !body.mimeType?.startsWith("audio/") && !body.mimeType?.startsWith("video/")) return refuse(REFUSALS.badRequest("no audio"));
  if (bytes > MAX_AUDIO_BYTES) return refuse(REFUSALS.tooLarge());
  const p = geminiPrices(env);
  const worst = (Math.ceil(bytes / AUDIO_BYTES_PER_TOKEN) + 256) * p.inputPerToken + TRANSCRIPT_OUTPUT_TOKENS * p.outputPerToken;
  const model = env.GEMINI_MODEL ?? "gemini-2.5-flash";
  const prompt = "Transcribe this recording verbatim. Label each turn with a speaker label (Speaker 1, Speaker 2, …) and a start time [mm:ss]. Do not summarise, translate, correct or add anything; mark inaudible parts as [inaudible].";
  return metered(sub, "gemini", worst, env, d, async () => {
    const res = await d.fetcher(`https://generativelanguage.googleapis.com/v1beta/models/${encodeURIComponent(model)}:generateContent`, {
      method: "POST",
      headers: { "content-type": "application/json", "x-goog-api-key": env.GEMINI_API_KEY },
      body: JSON.stringify({
        contents: [{ role: "user", parts: [{ text: prompt }, { inline_data: { mime_type: body.mimeType, data: audio } }] }],
        generationConfig: { maxOutputTokens: TRANSCRIPT_OUTPUT_TOKENS, temperature: 0 },
      }),
    });
    const text = await res.text();
    let cost: number | null = null;
    try {
      const u = (JSON.parse(text) as { usageMetadata?: { promptTokenCount?: number; candidatesTokenCount?: number; thoughtsTokenCount?: number } }).usageMetadata;
      if (u) cost = actualCost(u.promptTokenCount ?? 0, (u.candidatesTokenCount ?? 0) + (u.thoughtsTokenCount ?? 0), p);
    } catch { /* keep the worst case */ }
    return { res: new Response(text, { status: res.status, headers: { "content-type": "application/json" } }), cost };
  });
}

async function topUp(req: Request, sub: string, env: Env, d: Deps): Promise<Response> {
  let body: { transactionId?: string };
  try { body = await req.json(); } catch { return refuse(REFUSALS.badRequest("not JSON")); }
  if (!body.transactionId) return refuse(REFUSALS.badRequest("no transactionId"));
  const now = d.now();
  const tx = await transactionInfo(body.transactionId, appleConfig(env), d.fetcher, now);
  if (!tx || tx.productId !== PRODUCTS.aiTopUp200 || !validTopUp(tx, now)) return refuse(REFUSALS.badRequest("not a valid top-up"));
  const credited = await d.store.creditTopUp(tx.transactionId, sub, tx.purchaseDate);
  const left = await d.store.remaining(monthKey(now), sub, now);
  return json({ credited, remaining: left });
}

export async function handle(req: Request, env: Env, d: Deps): Promise<Response> {
  const url = new URL(req.url);
  const sub = req.headers.get("x-kals-subscription")?.trim() ?? "";
  if (!/^[0-9]{1,32}$/.test(sub)) return refuse(REFUSALS.notSubscribed());
  try {
    if (!(await subscribed(sub, env, d))) return refuse(REFUSALS.notSubscribed());
  } catch {
    return refuse(REFUSALS.storeUnavailable());
  }
  const now = d.now(), month = monthKey(now);
  // GET or POST: the app's network helper sends POST only.
  if (url.pathname === "/v1/status") {
    const spentA = await d.store.spent(month, "anthropic");
    const b = budgets(env);
    return json({ active: true, remaining: await d.store.remaining(month, sub, now),
                  paused: spentA >= b.anthropic - usd(0.5), sellable: sellable(spentA, b.anthropic), month });
  }
  if (req.method !== "POST") return refuse(REFUSALS.badRequest("method"));
  if (url.pathname === "/v1/messages") return messages(req, sub, env, d);
  if (url.pathname === "/v1/transcribe") return transcribe(req, sub, env, d);
  if (url.pathname === "/v1/topup") return topUp(req, sub, env, d);
  return refuse(REFUSALS.badRequest("unknown path"));
}

/** Whether new buyers may be offered AI Included this month (no subscription needed to ask). */
export async function publicSellable(env: Env, d: Deps): Promise<Response> {
  const spentA = await d.store.spent(monthKey(d.now()), "anthropic");
  return json({ sellable: sellable(spentA, budgets(env).anthropic) });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const deps: Deps = { store: new D1Store(env.DB), fetcher: (u, i) => fetch(u, i), now: () => new Date() };
    if (new URL(req.url).pathname === "/v1/sellable") return publicSellable(env, deps);
    return handle(req, env, deps);
  },
};
