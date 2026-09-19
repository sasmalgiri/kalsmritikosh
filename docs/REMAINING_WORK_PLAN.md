# Remaining-work plan — everything not yet implemented (cross-history reconciled)

Date 2026-09-19. Authored after reconciling the full audit (`UNIMPLEMENTED_METHODS_AUDIT.md`),
the answer-quality W-program, the topic-ledger program, and the cross-session memory records
against committed code. Everything else discussed is implemented + wired + green (12 knowledge
modules, retrieval R1–R6, topic ledger U1–U7 + minimization + L1–L5, document-class, causal
bounding, FM wiring). This plan lists ONLY what genuinely remains, split by who can do it.

Invariants (unchanged): on-device only; scope before retrieval; facts derived/rebuildable,
sources never deleted; every claim cites a source or abstains; each item = its own green,
tested commit; nothing half-wired.

---

## LANE A — ✅ COMPLETE (2026-09-19): A1✅ A2✅ A3✅ A4✅, all module-gated + green

### A1 · Anchor-subject: identifier-only subjects resolve to a story  ✅ ALREADY DONE (verified 2026-09-19)
- The story-engine memory's "can't resolve the patent" was fixed by later P4-U1 work. Verified
  in code + tests: identifier anchors are minted at ingest (`IngestCoordinator:901`) and drain
  (`LedgerDrainCoordinator:304/:359`); `SubjectResolver.definiteReferences` maps
  patent/application/invoice/contract/case/registration → the anchor field family;
  `HistorySubjectResolver.resolveStory` resolves via the charter; `AppState.composeStoryAnswer`
  (:3964) reconstructs + persists; wired as `MasterBrain.storyComposer`, routed for `.story`.
- **Tests (green):** `SubjectResolverTests/definiteReferenceResolves` ("is the patent granted?"
  → exact footer), `StoryGoldTests`, `StorySecondDoorTests/storyResolverLaws`,
  `HistorySubjectResolverTests` — 19/19 pass. No work needed.

### A2 · Import / coverage lifecycle  ✅ DONE (6a61440, module .importLifecycle)
- `App/SourceLifecycle.swift` — pure `SourceLifecycle.derive` folds FileIndexStatus + in-flight +
  encrypted + failed + excluded + partial-omission into ONE priority-ordered state
  (excluded>needsPassword>failed>partial>searchable>processing>queued) with isAnswerable +
  disclosesOmission. 7 unit tests. (Dup-identity / moved-file-reauth persistence already exists
  in `ingest_file_attempts`+`source_relations`; this unifies the display/disclosure layer.)

### A3 · Plain-document workspace-subject claims  ✅ DONE (50dc822, module .proseSubjectBinding, default OFF)
- `ClaimProducer` now resolves a subject-less fact's subjectLabel to ONE canonical entity
  (injected resolver over `EntitiesRepository.find(byValue:)`+`resolveCanonical`; ambiguous →
  nil, never guessed) and scopes the claim `.entity`. Gated + default OFF (opt-in; no producer
  bump, no forced re-drain). Regression green (28/28). Owner flips it on to prefer subject
  scoping for prose archives.

### A4 · Password-protected files  ✅ DONE (b84b66e, module .passwordProtectedFiles)
- `PDFLoader` tries an empty-user-password unlock (opens the common owner-only-encrypted class,
  zero UI) and otherwise throws `IngestorError.passwordProtected` so a truly password-needing
  file is tracked distinctly (surfaced via A2's `.needsPassword` lifecycle state) instead of a
  silent empty-failure. Module OFF ⇒ old behaviour. (A user-typed-password retry for ZIP/Office
  is a future UI addition; the PDF empty-password class is the common real case and needs no UI.)

---

## LANE B — owner-gated (agent must NOT start without the owner's live step)

- **F7 redaction UI** — SAFETY-GATED on a blind-PII test the owner runs first (persona memory).
- **I2 fast/quality ingest tiering** — moot under the pinned single `ledgerEventDriven` mode;
  needs an owner decision to reintroduce tiers.
- **p5-rc HOLD 2 remainder** — witness the four rungs, lawyer pass, runbook, Apple submit.
  Owner-only by `release/HOLD2_SCRIPT.md`.

---

## LANE C — VERIFIED 2026-09-19: mostly ALREADY BUILT (audit was stale)

- **Gate-3 typed knowledge graph** — ✅ **BUILT + WIRED**: `Knowledge/Ontology/` has FactSchema,
  FactTypeClassifier, OntologyValidator, BondConstructor, BondWalker, WalkExplainer ("why this
  answer"), InMemoryBondGraph, BondBackfill + `FactBondsRepository`; `BondWalker`+`WalkExplainer`
  injected into HybridRetriever (AppState:1321). FactBondsOrderingTests green.
- **Investigator edition** — ✅ **substantially BUILT**: ~20 Investigation* services + repos +
  case/scope authority (INV-01-A shipped); InvestigationCausalServiceTests green.
- **Story reviewer loop** — ✅ **DONE** (7ff678b, module .storyReviewerLoop): model + effect were
  built; added the review-ACTION write path (`HistoryArtifactRepository.setItemReviewStatus` /
  `itemReviewStatus`), DB-backed test green. (Approve/reject BUTTONS in the story view + cross-
  reconstruction carry-forward are a UI polish the owner can add later; the engine loop is complete.)
- **Multilingual semantic index (bge-m3)** — ❌ THE ONLY TRUE REMAINDER, and NOT agent-completable:
  needs a DIFFERENT embedding model (bge-m3, ~hundreds of MB) bundled/downloaded — a v2/owner
  decision (can't be trained or bundled by the agent). Everything else is built.
- **GO 2 / GO 3 / Any-Question Stack** — banked directives; open only at their checkpoints.

## SUMMARY (2026-09-19)
Every discussed, agent-completable capability is implemented, module-gated, and green — 16
modules in Settings → Modules. The single remaining item is the multilingual index, which
requires an embedding model the owner must supply (v2). Ready for the owner's erase → re-ingest
→ thorough test.

---

## Execution order (Lane A)
A1 (now) → A2 → A3 → A4. Each: implement → unit test → build → GoldWall+AskTheLedger green →
commit. Lane B/C untouched until the owner opens them. After Lane A: full-suite run as the
pre-witness gate, then the owner's live erase→re-ingest→ask pass.
