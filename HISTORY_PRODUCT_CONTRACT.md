# HISTORY_PRODUCT_CONTRACT.md — AUTHORITATIVE

_Source of truth for the Universal History Reconstruction program
(`Kalsmritikosh_Universal_History_and_Five_Persona_Instructions.md`, owner-issued
2026-07-23, audited head `748e652`). This contract governs the `Knowledge/History/`
subsystem and takes precedence for history behavior. It does not replace the
Production Readiness pack for non-history work._

## The promise (locked)

For any supported corpus and any **resolvable subject**, Kalsmritikosh produces a
**reproducible, subject-scoped reconstruction** of events, state changes,
relationships, decisions and periods over time, where **every material statement
links to evidence**, and **uncertainty, contradictions and missing evidence are
made visible**. A history is NOT a generic summary.

## Non-negotiable trust rules

1. No history item without provenance.
2. No invented date, role, actor, location, amount, status, motive, or causal link.
3. No silent fallback from a named subject to global archive activity.
4. No claim that a partial history is complete.
5. No automatic reconciliation of conflicting evidence (show both; never average).
6. No persona may change the underlying facts.
7. No LLM is required during ingestion.
8. No LLM may write directly into canonical evidence tables.
9. User corrections are append-only, reversible, attributed.
10. Every generated artifact is tied to a corpus snapshot and engine version.

## Support-status honesty

Every source is FULL / PARTIAL / PRESERVED-ONLY. History generation discloses how
much of the relevant material is each. Never claim universal semantic understanding.

## Architecture rule

ONE new orchestration service (`HistoryReconstructionEngine`) consolidating existing
primitives (events, entities, assertions, generic facts, relationships, evidence
blocks, chronological planner, rule-based + LLM narrative composers, contradiction /
gap / alternative-account builders). **Do NOT build a second history database or a
parallel history feature.** New code lives in `Kalsmritikosh/Knowledge/History/`.
Deterministic outline is built BEFORE any prose; LLM budgets cap prose, never outline
completeness. No model names in `Knowledge/` (capability discipline).

## Implementation order (per plan §65) — status

1. **Typed HistorySubject + canonical Dossier selection** ← in progress (Phase 1 kernel: models + resolver landed)
2. HistoryMaterialCollector
3. TemporalClaim + HistoryItem (+ schema migration)
4. GenericFact/Assertion → temporal projection
5. Complete ID-scoped history retrieval
6. Reconciliation, alternatives, gaps
7. HistoryReconstructionEngine
8. Rule-based fallback wiring
9. HistoryArtifact persistence
10. History/Dossier UX
11. Real file-to-history gold tests
12. Persona work products
13. Evidence Time Machine + Missing Chapter Engine

## Release gates (must pass before shipping history)

- Subject scope leakage: **0** (a named subject never becomes global archive activity).
- Material claim citation reopen: **100%**.
- Unsupported material claims / invented date-role-amount-location: **0**.
- Persona fact divergence: **0** (persona changes presentation, never claims).
- Deterministic outline stability: **100%** (same snapshot + engine version → same outline).
- Duplicate copies counted as independent corroboration: **0**.
- No generic RAG output labelled "Historical".

## Reuse ledger (do not duplicate)

`EvidenceStatus` (Core/Models/GenericFact.swift — the ONE shared enum),
`Entity`/`EntitiesRepository`, `Event`/`EventsRepository`, `Assertion`,
`GenericFact`/`GenericFactRepository`, `Relationship`, `EvidenceBlock`,
`DatePrecision`, `GapNode`, `CausalLink`, `ContradictionDetector`,
`AlternativeHistoryBuilder`, `NarrativeClaimVerifier`, `ReconstructionOutline*`,
`ChronologicalPlanner`, `RuleBasedNarrativeComposer`, `LLMNarrativeComposer`,
`CorpusSnapshotRepository`.
