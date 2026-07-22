# Canonical Evidence Authority (EV-001)

**Task:** EV-001 — declare the single canonical source/version/block authority so there is
**no ambiguity in active data authority**. Depends on `SCHEMA_AUTHORITY_MAP.md` (AUD-003).
**Status:** declaration (build-safe). The code-enforcement follow-ups (EV-002/003/006) are
listed at the end and are test-gated (require TST-001).

Grounded in code at schema v54:
`Kalsmritikosh/Core/Models/{EvidenceBlock,SourceLocator,Chunk,KnowledgeObject}.swift`,
`Storage/Repositories/{EvidenceStore,ChunksRepository,KnowledgeObjectRepository,FilesRepository,SourceRelationsRepository}.swift`.

## 1. The one authority chain

```
SourceDocument            ← canonical identity of an ingested source (root authority)
  └─ SourceVersion        ← immutable bytes/hash/provenance per version
       └─ EvidenceBlock   ← typed structural evidence, each with an exact SourceLocator
```

**Everything a user can cite resolves to an `EvidenceBlock` (or its `SourceLocator`) under a
specific `SourceVersion` of a `SourceDocument`.** That triple is the only authority for
"what the source says." No other table may claim that role.

## 2. What is a projection (derived, rebuildable — never authority)

| Artifact | Relationship to authority |
|---|---|
| `KnowledgeObject` (KO) | A normalized, format-agnostic **view** over a source version's blocks. Must reference its `SourceVersion` and the blocks it projects. Not a second source of truth. |
| `Chunk` | A retrieval-sized slice **of an `EvidenceBlock`**. Already carries `evidenceBlockID` (`Chunk.swift:51`); its `objectID` (KO id) is a convenience back-reference, not its authority. |
| `Summary`, `MemoryObject`, graph edges, `Contradiction`, `GapNode`, `Timeline`, `QAPair` | Derivations/detections/generated text. **Generated text is never primary evidence.** |
| FTS tables, `vectors`, `chunk_embeddings`, `embedding_cache` | Indexes/caches; rebuildable by re-indexing / re-embedding. |

Rule: if an authority row exists, its projections can be dropped and recomputed. The reverse
is never true — a projection must never be the last copy of a fact.

## 3. Human layer (authority for decisions, never mutates source)

`fact_reviews`, `review_decisions`, `review_tags` record `HUMAN_CONFIRMED / HUMAN_CORRECTED /
HUMAN_REJECTED`. They annotate derived findings; they **never edit** `SourceVersion` bytes or
`EvidenceBlock` content. A human correction creates a review record, not a source rewrite.

## 4. Snapshots (reproducibility)

`corpus_snapshots` pins the set of `SourceVersion`s + processing state an answer/asset was
produced against, so historical answers replay against their original scope (EV-004).

## 5. Ambiguities this declaration resolves (found in AUD-003 + code)

These are the concrete code deltas that make the above *enforced*, each mapped to its task:

1. **Chunk is KO-anchored, not block-anchored (EV-003).** `Chunk.objectID: KnowledgeObject.ID`
   is required; `evidenceBlockID` is optional. Target: every chunk must carry a non-null
   `evidenceBlockID` and reach its `SourceVersion` through the block. KO id becomes a
   nullable back-reference. Enforce with a projection-invariant test.
2. **SourceLocator points at `chunkID`, not the block (EV-002).** `SourceLocator.chunkID`
   (`SourceLocator.swift:20`) should also/instead carry the `evidenceBlockID` so a citation
   is lossless even if chunks are re-sliced. No locator dimension may be dropped when
   round-tripping a citation.
3. **Duplicate version mechanisms (EV-006).** `source_versions` (canonical) coexists with
   `file_versions` and `knowledge_objects_history`. One active version model wins
   (`source_versions`); the others are migrated/retired via a new versioned migration.
4. **Multiple entity representations (SEM-009).** `entities` vs `entities_new` vs
   `people`/`companies`/`projects`. Reconcile to one canonical entity model.

## 6. Invariants (to assert once TST-001 lands)

- Every `Chunk` resolves to exactly one `EvidenceBlock` → one `SourceVersion` → one `SourceDocument`.
- Every citation/`SourceLocator` resolves to a block under a known version; no dimension lost on round-trip.
- Dropping and rebuilding all PROJECTION + CACHE tables reproduces identical retrieval inputs.
- No write path mutates `SourceVersion` bytes or `EvidenceBlock` content after creation.
- Exactly one active version-history table (`source_versions`).

## 7. Follow-ups (test-gated — do not mark done on compile alone)

| Task | Deliverable | Gate |
|---|---|---|
| EV-002 | SourceLocator carries lossless block reference | round-trip test |
| EV-003 | KO/chunk reference source version + blocks | projection-invariant test |
| EV-004 | corpus/processing snapshots replay | replay test |
| EV-006 | consolidate to one version model | migration test |

Until those land with tests, this file is the **authoritative declaration**; the code is
**IMPLEMENTED-partial** against it (structural tables exist; enforcement pending).
