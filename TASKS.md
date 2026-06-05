# TASKS.md — kalsmritikosh upgrade plan (Gate 0 → Gate 1)

Rules: execute in order, one task per session, fresh session per task. Each task is
self-contained: Goal → Why → Files → Spec → Acceptance. Read CLAUDE.md first, always.

---

## T1 — Replace noisy-OR confidence with calibrated aggregation

**Why:** `Confidence.combined` is `1-(1-a)(1-b)` (Core/Models/Confidence.swift:31).
Reducing many claims with it mathematically pins answer confidence at ~1.00
(94 claims × 0.5 → 0.9999…). Confidence must vary with evidence quality.

**Files:** Core/Models/Confidence.swift, Brain/ConfidenceEngine.swift,
Experts/EmailExpert.swift (aggregateConfidence), any other expert reducing with combined().

**Spec:**
- Keep `combined(with:)` but mark it `// noisy-OR: P(at least one). Never use across claims.`
- Add `Confidence.aggregate(_ claims: [Confidence], agreement: Double, diversity: Double,
  contradictionPenalty: Double) -> Confidence`:
  weighted mean of claim confidences × (0.6 + 0.4·agreement) × (0.7 + 0.3·diversity)
  − 0.15·contradictionPenalty, clamped to [0.05, 0.98]. Constants as named `static let`s.
- DefaultConfidenceEngine.evaluate and every expert-level aggregation use the new function.
  agreement/diversity/contradiction inputs come from the signals the engine already computes.

**Acceptance:**
- New unit checks (in SmokeTest if no test target yet): (a) 94 claims at 0.5 with
  agreement 0.2, diversity 0.2 → result ≤ 0.65; (b) 3 claims at 0.9, agreement 0.9,
  diversity 1.0, no contradictions → result ≥ 0.85; (c) result never ≥ 0.99.
- ProjectDelta fixture answer no longer reports 1.00.

---

## T2 — Claim-level evidence contract (kill blanket stamping)

**Why:** In Experts (see EmailExpert.tryLLM) every parsed bullet receives the ENTIRE
retrieval set as supportingObjectIDs. Citations become theater, contradiction detection
fires on unrelated claims, and per-claim verification is impossible.

**Files:** Experts/Shared/PromptTemplates.swift, all 7 experts, Brain/EvidenceVerifier.swift,
Core/Models (ExpertFindings.Claim).

**Spec:**
- Prompts: number every retrieved item (chunks, events, memory snippets) as [E1], [E2]…
  and require strict JSON output: `{"claims":[{"text": "...", "evidence": ["E2","E5"]}]}`.
  No prose outside JSON.
- Parse robustly (strip code fences); map E-ids back to real object/event/entity IDs.
- Validation rule: a claim's evidence set must be a non-empty subset of the retrieval set.
  Claims with empty/invalid evidence are dropped, and a counter `droppedUnverifiable`
  is added to the ConfidenceReport.
- Heuristic fallback path (no LLM) keeps current behavior but marks claims
  `evidenceGranularity: .coarse` so the UI can distinguish.

**Acceptance:**
- On the fixture: at least two claims from the same expert carry DIFFERENT evidence sets.
- No claim's evidence equals the full retrieval set unless retrieval returned ≤2 items.
- EvidenceVerifier's sharesEvidence now compares per-claim sets (no behavior change needed
  in its code if it already reads claim.supportingObjectIDs — verify and report).

---

## T3 — Schema v3: canonical entities + mentions + aliases

**Why:** Entities are inserted per-document with no UNIQUE constraint
(Storage/Repositories/EntitiesRepository.swift uses plain INSERT) and EntityLinker.link
runs only on each file's own batch (Ingestion/Pipeline/IngestCoordinator.swift:201).
"Supplier ABC" across 30 files = 30 rows. Things, not strings.

**Files:** Storage/Schema/ (new SchemaV3), EntitiesRepository, EntityLinker,
IngestCoordinator, Brain/EvidenceVerifier.swift (domain→org mining), Knowledge tab queries.

**Spec:**
- New tables: `entity_mentions(id, entity_id FK, kind, surface, normalized,
  source_object_id FK ON DELETE CASCADE, span_start, span_end, confidence)` and
  `entity_aliases(entity_id FK, alias_normalized, source TEXT)` with
  UNIQUE(entity_id, alias_normalized).
- `entities` becomes canonical: add UNIQUE(kind, normalized); migration: insert distinct
  (kind, normalized) as canonical rows, convert existing rows to mentions pointing at them.
- Ingest path: extract → for each entity, upsert canonical
  (`INSERT … ON CONFLICT(kind, normalized) DO UPDATE` keeping max confidence) → insert
  mention. Lookups resolve through aliases: a query name matches canonical.normalized OR
  any alias_normalized.
- Port EvidenceVerifier's email-domain→organization mining to WRITE aliases
  (e.g. domain "northwind.com" → alias of org "Northwind") at ingest, not just at render.

**Acceptance:**
- Ingest the fixture twice: canonical entity count unchanged; mention count doubles only
  if files were re-ingested as changed (hash-idempotent path must still no-op).
- One canonical row per (kind, normalized) — verify with a GROUP BY HAVING count>1 query
  returning zero rows.
- Knowledge tab still lists people/companies/projects (now from canonical table).

---

## T4 — RelationshipExtractor: write the graph

**Why:** Nothing in the codebase constructs or inserts a Relationship; GraphStore,
the graph retrieval layer, and GraphExplorer read an empty table.

**Files:** new Knowledge/Graph/RelationshipExtractor.swift, RelationshipsRepository,
IngestCoordinator (call after entity upsert), Storage/Schema (only if columns missing:
relationships need source evidence ids + weight).

**Spec:**
- Co-occurrence edges at Tier 1: for each KO, for each unordered pair of distinct
  canonical entities mentioned in it, upsert edge kind `co_occurs` with weight += 1 and
  append the KO id to evidence (cap evidence list at 20 ids). Same for entities sharing
  an Event: kind `event_linked`.
- Email-specific typed edge: sender person → recipient person(s) `emailed`,
  sender person → sender-domain org `affiliated` (uses T3 aliases).
- Idempotency: re-ingest of unchanged file must not inflate weights (skip when the
  hash-idempotent path skips).

**Acceptance:**
- Fixture produces ≥ 8 edges; GraphExplorer lists them; HybridRetriever's graph layer
  returns non-empty results for "Supplier" queries (log it).
- 2-hop traversal from "Project Delta" reaches the supplier org.

---

## T5 — Real vector store (BLOB brute-force, quantized)

**Why:** SQLiteVectorStore is a no-op: upsert discards embeddings IngestCoordinator
already computes (Ingestion/Pipeline/IngestCoordinator.swift:219); nearest returns [].
Semantic recall doesn't exist.

**Files:** Storage/Vector/SQLiteVectorStore.swift, Storage/Schema (vectors table),
Retrieval/HybridRetriever.swift (vector layer now live).

**Spec:**
- Table `vectors(chunk_id PK FK ON DELETE CASCADE, dim INT, q BLOB, scale REAL)`.
- Quantize float32 → int8 symmetric (scale = max|x|/127); store blob + scale.
- nearest(query, k, candidateChunkIDs?): dequantize-free scoring — int8 dot product
  × scales, normalize → cosine. If candidate ids provided (from FTS/entity prefilter),
  scan only those; else full scan with a hard cap (log when corpus exceeds ~2M vectors:
  "ANN required — Gate 3").
- No new dependencies. sqlite-vec/DiskANN is explicitly Gate 3, not this task.

**Acceptance:**
- Round-trip: upsert 1k synthetic vectors, query returns the planted nearest neighbor
  with cosine ≥ 0.99 of float baseline on 20 random probes.
- Fixture: vector layer contributes results for a paraphrased query that FTS misses
  (e.g. "money owed by the supplier" finds invoice chunks).

---

## T6 — Batch embeddings; never embed into the void

**Why:** Per-chunk embedding calls waste 10–50× throughput; and embedding while the
store was a stub burned compute for nothing.

**Files:** Routing/Providers/OllamaProvider.swift (+ ModelProvider protocol),
Ingestion/Pipeline/IngestCoordinator.swift.

**Spec:**
- Add `embedBatch([String]) -> [[Float]]` to the embedding capability; Ollama
  implementation uses the batch-capable endpoint; Apple/other providers loop internally.
- IngestCoordinator accumulates chunks into batches of 64 (configurable) per KO group
  before embedding; skips embedding entirely if the vector store reports unavailable.

**Acceptance:** ingesting a 1,000-chunk synthetic corpus logs ≤ ceil(1000/64) embed
calls (add a counter to AtlasLog).

---

## T7 — Email quote-strip + attachment dedup

**Why:** Real archives are 50–80% quoted repetition; identical attachments recur across
threads. The fastest document is the one recognized as already read.

**Files:** Ingestion/Loaders/EmailLoader.swift, Ingestion/Pipeline/IngestCoordinator.swift.

**Spec:**
- Before chunking/extraction, strip quoted regions: lines prefixed `>`,
  blocks following /^On .{5,80} wrote:$/, gmail_quote/blockquote HTML containers,
  `-----Original Message-----` blocks. Keep the stripped text in KO metadata
  `quotedBytesRemoved` for the completeness report.
- Attachments: before parsing an attachment, compute contentHash; if a KO with that
  hash exists, link the email to the existing KO instead of re-parsing.

**Acceptance:** a synthetic 10-message thread fixture (write it under
Resources/Fixtures/) ingests with ≥60% fewer chunk tokens than unstripped; the same
PDF attached to two emails yields exactly one parsed KO with two parent links.

---

## T8 — Move / delete / revoke reconciliation

**Why:** Lookup is URL-first (IngestCoordinator:125–148): a moved file re-ingests as a
duplicate and the old row goes stale; deleted files leave silent ghosts; removing a
root (UI/SourcesView.swift ~line 85) silently keeps everything. Archive semantics:
knowledge must survive an unplugged drive.

**Files:** IngestCoordinator, FilesRepository, Storage/Schema (files.availability),
UI/SourcesView.swift, AppState (root reachability).

**Spec:**
- Hash-first on unknown path: if findByURL misses but a row with the same contentHash
  exists, UPDATE its url (move detected), no re-ingest.
- `files.availability` TEXT: 'available' | 'offline_root' | 'missing'. Root unreachable
  on launch/watch → mark its files offline_root, pause that root, badge in Sources.
  File individually gone within a reachable root → 'missing'; KOs and derived knowledge
  are KEPT; answers may cite with a "source file no longer on disk" badge. Never
  cascade-delete from a reconciliation sweep.
- Root removal becomes a dialog: "Stop watching (keep what was learned)" vs
  "Stop and forget everything from this folder" (the second performs explicit
  cascading deletes for that root's files, with a count shown first).

**Acceptance:** scripted check in SmokeTest: ingest file → move it → re-scan → same KO
id, new url, KO count unchanged. Delete it → availability 'missing', knowledge intact.
Remove root via dialog option 2 → its KOs gone, others intact.

---

## T9 — Event date confidence

**Why:** Email header dates are trustworthy; dates parsed from content are medium;
file mtime lies after copies. A timeline built on mtimes is fiction.

**Files:** Storage/Schema (events.date_confidence REAL), RuleEventExtractor,
EmailLoader (header date pass-through), ConfidenceEngine, TimelineView (badge).

**Spec:** assign 0.95 header / 0.7 content-extracted / 0.3 mtime-fallback. Engine
weights each event's contribution by date_confidence. Timeline shows a subtle "~"
badge on low-confidence dates.

**Acceptance:** fixture events carry expected tiers; an mtime-only synthetic file's
event shows the badge.

---

## T10 — Timeliness signals: freshness + temporal coverage

**Why:** Users need to see answer quality. Two numbers: how recent is the newest
evidence (weighted by whether the question cares), and does evidence span the asked window.

**Files:** Brain/ConfidenceEngine.swift, Core/Models (ConfidenceReport),
Brain/MasterBrain or RuleIntentDetector (temporal intent + window already detected — reuse).

**Spec:**
- freshness = exp(−ageDays/τ); τ=90 for status/current intents, τ=∞ (skip) for
  historical/reconstruction intents.
- coverage: bucket supporting events into the asked window's halves/quarters; coverage =
  fraction of buckets with ≥1 event; report gaps as ranges.
- Extend ConfidenceReport: newestEvidenceDate, coverage, coverageGaps[],
  ingestCoverage (fraction of files past Tier 1 — read from files table), and multiply
  final confidence by max(ingestCoverage, 0.5) while ingest is incomplete.

**Acceptance:** unit checks with synthetic events: full-range evidence → coverage 1.0;
2026-only evidence for a 2023–2026 question → coverage ≤ 0.5 with a named gap.

---

## T11 — Quality strip + conflict surface in AskView

**Why:** The gate's arithmetic must be visible or it builds no trust. Conflicts are
shown as conflicts, never averaged.

**Files:** UI/AskView.swift (+ small subviews), reads ConfidenceReport from T1/T10.

**Spec:** under each answer render one compact line, expandable:
`Confidence: strong|moderate|weak · Evidence: N claims, M files, formats · Timeliness:
newest <date>, covers <range>[, gap <range>] · Conflicts: K`. Tapping Conflicts shows
each conflict as two sides with their dates and source links. While ingest is running,
prepend `Answered from X% of your archive`. Words before numbers; no raw floats.

**Acceptance:** fixture answer renders the strip; a hand-made contradictory fixture
(two files asserting paid/unpaid) shows Conflicts: 1 with both sources tappable.

---

## T12 — Eval harness (Gate 1: decides whether we sell)

**Why:** All quality claims currently rest on an 8-file fixture. No retrieval change
ships without moving measured numbers.

**Files:** new `evalkit/` (SPM executable target or a CLI scheme), Resources/Eval/.

**Spec:**
- `questions.json`: 60 questions over a documented corpus, 15 each: lookup,
  aggregation, temporal/what-changed, multi-hop. Each: question, expectedKeywords[],
  expectedSourceFiles[], class.
- Corpus: ProjectDelta fixture + a documented script (`evalkit/README.md`) to prepare
  an Enron-subset corpus (point at a local maildir/mbox path; do NOT vendor the data).
- Runner: headless MasterBrain ingestion+answering; metrics per class: answer keyword
  hit rate, citation precision (cited files ∩ expected / cited), retrieval recall
  (expected files present in retrieval set), p50/p95 latency.
- Output `eval-report.md` with a table per class. Thresholds recorded as targets in the
  report header (lookup ≥0.9 precision; temporal coverage-aware), not enforced yet.

**Acceptance:** one command produces eval-report.md on the fixture corpus; numbers are
nonzero and reproducible across two runs (±5%).

---

## Gate 2 (outline — specs to be written after Gate 1 numbers exist)
Notarization + CODE_SIGN_ENTITLEMENTS wiring; per-file completeness report UI
(pages parsed/OCR'd/skipped, quotedBytesRemoved); onboarding multi-root suggestions +
"What kalsmritikosh can see" panel; SourceViewer range highlighting; UserNotifications
"answer matured" re-run; GB-tiered pricing copy.

## Gate 3 (outline)
sqlite-vec/ANN behind the VectorStore protocol; tiered LLM extraction at scale
(type-routed readers: invoice/contract/thread prompts); demand-driven Tier-3 queue fed
by retrieval gap detection and dossier opens; legacy DOC/XLS/PPT/MSG lean scanner
(UTF-16LE-aware) + PST via libpff; entity dossier export.
