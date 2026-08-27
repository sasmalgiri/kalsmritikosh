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

Final pass (same day):
- ✅ Standalone CLI evaluator rerun: kalverify recompiles the rules from
  protocol.json and reruns the deterministic evaluators over
  evaluation-facts.json, comparing (rule id → outcome). Proven live against
  the full attack matrix: file edit → INTEGRITY fails; recomputed hashes →
  AUTHENTICITY fails; malicious signer (wrong outcomes re-signed with a fresh
  key) → REPLAY fails via independent rerun.
- ✅ Trusted-signer allowlist: TrustedSigners (local, revocable) + Compliance
  Board "Trust signer"/"Untrust signer"; bundle verification binds identity to
  the list automatically and labels unlisted signers "key-consistent only".
- ✅ Custom-protocol run selection: per-matter "Governing protocol" picker in
  the handoff (persisted per case, locked once the run's constitution is
  frozen; a selected protocol with no active version falls back loudly).

Accurate current claim: tamper-evident, signed, per-rule assessed conformance
with actor-bound attestations, run binding, required-phase enforcement, TOFU
key pinning, and INDEPENDENT evaluator replay (in-app and standalone CLI).
Remaining before the claim is unqualified: approval-transaction atomicity
(needs a service-level transaction API — Database.transaction is synchronous
and multi-await BEGIN/COMMIT is explicitly unsafe in this codebase) and a
pinned developer key shipped in the release binary (an owner/release act:
export the release signing key's fingerprint and pin it at build time).


## Fourth-audit response (2026-08-26) — all ten findings implemented

1. ✅ Approval GATED by conformance: in strict mode the projected assessment
   (as if approved) must be conformant / conformant-with-deviations —
   indeterminate or failed BLOCKS the approval itself.
2. ✅ Recording/sealing failures ride the approval outcome ("approved — ⚠️ …");
   the success path can no longer erase them.
3. ✅ CLI envelope parity restored (runID, runStateSHA256,
   approvedDeviationCount, factsSHA256); the test fixture is PRODUCTION-SHAPED
   (run-bound + evidence manifest) and the CLI verified it live.
4. ✅ Facts are mandatory in bundles and factsSHA256 is SIGNED — the
   facts-deletion downgrade was run live and REFUSED by both verifiers.
5. ✅ Required phases: the built-in doctrine declares [caseIntake, findings];
   rules of an unreached required phase FAIL (attest-all cannot rescue).
6. ✅ Custom vacuous bypass closed: studio protocols require ALL included
   phases; pack verification refuses an empty effective-required set and
   required phases the protocol lacks.
7. ✅ Rule grounding: requiredEvidence (custody), humanRole (approver / case
   owner / analyst) and authorityReferences (SWGDE/NIST, Admiralty, Heuer)
   populated for the known doctrine lines. assertedProhibited remains
   attestation-based — deterministic content detection stays future work.
8. ✅ `conformantWithDeviations` distinct status (v110 CHECK), TYPED deviation
   authorization (who/role/why/when), prohibitions NON-waivable.
9. ✅ Bundles carry evidence-manifest.json (hash signed) alongside facts,
   protocol, evaluations, attestation, key.
10. ✅ Studios: every deliverable that leaves the app (copy/export/print)
   carries a SIGNED deliverable seal — content hash, honest stage completion,
   installation key — via the one shared shell (all ten studios).
CI now runs the standalone CLI against the production-shaped fixture plus the
edited-file, facts-downgrade and wrong-key attacks on every push.

Approval+assessment atomicity: ✅ CLOSED via RECORDED COMPENSATION
(2026-08-26). When the strict-mode assessment cannot be persisted after
approveFindings, the approval is automatically WITHDRAWN as a recorded
decision — both the approval and its reversal stay in the genealogy, the
failure surfaces as the error, and an approval can never stand without its
recorded assessment (tested: compensationWithdrawsApproval). A literal
single-SQL-transaction composition remains an optional refinement — the
codebase documents multi-await BEGIN/COMMIT as unsafe, and compensation
delivers the same invariant with full auditability.

Remaining (by nature, not omission): release-time pinned developer key
(owner act — Compliance Board › Copy my signer fingerprint →
PinnedDeveloperKey.keyID), deterministic prohibited-conclusion detection
(content-analysis engine; attestation-based today), external assurance
(never unilateral).
## Fifth-audit response (2026-08-26) — verified stale vs. real, real items implemented

The fifth external audit examined `0b1828b` — six commits behind, BEFORE
`1a579ac` (fourth-audit implementation) and `20fbe63` (atomicity). Its P0
claims about the approval gate, CLI envelope parity, facts binding, required
phases, rule enrichment, deviation governance, and the curated privilege-log
gate were verified against HEAD and are STALE (already fixed). Its claim
that no Core ML model is committed is FALSE (BGESmallEmbedder + BGEReranker
.mlpackage under Resources/). The five REAL findings, now implemented:

1. ✅ Semantic gates for JSON-authored job workflows. `WCField.mustEqual`
   (a value the field must HOLD, not merely answer) enforced fail-closed in
   `confirmStep` — advisory pre-check AND re-check against re-read
   authoritative values inside the write barrier — plus the auto-complete
   guard and the Confirm button (live-draft aware, reason shown). Applied
   automatically to every required bool attestation in the authored catalog
   ("Integrity verified", "Hold issued", …) and hand-marked on the seven
   binary completion checks ("Privilege log complete?" → "Complete",
   "Redaction validated" → "Validated", "Scope/Protocol confirmed?" →
   "Confirmed", "Approve to proceed?" → "Approved", "Right of reply" →
   "All offered a reply"). Recording a negative now BLOCKS the workflow.
2. ✅ Registry re-verifies at trust boundaries. `importPack` re-verifies
   signature+hash+schema inside the repository (never trusts the caller's
   "already verified"); `activeSutra` re-verifies the stored pack bytes and
   fails CLOSED to the built-in constitution on any mismatch (logged).
3. ✅ Copy sealed certificate re-verifies the stored seal first; an
   unverifiable stored seal is never handed out — replaced by a fresh seal
   or an explicit "UNSEALED" marker.
4. ✅ Audit-chain governance coverage (schema v111). Append-only
   `governance_events` ledger (findings.approved / approval.withdrawn /
   assessment.recorded / bundle.exported) sealed as a THIRD chain source
   beside custody and fact reviews. The approval act is recorded BEFORE the
   assessment seals, so the signed audit-chain head covers it.
5. ✅ Required-phase breadth — DECISION RECORDED: the built-in doctrine
   deliberately mandates [caseIntake, findings] as its spine. Custody,
   decision and closure phases are evidence-driven (their rules bind when
   reached; custody evidence kinds are required by the findings rules), and
   inflating requiredPhaseKinds to all 16 would mark every real matter
   non-conformant for phases that are legitimately conditional (e.g.
   closure on a still-open matter). Breadth is per-Sūtra policy, not a
   global constant: imported/custom protocols declare their OWN
   requiredPhaseKinds, the Studio requires ALL included phases, and pack
   verification refuses an empty effective-required set. Owners who want a
   stricter built-in spine publish an amended protocol pack.

Still by nature, not omission: full conformance ASSESSMENT (vs. deliverable
seals) for the ten studios' outputs is future scope — studios seal what
leaves the app; only the investigator findings handoff carries a governed
approval act today. Website "Download" targets and pricing copy resolve at
release (owner acts, RELEASE_EVIDENCE_INDEX.md).

## Sixth-audit response (2026-08-26) — first audit of current HEAD; all real findings implemented

This audit examined `3762506` (current at audit time) and its findings were
verified individually. Two corrections to OUR OWN earlier statements first:

- RETRACTION: the fourth-audit section said studio seals covered "all ten
  studios". That was wrong — only the four shell-based studios were sealed;
  Forensic, Journalist, Privilege-Log, SIU, Workplace and Reasoning had
  unsealed copy/print/export paths. As of this response all ten ARE sealed
  (the six standalone views now route every deliverable through
  StudioDeliverableSeal), and the claim is true going forward.
- CORRECTION: the fifth-audit response called "no Core ML model committed"
  false. The models exist on the DEVELOPER's disk but are deliberately
  .gitignored (built via scripts/build-bge-*.sh) — the public repo does NOT
  contain them, and the shipped app carries them only when the owner runs
  those scripts before archiving. Now an explicit owner-checklist step.

Implemented from this audit:

1. ✅ Confirmed workflow steps are IMMUTABLE: saveFields refuses a confirmed
   seq (re-read inside the write barrier) and can never plant or overwrite
   the who/when attestation stamps; the confirm barrier re-validates
   required fields, semantic assertions AND gates against re-read state.
2. ✅ The standalone verifier now reruns EVERY evaluator faithfully: the
   evidence-binding gate (gate.evidenceBinding.v1) is mirrored, the
   deterministic evidence enrichment is mirrored from the compiler, and a
   FULL rule-definition comparison (id/kind/text/phase/requiredEvidence,
   count) refuses doctored rule definitions even with reproducible outcomes.
3. ✅ All ten studios seal deliverables (see retraction above).
4. ✅ The classic switch is labelled as what it is — "Classic conformance
   mode (disables enforcement)" — and the website says "strict conformance
   mode (the default)" wherever approval-blocking is claimed. Classic
   remains a deliberate owner decision (restore the previous app IN FULL);
   it produces no certificates, so no false artifacts can come from it.
5. ✅ Systematic completion-check sweep over every required choice field in
   the authored catalog: "Log complete?" → Complete and the content
   creators' "Rights" → All cleared joined the gated set. The remaining
   required choices (Decision / Verdict / Acquisition method / Risk /
   Urgency / Conflicts…) are GENUINE human decisions with multiple
   legitimate outcomes — gating those would falsify the record.
6. ✅ Audit-chain errors now FAIL CLOSED at assessment time: a seal/verify/
   head failure refuses the conformance seal (recorded UNSEALED with an
   explicit warning) instead of silently attesting over an unknown ledger
   state. A compensation double-failure (withdrawal also failing) surfaces
   as a CRITICAL error naming the manual step — never as a quieter version
   of the original failure.
7. ✅ The run binding is now RECOMPUTABLE outside the app: the signed facts
   carry the binding components (receipt seal + case revision); with the
   envelope's runID, verifiers (app bundle verify AND kalverify) recompute
   runStateSHA256 and refuse a mismatch. The binding stopped being an
   assertion. (Source/work-product bytes stay out of bundles by privacy
   design — that boundary is permanent.)
8. ✅ Every built-in discipline declares its mandatory spine: clinical
   [intake, findings]; safety RCA [intake, causalAnalysis, findings];
   systematic review [intake, dataLab, findings]. The persona-lens
   reconstruction no longer drops requiredPhaseKinds or globalRequirements.

Correct-by-nature (documented, not deferred):
- Human authority remains self-asserted — a single-user, on-device app has
  no identity provider; attestations record who/role/why/when and the
  certificate says exactly that. Authenticated roles require an identity
  infrastructure this product intentionally does not have.
- Bundles prove the recorded run state, facts, rules and outcomes — not the
  truth of the underlying evidence. Stated on the verification page.

## Phase A (2026-08-26) — ONE evaluator, zero drift; the parity finding class is closed

The seventh audit's parity finding (CLI missing severity comparison) was the
third instance of one structural cause: the standalone verifier was a
hand-maintained mirror. Phase A removes the cause, not the instance:

- `verifier/kalverify.swift` is now GENERATED (`scripts/generate-kalverify.sh`)
  by concatenating the app's own conformance source verbatim — PersonaJobKind,
  JobTooling, Sutra, SutraConformance, SutraRules (compiler + every evaluator +
  the one `ConformanceStatus.rollup`), ConformanceEnvelope — plus a thin
  file-IO/printing tail (`verifier/kalverify.main.swift`). What an outsider
  reruns IS what the app ran; there is no second implementation to drift.
- CI regenerates on every push and FAILS if the committed verifier is stale.
- Full typed rule equality comes free (SutraRule Equatable covers severity,
  waivability, applicability, evidence requirements, human role, authority,
  evaluator version); the rollup is recomputed by the app's own function.
- Seventh-audit severity-demotion attack: refused twice over — the SIGNED
  ruleEvaluationsSHA256 catches the edit at AUTHENTICITY (the claimed attack
  was in fact never possible), and the shared-core full-rule comparison is
  the second lock. Attack 4 in the CI matrix proves it live.
- Wire types split to `ConformanceEnvelope.swift` (pure) so the envelope the
  CLI decodes is the envelope the app signs, byte-for-byte canonical.
- `recordAssessment` now refuses to seal over a BROKEN audit chain
  (`isIntact` checked, not just the unsealed count) — seventh audit #4.

## Phase C (2026-08-26) — durable approval state machine; the atomicity class is closed

The approval act is now ONE transaction (`ApprovalTransactionRepository`,
schema v112): the findings-approval decision row, the SEALED assessment row
(`approval_state = 'approved'`), and the governance event commit in a single
savepoint with no suspension points inside the barrier. Consequences:

- An approval STRUCTURALLY cannot exist without its recorded assessment —
  compensation is gone because no partial state can ever be observed
  (tested: a failing composite leaves NOTHING, not even a withdrawn pair).
- Sealing happens BEFORE the transaction; strict mode REFUSES the approval
  when the seal or the audit chain refuses ("no seal → no approval"). The
  sixth-audit warning path ("recorded UNSEALED") no longer exists on the
  approval path.
- The audit chain must verify INTACT before sealing; a broken or unavailable
  chain refuses the approval with the reason.
- Withdrawal is likewise atomic with its governance event.
- The revision the seal signs is re-derived inside the barrier and refused
  on mismatch (revisionRace) — the signed revision is the stored revision.
- The website claim "every approved strict-mode run carries a signed
  certificate" is now true BY CONSTRUCTION, not by best effort.
- The pending → assessed → sealed → approved states never persist
  individually; the CHECK'd approval_state column records the collapsed
  transition ('recorded' for assessments stored without an approval act).

## Phase B-1 (2026-08-26) — machine phase observability; the "phases can never complete" class closed for 14 of 16 kinds

The production assessor previously recognized four phases; the other twelve
could never be marked reached. Now:

- v113 `case_method_runs`: startMethod persists WHICH case phase a method
  run advances (causal/linkage/CAPA/effectiveness wrappers pass their
  kinds). Phase completion is DERIVED by joining onto method_runs — the
  runs table stays the single source of truth.
- `PhaseObservationService` derives phase completion from the case's OWN
  ledgers: hypotheses (analysis — a non-proposed hypothesis carries the
  human call), the reliability desk (confirmed assessments), the
  contradiction/gap desk (each item individually reconciled), the subject
  dossier, the identity decision log, and the v113 linkage. A probe error
  reads as NOT observed — fail-closed.
- `conformanceFacts()` unions observed phases into completedPhaseKinds and
  derives their reserved decisions from the decided artifacts; the SIGNED
  facts carry `observedPhaseKinds`, and the certificate prints the
  observed/attested split on its face.
- REFUSE AT RUN START: a governing protocol requiring a phase this build
  cannot machine-observe (today: `ask`, `dataLab`) is refused when the run
  would freeze, with the phases named — never a silent never-conforming
  run. (The systematic-review discipline is therefore not selectable as a
  governing findings protocol until dataLab observation lands — stated
  here, on the certificate, and in the refusal message.)
- Observable today (14/16): intake, findings, custody, closure, analysis,
  sourceReliability, contradictionGap, subjectDossier, identityResolution,
  methods, causalAnalysis, linkage, capaRegister, effectivenessReview.
  B-2 remainders: `ask` + `dataLab` observation, and feeding phase
  observations into the audit chain as a fourth source.

## Phase E (2026-08-26) — the claims registry; the wording class is closed

`CLAIMS.md` maps every load-bearing public sentence to the mechanism that
proves it (a named test, a CI step, a source pattern, or a recorded owner
act). `scripts/check-claims.sh` runs in CI on every push and fails when:
- a registered claim's copy no longer appears on the site (drift), or
- a claim's proof no longer exists (proof rot), or
- refused vocabulary ("provable compliance", "legally compliant",
  "court-admissible", …) appears anywhere in docs/.
New marketing copy therefore requires a registry row with a living proof
BEFORE it can ship. An auditor can dispute a mapping; they can no longer
discover an unbacked sentence.

Phase B-2 disposition: `ask`/`dataLab` observation needs the same
case-linkage pattern as v113 (their artifacts are workspace-scoped today) —
queued, honestly stated in the refusal message and on the certificate.
Feeding phase observations into the audit chain is intentionally NOT done:
observations are DERIVED state, not events; deriving them at assessment
time and signing them in the facts is the correct binding (the chain seals
the underlying ledgers those derivations read).

## Phase D (2026-08-26) — the publicly recomputable trail; the "outsiders can't replay" class shrunk to the privacy boundary

- DUAL-HASH CHAIN (v114): every new seal writes a keyless public link
  (`SHA256(payload || prev)`) alongside the private HMAC link. ONE shared
  computation (`PublicAuditChain` in the generated-verifier core) is used by
  the sealing service, the in-app bundle verifier and kalverify.
- The PUBLIC head is SIGNED into the conformance envelope
  (`publicAuditChainHead`); strict-mode approvals bind it automatically.
- Bundles export `audit-events.json` (event METADATA payloads — document
  content never ships). When the envelope commits to a public head the trail
  is MANDATORY: export refuses without it, and verifiers refuse a stripped
  trail even with a recomputed manifest.
- `kalverify --studio <sealed.md>` verifies studio deliverable seals with
  the app's own `StudioDeliverableVerifier` (shared source; the separator
  and envelope live in the same generated core).
- Pre-v114 rows carry no public link — the public chain starts at the first
  post-v114 seal, stated in the spec and on the wire. The remaining
  non-exportables are permanent privacy boundaries: source/work-product
  bytes and the receipt's content-derived payload stay on the device.

## Phase B-2 (2026-08-26) — TOTAL phase observability: 16 of 16

- v115 `case_phase_artifacts`: the last two attestation-only phases record
  their case artifacts — the case-scoped Ask records one row per verified
  answer (a question DIGEST only, never the question text; hashing lives in
  the repository, honoring the one-fingerprint-system guard), and DataLab
  records one row per prepared dataset.
- `PhaseObservationService.observableKinds` now covers EVERY built-in phase
  kind. The refuse-at-run-start guard stays for future kinds; the
  systematic-review discipline (requires dataLab) is now SELECTABLE as a
  governing protocol and freezes normally — proven by test.
- With B-2, the "phases can never complete" class is fully closed: every
  phase of every built-in protocol is machine-observable, and the signed
  observed/attested split on the certificate shows exactly which ones were.

## Eighth-audit response (2026-08-26) — the audit was RIGHT about the red run; all eight findings closed

**Correction, first:** this repo's status was reported as "CI-green, queue
empty" while the Phase B-2 run (32957155819, `a002135`) was still QUEUED. It
went RED on `architecture-guards`. The claim was premature and wrong; the run
outcome is recorded honestly in `RELEASE_EVIDENCE_INDEX.md`.

1. **Guard red (release blocker).** `CasePhaseArtifactRepository` used
   `PersonaJobKind` inside `Storage/Repositories/`, which the
   persona-neutral-truth guard forbids. The repository exists purely for
   conformance observation, so it MOVED to `Sutra/` (where phase vocabulary
   is legitimate). Guard green.
2. **Artifact truth.** Ask records an observation ONLY for answers that
   actually shipped (`!refused`) with a DURABLE artifact identity derived
   from SHA-256(caseID‖question) — never a random UUID; DataLab records
   AFTER the whole preparation (fields+rows+bindings) succeeded, not at
   dataset creation. Failed observation writes are LOGGED, never swallowed
   (the phase then stays machine-unobserved — the fail-closed direction).
3. **Strict approval fail-open on a missing chain.** approve() now REFUSES
   (`auditChainUnavailable`) when no audit chain is wired; the chain's
   eventProvider is THROWING, so a ledger-read failure fails seal/verify
   instead of silently shrinking the event set; AppState logs a missing
   Keychain secret at fault level.
4. **Signed head vs. advancing ledger.** The envelope's public head is, by
   construction, sealed BEFORE the approval's own governance event (the head
   cannot include the event recording the very approval being sealed).
   Export now TRUNCATES the trail to the prefix ending at the SIGNED head;
   a fresh ledger's genesis head exports with no trail and verifies. Both
   stated in BUNDLE_FORMAT.md; proven by tests
   (trailTruncatedToSignedHead, genesisHeadBundleVerifies).
5. **Public link rule v2 (v116).** Each link now binds
   `seq|source|eventID|occurredAt|payload` — exported trail METADATA can no
   longer be edited without breaking the fold. Genesis bumped to
   `GENESIS-public-audit-chain-v2`; v116 resets v114-rule links (pre-release
   rule change; the private HMAC chain is untouched).
6. **Verifier hardening (both verifiers — shared source).** Unknown manifest
   formatVersion REFUSED; manifest must cover the mandatory file set (an
   emptied `{"files":{}}` cannot pass integrity vacuously); a signed
   runStateSHA256 whose binding components are absent from the facts FAILS
   instead of noting.
7. **Claims registry.** Registered: "every line traceable to a source",
   "end in the actual hardcopy", "deliverable seal", "replays a keyless",
   "trail metadata cannot be edited", and the UNSEALED disclosure (the site
   now says a non-signing Mac produces a report marked UNSEALED on its face
   — the honest form of the old sentence). `owner:` proofs now print their
   conditional status and require a living checklist. Coverage boundary
   STATED in CLAIMS.md: narrative copy is not exhaustively registered;
   enforcement/guarantee sentences must get a row before shipping.
8. **Stale docs.** BUNDLE_FORMAT.md now lists evaluation-facts.json /
   evidence-manifest.json / audit-events.json with their mandatory
   conditions, documents rule v2 + truncation + genesis, and corrects the
   rule-comparison statement (both verifiers compare full typed rules).
   RELEASE_EVIDENCE_INDEX.md header now states rows are dated snapshots,
   names the living truth sources, and records the red run honestly.

Declared boundaries unchanged (classic mode by owner directive, self-asserted
roles, no source bytes in bundles, private HMAC key + public v2 chain,
gitignored BGE models built at archive time, no legal-compliance claims).

## Ninth-audit response (2026-08-26) — all five findings closed

(The audit's cited file paths were fabricated — `KalSmritiKosh/Features/…`
does not exist — but every described behavior was verified REAL in the
actual sources before fixing.)

1. **Ask counted non-refused incompletes.** True: AEE-M2's `answer()`
   collapses `.verifiedFinal` and `.incomplete` into one VerifiedAnswer, and
   a ledger-commit failure yields a NON-refused incomplete. The case-scoped
   Ask now consumes the lifecycle STREAM and records phase evidence only on
   `.verifiedFinal` — which by the AEE-M2 contract is emitted only AFTER the
   durable answer-ledger lock. A dataLab observation now REFUSES an
   artifact ID with no matching `workbench_datasets` row
   (`CasePhaseArtifactError.artifactMissing`); ask artifacts keep their
   digest-derived identity (answers are keyed by ledger revision, not by
   this ID) with the verifiedFinal gate as the truth link — stated in code.
2. **Keyless rewrite of public columns / occurred_at.** True: the HMAC
   covered neither. `verify()` now RE-DERIVES the stored timestamp and the
   full public chain (rule v2) from the authoritative source events, and
   `publicTrail()` exports provider data, never audit_chain's stored copies.
   A direct `UPDATE audit_chain SET occurred_at…` or a keyless public-hash
   rewrite is reported as a break BEFORE strict approval signs the head —
   proven by test (publicColumnsRewriteDetected).
3. **Registry not bidirectional.** `check-claims.sh` now checks
   site → registry too: any docs line matching the enforcement-keyword
   heuristic must carry a registered fragment or an explicit
   `claims-exempt` marker (disclaimers). The audit's reproduction (add an
   enforcement sentence → gate passes) now FAILS the gate — verified. Seven
   new rows registered ("Real standards, enforced", "refuses to guess",
   "enforced evidence gate", "refuses when the record", "disabling that
   enforcement", "right of reply enforced", "conclusions the app refuses to
   assert"); the models-ship sentence carries conditional wording on the
   site. The heuristic's limits are STATED in CLAIMS.md.
4. **Manifest gaps.** README.txt is now manifest-covered; both verifiers
   refuse a standalone `public-key.hex` that differs from the key embedded
   in the signed attestation; BUNDLE_FORMAT.md states plainly which layer
   protects what — the manifest is unsigned BY CONSTRUCTION (it covers the
   attestation; signing it would be circular), so forgery resistance lives
   entirely in the signed envelope's own hashes.
5. **Guard flake.** `printf | grep -q` under `pipefail` could SIGPIPE;
   replaced with pure shell case-matching (no pipe).

## Tenth-audit response (2026-08-26) — the three residual gaps closed

(This audit used REAL repository paths and its scoring was accurate: two
closed, three partial. All three residuals are now implemented.)

1. **Ask truth binding (was partial).** `VerifiedAnswer` gains
   `ledgerAnswerID` — the COMMIT PROOF, set by MasterBrain only after
   `lockVerifiedFinal` succeeded, carrying the ledger's answer ID. A
   degraded no-ledger `.verifiedFinal` carries nil (display-terminal, NOT
   durably committed — stated on the enum). The case-scoped Ask records
   phase evidence only when the proof is present, and the artifact ID IS
   that ledger answer ID; `CasePhaseArtifactRepository` refuses an ask
   artifact with no matching `verifiedFinal` event in
   `answer_revision_events` — the audit's random-ID reproduction now
   throws. The degraded emission itself is a DECLARED design decision
   (AEE-M2: tests/boot still get display-terminal answers); durability is
   now distinguishable on the wire, which is what conformance requires.
2. **Claims gate authority (was partial).** Exactly as prescribed:
   enforcement/verifiability/privacy sentences carry `data-claim="<id>"`
   attributes; CLAIMS.md is a three-column registry (id · verbatim
   fragment · proof); `check-claims.sh` enforces the id gate in BOTH
   directions (registry id must be tagged on the site; site id must have
   exactly one row; fragments and proofs still checked) and the keyword
   heuristic is demoted to a SECONDARY WARNING. The audit's bypass
   sentence now surfaces; an unregistered site id FAILS (both verified).
   Newly registered: never-leaves / no-servers / erase-everything /
   private-by-design (with real proofs). The models sentence now states
   the release-acceptance verification act inline.
3. **Manifest completeness (was partial).** README.txt joined the
   MANDATORY set; both verifiers require the bundle directory to contain
   EXACTLY manifest.files + manifest.json (deleted-and-delisted files and
   unlisted additions both fail; dotfiles excluded as OS artifacts, stated
   in the spec); the site and spec now say "the signed evidence-bearing
   contents have not changed" instead of "nothing changed since". Tests:
   exactDirectoryContentsEnforced (deletion + smuggling).

## Eleventh-audit response (2026-08-27) — case binding, structural claims gate, fail-closed enumeration

1. **Phase evidence bound to the case (was the "moat" gap).** Schema v117
   recreates `case_phase_artifacts`: FK to `investigation_cases`, immutable
   `case_revision` + INV-01-C4 `scope_fingerprint` columns, and
   UNIQUE(phase_kind, artifact_id) — one artifact is phase evidence for
   exactly ONE case. `record()` refuses a nonexistent case, a stale case
   revision, and an artifact already bound to another case (same-case
   re-record is idempotent). Both producers pass their REAL resolved
   context: Ask stamps the request's `InvestigationScopeContext`
   (revision + fingerprint), DataLab computes the fingerprint from the
   preparation's own scope. Pre-v117 rows carried no binding and are
   DROPPED (fail-closed: those phases return to machine-unobserved).
   Negative tests: nonexistent case, stale revision, case-A answer
   refused for case B, nonexistent answer/dataset.
2. **Structural claims gate.** The id/fragment checks are now an HTML
   parse: every registry fragment must occur INSIDE the text of an element
   carrying its id, checked PER FILE so a page cannot borrow another
   page's copy — the audit's swap-ID reproduction now fails with two
   errors (verified), and the clean tree passes. The untagged privacy
   sentences are tagged: privacy.html's short version, all persona-page
   pills, the Nothing-collected card (new `privacy.nothing-collected`
   row, owner-conditional), the privacy FAQ entries, the verification
   footer, and the website mirrors.
3. **Fail-closed enumeration + honest dotfile rule.** An unenumerable
   bundle directory now FAILS integrity in both verifiers (never silently
   skipped — test with a wx--x--x directory; CI attack 6). The dotfile
   exclusion is narrowed to exactly `.DS_Store` and AppleDouble `._*`; a
   smuggled `.extra.json` fails (test + CI attack 5), a genuine
   `.DS_Store` does not break a legitimate bundle (test). Stated in
   BUNDLE_FORMAT.md.

## Twelfth-audit response (2026-08-27) — the P0 migration defect + both partials closed

1. **P0 — the stale-counter self-heal skipped v107+ (RELEASE BLOCKER,
   confirmed).** `isSchemaFullyApplied()`'s marker list had not been
   extended past v106, so a real database at user_version 107–117 with the
   full v106 shape was stamped to latest WITHOUT the pending migrations
   running — a v116 database could report v117 while `case_phase_artifacts`
   kept the unbound v115 shape. Fixed: schema v118 rebuilds the table
   FAIL-CLOSED (idempotent DROP IF EXISTS + CREATE — unbound rows cannot be
   trusted retroactively); the sentinel now carries distinguishing markers
   for every migration v107…v118 (conformance_assessments+approval_state,
   protocol_registry, governance_events, case_method_runs, audit_chain
   public columns, the rebuilt case_phase_artifacts columns) plus stored-SQL
   probes for the UNIQUE(phase_kind, artifact_id) and case FK; migration
   milestones now include 106/107/111/113/115/116; dedicated tests prove a
   real v116 database receives the rebuild (unbound row dropped, constraints
   present after reopen) and a database WRONGLY stamped v117 in the field is
   repaired by v118.
2. **Scope binding enforced after recording.** `phaseCounts` counts only
   bindings matching the case's CURRENT revision (self-contained join —
   evidence recorded under a superseded scope is stale and no longer
   machine-observed; test: a revision bump empties the observations).
   `record()` now COMPUTES the fingerprint from the supplied scope with the
   one shared fingerprinter (no caller-supplied value to forge), refuses a
   same-case re-record at a different state (bindings are immutable), and
   inserts ATOMICALLY with the revision guard inside the INSERT (zero rows
   ⇒ the revision moved ⇒ staleness). ARTIFACT ORIGIN now determines the
   case, not binding order: v118 adds `answers.origin_scope_id`, stamped at
   answer CREATION by the producing request (the case-scoped Ask passes its
   case; global Asks carry NULL) and threaded opaquely through
   MasterBrain.answerStream — an ask artifact must be a durably committed
   answer whose origin IS the recording case, and a dataLab dataset must
   live in the case's own workspace. Tests: global answer refused, case-A
   answer offered FIRST to case B refused, cross-workspace dataset refused.
3. **Untagged privacy claims are failures.** The structural checker now
   walks text OUTSIDE data-claim elements — including
   `<meta name="description">` content — and any privacy-pattern match is
   an ERROR. All 23 previously untagged assertions are tagged (persona-page
   "Nothing is uploaded, ever" blocks → new `privacy.no-upload` +
   `privacy.offline` rows; privacy.html's offline/no-transmission paragraph;
   both index metas; the website hero; comparison-table cells), and CI
   self-tests the gate by injecting an untagged privacy sentence and
   requiring failure.

## Thirteenth-audit response (2026-08-27) — authoritative scope, case-bound datasets, structural claim zones

1. **Phase evidence is now authoritative, not caller-trusted.**
   `CasePhaseArtifactRepository` resolves the case's CURRENT scope ITSELF
   (case record → CaseRetrievalScopeResolver → the one fingerprinter) over
   the same single ledger. `record()` verifies the caller-resolved
   fingerprint against that authority and refuses `caseScopeNotCurrent` on
   mismatch; `phaseCounts()` counts only rows matching the CURRENT revision
   AND CURRENT authoritative fingerprint — so a logical source whose current
   version moved WITHOUT a case-revision bump un-observes the stale
   evidence (the exact thirteenth-audit reproduction; test:
   scopeFingerprintStaleness).
2. **DataLab origin is the CASE, not the workspace.** Schema v119 adds
   immutable `workbench_datasets.origin_case_id`, stamped once at creation
   by the case-scoped DataLab service (no setter exists). Phase evidence
   requires dataset origin == the recording case: a workspace-global
   dataset (origin NULL) and a SAME-WORKSPACE sibling case's dataset are
   both refused regardless of binding order. Sentinel + migration
   milestones (117, 118) extended; pin bumped to v119.
3. **The claims gate is structural, not regex-only.** Untagged text is
   AGGREGATED across inline markup before matching (`Nothing <em>is</em>
   uploaded` fails), the privacy regex covers the previously missed
   assertion shapes (never sent / not copied / never uploaded / stored
   only / local database / no cloud), and privacy pages are claim ZONES:
   every text node must live inside `data-claim` or `data-claims-exempt`,
   so uncovered text fails outright with no regex to outsmart.
   privacy.html is fully tagged (4 new claim rows + structural exemptions);
   CI self-tests all three failure modes (untagged, inline-split, zone).
