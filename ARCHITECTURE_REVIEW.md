> **DOC STATUS: PARTIALLY SUPERSEDED** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Directional; verify specifics against current code. _(bannered 2026-07-22, GOV-002.)_

# Kalsmritikosh — Architecture Review Packet

Compiled in response to the "everything must be AI-enriched before the
user can benefit" architectural critique. Read Part 1 first — it directly
engages the concern with evidence from the actual code.

---

## Part 1 — Direct response to the critique

**Your framing:**
> The architecture appears to assume: "Everything must be AI-enriched
> before the user can benefit."

**What the code actually does:** *partially right, partially wrong.*

### Where you are RIGHT

1. **The top of the retrieval priority is Memory, which IS gated on the
   LLM.**
   `HybridRetriever` iterates layers in this fixed order (from
   `Retrieval/HybridRetriever.swift:771`):
   ```
   memory → timeline → entity → metadata(FTS) → summary → graph → vector
   ```
   The `memory_objects` table is populated by MemoryDistiller, which is
   the biggest LLM sink in the whole pipeline. If distiller has not run
   for a subject, the retriever's *first-priority layer* is empty for
   that subject and the answer quality falls back to the lower layers.

2. **Context prefixes are dropped on timeout and only recovered later
   by a backfiller.**
   `ContextPrefixGenerator` retries 3 times (8s → 16s → 32s) and if
   Ollama is saturated the chunk is written **without** a prefix. Prefix
   presence boosts semantic retrieval quality. The backfill is
   eventually consistent, not immediately consistent.

3. **The declared "Tier 0 → Tier 1 → Tier 2 → Tier 3 enrichment ladder"
   in `CLAUDE.md` is aspirational, not fully implemented.**
   - Tier 0 (parse) ✓ implemented
   - Tier 1 (structure — entities, events) ✓ implemented, inline
   - Tier 2 (deepen — vectors + LLM extraction) ⚠ partial, mixed with T1
   - Tier 3 (deep study on demand) ✗ not implemented

4. **The user has no "% queryable" indicator.** `LiveMetrics.Sample`
   knows `chunkCount` vs `vectorCount`, but no UI translates that into
   "you can already ask questions about X% of your archive." That's a
   UX gap that reinforces the perception you flagged.

5. **The embedder is not what a knowledge system of this ambition
   should ship.** Reading `Storage/Vector/Embedder.swift`:
   ```swift
   public struct NLEmbedder: Embedder {
       public let dimension: Int  // From NLEmbedding model
   }
   ```
   This is Apple's `NLEmbedding.sentenceEmbedding` — an on-device model
   that ships with iOS/macOS. Dimension is ~300. It works, but it's
   significantly weaker than BGE-M3 (1024-dim, dense multilingual). The
   `BGETokenizer` in the codebase is ONLY wired to the reranker, not
   the embedder. That means top-of-funnel semantic search quality is
   capped at NLEmbedding's ceiling regardless of everything downstream.

### Where you are WRONG

1. **FTS is available IMMEDIATELY.** From `SchemaMigrations.swift`
   v14, a trigger fires on every chunk insert:
   ```swift
   CREATE TRIGGER IF NOT EXISTS chunks_fts_ai AFTER INSERT ON chunks BEGIN
       INSERT INTO chunks_fts(rowid, text) VALUES (new.rowid, new.text);
   END;
   ```
   And `ChunksRepository.searchFTS(...)`:
   ```swift
   SELECT c.id, c.object_id, c.ordinal, c.text, ...
   FROM chunks c
   JOIN chunks_fts ON chunks_fts.rowid = c.rowid
   WHERE chunks_fts.text MATCH ?
   ORDER BY rank LIMIT ?;
   ```
   **No filter on `context_prefix IS NOT NULL`.** As soon as
   `chunks.insertBatch(chunked)` returns, that chunk's text is
   BM25-searchable. Zero LLM dependency for keyword search.

2. **Entity search is available IMMEDIATELY.** Entities are extracted
   by NLTagger + rules (no LLM) inline during ingest. The `entity_trie`
   in-memory index and the `entities` table are populated at ingest,
   not at enrichment time. "Who is Alice?" works from minute one.

3. **The IngestCoordinator ships each stage's output IMMEDIATELY.**
   Chunks land in the DB BEFORE the context prefix arrives — the
   `ContextPrefixGenerator` populates a field on the in-memory `Chunk`
   struct, and if it fails, the chunk is still written with a NULL
   prefix. Downstream stages (entity extraction, embedding) do NOT
   block on prefix arrival either — they run in sequence but each
   commits its output to the DB before the next runs.

4. **Retrieval never short-circuits and never drops candidates.**
   `HybridRetriever` collects results from ALL layers and returns the
   union. If MEMORY is empty, TIMELINE fills in. If both are empty,
   FTS + ENTITY fill in. This is exactly the progressive-availability
   design you're advocating for — it just isn't advertised in the UI.

### The precise architectural gap

The pipeline **is** designed for progressive availability. What it
lacks is:

**(a) A user-facing "you can query now" signal.**
The `LiveDashboardView` shows counts but no meaningful "readiness"
score. Users don't know that FTS + entity lookups already work; they
only see the LLM churning and assume nothing is queryable.

**(b) A weight-adjusted retrieval ranking when Memory is empty.**
Right now Memory is priority 1. If Memory has 0 rows for a subject,
the retriever silently proceeds — but the composite ranking still
implicitly assumes Memory would have contributed. When Memory is
empty across the whole archive (early state), retrieval falls back to
FTS+Vector without adjusting the confidence baseline.

**(c) A better base embedder.**
Every chunk gets embedded with NLEmbedding (~300 dim). This caps
retrieval quality. Even if you swap `llama3` for `gpt-4o-mini`, you're
still retrieving from a weak vector space. **This is the highest-leverage
technical change I'd recommend.**

**(d) Chunk overlap is 0.** From `Chunker.swift`:
```swift
public let targetCharacterCount: Int       // Default: 1200
public let minChunkCharacterCount: Int    // Default: 80
```
No overlap parameter. Standard RAG practice is 10-20% overlap so
sentences that straddle chunk boundaries aren't split across
un-related vectors. This costs retrieval quality on questions whose
answer straddles a boundary.

---

## Part 2 — Assessment scorecard

| Dimension | Score | Notes |
|---|---|---|
| Schema design | 9/10 | 27 migrations, savepoints, FTS triggers fixed in v14, quality_tier / provenance / SCD2 versioning all present. Real work. |
| Concurrency model | 8/10 | Single Database actor + LaneScheduler is clean. Missing: no priority deferral when user is querying. |
| Ingestion pipeline | 7/10 | Correct order + ships early. Missing: chunk overlap, and NLEmbedding is a weak base. |
| Retrieval pipeline | 8/10 | Multi-layer union, FTS never gates on prefix, memory-cache warm path. Missing: layer-weight adaptation when top layer is empty. |
| LLM strategy | 5/10 | The LLM is on the critical path of prefix generation AND memory distillation. Both should be optional-boost, not path-blocking. |
| UX around long ingest | 3/10 | No "% queryable" signal. Users perceive "8 hours before I can use it" when in fact FTS + entity search work in minutes. |
| Scalability to 100 TB | 4/10 | Current model is per-chunk LLM call. That scales linearly with chunk count. 100 TB → ~50 million chunks → billion LLM calls at $0.005 each = $5M just for enrichment. Not viable. |
| Overall implementation quality | 8/10 | The bones are excellent; the LLM strategy needs a rethink for scale. Your 8.5-9 is fair. |

Where I disagree with your "10/10 with redesign" claim: **the base
embedder needs to be swapped before the redesign is worth doing.**
Fixing the LLM path without fixing the embedder is optimizing the wrong
layer.

---

## Part 3 — The 15 items you asked for

### 1. Repository structure

```
Kalsmritikosh/
├── App/                    (11 files) — AppState, health/inventory/metrics, feature flags, smoke test
├── Brain/                  (16 files) — MasterBrain, retriever, rerankers, evidence, investigation
├── Core/                   — Concurrency, Logging, Models, Security, Services (protocols)
├── EvalKit/                (7 files)  — Eval runners incl. new ReleaseReadiness.swift
├── Experts/                (7 experts + Shared/PromptTemplates.swift)
├── Ingestion/
│   ├── Archives/           (ZIP, PST, NSF, OLE2 readers)
│   ├── ASR/                (Whisper transcribers)
│   ├── Classification/
│   ├── Cleaning/
│   ├── Loaders/            (19 loaders — PDF, DOCX, XLSX, EML, mbox, iMessage, browser, chat…)
│   ├── OCR/                (Vision, Mistral)
│   └── Pipeline/           (Chunker, IngestCoordinator, ContextPrefixGenerator, FolderWatcher, IncrementalUpdater)
├── Knowledge/
│   ├── Causal/             (CausalDiscoverer, ContradictionFinder, CounterfactualSimulator)
│   ├── Memory/             (MemoryDistiller, MemoryHashCache)
│   ├── Ontology/           (OntologyBackfill, BondConstructor, BondBackfill)
│   ├── SyntheticQuestions/
│   ├── Summaries/          (CompressionScheduler)
│   ├── Topics/             (CooccurrenceGraphBuilder, community detection)
│   └── Backfill/           (ContextPrefixBackfiller)
├── Retrieval/              (HybridRetriever, layer-specific queriers)
├── Routing/                (DeterministicRouter, PrivacyGate, CapabilityRegistry, providers)
├── Storage/
│   ├── Database/           (DatabaseStack.swift — actor Database)
│   ├── Repositories/       (Files, KO, Chunks, Entities, Events, Relationships, Vectors, Memory, Bonds…)
│   ├── Schema/             (SchemaMigrations.swift — 27 versioned migrations)
│   └── Vector/             (Embedder.swift = NLEmbedder + SQLiteVectorStore)
└── UI/                     (SettingsView, AskView, TimelineView, LiveDashboard, OnboardingView, etc.)

KalsmritikoshTests/         (7 pure-logic test files)
Resources/Fixtures/ProjectDelta/  (8 evaluation fixtures)
```

### 2. Complete folder tree
Full tree via `Xcode Glob "**/*.swift"` — 250+ Swift files, grouped as
above. See attached `PROJECT_STRUCTURE.txt` at repo root if you want a
raw dump, or run:
```bash
find Kalsmritikosh -name '*.swift' | sort > project_structure.txt
```

### 3. SQLite schema
**File:** `Kalsmritikosh/Storage/Schema/SchemaMigrations.swift`
(latestVersion = 27, ~1500 lines).

**Table inventory:**

| Table | PK | Row-count-critical | FTS trigger |
|---|---|---|---|
| files | id | ✓ | — |
| knowledge_objects | id | ✓ | ✓ (v14) |
| chunks | id | ✓ | ✓ (v14) — `chunks_fts_ai/au/ad` triggers |
| chunks_fts | rowid | — | (target) |
| entities | id | ✓ | — |
| entity_mentions | id | ✓ | — |
| entity_aliases | (entity_id, alias_normalized) | ✓ | — |
| events | id | ✓ | — |
| vectors | chunk_id | ✓ | int8 quantized (v5) |
| memory_objects | id | ✓ | — |
| memory_changes | id | append-only | — |
| synthetic_questions | id | ✓ | ✓ (v9) |
| qa_pairs | id | ✓ | ✓ (v10) |
| fact_bonds | id | ✓ | — |
| entity_cooccurrences | (a, b) | derived | — |
| event_links | id | ✓ | causal graph (v23) |
| event_links_hypothetical | id | ✓ | counterfactuals (v23) |
| event_versions | id | audit | SCD2 + PROV-O (v24) |
| investigations + investigation_steps | id | ✓ | (v25) |

**Critical fix in v14:** the FTS triggers. Before v14, `chunks_fts` was
created but had no sync triggers — the FTS index was silently empty and
BM25 search returned nothing. This is the bug that made the whole
retrieval feel LLM-gated. It's fixed.

### 4. Worker architecture
**Type:** all conform `protocol BackgroundService { func start() async; func stop() async }`.

| Worker | Location | Cadence |
|---|---|---|
| CooccurrenceGraphBuilder | `Knowledge/Topics/` | 6h steady, 5min during 2h warmup |
| MemoryDistiller (via IncrementalUpdater) | `Knowledge/Memory/` | Event-driven, 1.5s debounce |
| ContextPrefixBackfiller | `Knowledge/Backfill/` | 5min steady |
| CausalDiscoverer | `Knowledge/Causal/` | 6h |
| NightlyCompressionScheduler | `Knowledge/Summaries/` | 6h |
| OntologyBackfill | `Knowledge/Ontology/` | once at boot |
| BondBackfill | `Knowledge/Ontology/` | manual (button in Settings) |
| SyntheticQuestionsBackfill | `Knowledge/SyntheticQuestions/` | manual + auto on new chunks |

**Missing:** No priority queue between them. All are equal citizens
competing for the single LLM socket.

### 5. Queue implementation
**Files:** `Ingestion/Pipeline/IngestCoordinator.swift`,
`Ingestion/Pipeline/IncrementalUpdater.swift`.

There is **no explicit queue**. `FolderWatcher` calls
`IngestCoordinator.ingest(fileAt:)` directly; the coordinator is an
`actor`, so concurrent file calls serialize automatically. Concurrency
is expressed via `LaneScheduler.withLane(...)`:
```swift
public actor LaneScheduler {
    private var capacities: [ResourceLane: Int]
    private var inFlight: [ResourceLane: Int]
    private var waiters: [ResourceLane: [CheckedContinuation<Void, Never>]]
}
```
Lanes: `cpu`, `neuralEngine`, `gpuModel`, `llm` (capacity 1),
`diskIO`, `network`.

**Gap:** No backpressure signal to the FolderWatcher. If the LLM lane
queue is 10,000 chunks deep, watcher keeps feeding new files.

### 6. Chunking code
**File:** `Ingestion/Pipeline/Chunker.swift`.
```swift
public struct Chunker: Sendable {
    public let targetCharacterCount: Int       // Default: 1200
    public let minChunkCharacterCount: Int    // Default: 80
    public nonisolated func chunk(
        objectID: KnowledgeObject.ID,
        content: String,
        pageBreaks: [Int] = []
    ) -> [Chunk]
}
```
- **Split strategy:** markdown headings → email headers → paragraphs →
  NLTokenizer sentences as fallback. Boundary-aware.
- **Chunk size:** 1200 chars (~300 tokens).
- **Overlap:** *zero.* — this is a quality gap for straddling
  answers.
- **Sync:** yes, pure CPU, no I/O.

### 7. Embedding pipeline
**File:** `Storage/Vector/Embedder.swift`.
```swift
public protocol Embedder: Sendable {
    var dimension: Int { get }
    func embed(_ text: String) async -> [Float]
    func embedBatch(_ texts: [String]) async -> [[Float]]
    func embedAll(_ texts: [String], batchSize: Int = 64) async -> [[Float]]
}
public struct NLEmbedder: Embedder { … }  // Apple NLEmbedding
```
- **Model:** `NLEmbedding.sentenceEmbedding()` — NOT BGE-M3.
- **Dimension:** ~300 (NLEmbedding default). BGE-M3 would be 1024.
- **Batch size:** 64.
- **Storage:** `SQLiteVectorStore` with int8 quantization (per `T5`
  smoke tests).
- **BGE tokenizer:** used ONLY by `Brain/EmbeddingReranker.swift` for
  cross-encoder reranking, not for base embedding.

**This is the biggest quality lever in the whole system.** Adopting a
proper BGE-M3 CoreML model would lift retrieval precision far more
than any LLM swap.

### 8. Memory Distiller
**File:** `Knowledge/Memory/MemoryDistiller.swift`.
```swift
private func buildPrompt(subject: Subject, events: [Event]) -> String {
    let timeline = events.prefix(40).map { … }.joined(separator: "\n")
    return """
    Subject: \(subject.kind.rawValue) "\(subject.identifier)".
    Summarize the current state in 2-3 short paragraphs, calling out:
    - key decisions,
    - active risks,
    - status (active / completed / blocked / unknown).
    Cite source events by date only.

    Evidence:
    \(timeline)
    """
}
```
- One LLM call per (subject, subject-kind) pair.
- Writes narrative + keyEventIDs + status + confidence + qualityTier
  to `memory_objects`.
- Low-signal gate rejects short/consonant-only/base64-looking subjects
  before ever calling the LLM.

### 9. Context Prefix implementation
**File:** `Ingestion/Pipeline/ContextPrefixGenerator.swift`.
- Prompt: "In one sentence, describe what this passage is about within
  the document above. Do not quote the passage; place it in context.
  Max 25 words."
- Timeouts: `initialTimeoutMs: 8000`, escalates 8s → 16s → 32s across
  3 attempts.
- Failure: NO heuristic fallback. If all three attempts miss, chunk
  ships with `context_prefix = NULL`. Backfiller picks it up later.
- **Written before or after DB insert?** Prefix is populated on the
  in-memory Chunk struct BEFORE `chunks.insertBatch(chunked)`. So a
  failed prefix = a NULL column, not a missing chunk.

### 10. Prompt templates
**File:** `Experts/Shared/PromptTemplates.swift`. Templates:
`emailAnalysis`, `financialAnalysis`, `legalAnalysis`,
`projectAnalysis`, `ocrAnalysis`, `timelineAnalysis`,
`researchAnalysis`. Each returns a `PromptFrame { prompt, evidenceMap }`.
The JSON output contract is enforced: `{"claims":[{"text","evidence":["E1","E3"]}]}`.

### 11. RAG retrieval pipeline
**File:** `Retrieval/HybridRetriever.swift`.
```swift
public actor HybridRetriever: Retriever {
    public func retrieve(
        for intent: UserIntent,
        layers: [RetrievalLayer]
    ) async throws -> RetrievalResult
}
extension RetrievalLayer {
    public nonisolated static let priorityOrder: [RetrievalLayer] = [
        .memory, .timeline, .entity, .metadata, .summary, .graph, .vector
    ]
}
```
Layers run in order and their results ACCUMULATE. No short-circuit; no
drop. Vector layer runs only if candidates from earlier layers exist.

### 12. Search pipeline
**File:** `Brain/MasterBrain.swift` — the answer path:
1. `intentDetector.detect(question:)` → UserIntent
2. `sessionProfile.recordTurn(...)` (memory of prior turns)
3. `router.route(intent:)` → RoutingDecision (experts + layers + complexity)
4. `retriever.retrieve(for: intent, layers:)` → RetrievalResult
5. `executor.execute(intent:, decision:, context:)` — experts run in
   parallel via `ParallelExecutor.run`
6. `verifier.verify(intent:, findings:, retrieval:)` → VerifiedAnswer
7. If refusal or zero citations → `chunkBasedFallback()` labels top 12
   chunks C1–C12 and asks LLM to cite them.

### 13. Canonical entity resolution
**File:** `Storage/Repositories/EntitiesRepository.swift`, method
`insertBatch(_:)`.
```swift
for e in entities {
    let rawNormalized = rawNormalize(e)
    let normalized = applyCanonicalAlias(rawNormalized, kind: e.kind)
    let canonID = try await upsertCanonical(e, normalized: normalized)
    try await insertMention(e, canonicalID: canonID, normalized: normalized)
    if normalized != rawNormalized {
        try await addAlias(entityID: canonID, aliasNormalized: rawNormalized, source: "canonical-alias")
    }
    mapping[e.id] = canonID
}
```
- Pure rule-based, **no LLM**.
- Hand-curated alias map handles Gmail→Google, msft→microsoft, x/twitter, etc.
- Every mention recorded in `entity_mentions`.
- UNIQUE(kind, normalized) at the entities table prevents duplicates.

### 14. Scheduler
**File:** `Core/Concurrency/BackgroundTaskScheduler.swift`.
```swift
public actor BackgroundTaskScheduler {
    public struct Job: Sendable {
        public let id: String
        public let interval: TimeInterval
        public let body: @Sendable () async -> Void
    }
    public func schedule(_ job: Job) { … Task loop with sleep … }
}
```
Fixed-interval loop per job. **No priority ordering, no deferral when
user is querying.** This is a design gap — pressing "Ask" should pause
the distiller and backfiller for the query's duration.

### 15. Threading model
- `actor Database` in `Storage/Database/DatabaseStack.swift` — single
  sqlite3 pointer, never escapes.
- Reads parallelize at the Swift concurrency layer; SQLite itself
  serializes writes via the actor.
- Transaction gate: a queue of `CheckedContinuation` prevents two
  callers from concurrent `BEGIN IMMEDIATE`.
- `LaneScheduler` in `Core/Concurrency/ResourceLane.swift` gates
  ingest workers by resource class. Defaults: `llm: 1`, `neuralEngine:
  1`, `cpu: cores-1`, `network: 4`.

---

## Part 4 — Performance metrics

`Kalsmritikosh/App/LiveMetrics.swift` and `PipelineMetrics.swift`
already track most of what you listed. From `PipelineMetrics.Stage`:
```
discovered, loaded, chunked, embedded, entities, events, relationships, bonds
```
Each is a counter with 60-sample rolling delta window (2s sampling).

Currently exposed:
- ✓ Files/sec, chunks/sec, embeddings/sec, entities/sec, events/sec (per-stage throughput sparkline)
- ✓ Queue depth (`ingestActiveCount`, `ingestLastFile`)
- ✓ RAM usage (`processMemoryBytes`)
- ✓ DB size (`dbBytes`)
- ✓ Per-worker LastRunStatus (CausalDiscoverer, Cooccurrence, etc.)

Not currently exposed:
- ✗ CPU utilization
- ✗ GPU/Neural Engine utilization
- ✗ **LLM calls/min** — this is critically absent given how much wall-clock LLM eats
- ✗ **Ollama socket concurrency** — currently invisible
- ✗ **Chunks-with-NULL-context_prefix count** — the actual "prefix debt"

**Recommended:** add these four metrics to `LiveMetrics.Sample` and
render them in `LiveDashboardView`. Would take ~50 lines.

---

## Part 5 — Concrete architectural changes I'd recommend, ranked

### 1. (HIGHEST LEVERAGE) Replace the embedder with BGE-M3 via CoreML
- Convert BGE-M3 to CoreML (one-time work, community models exist).
- Wire it as a new `Embedder` conformer alongside `NLEmbedder`.
- 300-dim → 1024-dim → measurable recall improvement on the eval kit.
- Zero user-facing behaviour change — retrieval just gets better.

### 2. Add chunk overlap (5 lines of code)
- Modify `Chunker.chunk(...)` to keep last ~120 chars from prior chunk
  as prefix to next. `Chunker.swift`, ~5 lines.

### 3. Add a "you can query X% of your archive now" indicator
- Compute: `chunksWithFTS ÷ chunksTotal × 100` (FTS is populated
  synchronously so this is always high).
- Show it in `AskView` and `OnboardingView`.
- Removes the false perception that "nothing works until enrichment
  completes."

### 4. Query-priority deferral in `BackgroundTaskScheduler`
- Add a flag `isUserQueryInFlight: Bool`.
- Workers check the flag before making LLM calls; if set, they yield
  their next call until the flag clears.
- Ensures the user's "Ask" gets the LLM lane immediately.

### 5. Make ContextPrefix a background-only concern
- Currently, `IngestCoordinator` calls the prefix generator INLINE
  during ingest. Move the call ENTIRELY to the backfiller (which
  already exists). Chunks land with `context_prefix = NULL`
  synchronously; backfiller populates as capacity allows.
- Simplifies the ingest hot path.
- Ollama saturation during ingest becomes a background concern, not a
  perceived block.

### 6. LLM call count metric + budget
- Expose LLM calls/min in `LiveMetrics`.
- Add a per-worker daily LLM call budget.
- Prevents runaway distillation from eating overnight enrichment
  capacity meant for other workers.

### 7. Tier 3 "deep study" mode
- Actually implement the fourth tier from CLAUDE.md.
- When user pins an entity/project/thread, run a deeper LLM pass on
  just that scope. Trades depth for narrower scope.
- Answers the "how do I get REALLY good answers about my most
  important stuff" question.

### 8. Progressive Ollama concurrency
- Detect Ollama's actual serving parallelism (via `OLLAMA_NUM_PARALLEL`
  env or runtime probe) and scale `LaneScheduler.llm` capacity to
  match. Currently hardcoded at 1.

---

## Part 6 — Where I disagree with your assessment

You said:
> Scalability to 100 TB: Not yet. The current enrichment strategy will
> become prohibitively expensive without architectural changes.

**Agreed, but the fix isn't a redesign — it's making enrichment
optional per data class.** Not every byte of a 100 TB archive needs the
full LLM treatment. Realistic scaling strategy:

- **Auto-classify files** at ingest into tiers by importance
  (financial docs, contracts, active threads = hot; old newsletters,
  spam = cold).
- **Cold tier gets FTS-only.** No prefix, no distillation, no
  synthetic questions. Reachable by keyword search, not by "story of
  my archive."
- **Hot tier gets full enrichment.** ~5% of a 100 TB archive.
- **Promotion on demand:** if the user asks about something in cold,
  auto-promote it and enrich in the background.

That's the change that makes 100 TB tractable. It's not a redesign —
it's an *additional dimension* on the existing enrichment ladder.
Fits within the current architecture cleanly.

Your 8.5-9/10 with room to reach 10/10 is fair. Getting there is
mostly about the seven items in Part 5, not a ground-up rework.
