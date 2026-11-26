-- AI relay (Cloudflare D1). Counts and credits only — no request or answer content is ever stored.
-- Owner decisions 2026-11-04: credits (1 credit = US$0.01 of provider cost), never-expiring credit packs.
-- First deployment: `npm run db:init`. (The earlier question-count tables were never deployed.)
-- Pay as you go (owner decision 2026-11-15) needs NO schema change: a pack-only account is a `sub` value of the form
-- "token:<uuid>" in `topups` and `daily` (no `allowance` row is ever written for it). A relay already initialised keeps
-- its database as it is; `npm run db:init` stays idempotent (CREATE ... IF NOT EXISTS).
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
  sub  TEXT NOT NULL,                  -- the AI subscription, or a pay-as-you-go "token:<uuid>" account
  day  TEXT NOT NULL,                  -- "2026-11-04" (UTC)
  used INTEGER NOT NULL DEFAULT 0,     -- credits charged that day (abuse limit)
  PRIMARY KEY (sub, day)
);
CREATE TABLE IF NOT EXISTS topups (
  transaction_id TEXT PRIMARY KEY,     -- the credit pack's App Store transactionId (credited once)
  sub            TEXT NOT NULL,        -- the account: the AI subscription it was bought for (originalTransactionId), or, pay as
                                       -- you go (2026-11-15), "token:<appAccountToken>" / "sandbox-token:<appAccountToken>"
  product_id     TEXT NOT NULL,
  purchased_at   INTEGER NOT NULL,     -- ms since epoch; packs never expire
  credits        INTEGER NOT NULL,
  remaining      INTEGER NOT NULL,
  revoked        INTEGER NOT NULL DEFAULT 0  -- 1 once Apple reports it refunded/revoked (remaining set to 0)
);
CREATE INDEX IF NOT EXISTS topups_by_sub ON topups (sub, purchased_at);
-- Unified path AI-24 (owner 2026-11-22) — not tested yet. A background case read sent through Anthropic's Message
-- Batches: the credits and spend reserved for it until its result is fetched (settled) or it fails (given back).
-- Counts only: the batch id and the reservation — never the request or its answer. Deleted when settled.
CREATE TABLE IF NOT EXISTS batch_holds (
  batch_id       TEXT PRIMARY KEY,     -- Anthropic's message batch id
  sub            TEXT NOT NULL,        -- the account that reserved it
  period         TEXT NOT NULL,        -- the allowance period the credits came from
  day            TEXT NOT NULL,        -- the UTC day counted
  month          TEXT NOT NULL,        -- the spend month reserved against
  worst_micro    INTEGER NOT NULL,     -- the worst case reserved (micro-dollars, batch rates)
  reserved       INTEGER NOT NULL,     -- credits reserved
  from_allowance INTEGER NOT NULL,
  from_topups    TEXT NOT NULL,        -- JSON [{id, n}] of the packs credits were taken from
  model          TEXT NOT NULL,
  created_at     INTEGER NOT NULL      -- ms since epoch
);
CREATE TABLE IF NOT EXISTS status_cache (
  sub        TEXT PRIMARY KEY,
  tier       TEXT,                     -- "ai" | "pro" | NULL (no AI plan) as Apple last reported
  anchor     INTEGER NOT NULL,         -- ms: purchase of the current period (allowance anniversary)
  expires    INTEGER NOT NULL,         -- ms: end of the current period
  checked_at INTEGER NOT NULL,         -- ms since epoch; re-checked with Apple after 10 minutes
  yearly     INTEGER NOT NULL DEFAULT 0 -- 1 = a yearly plan (AI Pro yearly: 5,400 credits a month, not 6,000)
);
