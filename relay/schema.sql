-- AI relay (Cloudflare D1). Counts and credits only — no request or answer content is ever stored.
-- Owner decisions 2026-11-04: credits (1 credit = US$0.01 of provider cost), never-expiring credit packs.
-- First deployment: `npm run db:init`. (The earlier question-count tables were never deployed.)
CREATE TABLE IF NOT EXISTS spend (
  month    TEXT NOT NULL,              -- "2026-11" (UTC calendar month, as the providers bill)
  provider TEXT NOT NULL,              -- "anthropic" | "gemini"
  micro    INTEGER NOT NULL DEFAULT 0, -- micro-dollars reserved/spent this month over all subscribers
  PRIMARY KEY (month, provider)
);
CREATE TABLE IF NOT EXISTS allowance (
  sub    TEXT NOT NULL,                -- the App Store originalTransactionId of the AI plan's subscription group
  period TEXT NOT NULL,                -- ISO start of the allowance month (anniversary of the period's purchase)
  used   INTEGER NOT NULL DEFAULT 0,   -- credits used from the plan's monthly allowance
  PRIMARY KEY (sub, period)
);
CREATE TABLE IF NOT EXISTS daily (
  sub  TEXT NOT NULL,
  day  TEXT NOT NULL,                  -- "2026-11-04" (UTC)
  used INTEGER NOT NULL DEFAULT 0,     -- credits charged that day (abuse limit)
  PRIMARY KEY (sub, day)
);
CREATE TABLE IF NOT EXISTS topups (
  transaction_id TEXT PRIMARY KEY,     -- the credit pack's App Store transactionId (credited once)
  sub            TEXT NOT NULL,        -- the subscription it was bought for (appAccountToken checked)
  product_id     TEXT NOT NULL,
  purchased_at   INTEGER NOT NULL,     -- ms since epoch; packs never expire
  credits        INTEGER NOT NULL,
  remaining      INTEGER NOT NULL,
  revoked        INTEGER NOT NULL DEFAULT 0  -- 1 once Apple reports it refunded/revoked (remaining set to 0)
);
CREATE INDEX IF NOT EXISTS topups_by_sub ON topups (sub, purchased_at);
CREATE TABLE IF NOT EXISTS status_cache (
  sub        TEXT PRIMARY KEY,
  tier       TEXT,                     -- "ai" | "pro" | NULL (no AI plan) as Apple last reported
  anchor     INTEGER NOT NULL,         -- ms: purchase of the current period (allowance anniversary)
  expires    INTEGER NOT NULL,         -- ms: end of the current period
  checked_at INTEGER NOT NULL,         -- ms since epoch; re-checked with Apple after 10 minutes
  yearly     INTEGER NOT NULL DEFAULT 0 -- 1 = a yearly plan (AI Pro yearly: 5,400 credits a month, not 6,000)
);
