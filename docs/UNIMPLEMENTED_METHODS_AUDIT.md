# Discussed / planned / approved but NOT implemented — full pipeline audit

Date 2026-09-17. Method: 5 parallel doc↔code audits (2 completed; 3 hit the account
session limit and were complemented by direct code greps + the authored plans).
"Not wired" = code exists but nothing invokes it on the live path. "Gated off" =
code exists but a policy/flag disables it in the shipping (minimum-LLM) profile.
Excludes intentional stubs CLAUDE.md says to leave (MLX/LlamaCpp/Cloud providers,
legacy DOC/XLS/PPT/MSG/PST loaders, iOS shims, Whisper/audio).

## Stage 1 — INGESTION
- **BoilerplateRegistry embedding-skip (Stage 1b)** — deterministic boilerplate skip
  on the embed path. Planned INGEST_QUALITY_TIERING_PLAN §1/§7. Registry exists;
  NOT wired (only ChunkAdmissionGate blank/short/nav rules run).
- **Fast vs Quality ingest tiering (Stages 2–7)** — independent OCR / embedding /
  prefix policies per tier. Planned INGEST_QUALITY_TIERING_PLAN. Only Stage-1
  vector-admission landed; 2–7 not started.
- **Deterministic context-prefix on chunks** — prepend "what this chunk is about"
  at embed time (Anthropic-style contextual retrieval). ContextPrefixBackfiller
  exists but **gated off** (`contextPrefixBackfillEnabled=false` in
  ReleaseCapabilityProfile; policy `contextPrefixBackfill`).
- **Import/coverage lifecycle (T-G4.1)** — per-source state, partial-omission
  disclosure, dup identity, transient-retry-without-dup, moved-file reauth. Planned
  COMPLETION_DIRECTIVE_PLAN. Partial (FileIndexStatus only).

## Stage 2 — LEDGER / TOPICS / MEMORY / HISTORY  ← the core gap
- **Topic rollup / "upside-down tree" (facts→topic→subject)** — build real topics
  from leaves. TopicTreeBuilder + TermSalienceComputer run in the drain, but there
  is **no topic layer output** the answer path uses and **no topic-tree UI**. The
  intended rollup that turns 790 flat facts into ~dozens of topics is effectively
  absent end-to-end.
- **Memory distillation at ingest (MemoryDistiller)** — per-subject memory objects.
  Exists + wired, but **gated off** (`eagerMemoryDistillation=false`); and
  `synthesizeNarrative` is a **deterministic stub** ("no events directly mention X
  yet"), not the planned real synthesis. Result: `memory_objects = 0`.
- **Summaries / community summaries** — CommunitySummarizer exists but runs only as a
  background pass, not during ingest; `summaries = 0`, `community_summaries = 2`.
- **History chapters/items at ingest** — HistoryReconstructionEngine builds only at
  query time on demand; `history_chapters = 0`, `history_items = 0` in the ledger.
- **5W+H event slot enrichment (SlotEnricher)** — WHO/WHERE/WHY/HOW per event.
  Only a rule-based extractor exists; the planned LLM slot fill is absent; event
  slot columns largely empty.
- **C-10 merge corroboration (sourceCount + max-confidence)** — NOW LANDED as
  Topic-Ledger U1–U4 (naturalKey merge + dedup + junk gate). ✅
- **CausalDiscoverer link bounding** — per-event top-K cap + raised threshold;
  causal links are inflated. Planned V1.1 ADDENDA §A. Not committed.
- **Document-class persisted labeling (C-9)** — `document_class` column to tighten
  packs. Planned V1.1 ADDENDA §B. Not landed.

## Stage 3 — RETRIEVAL / EMBEDDINGS / RANKING
- **Cross-encoder reranker on the answer path** — RerankerLadder + CoreMLCrossEncoderTier
  EXIST but are **not invoked** by MasterBrain/HybridRetriever. This is the single
  biggest retrieval-quality gap (answer-quality plan W1).
- **ANN (HNSW/IVF) as the live index** — implemented + strategy-selectable, but the
  **brute-force scan is still the shipping baseline**; ANN not the default path.
- **HyDE / query rewriting / decomposition** — none present (answer-quality plan W3).
- **Corrective / adaptive re-retrieval** — CorrectiveRetrievalPlanner exists;
  **not wired** into the query loop (W2).
- **Temporal window grammar** — "between week N and M" / "over time" → timeframe.
  Planned GATE2_ROADMAP. Absent.

## Stage 4 — ANSWER / BRAIN / COMPOSERS
- **Composers read built topics first (U7)** — answer path still leads with raw
  fact/passage piles; the (empty) topic layer is not consulted. The deterministic
  path is a fact-dump, not a topic composer.
- **AI connective reconstruction (U6 / StoryProseRephraser under a fact-preserving
  guard)** — not implemented as specified.
- **Actor question shape ("who drafted/filed/signed X")** — QuestionShape.actor not
  distinguished from `role`. Planned answer-quality plan W5.
- **Progressive answer streaming** — instant→synthesis→deep→verified phases defined
  (ProgressiveAnswer types exist) but MasterBrain.answer still awaits the whole
  result; not streamed.
- **Reasoning-model-dependent synthesis** — silently no-ops when no model is present
  (the machine shows "No reasoning model available"), so answers fall to the
  deterministic dump. No deterministic topic composer to catch this.

## Stage 5 — OUTPUT / RELIABILITY / ROADMAP (larger, later)
- **Gate-3 typed knowledge graph** — FactType/FactSlot/BondRule taxonomy, OntologyValidator,
  BondConstructor, typed walk planner+executor, "why this answer" walk-path UI.
  Planned G3_PERIODIC_TABLE_ROADMAP (Q4 2026–Q2 2027). Not started.
- **Story reviewer loop** — approve/correct/reject beats feeding the next
  reconstruction. Planned ROADMAP_1_2. Absent.
- **Multilingual semantic index** (bge-m3, no translate-to-English) — v2. Absent.
- **Background/perf budgets on M4 + min env (T-G4.2)** — not formalized/measured.
- **Investigator edition** (§21) — deliberately deferred until research gates pass.

## The through-line
Deterministic **leaf extraction** runs; almost every **synthesis / rollup / rerank**
stage is either not-wired, gated-off in minimum-LLM, or a stub that needs a reasoning
model. That is why the DB is flat facts with no topics, and answers dump instead of
compose. The highest-leverage, model-independent fixes: **Topic rollup spine (U5)**,
**cross-encoder rerank on the answer path (W1)**, **composers read topics first (U7)**.
