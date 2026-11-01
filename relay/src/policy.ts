// AI Included relay — the pure rules (no I/O), so they are tested exactly as they run.
//
// Owner decisions 2026-11-01: AI Included gives 300 questions a month per subscriber (+ 200-question
// top-ups); the owner pays nothing — a HARD monthly spend cap ($20 Anthropic, $5 Gemini) is never
// exceeded, because each request's worst-case cost is reserved BEFORE it is forwarded and only the
// actual cost is kept afterwards. Nothing a request contains is stored or logged; only counts.

export const MONTHLY_QUESTIONS = 300;
export const TOPUP_QUESTIONS = 200;
/** A top-up is usable for twelve months from its purchase. */
export const TOPUP_VALID_DAYS = 365;

/** Micro-dollars (1e-6 USD) — integer arithmetic for money. */
export type Micro = number;
export const usd = (dollars: number): Micro => Math.round(dollars * 1_000_000);

export interface Prices {
  /** Micro-dollars per input token and per output token. */
  inputPerToken: Micro;
  outputPerToken: Micro;
}

/** Claude Opus 5 list price: $5 / MTok input, $25 / MTok output → 5 and 25 micro-dollars per token. */
export const ANTHROPIC_OPUS5: Prices = { inputPerToken: 5, outputPerToken: 25 };

/** The provider budget a request draws on. */
export type Provider = "anthropic" | "gemini";

/** The calendar month a count belongs to, in UTC ("2026-11"). */
export function monthKey(now: Date): string {
  return now.toISOString().slice(0, 7);
}

/** Tokens a text is at most worth, conservatively (≈ 3 characters per token; real English is ~4). */
export function maxTokensForText(chars: number): number {
  return Math.ceil(chars / 3) + 64;
}

/** The worst case a request can cost: all of its input plus its full output allowance. */
export function worstCaseCost(inputChars: number, maxOutputTokens: number, p: Prices): Micro {
  return maxTokensForText(inputChars) * p.inputPerToken + maxOutputTokens * p.outputPerToken;
}

/** What the provider reported it actually used. */
export function actualCost(inputTokens: number, outputTokens: number, p: Prices): Micro {
  return Math.max(0, inputTokens) * p.inputPerToken + Math.max(0, outputTokens) * p.outputPerToken;
}

/** The output ceiling the relay enforces whatever the app asks for (cost control). */
export const MAX_OUTPUT_TOKENS = 4096;
/** The largest request body the relay forwards (keeps the worst case bounded). */
export const MAX_INPUT_CHARS = 120_000;

export type Refusal =
  | { code: "not-subscribed"; message: string }
  | { code: "quota-used"; message: string }
  | { code: "capacity-paused"; message: string }
  | { code: "too-large"; message: string }
  | { code: "bad-request"; message: string }
  | { code: "store-unavailable"; message: string }
  | { code: "region-unavailable"; message: string };

export const REFUSALS = {
  notSubscribed: (): Refusal => ({ code: "not-subscribed", message: "AI Included is not active for this Apple account. Subscribe, restore your purchase, or add your own AI key in Settings." }),
  quotaUsed: (): Refusal => ({ code: "quota-used", message: "This month's AI Included questions are used up. Buy 200 more, wait for the next month, or add your own AI key in Settings." }),
  capacityPaused: (): Refusal => ({ code: "capacity-paused", message: "AI Included has reached this month's service capacity and is paused until the 1st. Everything else keeps working, and you can add your own AI key in Settings." }),
  tooLarge: (): Refusal => ({ code: "too-large", message: "This request is larger than AI Included accepts. Select fewer passages and try again." }),
  badRequest: (why: string): Refusal => ({ code: "bad-request", message: `The request was not in the expected form: ${why}` }),
  storeUnavailable: (): Refusal => ({ code: "store-unavailable", message: "The App Store could not confirm the subscription just now. Nothing was sent; try again in a minute." }),
  regionUnavailable: (): Refusal => ({ code: "region-unavailable", message: "AI Included is not available where this request comes from. Nothing was sent; everything else in the app keeps working." }),
};

/** The same countries as AI_BLOCKED_STOREFRONTS, as the two-letter codes Cloudflare reports for a request. */
export const AI_BLOCKED_REQUEST_COUNTRIES: readonly string[] = ["CN", "HK", "MO", "RU", "BY", "VE", "AF", "MM", "YE", "IR", "KP", "SY", "CU"];

/** HTTP status for each refusal. */
export function statusFor(r: Refusal): number {
  switch (r.code) {
    case "not-subscribed": return 402;
    case "quota-used": return 429;
    case "capacity-paused": return 503;
    case "too-large": return 413;
    case "bad-request": return 400;
    case "store-unavailable": return 503;
    case "region-unavailable": return 451;
  }
}

/** New buyers are not offered AI Included once this share of the month's budget is spent. */
export const SELL_STOP_SHARE = 0.9;

export function sellable(spent: Micro, budget: Micro): boolean {
  return spent < Math.floor(budget * SELL_STOP_SHARE);
}

/** Product identifiers (must match the app and App Store Connect). */
export const PRODUCTS = {
  aiMonthly: "ecosanskritiinnovation.Kalsmritikosh.ai.monthly",
  aiAnnual: "ecosanskritiinnovation.Kalsmritikosh.ai.annual",
  aiTopUp200: "ecosanskritiinnovation.Kalsmritikosh.ai.topup200",
};

/** The subset of Apple's decoded transaction the relay reads. */
export interface AppleTransaction {
  productId: string;
  originalTransactionId: string;
  transactionId: string;
  expiresDate?: number;      // ms since epoch (subscriptions)
  purchaseDate: number;      // ms since epoch
  revocationDate?: number;   // set when refunded or revoked
  storefront?: string;       // ISO 3166-1 alpha-3 App Store country of the purchase
}

/** A3 — App Store storefronts where generative AI is off. Keep identical to AIRegion.blocked in the app. */
export const AI_BLOCKED_STOREFRONTS: readonly string[] = ["CHN", "HKG", "MAC", "RUS", "BLR", "VEN", "AFG", "MMR", "YEM", "IRN", "PRK", "SYR", "CUB"];

/** Apple's subscription status values (App Store Server API). */
export const APPLE_STATUS = { active: 1, expired: 2, billingRetry: 3, gracePeriod: 4, revoked: 5 } as const;

/** Whether a subscription status entry grants AI Included now. Grace counts; billing retry does not. */
export function grantsAI(status: number, tx: AppleTransaction, now: Date): boolean {
  if (tx.productId !== PRODUCTS.aiMonthly && tx.productId !== PRODUCTS.aiAnnual) return false;
  if (tx.revocationDate) return false;
  if (tx.storefront && AI_BLOCKED_STOREFRONTS.includes(tx.storefront.toUpperCase())) return false;
  if (status === APPLE_STATUS.active) return (tx.expiresDate ?? 0) > now.getTime();
  return status === APPLE_STATUS.gracePeriod;
}

/** Whether a consumable transaction is a valid, unrevoked top-up still inside its twelve months. */
export function validTopUp(tx: AppleTransaction, now: Date): boolean {
  if (tx.productId !== PRODUCTS.aiTopUp200 || tx.revocationDate) return false;
  return now.getTime() - tx.purchaseDate < TOPUP_VALID_DAYS * 86_400_000;
}
