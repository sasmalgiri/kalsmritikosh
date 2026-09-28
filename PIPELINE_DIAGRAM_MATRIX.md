# PIPELINE_DIAGRAM_MATRIX — Kalsmritikosh, ingest → answer

**Assembled:** 2026-09-24 · branch `v11-implement-all` · schema **v129**
**Method:** traced from the live call chain in committed code. Every `file:line`
below was re-read against the file after drafting.

### The document set (four files, distinct jobs — so they cannot drift)

| file | job |
|---|---|
| **this file** | the diagram + the stage matrix, at a glance |
| `PIPELINE_WORKFLOW.md` | the prose detail behind it, with per-finding failure stories |
| `PIPELINE_MATRIX.md` | **generated** table wiring — `python3 scripts/pipeline-matrix.py` |
| `PRODUCT_COMPLETION_TODO.md` | the remaining work, with acceptance criteria |

### What this establishes, and what it does not

`OK` in the matrix means **traced, wired, and covered by a test**. It does **not**
mean the values written are correct on real data — a table can be fully wired
and fully wrong. Proving behaviour is the job of Tiers 2–5 in
`PRODUCT_COMPLETION_TODO.md`. Anything I could not establish is marked
`UNKNOWN` rather than assumed in either direction.

This supersedes `ANALYSIS_ingest_to_answer.md`,
`FULL_REPOSITORY_STATIC_AUDIT.md` and `FILE_BY_FILE_AUDIT.csv` — all three
describe schema v103 (July 2026) and record every file as "unwired (no test
target)", untrue since the suite reached ~4,700 tests. One of them asserts
"Ingestion is correct and complete."

---

## A · INGEST FLOW

```
  AskView:490 · WorkCenterView:1124 · SmokeTest:89 · IncrementalUpdater:102
                              │
      IngestCoordinator.ingest(fileAt:intent:)                      :408
                              │
      runIngest(fileAt:parentVersion:memberByteURL:)                :518
                              │
      ingestCore(...)                                               :937
      ┌───────────────────────┴──────────────────────────────────────────┐
      │ A1  intakeCoordinator.admit()              :949 / :953           │
      │       custody + ONE detected type — no second detection pass     │
      │ A2  guard handle.shouldProcess             :982     ← skip gate  │
      │ A3  universalExecutor.execute(request)     :1016    ← parser     │
      │ A4  containerCoordinator.expand()          :1039  ⟲ runIngest    │
      │ A5  backupCoordinator.expand()             :1061  ⟲ runIngest    │
      │ A6  guard !perFileKOs.isEmpty              :1079                 │
      │ A7  persistStructuralDoc()                 :712  → EvidenceStore │
      │       evidenceStore.linkBlocks()           :1146                 │
      │ A8  advanceReadiness() / ftsCoverage()     :683 / :1161          │
      └───────────────────────┬──────────────────────────────────────────┘
                              │
      processKnowledgeObject(...)                                   :1222
      ┌───────────────────────┴──────────────────────────────────────────┐
      │ B1  env.extractStructuralMetadata()        :1237                 │
      │ B2  objects.insert(object, fileID:)        :1258 → knowledge_objects
      │ B3  chunks.insertBatch(chunked)            :1395 → chunks +_fts  │
      │ B4  synthRepo.insertBatch(rows)            :1462 → synthetic_questions
      │ B5  entityExtractor.extractEntities()      :1490                 │
      │       entities.insertBatch(raw)            :1520 → entities      │
      │ B6  eventExtractor.extractEvents()         :1527                 │
      │       events.insertBatch(remapped)         :1544 → events        │
      │ B7  narrativeSlotExtractor.extract()       :1576                 │
      │ B8  relationships.upsertEdges()            :1606 → relationships │
      └───────────────────────┬──────────────────────────────────────────┘
                              │
      Also on the ingest path:
        extractTypedFields()      :749  → typed_fields
        deriveAssertions()        :772  → assertions
        insertObserved()          :813  → assertions
        deriveGenericFacts()      :835  → generic_facts   ← C-4 + OCR live here
        bindIdentifierAnchors()   :903  → entities (anchors)
        writeDomainAliases()      :1830 → entity_aliases
        emailParticipants()       :1700 → email_participant_occurrences
        subjects(forEntities:)    :1943 → cache invalidation
```

All line numbers above are in `Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift`.

### Background lanes — *not* part of one ingest call

| lane | entry | note |
|---|---|---|
| Embedding drain | `embeddingDrainLoop():328` · `drainEmbeddingsNow():384` | writes `chunk_embeddings`; survives restarts |
| Progressive upgrade | `configureUpgrades():416` · `reprocess():439` · `drainUpgrades():461` | on-demand re-parse to a higher goal |
| Resume / recovery | `resumeIncompleteIngests():615` · `reingestFailedLegacy():591` | crash recovery |
| **Topics** | `AppState:1848` (auto, post-ingest) · `AppState+LedgerMaintenance:89` · `SettingsView:1512` (manual) | **gated on the on-device model being up** |
| **History** | `reconstruct(subject:request:)` — `AppState:3950`, `:4025`, `AppState+LedgerMaintenance:252` | **on demand, per subject** — never global |
| Ledger drain | `LedgerDrainCoordinator.drain()` | rewrites derived layers to current eras |

---

## B · ANSWER FLOW

```
  AskView:880  brain.answer(...)        │  HistoryView:750 · LibraryView:236
                                        │  brain.answerStream(...)
      MasterBrain.answer(...)   :1400 ──┴──→ answerStream(...)          :326
      ┌──────────────────────────────────────────────────────────────────┐
      │ Q1   QuestionShapeRouter.route(question)          :364           │
      │        out-of-scope → outOfScopeRefusal            :368           │
      │ Q2   QueryMissionCompiler().compile(...)          :1600          │
      │ Q3   AdaptiveEvidencePlanner().plan(...)           :917          │
      │ Q4   HybridRetriever.retrieve(...)                 → §C          │
      │ Q5   applyCorrectiveRetrieval(...)            :869 / :1681       │
      │        CorrectiveRetrievalPlanner().decide()        :882          │
      │ Q6   composers by shape:                                         │
      │        SlotAnswerComposer · EventAnswerComposer · story          │
      │        ToolGroundedComposer                                      │
      │        DeterministicEvidenceFallback              :1759          │
      │        AnswerSynthesizer                          :1826          │
      │ Q7   ClaimEvaluator · ClaimGrounding · AssertabilityPolicy       │
      │ Q8   EvidenceVerifier → ship / downgrade / refuse / conflict     │
      │ Q9   findCrossRetrievalContradictions(...)                       │
      │ Q10  ConfidenceEngine + CitationResolver → quality strip         │
      │ Q11  finalizeProgressiveAnswer(...)               :1443          │
      │        beginAnswer()                              :1456          │
      │        appendWorkingResult()              :1460 / :1469          │
      │        markReviewReady() → lockVerifiedFinal()  :1473 / :1474    │
      │        markIncomplete()                           :1465          │
      └──────────────────────────────────────────────────────────────────┘
```

Line numbers are in `Kalsmritikosh/Brain/MasterBrain.swift`.

**Durability ordering is correct as written:** `lockVerifiedFinal` runs *after*
the durable commit (`:1474`, commented "durable commit BEFORE verifiedFinal"),
so a `verifiedFinal` event cannot exist without its revision.

---

## C · RETRIEVAL LAYERS — `Kalsmritikosh/Retrieval/HybridRetriever.swift`

| # | layer | line | reads |
|---|---|---|---|
| 1 | `memoryLayer` | 592 | `memory_objects` |
| 2 | `timelineLayer` | 647 | `events` |
| 3 | `entityLayer` | 697 | `entities`, `entity_aliases` |
| 4 | `metadataLayer` | 801 | `chunks_fts`, `chunks` |
| 5 | `summaryLayer` | 889 | `summaries` |
| 6 | `graphLayer` | 897 | `relationships` |
| 7 | **`bondLayer`** | 918 | `fact_bonds` — typed bond walk, intent-biased |
| 8 | `vectorLayer` | 1024 | `chunk_embeddings` |

`bondLayer` is an **eighth** layer. CLAUDE.md's documented priority
(Memory → Timeline → Entity → FTS/metadata → Summary → Graph → Vector) names
seven. The code looks sound; the documented invariant is what reviewers check
against, so one of the two should change (finding F-8).

---

## D · STAGE MATRIX

**OK** traced · wired · tested — **RISK** works, with a named failure mode —
**GAP** missing or unverified — **UNKNOWN** not established by this pass

| # | stage | writes | status |
|---|---|---|---|
| A1 | Intake · custody · type detection | `files`, `source_versions`, `source_intake_receipts` | OK |
| A2 | Skip gate | — | RISK — skip reason never aggregated |
| A3 | Parse (plugin) | `evidence_blocks`, `parser_runs` | OK |
| A4 | Container expansion | `container_manifests`, `container_members` | **RISK — `try?` :1042** |
| A5 | iOS backup expansion | same | **RISK — `try?` :1067** |
| A7 | Structural persist | `evidence_blocks`, `evidence_block_objects` | **RISK — `linkBlocks` `try?` :1146** |
| A8 | Readiness | `source_readiness_*` | OK |
| B2 | KnowledgeObject | `knowledge_objects` | OK |
| B3 | Chunking | `chunks`, `chunks_fts` | OK |
| B4 | Synthetic questions | `synthetic_questions` | **GAP — `synthetic_questions_fts` never populated** |
| B5 | Entities | `entities`, `entity_mentions` | **RISK — `try?` :1520 CASCADES (F-1)** |
| B6 | Events | `events`, `event_entities` | RISK — `try?` :1544 |
| B7 | Narrative slots | slot columns | UNKNOWN |
| B8 | Relationships | `relationships` | RISK — `try?` :1606 |
| — | Typed fields | `typed_fields` | OK |
| — | Assertions | `assertions` | **GAP — no test names it** |
| — | Generic facts | `generic_facts` + `derivation` (v129) | OK |
| — | Anchors | `entities` | OK |
| — | Aliases | `entity_aliases` | GAP — untested |
| — | Embeddings | `chunk_embeddings` | **RISK — `try?` :372 / :398** |
| — | Boilerplate | `boilerplate_templates`, `boilerplate_uses` | **GAP — write-only + untested** |
| — | Salience | `document_terms` | OK |
| — | **Topics** | `memory_objects`, `memory_changes`, `entity_cooccurrences` | **RISK — silently empty when the model is down** |
| — | **History** | `history_artifacts`, `history_items`, `history_gaps`, `history_item_evidence`, `history_chapters` | **GAP — `history_chapters` write-only** |
| — | Claims | `claims`, `claim_evidence`, … | OK |
| Q1–Q11 | Answer | `answers`, `answer_revisions`, `answer_revision_events`, `answer_claims` | OK — no real-data harness yet |

---

## E · FINDINGS

| id | sev | finding | task |
|---|---|---|---|
| **F-1** | HIGH | `:1520` swallowed entity insert → empty `canonicalMapping` → `:1544` writes events with **un-canonicalised references**. The corruption is downstream of the failure and looks like valid data | #83 |
| **F-2** | HIGH | `history_chapters` written every build, read nowhere — inside a suite whose test is named *"Save persists the full graph and reloads"* and asserts no chapter | #86 |
| ~~F-3~~ | **WITHDRAWN** | I claimed `qa_pairs_fts` + `synthetic_questions_fts` had no producer. FALSE. Both repositories maintain their index explicitly (`SyntheticQuestionsRepository:68`, `QAPairsRepository:71`) AND `HybridRetriever` calls both searches (`:837`, `:868`). The lane is fully wired. My scan produced two false negatives — see §F | — |
| **F-4** | MED | `:1042` / `:1067` / `:1123` recursive member ingest `try?` — an examiner cannot tell *"not in the container"* from *"failed to parse"* | #84 |
| **F-5** | MED | `:1146 linkBlocks` `try?` — the one call that wires the claim–evidence contract; a silent failure yields facts citing evidence that cannot resolve | #84 |
| **F-6** | MED | `:372` / `:398` embedding `try?` — **failed** is indistinguishable from **pending**, so coverage can never be honest | #84 |
| **F-7** | MED | `knowledge_objects_fts` trigger-maintained on every KO write (`SchemaMigrations:1226–1234`), queried by nothing | #86 |
| **F-8** | LOW | `bondLayer` is an eighth retrieval layer the documented invariant omits | T5-3 |
| **F-9** | LOW | `boilerplate_uses` written at `BoilerplateRegistry:92`, never consulted | #86 |
| **F-10** | LOW | 9 tables with no producer. `vectors` is deliberate — a migration reads it to backfill `chunk_embeddings` | #82, #86 |

### Still UNKNOWN — stated rather than assumed

- What `narrativeSlotExtractor` (`:1576`) writes, and whether anything reads it.
- The transaction boundary across B2–B8: can a crash leave a KO with chunks but
  no entities, and would the next run treat it as done? (task #85)
- Whether any retrieval query is unbounded (no `LIMIT`) on a large ledger.
- `document_profiles` / `derived_objects` / `enrichment_status` /
  `event_versions` semantics.

---

## F · Verification status of this document

| claim set | how verified |
|---|---|
| 19 `IngestCoordinator` citations | re-read against the file after drafting. **1 was wrong** on the first pass (`universalExecutor.execute` is `:1016`, not `:1017`) and is corrected |
| 8 retrieval-layer lines | re-verified by direct `grep -n` |
| `MasterBrain` lines | taken from direct `grep -n` output |
| table wiring | generated by `scripts/pipeline-matrix.py`, which **refuses to emit** a matrix disagreeing with 8 hand-verified cases. That guard caught three of my own classifier errors in sequence |
| correctness of written values | **NOT verified** — see the scope note at the top |

To re-verify after any edit:

```sh
python3 scripts/pipeline-matrix.py          # regenerates PIPELINE_MATRIX.md + self-checks
grep -n "<symbol>" <file>                    # spot-check any citation above
```
