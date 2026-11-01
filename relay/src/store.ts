// AI Included relay — counts only. Every reservation is ONE conditional update, so two requests
// arriving together can never both pass a limit that only one of them fits under.

import { type Micro, type Provider, MONTHLY_QUESTIONS, TOPUP_QUESTIONS, TOPUP_VALID_DAYS } from "./policy.ts";

export type QuestionSource = { kind: "monthly" } | { kind: "topup"; transactionId: string };

export interface Store {
  /** Add `amount` to the month's spend for `provider` only if the total stays within `budget`. */
  reserveSpend(month: string, provider: Provider, amount: Micro, budget: Micro): Promise<boolean>;
  /** Correct a reservation to the actual cost (delta is usually negative). Never below zero. */
  adjustSpend(month: string, provider: Provider, delta: Micro): Promise<void>;
  spent(month: string, provider: Provider): Promise<Micro>;
  /** Use one question: the month's allowance first, then the oldest valid top-up; null when none is left. */
  consumeQuestion(month: string, sub: string, now: Date): Promise<QuestionSource | null>;
  /** Give a question back (the provider call failed, nothing was answered). */
  refundQuestion(month: string, sub: string, source: QuestionSource): Promise<void>;
  /** Credit a verified top-up once; false when this transaction was already credited. */
  creditTopUp(transactionId: string, sub: string, purchasedAt: number): Promise<boolean>;
  remaining(month: string, sub: string, now: Date): Promise<{ monthly: number; topUps: number }>;
  /** Apple's last answer about this subscriber (re-asked after STATUS_TTL_MS). */
  cachedStatus(sub: string): Promise<{ active: boolean; checkedAt: number } | null>;
  cacheStatus(sub: string, active: boolean, at: number): Promise<void>;
  /** Retention (privacy policy): drop months before `oldestMonth`, top-ups bought before `topUpsBefore`
   *  (ms), and status answers older than `statusBefore` (ms). */
  purge(oldestMonth: string, topUpsBefore: number, statusBefore: number): Promise<void>;
}

const topUpCutoff = (now: Date) => now.getTime() - TOPUP_VALID_DAYS * 86_400_000;

/** In-memory store for tests (same semantics as D1). */
export class MemoryStore implements Store {
  status = new Map<string, { active: boolean; checkedAt: number }>();
  async cachedStatus(sub: string) { return this.status.get(sub) ?? null; }
  async cacheStatus(sub: string, active: boolean, at: number) { this.status.set(sub, { active, checkedAt: at }); }
  spend = new Map<string, Micro>();
  usage = new Map<string, number>();
  topups = new Map<string, { sub: string; purchasedAt: number; remaining: number }>();

  async reserveSpend(month: string, provider: Provider, amount: Micro, budget: Micro): Promise<boolean> {
    const k = `${month}|${provider}`;
    const cur = this.spend.get(k) ?? 0;
    if (cur + amount > budget) return false;
    this.spend.set(k, cur + amount);
    return true;
  }
  async adjustSpend(month: string, provider: Provider, delta: Micro): Promise<void> {
    const k = `${month}|${provider}`;
    this.spend.set(k, Math.max(0, (this.spend.get(k) ?? 0) + delta));
  }
  async spent(month: string, provider: Provider): Promise<Micro> {
    return this.spend.get(`${month}|${provider}`) ?? 0;
  }
  async consumeQuestion(month: string, sub: string, now: Date): Promise<QuestionSource | null> {
    const k = `${month}|${sub}`;
    const used = this.usage.get(k) ?? 0;
    if (used < MONTHLY_QUESTIONS) { this.usage.set(k, used + 1); return { kind: "monthly" }; }
    const cutoff = topUpCutoff(now);
    const valid = [...this.topups.entries()]
      .filter(([, t]) => t.sub === sub && t.remaining > 0 && t.purchasedAt > cutoff)
      .sort((a, b) => a[1].purchasedAt - b[1].purchasedAt);
    if (valid.length === 0) return null;
    const [id, t] = valid[0];
    t.remaining -= 1;
    return { kind: "topup", transactionId: id };
  }
  async refundQuestion(month: string, sub: string, source: QuestionSource): Promise<void> {
    if (source.kind === "monthly") {
      const k = `${month}|${sub}`;
      this.usage.set(k, Math.max(0, (this.usage.get(k) ?? 0) - 1));
    } else {
      const t = this.topups.get(source.transactionId);
      if (t) t.remaining = Math.min(TOPUP_QUESTIONS, t.remaining + 1);
    }
  }
  async creditTopUp(transactionId: string, sub: string, purchasedAt: number): Promise<boolean> {
    if (this.topups.has(transactionId)) return false;
    this.topups.set(transactionId, { sub, purchasedAt, remaining: TOPUP_QUESTIONS });
    return true;
  }
  async purge(oldestMonth: string, topUpsBefore: number, statusBefore: number): Promise<void> {
    for (const k of [...this.spend.keys()]) if (k.split("|")[0] < oldestMonth) this.spend.delete(k);
    for (const k of [...this.usage.keys()]) if (k.split("|")[0] < oldestMonth) this.usage.delete(k);
    for (const [k, t] of [...this.topups.entries()]) if (t.purchasedAt < topUpsBefore) this.topups.delete(k);
    for (const [k, s] of [...this.status.entries()]) if (s.checkedAt < statusBefore) this.status.delete(k);
  }
  async remaining(month: string, sub: string, now: Date): Promise<{ monthly: number; topUps: number }> {
    const cutoff = topUpCutoff(now);
    const topUps = [...this.topups.values()].filter((t) => t.sub === sub && t.purchasedAt > cutoff).reduce((s, t) => s + t.remaining, 0);
    return { monthly: Math.max(0, MONTHLY_QUESTIONS - (this.usage.get(`${month}|${sub}`) ?? 0)), topUps };
  }
}

/** Minimal shape of Cloudflare D1 the relay uses. */
export interface D1Like {
  prepare(sql: string): { bind(...values: unknown[]): { run(): Promise<{ meta: { changes: number } }>; first<T = Record<string, unknown>>(): Promise<T | null> } };
}

/** Production store on Cloudflare D1 (SQLite). Schema: relay/schema.sql. */
export class D1Store implements Store {
  private readonly db: D1Like;
  constructor(db: D1Like) { this.db = db; }

  async cachedStatus(sub: string): Promise<{ active: boolean; checkedAt: number } | null> {
    const r = await this.db.prepare("SELECT active, checked_at FROM status_cache WHERE sub = ?1").bind(sub).first<{ active: number; checked_at: number }>();
    return r ? { active: r.active === 1, checkedAt: r.checked_at } : null;
  }
  async cacheStatus(sub: string, active: boolean, at: number): Promise<void> {
    await this.db.prepare("INSERT INTO status_cache (sub, active, checked_at) VALUES (?1, ?2, ?3) ON CONFLICT(sub) DO UPDATE SET active = ?2, checked_at = ?3")
      .bind(sub, active ? 1 : 0, at).run();
  }

  async reserveSpend(month: string, provider: Provider, amount: Micro, budget: Micro): Promise<boolean> {
    await this.db.prepare("INSERT OR IGNORE INTO spend (month, provider, micro) VALUES (?1, ?2, 0)").bind(month, provider).run();
    const r = await this.db.prepare("UPDATE spend SET micro = micro + ?1 WHERE month = ?2 AND provider = ?3 AND micro + ?1 <= ?4")
      .bind(amount, month, provider, budget).run();
    return r.meta.changes === 1;
  }
  async adjustSpend(month: string, provider: Provider, delta: Micro): Promise<void> {
    await this.db.prepare("UPDATE spend SET micro = MAX(0, micro + ?1) WHERE month = ?2 AND provider = ?3").bind(delta, month, provider).run();
  }
  async spent(month: string, provider: Provider): Promise<Micro> {
    const row = await this.db.prepare("SELECT micro FROM spend WHERE month = ?1 AND provider = ?2").bind(month, provider).first<{ micro: number }>();
    return row?.micro ?? 0;
  }
  async consumeQuestion(month: string, sub: string, now: Date): Promise<QuestionSource | null> {
    await this.db.prepare("INSERT OR IGNORE INTO usage (month, sub, used) VALUES (?1, ?2, 0)").bind(month, sub).run();
    const m = await this.db.prepare("UPDATE usage SET used = used + 1 WHERE month = ?1 AND sub = ?2 AND used < ?3").bind(month, sub, MONTHLY_QUESTIONS).run();
    if (m.meta.changes === 1) return { kind: "monthly" };
    const t = await this.db.prepare("SELECT transaction_id FROM topups WHERE sub = ?1 AND remaining > 0 AND purchased_at > ?2 ORDER BY purchased_at LIMIT 1")
      .bind(sub, topUpCutoff(now)).first<{ transaction_id: string }>();
    if (!t) return null;
    const u = await this.db.prepare("UPDATE topups SET remaining = remaining - 1 WHERE transaction_id = ?1 AND remaining > 0").bind(t.transaction_id).run();
    return u.meta.changes === 1 ? { kind: "topup", transactionId: t.transaction_id } : null;
  }
  async refundQuestion(month: string, sub: string, source: QuestionSource): Promise<void> {
    if (source.kind === "monthly") {
      await this.db.prepare("UPDATE usage SET used = MAX(0, used - 1) WHERE month = ?1 AND sub = ?2").bind(month, sub).run();
    } else {
      await this.db.prepare("UPDATE topups SET remaining = MIN(?2, remaining + 1) WHERE transaction_id = ?1").bind(source.transactionId, TOPUP_QUESTIONS).run();
    }
  }
  async creditTopUp(transactionId: string, sub: string, purchasedAt: number): Promise<boolean> {
    const r = await this.db.prepare("INSERT OR IGNORE INTO topups (transaction_id, sub, purchased_at, remaining) VALUES (?1, ?2, ?3, ?4)")
      .bind(transactionId, sub, purchasedAt, TOPUP_QUESTIONS).run();
    return r.meta.changes === 1;
  }
  async purge(oldestMonth: string, topUpsBefore: number, statusBefore: number): Promise<void> {
    await this.db.prepare("DELETE FROM spend WHERE month < ?1").bind(oldestMonth).run();
    await this.db.prepare("DELETE FROM usage WHERE month < ?1").bind(oldestMonth).run();
    await this.db.prepare("DELETE FROM topups WHERE purchased_at < ?1").bind(topUpsBefore).run();
    await this.db.prepare("DELETE FROM status_cache WHERE checked_at < ?1").bind(statusBefore).run();
  }
  async remaining(month: string, sub: string, now: Date): Promise<{ monthly: number; topUps: number }> {
    const u = await this.db.prepare("SELECT used FROM usage WHERE month = ?1 AND sub = ?2").bind(month, sub).first<{ used: number }>();
    const t = await this.db.prepare("SELECT COALESCE(SUM(remaining), 0) AS left FROM topups WHERE sub = ?1 AND purchased_at > ?2").bind(sub, topUpCutoff(now)).first<{ left: number }>();
    return { monthly: Math.max(0, MONTHLY_QUESTIONS - (u?.used ?? 0)), topUps: t?.left ?? 0 };
  }
}
