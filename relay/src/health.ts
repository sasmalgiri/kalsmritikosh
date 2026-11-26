// Unified path R2-E (PERF-12, owner 2026-11-22 round 2) — not tested yet. Content-free health counters for the relay:
// per route (a fixed list), per status class, latency buckets and the in-flight count. Never a credential, a body,
// a model reply, an account id or an IP address. Read by an operator at GET /v1/health with the OPERATOR_TOKEN
// secret (wrangler secret put OPERATOR_TOKEN); without that secret the route does not exist (404).

export const HEALTH_ROUTES = ["/v1/messages", "/v1/transcribe", "/v1/status", "/v1/topup", "/v1/batch/create", "/v1/batch/result",
                              "/v1/sellable", "/v1/apple-notifications", "other"] as const;

export interface HealthSnapshot {
  label: string;
  since: string;
  inFlight: number;
  routes: Record<string, { count: number; byStatusClass: Record<string, number>; latencyMs: Record<string, number> }>;
}

export class HealthCounters {
  private since: Date;
  private inFlight = 0;
  private routes: HealthSnapshot["routes"] = {};
  constructor(now: Date = new Date()) { this.since = now; }

  static routeKey(path: string): string {
    return (HEALTH_ROUTES as readonly string[]).includes(path) ? path : "other";
  }

  begin(): void { this.inFlight += 1; }

  end(path: string, status: number, ms: number): void {
    this.inFlight = Math.max(0, this.inFlight - 1);
    const key = HealthCounters.routeKey(path);
    const r = this.routes[key] ?? (this.routes[key] = { count: 0, byStatusClass: {}, latencyMs: {} });
    r.count += 1;
    const cls = `${Math.floor(status / 100)}xx`;
    r.byStatusClass[cls] = (r.byStatusClass[cls] ?? 0) + 1;
    const bucket = ms < 250 ? "<250" : ms < 1000 ? "<1000" : ms < 10000 ? "<10000" : ">=10000";
    r.latencyMs[bucket] = (r.latencyMs[bucket] ?? 0) + 1;
  }

  snapshot(): HealthSnapshot {
    return { label: "content-free relay health (per isolate)", since: this.since.toISOString(), inFlight: this.inFlight,
             routes: structuredClone(this.routes) };
  }
}

/** Constant-time comparison of the operator token. */
export function operatorAllowed(given: string | null, secret: string | undefined): boolean {
  if (!secret || !given || given.length !== secret.length) return false;
  let diff = 0;
  for (let i = 0; i < secret.length; i++) diff |= secret.charCodeAt(i) ^ given.charCodeAt(i);
  return diff === 0;
}
