// AI relay — counts and credits only. Every reservation is a conditional update, so two requests
// arriving together can never both pass a limit that only one of them fits under.

import { type Micro, type Tier, type TopUpTake } from "./policy.ts";

export type Provider = "anthropic" | "gemini";

/** Apple's last answer about a subscriber: the AI tier and the current period (re-asked after a TTL). */
export interface PlanStatus { tier: Tier | null; anchor: number; expires: number; checkedAt: number; yearly?: boolean }

export type CreditReservation =
  | { ok: true; fromAllowance: number; fromTopUps: TopUpTake[] }
  | { ok: false; reason: "credits" | "daily"; balance: number };

export interface Balance { allowanceUsed: number; topUps: number; dailyUsed: number }

export interface Store {
  /** Add `amount` to the month's spend for `provider` only if the total stays within `cap` and the
   *  spend so far is below `stopAt`. */
  reserveSpend(month: string, provider: Provider, amount: Micro, cap: Micro, stopAt: Micro): Promise<boolean>;
  /** Correct a reservation to the actual cost. Never below zero. */
  adjustSpend(month: string, provider: Provider, delta: Micro): Promise<void>;
  spent(month: string, provider: Provider): Promise<Micro>;

  /** Reserve `credits`: the day's limit first, then the period's allowance, then unrevoked top-ups
   *  oldest first. All or nothing. */
  reserveCredits(sub: string, period: string, allowance: number, day: string, dailyLimit: number, credits: number): Promise<CreditReservation>;
  /** Give credits back (the unused part of a reservation, or all of it after a failure). */
  releaseCredits(sub: string, period: string, day: string, fromAllowance: number, fromTopUps: TopUpTake[]): Promise<void>;
  balance(sub: string, period: string, day: string): Promise<Balance>;

  /** Credit a verified pack once; false when this transaction was already credited. */
  creditTopUp(transactionId: string, sub: string, productId: string, purchasedAt: number, credits: number): Promise<boolean>;
  /** A refunded or revoked pack: its remaining credits are removed. true when it was on record. */
  revokeTopUp(transactionId: string): Promise<boolean>;

  cachedStatus(sub: string): Promise<PlanStatus | null>;
  cacheStatus(sub: string, s: PlanStatus): Promise<void>;
  forgetStatus(sub: string): Promise<void>;

  /** Retention: spend months before `oldestMonth`, allowance periods starting before `oldestPeriod` (ISO),
   *  day counts before `oldestDay`, EMPTY top-ups bought before `topUpsBefore` (ms) — a pack with credits
   *  left is never deleted — and status answers older than `statusBefore` (ms). */
  purge(oldestMonth: string, oldestPeriod: string, oldestDay: string, topUpsBefore: number, statusBefore: number): Promise<void>;
}

interface TopUpRow { sub: string; productId: string; purchasedAt: number; credits: number; remaining: number; revoked: boolean }

/** In-memory store for tests (same semantics as D1; no await inside a critical section). */
export class MemoryStore implements Store {
  spend = new Map<string, Micro>();
  allowance = new Map<string, number>();   // `${sub}|${period}` → used
  daily = new Map<string, number>();       // `${sub}|${day}` → used
  topups = new Map<string, TopUpRow>();
  status = new Map<string, PlanStatus>();

  async reserveSpend(month: string, provider: Provider, amount: Micro, cap: Micro, stopAt: Micro): Promise<boolean> {
    const k = `${month}|${provider}`;
    const cur = this.spend.get(k) ?? 0;
    if (cur >= stopAt || cur + amount > cap) return false;
    this.spend.set(k, cur + amount);
    return true;
  }
  async adjustSpend(month: string, provider: Provider, delta: Micro): Promise<void> {
    const k = `${month}|${provider}`;
    this.spend.set(k, Math.max(0, (this.spend.get(k) ?? 0) + delta));
  }
  async spent(month: string, provider: Provider): Promise<Micro> { return this.spend.get(`${month}|${provider}`) ?? 0; }

  private usable(sub: string) {
    return [...this.topups.entries()].filter(([, t]) => t.sub === sub && !t.revoked && t.remaining > 0)
      .sort((a, b) => a[1].purchasedAt - b[1].purchasedAt);
  }

  async reserveCredits(sub: string, period: string, allowance: number, day: string, dailyLimit: number, credits: number): Promise<CreditReservation> {
    const ak = `${sub}|${period}`, dk = `${sub}|${day}`;
    const used = this.allowance.get(ak) ?? 0;
    const topUps = this.usable(sub).reduce((s, [, t]) => s + t.remaining, 0);
    const balance = Math.max(0, allowance - used) + topUps;
    if ((this.daily.get(dk) ?? 0) + credits > dailyLimit) return { ok: false, reason: "daily", balance };
    if (balance < credits) return { ok: false, reason: "credits", balance };
    const fromAllowance = Math.min(credits, Math.max(0, allowance - used));
    let rest = credits - fromAllowance;
    const fromTopUps: TopUpTake[] = [];
    for (const [id, t] of this.usable(sub)) {
      if (rest === 0) break;
      const n = Math.min(rest, t.remaining);
      t.remaining -= n; rest -= n;
      fromTopUps.push({ id, n });
    }
    this.allowance.set(ak, used + fromAllowance);
    this.daily.set(dk, (this.daily.get(dk) ?? 0) + credits);
    return { ok: true, fromAllowance, fromTopUps };
  }
  async releaseCredits(sub: string, period: string, day: string, fromAllowance: number, fromTopUps: TopUpTake[]): Promise<void> {
    const ak = `${sub}|${period}`, dk = `${sub}|${day}`;
    this.allowance.set(ak, Math.max(0, (this.allowance.get(ak) ?? 0) - fromAllowance));
    let back = fromAllowance;
    for (const t of fromTopUps) {
      back += t.n;
      const row = this.topups.get(t.id);
      if (row && !row.revoked) row.remaining = Math.min(row.credits, row.remaining + t.n);
    }
    this.daily.set(dk, Math.max(0, (this.daily.get(dk) ?? 0) - back));
  }
  async balance(sub: string, period: string, day: string): Promise<Balance> {
    return { allowanceUsed: this.allowance.get(`${sub}|${period}`) ?? 0,
             topUps: this.usable(sub).reduce((s, [, t]) => s + t.remaining, 0),
             dailyUsed: this.daily.get(`${sub}|${day}`) ?? 0 };
  }
  async creditTopUp(transactionId: string, sub: string, productId: string, purchasedAt: number, credits: number): Promise<boolean> {
    if (this.topups.has(transactionId)) return false;
    this.topups.set(transactionId, { sub, productId, purchasedAt, credits, remaining: credits, revoked: false });
    return true;
  }
  async revokeTopUp(transactionId: string): Promise<boolean> {
    const t = this.topups.get(transactionId);
    if (!t) return false;
    t.revoked = true; t.remaining = 0;
    return true;
  }
  async cachedStatus(sub: string) { return this.status.get(sub) ?? null; }
  async cacheStatus(sub: string, s: PlanStatus) { this.status.set(sub, s); }
  async forgetStatus(sub: string) { this.status.delete(sub); }
  async purge(oldestMonth: string, oldestPeriod: string, oldestDay: string, topUpsBefore: number, statusBefore: number): Promise<void> {
    for (const k of [...this.spend.keys()]) if (k.split("|")[0] < oldestMonth) this.spend.delete(k);
    for (const k of [...this.allowance.keys()]) if (k.split("|")[1] < oldestPeriod) this.allowance.delete(k);
    for (const k of [...this.daily.keys()]) if (k.split("|")[1] < oldestDay) this.daily.delete(k);
    for (const [k, t] of [...this.topups.entries()]) if (t.remaining === 0 && t.purchasedAt < topUpsBefore) this.topups.delete(k);
    for (const [k, s] of [...this.status.entries()]) if (s.checkedAt < statusBefore) this.status.delete(k);
  }
}

/** Minimal shape of Cloudflare D1 the relay uses. */
export interface D1Like {
  prepare(sql: string): { bind(...values: unknown[]): {
    run(): Promise<{ meta: { changes: number } }>;
    first<T = Record<string, unknown>>(): Promise<T | null>;
    all<T = Record<string, unknown>>(): Promise<{ results: T[] }>;
  } };
}

/** Production store on Cloudflare D1 (SQLite). Schema: relay/schema.sql. */
export class D1Store implements Store {
  private readonly db: D1Like;
  constructor(db: D1Like) { this.db = db; }
  private q(sql: string, ...v: unknown[]) { return this.db.prepare(sql).bind(...v); }

  async reserveSpend(month: string, provider: Provider, amount: Micro, cap: Micro, stopAt: Micro): Promise<boolean> {
    await this.q("INSERT OR IGNORE INTO spend (month, provider, micro) VALUES (?1, ?2, 0)", month, provider).run();
    const r = await this.q("UPDATE spend SET micro = micro + ?1 WHERE month = ?2 AND provider = ?3 AND micro + ?1 <= ?4 AND micro < ?5",
      amount, month, provider, cap, stopAt).run();
    return r.meta.changes === 1;
  }
  async adjustSpend(month: string, provider: Provider, delta: Micro): Promise<void> {
    await this.q("UPDATE spend SET micro = MAX(0, micro + ?1) WHERE month = ?2 AND provider = ?3", delta, month, provider).run();
  }
  async spent(month: string, provider: Provider): Promise<Micro> {
    return (await this.q("SELECT micro FROM spend WHERE month = ?1 AND provider = ?2", month, provider).first<{ micro: number }>())?.micro ?? 0;
  }

  async reserveCredits(sub: string, period: string, allowance: number, day: string, dailyLimit: number, credits: number): Promise<CreditReservation> {
    const bal = async () => {
      const b = await this.balance(sub, period, day);
      return Math.max(0, allowance - b.allowanceUsed) + b.topUps;
    };
    // 1. The day's limit (one conditional update).
    await this.q("INSERT OR IGNORE INTO daily (sub, day, used) VALUES (?1, ?2, 0)", sub, day).run();
    const d = await this.q("UPDATE daily SET used = used + ?3 WHERE sub = ?1 AND day = ?2 AND used + ?3 <= ?4", sub, day, credits, dailyLimit).run();
    if (d.meta.changes !== 1) return { ok: false, reason: "daily", balance: await bal() };
    // 2. The allowance: take what is left of it (optimistic: retried when another request moved it).
    await this.q("INSERT OR IGNORE INTO allowance (sub, period, used) VALUES (?1, ?2, 0)", sub, period).run();
    let fromAllowance = 0;
    for (let attempt = 0; attempt < 5; attempt++) {
      const used = (await this.q("SELECT used FROM allowance WHERE sub = ?1 AND period = ?2", sub, period).first<{ used: number }>())?.used ?? 0;
      const take = Math.min(credits, Math.max(0, allowance - used));
      if (take === 0) break;
      const u = await this.q("UPDATE allowance SET used = used + ?3 WHERE sub = ?1 AND period = ?2 AND used = ?4", sub, period, take, used).run();
      if (u.meta.changes === 1) { fromAllowance = take; break; }
    }
    // 3. Top-ups, oldest first, each by a conditional update.
    let rest = credits - fromAllowance;
    const fromTopUps: TopUpTake[] = [];
    if (rest > 0) {
      const rows = (await this.q("SELECT transaction_id, remaining FROM topups WHERE sub = ?1 AND revoked = 0 AND remaining > 0 ORDER BY purchased_at", sub)
        .all<{ transaction_id: string; remaining: number }>()).results;
      for (const r of rows) {
        if (rest === 0) break;
        const n = Math.min(rest, r.remaining);
        const u = await this.q("UPDATE topups SET remaining = remaining - ?2 WHERE transaction_id = ?1 AND revoked = 0 AND remaining >= ?2", r.transaction_id, n).run();
        if (u.meta.changes === 1) { fromTopUps.push({ id: r.transaction_id, n }); rest -= n; }
      }
    }
    if (rest > 0) {
      // Not enough: everything taken goes back (the day's count too), nothing is sent.
      await this.releaseCredits(sub, period, day, fromAllowance, fromTopUps);
      await this.q("UPDATE daily SET used = MAX(0, used - ?3) WHERE sub = ?1 AND day = ?2", sub, day, rest).run();
      return { ok: false, reason: "credits", balance: await bal() };
    }
    return { ok: true, fromAllowance, fromTopUps };
  }
  async releaseCredits(sub: string, period: string, day: string, fromAllowance: number, fromTopUps: TopUpTake[]): Promise<void> {
    let back = fromAllowance;
    if (fromAllowance > 0) await this.q("UPDATE allowance SET used = MAX(0, used - ?3) WHERE sub = ?1 AND period = ?2", sub, period, fromAllowance).run();
    for (const t of fromTopUps) {
      back += t.n;
      await this.q("UPDATE topups SET remaining = MIN(credits, remaining + ?2) WHERE transaction_id = ?1 AND revoked = 0", t.id, t.n).run();
    }
    if (back > 0) await this.q("UPDATE daily SET used = MAX(0, used - ?3) WHERE sub = ?1 AND day = ?2", sub, day, back).run();
  }
  async balance(sub: string, period: string, day: string): Promise<Balance> {
    const a = await this.q("SELECT used FROM allowance WHERE sub = ?1 AND period = ?2", sub, period).first<{ used: number }>();
    const t = await this.q("SELECT COALESCE(SUM(remaining), 0) AS left FROM topups WHERE sub = ?1 AND revoked = 0", sub).first<{ left: number }>();
    const d = await this.q("SELECT used FROM daily WHERE sub = ?1 AND day = ?2", sub, day).first<{ used: number }>();
    return { allowanceUsed: a?.used ?? 0, topUps: t?.left ?? 0, dailyUsed: d?.used ?? 0 };
  }
  async creditTopUp(transactionId: string, sub: string, productId: string, purchasedAt: number, credits: number): Promise<boolean> {
    const r = await this.q("INSERT OR IGNORE INTO topups (transaction_id, sub, product_id, purchased_at, credits, remaining, revoked) VALUES (?1, ?2, ?3, ?4, ?5, ?5, 0)",
      transactionId, sub, productId, purchasedAt, credits).run();
    return r.meta.changes === 1;
  }
  async revokeTopUp(transactionId: string): Promise<boolean> {
    const r = await this.q("UPDATE topups SET revoked = 1, remaining = 0 WHERE transaction_id = ?1", transactionId).run();
    return r.meta.changes === 1;
  }
  async cachedStatus(sub: string): Promise<PlanStatus | null> {
    const r = await this.q("SELECT tier, anchor, expires, checked_at, yearly FROM status_cache WHERE sub = ?1", sub)
      .first<{ tier: string | null; anchor: number; expires: number; checked_at: number; yearly: number | null }>();
    return r ? { tier: (r.tier === "ai" || r.tier === "pro") ? r.tier : null, anchor: r.anchor, expires: r.expires, checkedAt: r.checked_at,
                 yearly: r.yearly === 1 } : null;
  }
  async cacheStatus(sub: string, s: PlanStatus): Promise<void> {
    await this.q("INSERT INTO status_cache (sub, tier, anchor, expires, checked_at, yearly) VALUES (?1, ?2, ?3, ?4, ?5, ?6) ON CONFLICT(sub) DO UPDATE SET tier = ?2, anchor = ?3, expires = ?4, checked_at = ?5, yearly = ?6",
      sub, s.tier, s.anchor, s.expires, s.checkedAt, s.yearly ? 1 : 0).run();
  }
  async forgetStatus(sub: string): Promise<void> {
    await this.q("DELETE FROM status_cache WHERE sub = ?1", sub).run();
  }
  async purge(oldestMonth: string, oldestPeriod: string, oldestDay: string, topUpsBefore: number, statusBefore: number): Promise<void> {
    await this.q("DELETE FROM spend WHERE month < ?1", oldestMonth).run();
    await this.q("DELETE FROM allowance WHERE period < ?1", oldestPeriod).run();
    await this.q("DELETE FROM daily WHERE day < ?1", oldestDay).run();
    await this.q("DELETE FROM topups WHERE remaining = 0 AND purchased_at < ?1", topUpsBefore).run();
    await this.q("DELETE FROM status_cache WHERE checked_at < ?1", statusBefore).run();
  }
}
