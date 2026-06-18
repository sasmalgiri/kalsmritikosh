# Kalsmritikosh — LLM-on Baseline (Gate 1)

**Generated:** 18 Jun 2026 at 6:15:03 AM
**Mode:** LLM-on via Ollama
**Reasoning provider:** `provider.local.network` (Ollama running `llama3:latest`, 8B Q4_0)
**Confirmation:** every expert log line read `provider=provider.local.network available=true` followed by `produced N claims, dropped M` (visible in Xcode console); per-question p50 latencies are 36s–15min, consistent with ~96 real LLM round-trips total. **This baseline measures the engine with reasoning.**

## Targets (Gate 1)

- lookup citation precision ≥ 0.9
- temporal answers carry non-empty coverage with named gap labels
- aggregation keyword-hit rate ≥ 0.8
- multi-hop retrieval recall ≥ 0.6

## Per-class metrics

| Class | N | Keyword hit | Cite precision | Retrieval recall | p50 (ms) | p95 (ms) |
|---|---:|---:|---:|---:|---:|---:|
| lookup | 4 | **1.00** | 0.33 | 0.88 | 36 293 | 46 497 |
| aggregation | 4 | 0.50 | 0.51 | 0.94 | 80 956 | 936 240 |
| temporal | 4 | 0.50 | 0.12 | 0.38 | 923 332 | 995 268 |
| multihop | 4 | 0.50 | 0.42 | 0.67 | 933 370 | 964 867 |

## Per-question detail

| Q | class | intent | cited | expected | overlap | precision | recall |
|---|---|---|---:|---:|---:|---:|---:|
| L1 | lookup | factualLookup | 3 | 1 | 1 | 0.33 | 1.00 |
| L2 | lookup | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| L3 | lookup | factualLookup | 3 | 1 | 1 | 0.33 | 1.00 |
| L4 | lookup | factualLookup | 3 | 1 | 1 | 0.33 | 1.00 |
| A1 | aggregation | factualLookup | 6 | 2 | 2 | 0.33 | 1.00 |
| A2 | aggregation | reconstructRelationship | 5 | 4 | 3 | 0.60 | 0.75 |
| A3 | aggregation | factualLookup | 7 | 3 | 3 | 0.43 | 1.00 |
| A4 | aggregation | reconstructProject | 6 | 4 | 4 | 0.67 | 1.00 |
| T1 | temporal | — | 0 | 4 | 0 | 0.00 | 0.00 |
| T2 | temporal | reconstructRelationship | 6 | 1 | 1 | 0.17 | 1.00 |
| T3 | temporal | reconstructProject | 6 | 2 | 0 | 0.00 | 0.00 |
| T4 | temporal | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| M1 | multihop | reconstructProject | 6 | 3 | 2 | 0.33 | 0.67 |
| M2 | multihop | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| M3 | multihop | factualLookup | 3 | 2 | 1 | 0.33 | 0.50 |
| M4 | multihop | factualLookup | 3 | 2 | 2 | 0.67 | 1.00 |

## Sample expert LLM execution log (from Xcode console)

```
expert.research LLM: provider=provider.local.network available=true
expert.financial LLM: provider=provider.local.network produced 1 claims, dropped 0
expert.email LLM: provider=provider.local.network produced 0 claims, dropped 0
expert.legal LLM: provider=provider.local.network produced 1 claims, dropped 0
expert.project LLM: provider=provider.local.network available=true
expert.timeline LLM: provider=provider.local.network available=true
expert.research LLM: provider=provider.local.network produced 1 claims, dropped 0
expert.financial LLM: provider=provider.local.network produced 0 claims, dropped 0
```

(All ~96 expert invocations show `provider=provider.local.network`. No `available=false` log lines, no heuristic fallbacks for the reasoning role.)

## Gate 1 target status (LLM)

| Target | Result | Status |
|---|---:|---|
| Lookup citation precision ≥ 0.9 | 0.33 | ❌ ranker still drives the cap; LLM lifts answer *text*, not citation selection → reranker is the Gate 2/3 fix |
| Aggregation keyword-hit ≥ 0.8 | 0.50 | ⚠ doubled from floor (0.25) but still short; deeper reasoning model would likely close it |
| Multi-hop retrieval recall ≥ 0.6 | **0.67** | ✓ **MET** |
| Temporal coverage (qualitative) | T1 and T3 cite 0 docs | ❌ temporal reasoning + intent-window handling weak; Gate 2 work |

## Vs floor — what the LLM actually changed

| Metric | Floor | LLM | Δ |
|---|---:|---:|---|
| Lookup keyword-hit | 0.50 | **1.00** | **+100%** ✓ |
| Aggregation keyword-hit | 0.25 | **0.50** | **+100%** |
| Multihop keyword-hit | 0.00 | **0.50** | new (was 0) |
| Citation precision (any class) | ≈ same | ≈ same | 0% — ranker-driven, not claim-driven |
| Recall (any class) | ≈ same | ≈ same | 0% — retrieval was already sound |

**The honest read:** the LLM doubled or tripled keyword-hit across lookup/aggregation/multihop because answer *bodies* are now real synthesized sentences instead of snippet bullets. But citation precision didn't move because `EvidenceVerifier`'s cap + rank picks survivors by `scoreByObject` (retrieval similarity), not by which claim cited them. The Gate 2/3 reranker is what closes that gap.

## Latency observation (for Gate 2)

Temporal/multihop p50 ~15 minutes/question. The eval ran ~3-4 hours wall clock. Cause: each of 6+ experts independently re-builds its full prompt evidence and makes a separate Ollama call. With shared evidence assembly and per-expert prompt caching, this should drop ~5×.

## Methodology (unchanged from floor)

- Isolated DB; user's real archive never touched.
- Fixture: 8 files (4 .md + 4 .eml + 4 supplier_abc, total 8).
- Scorer compares citation object-IDs resolved to filenames against `questions.json`.
- Keyword-hit scored on `answerText` (synthesized portion), not full `body`.
- Preflight: `Reasoning provider: provider.local.network (LLM-on baseline)` confirmed in Settings UI before run started.
