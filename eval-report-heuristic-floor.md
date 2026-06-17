# Kalsmritikosh — Heuristic-Floor Baseline (Gate 1)

**Generated:** 18 Jun 2026 at 1:45:56 AM
**Mode:** HEURISTIC FLOOR (no LLM)
**Confirmation:** p50 latencies of 17–28 ms across all classes; no LLM round-trip in the data. Every expert ran on heuristic fallback. This is the floor — what kalsmritikosh's retrieval + structure can do *without* any reasoning model.

This baseline reflects the engine after UPDATE_07 through UPDATE_14: scorer fixed, corpus isolated, fixture bundled, retrieval sound, chunk→answer bridge in place, intent-aware citation cap applied.

## Targets (Gate 1)

- lookup citation precision ≥ 0.9
- temporal answers carry non-empty coverage with named gap labels
- aggregation keyword-hit rate ≥ 0.8
- multi-hop retrieval recall ≥ 0.6

## Per-class metrics

| Class | N | Keyword hit | Cite precision | Retrieval recall | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|---:|---:|
| lookup | 4 | 0.50 | 0.33 | 0.88 | 28 | 28 |
| aggregation | 4 | 0.25 | 0.46 | 0.94 | 26 | 35 |
| temporal | 4 | 0.50 | 0.12 | 0.38 | 17 | 36 |
| multihop | 4 | 0.00 | 0.42 | 0.67 | 17 | 18 |

## Per-question detail

| Q | class | intent | cited | expected | overlap | precision | recall |
|---|---|---|---:|---:|---:|---:|---:|
| L1 | lookup | factualLookup | 3 | 1 | 1 | 0.33 | 1.00 |
| L2 | lookup | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| L3 | lookup | factualLookup | 3 | 1 | 1 | 0.33 | 1.00 |
| L4 | lookup | factualLookup | 3 | 1 | 1 | 0.33 | 1.00 |
| A1 | aggregation | factualLookup | 7 | 2 | 2 | 0.29 | 1.00 |
| A2 | aggregation | reconstructRelationship | 6 | 4 | 3 | 0.50 | 0.75 |
| A3 | aggregation | factualLookup | 8 | 3 | 3 | 0.38 | 1.00 |
| A4 | aggregation | reconstructProject | 6 | 4 | 4 | 0.67 | 1.00 |
| T1 | temporal | — | 0 | 4 | 0 | 0.00 | 0.00 |
| T2 | temporal | reconstructRelationship | 6 | 1 | 1 | 0.17 | 1.00 |
| T3 | temporal | reconstructProject | 6 | 2 | 0 | 0.00 | 0.00 |
| T4 | temporal | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| M1 | multihop | reconstructProject | 6 | 3 | 2 | 0.33 | 0.67 |
| M2 | multihop | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| M3 | multihop | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| M4 | multihop | factualLookup | 3 | 2 | 2 | 0.67 | 1.00 |

## Gate 1 target status (floor)

| Target | Result | Status |
|---|---:|---|
| Lookup citation precision ≥ 0.9 | 0.33 | ❌ heuristic ceiling (snippet-text ranker can't fully prefer the canonical document); LLM expected to lift |
| Aggregation keyword-hit ≥ 0.8 | 0.25 | ❌ floor cannot meet this — aggregation answers need synthesis, not snippet bullets |
| Multi-hop retrieval recall ≥ 0.6 | **0.67** | ✓ **MET** |
| Temporal coverage (qualitative) | not measured this run | — |

## Notable

- **Multi-hop retrieval recall hit target (0.67 ≥ 0.6).** First Gate 1 target met by the floor alone.
- **L2 regression to note (do NOT patch):** L2 expects `amendment-7.md` + `contract.md`. The cap=3 kept amendment-7.md but dropped contract.md in favor of `invoice-432.eml` (the heuristic ranker scored an invoice's "delivery date" wording above the contract). This is almost certainly a heuristic-floor artifact — an LLM picking the canonical source for a "contracted delivery date" claim should recover contract.md. Re-check L2 against the LLM run before deciding whether this is real ranking failure.
- **T1 and T3 cite nothing (cited=0/4):** the "What changed between week N and week M" and "How did contract status evolve" questions require temporal reasoning the heuristic path lacks; LLM expected to address.
- **L4 mis-citation**: cites `supplier_abc_25.eml` instead of `invoice-401.eml`. Score-ranking artifact; LLM likely fixes by reading the invoice's content.

## Methodology

- Isolated DB (`/tmp/Gate1Baseline-<uuid>/eval.sqlite`); user's real archive never touched.
- Fixture: 8 files in `Kalsmritikosh/Resources/Fixtures/ProjectDelta/` — all loaded via folder-ref + flat-bundle fallback with loud-fail on missing files.
- Ingest coverage probe confirms all 8 files have non-zero chunks + vectors + entities + FTS rows.
- L1 retrieval probe confirms `contract.md` ranks #1 (score 0.863) for "Who is the project owner".
- Scorer compares citation object-IDs resolved to source filenames against `questions.json`'s `expectedSourceFiles` (filenames). Keyword-hit scored against `answerText` (synthesized portion), not the full `body`.

## What's next (Gate 1 procedure)

1. This is `eval-report-heuristic-floor.md` — the documented floor.
2. Run with Ollama (`llama3.1:8b`) for the LLM baseline → `eval-report-llm.md`.
3. Lock Gate 1 with both reports side by side in `eval-report.md` at repo root (UPDATE_16 Item 5).
