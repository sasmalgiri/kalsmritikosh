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
Status: ◐ — verification ladder strong (U-1 answer/evidence split, sweep,
abstention), but two **confirmed** structural gaps remain.
- T-G1.1 ✗ **Access-context threading (Stage 1).** Thread one explicit
  fail-closed `SensitiveAccessContext` through `composeStoryAnswer(question:)`
  and `composeToolGroundedAnswer(question:)` (AppState:3908/3979) and the
  `MasterBrain` story/tool fallback closures. Scope BEFORE retrieval
  limit/rank. No implicit global fallback. Cache keys include scope +
  evidence stamp + pipeline version. Acceptance cases 1–5 (§5).
- T-G1.2 ✗ **Field provenance (Stage 2.1).** `LedgerTools.lookupField`
  resolves source via `sourceBlockIDs` + canonical source/version/location,
  NOT `subjectID` (LedgerTools:97). Kill generic `"Ledger result"` /
  `"Story evidence"` citations (AppState:4041) — map to real passages.
  Constrain lookup by subject + scope + source version + fact status.
- T-G1.3 ◐ **One acceptance contract for every composer (Stage 2.2).**
  chunk-fallback, tool-grounded, story, deterministic, structured, progressive
  all pass the same policy-aware acceptance. U-1 covers tool-grounded; audit
  the others. Add adversarial tests: negation, subject swap, wrong date/tz,
  amount/currency/unit, quoted allegation, causal claim, conflicting accounts,
  question-as-proof, prompt-injection (file content ≠ instructions).
- T-G1.4 ✗ **Evidence metrics (Stage 6.3)** measured separately: retrieval
  recall · source-identity correctness · claim support · unanswerable
  handling · conflict detection · scope violations. No single score.
- T-G1.5 ◐ **GoldWall unanswerable branch (Stage 13)** — must require
  abstention, not accept a nonempty citation (overlaps U-8; finish).

## Gate G2 — Durability (Stages 3, 11)
Status: ◐.
- T-G2.1 ✗ **Durable conversation reopening (Stage 3).** Bind `AskView`
  turns to durable answer revisions (ConversationsRepository) so citations/
  status/receipt restore on reopen; honest legacy state for old turns; atomic
  writes. (U-1 built the two-section card; this adds the persistence link.)
- T-G2.2 ✗ Source opening shows exact passage/page/cell/message; handle
  missing/moved/revoked/deleted/old-version originals with tested fallback.
- T-G2.3 🔎 **Migrations + backup/restore (Stage 11)** — upgrade populated
  legacy schema; rollback after interrupted migration; backup/restore to a
  clean profile; deletion cascade semantics. (Schema-version guard exists.)

## Gate G3 — Product flows (Stages 5, 6, 7)
Status: ◐ — engines exist; the three flagship workflows need end-to-end UI
lifecycle (start/cancel/review/correct/save/reopen/export).
- T-G3.1 ◐ Workflow A (precise Q&A) — Ask path exists; add explicit scope
  chooser, save-to-project-output, reopen-with-evidence, exact-vs-synthesis
  labeling. Acceptance §9-A.
- T-G3.2 ◐ Workflow B (chronology) — history engine exists; reconcile the
  deferred topic/folder/corpus subject (Stage 5); event-time vs doc-time,
  date precision, uncertainty; bounded causal links (U-3.2 done); export.
- T-G3.3 ✗ Workflow C (comparison brief) — propositions×sources matrix →
  sourced brief; disagreement vs different-units; absent-evidence vs
  evidence-of-absence; export + reopen + recompute-to-new-revision.
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
