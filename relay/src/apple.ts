// AI Included relay — asks Apple (App Store Server API) whether a subscription or top-up is real.
// (Who is asking is proven first, by the signed transaction the app sends: jws.ts.)
// The answer comes straight from Apple over TLS, so it is authoritative; the app's own claim is never
// trusted. Production is asked first, then sandbox (TestFlight / review), as Apple recommends.

import { type AppleTransaction } from "./policy.ts";

export interface AppleConfig {
  issuerId: string;   // App Store Connect API issuer id
  keyId: string;      // In-App Purchase key id
  privateKeyPem: string; // the .p8 key (PKCS#8 PEM)
  bundleId: string;
}

export type Fetch = (input: string, init?: RequestInit) => Promise<Response>;

const HOSTS = ["https://api.storekit.itunes.apple.com", "https://api.storekit-sandbox.itunes.apple.com"];

function b64url(bytes: Uint8Array | string): string {
  const b = typeof bytes === "string" ? new TextEncoder().encode(bytes) : bytes;
  let s = "";
  for (const x of b) s += String.fromCharCode(x);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToDer(pem: string): ArrayBuffer {
  const body = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const raw = atob(body);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out.buffer;
}

/** A 20-minute ES256 token for the App Store Server API. */
export async function appleToken(cfg: AppleConfig, now: Date): Promise<string> {
  const header = { alg: "ES256", kid: cfg.keyId, typ: "JWT" };
  const iat = Math.floor(now.getTime() / 1000);
  const payload = { iss: cfg.issuerId, iat, exp: iat + 1200, aud: "appstoreconnect-v1", bid: cfg.bundleId };
  const signingInput = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`;
  const key = await crypto.subtle.importKey("pkcs8", pemToDer(cfg.privateKeyPem), { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, new TextEncoder().encode(signingInput));
  return `${signingInput}.${b64url(new Uint8Array(sig))}`;
}

/** The payload of a JWS Apple returned to us directly (trusted because we fetched it from Apple). */
export function decodeJWSPayload<T>(jws: string): T {
  const part = jws.split(".")[1] ?? "";
  const padded = part.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((part.length + 3) % 4);
  return JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(padded), (c) => c.charCodeAt(0))));
}

/** The hosts to ask: a signed transaction names its environment (SEC-05), so only that one is asked;
 *  without one (a notification hint), production first, then sandbox. */
function hostsFor(environment?: string): string[] {
  if (environment === "Production") return [HOSTS[0]];
  if (environment === "Sandbox") return [HOSTS[1]];
  return HOSTS;
}

async function getFromApple(path: string, cfg: AppleConfig, fetcher: Fetch, now: Date, environment?: string): Promise<unknown | null> {
  const token = await appleToken(cfg, now);
  for (const host of hostsFor(environment)) {
    const res = await fetcher(`${host}${path}`, { headers: { Authorization: `Bearer ${token}` } });
    if (res.status === 404) continue;            // not in this environment: try the next
    if (!res.ok) throw new Error(`App Store Server API ${res.status}`);
    return await res.json();
  }
  return null;
}

export interface SubscriptionStatus { status: number; transaction: AppleTransaction }

/** Every subscription status Apple holds for the subscription this transaction belongs to. */
export async function subscriptionStatuses(transactionId: string, cfg: AppleConfig, fetcher: Fetch, now: Date, environment?: string): Promise<SubscriptionStatus[]> {
  const body = await getFromApple(`/inApps/v1/subscriptions/${encodeURIComponent(transactionId)}`, cfg, fetcher, now, environment) as
    { data?: { lastTransactions?: { status: number; signedTransactionInfo: string }[] }[] } | null;
  const out: SubscriptionStatus[] = [];
  for (const group of body?.data ?? []) {
    for (const t of group.lastTransactions ?? []) {
      out.push({ status: t.status, transaction: decodeJWSPayload<AppleTransaction>(t.signedTransactionInfo) });
    }
  }
  return out;
}

/** One transaction as Apple records it (used for consumable top-ups). */
export async function transactionInfo(transactionId: string, cfg: AppleConfig, fetcher: Fetch, now: Date, environment?: string): Promise<AppleTransaction | null> {
  const body = await getFromApple(`/inApps/v1/transactions/${encodeURIComponent(transactionId)}`, cfg, fetcher, now, environment) as
    { signedTransactionInfo?: string } | null;
  return body?.signedTransactionInfo ? decodeJWSPayload<AppleTransaction>(body.signedTransactionInfo) : null;
}
