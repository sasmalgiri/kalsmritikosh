# Ingestion Quality Gate + Fast/Quality Tiering — Plan

Status: **PLAN ONLY — no code yet.** For owner review before implementation.
Date: 2026-07-15.

## 0. Owner principle (locked)

1. **On-device only, always. No outside/cloud services — ever.** (Privacy invariant.)
2. **Default = FAST tier**, built on Apple frameworks (Vision OCR + NLEmbedding), fewest passes, lowest latency.
3. **QUALITY is opt-in, two triggers:**
   - **User presses for it** — a "Higher quality (slower)" option (global setting + per-source / per-workspace override + a "re-ingest at higher quality" action).
   - **App auto-escalates** — when internal quality checks detect degradation on the fast pass, the app flags (or runs, in the background) a higher-quality re-pass.
4. **Quality costs time** — always surfaced to the user (estimated time / "≈N× slower", live progress). No silent long waits.
5. Even the QUALITY tier stays **on-device** (heavier local models like BGE Core ML / on-device Llama). "No outside things" is absolute; "quality" never means cloud.

Alignment with the persona spec's foundation gate (§5): the FAST tier does **zero generative work** ("no hidden generative backfill runs"); any LLM step is confined to the explicit, user-visible QUALITY tier. Direct evidence still outranks anything generated.

---

## 1. Problem being fixed

Two issues, one root:

- **The "don't embed everything" list is only partly enforced — and on the wrong path.** Embeddings + FTS are built from `chunker.chunk(KnowledgeObject.content)` (raw KO text). The boilerplate / min-length / non-content filtering lives on the **structural evidence-block layer** (`ParsedDocument` drops `isBoilerplate` blocks and `< 3` char fragments), which the **embedding path does not consume**. So signatures, disclaimers, repeated headers/footers, page numbers, nav text, and short fragments reach the vector + FTS layers.
- **`BoilerplateRegistry` exists but is not wired into ingest** (no call sites in `IngestCoordinator`).

What already works (keep): content-hash embedding reuse (`CachedEmbedder` + `EmbeddingCacheRepository`, keyed by `modelID`+`text_hash`); duplicate-file dedup (`findCanonicalByContentHash` → `alias_of`); tracking-pixel OCR skip (PERF.4); blank skip; the background embedding drain (now boot-started, timeout+breaker, no hot-loop).

---

## 2. Part A — Enforce the skip-list on the EMBEDDING path (deterministic, Fast-tier safe)

A single deterministic **ChunkAdmissionGate**, applied in `IngestCoordinator` right after `chunker.chunk(...)` and before persistence / embedding / FTS. No LLM, no network.

Marks a chunk **not admitted for embedding/FTS** when it is:
- blank / whitespace-only;
- below a tuned min meaningful length (candidate: `< 12` chars after trim + collapse; measured, not guessed);
- a **BoilerplateRegistry** match (repeated substrings across the corpus: email signatures, legal disclaimers, unsubscribe/footer blocks) — **wire the existing registry in**;
- **page-number-only / nav-only** (conservative regexes: `^\s*Page \d+( of \d+)?\s*$`, lone integers, `^(Next|Previous|Back|Home|Menu|Skip to content)$`, breadcrumb runs);
- an **in-document exact duplicate** (normalized-text hash already seen in this KO).

**Never-delete guarantee (core directive):** the gate does **not** delete or drop text. Admitted-false chunks are still **stored and citable**; they are only excluded from the vector index + FTS. Implementation options (owner pick during impl): (a) additive `chunks.admit_embedding INTEGER DEFAULT 1` column, or (b) simply don't insert into `chunks_fts`/`vectors` for non-admitted chunks while the `chunks` row stays. Either way retrieval still resolves the source.

**Cross-document dedup of embeddings:** extend the existing per-text cache into a chunk-level rule — normalized-text hash → embed once, reuse the vector for every identical chunk (the "one canonical content hash reuses the same embedding where normalized text + model version are identical" requirement). Mostly already covered by `EmbeddingCacheRepository`; needs a normalization pass (lowercase, trim, collapse whitespace) so near-identical boilerplate collapses.

**Verification gate (hard requirement, learned from the binary-classifier rejection):** before enabling ANY skip rule, run it over the real corpus and confirm **~0% false positives on genuine content** (the binary classifier flagged 43% of good chunks — that must never ship). Each rule ships only after this check.

Later (Stage 2): source embedding chunks directly from the **filtered structural blocks** (`!isBoilerplate`) instead of raw KO content — the cleaner long-term fix, larger change.

---

## 3. Part B — Fast vs Quality tiers

`enum IngestQuality { case fast, thorough }` (default `.fast`).

| Stage | FAST (default, Apple, speed) | THOROUGH (opt-in/auto, on-device, quality) |
|---|---|---|
| OCR | Vision fast pass; skip table pass unless clearly tabular | Vision **accurate** + table reconstruction + multi-orientation |
| Embedding | Apple **NLEmbedding** (300-dim) | **BGE-small** Core ML (384-dim, subword — embeds foreign/OOV too, higher quality) — on-device |
| Chunk admission gate (Part A) | on | on |
| Context prefixes (contextual retrieval) | off | on-device **Llama** context-prefix generation |
| Generative work | **none** | explicit, user-visible only |

Both tiers are 100% on-device. THOROUGH is slower and higher quality.

### Triggers
1. **User:** Settings → "Ingestion quality: Fast / Higher quality (slower)"; per-source & per-workspace override; a **"Re-ingest at higher quality"** button on a source/workspace/answer.
2. **Auto-escalation (internal quality checks):** during a FAST pass, compute cheap per-source signals; if below threshold, record it and (setting-controlled) queue a background THOROUGH re-pass:
   - OCR mean confidence `< τ_ocr` → re-OCR accurate;
   - empty-embedding ratio (NLEmbedding OOV / non-English) `> τ_oov` → BGE re-embed;
   - boilerplate ratio / low unique-content ratio high → note (not escalate);
   - parser warnings / partial extraction status.
   Persist a per-source **quality report**; surface a **quality chip** in the UI (tier + reason + what would improve).

### Cost surfacing
Show the tradeoff explicitly: estimated time / "Higher quality ≈ N× slower", and live progress. "Quality comes with a price: time" is stated in the UI at the choice point.

---

## 4. Part C — Data model + wiring (additive, migration-safe)

- `FeatureFlags`/AppState: `ingestQuality` (default `.fast`) + optional per-source override store.
- Wire `BoilerplateRegistry` into `IngestCoordinator` (currently unwired).
- Chunk admission: additive `chunks.admit_embedding` column **or** conditional FTS/vector insert (never removes the `chunks` row).
- Embedder tier: the capability spec already resolves the embedder; add a **quality dimension** so FAST→NLEmbedding, THOROUGH→BGE. (BGE model bundling = P6.2, needs the artifact.)
- Quality signals: extend `PipelineMetrics` + a per-source `quality_report` (additive table).
- Re-embed migration: when THOROUGH swaps the embedder, the `modelID` change makes the cache a clean miss (no stale vectors) — existing behavior; a background re-embed drains the now-"missing" set.

---

## 5. Part D — Staging (safe order; verify before enabling; test-gate the risky)

1. **Stage 1 (safe, deterministic, highest ROI):** wire `BoilerplateRegistry` + add the `ChunkAdmissionGate` (blank / short / page-number / nav / in-doc-dup) on the embedding+FTS path, text preserved. **Verify each rule on the real corpus first** (≈0% false positives). Measure chunks-skipped + index-size reduction.
2. **Stage 2:** `IngestQuality` enum + Settings toggle + per-source override. FAST = current behavior; THOROUGH wires accurate OCR + on-device Llama context prefixes.
3. **Stage 3:** BGE-small Core ML as the THOROUGH embedder (needs the model artifact bundled — owner/blind-run step) + re-embed drain.
4. **Stage 4:** auto-escalation via quality signals + background THOROUGH re-pass + UI quality chip + time-cost surfacing.

---

## 6. Guardrails / acceptance

- **Never deletes text.** The gate only affects embedding/FTS eligibility; every chunk stays stored and every citation still resolves.
- **On-device only, both tiers.** No network path added anywhere (privacy gate unchanged).
- **Every skip rule verified on the real corpus** (≈0% false positives on genuine content) before it is enabled — no repeat of the 43%-false-positive binary classifier.
- **FAST tier does zero generative work** (matches foundation-gate §5 "no hidden generative backfill").
- **Escalation is transparent** — the UI shows the tier, the reason it escalated, and the time cost.
- Deterministic, reproducible: same input + same tier → same admitted set + same vectors.
