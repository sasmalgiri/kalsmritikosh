# Kalsmritikosh — Completion Directive execution plan

Source: `Kalsmritikosh-Xcode-Completion-Directive.md` (15 Sep 2026). Branch:
`v11-implement-all` (18 commits ahead of `main` @ faebecf). This plan maps
the directive's Stages 0–15 / gates G0–G5 onto concrete, dependency-ordered
work, marking what the v11 IMPLEMENT-ALL program already delivered vs what is
genuinely new. It is the resumable record required by §22.

Legend: ✅ done · ◐ partial · ✗ not started · 🔎 verify.

---

## 0. In-flight right now (finish first)
- **Domain-pack precision fix** (Stage 2/4 provenance-quality). Live ledger
  showed the six new packs false-firing: `medication="TOJXAijyAQ-3D-3D"`
  (base64), `diagnosis="FIR NO"`, `hearingdate`×331/`deeddate`×153 on bare
  dates. Fix (uncommitted, builds green): `labeledValue` now requires a real
  `Label:` separator + `isPlausibleFieldValue` junk gate; `labeledDate`
  proximity-bounds dates; Medical/LegalCase/Property markers tightened.
  **Next: update StarterPackCoverage tests to the labeled-field shape,
  re-verify against live-shaped junk via RunCodeSnippet, commit.**

---

## Gate G0 — Grounded scope (Stage 0)
Status: ◐ — partial inventory exists (feature work is well known), but the
directive's **feature matrix** (`feature | entry | executor | storage | scope
| provenance | cancel | reopen/export | tests | release-availability |
remaining`) across all ~57 destinations is not written down as one artifact.
- T-G0.1 ✗ Build the feature/route matrix doc (all destinations, answer
  composers, fallback routes, cache paths, finalizers).
- T-G0.2 ✗ Format-coverage inventory by behavior (parsed/partial/preserved/
  unsupported/failed) — reuse `FileIndexStatus` (U-3.6) as the spine.
- T-G0.3 ✅ Reproducible baseline build/test commands (xcodebuild on
  `/tmp/dd-implement-all`; CI guards in `ci/guards`).

## Gate G1 — Trust: scope + provenance + verification (Stages 1, 2, 6.3)
Status: ◐ — T-G1.1/1.2/1.3 DONE (commits eeaa298, 60a2c68, e24319e); T-G1.4
metrics + T-G1.5 GoldWall in progress.
- T-G1.1 ✅ **Access-context threading (Stage 1)** — done (eeaa298): access
  threaded through story/tool composers; fail-closed under narrowed scope.
- T-G1.2 ✅ **Field provenance (Stage 2.1)** — done (60a2c68): sourceBlockIDs
  not subjectID; real citation snippets; provenance test.
- T-G1.3 ✅ **Question-is-not-proof + adversarial sweep (Stage 6.2)** — done
  (e24319e): sweep grounds on cited text only; adversarial tests for
  question-as-proof, wrong-date, subject-swap.
- T-G1.5 ✅ **GoldWall unanswerable (Stage 13)** — done: unanswerable rows
  MUST abstain (per-row groundedAnswerLegal flag); GoldWall green — the four
  pure-unanswerable rows genuinely abstain, only the grounded-legal row
  answers. Confirms the system already abstains; the test was too lenient.
- T-G1.3b ◐ **Composer-acceptance / adversarial suite (Stage 2.2 / AT-05,18)**
  — DONE for the tool sweep: question-as-proof (e24319e), wrong-date +
  subject-swap (e24319e), prompt-injection defang (2acfab4), negation-polarity
  (e7fa66e), currency/unit-polarity (424f933). Remaining: audit that
  chunk-fallback / story / structured / progressive paths pass the SAME
  policy-aware acceptance; quoted-allegation-as-fact case.
- T-G2.3b ✅ **Deletion cascade (Stage 11 / AT-17-adjacent)** — done (eae45ea):
  deleting a document removes every derived row + leaves no orphaned vectors,
  tested over real rig-produced rows.
- T-G1.4 ✗ **Evidence metrics (Stage 6.3)** measured separately: retrieval
  recall · source-identity correctness · claim support · unanswerable
  handling · conflict detection · scope violations. No single score.

## Gate G2 — Durability (Stages 3, 11)
Status: ◐ — T-G2.1 DONE (bffd409); migration-safety for v128 verified.
- T-G2.1 ✅ **Durable conversation reopening (Stage 3)** — done (bffd409):
  schema v128 conversation_turns.answer_ledger_id; turn↔durable-answer link;
  reconstructVerifiedAnswer restores citations/status/receipt on reopen;
  legacy turns honest-empty; round-trip tested.
- T-G2.2 ✗ Source opening shows exact passage/page/cell/message; handle
  missing/moved/revoked/deleted/old-version originals with tested fallback.
- T-G2.3 ◐ **Migrations + backup/restore (Stage 11)** — migration-safety for
  v128 VERIFIED (full MigrationMatrix green: 24 milestone versions 0→128
  migrate with row preservation, FK integrity, rollback, idempotent
  re-migration). Still to do: backup/restore to a clean profile; deletion
  cascade semantics audit.

## Gate G3 — Product flows (Stages 5, 6, 7)
Status: ◐ — engines exist; the three flagship workflows need end-to-end UI
lifecycle (start/cancel/review/correct/save/reopen/export).
- T-G3.1 ◐ Workflow A (precise Q&A) — Ask path exists; add explicit scope
  chooser, save-to-project-output, reopen-with-evidence, exact-vs-synthesis
  labeling. Acceptance §9-A.
- T-G3.2 ◐ Workflow B (chronology) — history engine exists; reconcile the
  deferred topic/folder/corpus subject (Stage 5); event-time vs doc-time,
  date precision, uncertainty; bounded causal links (U-3.2 done); export.
- T-G3.3 ◐ Workflow C (comparison brief) — DETERMINISTIC CORE done:
  ComparisonMatrix (f61c422, verdicts agree/disagree/differentUnit/
  singleSource/unattested + absent-evidence vs evidence-of-absence) and
  ComparisonBrief renderer (8dea284, sourced sections + register). Remaining:
  wire the matrix to real ledger field-values per source; the brief UI
  (select docs/fields, edit analyst assessment, export PDF/MD, reopen,
  recompute-to-new-revision).
- T-G3.4 ◐ **Navigation redesign (Stage 7)** — Home / Projects / Files /
  Outputs; Simple mode completes flagships with no persona/SOP knowledge;
  Advanced + command palette for specialists; keep Fast / Long-with-evidence;
  demo archive with clean reset. Dedupe recents/nav.
- T-G3.5 ◐ **Retained professional workflows (Stage 6)** — trace every job/
  method end-to-end; approval-required gates real; data-lab calc correctness;
  redaction actually removes content; receipts ≠ admissibility.

## Gate G4 — Reliability (Stages 4, 9, 10)
Status: ◐.
- T-G4.1 ◐ **Import/coverage lifecycle (Stage 4)** — per-source state,
  partial-omission disclosure, dup identity, safe archive expansion,
  transient-retry without dup facts, moved-file reauth, OCR-correction
  provenance (U-4 gave per-line conf/bbox). "not found" vs "not searchable".
- T-G4.2 🔎 **Background/perf/stability (Stage 9)** — BackgroundWorkGate
  window/idle/sleep/stop/restart; no dup workers; bounded concurrency;
  measured perf budgets on M4 + min env.
- T-G4.3 ◐ **Model/OS compat (Stage 10)** — no-provider/unavailable path,
  deterministic usable without AI (U-0 kept this), model stamps on artifacts.

## Gate G5 — Release candidate (Stages 12, 13, 14, 15)
Status: ◐ — RC docs/gates largely present (U-9 ledger).
- T-G5.1 ◐ Accessibility + visual completion (Stage 12); current screenshots.
- T-G5.2 ✗ **AT-01…AT-20 acceptance suite (Stage 13)** — the concrete
  release scenarios; real routing + persistence, not fixture-only.
- T-G5.3 ◐ Purchase/packaging (Stage 14) — StoreKit completeness if present;
  Release archive/signing/entitlements (owner-gated Apple actions).
- T-G5.4 ◐ Help/positioning/beta (Stage 15) — honest copy (no "zero
  hallucinations"/"police ready"); demo archive; usability protocol.

## §21 — Investigator edition (AFTER research gates)
Status: ✗ deferred by the directive itself — shared core + research edition
first; investigator = separate config/nav reusing the engine.

---

## Dependency order (execution sequence)
1. **Finish in-flight pack precision fix** (§0) — commit clean.
2. **G1 trust** (T-G1.1 access context → T-G1.2 provenance → T-G1.3 composer
   acceptance + adversarial tests → T-G1.5 GoldWall) — highest risk, gates
   everything.
3. **G0 matrix** (T-G0.1/0.2) — cheap, unlocks honest tracking.
4. **G2 durability** (reopening + migration/backup).
5. **G3 product flows** (workflows A/B/C + navigation).
6. **G4 reliability** (import lifecycle, background, perf, OS/model).
7. **G5 release candidate** (accessibility, AT-01..20, packaging, help).
8. Then the live end-check + HOLD-2 (owner) → merge.

## Standing constraints (unchanged)
On-device only / no network entitlement · scope enforced before model ·
evidence-status vocabulary reused not forked · originals authoritative ·
predicted-diff before behavior · never lower a gate to go green · owner-gated:
Apple signing/submit, StoreKit accounts, device validation, usability
participants, page/market claims.
