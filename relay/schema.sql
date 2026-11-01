-- AI Included relay (Cloudflare D1). Counts only — no request or answer content is ever stored.
CREATE TABLE IF NOT EXISTS spend (
  month    TEXT NOT NULL,              -- "2026-11" (UTC)
  provider TEXT NOT NULL,              -- "anthropic" | "gemini"
  micro    INTEGER NOT NULL DEFAULT 0, -- micro-dollars reserved/spent this month
  PRIMARY KEY (month, provider)
);
CREATE TABLE IF NOT EXISTS usage (
  month TEXT NOT NULL,
  sub   TEXT NOT NULL,                 -- the App Store originalTransactionId of the AI Included subscription
  used  INTEGER NOT NULL DEFAULT 0,    -- questions used from this month's 300
  PRIMARY KEY (month, sub)
);
CREATE TABLE IF NOT EXISTS topups (
  transaction_id TEXT PRIMARY KEY,     -- the consumable's App Store transactionId (credited once)
  sub            TEXT NOT NULL,
  purchased_at   INTEGER NOT NULL,     -- ms since epoch
  remaining      INTEGER NOT NULL
);
CREATE TABLE IF NOT EXISTS status_cache (
  sub        TEXT PRIMARY KEY,
  active     INTEGER NOT NULL,         -- 1 when Apple last reported an active/grace AI Included subscription
  checked_at INTEGER NOT NULL          -- ms since epoch; re-checked with Apple after 10 minutes
);
