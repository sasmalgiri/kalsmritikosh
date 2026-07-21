> **DOC STATUS: PARTIALLY SUPERSEDED** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Reconstruction contract now lives in pack file 08. _(bannered 2026-07-22, GOV-002.)_

# Plan: Reach the Core Promise

> **Directive:** At any user question, if the data exists, the system should be able to recreate the history / facts / context with maximum detailing possible as per data ingested. Preserve all data; arrange, don't filter.

## 1. Honest baseline — where the system is today

After this session's commits the engine has:
- 22 files / 476 KOs / 42K chunks / 9K entities / 1.2K bonds / 781 events / 2K memory_objects ingested from your real archive
- Format coverage: EML, mbox (per-message), PDF (with OCR fallback), CSV, attachments
- Structured layer: canonical entities + aliases, events with dates+confidence, typed bonds (sent_by / received_by / made_by / affiliated_with), per-fact provenance
- Retrieval: 7-tier (Memory → Timeline → Entity → FTS → Summary → Graph → Vector)
- Brain: MasterBrain dispatches to 7 experts, EvidenceVerifier gates claims by citation, QualityStrip shows confidence/conflicts

What it CAN'T do today vs the directive:
- Topic-aware ranking (it ranks by frequency — Google wins because gmail.com is in every header)
- Composed narratives (it returns bullets, not story)
- 5W+H slot filling (slot_values_json is mostly empty)
- Chronological reconstruction with causation
- Multi-level summaries (memory_objects exist but are shallow — "no events directly mention X yet")
- Topic browsing (no clusters, no tree, no dossiers)

## 2. What the literature says we should do

Approaches we should adopt:

| Idea | Source | What it gives us |
|---|---|---|
| **GraphRAG** | Microsoft (2024) — *From Local to Global: A Graph RAG Approach to Query-Focused Summarization* | Entity-relationship graph + Leiden community detection + hierarchical community summaries. At query time, pick the right summary level. Solves topic navigation. |
| **HyDE** | Gao et al. (2022) — *Precise Zero-Shot Dense Retrieval without Relevance Labels* | LLM generates hypothetical answer → embed that → retrieve. Better than embedding the raw question. We have the inverse via `synthetic_questions` per chunk — same effect. |
| **mem0** | mem0.ai (2024) episodic memory | Memory layers (raw → episodic → semantic), compression over time, recency-weighted retrieval. We have MemoryObject + MemoryChange — same idea, needs depth. |
| **Multi-hop QA** | HotpotQA, MuSiQue benchmarks | Decompose question → sub-questions → evidence per sub-q → compose. Our BondWalker already does graph hops; brain doesn't decompose. |
| **Temporal KG** | Trivedi et al. (2017) | Facts with valid_from/valid_to enable "John worked at X in 2022 but moved to Y in 2024" answers. We have event.date but no validity windows. |
| **Provenance-first** | Memex, Vannevar Bush 1945 | Every fact carries source. We already do this. Keep it. |
| **Contradiction surfacing** | CLAUDE.md | Don't average conflicting evidence; show both with sources. Confidence.aggregate has it; brain output rarely uses it. |

We don't have to invent — we have to COMPLETE existing primitives and WIRE THEM TOGETHER.

## 3. The build — 6 phases, ordered by impact

### Phase A — Tier the data (preserve, classify, weight)
**Goal:** Every extracted fact carries a `quality_tier` (T1/T2/T3) so the brain can DEMOTE noise at query time without ever deleting. Direct response to the "preserve all data" directive.

**Files / changes:**
- Schema migration v14: add `quality_tier TEXT NOT NULL DEFAULT 'T2'` columns to `entities`, `events`, `memory_objects`, `fact_bonds`.
- New `QualityTierClassifier.swift` next to EntityQualityGate, with a single `tier(forEntity:) -> Tier` method:
  - **T1**: structured header-derived (EmailLoader's `structuredEntities` — From / To / Cc / Date)
  - **T2**: NER body extraction (NLTagger results from content)
  - **T3**: shape-flagged (mid-cap noise, vowel-less consonant runs, hostname-shape with digits, base64-looking)
- `IngestCoordinator.processKnowledgeObject` annotates each entity with its tier before `entities.insertBatch`.
- `EntityQualityGate.purgeGarbage` REMOVED (no destructive paths to the DB ever again).
- `MemoryDistiller.isLowSignalSubject` reused as a tier-T3 detector — but only to skip distillation, NOT to delete.
- Brain retrieval composers (`HybridRetriever`, scoring in MasterBrain) multiply candidate scores by `tier_weight` (T1 = 1.0, T2 = 0.6, T3 = 0.15). Adjustable from Settings.

**Outcome:**
- "What organizations am I in touch with via patents?" — T1 contacts (IIPRD, Khurana) rank above T3 (mailer-daemon, AeTnFNk…)
- All data preserved; user can flip `showT3InResults` to see everything.

**Time:** 2-3 focused days. Smoke + real-archive eval after.

**Risk:** classifier mis-tiers a legitimate entity. Mitigation: tier is a column, can be recomputed cheaply.

---

### Phase B — Topic-aware retrieval (community detection)
**Goal:** "patents" → cluster of patent-related entities, not Google.

**Files / changes:**
- New `Knowledge/Topics/TopicGraph.swift`:
  - Build entity co-occurrence graph from `entity_mentions` (which entities appear in same KO)
  - Run Leiden community detection (Swift port — ~200 LoC; reference: Traag et al. 2019)
  - Persist `entity_communities` table: `(community_id, entity_id, level)` — Leiden gives 3-4 hierarchical levels
- Generate community summaries: for each community, fetch top entities + top KOs, run LLM summarization (via existing `CapabilityRegistry.resolve(spec: .summarization)`), store in `community_summaries` table
- New `TopicRetriever` in `Retrieval/`:
  - Embed the query
  - Match against community summaries (highest-level first)
  - Drill down to leaf community of best match
  - Return entities + KOs from that community
- Wire into `MasterBrain` as a new retrieval tier between Entity and FTS

**Outcome:**
- Patent question hits a "patents/IP" community containing IIPRD, Khurana, BiswajitSarkar, Patentattorneyworldwide
- Broad questions ("what's been going on with patents over the years?") hit top-level summary
- Narrow questions ("when did IIPRD file my trademark?") hit leaf community

**Time:** 5-7 focused days. Leiden port is the bulk.

**Risk:** community detection on small archives (40K chunks) may produce odd clusters. Mitigation: fall through to existing FTS if community match confidence < threshold.

---

### Phase C — 5W+H slot filling
**Goal:** Each event answers WHAT / WHEN / WHO / WHERE / WHY / HOW from its source.

**Files / changes:**
- Extend `FactSchema.Event` slot_values_json with explicit keys: `who_did`, `who_received`, `where`, `why`, `how`, `what_about`
- New `Knowledge/Ontology/SlotEnricher.swift`:
  - For each event lacking slots, fetch source KO + ±1 chunk
  - LLM prompt (via existing summarization capability): "Given this email/document, fill these slots: WHO did the action, WHO received it, WHERE did it happen, WHY (motivation in one phrase), HOW (mechanism in one phrase). Reply JSON."
  - Persist to slot_values_json
- Run as a background pass after ingest completes (don't block the activity banner — that was today's lesson)
- Heuristic for high-value events first (taskAssigned, contractSigned, contractModified, deliveryDelayed) — don't run LLM on all 781 events; pick top 50-100 by confidence + recency

**Outcome:**
- Timeline / dossier views show structured facts: "On 2024-08-29 you sent IIPRD a response (WHAT: trademark filing acknowledgment, WHO: you → vijay@khuranaandkhurana.com, WHY: respond to office action, HOW: PDF attachment)"

**Time:** 1 week. Most is prompt tuning + ensuring extractions don't hallucinate.

**Risk:** LLM hallucination on slot values. Mitigation: store `slot_values_provenance_json` alongside — each slot value carries source-chunk range so user can verify.

---

### Phase D — Narrative composer (the centerpiece)
**Goal:** Brain returns a STORY composed from facts, not a bullet list.

**Files / changes:**
- New `Brain/NarrativeComposer.swift`:
  - Inputs: retrieved facts (events + bonds + memory_object narratives + KO citations)
  - Sort chronologically; cluster into "chapters" by topic / month / project
  - For each chapter, traverse bond graph to find causal/connective links between facts
  - Emit a structured outline:
    ```
    chapter("2023 Q4 — first patent contact"):
      - 2023-10-05: cold email TO response@iiprd.com (WHO: you → IIPRD)
      - 2023-10-12: reply FROM vijay@khurana (HOW: directed you to file Form 1)
      - bond: discusses(patent_application) chain ↑
    chapter("2024 Q1 — engagement"):
      ...
    ```
  - This outline goes to the LLM with prompt: "Compose this outline into a clear narrative paragraph. Cite source IDs in [brackets]."
- Replace the current `MasterBrain.answer` LLM call's prompt construction to use NarrativeComposer when intent ∈ {reconstructTimeline, narrate, story, multi-hop, aggregation}
- For pure factual lookups ("when did X happen?") keep the current short-answer path

**Outcome:**
> "Your patent correspondence began on 2023-10-05 when you cold-emailed response@iiprd.com asking about trademark registration. Within a week (2023-10-12) vijay@khuranaandkhurana.com — IIPRD's lead — replied directing you to file Form 1. Through Q1 2024 you exchanged 8 emails refining the application; the signed engagement letter came on 2024-02-08 from prasad@patentattorneyworldwide.com (overlapping engagement). The application was filed 2024-04-15 (per the GDPR report). The first office action arrived 2024-08-06 and you responded by 2024-08-29. [sources: ko-1, ko-7, ko-12, ko-23]"

**Time:** 1-2 weeks. The composer's outline-building is the tricky part; LLM prose-from-outline is well-understood.

**Risk:** composer over-narrates / fabricates causation. Mitigation: every chapter step must cite a fact ID. If a step has no fact ID, drop the step.

---

### Phase E — Library / topic tree / dossier UI
**Goal:** Browse the structured world the engine built, not just query it.

**Files / changes:**
- New `UI/DossierView.swift`: per-entity panel with chronology, bonds, narrative, all referenced KOs
- New `UI/TopicTreeView.swift`: browse community hierarchy from Phase B
- New `UI/LedgerView.swift`: time-ordered ledger with WHO / WHAT / WHEN / WHERE columns
- Wire from existing Sources / Timeline tabs

**Outcome:**
- Click an entity → see everything we know about them (a "real" memory_object surfaced)
- Browse topics like a Wikipedia category tree
- Scroll a year-by-year ledger of your life

**Time:** 1 week. Mostly SwiftUI work; data is already in the DB after Phases A-D.

---

### Phase F — Quality eval loop (close the feedback)
**Goal:** Measurable improvement over time, not vibes.

**Files / changes:**
- New `EvalKit/UserQuestionsEval.swift`: lets you save the actual questions you ask + your expected answer. Becomes a personal eval set.
- "This answer is wrong" button on each answer → captures (query, returned answer, your correction) into the eval set
- Weekly eval run that computes:
  - Recall@10 (did the right KO get retrieved?)
  - Citation precision (cited KOs actually relevant?)
  - Answer recall (which expected facts appeared in answer?)
  - Confidence calibration (high-confidence wrong vs low-confidence right)
- Track over time → graph
- "I want to remember this answer correction" → adds to a never-show-again-confidence-degraded list

**Outcome:**
- You see numbers move up week over week
- Wrong answers fix themselves (the eval set forces regression-resistance)

**Time:** 3-5 days.

## 4. Order of priority + dependencies

```
Phase A (tier) ────┬──> Phase B (topics) ──┬──> Phase D (composer) ──> Phase E (UI)
                   │                       │
                   └──> Phase C (slots) ───┘
                              │
                              └──> Phase F (eval loop)  [can start anytime]
```

**If we have 1 week:** Phase A only. Biggest single-week win.
**If we have 3 weeks:** A + B + F. Topic-aware retrieval + measurable progress.
**If we have 5-6 weeks:** All of A–F. Delivers the directive.

## 5. What this plan deliberately does NOT do

- **No cloud LLM dependency.** Apple FoundationModels on macOS 26+ + Ollama fallback covers everything. Capability discipline preserved.
- **No new schema for raw data.** Existing `knowledge_objects + chunks + entity_mentions` keeps every byte. New columns/tables are derived views.
- **No data deletion ever again.** The purge utility stays but has no automatic callers.
- **No format-specific branches in Brain/Knowledge/Retrieval.** All format handling stays in Ingestion (architecture invariant).

## 6. Risks I want to flag honestly

1. **LLM cost / latency** — Phase C slot enrichment and Phase D composer both call the LLM many times. On Apple FoundationModels (on-device) this is fine; on Ollama it's seconds per call. Mitigation: queue + cache + run during idle.
2. **Leiden port complexity** — community detection is a real algorithm. ~300 LoC Swift port + tests. We could also start with a simpler agglomerative clustering, accept lower quality, swap later.
3. **Slot hallucination** — LLM might invent WHY/HOW when text doesn't support it. Mitigation: provenance per slot + a "this slot was unsourced" badge in the UI.
4. **Composer overreach** — narrative composer might bridge unrelated facts. Mitigation: every chapter step requires fact-ID citations; unsupported transitions are dropped.
5. **Eval-set bootstrapping** — Phase F needs you to author ground-truth answers. If you don't have time, eval stays vibe-based.

## 7. Smallest concrete next step (if you say "go")

**Phase A's first commit** — schema migration v14 + QualityTierClassifier + tier annotation at extraction. Files to touch:
- `Kalsmritikosh/Storage/Schema/SchemaMigrations.swift` (add v14)
- `Kalsmritikosh/Storage/Repositories/EntitiesRepository.swift` (column + read/write)
- `Kalsmritikosh/Storage/Repositories/EventsRepository.swift` (same)
- `Kalsmritikosh/Knowledge/Entities/QualityTierClassifier.swift` (new — 80 LoC)
- `Kalsmritikosh/Ingestion/Pipeline/IngestCoordinator.swift` (tier annotation before insert)
- `Kalsmritikosh/Retrieval/HybridRetriever.swift` (tier weighting in scoring)
- Tests: per-tier classification + score-weighting smoke

Ship + commit. Re-ingest. Compare brain answers before/after.

That's the smallest useful step that visibly moves toward the directive.
