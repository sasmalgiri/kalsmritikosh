# Kalsmritikosh conformance verification bundle — format v1

A sealed conformance assessment exports as a plain folder that anyone can
verify without Kalsmritikosh. This document is the format contract; a
reference verifier (Foundation + CryptoKit only) lives at
[`verifier/kalverify.swift`](../../verifier/kalverify.swift).

## Files

| File | Content |
|---|---|
| `protocol.json` | The exact constitution (Sūtra) the run was assessed against — the canonical JSON snapshot frozen at run start. |
| `rule-evaluations.json` | Every typed rule with its single outcome (`passed` / `failed` / `notApplicable` / `notEvaluated` / `approvedDeviation` / `evaluatorError`), evaluator ID and detail — canonical encoding. |
| `attestation.json` | The signed seal: envelope + ECDSA P-256 signature (DER, hex) + public key (X9.63, hex). |
| `public-key.hex` | The signer's public key again, as a standalone file for convenience. |
| `manifest.json` | `{ "formatVersion": 1, "files": { "<name>": "<sha256 hex>" } }` over every other file. |
| `README.txt` | Human instructions. |

No source documents are included — only rule outcomes and hashes. The
`evidenceManifestSHA256` in the envelope commits to the run's custody manifest
(source-version IDs + content hashes) without revealing it.

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
   it was legitimately signed. The in-app verifier additionally compares full
   rule definitions (id + kind + severity + text).

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
receiptSeal?, databaseSchemaVersion?, evidenceManifestSHA256?, signerAssurance?`

Optional fields are omitted when absent (never `null`), which the sorted-keys
canonical form preserves deterministically.
