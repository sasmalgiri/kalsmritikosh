# AI Included relay

The small server behind the **AI Included** subscription of Investigations Made Easy. It holds the
publisher's Anthropic and Gemini keys (never the app), confirms each subscriber with Apple, counts
300 questions a month (plus 200-question top-ups), and enforces hard monthly spend caps
($20 Anthropic, $5 Gemini). It stores **counts only** — never a question, a passage or an answer.

## What it does per request
1. Asks Apple (App Store Server API) whether the subscription is active (cached 10 minutes).
2. Takes one question from the month's 300, then from a valid top-up.
3. Reserves the request's worst-case cost against the cap — it is refused (and the question given
   back) if the worst case would not fit, so the cap can never be exceeded.
4. Forwards with the model and output ceiling fixed here.
5. Keeps the actual cost; a provider failure gives the question and the money back.
When 90 % of the month's Anthropic budget is spent, the app stops offering AI Included to new buyers
(`GET /v1/sellable`).

## Owner setup (one time, ~15 minutes)
1. Create a free Cloudflare account. Then, in this folder: `npx wrangler login`.
2. `npx wrangler d1 create kals-relay` — copy the printed `database_id` into `wrangler.toml`.
3. `npm run db:init`
4. Secrets (each command asks for the value):
   - `npx wrangler secret put ANTHROPIC_API_KEY` — from console.anthropic.com (set the same $20
     monthly spend limit there too).
   - `npx wrangler secret put GEMINI_API_KEY` — from Google AI Studio (set a $5 budget alert there).
   - `npx wrangler secret put APPLE_ISSUER_ID`, `APPLE_KEY_ID`, `APPLE_PRIVATE_KEY` — App Store
     Connect ▸ Users and Access ▸ Integrations ▸ **In-App Purchase** key (paste the whole .p8 file).
5. `npm run deploy` — note the printed address (`https://kals-ai-relay.<you>.workers.dev`) and give
   it to the agent; the app is built with it.

## Retention and requests
A daily job (cron in `wrangler.toml`) deletes monthly counts older than 13 months, top-up records 25 months after
purchase, and Apple's status answers after a day — as the privacy policy states. If a subscriber asks for their
record to be deleted (they give their App Store order number; find the original transaction id in App Store Connect):
`npx wrangler d1 execute kals-relay --remote --command "DELETE FROM usage WHERE sub='<id>'; DELETE FROM topups WHERE sub='<id>'; DELETE FROM status_cache WHERE sub='<id>'"`.

## Tests
`npm test` (Node 24, no dependencies): quota, top-ups credited once, refunds, sandbox fallback,
grace period, the cap under 40 concurrent requests, and that nothing a request contains is stored.
