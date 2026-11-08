// SEC-05 — the subscriber's credential is a StoreKit 2 signed transaction (JWS), not a bare number.
// A transaction number is not a secret (it is printed on App Store receipts and order e-mails), so the
// relay accepts only a transaction Apple signed: the JWS's x5c chain must end in Apple Root CA - G3
// (pinned here, byte for byte), every certificate must be signed by the next and valid at the
// signing date, the intermediate and leaf must carry Apple's marker extensions, the JWS must be ES256
// over its own header and payload with the leaf's key, and the payload must name this app's bundle,
// an allowed environment, and an unrevoked, unexpired (or within billing grace) transaction. The plan
// itself is still asked of Apple's App Store Server API for the originalTransactionId the verified
// payload names (index.ts planStatus), so a stolen-but-old JWS buys nothing once Apple says it ended.
//
// No dependencies: a minimal DER reader and WebCrypto (ECDSA P-256 / P-384, SHA-256 / SHA-384).

/** Apple Root CA - G3 (DER, base64). SHA-256 63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79,
 *  valid 2014-04-30 → 2039-04-30. From the macOS system anchors; also published at apple.com/certificateauthority. */
export const APPLE_ROOT_CA_G3 =
  "MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwSQXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcNMTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBSb290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtfTjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySrMA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gAMGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM6BgD56KyKA==";

/** The header the app sends: the JWS of the AI subscription's latest verified transaction. */
export const SIGNED_TRANSACTION_HEADER = "x-kals-signed-transaction";
/** The old header carried a bare transaction number. It is refused (never trusted). */
export const LEGACY_SUBSCRIPTION_HEADER = "x-kals-subscription";
/** App Store environments accepted by default (TestFlight and App Review are Sandbox). "Xcode" (local
 *  StoreKit testing) is never accepted — it is not signed by Apple anyway. */
export const DEFAULT_ENVIRONMENTS: readonly string[] = ["Production", "Sandbox"];
/** Apple's billing grace period is at most 16 days: a transaction past its expiry by less is still
 *  accepted here (Apple's status answer then decides whether grace really applies). */
export const GRACE_TOLERANCE_MS = 16 * 86_400_000;
/** How long one verified JWS is remembered (per originalTransactionId). */
export const VERIFY_TTL_MS = 5 * 60_000;
const MAX_JWS_CHARS = 16_384;

export interface SignedTransaction {
  originalTransactionId: string;
  transactionId: string;
  bundleId: string;
  environment: string;
  productId: string;
  signedDate: number;
  purchaseDate?: number;
  expiresDate?: number;
  revocationDate?: number;
}

export type Verified = { ok: true; tx: SignedTransaction; cached: boolean } | { ok: false; reason: string };

export interface VerifyOptions {
  bundleId: string;
  now: Date;
  /** Trusted roots (DER, base64). Default: Apple Root CA - G3 only. Tests inject their own. */
  roots?: readonly string[];
  environments?: readonly string[];
  cache?: VerificationCache;
}

/** Verified credentials, keyed by originalTransactionId; a hit needs the same JWS (by SHA-256), so a
 *  different token naming the same number is verified from scratch. Short TTL; bounded. */
export class VerificationCache {
  private entries = new Map<string, { digest: string; tx: SignedTransaction; until: number }>();
  private ttlMs: number;
  private max: number;
  constructor(ttlMs = VERIFY_TTL_MS, max = 10_000) { this.ttlMs = ttlMs; this.max = max; }
  get(originalTransactionId: string, digest: string, now: number): SignedTransaction | null {
    const e = this.entries.get(originalTransactionId);
    if (!e || e.digest !== digest || e.until <= now) return null;
    return e.tx;
  }
  put(tx: SignedTransaction, digest: string, now: number): void {
    if (this.entries.size >= this.max) this.entries.delete(this.entries.keys().next().value as string);
    this.entries.set(tx.originalTransactionId, { digest, tx, until: now + this.ttlMs });
  }
  get size(): number { return this.entries.size; }
}

// MARK: - base64

function fromB64(s: string): Uint8Array {
  const raw = atob(s);
  const out = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}
function fromB64url(s: string): Uint8Array {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw new Error("not base64url");
  return fromB64(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
}
const hex = (b: Uint8Array) => [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
function equal(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a[i] ^ b[i];
  return d === 0;
}
function contains(hay: Uint8Array, needle: number[]): boolean {
  outer: for (let i = 0; i + needle.length <= hay.length; i++) {
    for (let j = 0; j < needle.length; j++) if (hay[i + j] !== needle[j]) continue outer;
    return true;
  }
  return false;
}

// MARK: - minimal DER

interface Node { tag: number; start: number; body: number; end: number }

function read(b: Uint8Array, at: number, limit = b.length): Node {
  if (at + 2 > limit) throw new Error("DER: truncated");
  const tag = b[at];
  let len = b[at + 1];
  let body = at + 2;
  if (len & 0x80) {
    const n = len & 0x7f;
    if (n === 0 || n > 4 || body + n > limit) throw new Error("DER: bad length");
    len = 0;
    for (let i = 0; i < n; i++) len = len * 256 + b[body + i];
    body += n;
  }
  const end = body + len;
  if (end > limit) throw new Error("DER: overrun");
  return { tag, start: at, body, end };
}
function children(b: Uint8Array, n: Node): Node[] {
  const out: Node[] = [];
  for (let at = n.body; at < n.end;) { const c = read(b, at, n.end); out.push(c); at = c.end; }
  return out;
}

const OID = {
  p256: [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07],
  p384: [0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22],
  ecdsaSha256: [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02],
  ecdsaSha384: [0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x03],
  /** 1.2.840.113635.100.6.2.1 — Apple WWDR intermediate marker. */
  appleIntermediate: [0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01],
  /** 1.2.840.113635.100.6.11.1 — Apple App Store receipt-signing leaf marker. */
  appleLeaf: [0x06, 0x0a, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x0b, 0x01],
};

interface Cert {
  der: Uint8Array;
  tbs: Uint8Array;
  hash: "SHA-256" | "SHA-384";
  signature: Uint8Array;           // DER Ecdsa-Sig-Value
  spki: Uint8Array;
  curve: "P-256" | "P-384";
  notBefore: number;
  notAfter: number;
  extensions: Uint8Array;
}

function time(b: Uint8Array, n: Node): number {
  const s = new TextDecoder().decode(b.slice(n.body, n.end));
  const m = n.tag === 0x17 ? /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s) : /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(s);
  if (!m) throw new Error("DER: bad time");
  let y = Number(m[1]);
  if (n.tag === 0x17) y += y < 50 ? 2000 : 1900;
  return Date.UTC(y, Number(m[2]) - 1, Number(m[3]), Number(m[4]), Number(m[5]), Number(m[6]));
}

function parseCert(der: Uint8Array): Cert {
  const top = read(der, 0);
  if (top.tag !== 0x30 || top.end !== der.length) throw new Error("certificate: not a SEQUENCE");
  const [tbsN, algN, sigN] = children(der, top);
  if (!tbsN || !algN || !sigN || sigN.tag !== 0x03) throw new Error("certificate: shape");
  const alg = der.slice(algN.body, algN.end);
  const hash = contains(alg, OID.ecdsaSha384) ? "SHA-384" : contains(alg, OID.ecdsaSha256) ? "SHA-256" : null;
  if (!hash) throw new Error("certificate: unsupported signature algorithm");
  const tbsKids = children(der, tbsN);
  let i = tbsKids[0]?.tag === 0xa0 ? 1 : 0;      // [0] version
  i += 1;                                          // serial
  i += 1;                                          // signature algorithm
  i += 1;                                          // issuer
  const validity = tbsKids[i++];
  i += 1;                                          // subject
  const spkiN = tbsKids[i++];
  if (!validity || !spkiN) throw new Error("certificate: tbs shape");
  const [nb, na] = children(der, validity);
  const spki = der.slice(spkiN.start, spkiN.end);
  const spkiAlg = children(der, spkiN)[0];
  const algBytes = der.slice(spkiAlg.body, spkiAlg.end);
  const curve = contains(algBytes, OID.p256) ? "P-256" : contains(algBytes, OID.p384) ? "P-384" : null;
  if (!curve) throw new Error("certificate: unsupported key");
  const extN = tbsKids.find((k) => k.tag === 0xa3);
  return {
    der, tbs: der.slice(tbsN.start, tbsN.end), hash,
    signature: der.slice(sigN.body + 1, sigN.end),  // BIT STRING: skip the unused-bits byte
    spki, curve, notBefore: time(der, nb), notAfter: time(der, na),
    extensions: extN ? der.slice(extN.start, extN.end) : new Uint8Array(),
  };
}

/** DER Ecdsa-Sig-Value → the raw r‖s WebCrypto verifies. */
function rawSignature(sig: Uint8Array, size: number): Uint8Array {
  const seq = read(sig, 0);
  const [r, s] = children(sig, seq);
  if (!r || !s || r.tag !== 0x02 || s.tag !== 0x02) throw new Error("signature: shape");
  const out = new Uint8Array(size * 2);
  for (const [k, n] of [[0, r], [1, s]] as const) {
    let v = sig.slice(n.body, n.end);
    while (v.length > size && v[0] === 0) v = v.slice(1);
    if (v.length > size) throw new Error("signature: too long");
    out.set(v, k * size + (size - v.length));
  }
  return out;
}

async function verifiedBy(child: Cert, parent: Cert): Promise<boolean> {
  const key = await crypto.subtle.importKey("spki", parent.spki, { name: "ECDSA", namedCurve: parent.curve }, false, ["verify"]);
  const size = parent.curve === "P-256" ? 32 : 48;
  return crypto.subtle.verify({ name: "ECDSA", hash: child.hash }, key, rawSignature(child.signature, size), child.tbs);
}

// MARK: - the check

function decodeJSON<T>(part: string): T { return JSON.parse(new TextDecoder().decode(fromB64url(part))) as T; }

/** The originalTransactionId a token CLAIMS, read without verifying (cache lookup only). */
function claimedOriginal(jws: string): string | null {
  try {
    const p = decodeJSON<{ originalTransactionId?: unknown }>(jws.split(".")[1] ?? "");
    return typeof p.originalTransactionId === "string" ? p.originalTransactionId : null;
  } catch { return null; }
}

/** Verify a StoreKit 2 signed transaction. Never throws: a malformed token is a refusal. */
export async function verifySignedTransaction(jws: string, o: VerifyOptions): Promise<Verified> {
  const now = o.now.getTime();
  if (!jws || jws.length > MAX_JWS_CHARS) return { ok: false, reason: "missing or oversized credential" };
  const parts = jws.split(".");
  if (parts.length !== 3 || parts.some((p) => !/^[A-Za-z0-9_-]+$/.test(p))) return { ok: false, reason: "not a signed transaction" };
  const digest = hex(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(jws))));
  const claimed = claimedOriginal(jws);
  if (claimed && o.cache) {
    const hit = o.cache.get(claimed, digest, now);
    if (hit) return { ok: true, tx: hit, cached: true };
  }
  try {
    const header = decodeJSON<{ alg?: unknown; x5c?: unknown }>(parts[0]);
    if (header.alg !== "ES256") return { ok: false, reason: "algorithm" };
    if (!Array.isArray(header.x5c) || header.x5c.length !== 3 || !header.x5c.every((c) => typeof c === "string")) {
      return { ok: false, reason: "certificate chain" };
    }
    const ders = (header.x5c as string[]).map(fromB64);
    const roots = (o.roots ?? [APPLE_ROOT_CA_G3]).map(fromB64);
    if (!roots.some((r) => equal(r, ders[2]))) return { ok: false, reason: "chain does not end in Apple's root" };
    const [leaf, intermediate, root] = ders.map(parseCert);
    if (!contains(intermediate.extensions, OID.appleIntermediate)) return { ok: false, reason: "intermediate is not Apple's" };
    if (!contains(leaf.extensions, OID.appleLeaf)) return { ok: false, reason: "leaf is not an App Store signing certificate" };
    if (!(await verifiedBy(intermediate, root)) || !(await verifiedBy(leaf, intermediate))) return { ok: false, reason: "chain signature" };
    if (leaf.curve !== "P-256") return { ok: false, reason: "leaf key" };
    const leafKey = await crypto.subtle.importKey("spki", leaf.spki, { name: "ECDSA", namedCurve: "P-256" }, false, ["verify"]);
    const signed = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
    if (!(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, leafKey, fromB64url(parts[2]), signed))) {
      return { ok: false, reason: "signature" };
    }
    const p = decodeJSON<Partial<SignedTransaction>>(parts[1]);
    const signedDate = typeof p.signedDate === "number" ? p.signedDate : NaN;
    if (!Number.isFinite(signedDate) || signedDate > now + 5 * 60_000) return { ok: false, reason: "signing date" };
    // Each certificate valid when the transaction was signed (as Apple's own library checks offline).
    for (const c of [leaf, intermediate, root]) {
      if (signedDate < c.notBefore || signedDate > c.notAfter) return { ok: false, reason: "certificate not valid at signing" };
    }
    if (p.bundleId !== o.bundleId) return { ok: false, reason: "another app's transaction" };
    if (typeof p.environment !== "string" || !(o.environments ?? DEFAULT_ENVIRONMENTS).includes(p.environment)) {
      return { ok: false, reason: "environment" };
    }
    if (typeof p.originalTransactionId !== "string" || !/^[0-9]{1,32}$/.test(p.originalTransactionId)) return { ok: false, reason: "transaction number" };
    if (p.revocationDate) return { ok: false, reason: "revoked" };
    if (typeof p.expiresDate === "number" && p.expiresDate + GRACE_TOLERANCE_MS <= now) return { ok: false, reason: "expired" };
    const tx: SignedTransaction = {
      originalTransactionId: p.originalTransactionId, transactionId: String(p.transactionId ?? ""), bundleId: p.bundleId,
      environment: p.environment, productId: String(p.productId ?? ""), signedDate,
      purchaseDate: p.purchaseDate, expiresDate: p.expiresDate,
    };
    o.cache?.put(tx, digest, now);
    return { ok: true, tx, cached: false };
  } catch {
    return { ok: false, reason: "unreadable credential" };
  }
}
