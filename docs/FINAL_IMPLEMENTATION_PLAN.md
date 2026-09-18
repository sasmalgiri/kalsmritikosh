# Final implementation plan — everything remaining, in order

Date 2026-09-18. This is the single, complete list of remaining work to finish the
product. Each item: **what · files · steps · test · done-when.** Ordered by
dependency and value. Nothing omitted. (Already-shipped work — topic ledger U1–U7,
answer gates W4, C1 routing, B6 grammar, B1 metrics, U6 polish, FM wiring — is not
repeated here.)

Invariants for every item: on-device only; scope before retrieval; facts are
derived (rebuildable, sources never deleted); AI advisory over deterministic code;
every claim cites a source or abstains; build green + regression green before commit.

---

## PHASE 1 — Retrieval quality (highest answer impact)

### R1 · Wire TemporalGrammar into retrieval
- files: `Brain/AEE/QueryMissionCompiler.swift` (or intent compilation), `Brain/LedgerTools.swift` (timelineSlice).
- steps: call `TemporalGrammar.parse(question, now:)`; when non-nil, set `intent.timeframe`/pass `from`/`to` into `timelineSlice` and filter retrieval events/chunks by the window.
- test: a dated question ("what happened in 2024") returns only in-window events (unit test over a fixture).
- done-when: temporal questions retrieve the right slice; GoldWall/AskTheLedger green.

### R2 · Cross-encoder rerank on the answer path
- files: `Retrieval/HybridRetriever.swift` (add optional `reranker: RerankerLadder?`), `App/AppState.swift` (construct ladder with `HeuristicKeywordTier` + `CoreMLCrossEncoderTier`, inject), `Brain/RerankerLadder.swift`.
- steps: after hybrid candidate assembly, if reranker present, `score(question, candidates:)` the top ~100 chunk texts, reorder by score, keep top-k for composition. Never drop below current recall; reorder only.
- test: `RetrievalEval` (B1) shows recall@k not lower + the drafted-claims passage ranks top on a fixture; identity when reranker nil.
- done-when: measured recall ≥ baseline on the gold set; regression green.

### R3 · Corrective re-retrieve on weak evidence
- files: `Brain/MasterBrain.swift`, `Brain/CorrectiveRetrievalPlanner.swift`, `Brain/AEE/MissionEvidenceAssessor.swift`.
- steps: after rerank, if top groundedness < floor (boilerplate/field-only), spend the 1-pass budget to re-retrieve with expanded terms, re-rank; if still weak → abstain.
- test: thin-evidence question re-retrieves once then abstains (not dumps).
- done-when: corrective pass fires on weak evidence; no infinite loop; regression green.

### R4 · HyDE query expansion (uses the reasoning model)
- files: new `Brain/HypotheticalQueryExpander.swift`, wired in `HybridRetriever` vector step.
- steps: gate on low first-pass groundedness; ask FM for a 1–2 sentence hypothetical answer; embed it (bundled BGE); RRF-fuse with the literal query vector; intent-preservation guard (drop if it loses all content terms). Hypothetical never shown/cited.
- test: pure fuse test with a stubbed reasoner; intent-guard rejects an empty rewrite.
- done-when: vocabulary-mismatch questions retrieve the right passage; B1 recall↑.

### R5 · Make ANN (HNSW/IVF) the live vector index
- files: `Storage/Vector/ANNIndexCoordinator.swift`, `IndexStrategySelector.swift`.
- steps: default to ANN above a size threshold with brute-force as correctness fallback; ensure index builds on ingest/drain.
- test: recall parity vs brute-force ≥ target on a fixture; latency recorded.
- done-when: ANN is the default path with parity proven.

### R6 · Contextual chunk prefixes at embed-time
- files: `Ingestion/Pipeline/ContextPrefixGenerator.swift`, release ingest policy in `App/ReleaseCapabilityProfile.swift`/`AppState`.
- steps: enable the deterministic prefix (doc title + section path) prepended before embedding; re-embed on next drain.
- test: heading-only chunks rank lower in B1 after prefixing.
- done-when: prefixes applied at ingest; B1 unaffected-or-better.

---

## PHASE 2 — Ledger synthesis (fills the remaining empty tables)

### L1 · Auto-build topics after ingest + entity-subject grouping
- files: `Ingestion/Pipeline/IngestCoordinator.swift` (post-drain hook), `App/AppState+LedgerMaintenance.swift`, new `Knowledge/Topics/TopicSubjectResolver.swift`.
- steps: after a drain quiesces, call `buildTopics()` for changed subjects; group facts by resolved canonical entity (alias-unified) instead of document title.
- test: resolver unit test (aliases → one subject); re-ingest → memory_objects > 0 automatically.
- done-when: topics rebuild on ingest, keyed by real subject; no manual button needed.

### L2 · Summaries + community summaries at ingest
- files: `Knowledge/Topics/CommunitySummarizer.swift`, `Core/Services/Summarizer.swift`, drain hook.
- steps: run the deterministic summarizer for changed communities/documents during the drain; persist to `summaries`/`community_summaries`.
- test: summaries table grows on ingest fixture.
- done-when: summaries populated at ingest.

### L3 · History chapters/items persisted at ingest
- files: `Knowledge/History/HistoryReconstructionEngine.swift`, drain hook, `Storage/Repositories/HistoryArtifactRepository.swift`.
- steps: reconstruct per-subject history during the drain; persist chapters+items.
- test: history_* > 0 after ingest; reopen a chronology.
- done-when: history built at ingest, reopenable.

### L4 · 5W+H event slot enrichment
- files: `Events/NarrativeSlotExtractor.swift` (extend), optional FM slot fill.
- steps: deterministic rules for WHO/WHERE/WHEN/WHY/HOW; when FM present, fill gaps under a fact-preserving guard.
- test: slot fill-rate > 0 on a fixture; guard rejects invented slot values.
- done-when: event slots populated.

### L5 · CausalDiscoverer link bounding
- files: the causal link generator (search `Knowledge/Causal/*` + generation site), `Core/Models/CausalLink.swift`.
- steps: per-event top-K cap + raised similarity/temporal threshold; disclose truncation.
- test: link count bounded on a fixture; unit test the cap.
- done-when: causal links no longer inflated.

### L6 · Document-class persisted labeling (C-9)
- files: schema migration (+1 version, update MigrationMatrix pin), loaders stamp `document_class`, `DomainFactExtractor` reads it.
- steps: classify at ingest, persist, gate packs by class.
- test: migration matrix green; extraction tests read class.
- done-when: document_class stored + used.

---

## PHASE 3 — Answer composition polish

### A1 · Actor answer composer (finish C1)
- files: `Brain/MasterBrain.swift` (route `.actor` → actor selector), reuse `PassageAnswerSelector`.
- steps: for `.actor`, select the passage naming the acting party (action verb + named actor) and compose "X did Y" grounded to it; else fall to the universal path.
- test: "who drafted the claims" composes the attorney passage (fixture, using the selector).
- done-when: actor questions get a named-actor answer.

### A2 · Progressive answer streaming
- files: `Brain/MasterBrain.swift` (`answerStream`), `Brain/AEE/ProgressiveAnswer*`, `UI/AskView.swift`.
- steps: wrap instant→synthesis→deep→verified phases in an AsyncStream; UI renders partials.
- test: stream yields ≥2 states; final state equals non-streamed result.
- done-when: answers render progressively.

### A3 · Topics feed all composers (extend U7)
- files: `Brain/ExpertCouncil.swift`, `Brain/ToolGroundedComposer.swift`.
- steps: pass the matched topic into the primary composers (not just the deterministic fallback) so the model composes over the topic first.
- test: with a topic present, the composed answer references it; regression green.
- done-when: topic-first holds across all answer routes.

---

## PHASE 4 — Ingestion lifecycle & reliability

### I1 · BoilerplateRegistry embed-skip wiring
- files: `Ingestion/Pipeline/ChunkAdmissionGate` + `BoilerplateRegistry`.
- steps: consult the registry on the embed path; skip known boilerplate.
- test: boilerplate chunk not embedded; B1 unaffected/improved.

### I2 · Fast/Quality ingest tiering (stages 2–7)
- files: `Ingestion/Pipeline/*` per `docs/INGEST_QUALITY_TIERING_PLAN.md`.
- steps: independent OCR/embedding/prefix policies per tier.
- test: tier selection unit tests; coverage unaffected.

### I3 · Import/coverage lifecycle
- files: `Ingestion/Pipeline/*`, `App/FileIndexStatus.swift`.
- steps: per-source states (queued/processing/searchable/partial/failed/excluded), partial-omission disclosure, dup identity, transient-retry-without-dup, moved-file reauth.
- test: state transitions + no-dup-on-retry tests.

### I4 · Model/pipeline stamps on derived artifacts
- files: schema (where supported), writers for facts/topics/answers.
- steps: stamp model/runtime/pipeline version; regeneration = new revision.
- test: stamp present on new rows.

---

## PHASE 5 — Output, migration, backup, export

### O1 · Migrations from populated legacy snapshots
- files: `Storage/Schema/*`, MigrationMatrix tests.
- steps: upgrade populated beta DBs; verify FK/provenance/lifecycle intact.
- test: migrate populated snapshot 0→latest, row preservation.

### O2 · Restore link-rewire end-to-end
- files: `App/BackupService.swift`.
- steps: after restore, rewire source/output links; verify openable.
- test: backup→restore→reopen an output round-trip.

### O3 · Export completeness
- files: existing exporters.
- steps: PDF + Markdown (briefs) + CSV (timelines/comparisons) with source register; no private absolute paths.
- test: export each type; reopen; path-leak guard.

---

## PHASE 6 — Gate-3 typed knowledge graph (large, sequential)

- G1 `FactType`/`FactSlot`/`BondRule` taxonomy (schema + registry).
- G2 OntologyValidator + FactTypeClassifier (rule-based typing + slot validation).
- G3 BondConstructor + slot extractors (cross-document typed relationships).
- G4 Walk planner + executor (intent-driven typed traversal returning typed paths).
- G5 Walk-path evidence + "why this answer" UI.
- Sequence G1→G5; each its own unit + tests. Start only after Phases 1–3 measure well.

---

## PHASE 7 — Later / scoped
- Z1 Multilingual semantic index (bge-m3, no translate-to-English).
- Z2 Story reviewer loop (approve/correct/reject beats → next reconstruction).
- Z3 Investigator edition (shared core + separate config/nav).
- Z4 Legacy Office/Mail formats (DOC/XLS/PPT/MSG/PST); on-device GGUF runtime (needs a project dependency = owner/Xcode).
- Z5 M4 + min-env performance budgets (measured on owner hardware).

---

## Execution order
Phase 1 (R1→R2→R3→R4→R5→R6) → Phase 2 (L1→L2→L3→L4→L5→L6) → Phase 3 (A1→A2→A3)
→ Phase 4 → Phase 5 → Phase 6 → Phase 7. Each item: implement → unit test → build →
regression (GoldWall + AskTheLedger) → commit. Owner runs the app to confirm the
measured items (R2/R4/R5, L1–L3) against B1 on the real archive.
