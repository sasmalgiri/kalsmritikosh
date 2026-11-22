# Unified-path program (owner, 2026-11-22)

**Authority.** This is the owner's instruction of 2026-11-22:

1. Track every item in the "built but not used / discussed but not built" inventory.
2. Implement them all **without testing now**. The owner tests later.
3. **One path:** small and big cases go through the same steps.
4. **Dynamic workers sized by memory:** split the input into worker-sized batches; each worker writes to its own shard file; merge at the end.

The tracker rows carry spec ref `UP-2026-11-22` in `docs/SMART_MAP_COMPLETION_MATRIX.json`. A finished row is marked `IMPLEMENTED` with "not tested (owner: test later)". It is never marked `AUTOMATED_VERIFIED` until its tests are written and run.

This supersedes the "scaffolding only" rule of 2026-11-06 for AI-path work. These stay in force:
- privacy defaults: sending documents online is the person's choice, with consent once per case;
- capability discipline: no model names in Experts, Brain, Knowledge, Retrieval or Ingestion;
- the one-ledger invariant: shards are staging only, and the merge goes through the ledger's own actor.

## Why

Code read on 2026-11-22 at `be5d1563`:
- In a case with AI, the reader (`Brain/CaseReader.swift`) received only `knowledge_objects.content`.
- None of the structured ledger reached it, and most of MasterBrain was skipped (planning, ledger tools, the expert panel).
- The Cleaner's output was never stored.
- Near-duplicates were not collapsed.

The ledger and the Brain are the product's main work. This program makes them feed the AI.

## 1. The one case path (AI-17 … AI-25, PERF-18)

Every question in a case runs these steps, whatever the case size:

| Step | What happens | Built from |
|---|---|---|
| 1. Understand | Canonicalise the wording, then interpret it and route it by shape | `QuestionCanonicalizer`, `QuestionUnderstanding`, `QuestionShapeRouter` |
| 2. Plan | Compile a mission and its evidence obligations; assess them | `QueryMissionCompiler`, `MissionEvidenceObligations`, `MissionEvidenceAssessor` |
| 3. Find | Case-scoped retrieval, then corrective retrieval, re-ranking and hypothetical-answer expansion. This orders the documents and focuses the briefing; it does not decide what is sent. | `HybridRetriever`, `CorrectiveRetrievalPlanner`, `RerankerLadder`, `HypotheticalQueryExpander` |
| 4. Brief | The ledger case briefing (below), with a document number on every line | `CaseBriefing` (new) |
| 5. Prepare | Cleaned text pinned to its version; boilerplate, signatures and disclaimers removed; near-duplicates and same-text copies sent once with a note; documents ordered by step 3 and packed into **parts** that fit the budget. A small case is one part. | `Cleaner`, `NearDuplicateFinder`, `SourceSameness`, `CaseReader.parts` |
| 6. Read | Each part goes out as briefing + part + question. The reader may request ledger tool results as plain JSON (at most 3 rounds), and the app answers locally. Parts run concurrently up to the worker count. | `CaseReader`, `LedgerTools` |
| 7. Merge | Combine the parts' claims; duplicates are removed and conflicts kept | `CaseReader.merge` |
| 8. Second look | One more pass: which briefing items does the answer not explain, and which contradict it? | `CaseReader` |
| 9. Restore and verify | Masked names are restored on the Mac. Then the verifier checks every claim: quote verbatim, figures, full names. | `OnlinePIIMasker`, `CaseReader.verdict` |
| 10. Cross-check | The rules reading, the expert panel, the shape gates, and the second AI reading (a disagreement marks the answer "Needs review") | `MasterBrain`, `ExpertCouncil`, `ComposeTwin` |
| 11. Present | Answer, quality strip and follow-up suggestions | `AskView`, `QualityStrip` |

Without AI, steps 1–4 run and the person sees the search results plus the briefing (no prose answer), as the AI-first disclosure says.

**The case briefing** is built from the ledger for the case's authorised sources. It is in a fixed order, so the provider can cache it. It contains:
- people and organisations, with aliases and quality tier;
- dated events, with date precision;
- relationships;
- typed fields;
- domain facts;
- statements (who said what);
- claims;
- contradictions;
- money figures;
- memory objects;
- summaries;
- topics and the subject spine;
- reconstructed history;
- coverage gaps (what was not read, and why).

Every line carries `[D<n>]`, the document it came from. A line without a document is not included.

**Consent.** The consent sheet says that the documents go together with "what the app extracted from them".

**Background work** (method review, AI conflict look, deep study) uses the provider's batch service where available (AI-24).

## 2. Memory-sized shard workers (PERF-14 … PERF-17)

1. **Budget.** `IngestWorkerPool` works out the worker count from:
   - available memory (free + inactive pages), with half reserved for the system and the app;
   - a per-worker share;
   - memory-pressure events;
   - thermal state.

   The count stays between 1 and the number of active cores − 1, and it is re-checked between batches.
2. **Batches.** `IngestBatchPlanner` packs the files of the chosen folders into batches, by size and estimated pages or records, so that each batch fits one worker's share. A very large file (mailbox, PDF, archive) gets its own batch or is split into page or record ranges.
3. **Shards.** Each worker imports its batch into its own **shard ledger**: an encrypted SQLite file with the ledger's schema, under `Application Support/…/Shards/<run>/<n>.sqlite`. It uses the same key and commits small transactions.
4. **Merge.** When every worker is done, `ShardMerger` merges each shard into the one ledger:
   - It attaches the shard inside `actor Database`.
   - It copies rows table by table in dependency order (ids are UUIDs, so no remap is needed).
   - It skips sources the ledger already holds (by content hash).
   - It then runs the work that spans shards: entity linking and reconciliation, the people-register refresh, FTS, vectors and receipts.

   The merge records its progress per shard and table, so a crash resumes. A shard file is deleted only after its merge is confirmed.

## 3. Inventory → rows

| Section | Rows |
|---|---|
| One path | AI-17 one path · AI-18 briefing · AI-19 cleaned/de-duplicated text · AI-20 ledger tools loop · AI-21 second look · AI-22 Brain steps on the case path · AI-23 methods review / conflict look / claim check on the same path · AI-24 batch reads · AI-25 mask-send-restore · PERF-18 reader parts |
| Built, not called | AI-26 ComposeTwin · AI-27 story rewording · AI-28 deep study (Tier 3) · AI-29 mission assessor · AI-30 table questions · AI-31 missing evidence · AI-32 capability catalogue · AI-33 source location resolver · IN-15 logistics tables · IN-16 enrichment queue · IN-17 boilerplate compaction · IN-18 register refresh + merge audit · IN-19 readiness inspector + version view · IN-20 case enrichment · IN-21 data sets · REASON-17 scope ledger · HISTORY-09 history tools · AUTO-13 workflow engine · ARCH-11 persona routing · OUTPUT-11 persona work products · ADAPT-11 workbench sensitivity · MAP-14 unopened screens · ARCH-12 small unused types · QA-20 measurement on real use |
| Off by default | AI-34 AI levers on when AI is on · IN-22 thread merge + email forensics · IN-23 transcription engines · AUTO-14 Custom Protocol Studio · IN-24 RAR / legacy Office (BLOCKED) |
| Not built | IN-25 extraction backlog · IN-26 OCR repair · TIME-11 undated order · GRAPH-13 deeper links · HISTORY-10 multi-topic stories · SEARCH-16 follow-ups · SEARCH-17 reference shelf · SRC-11 host artifacts · AI-35 on-device model (BLOCKED) |
| Workers | PERF-14 budget · PERF-15 batches · PERF-16 shards · PERF-17 merge |

The 45 earlier rows that are not finished (identities, human studies, signed builds and so on) are already in the tracker with their blockers. They need people, accounts or a server, not code.

## 4. Round 2 (owner, 2026-11-22, later)

The owner decided:
- **One AI.** The only AI is Claude, on the person's own key or the owner's relay. AI-35 (an on-device model) is dropped. Import-time AI asks permission once per import and shows the cost.
- **AI all the time.**
- **RAR / 7z** through the system libarchive (BSD).
- **The 45 rows** that need people, accounts or a server are finished as labelled simulations.
- **Open-source forensic samples** are used to check the readers.
- **Parallel workers** in every pipeline step.
- **The briefing** draws on every source and adds AI suggestions.
- **The reference shelf** and **batch reads** are finished.
- **The round-1 limits** are removed and the generated docs are regenerated.

All of this is done first, without tests. The test phase and the screen walk follow. New rows: AI-36..39, PERF-19..20, SRC-12, IN-27, QA-21..23. IN-24 is unblocked.
