# Conformance Roadmap — governing spec (2026-08-25)

Thesis: **Dynamic authorship. Signed, immutable execution. Independently replayable proof.**

Assurance levels and the maximum permitted claim:

| Level | Meaning | Status |
|---|---|---|
| 1 | One outcome per typed rule, fail-closed, Sutra frozen by SHA-256 | **Core shipped** (`Sutra/SutraRules.swift`); remainder below |
| 2 | ECDSA P-256 signed seal; recomputed-hash forgery fails signature | **Core shipped** (`Core/Security/ConformanceSeal.swift`); remainder below |
| 3 | Standalone open verifier: integrity / authenticity / conformance replay | Planned 1.0.x-C |
| 4 | External-standard compliance | Never claimed unilaterally — assurance-labelled only |

## Levels 1–2 remainder — status after v107 (2026-08-25)

Done (all suite-verified):
- ✅ Per-rule evaluations persisted as append-only DB rows bound to the case
  (`conformance_assessments`, migration v107; `ConformanceAssessmentRepository`).
- ✅ Sutra frozen at RUN START (findings build), recorded with the assessment;
  old runs reopen against their stored snapshot, never the live compiler
  (tested: `reopenAgainstOriginal`).
- ✅ Facts derivation moved into the model (`WorkProductHandoffModel.conformanceFacts()`);
  the view no longer assembles facts.
- ✅ Rule schema depth: applicability (restricted language: `always` /
  `phase_reached(<kind>)`; unknown → evaluatorError, fail-closed), evaluatorVersion,
  requiredEvidence (declared), humanRole, authorityReferences.
- ✅ `globalRequirements` on `Sutra` → mandatory always-applicable global rules.
- ✅ Producers: `approvedDeviation` (facts.approvedDeviations, justification on the
  certificate) and `evaluatorError` (unparseable applicability, phase-less human rule).
- ✅ Envelope v2 linkage fields (caseID, runRevision, auditChainHead, auditEventCount,
  receiptSeal, databaseSchemaVersion) — signed, forgery-tested.
- ✅ Seal refusals: indeterminate, unsealed audit events, run-revision mismatch.
- ✅ Owner switch: Settings › "Classic conformance readout" restores the previous
  behavior verbatim; strict mode is the default; the flip is lossless.

Still open (honest tail):
- requiredEvidence is declared on rules but not yet BOUND to evidence records
  (attestation substitutes); evidenceManifestSHA256 not yet in the envelope.
- The live handoff does not yet feed auditChainHead/unsealedCount from the v104
  AuditChain into the linkage (fields + refusal exist and are tested; production
  wiring passes receiptSeal, revision and schema version).
- Deviations have producers + tests but no recording UI yet.
- Wiring beyond the findings handoff (studios, other phases); Secure Enclave
  option; signer assurance levels.

## Non-negotiable acceptance tests

1. Booleans alone can never generate conformance — every mandatory rule has exactly one persisted result. ✅ (`ConformanceLevel12Tests`)
2. Mandatory `notEvaluated`/`evaluatorError` block conformance (indeterminate, never green). ✅
3. The exact Sutra snapshot (canonical JSON + SHA-256) is frozen into the assessment. ✅
4. N/A only by deterministic condition (phase not reached). ✅
5. Editing the envelope and keeping/recomputing hashes still fails the signature. ✅
6. Indeterminate assessments refuse to seal. ✅
7. The standalone verifier recomputes the same status as the app. ⏳ 1.0.x-C
8. An unsigned custom protocol cannot activate. ⏳ 1.1
9. A protocol never mutates during a run; supersession creates a new run. ⏳ 1.1
10. Protocol updates ship as signed OFFLINE packs (Files/AirDrop/MDM import) — the app makes zero network connections, always. ⏳ 1.1

## Wording rules (marketing + UI)

- Unkeyed hash chains are "integrity checks — internally consistent", never "genuine/unaltered".
- The seal "proves this installation's key signed this exact assessment" — not who ran it, not third-party certification.
- Claims by assurance level: developer pack → "conformant to Kalsmritikosh Protocol X"; org pack → "conformant to ACME Protocol X"; expert-reviewed mapping → "independently reviewed mapping to selected requirements of Standard Y"; external certification → only the exact granted claim.
- Compliance Board is a *reminder + review record*, status is "reviewed as of date", never automatically "current".

## Sequence

- **1.0.x-C — open verifier**: portable JSON rule format (no Swift/JS/AI execution), published canonicalization spec + test vectors + tampered fixtures, small OSS CLI, separate integrity/authenticity/replay verdicts.
- **1.1 — offline protocol packs + governance**: signed import, authority manifests, governed review records (reviewer, source hash, diff, affected rules, signature), supersession/revocation.
- **2.0 — custom protocol studio**: AI drafts only; typed rule builder; lifecycle Draft → Structure → Compile → Test → Expert review → Org approval → Sign → Activate → Supersede; assurance labels.
- **Later — external assurance**: expert crosswalks, published mappings, partnerships; certification only where a body grants it.

The moat is not the hashes (copyable) — it is expert-reviewed mappings, the portable rule corpus, accumulated edge cases, evidence-level provenance, org-specific packs, and professional acceptance of the attestations.
