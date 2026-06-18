# Kalsmritikosh — Gate 1 Baseline (LOCKED)

**Locked:** 18 Jun 2026
**Branch:** main @ `54974a2`
**Methodology:** isolated DB per run; 8-file ProjectDelta fixture; per-question scorer compares citation object-IDs resolved to source filenames against `questions.json`'s `expectedSourceFiles`; keyword-hit scored against `answerText` (synthesized portion of body, footer stripped); intent-aware citation cap with aggregation-shape override.

This document is the LOCKED Gate 1 baseline. Engine phase closes here per UPDATE_16 Item 5. Subsequent precision/recall improvements are Gate 2/3 work (reranker, contextual retrieval, parallelized expert prompts).

---

## Two baselines, side by side

Two distinct measurements because the deployment floor is macOS 15.6 where Apple's FoundationModels is unavailable. The reasoning model question (whether the LLM executes) is operational, not architectural:

| Baseline | What it measures | Reasoning provider | Triggered by |
|---|---|---|---|
| **HEURISTIC FLOOR** | Engine quality without any reasoning model — what retrieval + structure + ranking alone produce. | none (every expert on heuristic fallback) | macOS 15.6 with no Ollama running |
| **LLM-on** | Engine quality with a local reasoning model in the loop. | `provider.local.network` (Ollama serving `llama3:latest`, 8B Q4_0, on M4 16 GB) | macOS 15.6 + Ollama running |

Both baselines were generated against the same isolated ProjectDelta fixture, both passed the preflight (`Reasoning provider:` line in SettingsView reflects which one ran), both use the same scorer, same per-question table format, and the same intent-aware citation cap.

---

## Gate 1 target results

| Target | Floor | LLM | Met? |
|---|---:|---:|:--:|
| **Lookup citation precision ≥ 0.9** | 0.33 | 0.33 | ❌ both — ranker-driven citation selection; reranker is the Gate 2 fix |
| **Aggregation keyword-hit ≥ 0.8** | 0.25 | 0.50 | ❌ both — LLM doubled the score but llama3 8B is below a stronger model's ceiling |
| **Multi-hop retrieval recall ≥ 0.6** | **0.67** | **0.67** | ✓ **MET (both)** |
| **Temporal coverage (qualitative)** | T1/T3 cite 0 | T1/T3 cite 0 | ❌ both — temporal window resolution is weak; Gate 2 work |

**One target hit, three missed.** The misses fall into three diagnosed categories — each has a designated fix at a later gate, none is a regression to chase here:

1. **Lookup precision** — ranker still picks citations by retrieval similarity; the LLM produces better *answer text* but doesn't get to choose its own citations. Gate 2: reranker (per-claim relevance scoring).
2. **Aggregation keyword-hit** — `llama3:latest` is good enough to double aggregation answers (0.25 → 0.50) but not enough to fully aggregate across multi-document evidence. Gate 2 will measure stronger local models / FoundationModels on macOS 26.
3. **Temporal T1/T3 cite nothing** — IntentDetector doesn't resolve time windows ("between week 22 and 25", "evolved over time") cleanly, so retrieval gets a generic intent and the verifier refuses. Gate 2: temporal intent extraction.

---

## Per-class summary

| Class | Metric | Floor | LLM | Δ | Notes |
|---|---|---:|---:|---:|---|
| Lookup | Keyword hit | 0.50 | **1.00** | +100% | LLM produces real answer sentences; every lookup now contains its expected keyword |
| Lookup | Cite precision | 0.33 | 0.33 | 0% | Ranker-driven |
| Lookup | Recall | 0.88 | 0.88 | 0% | L2 lost `contract.md` under cap=3 both runs — flagged for reranker |
| Aggregation | Keyword hit | 0.25 | **0.50** | +100% | Synthesis kicked in; aggregation answers now coherent |
| Aggregation | Cite precision | 0.46 | 0.51 | +11% | LLM run barely tighter |
| Aggregation | Recall | 0.94 | 0.94 | 0% | Aggregation-shape override holding (no regression from cap) |
| Temporal | Keyword hit | 0.50 | 0.50 | 0% | T1/T3 refusals dominate the average |
| Temporal | Cite precision | 0.12 | 0.12 | 0% | T1/T3 cite 0; T2/T4 are over-cited |
| Temporal | Recall | 0.38 | 0.38 | 0% | Same — T1/T3 zero pulls average down |
| Multihop | Keyword hit | 0.00 | **0.50** | new | Floor literally couldn't multi-hop reason; LLM can |
| Multihop | Cite precision | 0.42 | 0.42 | 0% | Ranker-driven |
| **Multihop** | **Recall** | **0.67** | **0.67** | 0% | ✓ Target met both baselines |

---

## What's locked

✓ **Bundling** — `Resources/Fixtures/ProjectDelta/` ships all 8 files via PBXFileSystemSynchronizedRootGroup; loud-fail in `Gate1Baseline.fixtureURLs()` if any are missing
✓ **Ingestion** — every fixture file produces ≥ 1 KO + chunk + vector + entities + FTS row; `chunks_fts` populated; isolated DB per run; user archive never touched
✓ **Retrieval** — `contract.md` ranks #1 on L1 (score 0.863) in both baselines; vector hits all 8 files
✓ **Routing + experts** — `factualLookup` returns all experts including `ResearchExpert` (which reads `.vector`-layer chunks); event-experts also receive top-N chunks as `DOC` E-ids; all 6 expert LLM call-sites log `provider=<id> available=true/false` and `produced N claims, dropped M`
✓ **Citation assembly** — per-claim cap (3) + cross-claim dedupe + rank-by-`scoreByObject` + intent-aware global cap (`factualLookup`→3, `reconstruct*`→6, `executive*`→8, aggregation-shape override→8); verified via `intent` column in per-question table
✓ **Answer rendering** — `VerifiedAnswer.answerText` separates synthesized portion from subject-heading footer; EvalKit scores keyword-hit against `answerText` only (no metric gaming via entity dump)
✓ **Eval scorer** — citation `objectID` → source filename via `KnowledgeObjectRepository.sourceFilenames(for:)`; compares filename sets against `questions.json`'s `expectedSourceFiles`
✓ **Wiring transparency** — `Gate1Baseline.runPreflight` calls the same `CapabilityRegistry.resolve(.reasoning)` as experts; SettingsView surfaces `Reasoning provider: <id>` so the user knows in 1 second whether the LLM path is exercised
✓ **Privacy** — `CapabilitySpec.reasoning` declares `.localNetwork`; `isPrivacyEligible` admits both `.onDevice` (FoundationModels on macOS 26) and `.localNetwork` (Ollama on 15.6); cloud filtered via PrivacyGate

---

## What's NOT locked (deferred to Gate 2/3)

| Item | Why deferred | Where |
|---|---|---|
| Citation precision lift to ≥ 0.9 | Needs reranker scoring per-claim relevance, not retrieval similarity | Gate 2 — UPDATE_08 Item 2 spec exists |
| Aggregation keyword-hit ≥ 0.8 | Needs better-than-llama3:latest reasoning model OR FoundationModels on macOS 26 | Gate 2 — measured against stronger models |
| Temporal intent window extraction | T1 ("between week 22 and 25") returns no time window; verifier refuses | Gate 2 — IntentDetector temporal grammar |
| L2 contract.md drop | Heuristic AND LLM run both lose contract.md to invoice-432.eml on "delivery date" similarity; reranker fix | Gate 2 |
| Eval wall-clock latency | 6+ experts × independent prompt assembly × per-expert LLM call = 3-4h LLM run | Gate 2 — shared evidence cache + parallel expert dispatch |
| sqlite-vec / ANN | Brute-force vector scan; fine at fixture scale, doesn't scale to 100K+ chunks | Gate 3 |
| Contextual retrieval (Anthropic-style chunk prefix) | Improves vector ranking on small docs vs chatty neighbors | Gate 2 |
| Legacy mail formats (PST, OST, MSG, NSF) | GS-MAIL spec appended to TASKS.md Gate 3 | Gate 3 |

---

## Reproduce these numbers

```bash
# 1. Clone + checkout
git clone https://github.com/sasmalgiri/kalsmritikosh.git
cd kalsmritikosh
git checkout 54974a2     # The locked Gate 1 commit

# 2. (LLM baseline only) Install Ollama and pull llama3
brew install ollama       # or download from ollama.com
ollama serve              # in another terminal, or use menubar app
ollama pull llama3:latest # ~4.6 GB

# 3. Open in Xcode 16+ on macOS 15.6+
open Kalsmritikosh.xcodeproj

# 4. Build & run, then:
# Settings → Diagnostics → Generate Gate 1 Baseline
# Check the first line of the status box:
#   "Reasoning provider: provider.local.network (LLM-on baseline)"  → matches eval-report-llm.md
#   "Reasoning provider: none (HEURISTIC FLOOR baseline)"           → matches eval-report-heuristic-floor.md

# Reports land in:
#   ~/Library/Containers/ecosanskritiinnovation.-Kalsmritikosh/Data/Documents/EvalBaselines/
#     eval-report.md
#     eval-l1-retrieval.md
#     eval-ingest-coverage.md
```

---

## Detailed reports

- [eval-report-heuristic-floor.md](./eval-report-heuristic-floor.md)
- [eval-l1-retrieval-heuristic-floor.md](./eval-l1-retrieval-heuristic-floor.md)
- [eval-ingest-coverage-heuristic-floor.md](./eval-ingest-coverage-heuristic-floor.md)
- [eval-report-llm.md](./eval-report-llm.md)
- [eval-l1-retrieval-llm.md](./eval-l1-retrieval-llm.md)

Gate 1 is locked. G2-SWIFT6 (UPDATE_03 standing decision) is now unblocked. Reranker and contextual retrieval are the measured Gate 2 work.
