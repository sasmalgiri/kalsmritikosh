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

## LANE A — agent-completable now (ordered by answer-value)

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

### A2 · Import / coverage lifecycle (audit I3)
- **Why:** per-source state machine is partial (`FileIndexStatus` only).
- **Files:** `App/FileIndexStatus.swift`, `Ingestion/Pipeline/*`, readiness repo.
- **Steps:** per-source states (queued/processing/searchable/partial/failed/excluded),
  partial-omission disclosure, dup identity, transient-retry-without-dup, moved-file reauth.
- **Done-when:** state transitions + no-dup-on-retry tests; a moved file re-auths without a
  duplicate row.

### A3 · Plain-document workspace-subject claims  ✅ DONE (50dc822, module .proseSubjectBinding, default OFF)
- `ClaimProducer` now resolves a subject-less fact's subjectLabel to ONE canonical entity
  (injected resolver over `EntitiesRepository.find(byValue:)`+`resolveCanonical`; ambiguous →
  nil, never guessed) and scopes the claim `.entity`. Gated + default OFF (opt-in; no producer
  bump, no forced re-drain). Regression green (28/28). Owner flips it on to prefer subject
  scoping for prose archives.

### A4 · Password-protected files (encrypted PDF/ZIP/Office)
- **Why:** encrypted sources are skipped; niche but real.
- **Files:** loaders + a password-collection UI hook (never crack; user supplies the password).
- **Steps:** detect encryption → surface a "needs password" state → retry decode with the
  user-supplied secret → ingest through the same pipeline.
- **Done-when:** an encrypted fixture ingests after a password is provided; wrong/absent
  password fails closed (no crash, marked needs-password).

---

## LANE B — owner-gated (agent must NOT start without the owner's live step)

- **F7 redaction UI** — SAFETY-GATED on a blind-PII test the owner runs first (persona memory).
- **I2 fast/quality ingest tiering** — moot under the pinned single `ledgerEventDriven` mode;
  needs an owner decision to reintroduce tiers.
- **p5-rc HOLD 2 remainder** — witness the four rungs, lawyer pass, runbook, Apple submit.
  Owner-only by `release/HOLD2_SCRIPT.md`.

---

## LANE C — activation-gated (banked; do NOT open until the owner activates)

- **GO 2 / GO 3 banked directives** — open only at their checkpoints.
- **Any-Question Stack** (archive→shelf→GK lanes) — activation Go-3 first train.
- **Gate-3 typed knowledge graph** (FactType/BondRule/walk planner/"why this answer" UI) —
  Q4 2026–Q2 2027 roadmap.
- **Story reviewer loop** (approve/correct/reject beats) — ROADMAP_1_2.
- **Multilingual semantic index** (bge-m3, no translate) — v2.
- **Investigator edition** — deferred until research gates pass.

---

## Execution order (Lane A)
A1 (now) → A2 → A3 → A4. Each: implement → unit test → build → GoldWall+AskTheLedger green →
commit. Lane B/C untouched until the owner opens them. After Lane A: full-suite run as the
pre-witness gate, then the owner's live erase→re-ingest→ask pass.
