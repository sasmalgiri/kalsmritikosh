# AI relay (AI Included and AI Pro)

The small server behind the **AI Included** and **AI Pro** subscriptions of Investigations Made Easy. It
holds the publisher's Anthropic and Gemini keys (never the app), confirms each subscriber's plan with
Apple, meters every request in **credits** (1 credit = US$0.01 of real provider cost) and enforces a
global monthly safety cap. It stores **counts and credits only** — never a question, a passage or an
answer.

## Plans and credits (owner decisions 2026-11-04; the one place: `src/policy.ts`)
| Plan | Credits / month | One request | One confirmed whole-case read | Per day |
|---|---|---|---|---|
| AI Included (monthly $39 / yearly $389.99) | 2,000 | 400 | 600 | 1,500 |
| AI Pro (monthly $99 / yearly $989.99) | 6,000 (yearly: 5,400) | 400 | 3,000 | 4,000 |

* **Allowance month = anniversary month.** It starts at the purchase of the current subscription
  period (the renewal for monthly plans; the start of the year for yearly plans; the moment of an
  upgrade) and resets on that day every month (clamped to short months). Yearly plans get the same
  monthly allowance every month. Billing grace never opens a new month. Unused allowance does not
  carry over.
* **Credit packs** (500 credits $9.99, 2,000 credits $34.99, consumable) **never expire**. They are
  spent after the month's allowance (oldest first), only while an AI plan is active. A pack belongs to
  the Apple account's subscription group: the app buys it with `appAccountToken` =
  UUIDv5-layout(SHA-256("kals-credits:" + originalTransactionId)) and the relay credits it only to that
  subscription — so the balance survives reinstalling, another Mac, renewals, upgrades and
  resubscribing. A refunded/revoked pack loses its remaining credits (App Store Server Notification,
  re-checked with Apple, or the app reporting the refund).
* Workbench ($4.99 / $39.99, 14-day free trial) has no relay credits; its Online AI uses the person's own key.

## What it does per request
1. Asks Apple (App Store Server API) which AI plan is active and its current period (cached 10 minutes).
2. Estimates the **worst case**: input tokens (characters ÷ 3 + 64, images at 1,600 tokens) × the
   dearest input rate the request could be billed at (×2 if it asks for a 1-hour cache write, ×1.25 for
   a 5-minute one) + `max_tokens` (capped at 24,000) × the output rate.
3. Refuses (`too-costly`, 413) if that exceeds 400 credits — or the plan's case limit when the app sent
   `x-kals-large-read: confirmed` (only after the person confirmed the estimate).
4. Reserves the worst case against the global cap (refused with `capacity-paused` once 90 % of it is
   spent), then from the subscriber: the day's limit (`daily-limit`), the month's allowance, then credit
   packs (`credits-used` when it does not fit — nothing is sent, nothing is truncated).
5. Forwards with the model and output ceiling fixed here.
6. Reads `usage` (input, cache writes 5m/1h, cache reads, output incl. thinking) and charges the
   **actual** cost — rounded up to whole credits, at least 1, never more than reserved — and gives the
   rest back. A provider failure gives everything back.
7. Returns the provider's reply with a `kals` receipt: `charged`, `reserved`, `allowanceLeft`, `topUps`,
   `periodEndsAt`, the day's use and the plan's limits.

Rates (`ANTHROPIC_RATES`): claude-opus-5 $5 / MTok input, $25 / MTok output, cache write 5-min 1.25×,
1-hour 2×, cache read 0.1×, batch 50 %. Transcription (Gemini) is metered in credits too, against its
own cap. Settlement runs under `waitUntil`, so it finishes even if the app disconnects.

## Owner setup (one time, ~20 minutes)
1. Create a free Cloudflare account. Then, in this folder: `npx wrangler login`.
2. `npx wrangler d1 create kals-relay` — copy the printed `database_id` into `wrangler.toml`.
3. `npm run db:init`
4. Secrets (each command asks for the value):
   - `npx wrangler secret put ANTHROPIC_API_KEY` — from console.anthropic.com. Set a monthly spend limit
     there at or above `GLOBAL_CAP_USD`.
   - `npx wrangler secret put GEMINI_API_KEY` — from Google AI Studio, a billing-enabled project (set a
     budget alert at `GEMINI_BUDGET_USD`).
   - `npx wrangler secret put APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` — App Store
     Connect ▸ Users and Access ▸ Integrations ▸ **In-App Purchase** key (paste the whole .p8 file).
5. The global cap: `GLOBAL_CAP_USD` in `wrangler.toml` `[vars]` only (default `20` for App Review). To raise it,
   edit it and `npm run deploy` — before releasing the app to the public. Do not also create a secret with the
   same name (Cloudflare does not allow a var and a secret with one name).
6. `npm run deploy` — note the printed address (`https://kals-ai-relay.<you>.workers.dev`) and give
   it to the agent; the app is built with it.
7. App Store Connect ▸ the app ▸ App Information ▸ **App Store Server Notifications** (Version 2),
   production and sandbox URL: `https://kals-ai-relay.<you>.workers.dev/v1/apple-notifications`
   (refunded credit packs are then removed promptly).

## Retention and requests
A daily job (cron in `wrangler.toml`) deletes monthly counts older than 13 months, day counts after
40 days, credit packs that are used up (or refunded) 25 months after purchase — **a pack with credits
left is never deleted** — and Apple's status answers after a day. If a subscriber asks for their
record to be deleted (they give their App Store order number; find the original transaction id in
App Store Connect): `npx wrangler d1 execute kals-relay --remote --command "DELETE FROM allowance WHERE sub='<id>'; DELETE FROM daily WHERE sub='<id>'; DELETE FROM topups WHERE sub='<id>'; DELETE FROM status_cache WHERE sub='<id>'"`
(this also deletes their remaining pack credits — say so first).

## Tests
`npm test` (Node ≥ 23.6, no dependencies): refusals, the model and ceiling, actual-cost charging with
cache splits, reservation and refund, provider failure, allowance then packs, packs never expiring and
bound to their subscription, refunded packs and notifications, the global cap under 40 concurrent
requests and the 90 % stop, the daily limit and the large-read limit, yearly anniversary months and
grace, upgrade to AI Pro, Gemini metering, retention, and that nothing a request contains is stored.
