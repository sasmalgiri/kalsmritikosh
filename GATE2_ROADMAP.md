> **DOC STATUS: HISTORICAL** — authority chain is the Production Readiness pack -> `SHIP_DECISIONS.md` (CURRENT) -> committed code. Superseded by the pack backlog. _(bannered 2026-07-22, GOV-002.)_

# Gate 2 — Roadmap

Derived from the locked Gate 1 dual-baseline ([eval-report.md](./eval-report.md), commit `4bcf4e5`, 18 Jun 2026). Every item below has an eval metric that proves success against the heuristic-floor and LLM-on baselines locked at Gate 1. Items are ordered for measurement cost first, then quality wins, then ergonomics.

**Standing rule:** every Gate 2 item must re-run the eval and write a per-item delta into the report. No item is "done" until it shows up in the numbers without regressing recall. The hard guard from UPDATE_14 still applies — precision wins that cost recall are NOT accepted; the per-claim recall floors lock per intent kind:

- Lookup recall ≥ 0.88 (current floor + LLM)
- Aggregation recall ≥ 0.94
- Multi-hop recall ≥ 0.67 (Gate 1 target met)

If an item's re-run drops any of those, the item rolls back.

---

## G2-0 — Eval latency: parallel expert dispatch + shared evidence cache

**Why first:** Gate 1's LLM run took 3–4 hours wall clock (temporal/multihop p50 ~15 min/question) because each of 6 experts independently re-built its prompt evidence and made an isolated Ollama call. Until this lands, every subsequent Gate 2 item's re-run also costs 3–4 hours, making the loop unworkable.

**Cause (verified at Gate 1):** `ParallelExecutor` dispatches experts concurrently, but each expert calls `context.retriever.retrieve(...)` on its own (own layer list, own latency) and builds its prompt evidence map from scratch. The retrieval result and the chunk-evidence assembly are duplicated 6×. The Ollama server processes the calls sequentially because each prompt is rebuilt and re-tokenized.

**Spec:**
- One shared retrieval pass per question (per intent), cached on `ExpertContext` and reused across all experts. Each expert gets the layer-filtered view it asked for from the shared result; no second SQL traffic.
- One shared chunk-evidence assembly (the `appendChunkEvidence` step from `PromptTemplates`) shared across all experts that ask for it; each expert appends its domain-specific event evidence on top.
- Per-question wall-clock target: p50 ≤ 60s (down from 80s–15min). p95 ≤ 5 min.
- Run the full 16-question eval in ≤ 30 min wall clock.

**Eval metric (LLM baseline):**
- p50 latency: lookup ≤ 30s, aggregation ≤ 60s, temporal ≤ 90s, multihop ≤ 90s.
- Recall floors unchanged (hard guard).
- Keyword-hit unchanged or improved.

**Files touched:** `Core/Services/Expert.swift` (add cached retrieval to `ExpertContext`), `Brain/MasterBrain.swift` (call retriever once, hand result through), `Experts/*.swift` (remove redundant `context.retriever.retrieve` calls), `Experts/Shared/PromptTemplates.swift` (memoize `appendChunkEvidence`).

**Acceptance:** build green, grep guard clean, `SmokeTest` passes, eval wall-clock for LLM run < 30 min.

**Commit:** `perf: shared retrieval + chunk-evidence cache across experts`

---

## G2-PROGRESSIVE — Streaming progressive answer (instant first, deepens with reasoning)

**Why early:** transforms perceived latency the moment it ships. Today `MasterBrain.answer` is `async -> VerifiedAnswer` — the user waits the whole pipeline before seeing anything. The engine already has every piece needed for a Google-fast first hit (Memory layer narratives, streaming LLM preview, parallel experts, verified final pass); they're just not stitched. Progressive surfacing turns the worst-case 30-60s answer into a sub-second first read with the deep answer arriving while the user is still reading.

**The four phases** (each yields as it's ready):

| Phase | p50 latency | What ships to UI | Engine work |
|---|---:|---|---|
| 1 Instant cache | < 500 ms | Memory narrative for the resolved subject (project/org/person) if one exists, otherwise the subject-heading dump | `MemoryRepository.current(forSubject:identifier:)`, already implemented |
| 2 First synthesis | ~ 2-5 s | Streaming sentence answer — tokens appear live in the bubble | `AskView.streamPreview` already implemented; wire its tokens into the bubble's primary body, not just preview state |
| 3 Deep expert pass | ~ 5-30 s | Body updates with cross-doc claims; citation list grows | Existing expert fan-out; emit per-finding events instead of awaiting all |
| 4 Final verified | ~ 30-60 s | Final answer + Quality Strip + reranker-ordered citations + contradictions | Existing verifier + G2-1 reranker |

**Spec:**
- New return type: `MasterBrain.answer(question:) -> AsyncStream<AnswerUpdate>` where:
  ```
  enum AnswerUpdate {
      case instant(body: String, citations: [Citation])           // Phase 1
      case synthesisToken(String)                                  // Phase 2 deltas
      case expertFindingsArrived(ExpertFindings)                  // Phase 3 incremental
      case verified(VerifiedAnswer)                                // Phase 4 final
  }
  ```
- MasterBrain composes the stream from existing components: Memory probe + streamPreview + parallel experts + verifier — each phase yields to the stream as it completes, then phase N+1 starts (or runs concurrently where possible).
- `AskView` consumes the stream: bubble shows Phase 1 immediately, swaps to streaming for Phase 2, updates citation list as expert findings arrive in Phase 3, locks in Quality Strip at Phase 4.
- Existing `MasterBrain.answer(question:) -> VerifiedAnswer` becomes a thin wrapper that collects the stream's last `.verified` event — preserves the eval harness, no breaking API change for `EvalKitRunner`.

**Trust contract (UI required, not optional):** every phase shows a
visible state tag in the bubble so the user can NEVER mistake a
preview for a verified answer. Required states:

| Phase | Tag / visual | What user sees |
|---|---|---|
| 1 | `🕒 Quick read · verifying…` (gray, italic) | Cached narrative + citation list (clickable to source) |
| 2 | `✎ Synthesizing…` (with blinking cursor) | Streaming tokens append in real time |
| 3 | `🔍 Reading sources… N citations` (citation count grows) | Body updates with synthesized claims; citations animate in |
| 4 | full Quality Strip — confidence %, citations N, freshness, contradictions if any | Locked-in verified answer; tag disappears |

The Phase 1→4 transition must be a visible update in place — the user
SEES the answer deepen. No ambiguity about which read they're acting
on. Phase 1 must NEVER appear without the "verifying…" tag, even when
the cached narrative happens to be correct: the trust contract is
that the user always knows what they're reading.

Cache-match gate: do NOT emit Phase 1 unless the intent's subject
matches a distilled MemoryObject AND the cached narrative overlaps
the question's keyword/entity terms above a confidence threshold. If
no good match, skip Phase 1 entirely and stream directly to Phase 2.
This prevents stale cache from polluting Phase 1.

**Eval metric:** none directly — Gate 1 metrics still measured by the final verified output, unchanged. The new metric is **time-to-first-visible-content (TTFVC)**: target p50 < 1 s, p95 < 3 s. Measure by adding a TTFVC column to the per-question table; capture the timestamp of the first `AnswerUpdate` yielded.

**Files touched:** `Brain/MasterBrain.swift` (rewrite `answer`), new `Brain/AnswerUpdate.swift` (the enum), `UI/AskView.swift` (consume stream, swap bubble content as phases arrive), `EvalKit/EvalKitRunner.swift` (collect final from stream; add TTFVC column).

**Acceptance:**
- build green; grep guard clean; SmokeTest passes
- TTFVC p50 < 1 s on questions whose subject has a Memory narrative; < 3 s otherwise
- Final `VerifiedAnswer` byte-for-byte equal to pre-progressive output on the same input — recall and precision metrics unchanged (hard guard)
- AskView visibly transitions through the four phases on a real question (not just instant→done)

**Commit:** `feat: progressive answer stream (instant → synthesis → deep → verified)`

---

## G2-SWIFT6 — Swift 6 strict-concurrency migration

**Why next:** UPDATE_03 standing decision, unblocked now that Gate 1 baseline exists. Migration regressions are detected by re-running the eval against the locked baselines; that's only practical after G2-0 makes the eval finish in 30 min.

**Spec:** existing per CLAUDE.md and UPDATE_03 — `SWIFT_STRICT_CONCURRENCY=complete` across all targets, surviving warnings fixed in batches by directory (Core → Routing → Knowledge → Brain → UI → Ingestion).

**Eval metric:**
- Re-run BOTH baselines (heuristic + LLM via Ollama). Numbers must match Gate 1 within ± 2% on every metric. Any larger delta is investigated and explained in the commit message before the migration step is accepted.

**Acceptance:** build green with strict-concurrency, grep guard clean, no eval regression > 2%, SmokeTest passes.

**Commits:** `chore(swift6): <directory> strict-concurrency cleanup` (one per directory).

---

## G2-1 — Per-claim reranker (lifts citation precision)

**Why:** Gate 1's headline gap. Lookup citation precision was 0.33 in BOTH baselines because `EvidenceVerifier` ranks citation survivors by `scoreByObject` (retrieval similarity), not by claim-relevance. The LLM produces better answer *text* but doesn't get to pick its own citations. L1 cites contract.md correctly (it's #1 by retrieval similarity), but L2 ("delivery date") loses contract.md to invoice-432.eml because invoices have explicit date wording. A reranker that scores (claim text, candidate evidence text) breaks that tie.

**Spec:**
- New capability `.reranking` on `ModelCapability`.
- New `CapabilitySpec.reranking(...)` helper with `privacy: .localNetwork` (same rule as `.reasoning`).
- New `Reranker` actor consuming pairs of (claim, candidate-evidence-text) and returning per-pair scores 0..1. Resolved through `CapabilityRegistry`; never names a model. Cloud → on-device fallback: identity scoring (returns 0.5, preserving the existing scoreByObject order so no regression).
- `EvidenceVerifier.verify` calls the reranker on the post-dedupe, pre-cap candidate set; reorders by `(rerankScore, scoreByObject)` desc; THEN applies the intent-aware global cap.
- Ollama path: `qwen2.5:14b` or similar via cross-encoder mode (Ollama doesn't expose cross-encoder directly; use prompted scoring — "Rate 0–1 how strongly this evidence supports this claim. Reply with a single number." with a strict number parser).

**Eval metric (LLM baseline):**
- Lookup citation precision: 0.33 → ≥ 0.6 (trajectory toward 0.9). L2 regains contract.md.
- All recall floors unchanged.
- Per-question table: each lookup's `overlap` ≥ 1 with at most 3 cited.

**Files touched:** `Core/Services/ModelProvider.swift` (add `.reranking` capability), `Routing/CapabilitySpec.swift` (add `.reranking` helper), new `Brain/Reranker.swift`, `Brain/EvidenceVerifier.swift` (call reranker before cap), `App/AppState.swift` (register the reranker capability through the existing providers — no model name in restricted dirs).

**Acceptance:** build green, grep guard clean, LLM eval shows lookup precision ≥ 0.6 with recall held, SmokeTest passes.

**Commit:** `feat: per-claim reranker for citation selection`

---

## G2-2 — Temporal intent window grammar (fixes T1, T3)

**Why:** Gate 1 has TWO temporal questions that cite zero documents and produce no answer:
- T1: "What changed between week 22 and week 25 of Project Delta?"
- T3: "How did the contract status evolve over time for Project Delta?"

`IntentDetector.inferKind` correctly classifies T1 as `executiveBriefing` and T3 as `reconstructProject` — but the **timeframe** is never extracted. With no `intent.timeframe`, the timeline layer returns 100 generic recent events, the brain refuses or produces noise, and no expert cites a doc.

**Spec:**
- New `TemporalGrammar` helper inside `IntentDetector` that parses:
  - "between week N and week M of <project>" → a `Timeframe` resolved against the project's earliest known event (or its `Effective Date` field from contract.md)
  - "over time" / "evolved" / "changed" → an open timeframe from the project's first event to its last
  - "this week / this month / last quarter" → window relative to `Date()`
- Inject into `UserIntent.timeframe` so the timeline layer can use it.
- Update `EvidenceVerifier.subjectHeading` to surface the resolved window in the answer footer.

**Eval metric:**
- T1, T3 cite ≥ 2 documents each (currently 0).
- Temporal retrieval recall: 0.38 → ≥ 0.6.
- Temporal keyword-hit: 0.50 → ≥ 0.75.

**Files touched:** `Routing/IntentDetector.swift`, `Brain/EvidenceVerifier.swift` (subjectHeading footer line).

**Acceptance:** build green, grep guard clean, both baselines show T1 and T3 with non-empty `cited` columns, recall floors held.

**Commit:** `feat: temporal window grammar in IntentDetector`

---

## G2-3 — Contextual retrieval (Anthropic-style chunk prefix)

**Why:** Vector retrieval correctly ranks contract.md #1 on L1, but the score gap is tiny (0.863 vs 0.860 vs 0.853 vs 0.845 — 6 docs within 0.018 of each other). Chunks lack their parent document's context, so a contract paragraph about "delivery" embeds similarly to an invoice line about "delivery." Anthropic's contextual retrieval prepends a sentence summarizing the parent doc to each chunk before embedding, opening the score gap.

**Spec:**
- During ingestion (`Ingestion/Pipeline/Chunker.swift` → `Ingestion/Pipeline/IngestCoordinator.swift`):
  - Before embedding each chunk, call the reasoning capability with a small prompt: "In one sentence, what is this section's context within the document `<filename>`?" using the document's first 1500 chars + the chunk text.
  - Prepend the response to the chunk text used ONLY for embedding (the stored chunk text is unchanged, so display + FTS are unaffected).
  - Skip if the chunk is the whole document (no parent context to add).
- Schema migration v9: add `chunks.context_prefix` (TEXT NULL).

**Eval metric:**
- L1 retrieval probe shows contract.md's vector score gap to #2 widen from 0.003 to ≥ 0.02.
- Lookup citation precision improves on questions whose ground truth is a small doc (L1, L3) by ≥ 0.1.
- Recall floors held.

**Files touched:** `Storage/Schema/SchemaMigrations.swift` (v9), `Ingestion/Pipeline/Chunker.swift`, `Ingestion/Pipeline/IngestCoordinator.swift`, `Storage/Vector/Embedder.swift` (use prefix at embed time, not at chunk store time).

**Acceptance:** build green, grep guard clean, ingest coverage probe shows all 8 fixture files with `context_prefix IS NOT NULL` (except the .md files whose chunks ARE the whole doc), L1 vector gap widens, recall held.

**Commit:** `feat: contextual retrieval — per-chunk context prefix at embed time`

---

## G2-4 — Operational: stronger reasoning model evaluation

**Why:** Gate 1's LLM-on baseline uses `llama3:latest` (8B, Q4_0). Aggregation keyword-hit doubled (0.25 → 0.50) but is short of the 0.8 target. This is a model-ceiling question, not a code question. Document the path so the next reasoning-model trial is reproducible.

**Spec (no code; instructions in repo):**
- Procedure for trying a stronger model:
  1. `ollama pull qwen2.5:14b` (or another larger model that fits user hardware)
  2. Update `AppState.swift:144` `modelTag` to the new tag — the architecture invariant keeps the model name confined to `App/`
  3. Re-run Gate 1 baseline, save as `eval-report-llm-<modelname>.md` at repo root
- macOS 26 / Apple Intelligence: `FoundationModelsProvider`'s `#available(macOS 26.0, *)` gate fires automatically; no code change needed.
- `eval-report.md` table grows a column per evaluated model. The lock stays — additional rows are evidence of model ceilings, not new Gate 1 targets.

**Eval metric:** none required for the spec itself. When a model is trialed, the existing aggregation keyword-hit ≥ 0.8 target either gets met or doesn't, and the result lands in the report.

**Files touched:** README section, optionally a small `tools/run-gate1.sh` script.

**Commit:** `docs: stronger-model trial procedure`

---

## G2-5 — UI: streaming + Quality Strip expand affordance

**Why:** Gate 1 work focused on engine correctness; the user-facing answer surface is functional but minimal. Two small UX wins ship cheaply now that the engine is stable.

**Spec:**
- AskView: when an LLM provider is resolved for streaming, the answer body fills word-by-word (existing `streamPreview` already supports this — just needs a UI polish pass for cursor + done state).
- QualityStrip: tap to expand a popover showing per-citation snippets + the contradiction list verbatim. Already in `VerifiedAnswer`; just unsurfaced.

**Eval metric:** none. UX wins. SmokeTest must still pass.

**Files touched:** `UI/AskView.swift`, `UI/QualityStrip.swift`.

**Commit:** `feat: streaming answer + Quality Strip expand`

---

## Order summary

```
G2-0       →  G2-PROGRESSIVE  →  G2-SWIFT6  →  G2-1   →  G2-2  →  G2-3  →  G2-4  →  G2-5
latency       UX feel            strict       reranker  temporal contextual model   ux
(retrieval)   (stream phases)    concurrency           window   retrieval  trial   polish
```

G2-PROGRESSIVE is placed before G2-SWIFT6 because it transforms the user's experience of latency *immediately* — even on the heuristic floor a real interaction feels instant, because Phase 1 hits the Memory cache and Phase 2 streams. The reranker (G2-1) plugs into Phase 4 cleanly once it lands; the progressive scaffolding doesn't need it to ship value.

Re-run eval after each. Hard guard on recall throughout. Engine phase remains closed in the sense that this is *measured* improvement against a locked baseline — every item is "did the numbers move in the direction we predicted?", not "did we ship more features." If an item doesn't move the numbers, it doesn't ship.

---

## Out of scope (Gate 3)

- sqlite-vec / ANN (`UPDATE_03` and TASKS.md Gate 3 outline)
- GS-MAIL legacy parser port (TASKS.md `GS-MAIL` block)
- T13.3 Foundation Models guided extraction (gated on macOS 26 floor)
- Tiered LLM extraction at scale, demand-driven Tier-3 queue
- Entity dossier export

---

Locked at: 18 Jun 2026, against `eval-report.md` commit `4bcf4e5`.
