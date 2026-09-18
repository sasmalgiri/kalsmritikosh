# Master implementation plan — every unimplemented method

Date 2026-09-18. Source: `docs/UNIMPLEMENTED_METHODS_AUDIT.md` (the pipeline audit).
This is the single ordered plan to close every discussed/planned/approved-but-absent
method. Each item: **Goal · Files · Approach · Verify · Depends · Gate.**

Gate legend: 🟢 model-independent + unit-testable (agent can fully do) · 🟡 needs the
running app / re-ingest to verify (agent builds, owner confirms) · 🔴 needs an on-device
reasoning model (no-ops until one is present) · ⚫ large multi-phase / roadmap.

Standing invariants (every item): on-device only, no network; scope before retrieval;
facts are derived (dedup/rebuild OK, sources never deleted); AI advisory over
deterministic code; every surfaced line cites a source or abstains; never lower a gate
to go green; predicted diff before behavior.

Already landed this program (context): U1–U7 topic-ledger (naturalKey merge, mergeUpsert
on ingest+drain, dedupExisting + "Tidy up", junk gate, TopicSpineBuilder + "Build
topics", topic-first fallback, fact-preserving prose polisher) and answer-path W4
(relevance-gate + abstention in the three composers). Those are excluded below.

---

## PHASE A — Ledger/topics: finish the rollup so topics are real & automatic
Goal: the "upside-down tree" builds itself on ingest and drives every answer.

- **A1 · Auto-build topics after ingest/cleanup** 🟡
  Goal: topics build without the owner pressing "Build topics".
  Files: `Ingestion/Pipeline/LedgerDrainCoordinator.swift`, `App/AppState+LedgerMaintenance.swift`.
  Approach: after a drain/ingest quiesces, call `buildTopics()` for changed subjects only
  (incremental); guard behind a "topics dirty" set. Verify: re-ingest → memory_objects > 0
  automatically. Depends: U5. Gate: 🟡 (needs re-ingest to confirm).

- **A2 · Subject identity = entity, not document title** 🟡
  Goal: a topic groups by the real-world subject (canonical entity), not the file title,
  so one "Patent 202331019665" topic gathers facts from many documents.
  Files: `Knowledge/Topics/TopicSpineBuilder.swift` (input grouping), a new
  `TopicSubjectResolver` mapping facts→canonical entity via `entity_mentions`.
  Approach: group facts by resolved `subjectID` (entity) with alias unification; fall back
  to subjectLabel when unresolved. Verify: fewer, richer topics; unit test the resolver.
  Depends: A1. Gate: 🟡.

- **A3 · 5W+H event slot enrichment (deterministic)** 🟢→🔴
  Goal: WHO/WHERE/WHEN/WHY/HOW per event populate the slot columns.
  Files: `Events/NarrativeSlotExtractor.swift` (extend rule-based), schema slot columns.
  Approach: deterministic rules first (dates→WHEN, cited parties→WHO, doc→WHERE); optional
  model fill later. Verify: event slot fill-rate metric > 0; unit tests on fixtures.
  Gate: 🟢 for rules; 🔴 for the LLM slot fill.

- **A4 · Community summaries at ingest** 🟡
  Goal: `community_summaries` populated during/after ingest, not only a daily bg pass.
  Files: `Knowledge/Topics/CommunitySummarizer.swift`, drain trigger in AppState.
  Approach: run the deterministic community summarizer in the drain for changed
  communities. Verify: community_summaries grows on ingest. Depends: A1. Gate: 🟡.

- **A5 · History chapters/items persisted at ingest** 🟡
  Goal: `history_chapters`/`history_items` built during ingest, not only on query.
  Files: `Knowledge/History/HistoryReconstructionEngine.swift`, drain trigger.
  Approach: reconstruct per-subject history in the drain; persist. Verify: history_* > 0
  after ingest; reopen a chronology. Depends: A1/A2. Gate: 🟡.

- **A6 · CausalDiscoverer link bounding** 🟢
  Goal: stop the causal-link explosion (inflated CONTRIBUTED_TO).
  Files: the causal discoverer + `Core/Models/CausalLink.swift`.
  Approach: per-event top-K cap + raised similarity/temporal threshold; disclose truncation.
  Verify: link count bounded on a fixture; unit test the cap. Gate: 🟢.

- **A7 · Document-class persisted labeling (C-9)** 🟢
  Goal: `document_class` column so packs tighten by class.
  Files: schema migration (+1 version), loaders stamp class, `DomainFactExtractor` reads it.
  Approach: classify at ingest (already have DocumentClass), persist, gate packs. Verify:
  migration matrix + extraction tests. Gate: 🟢.

---

## PHASE B — Retrieval quality (the biggest answer lever)
Goal: surface the right passage; measure before/after so nothing regresses.

- **B1 · W6 evidence-metrics harness (DO THIS FIRST)** 🟢
  Goal: measure retrieval recall@k, source-identity, groundedness, unanswerable-handling,
  conflict-detection, scope-violations separately over a small gold set.
  Files: new `KalsmritikoshTests/AnswerQualityEvalTests.swift` + a gold fixture (synthetic +
  de-identified real-shaped, incl. the diagnostic questions). Approach: deterministic eval,
  emit a report, wire a CI floor. Verify: baseline numbers recorded. Gate: 🟢. **Blocks B2–B4.**

- **B2 · Cross-encoder rerank on the answer path (W1)** 🟡
  Goal: rerank top-~100 hybrid candidates with `CoreMLCrossEncoderTier` before composition;
  field-facts + boilerplate compete, don't bypass.
  Files: `Retrieval/HybridRetriever.swift` (inject `RerankerLadder`, rerank before
  `RetrievalResult`), `App/AppState.swift` (construct + inject), `Brain/RerankerLadder.swift`.
  Approach: ladder with heuristic tier as always-safe fallback; cap + fast-path floor for
  latency. Verify: B1 shows recall↑ with no groundedness↓; the "drafted claims" passage
  ranks top. Depends: B1. Gate: 🟡 (measured).

- **B3 · Corrective re-retrieve on weak evidence (W2)** 🟡
  Goal: when top reranked evidence is generic/boilerplate, spend 1 corrective pass, then
  abstain if still weak.
  Files: `Brain/MasterBrain.swift`, `Brain/CorrectiveRetrievalPlanner.swift`,
  `Brain/AEE/MissionEvidenceAssessor.swift`. Verify: thin-evidence question re-retrieves
  or abstains (not dumps). Depends: B2. Gate: 🟡.

- **B4 · HyDE query expansion (W3)** 🔴
  Goal: bridge vocabulary mismatch ("drafted" ↔ "prepared a draft") via a hypothetical-
  answer embedding fused (RRF) with the literal query. Gated on low first-pass groundedness;
  intent-preservation guard; hypothetical never shown/cited.
  Files: new `Brain/HypotheticalQueryExpander.swift` (injected FM + embedder), wired in
  retrieval. Verify: mismatch questions retrieve the right passage. Depends: B1,B2. Gate: 🔴
  (needs a reasoning model; test the pure fuse with a stub).

- **B5 · ANN (HNSW/IVF) as the live index** 🟡
  Goal: make the built ANN index the default vector path (currently brute-force baseline).
  Files: `Storage/Vector/ANNIndexCoordinator.swift`, `IndexStrategySelector.swift`.
  Approach: flip default to ANN with the brute-force scan as correctness fallback above a
  size threshold; recall parity test vs brute-force. Verify: recall parity ≥ target on a
  fixture. Gate: 🟡 (perf/recall measured).

- **B6 · Temporal window grammar** 🟢
  Goal: parse "between week N and M", "over time" → `intent.timeframe`.
  Files: new `Brain/TemporalGrammar.swift`, wired in intent compilation. Verify: unit tests
  mapping phrases → windows; T1/T3 recall↑ in B1. Gate: 🟢.

- **B7 · Contextual chunk prefixes (embed-time)** 🟡
  Goal: prepend a deterministic "what this chunk is about" (doc title + section) before
  embedding, so heading-only chunks stop winning.
  Files: `Ingestion/Pipeline/ContextPrefixGenerator.swift` (deterministic path), enable in
  the release ingest policy. Verify: boilerplate-heading chunks rank lower in B1. Gate: 🟡
  (re-embed needed).

---

## PHASE C — Answer composition & shapes
- **C1 · `.actor` question shape (W5)** 🟢
  Goal: "who drafted/prepared/filed/signed X" routes to an actor selector requiring a
  passage with the action verb + a named party; else the improved universal path.
  Files: `Brain/QuestionShapeRouter.swift` (+ twin), a small actor selector, composer hook.
  Verify: router classification tests for a dozen phrasings + twin agreement. Gate: 🟢.

- **C2 · Progressive answer streaming** 🟡
  Goal: instant cache → synthesis → deep → verified phases yield incrementally.
  Files: `Brain/AEE/ProgressiveAnswer*` (types exist), `Brain/MasterBrain.swift`
  (`answerStream`), `UI/AskView.swift`. Approach: wrap the existing phases in an AsyncStream;
  UI renders partials. Verify: UI shows progressive states; no final-state regression. Gate: 🟡.

- **C3 · U6 → live buildTopics polish** 🔴
  Goal: when a reasoning model is present, `buildTopics()` runs each spine through
  `TopicProsePolisher`. Files: `App/AppState+LedgerMaintenance.swift`, capabilities wiring.
  Verify: with a model, topics read as prose but pass the fact guard; without, unchanged.
  Depends: U6 (done). Gate: 🔴.

---

## PHASE D — Ingestion lifecycle & reliability (Stage 4 / G4)
- **D1 · BoilerplateRegistry embed-skip wiring** 🟡 — deterministic boilerplate skip on the
  embed path. Files: `Ingestion/.../ChunkAdmissionGate` + BoilerplateRegistry. Verify:
  boilerplate not embedded; B1 unaffected/improved.
- **D2 · Import/coverage lifecycle (T-G4.1)** 🟡 — per-source state (queued/processing/
  searchable/partial/failed/excluded), partial-omission disclosure, dup identity, transient-
  retry-without-dup, moved-file reauth. Files: `Ingestion/Pipeline/*`, `App/FileIndexStatus.swift`.
- **D3 · Background/perf budgets (T-G4.2)** 🔴-owner — BackgroundWorkGate window/idle/sleep/
  restart, bounded concurrency, measured budgets on M4 + min env. Gate: needs owner devices.
- **D4 · Model/OS compat stamps (T-G4.3)** 🟢 — model/runtime/pipeline stamps on derived
  artifacts; regeneration = new revision.

---

## PHASE E — Output, export, migration, backup (Stage 8/11)
- **E1 · Migrations from populated legacy snapshots** 🟡 — upgrade populated beta DBs; FK/
  provenance/lifecycle intact. Files: `Storage/Schema/*`, MigrationMatrix.
- **E2 · Restore-into-clean-profile end-to-end** 🟡 — extend BackupService restore to rewire
  source/output links after restore (round-trip already tested at file level).
- **E3 · Export completeness** 🟡 — PDF + editable (MD briefs, CSV timelines/comparisons)
  with source register; no private absolute paths. Files: existing exporters.

---

## PHASE F — Gate-3 typed knowledge graph  ⚫ (roadmap, quarters)
Goal: the periodic-table schema — types, bonds, typed retrieval, explainable walks.
- **F1** FactType/FactSlot/BondRule taxonomy (schema + registry).
- **F2** OntologyValidator + FactTypeClassifier (rule-based typing + slot validation).
- **F3** BondConstructor + slot extractors (cross-document typed relationships).
- **F4** Walk planner + executor (intent-driven typed traversal).
- **F5** Walk-path evidence + "why this answer" UI.
Gate: ⚫ each is its own multi-week phase; sequence F1→F5. Do NOT start before Phases A–C
land and measure well.

## PHASE G — Later / owner-scoped ⚫
- **G1** Multilingual semantic index (bge-m3, no translate-to-English) — v2.
- **G2** Story reviewer loop (approve/correct/reject beats → next reconstruction).
- **G3** Investigator edition (shared core + separate config/nav) — after research gates.
- **G4** Legacy Office/Mail formats, on-device GGUF reasoning runtime — owner-scoped.

---

## Recommended execution order (dependency-correct)
1. **B1 metrics harness** (gates all retrieval work).
2. **Phase A** (A1→A2→A4→A5 topic automation; A6/A7/A3 hygiene) — makes the DB self-build topics.
3. **B2 rerank → B3 corrective → B6 temporal → B7 prefixes → B5 ANN** (measured each step vs B1).
4. **C1 actor shape, C2 progressive, C3 model polish** (C3 when a model exists).
5. **Phase D/E reliability + export.**
6. **Phase F Gate-3 graph** (only after A–C prove out).
7. **Phase G** owner-scoped.

## What blocks the biggest win right now
Two things outside code: (a) **no reasoning model** on the machine (B4/C3 and rich synthesis
stay dormant until Local GGUF/Apple-FM is enabled); (b) **measurement** — B1 must exist before
B2–B7 so quality changes are proven, not guessed. Everything 🟢 can proceed immediately;
🟡 needs an owner re-ingest/observe; 🔴 needs the model; ⚫ is scheduled roadmap.
