// AI relay — the pure rules (no I/O), so they are tested exactly as they run.
//
// Owner decisions 2026-11-04 (plans and credits). THIS FILE IS THE ONE PLACE the plan parameters,
// the product ids and the price table live; the app mirrors them for display only
// (Kalsmritikosh/Routing/Providers/Online/AIPricing.swift, checked by ci/guards/relay-host-match.sh).
//
// • 1 credit = US$0.01 of real provider cost (Anthropic's published rates below).
// • AI Included: 2,000 credits a month (monthly and yearly). AI Pro: 6,000 a month on the monthly plan,
//   5,400 a month on the yearly plan (owner decision 2026-11-04: at Apple's 15 % commission and 27 % VAT
//   included, a fully used 6,000 would cost more than AI Pro yearly earns; AI Included yearly stays covered).
// • Allowance month = ANNIVERSARY month: it starts on the day of the current subscription period's
//   purchase (Apple's `purchaseDate` of the latest transaction — the renewal for monthly plans, the
//   start of the year for yearly plans, the moment of an upgrade) and resets on that day each month
//   (clamped to the month's last day). Unused allowance does not carry over.
// • Top-up packs (500 / 2,000 credits) NEVER expire (App Review 3.1.1). They are spent after the month's
//   allowance, only while an AI plan is active, and belong to the Apple account's subscription group
//   (its originalTransactionId, which survives reinstall, another Mac, renewals, upgrades and
//   resubscribing). A refunded or revoked pack loses its remaining credits.
// • Every request reserves its WORST-CASE cost first (monthly allowance, then top-ups, oldest first),
//   is forwarded, then is charged its ACTUAL cost (rounded up to whole credits, at least 1); the rest is
//   given back. A provider failure gives everything back. Nothing a request contains is stored.
// • A global monthly safety cap (GLOBAL_CAP_USD, default $20 until launch) over all subscribers: at 90 %
//   of it AI plans stop being sold and new reservations are refused. Gemini transcription has its own
//   cap (GEMINI_BUDGET_USD, default $5) and is metered in credits too.

/** Micro-dollars (1e-6 USD) — integer arithmetic for money. */
export type Micro = number;
export const usd = (dollars: number): Micro => Math.round(dollars * 1_000_000);

/** One credit is one US cent of provider cost. */
export const CREDIT_MICRO: Micro = 10_000;

// MARK: - Plans

export type Tier = "ai" | "pro";

export interface PlanPolicy {
  label: string;
  /** Credits each allowance month on the monthly plan. */
  monthlyCredits: number;
  /** Credits each allowance month on the yearly plan. */
  yearlyMonthlyCredits: number;
  /** The most one ordinary request may reserve. */
  perRequestCredits: number;
  /** The most one confirmed "large read" (reading the whole case) may reserve. */
  caseReadCredits: number;
  /** Abuse limit: credits charged per UTC day. */
  dailyCredits: number;
  /** The most case text (estimated tokens, `maxTokensForText`) the app offers to read whole on this plan.
   *  The app derives its whole-case limit from this and caps it so the worst-case reservation of such a
   *  read always fits `caseReadCredits` and LARGE_READ_MAX_INPUT_CHARS (AIPricing.caseReadTokenCeiling). */
  caseReadTokens: number;
}

export const PLANS: Record<Tier, PlanPolicy> = {
  ai:  { label: "AI Included", monthlyCredits: 2_000, yearlyMonthlyCredits: 2_000, perRequestCredits: 400, caseReadCredits:   600, dailyCredits: 1_500, caseReadTokens: 300_000 },
  pro: { label: "AI Pro",      monthlyCredits: 6_000, yearlyMonthlyCredits: 5_400, perRequestCredits: 400, caseReadCredits: 3_000, dailyCredits: 4_000, caseReadTokens: 800_000 },
};
const TIER_RANK: Record<Tier, number> = { ai: 1, pro: 2 };
export const higherTier = (a: Tier | null, b: Tier | null): Tier | null =>
  a === null ? b : b === null ? a : (TIER_RANK[b] > TIER_RANK[a] ? b : a);

/** Product identifiers (must match the app, the .storekit file and App Store Connect). */
export const PRODUCTS = {
  workbenchMonthly: "ecosanskritiinnovation.Kalsmritikosh.edition.monthly",
  workbenchAnnual: "ecosanskritiinnovation.Kalsmritikosh.edition.annual",
  aiMonthly: "ecosanskritiinnovation.Kalsmritikosh.ai.monthly",
  aiAnnual: "ecosanskritiinnovation.Kalsmritikosh.ai.annual",
  proMonthly: "ecosanskritiinnovation.Kalsmritikosh.aipro.monthly",
  proAnnual: "ecosanskritiinnovation.Kalsmritikosh.aipro.annual",
  credits500: "ecosanskritiinnovation.Kalsmritikosh.ai.credits500",
  credits2000: "ecosanskritiinnovation.Kalsmritikosh.ai.credits2000",
} as const;

/** The yearly subscription products (their allowance month is `yearlyMonthlyCredits`). */
export const YEARLY_PRODUCTS: readonly string[] = [PRODUCTS.workbenchAnnual, PRODUCTS.aiAnnual, PRODUCTS.proAnnual];

/** The credits of one allowance month for `tier` on a monthly or a yearly plan. */
export const monthlyAllowance = (tier: Tier, yearly: boolean): number =>
  yearly ? PLANS[tier].yearlyMonthlyCredits : PLANS[tier].monthlyCredits;

/** Which AI tier a subscription product grants (Workbench grants none). */
export const TIER_OF_PRODUCT: Record<string, Tier> = {
  [PRODUCTS.aiMonthly]: "ai", [PRODUCTS.aiAnnual]: "ai", [PRODUCTS.proMonthly]: "pro", [PRODUCTS.proAnnual]: "pro",
};

/** Credits in each consumable pack. */
export const TOPUP_CREDITS: Record<string, number> = { [PRODUCTS.credits500]: 500, [PRODUCTS.credits2000]: 2_000 };

// MARK: - Prices (Anthropic's published rates; keep at Anthropic's list price)

export interface ModelRates {
  inputPerMTok: number;     // USD per million input tokens
  outputPerMTok: number;    // USD per million output tokens (thinking tokens are billed as output)
  cacheWrite5m: number;     // × input price
  cacheWrite1h: number;     // × input price
  cacheRead: number;        // × input price
  batch: number;            // × every price (Batch API; the relay does not use it)
}

// Package B (2026-11-06): the relay answers with Claude Opus 5.5 ($4 / $20 per MTok; cache reads $0.20 =
// 0.05× input — Anthropic's published rate, not the 0.1× of earlier models; cache writes 1.25× / 2×).
// Claude Opus 5 and Opus 4.8 stay in the table because Anthropic's server-side fallback (`fallbacks:
// "default"`) may answer a declined request with one of them, billed at THEIR rates.
export const ANTHROPIC_RATES: Record<string, ModelRates> = {
  "claude-opus-5-5": { inputPerMTok: 4, outputPerMTok: 20, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.05, batch: 0.5 },
  "claude-opus-5": { inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5 },
  "claude-opus-4-8": { inputPerMTok: 5, outputPerMTok: 25, cacheWrite5m: 1.25, cacheWrite1h: 2, cacheRead: 0.1, batch: 0.5 },
};
export const DEFAULT_ANTHROPIC_MODEL = "claude-opus-5-5";
/** The models Anthropic's server-side fallback may answer with when the relay's model declines. */
export const FALLBACK_MODELS: readonly string[] = ["claude-opus-5", "claude-opus-4-8"];

/** Every price at the dearest of `models` (field by field) — what a request may be billed at at worst.
 *  An unknown model counts as the dearest model in the table. */
export function dearestRates(models: readonly string[]): ModelRates {
  const known = models.map((m) => ANTHROPIC_RATES[m]).filter((r): r is ModelRates => r !== undefined);
  const pool = known.length === models.length && known.length > 0 ? known : Object.values(ANTHROPIC_RATES);
  const max = (f: (r: ModelRates) => number) => Math.max(...pool.map(f));
  return { inputPerMTok: max((r) => r.inputPerMTok), outputPerMTok: max((r) => r.outputPerMTok), cacheWrite5m: max((r) => r.cacheWrite5m),
           cacheWrite1h: max((r) => r.cacheWrite1h), cacheRead: max((r) => r.cacheRead), batch: max((r) => r.batch) };
}
/** The rates of a model that answered (an unknown one: the dearest in the table). */
export const ratesFor = (model: string): ModelRates => ANTHROPIC_RATES[model] ?? dearestRates([]);
/** What a request to `model` is RESERVED at: the dearest of the model and its fallbacks, so a declined
 *  request answered by a fallback model never costs more than was reserved. */
export const reservationRates = (model: string): ModelRates => dearestRates([model, ...FALLBACK_MODELS]);

/** Effort levels the app may ask for; the relay always sends one (Opus 5.5's own default is `medium`,
 *  Opus 5's was `high` — the relay keeps `high` when the app does not ask, so nothing changes silently). */
export const EFFORTS: readonly string[] = ["low", "medium", "high"];
export const DEFAULT_EFFORT = "high";
export const effortFor = (asked: unknown): string =>
  typeof asked === "string" && EFFORTS.includes(asked) ? asked : DEFAULT_EFFORT;

/** What Anthropic reports a request used (`usage` of a Messages reply). */
export interface AnthropicUsage {
  input_tokens?: number;
  output_tokens?: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
  cache_creation?: { ephemeral_5m_input_tokens?: number; ephemeral_1h_input_tokens?: number };
}

const n0 = (x: unknown) => (typeof x === "number" && x > 0 ? x : 0);

/** The actual cost of a reply, in micro-dollars (rounded up). Cache writes without a 5m/1h split are
 *  counted at the dearer 1-hour rate. */
export function anthropicCost(u: AnthropicUsage, r: ModelRates, batch = false): Micro {
  const created = n0(u.cache_creation_input_tokens);
  const w5 = n0(u.cache_creation?.ephemeral_5m_input_tokens);
  // Any written token the split does not account for is counted at the 1-hour rate.
  const w1 = Math.max(n0(u.cache_creation?.ephemeral_1h_input_tokens), created - w5);
  const perIn = r.inputPerMTok; // USD per MTok == micro-dollars per token
  const usdMicro = n0(u.input_tokens) * perIn + w5 * perIn * r.cacheWrite5m + w1 * perIn * r.cacheWrite1h
    + n0(u.cache_read_input_tokens) * perIn * r.cacheRead + n0(u.output_tokens) * r.outputPerMTok;
  return Math.ceil(usdMicro * (batch ? r.batch : 1));
}

// MARK: - Size estimate (THE estimator; the app uses the same constants: AIPricing.maxTokensForText)
//
// The relay never sees a token count before the provider answers, so it sizes a request from its text:
// at most one token per CHARS_PER_TOKEN characters (English is ~4; 3 leaves room for code, numbers and
// other scripts), plus TOKEN_OVERHEAD for the message framing, plus IMAGE_TOKENS per image or document
// block (Claude's own ceiling after resizing). Characters are JavaScript string length (UTF-16 code
// units); the app counts UTF-8 bytes, which are never fewer, so its estimate is never below this one.

/** Characters per token in the conservative estimate. */
export const CHARS_PER_TOKEN = 3;
/** Tokens added once per request for the message framing. */
export const TOKEN_OVERHEAD = 64;
/** Claude bills an image at most ~1,600 tokens after its own resizing; counted at that ceiling. */
export const IMAGE_TOKENS = 1_600;

/** Tokens a text is at most worth, conservatively. */
export function maxTokensForText(chars: number): number {
  return Math.ceil(chars / CHARS_PER_TOKEN) + TOKEN_OVERHEAD;
}

/** Tokens a Messages request's input is at most worth: its text characters and its images. */
export function maxInputTokens(chars: number, images: number): number {
  return maxTokensForText(chars) + images * IMAGE_TOKENS;
}

/** How a request's input could be billed at worst: plain, or written to a 5-minute / 1-hour cache. */
export type CacheUse = "none" | "5m" | "1h";

/** The worst case a Messages request can cost: every input token at the dearest rate it could be
 *  billed at, plus the full output allowance. */
export function worstCaseCost(inputTokens: number, maxOutputTokens: number, r: ModelRates, cache: CacheUse): Micro {
  const mult = cache === "1h" ? r.cacheWrite1h : cache === "5m" ? r.cacheWrite5m : 1;
  return Math.ceil(inputTokens * r.inputPerMTok * Math.max(1, mult) + maxOutputTokens * r.outputPerMTok);
}

/** Gemini's cost from its own usage numbers (prices in micro-dollars per token, set in wrangler.toml). */
export function tokenCost(inputTokens: number, outputTokens: number, inputMicro: number, outputMicro: number): Micro {
  return Math.ceil(n0(inputTokens) * inputMicro + n0(outputTokens) * outputMicro);
}

/** Micro-dollars to whole credits: rounded up, at least 1. */
export function creditsFor(micro: Micro): number {
  return Math.max(1, Math.ceil(micro / CREDIT_MICRO));
}

/** Sandbox (TestFlight, App Review) credits per UTC day when SANDBOX_DAILY_CREDITS is not set: one
 *  allowance per real day (sandbox renewals come every few minutes), also the sandbox daily limit. */
export const SANDBOX_DAILY_CREDITS = 100;

/** The output ceiling the relay enforces whatever the app asks for (reply + thinking room). */
export const MAX_OUTPUT_TOKENS = 24_000;
/** The largest ordinary request the relay forwards (text characters). */
export const MAX_INPUT_CHARS = 120_000;
/** A confirmed large read (the whole case) may carry this much (text characters, the question and the
 *  system prompt included); its credits are capped by the plan. AI Pro's 800k-token whole-case limit is
 *  at most 2,400,000 characters of case text by the estimate above, which leaves room for the task. */
export const LARGE_READ_MAX_INPUT_CHARS = 2_800_000;

// MARK: - Allowance months

function addMonthsUTC(t: number, months: number): number {
  const d = new Date(t);
  const y = d.getUTCFullYear(), m = d.getUTCMonth() + months, day = d.getUTCDate();
  const last = new Date(Date.UTC(y, m + 1, 0)).getUTCDate();
  return Date.UTC(y, m, Math.min(day, last), d.getUTCHours(), d.getUTCMinutes(), d.getUTCSeconds(), d.getUTCMilliseconds());
}

/** The allowance month `now` falls in, counted from `anchor` (the current period's purchase). A month
 *  never starts at or after `expires`, so billing grace never opens a new allowance. */
export function allowancePeriod(anchor: number, expires: number, now: number): { key: string; startsAt: number; endsAt: number } {
  let n = 0;
  while (addMonthsUTC(anchor, n + 1) <= now && addMonthsUTC(anchor, n + 1) < expires && n < 1200) n += 1;
  const startsAt = addMonthsUTC(anchor, n);
  return { key: new Date(startsAt).toISOString(), startsAt, endsAt: addMonthsUTC(anchor, n + 1) };
}

/** The calendar month a provider's spend belongs to, in UTC ("2026-11") — providers bill by it. */
export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}
export function dayKey(now: Date): string {
  return now.toISOString().slice(0, 10);
}

// MARK: - The global safety cap

/** New buyers are not offered AI plans, and new reservations are refused, once this share is spent. */
export const SELL_STOP_SHARE = 0.9;

export function sellable(spent: Micro, cap: Micro): boolean {
  return spent < Math.floor(cap * SELL_STOP_SHARE);
}

// MARK: - Settlement

export interface TopUpTake { id: string; n: number }

/** After a reply: what to give back. The charge is taken from the allowance first (it expires; top-ups
 *  do not), so refunds go to the top-ups first, in the reverse order they were taken. */
export function refundSplit(fromAllowance: number, fromTopUps: TopUpTake[], charged: number): { allowance: number; topUps: TopUpTake[] } {
  const keepAllowance = Math.min(fromAllowance, charged);
  let keepTopUps = charged - keepAllowance;
  const back: TopUpTake[] = [];
  for (const t of fromTopUps) {
    const keep = Math.min(t.n, keepTopUps);
    keepTopUps -= keep;
    if (t.n - keep > 0) back.push({ id: t.id, n: t.n - keep });
  }
  return { allowance: fromAllowance - keepAllowance, topUps: back.reverse() };
}

// MARK: - Refusals

export type RefusalCode =
  | "not-subscribed" | "credits-used" | "daily-limit" | "too-costly" | "capacity-paused" | "too-large"
  | "bad-request" | "store-unavailable" | "region-unavailable" | "provider-unavailable";
export interface Refusal { code: RefusalCode; message: string; estimate?: number; balance?: number }

export const REFUSALS = {
  notSubscribed: (): Refusal => ({ code: "not-subscribed", message: "No AI plan (AI Included or AI Pro) is active for this Apple account. Subscribe, restore your purchase, or use your own AI key in Settings." }),
  creditsUsed: (estimate: number, balance: number): Refusal => ({ code: "credits-used", estimate, balance,
    message: `This request needs up to ${estimate} credits and ${balance} are left (this month's allowance and your credit packs). Nothing was sent. Buy a credit pack, wait for the allowance to reset, or use your own AI key in Settings.` }),
  dailyLimit: (limit: number): Refusal => ({ code: "daily-limit", message: `Today's AI limit of ${limit} credits for this plan is reached. Nothing was sent; it resets at midnight UTC.` }),
  tooCostly: (estimate: number, ceiling: number, large: boolean): Refusal => ({ code: "too-costly", estimate,
    message: large
      ? `Reading this much at once needs up to ${estimate} credits, more than this plan's ${ceiling}-credit limit for one read. Nothing was sent; select fewer documents (AI Pro reads more at once).`
      : `This request needs up to ${estimate} credits, more than the ${ceiling} one request may use. Nothing was sent; select fewer passages, or confirm it as a large read.` }),
  capacityPaused: (): Refusal => ({ code: "capacity-paused", message: "The AI service has reached this month's capacity and is paused until the 1st. Nothing was charged; everything else keeps working, and you can use your own AI key in Settings." }),
  tooLarge: (): Refusal => ({ code: "too-large", message: "This request is larger than the AI service accepts. Select fewer passages and try again." }),
  badRequest: (why: string): Refusal => ({ code: "bad-request", message: `The request was not in the expected form: ${why}` }),
  storeUnavailable: (): Refusal => ({ code: "store-unavailable", message: "The App Store could not confirm the subscription just now. Nothing was sent; try again in a minute." }),
  // After the request was handed to the provider: it may have reached it, so never "Nothing was sent".
  // What is charged is exact: metered() gives every reserved credit back when the provider does not answer.
  providerUnavailable: (): Refusal => ({ code: "provider-unavailable", message: "The AI service did not answer. Your request may have reached it; no credits were charged for it. Try again in a minute." }),
  regionUnavailable: (): Refusal => ({ code: "region-unavailable", message: "AI plans are not available where this request comes from. Nothing was sent; everything else in the app keeps working." }),
};

/** HTTP status for each refusal. */
export function statusFor(r: Refusal): number {
  switch (r.code) {
    case "not-subscribed": return 402;
    case "credits-used": return 402;
    case "daily-limit": return 429;
    case "too-costly": return 413;
    case "capacity-paused": return 503;
    case "too-large": return 413;
    case "bad-request": return 400;
    case "store-unavailable": return 503;
    case "region-unavailable": return 451;
    case "provider-unavailable": return 502;
  }
}

/** The same countries as AI_BLOCKED_STOREFRONTS, as the two-letter codes Cloudflare reports for a request. */
export const AI_BLOCKED_REQUEST_COUNTRIES: readonly string[] = ["CN", "HK", "MO", "RU", "BY", "VE", "AF", "MM", "YE", "IR", "KP", "SY", "CU"];

// MARK: - Apple

/** The subset of Apple's decoded transaction the relay reads. */
export interface AppleTransaction {
  productId: string;
  originalTransactionId: string;
  transactionId: string;
  expiresDate?: number;      // ms since epoch (subscriptions)
  purchaseDate: number;      // ms since epoch
  revocationDate?: number;   // set when refunded or revoked
  storefront?: string;       // ISO 3166-1 alpha-3 App Store country of the purchase
  appAccountToken?: string;  // UUID the app set at purchase (top-ups: bound to the subscription)
}

/** A3 — App Store storefronts where generative AI is off. Keep identical to AIRegion.blocked in the app. */
export const AI_BLOCKED_STOREFRONTS: readonly string[] = ["CHN", "HKG", "MAC", "RUS", "BLR", "VEN", "AFG", "MMR", "YEM", "IRN", "PRK", "SYR", "CUB"];

/** Apple's subscription status values (App Store Server API). */
export const APPLE_STATUS = { active: 1, expired: 2, billingRetry: 3, gracePeriod: 4, revoked: 5 } as const;

/** The AI tier a subscription status entry grants now (null = none). Grace counts; billing retry does not. */
export function grantedTier(status: number, tx: AppleTransaction, now: Date): Tier | null {
  const tier = TIER_OF_PRODUCT[tx.productId];
  if (!tier || tx.revocationDate) return null;
  if (tx.storefront && AI_BLOCKED_STOREFRONTS.includes(tx.storefront.toUpperCase())) return null;
  if (status === APPLE_STATUS.active) return (tx.expiresDate ?? 0) > now.getTime() ? tier : null;
  return status === APPLE_STATUS.gracePeriod ? tier : null;
}

/** Whether a consumable transaction is an unrevoked credit pack. Packs never expire. */
export function validTopUp(tx: AppleTransaction): boolean {
  return TOPUP_CREDITS[tx.productId] !== undefined && !tx.revocationDate;
}

/** The appAccountToken the app sets when it buys a pack for subscription `sub`: a UUID from
 *  SHA-256("kals-credits:" + sub) (RFC 4122 version 5 layout). Mirrored in AIIncludedRelay.accountToken. */
export async function accountToken(sub: string): Promise<string> {
  const h = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(`kals-credits:${sub}`))).slice(0, 16);
  h[6] = (h[6] & 0x0f) | 0x50;
  h[8] = (h[8] & 0x3f) | 0x80;
  const hex = [...h].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
