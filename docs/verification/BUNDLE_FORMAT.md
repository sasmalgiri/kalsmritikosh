# Kalsmritikosh conformance verification bundle — format v1

A sealed conformance assessment exports as a plain folder that anyone can
verify without Kalsmritikosh. This document is the format contract; a
reference verifier (Foundation + CryptoKit only) lives at
[`verifier/kalverify.swift`](../../verifier/kalverify.swift).

## Files

| File | Content |
|---|---|
| `protocol.json` | The exact constitution (Sūtra) the run was assessed against — the canonical JSON snapshot frozen at run start. MANDATORY. |
| `rule-evaluations.json` | Every typed rule with its single outcome (`passed` / `failed` / `notApplicable` / `notEvaluated` / `approvedDeviation` / `evaluatorError`), evaluator ID and detail — canonical encoding. MANDATORY. |
| `attestation.json` | The signed seal: envelope + ECDSA P-256 signature (DER, hex) + public key (X9.63, hex). MANDATORY. |
| `evaluation-facts.json` | The canonical consulted facts the evaluators ran over (phase completion, decisions, attestations, run-binding components). MANDATORY — a bundle that cannot be replayed is refused at export, and `factsSHA256` is signed. |
| `evidence-manifest.json` | The run's evidence manifest (source-version IDs + custody content hashes) when the signed envelope carries `evidenceManifestSHA256`. Metadata only — never document content. |
| `audit-events.json` | The PUBLIC audit trail (Phase D), truncated to the SIGNED head. MANDATORY when the envelope signs a non-genesis `publicAuditChainHead`. |
| `public-key.hex` | The signer's public key again, as a standalone file for convenience. MANDATORY. |
| `manifest.json` | `{ "formatVersion": 1, "files": { "<name>": "<sha256 hex>" } }` over every other file, INCLUDING `README.txt` (ninth audit). Verifiers REFUSE an unknown `formatVersion` and REFUSE a manifest that does not cover the mandatory file set (eighth audit — an emptied manifest cannot pass integrity vacuously). |
| `README.txt` | Human instructions. Manifest-covered; display-only (its hash is not in the signed envelope). |

No source documents are included — only rule outcomes, metadata and hashes.
The evidence manifest, when exported, reveals source-version IDs and content
hashes (custody metadata), never content.

**What each layer protects (stated honestly).** The manifest is UNSIGNED by
construction — it covers `attestation.json`, so it cannot be signed by the
attestation without circularity. INTEGRITY therefore detects accidental
corruption and naive edits, nothing more. Forgery resistance lives entirely
in AUTHENTICITY: the signed envelope hashes the protocol, evaluations,
facts, evidence manifest and public-trail head, so no evidence-bearing file
can be swapped without breaking the signature. The standalone
`public-key.hex` MUST byte-equal the key embedded in the signed attestation
(ninth audit) — verifiers refuse a swapped standalone key. An attacker who
rewrites a display-only file AND regenerates the unsigned manifest changes
nothing the certificate attests to.

## Canonicalization (the signing contract)

All hashed/signed JSON is produced with: **UTF-8, lexicographically sorted keys,
ISO-8601 dates, no pretty-printing** (Swift: `JSONEncoder` with
`.sortedKeys` + `.iso8601`). Bundle files store those exact bytes, so verifiers
hash **raw file bytes** — never re-encode `protocol.json` or
`rule-evaluations.json`. Only the attestation **envelope** must be re-encoded
canonically (from the mirrored struct in the spec) to check the signature.

## Verification — three separated verdicts

1. **INTEGRITY** — every file listed in `manifest.json` exists and its SHA-256
   matches. Detects edits, truncation, renames. Proves nothing about origin.
2. **AUTHENTICITY** — (a) `envelope.sutraSHA256 == SHA256(protocol.json bytes)`;
   (b) `envelope.ruleEvaluationsSHA256 == SHA256(rule-evaluations.json bytes)`;
   (c) the ECDSA P-256/SHA-256 signature over the canonical envelope bytes
   verifies with the embedded public key. Editing any content and recomputing
   the hashes still fails (c). `signerAssurance` states where the private key
   lives: `secure-enclave`, `keychain-software`, or `external-software`.
3. **CONFORMANCE REPLAY** — recompute the fail-closed rollup from the
   evaluations: any mandatory `failed` → `notConformant`; else any mandatory
   `notEvaluated`/`evaluatorError` → `indeterminate`; else `conformant`. Must
   equal `envelope.overallStatus`; the evaluation count must equal
   `envelope.ruleCount`; rule IDs must be unique. When `evaluation-facts.json`
   is present (always, for app-produced bundles), the verifier RERUNS the
   deterministic evaluators: recompile the rules from `protocol.json`
   (global requirements → `global.requirement.<i>`; per phase, obligations /
   humanDecisions / prohibitedConclusions → `<kind>.<type>.<i>`), evaluate each
   over the facts (applicability → required-phase failure → deviation →
   kind-specific gates → attestation), and require every (rule id → outcome)
   to reproduce exactly. This catches a wrongly computed evaluation even when
   it was legitimately signed. BOTH verifiers (in-app and the generated CLI —
   which is the app's own source concatenated, not a mirror) compare FULL
   rule definitions: every rule field participates via typed equality.
   When the envelope signs `runStateSHA256`, the facts MUST carry the
   binding components (`runReceiptSeal`, `runCaseRevision`) and the binding
   MUST recompute — components absent fails REPLAY (unverifiable binding
   refused, eighth audit).

Each verdict gates the next; report all three separately — never a single
blended "genuine" claim.

## What a passing bundle proves — and what it does not

Proves: this exact assessment (these rules, these outcomes, this constitution,
this status) was signed by the holder of the embedded key, and nothing in the
bundle changed since. Does **not** prove: which human ran it, that the
underlying evidence is truthful, or compliance with any external standard —
see the assurance-level table in `CONFORMANCE_ROADMAP.md`.

## Envelope fields (v2)

`formatVersion, sutraCitation, sutraSHA256, ruleEvaluationsSHA256,
overallStatus, ruleCount, assessedAt, applicationBuild, signerKeyID,
signatureAlgorithm, caseID?, runRevision?, auditChainHead?, auditEventCount?,
receiptSeal?, databaseSchemaVersion?, evidenceManifestSHA256?, signerAssurance?,
runID?, runStateSHA256?, approvedDeviationCount?, factsSHA256?`

`overallStatus` vocabulary: `conformant` · `conformantWithDeviations` (every
mandatory rule resolved, at least one via a typed authorized deviation —
NEVER blended into plain conformant) · `notConformant` · `indeterminate`.
Prohibitions are non-waivable: a deviation on one evaluates `failed`.

**Downgrade-proof facts:** `factsSHA256` is SIGNED. When present, verifiers
MUST require `evaluation-facts.json`, check its hash, and rerun the
evaluators; deleting the facts (even with a regenerated manifest) fails
REPLAY. `evidenceManifestSHA256`, when present, likewise requires a matching
`evidence-manifest.json`. Required phases travel inside the facts
(`requiredPhaseKinds`): a rule of an unreached required phase evaluates
`failed`, never `notApplicable`.

Optional fields are omitted when absent (never `null`), which the sorted-keys
canonical form preserves deterministically.

## Phase D additions (2026-08-26; rule v2 — eighth audit)

- `audit-events.json` — the PUBLIC audit trail: an array of
  `{seq, source, eventID, occurredAt, canonicalPayload, publicPrev, publicHash}`
  (canonical JSON). **Chain rule v2:** each link is
  `SHA256(canonicalEntry || "|" || prev)` where
  `canonicalEntry = "<seq>|<source>|<eventID>|<occurredAt ISO-8601 UTC, whole seconds>|<canonicalPayload>"`,
  folded from genesis `GENESIS-public-audit-chain-v2`. The link binds the
  entry's METADATA as well as its payload — editing `seq`, `source`,
  `eventID` or `occurredAt` in an exported trail breaks the fold. The final
  hash must equal the envelope's SIGNED `publicAuditChainHead`. When the
  envelope signs a non-genesis head, this file is MANDATORY — its absence
  fails REPLAY (downgrade refused). Payloads are event METADATA only;
  document content never ships.
- **Truncation to the signed head:** the ledger keeps sealing after the
  envelope signs its head (the approval's own governance event seals next,
  by construction — the head cannot include the event that records the very
  approval being sealed). Export therefore ships the trail PREFIX ending at
  the signed head; the approval event appears in later exports' trails and
  in the ledger itself. A trail extending past the signed head is an export
  bug and fails replay.
- **Genesis head:** a fresh, zero-event ledger's head IS the genesis
  constant. Such a bundle ships no `audit-events.json` and is valid; a
  non-empty trail claiming to fold to genesis fails.
- Envelope field `publicAuditChainHead` (optional; nil on pre-v114 seals).
  Rows sealed under the v114 payload-only rule were RESET by schema v116
  (pre-release rule change) — the public chain starts at the first
  post-v116 seal, stated here.
- Studio deliverables: `swift kalverify.swift --studio <sealed.md>` verifies
  a sealed studio report — content hash above the seal separator + ECDSA
  P-256 over the canonical `StudioDeliverableEnvelope` — with the app's own
  `StudioDeliverableVerifier` (shared source, not a mirror).
