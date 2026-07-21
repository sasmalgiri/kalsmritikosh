> **DOC STATUS: HISTORICAL** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Superseded by the pack backlog. _(bannered 2026-07-22, GOV-002.)_

# G3 — The Periodic Table of Facts (detailed roadmap)

Date: 2026-06-20
Vision: a typed, schema-first knowledge graph where every fact has a known
type, every bond between facts follows a real-world rule, and the Brain
answers questions by walking the graph instead of guessing via similarity.

> "Each meaningful sentence or paragraph or cluster should form bonds with
> rules — not chemistry rules but real facts that connect through their
> relevant information across documents." — the founding insight (2026-06-20)

---

## Why this is G3, not G2

Gate 2 ships a usable archive search with:
- Deterministic cross-encoder reranker (UPDATE_17B)
- Temporal grammar (port chatmind date regex)
- Synthetic questions + QA pairs (chatmind layers)
- Soft semantic-bond graph (HippoRAG-style)

Gate 3 turns the archive into a **reasoning surface**:
- Every fact has a known `FactType`
- Bonds between facts follow strict rules (cardinality, slot constraints)
- Multi-hop questions become graph walks with **explainable traces**
- The answer comes with a "why" — the walk path, not just citations

These are layered: G2 makes retrieval reliable; G3 makes reasoning explicit.

---

## G3 task ladder (24 ordered tasks)

### Phase 1 — Schema (no runtime impact, ~1 week)

| # | Task | ETA | Output |
|---|---|---|---|
| G3.1 | `FactSchema.swift` — enum FactType + FactSlot struct + BondRule struct | 1 day | Knowledge/Ontology/FactSchema.swift (~200 LOC, pure data) |
| G3.2 | `Ontology.swift` — static registry of ~10 starter types and ~15 bond rules | 1 day | Knowledge/Ontology/Ontology.swift |
| G3.3 | `ONTOLOGY_V1.md` — human-readable doc explaining types, slots, rules | 0.5 day | Docs only — the "periodic table" poster |
| G3.4 | Worked-example trace doc: walk through ProjectDelta fixture end-to-end with the v1 ontology | 1 day | Knowledge/Ontology/WORKED_EXAMPLE.md |

### Phase 2 — Storage + labeling (~1 week)

| # | Task | ETA | Output |
|---|---|---|---|
| G3.5 | DB migration: add `fact_type TEXT` to entities, events, memory_objects (nullable, NULL = unlabeled) | 0.5 day | Storage/Schema/Migration_NNN.swift |
| G3.6 | DB migration: add `slots JSONB` for typed slot storage | 0.5 day | Same migration as above |
| G3.7 | `FactTypeClassifier` — rule-based label per entity/event using NLTagger + Ontology rules | 2 days | Knowledge/Ontology/FactTypeClassifier.swift |
| G3.8 | Backfill job: classify existing entities/events with `fact_type` | 0.5 day | Knowledge/Ontology/Backfill.swift |
| G3.9 | `OntologyValidator` — given a row, validates against its FactType's slot constraints | 1 day | Knowledge/Ontology/OntologyValidator.swift |

### Phase 3 — Bond engine (~1.5 weeks)

| # | Task | ETA | Output |
|---|---|---|---|
| G3.10 | `BondConstructor` actor — given a fact, walk Ontology.rules to find counterparts, create Relationship rows | 3 days | Knowledge/Ontology/BondConstructor.swift |
| G3.11 | Idempotent bond writes — re-running ingest doesn't double-create | 1 day | Same file |
| G3.12 | Wire BondConstructor into IngestCoordinator (after entity/event extraction) | 0.5 day | Ingestion/Pipeline/IngestCoordinator.swift edit |
| G3.13 | Slot extractors per FactType — rule-based first (regex + NLTagger) | 3 days | Knowledge/Ontology/Slots/*.swift |
| G3.14 | LLM-assisted slot extractor fallback (uses extraction capability spec) | 2 days | Knowledge/Ontology/Slots/LLMSlotExtractor.swift |
| G3.15 | Cardinality enforcement — required slots/bonds must exist; exclusive bonds are mutex | 1 day | Knowledge/Ontology/CardinalityCheck.swift |

### Phase 4 — Schema-aware retrieval (~1 week)

| # | Task | ETA | Output |
|---|---|---|---|
| G3.16 | New retrieval layer `graph_typed` in HybridRetriever | 2 days | Retrieval/HybridRetriever.swift extension |
| G3.17 | Intent → walk plan: question shape determines which bonds to traverse | 2 days | Brain/WalkPlanner.swift |
| G3.18 | Walk executor: given start nodes + walk plan, return typed evidence | 2 days | Brain/WalkExecutor.swift |
| G3.19 | RRF fusion of typed-graph results with vector/FTS/entity layers | 1 day | Retrieval/HybridRetriever.swift |

### Phase 5 — Explainability (~3 days)

| # | Task | ETA | Output |
|---|---|---|---|
| G3.20 | Walk-path attachment on VerifiedAnswer (`evidencePath: [WalkStep]`) | 1 day | Core/Models/VerifiedAnswer.swift extension |
| G3.21 | "Why this answer?" UI panel showing the walk path with chunk citations per step | 2 days | UI surface |

### Phase 6 — Validation (~1 week)

| # | Task | ETA | Output |
|---|---|---|---|
| G3.22 | Eval expansion — new questions specifically targeting bond walks (multi-hop) | 2 days | Resources/Eval/questions.json + g3 fixture |
| G3.23 | Eval metric — "walk-correctness": did we walk the right bond at each step? | 1 day | EvalKit/G3Metrics.swift |
| G3.24 | Gate 3 closeout report — typed-graph retrieval recall, walk accuracy, latency | 1 day | Documentation |

---

## Critical decisions to lock before Phase 2 starts

These need answers before we write a migration:

1. **`fact_type` on entities only, or also chunks?**
   Lean: entities + events for v1. Chunks stay typeless.
2. **Slots as JSONB or as typed columns per FactType?**
   Lean: JSONB. Faster to evolve. Add typed columns once schema stabilizes.
3. **Required-slot violations: drop the fact, or store with confidence=0?**
   Lean: store with low confidence + surface as a "quality issue" in the UI.
   Dropping facts silently is anti-user.
4. **LLM-derived vs rule-derived bonds: how do we mark provenance?**
   Lean: `Relationship.derivation` enum with `.rule`, `.llm`, `.heuristic`.
   Lets the verifier weight rule-derived bonds higher.
5. **Multi-language**: do v1 slots assume English?
   Lean: yes. v2 expands. We're shipping English-first per SHIP_DECISIONS.

---

## Risks (be honest)

- **Schema design is the hard part.** v1 ontology will be wrong; expect 2-3
  iterations on the type list and bond rules before it stabilizes.
- **Most docs are unstructured**. A blog post mentioning Project Delta will
  not populate `Contract.party_a_org`. The graph degrades to vector retrieval
  for those docs. That's OK — the graph adds value where slots can be filled.
- **Maintenance burden grows with ontology size.** Each new FactType adds
  N² potential bond rules. Constrain to the ones that earn their keep.
- **Cold-start.** A user's first 100 docs may have no bonds yet because the
  graph needs cross-document fact matches. UX should not advertise the graph
  benefit until coverage is meaningful.

---

## What G3 is NOT

- Not a re-implementation of GraphRAG. We're not extracting subject-verb-object
  triples from arbitrary text. We're extracting typed facts with typed bonds
  where the rules are knowable up front.
- Not an LLM-based ontology learner. The schema is hand-curated.
- Not a replacement for vector retrieval. Vector + FTS + graph fuse via RRF.
- Not a graph database. We stay on SQLite. The relationships table grows but
  stays tractable.
- Not a v1 ship blocker. G2 ships first.

---

## Provisional sequencing (calendar-aware)

Assuming G2 ships ~end of Q3 2026:

- **Q4 2026** — Phase 1 (schema), Phase 2 (storage + labeling)
- **Q1 2027** — Phase 3 (bond engine), Phase 4 (retrieval)
- **Q2 2027** — Phase 5 (explainability), Phase 6 (validation), G3 closeout

Total: ~6 calendar months of part-time work.

---

## What ships when G3 is done

A user asks: *"Why did delivery slip on Project Delta in April 2024?"*

Today's answer (Gate 1): a paragraph stitching top chunks, with citation
list. No reasoning visible. Multi-hop recall flaky.

Gate 3 answer:
```
Delivery for Project Delta slipped on 2024-04-08.

  Walk:
  Project Delta
    → delivers_for ← Delivery(2024-04-08, status=delayed)
    → caused_by ← Email(supplier_abc_22.eml, from=Maria Lopez,
                        mentions: "parts shortage upstream")
    → preceded_by ← Email(supplier_abc_22.eml,
                          forwarded: "supplier warned 5 days prior")

  Confidence: 0.91 — 3 hops, each with chunk evidence
```

That's the gate-3 promise: not just an answer, an **inspectable chain of
typed facts** the user can audit.
