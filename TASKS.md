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

## T13 — Email parsing quality: mbox split, structured headers, guided extraction, entity gate

**Why (pre-Gate-1; blocks demo AND eval validity):** on a real archive the
extractor emits mostly garbage entities — mail-server hostnames (Seqmbx01,
Tyzpr01mb4530), header keywords (SMTP, MAIL, Reply, Notifications, Message ID),
weekday/month tokens as people/orgs (tue, thu, jun), generic tokens (urls,
category, ref), and the app's own internal identifiers (apple naturallanguage,
worker-pod names). Garbage entities poison the graph, Knowledge tab, memory, and
every answer, and would make the Gate 1 eval numbers meaningless. Run T13 BEFORE
the first eval.

**Files:** EmailLoader.swift, NLEntityExtractor (becomes a fallback path),
new Knowledge/Entities/EntityQualityGate.swift + an editable Resources stoplist,
new Knowledge/Extraction guided-extraction call site, IngestCoordinator.

**Spec:**
1. Split mbox into one KnowledgeObject per message (the documented "M5" debt):
   EmailLoader returns [KnowledgeObject]; IngestCoordinator loops. Per-message KOs
   carry <50 entities, so UPDATE_04's oversized guard never fires and per-message
   co_occurrence becomes meaningful again. Remove the "single concatenated KO"
   stub and its M5 TODO from the EmailLoader header once done.

2. Parse structured headers (From, To, Cc, Date, Subject) into typed fields.
   Populate person / organization / date entities DIRECTLY from From/To/Date as
   high-confidence structured facts. NEVER run NER over routing headers
   (Received, Message-ID, Return-Path, DKIM/SPF, X-*, server names). NER/guided
   extraction runs ONLY over Subject + decoded body (after T7 quote-strip).

3. PRIMARY extraction via on-device guided generation:
   - Route entity + event extraction for the Subject+body through the EXTRACTION
     capability (`context.capabilities.resolve(.extraction)`), which resolves to
     Apple's on-device Foundation Models provider already registered in Routing.
     Use guided generation / structured output with a strict schema (people,
     organizations, dates-with-role, monetary amounts). A schema-constrained
     model will not emit "Tuesday" as a person — this is the actual cure, not the
     stoplist.
   - CAPABILITY DISCIPLINE: do NOT reference any model name in Knowledge/. Resolve
     the capability; the registry picks the model. On devices without Foundation
     Models (older OS / non-Apple-Intelligence), the registry falls back to the
     NLTagger path automatically.

4. SECONDARY safety net — EntityQualityGate (applies to BOTH paths, before insert):
   reject weekday and month tokens; a stoplist of mail/header keywords (smtp,
   mail, mailer-daemon, reply, notifications, message id, localhost, async, urls,
   category, ref, alerts, profiles, …); the app's own internal identifiers (apple
   naturallanguage, apple ai, apple intelligence, *worker*, container/pod-name
   patterns); single generic lowercased words; and hostname/hex/numeric-shaped
   tokens (tyzpr01mb4530, seqmbx01, d22rediffmail). Stoplist is an editable
   Resources data file, not hardcoded.

5. Verify T3 canonicalization folds case + known aliases:
   google / Google / Gmail / Googlemail / googlemail must resolve to ONE org.
   If they are separate in this build, fix normalization/alias seeding and report
   what was wrong.

6. Gmail Takeout headers — use them directly:
   - `X-GM-THRID` is Gmail's own thread id. Group messages into threads by
     X-GM-THRID directly; it is more reliable than reconstructing threads from
     References / In-Reply-To. Carry the thread id into KO metadata.
   - `X-Gmail-Labels` carries labels/folders (Sent, Important, custom labels).
     Store as KO metadata/tags; do NOT feed label text to NER/extraction.
   - Prefer these over the generic threading path when present.

7. Inline attachments — handle BEFORE extraction (a second garbage/bloat source):
   - Gmail Takeout inlines attachments as base64 MIME parts. NEVER run NER or
     guided extraction over base64 or raw MIME part bytes — decode first.
   - Decode each attachment part; route real attachments (PDF, DOCX, images …)
     through the EXISTING loaders so they become their own KnowledgeObjects
     linked to the parent message, and dedupe by content hash per T7 (the same
     attachment recurs across many messages).
   - The text handed to extraction is the decoded text/plain or text/html part
     only (after T7 quote-strip), never the attachment bytes.

**Acceptance:**
- Re-ingest the real Sent.mbox: each message is its own KO; entities-per-message
  < 50; a 50-entity spot check of the Knowledge tab shows real people/orgs with
  ZERO weekdays, header keywords, hostnames, or internal identifiers.
- Total canonical-entity count is far below the pre-fix ~6,514. If the count is
  still in the thousands after T13, header-stripping or the gate is not working
  — investigate before declaring T13 done.
- co_occurs edges form per message and are bounded; the UPDATE_04 guard does not
  fire on per-message KOs.
- ProjectDelta answers unchanged or improved; grep guard clean; BuildProject
  green; SmokeTest passes.

---

## Gate 2 (outline — specs to be written after Gate 1 numbers exist)

**Gate 1 is locked** (eval-report.md commit `4bcf4e5`, 18 Jun 2026). The
prioritized, eval-driven Gate 2 work derived from the lock lives in
[GATE2_ROADMAP.md](./GATE2_ROADMAP.md):

- G2-0  parallel expert dispatch + shared evidence cache (cuts 3-4 h eval → 30 min)
- G2-SWIFT6  Swift 6 strict-concurrency (spec below; precondition met by Gate 1 lock)
- G2-1  per-claim reranker (lifts citation precision from 0.33 → ≥0.6)
- G2-2  temporal intent window grammar (fixes T1/T3 = 0)
- G2-3  contextual retrieval (Anthropic-style chunk prefix)
- G2-4  stronger reasoning model trial procedure
- G2-5  UI: streaming + Quality Strip expand

Items below (notarization + UI items) remain Gate 2 and stay in this file.

Notarization + CODE_SIGN_ENTITLEMENTS wiring; per-file completeness report UI
(pages parsed/OCR'd/skipped, quotedBytesRemoved); onboarding multi-root suggestions +
"What kalsmritikosh can see" panel; SourceViewer range highlighting; UserNotifications
"answer matured" re-run; GB-tiered pricing copy.

### G2-SWIFT6 — Swift 6 strict-concurrency migration (Gate 2)

**Why:** ~279 isolation warnings are 279 places the compiler cannot prove
data-race safety, in an app that will hold a user's life archive under real
concurrency (WorkerPool ingest + UI + background distillation). Must be zero
before sale. Deliberately scheduled AFTER Gate 1 so the eval harness provides a
behavioral regression baseline for the refactor.

**Precondition (hard):** T12 complete and a baseline eval-report.md committed.

**Files:** cross-cutting by module, in this order, ONE MODULE PER COMMIT:
Core → Storage → Knowledge → Retrieval → Routing → Brain → Ingestion → App/UI.

**Spec:**
- Phase the compiler: first build each module clean under
  `-strict-concurrency=targeted`, then `complete`; flip the project to the
  Swift 6 language mode only as the final commit.
- Preferred fixes, in order: confine types to an existing actor; add
  @MainActor where the type is genuinely UI-bound; add Sendable conformances
  to value types; replace cross-actor `.shared` access with injected
  references (IngestCoordinator already shows the DI pattern). Avoid
  @unchecked Sendable except with a comment proving invariants; never use it
  on mutable reference types.
- Known specific items from the warning audit:
  - AppState/CapabilityRegistry `.shared` cross-actor access → inject.
  - DatabaseStack execRaw call sites → route through the Database actor API.
  - IngestCoordinator default-param actor inits → make params explicit at
    call sites.
  - OllamaProvider isolation-mismatch conformance → align protocol isolation.
  - SourceRange.swift:31 `Range: @retroactive Codable` → REMOVE the
    retroactive conformance (future-SDK breakage risk); replace with a small
    owned Codable wrapper struct (e.g. CodableRange) and migrate call sites.
- After EVERY module commit: BuildProject green + SmokeTest passes.
- After the FINAL commit: re-run the full eval harness.

**Acceptance:**
- Zero strict-concurrency warnings; project compiles in Swift 6 language mode.
- SmokeTest passes; ingest stress check (fixture corpus at max WorkerPool
  concurrency) completes without deadlock.
- Eval metrics within ±2% of the pre-migration baseline report; any larger
  delta is investigated and explained in the commit message before merge.
- Grep guard still clean.

## Gate 3 (outline)
sqlite-vec/ANN behind the VectorStore protocol; tiered LLM extraction at scale
(type-routed readers: invoice/contract/thread prompts); demand-driven Tier-3 queue fed
by retrieval gap detection and dossier opens; legacy DOC/XLS/PPT/MSG lean scanner
(UTF-16LE-aware) + PST via libpff; entity dossier export.

### GS-MAIL — Port mailin email-format parsers (Gate 3)

**Why:** PST, OST, MSG, NSF, and hardened MIME parsing already exist as
production Swift in the sibling repo github.com/sasmalgiri/mailin (folder
`mailin/`: PSTParser.swift, NSFParser.swift, MSGParser.swift, MIMEParser.swift,
MBOXParser.swift, EMLXParser.swift, EmailParserProtocol.swift). Porting them
closes every legacy email format in one task, adds Lotus Notes (NSF) support no
competitor has, and removes the previously-planned libpff dependency. Same owner's
proprietary code — porting is permitted; keep a one-line provenance comment atop
each ported file.

**Files:** new Ingestion/Loaders/Ported/ (PSTParser, MSGParser, NSFParser,
MIMEParser + minimal shared helpers), EmailLoader / loader-registry updates,
Resources/Fixtures/LegacyMail/ additions.

**Spec:**
- Copy the parser sources; strip mailin-specific UI/model types; adapt output to
  emit KnowledgeObjects via the EXISTING Ingestor protocol (do not modify it).
- Route OST through the PST path if mailin does so — verify in source and mirror.
- Preserve streaming/batch behavior for large archives (mailin handles 100MB+).
- Carry threading metadata (message-id, in-reply-to, references, thread id, and
  Gmail X-GM-THRID when present) into KO metadata so T13 dedup/threading can use it.
- Consider upgrading the existing EML/MBOX path to mailin's MIMEParser ONLY if a
  side-by-side fixture run shows strictly better extraction; otherwise leave it and
  report the comparison.
- No new third-party dependencies.

**Acceptance:**
- Sample PST, MSG, and NSF fixtures each ingest to KnowledgeObjects with correct
  message counts and non-empty bodies.
- Hash-idempotent re-ingest still no-ops; grep guard clean; BuildProject green;
  SmokeTest passes.
