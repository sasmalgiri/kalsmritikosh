# Conformance Roadmap — governing spec (2026-08-25)

Thesis: **Dynamic authorship. Signed, immutable execution. Independently replayable proof.**

Assurance levels and the maximum permitted claim:

| Level | Meaning | Status |
|---|---|---|
| 1 | One outcome per typed rule, fail-closed, Sutra frozen by SHA-256 | **Core shipped** (`Sutra/SutraRules.swift`); remainder below |
| 2 | ECDSA P-256 signed seal; recomputed-hash forgery fails signature | **Core shipped** (`Core/Security/ConformanceSeal.swift`); remainder below |
| 3 | Standalone open verifier: integrity / authenticity / conformance replay | **Shipped** — `ConformanceBundle` export, `verifier/kalverify.swift` CLI, spec in `docs/verification/BUNDLE_FORMAT.md`; cross-verified both ways (CLI accepts app bundles; CLI rejects tampering; app-side tamper matrix incl. recomputed-hash forgery) |
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

Completed in the tail pass (2026-08-25, all suite-verified):
- ✅ Evidence binding: `requiredEvidence` gates evaluation (`gate.evidenceBinding.v1`;
  attestation cannot substitute for absent evidence); the custody manifest is
  hashed into the envelope (`evidenceManifestSHA256`) and signed.
- ✅ Audit-chain feed: at approval the v104 chain is sealed, verified, and its
  head + count bind into the signed envelope; a remaining unsealed count
  refuses the seal.
- ✅ Deviation recording UI: per-rule "Record deviation…" with mandatory
  justification; travels visibly on the certificate.
- ✅ Multi-phase facts: chain-of-custody and closure phases evaluate alongside
  findings (reach, decisions, and evidence kinds derived from the snapshot).
- ✅ Secure Enclave signing when the hardware offers it (Keychain software key
  fallback); `signerAssurance` recorded and signed in the envelope.

Deliberately out of scope here (by design, not omission):
- Persona studios are standalone deliverable documents whose completeness gates
  live in `StudioDeliverable.isComplete`; run-level conformance applies to case
  runs. Extending sealed assessments to studio deliverables is part of the
  1.0.x-C bundle format work, where each deliverable exports as a verifiable
  bundle rather than growing its own parallel assessor.

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

- **1.0.x-C — open verifier**: ✅ SHIPPED (2026-08-25). Bundle format v1
  (canonical bytes on disk, three separated verdicts), in-app export from the
  strict readout, standalone CLI (Foundation + CryptoKit only, no app
  dependency), published spec. Acceptance tests 5/6/7 verified: editing any
  file breaks integrity; a recomputed-hash forgery passes integrity but fails
  the signature; the verifier recomputes the same status the app sealed.
- **1.1 — offline protocol packs + governance**: ✅ SHIPPED (2026-08-25).
  Signed `.kalprotocol` packs (P-256; a pack activates ONLY when signature +
  hash + schema-compile all pass — acceptance test 8); registry with
  imported → active → superseded / revoked lifecycle (v108); new runs freeze
  the ACTIVE imported constitution, built-in doctrine as fallback; activation
  never mutates frozen runs (acceptance test 9); full offline update loop
  export → verify → import → activate tested (acceptance test 11); the
  Compliance Board gained pack import/activate/revoke and GOVERNED review
  records (reviewer, role, source, decision, notes — signed with the
  installation key, "reviewed as of date" not "current"). Zero network
  retained throughout (test 12). Distribution: Files/AirDrop/USB/MDM.
- **2.0 — custom protocol studio**: ✅ BUILT, SHIPPED OFF (owner decision
  2026-08-25; Settings › Custom protocol studio). Lifecycle Draft (AI drafts
  only, via SutraDraftParser) → Structure (per-phase obligations / reserved
  decisions / prohibitions + global requirements, on the standard phase
  skeleton) → Compile (the SAME export→verify gate that guards activation) →
  Test (fact simulator with live fail-closed status) → Sign (publisher +
  self-authored / organization-approved assurance) → Register/Activate through
  the ordinary v108 registry. Custom constitutions assess fail-closed like any
  built-in. Remaining inside 2.0: visual per-rule builder with applicability /
  evidence-requirement editors, multi-role approval, pack sharing UX.
- **Later — external assurance**: expert crosswalks, published mappings, partnerships; certification only where a body grants it.

The moat is not the hashes (copyable) — it is expert-reviewed mappings, the portable rule corpus, accumulated edge cases, evidence-level provenance, org-specific packs, and professional acceptance of the attestations.

## Third-audit verdict (2026-08-25) — honest current state

Fixed in the audit-response pass:
- ✅ CI red: MigrationMatrixTests pinned latestVersion 106 → 108 (+ v107/v108
  table markers); guard step gained `set -o pipefail` (the false-green hole).
- ✅ Classic readout relabelled: "legacy checklist — not a per-rule conformance
  determination" (kept per owner decision, no longer masquerades).
- ✅ Empty protocols refuse everywhere (pack verify + studio build): zero rules
  can no longer roll up as vacuously conformant; built-in identifiers reserved
  in the studio.
- ✅ Replay compares FULL rule definitions (id + kind + severity + text), not
  IDs — a severity swap under a kept ID is caught.
- ✅ kalverify takes an optional trusted signer key ID; without one, AUTHENTICITY
  is explicitly labelled "key-consistent only". Wrong key ID fails.
- ✅ Sealing failures surface to the reviewer instead of silently recording an
  unsealed row.
- ✅ Website claim scoped to what is true (approved findings runs, fail-closed).

Structural items — status after the v109 pass (all suite-verified):
1. ✅ Per-rule, actor-bound attestations (who/role/rationale/timestamp on each
   evaluation, `human.attest.v2`); the blanket "attest all" toggle is GONE from
   the UI. Bare programmatic `attestedRuleIDs` still exists for tests and is
   reported as "unattributed" on the certificate.
2. ✅ Run binding: assessments carry the real findings run ID + a run-state
   hash (run ID, receipt seal, case revision), persisted (v109 columns) and
   signed into the envelope. ⏳ Same-transaction atomicity with approval is
   still pending (recording happens immediately after, failures surface loudly).
3. ✅ Required phases: `Sutra.requiredPhaseKinds` (legacy default: findings);
   an unreached required phase FAILS its rules (`gate.requiredPhase.v1`) —
   attesting everything cannot rescue it (tested).
4. ✅ TOFU key pinning: a known publisher presenting a new key is refused until
   prior packs are explicitly revoked (rotation is an act, never silent);
   in-app bundle verify + kalverify accept a trusted signer key ID and label
   unpinned verification "key-consistent only". ⏳ A pinned developer key
   shipped in the app bundle is still pending.
5. ✅ True replay: bundles carry `evaluation-facts.json`; the in-app verifier
   RERUNS every evaluator over the recorded facts and requires exact
   reproduction — a legitimately signed but wrongly computed evaluation is
   caught (tested). ⏳ The standalone CLI still does outcome-consistency only
   (portable evaluators are the remaining piece).
6. ⏳ Custom protocol selection at run creation (today only the built-in
   doctrine id resolves for real runs).
7. ✅ Deviations distinct on the wire: `approvedDeviationCount` signed in the
   envelope; the readout says "Conformant with N approved deviation(s)".

Accurate current claim: tamper-evident, signed, per-rule assessed conformance
with actor-bound attestations, run binding, required-phase enforcement, TOFU
key pinning, and in-app evaluator replay. The standalone-CLI evaluator rerun,
approval-transaction atomicity, a shipped pinned developer key, and custom-
protocol run selection remain before "fully independently replayed" is claimed.
