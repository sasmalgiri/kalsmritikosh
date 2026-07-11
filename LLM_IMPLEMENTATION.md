# LLM Implementation — Before vs After

_A map of every place Kalsmritikosh does (or deliberately does NOT) call a generative
LLM, so the "minimum-LLM" behaviour can be verified against the evidence-ledger spec
(`evidence_ledger_ai_agent_instructions.md`, §11 & §22)._

**Scope of the change (commits `9db3f8d`, `538db0f`, `5728cd8`):** query-time only.
Ingestion was already zero-LLM; the answer path was not. Nothing about parsing,
indexing, embeddings, or the ledger changed.

Terminology: "LLM call" = one generative `provider.generate()` / `respondClaims()`
invocation. Embeddings and the Core ML reranker are ML models but **not** generative
LLM calls, and are excluded from these counts.

---

## 1. Headline: calls per single question

| Question type | BEFORE | AFTER | Spec target (§11.3 / §22) |
|---|---:|---:|---:|
| Ordinary factual lookup | ~10–14 | **1** | "often one call is enough" |
| Moderate (weak evidence) | ~10–14 | **2** | small |
| Complex / contradiction / high-risk | ~10–14 | **≤3** | selective |
| Reconstruction (history/timeline) | up to 8 | **≤3** (5 if explicit deep) | selective |
| Investigation (explicitly requested) | ~14+ | **≤5** | on demand only |

---

## 2. Stage-by-stage

### 2.1 Ingestion — unchanged, already zero-LLM ✅

Engine pinned to `.ledgerEventDriven` (`FeatureFlags.swift`), whose policy is
`eagerMemoryDistillation: false, contextPrefixBackfill: false, firstChunkCard: false`.

| Ingest step | LLM? | How |
|---|---|---|
| Hash / MIME / dedup | No | deterministic |
| Parse (PDF/DOCX/XLSX/EML/…) | No | format parsers |
| OCR / ASR | ML, not LLM | Vision / Speech |
| Chunk + citations | No | structural rules |
| FTS index | No | SQLite FTS5 |
| Embeddings | ML, not LLM | on-device BGE, batched |
| Entities / dates | No | NER + regex |
| Memory distillation | **No (off)** | `distillOnIngest = false` |
| Context-prefix cards | **No (off)** | `contextPrefixBackfill = false` |

Matches spec §22 "Phase 1: Cheap mandatory ingestion — Generative LLM calls: zero."

### 2.2 Retrieval — unchanged, no generative LLM ✅

`HybridRetriever` uses Memory → Timeline → Entity → FTS → Summary → Graph → Vector.
The reranker default is the Core ML cross-encoder "ladder" (deterministic), **not** an
LLM (`EvidenceVerifier.swift`; env `KALSMRITIKOSH_RERANKER` can opt into an Ollama
reranker for diagnostics, off by default). The `EvidenceVerifier` itself makes **zero**
LLM calls.

### 2.3 Expert fan-out — CHANGED

**Before:** `factualLookup` had empty required-domains → `ExpertRegistry` returned
**all ~8 experts**; each `Expert.analyze()` fired one `provider.generate()`. → up to 8 calls.

**After:** `DeterministicRouter.minimalExpertSet(from:complexity:)` routes ordinary
questions (complexity < 4) to a **single generalist** (`expert.reasoning`, which reasons
across every retrieved layer and emits cited claims). The full panel returns only for
genuinely complex intents. → **1 call** for ordinary questions.

- File: `Kalsmritikosh/Routing/DeterministicRouter.swift`
- Second specialist is added only on contradiction / failed verification (via the
  synthesis escalation below), per spec §11.2.

### 2.4 Answer synthesis (MoE council + draft/critique/refine) — CHANGED

**Before:** on every non-refused answer, `AnswerSynthesizer.synthesize` ran
unconditionally with all flags default-ON:
`ExpertCouncil.deliberate` (3 personas) + DRAFT + CRITIQUE + REFINE = **~6 calls**.

**After:** `MasterBrain.escalationLevel(for:intent:question:)` decides how much the
answer is worth, and `AnswerSynthesizer.Depth` spends exactly that:

| Escalation | Synthesis | Calls added |
|---|---|---:|
| `.none` (ordinary) | ship verifier's grounded body — **no synthesis** | 0 |
| `.moderate` → `.refine` | DRAFT only | 1 |
| `.complex` → `.deep` | DRAFT + one evidence-checked REFINE | 2 |
| `.investigation` | + 2-persona council before draft | ≤4 |

- Files: `Kalsmritikosh/Brain/MasterBrain.swift`, `Kalsmritikosh/Brain/AnswerSynthesizer.swift`
- Council (`ExpertCouncil.deliberate`) now runs **only** on explicit investigation.
- Critique + refine collapsed into a single evidence-checked pass (was 2 calls).

**Escalate only on** (evidence/risk signals): retrieval confidence < 0.6, contradictions
present, unsupported/dropped claims, < 2 distinct sources, coverage < 0.5, `.riskDetection`
intent, or an explicit "deep analysis / investigate / thorough" request.
**Never escalate on** volume: document count, answer length, entity count, or general
wording. (Spec §11.3, and the user's stated rule.)

### 2.5 Narrative reconstruction — CHANGED

**Before:** `LLMNarrativeComposer` composes **one LLM call per chapter**, capped at 8.
A rich history → up to 8 calls.

**After:** `chapterBudget(for:hardMax:)` caps chapters to **3** (ordinary) / **5**
(explicit deep). Contradiction detection and narrative folding downstream are
deterministic (no LLM), so the chapter count *is* the reconstruction's call budget.

- File: `Kalsmritikosh/Knowledge/Narrative/LLMNarrativeComposer.swift`

---

## 3. Where the LLM IS used (mapped to spec §11.2)

| Spec §11.2 use | Implemented in | LLM? |
|---|---|---|
| Producing user-facing answers | `AnswerSynthesizer` / `ReasoningExpert` | Yes (adaptive) |
| Timeline narration | `LLMNarrativeComposer` | Yes (≤3 chapters) |
| Explaining evidence / reconciling contradictions | `AnswerSynthesizer` deep refine | Yes (on escalation) |
| Claim / event extraction from prose | Experts (`respondClaims` / prompt-parse) | Yes (query-time) |
| Difficult reranking | opt-in only (`KALSMRITIKOSH_RERANKER=ollama`) | Off by default |

## 4. Where the LLM is NOT used (spec §11.1) — all deterministic ✅

Hashing, MIME/type detection, native text extraction, spreadsheet/email/log parsing,
metadata, chain-of-custody, citation generation, exact dedup, FTS, chunking, date
arithmetic, timeline sorting, confidence aggregation, contradiction detection,
answerability gate.

---

## 5. How to verify

1. **Provider-boundary counter.** Every generative call now increments
   `LLMCallCounters` inside the provider (`OllamaProvider`, `CloudProvider`,
   `FoundationModelsProvider` + structured). Single source of truth.
2. **Probe My Data** (Settings → Release Readiness). Runs questions against your real
   archive read-only and reports LLM calls + latency + cited real files per question.
   Writes `EvalBaselines/real-data-probe.md`. Expect ordinary questions at 1 call.
3. **Fast Gate / Deep Eval.** Fixture-based (ProjectDelta), scored vs gold. Good for
   regression + speed; does **not** touch your real data.

## 6. Known limitations (honest)

- **Not runtime-verified end-to-end** at time of writing — builds green; the real proof
  is a Probe/Deep run showing the call counts.
- **Correctness is not auto-scored on real data** (no gold answers exist for a user's own
  documents) — that's an eyeball check on the Ask tab.
- The `SmokeTest.swift` diagnostic still force-runs a memory-distillation sweep
  (per-entity) that production ingest does not — a test-harness cost, not a shipping path.
